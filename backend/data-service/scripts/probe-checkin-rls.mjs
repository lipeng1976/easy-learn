#!/usr/bin/env node
/**
 * **打卡隔离的行为判据** —— 换一个身份，看行数变不变。
 *
 * `019_checkin_quiz.sql` 给 `checkin_quiz` / `checkin_result` 加了
 * `student_id = ANY(app_csv_setting('app.visible_students'))` 的 RLS 策略。
 * 这条语义**单元测试证明不了**：`test/checkin-store.test.js` 用的是假 client，
 * 它只证明「SQL 被发出去了」。策略写错、只建不启用、或者 `app.visible_students`
 * 传成会话级（连接池复用串身份），那边照样全绿。
 *
 * ## 判据
 *
 *   · 学生 S1 看到自己的 1 份打卡，看不到 S2 的
 *   · 家长 P1 看到孩子 S1 的打卡（这是「家长发起/查看」的全部依据）
 *   · 无关系的学生看到 0 行
 *   · 学生 S2 INSERT 一份属于 S1 的打卡 → 42501
 *   · 学生 S2 UPDATE S1 的打卡 → 影响 0 行
 *   · 结果表同口径（S1 看到 1 行，路人 0 行）
 *   · **反向对照**：管理员看到 2 行 —— 上面那些 0/1 才是被策略拦下的
 *
 * ## 用法
 *
 *   node scripts/probe-checkin-rls.mjs --env-file "D:/easy_learn_home/config/local.env"
 *
 * 读 `PG_OPS_USER/PG_OPS_PASSWORD`（造数据、对照）与 `PGUSER/PGPASSWORD`（被验证的身份）。
 * **跑完会删掉自己造的全部数据**（前缀 `ckprobe`）。
 */
import pg from 'pg';

import { cloudHost, loadEnv, valueOf } from './lib/env-file.mjs';

const PREFIX = 'ckprobe';
const P1 = `${PREFIX}_parent1`;
const S1 = `${PREFIX}_stu1`;
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
console.log('  打卡隔离 · 行为判据');
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

const QUESTIONS = JSON.stringify([
  {
    type: 'choice',
    stem: '$1+1=?$',
    options: ['1', '2', '3', '4'],
    answer: 'B',
    knowledge: '有理数',
    analysis: '',
  },
]);

async function cleanup() {
  await admin.query(`delete from checkin_quiz where student_id like $1`, [`${PREFIX}%`]);
  await admin.query(`delete from relationship where student_id like $1 or parent_id like $1`, [
    `${PREFIX}%`,
  ]);
  await admin.query(`delete from app_user where id like $1`, [`${PREFIX}%`]);
}

await cleanup();

await admin.query(
  `insert into app_user (id, name, role, avatar) values
     ($1,'探针家长','parent',''), ($2,'探针学生1','student',''),
     ($3,'探针学生2','student',''), ($4,'无关系学生','student','')`,
  [P1, S1, S2, LONER],
);
await admin.query(
  `insert into relationship (id, student_id, parent_id, sender_id, status)
   values ($1,$2,$3,$2,'active')`,
  [`${PREFIX}_rel1`, S1, P1],
);
await admin.query(
  `insert into checkin_quiz (id, student_id, owner_user_id, quiz_date, subject, questions, status)
   values ($1,$2,$3,$4,'数学',$5::jsonb,'done'), ($6,$7,$8,$9,'数学',$5::jsonb,'pending')`,
  [`${PREFIX}_quiz1`, S1, P1, '2026-10-27', QUESTIONS, `${PREFIX}_quiz2`, S2, S2, '2026-10-27'],
);
await admin.query(
  `insert into checkin_result (quiz_id, student_id, answers, score, total)
   values ($1,$2,$3::jsonb,1,1)`,
  [`${PREFIX}_quiz1`, S1, JSON.stringify([{ index: 0, picked: 'B' }])],
);

let failed = 0;
const check = (ok, name, detail) => {
  if (!ok) failed += 1;
  console.log(`  ${ok ? '✓' : '✗'} ${name}`);
  if (detail) console.log(`      ${detail}`);
};

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

console.log('【读路径】');

const s1 = await asUser(
  S1,
  S1,
  `select id, student_id from checkin_quiz where student_id like $1 order by id`,
  [`${PREFIX}%`],
);
check(
  s1.rowCount === 1 && s1.rows[0].student_id === S1,
  '学生 S1 只看到自己的 1 份打卡',
  `实际 ${s1.rowCount} 行${s1.rowCount ? ' → ' + JSON.stringify(s1.rows) : ''}`,
);

const p1 = await asUser(
  P1,
  S1,
  `select id from checkin_quiz where student_id like $1`,
  [`${PREFIX}%`],
);
check(p1.rowCount === 1, '家长 P1 看到孩子 S1 的打卡', `实际 ${p1.rowCount} 行`);

const loner = await asUser(
  LONER,
  LONER,
  `select id from checkin_quiz where student_id like $1`,
  [`${PREFIX}%`],
);
check(loner.rowCount === 0, '无关系的学生看不到任何打卡', `实际 ${loner.rowCount} 行`);

const s1Result = await asUser(
  S1,
  S1,
  `select quiz_id from checkin_result where student_id like $1`,
  [`${PREFIX}%`],
);
check(s1Result.rowCount === 1, '学生 S1 看到自己的结果 1 行', `实际 ${s1Result.rowCount} 行`);

const lonerResult = await asUser(
  LONER,
  LONER,
  `select quiz_id from checkin_result where student_id like $1`,
  [`${PREFIX}%`],
);
check(lonerResult.rowCount === 0, '无关系的学生看不到任何结果', `实际 ${lonerResult.rowCount} 行`);

console.log('\n【反向对照 · 判据的区分力】');
const all = await admin.query(
  `select count(*)::int as n from checkin_quiz where student_id like $1`,
  [`${PREFIX}%`],
);
check(
  all.rows[0].n === 2,
  '管理员（不受策略约束）看到 2 份打卡',
  all.rows[0].n === 2
    ? '所以上面的 0/1 是**被策略拦下来的**，不是「表里没数据」'
    : `实际 ${all.rows[0].n} 行 → 上面的 0/1 不能算证据`,
);

console.log('\n【写路径 · 读被管住 ≠ 写被管住】');

const upd = await asUser(
  S2,
  S2,
  `update checkin_quiz set subject='hacked' where student_id = $1`,
  [S1],
);
check(upd.rowCount === 0, '学生 S2 改不动 S1 的打卡（影响 0 行）', `实际影响 ${upd.rowCount} 行`);

let insertCode = '';
await app.query('begin');
try {
  await app.query('select set_config($1,$2,true)', ['app.user_id', S2]);
  await app.query('select set_config($1,$2,true)', ['app.visible_students', S2]);
  await app.query(
    `insert into checkin_quiz (id, student_id, quiz_date, questions)
     values ($1,$2,$3,$4::jsonb)`,
    [`${PREFIX}_illegal`, S1, '2026-10-28', QUESTIONS],
  );
  await app.query('rollback');
} catch (e) {
  insertCode = e.code ?? 'unknown';
  await app.query('rollback');
}
check(
  insertCode === '42501',
  '学生 S2 给别人造打卡：被拒（42501）',
  insertCode ? `错误码 ${insertCode}` : '竟然插进去了 —— 写路径没拦住',
);

await cleanup();
const left = await admin.query(`select count(*)::int as n from checkin_quiz where id like $1`, [
  `${PREFIX}%`,
]);
console.log(`\n清理：残留打卡 ${left.rows[0].n} 行`);

await admin.end();
await app.end();

console.log('');
if (failed === 0) {
  console.log('✓ 全部判据通过 —— 打卡只对本人与家长可见，写也拦住了。');
  process.exit(0);
}
console.log(`✗ ${failed} 条判据没过 —— 带 ✗ 的每一条都要当问题处理。`);
process.exit(1);
