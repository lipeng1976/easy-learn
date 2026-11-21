#!/usr/bin/env node
/**
 * **ima 同步的学生侧隔离判据** —— 不看"策略建了没有"，只看"换身份行数变不变"。
 *
 * ## 为什么必须单独有这一条
 *
 * `018_ima_family_read.sql` 的目的是「学生能读到所属家庭的同步状态，但不能写」。
 * 这条语义**没有任何单元测试能覆盖**：`test/ima-credential.test.js` 用的是假 client，
 * 它验证的是「SQL 被发出去了」，不是「PG 真的这么判」。策略写错、少写 `FOR SELECT`、
 * 或者子查询方向反了，那些测试**全都是绿的**。
 *
 * 所以这里用真库、真角色、真关系行造两个家庭，逐条量行数。
 *
 * ## 判据（每一条都挡一种具体的错法）
 *
 *   · 学生 S1 看 `ima_credential`         → 1 行（自家 P1），**看不到 P2**
 *   · 学生 S1 看 `ima_student_kb`          → 1 行（自己的 KB）
 *   · 家长 P1 看 `ima_credential`          → 1 行（自己那行，017 的 own 策略）
 *   · 没有关系的路人学生                    → 0 行（策略不能顺带放行全表）
 *   · 学生 S1 UPDATE / DELETE 凭证          → 影响 0 行（只给了 SELECT，写不进来）
 *   · 学生 S1 INSERT 凭证                   → 抛 42501
 *   · **反向对照**：管理员看得到 2 行       → 上面那些 0/1 才是"被策略拦的"
 *
 * ## 用法
 *
 *   node scripts/probe-ima-rls.mjs --env-file "D:/easy_learn_home/config/local.env"
 *
 * 读 `PG_OPS_USER/PG_OPS_PASSWORD`（造数据、做对照）与 `PGUSER/PGPASSWORD`（被验证的身份）。
 * **跑完会删掉自己造的全部数据**（前缀 `imaprobe`）。
 */
import pg from 'pg';

import { cloudHost, loadEnv, valueOf } from './lib/env-file.mjs';

const PREFIX = 'imaprobe';
const P1 = `${PREFIX}_parent1`;
const S1 = `${PREFIX}_stu1`;
const P2 = `${PREFIX}_parent2`;
const S2 = `${PREFIX}_stu2`;
const LONER = `${PREFIX}_loner`;

const args = process.argv.slice(2);
const { env, fromFile } = loadEnv(valueOf(args, '--env-file'));

const base = {
  host: cloudHost(env),
  port: Number(env.PGPORT ?? 5432),
  database: env.PGDATABASE ?? 'easy_learn',
};

const opsUser = (env.PG_OPS_USER ?? '') || env.PGUSER;
const opsPass = (env.PG_OPS_USER ?? '') ? env.PG_OPS_PASSWORD : env.PGPASSWORD;
const appUser = env.PGUSER;
const appPass = env.PGPASSWORD;

if (!appUser || !appPass) {
  console.error('缺 PGUSER / PGPASSWORD —— 没有"应用角色"这一侧就对照不了。');
  process.exit(2);
}

console.log('═══════════════════════════════════════════════════════════════');
console.log('  ima 同步 · 学生侧隔离判据');
console.log('═══════════════════════════════════════════════════════════════\n');
console.log(`  库：${base.host}:${base.port}/${base.database}`);
console.log(`  造数据 / 对照：${opsUser}  ·  被验证的身份：${appUser}`);
if (fromFile) console.log(`  环境变量文件：${valueOf(args, '--env-file')}`);
console.log('');

const admin = new pg.Client({ ...base, user: opsUser, password: opsPass });
const app = new pg.Client({ ...base, user: appUser, password: appPass });

try {
  await admin.connect();
  await app.connect();
} catch (e) {
  console.error(`连不上：${e.code ?? ''} ${e.message}`);
  process.exit(1);
}

// ── 造两个家庭 ────────────────────────────────────────────────
// 先清残留（上一次被中断过），再按「关系 → 用户」的顺序插。
async function cleanup() {
  await admin.query(`delete from relationship where student_id like $1 or parent_id like $1`, [
    `${PREFIX}%`,
  ]);
  await admin.query(`delete from app_user where id like $1`, [`${PREFIX}%`]);
}

await cleanup();

await admin.query(
  `insert into app_user (id, name, role, avatar) values
     ($1,'探针家长1','parent',''), ($2,'探针学生1','student',''),
     ($3,'探针家长2','parent',''), ($4,'探针学生2','student',''),
     ($5,'无关系学生','student','')`,
  [P1, S1, P2, S2, LONER],
);

await admin.query(
  `insert into relationship (id, student_id, parent_id, sender_id, status) values
     ($1,$2,$3,$2,'active'), ($4,$5,$6,$5,'active')`,
  [`${PREFIX}_rel1`, S1, P1, `${PREFIX}_rel2`, S2, P2],
);

// 两个家庭都"已连接"，状态故意不同（P2 用 expired）——
// 这样"看到 1 行"还能顺带证明看到的是**自家那一行**，不是随便某一行。
await admin.query(
  `insert into ima_credential (owner_user_id, clientid_enc, apikey_enc, status, kb_owner_name)
   values ($1,'probe-cid-1','probe-key-1','active','探针家长1'),
          ($2,'probe-cid-2','probe-key-2','expired','探针家长2')`,
  [P1, P2],
);

await admin.query(
  `insert into ima_student_kb (student_id, owner_user_id, kb_id, kb_name)
   values ($1,$2,'kb_probe_1','伴学-探针1'), ($3,$4,'kb_probe_2','伴学-探针2')`,
  [S1, P1, S2, P2],
);

let failed = 0;
const check = (ok, name, detail) => {
  if (!ok) failed += 1;
  console.log(`  ${ok ? '✓' : '✗'} ${name}`);
  if (detail) console.log(`      ${detail}`);
};

/**
 * 以某个身份在事务里读一次。
 *
 * ⚠️ 必须是 `set_config(..., true)`（事务级）：会话级 `SET` 会被连接池复用到
 * 下一个请求上 —— 那正是 RLS 最危险的失效方式（上一家的身份读到下一家的数据）。
 */
async function asUser(userId, visible, sql, params = []) {
  await app.query('begin');
  try {
    await app.query('select set_config($1,$2,true)', ['app.user_id', userId]);
    await app.query('select set_config($1,$2,true)', ['app.visible_students', visible]);
    const r = await app.query(sql, params);
    await app.query('commit');
    return r;
  } catch (e) {
    await app.query('rollback');
    throw e;
  }
}

// ── 读路径 ────────────────────────────────────────────────────
console.log('【读路径 · 学生只读自家】');

const s1Cred = await asUser(
  S1,
  S1,
  `select owner_user_id, status from ima_credential where owner_user_id like $1 order by owner_user_id`,
  [`${PREFIX}%`],
);
check(
  s1Cred.rowCount === 1 && s1Cred.rows[0].owner_user_id === P1,
  '学生 S1 看到 ima_credential 1 行，且是自家 P1',
  `实际 ${s1Cred.rowCount} 行${s1Cred.rowCount ? ' → ' + JSON.stringify(s1Cred.rows) : ''}`,
);
check(
  s1Cred.rows[0]?.status === 'active',
  '读到的是自家状态（active），不是 P2 的 expired',
  `status=${s1Cred.rows[0]?.status}`,
);

const s1Kb = await asUser(
  S1,
  S1,
  `select student_id, kb_id from ima_student_kb where student_id like $1 order by student_id`,
  [`${PREFIX}%`],
);
check(
  s1Kb.rowCount === 1 && s1Kb.rows[0].student_id === S1,
  '学生 S1 看到 ima_student_kb 1 行（自己的）',
  `实际 ${s1Kb.rowCount} 行`,
);

const p1Cred = await asUser(
  P1,
  S1,
  `select owner_user_id from ima_credential where owner_user_id like $1`,
  [`${PREFIX}%`],
);
check(
  p1Cred.rowCount === 1 && p1Cred.rows[0].owner_user_id === P1,
  '家长 P1 看到自己那 1 行（017 的 own 策略仍生效）',
  `实际 ${p1Cred.rowCount} 行`,
);

const lonerCred = await asUser(
  LONER,
  LONER,
  `select owner_user_id from ima_credential where owner_user_id like $1`,
  [`${PREFIX}%`],
);
check(lonerCred.rowCount === 0, '无关系的路人学生看不到任何一行', `实际 ${lonerCred.rowCount} 行`);

// ── 反向对照 ──────────────────────────────────────────────────
console.log('\n【反向对照 · 判据的区分力】');
const all = await admin.query(
  `select count(*)::int as n from ima_credential where owner_user_id like $1`,
  [`${PREFIX}%`],
);
const total = all.rows[0].n;
check(
  total === 2,
  '管理员（不受策略约束）看到 2 行',
  total === 2
    ? '所以上面那些 0/1 行是**被策略拦下来的**，不是「表里没数据」'
    : `实际 ${total} 行 → 上面的 0/1 不能算证据`,
);

// ── 写路径 ────────────────────────────────────────────────────
console.log('\n【写路径 · 只给了 SELECT，就别让它写】');

const upd = await asUser(
  S1,
  S1,
  `update ima_credential set status='unconnected' where owner_user_id like $1`,
  [`${PREFIX}%`],
);
check(
  upd.rowCount === 0,
  '学生 S1 UPDATE 凭证：影响 0 行（改不到家长的 apikey）',
  `实际影响 ${upd.rowCount} 行`,
);

const del = await asUser(
  S1,
  S1,
  `delete from ima_credential where owner_user_id like $1`,
  [`${PREFIX}%`],
);
check(del.rowCount === 0, '学生 S1 DELETE 凭证：影响 0 行', `实际影响 ${del.rowCount} 行`);

let insertCode = '';
await app.query('begin');
try {
  await app.query('select set_config($1,$2,true)', ['app.user_id', S1]);
  await app.query('select set_config($1,$2,true)', ['app.visible_students', S1]);
  await app.query(
    `insert into ima_credential (owner_user_id, clientid_enc, apikey_enc, status)
     values ($1,'x','y','active')`,
    [P1],
  );
  await app.query('rollback');
} catch (e) {
  insertCode = e.code ?? 'unknown';
  await app.query('rollback');
}
check(
  insertCode === '42501',
  '学生 S1 INSERT 凭证：被拒（42501）',
  insertCode ? `错误码 ${insertCode}` : '竟然插进去了 —— 写路径没拦住',
);

// ── 清理 ──────────────────────────────────────────────────────
await cleanup();
const leftUsers = await admin.query(`select count(*)::int as n from app_user where id like $1`, [
  `${PREFIX}%`,
]);
const leftCred = await admin.query(
  `select count(*)::int as n from ima_credential where owner_user_id like $1`,
  [`${PREFIX}%`],
);
console.log(
  `\n清理：残留用户 ${leftUsers.rows[0].n} 行 / 凭证 ${leftCred.rows[0].n} 行` +
    '（app_user 级联删 ima_credential 与 ima_student_kb）',
);

await admin.end();
await app.end();

console.log('');
if (failed === 0) {
  console.log('✓ 全部判据通过 —— 学生只读自家状态、写不进来、跨家庭不可见。');
  process.exit(0);
}
console.log(`✗ ${failed} 条判据没过 —— 带 ✗ 的每一条都要当问题处理。`);
process.exit(1);
