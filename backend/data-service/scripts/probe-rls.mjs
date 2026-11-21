#!/usr/bin/env node
/**
 * **行级隔离的行为判据** —— 不看"迁移成功"，只看"不同身份分别能看到几行"。
 *
 * ## 为什么必须单独有这一条
 *
 * `schema_migrations` 全绿、策略数对得上、`relrowsecurity = true` ……这些**都不构成**
 * 「隔离生效」的证据。策略可以写错、可以只建不启用、可以被更宽的一条 OR 掉，
 * 而上面那些仍然全部为真。唯一的证据是：**换一个身份，看到的行数变了。**
 *
 * ## 判据设计（每一侧都有它挡的东西）
 *
 * 用**管理员**（带 BYPASSRLS）造三行探针数据 —— 学生 A、学生 B，**外加一行
 * `student_id = ''`**（那是 schema 里归属列的默认值，"漏传归属"会静默写出这种行）。
 * 然后用**应用角色**逐个试可见集合：
 *
 *   不设 · 空串 · 'stu_a' · 'stu_b' · 'stu_a,stu_b' · 不存在的学生 · ',,'
 *   期望： 0  ·  0   ·   1    ·   1    ·       2       ·       0        ·  0
 *
 * 三处刻意设计：
 *
 * 1. **反向对照**：管理员必须看到**全部 3 行**。没有这一条，上面那些 0 只是
 *    「表里没数据」，判据根本没有区分力。
 * 2. **`',,'`**：解析 `''` 得到的是**空数组**（安全），而 `',,'` 会得到
 *    **含空串元素的数组** —— 它会匹配 `student_id = ''` 的行。这一条就是为它留的。
 * 3. **写路径**：以 A 的身份插一行 B 的数据，必须被拒
 *    （`42501 new row violates row-level security policy`）。
 *    「读被管住了」不等于「写也被管住了」。
 *
 * ## 用法
 *
 *   node scripts/probe-rls.mjs --env-file ../../.env.prod
 *
 * 读 `PG_OPS_USER/PG_OPS_PASSWORD`（造数据、做对照）与 `PGUSER/PGPASSWORD`（被验证的那个身份）。
 * **跑完会把自己造的数据删掉**（id 前缀 `rlsprobe`）。
 */
import pg from 'pg';

import { cloudHost, loadEnv, valueOf } from './lib/env-file.mjs';

// 选 homework 的理由：它的最小插入只需要 id 与归属列（其余列都有默认值或可空），
// 所以探针不会因为「忘了给某个 NOT NULL 列」而失败 —— 那会让探针的红变成假红。
const TABLE = 'homework';
const OWNER_COL = 'student_id';
const ID_PREFIX = 'rlsprobe';

const A = 'stu_rlsprobe_a';
const B = 'stu_rlsprobe_b';

const args = process.argv.slice(2);
const { env, fromFile } = loadEnv(valueOf(args, '--env-file'));

const base = {
  // ⚠️ `cloudHost()`：本脚本在 VPC 外跑 → 走**外网端点**。见 `lib/env-file.mjs`。
  host: cloudHost(env),
  port: Number(env.PGPORT ?? 5432),
  database: env.PGDATABASE ?? 'easy_learn',
};

const opsUser = (env.PG_OPS_USER ?? '') || env.PGUSER;
const opsPass = (env.PG_OPS_USER ?? '') ? env.PG_OPS_PASSWORD : env.PGPASSWORD;
const appUser = env.PGUSER;
const appPass = env.PGPASSWORD;

if (!appUser || !appPass) {
  console.error('缺 PGUSER / PGPASSWORD —— 没有"应用角色"这个身份就没有可对照的另一侧，测不了。');
  process.exit(2);
}

console.log('═══════════════════════════════════════════════════════════════');
console.log('  行级隔离 · 行为判据');
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
  console.error('先跑 `node scripts/probe-db-access.mjs --env-file <同一个文件>` 看是哪一层的问题。');
  process.exit(1);
}

const ids = [`${ID_PREFIX}_a1`, `${ID_PREFIX}_b1`, `${ID_PREFIX}_empty1`];

// 清理可能在的旧数据（脚本被中断过），再插入。
await admin.query(`delete from ${TABLE} where id like $1`, [`${ID_PREFIX}%`]);
await admin.query(
  `insert into ${TABLE} (id, ${OWNER_COL}) values ($1,$2), ($3,$4), ($5,'')`,
  [ids[0], A, ids[1], B, ids[2]],
);

// ── 先说清 PG 的解析语义（判据本身依赖它，所以要打出来）────────
const sem = (
  await admin.query(
    `select string_to_array('', ',') as empty_arr,
            string_to_array(',,', ',') as commas_arr,
            ('x' = any(string_to_array('', ','))) as x_matches_empty,
            ('' = any(string_to_array(',,', ','))) as empty_matches_commas`,
  )
).rows[0];
console.log('【PG 的解析语义 · 判据依赖它】');
console.log(`  string_to_array('', ',')   = ${JSON.stringify(sem.empty_arr)}（空数组 → 匹配 0 行）`);
console.log(`  string_to_array(',,', ',') = ${JSON.stringify(sem.commas_arr)}（**含空串元素**）`);
console.log(`  '' = ANY(',,' 解析结果)      = ${sem.empty_matches_commas}  ← 为 true 就意味着空归属的行会露出来`);
console.log('');

const cases = [
  { name: '不设可见集合（fail-closed 的基本情形）', set: null, expect: 0 },
  { name: "设成空串 ''（应用第一步实际做的事）", set: '', expect: 0 },
  { name: `设成 ${A}`, set: A, expect: 1 },
  { name: `设成 ${B}`, set: B, expect: 1 },
  { name: '设成不存在的学生', set: 'stu_rlsprobe_nobody', expect: 0 },
  { name: `设成 ${A},${B}（家长看多个孩子）`, set: `${A},${B}`, expect: 2 },
  { name: "设成 ',,'（**只在列表含空元素时**才危险）", set: ',,', expect: 0 },
];

let failed = 0;
console.log(`【app 身份（${appUser}）在 ${TABLE} 上能看到几行】`);
for (const c of cases) {
  await app.query('begin');
  if (c.set !== null) {
    await app.query('select set_config($1, $2, true)', ['app.visible_students', c.set]);
  }
  const r = await app.query(`select id, ${OWNER_COL} from ${TABLE} where id like $1 order by id`, [
    `${ID_PREFIX}%`,
  ]);
  await app.query('commit');

  const ok = r.rowCount === c.expect;
  if (!ok) failed += 1;
  const seen = r.rows.map((x) => `${x.id}(${OWNER_COL}=${JSON.stringify(x[OWNER_COL])})`).join(', ');
  console.log(`  ${ok ? '✓' : '✗'} ${c.name}`);
  console.log(`      期望 ${c.expect} 行 · 实际 ${r.rowCount} 行${seen ? ' → ' + seen : ''}`);
}

// ── 反向对照 ──────────────────────────────────────────────────
const all = await admin.query(
  `select count(*)::int as n from ${TABLE} where id like $1`,
  [`${ID_PREFIX}%`],
);
const total = all.rows[0].n;
console.log('\n【反向对照 · 判据的区分力】');
console.log(`  管理员（不受策略约束）看到 ${total} 行 —— 探针数据确实有 3 行。`);
if (total !== 3) {
  console.log('  ✗ 不是 3 行 → 上面每一个「0 行」都不能算证据（可能只是没数据）');
  failed += 1;
} else {
  console.log('  ✓ 所以上面那些 0 行是**被策略拦下来的**，不是「表里没数据」');
}

// ── 写路径 ────────────────────────────────────────────────────
console.log('\n【写路径 · 读被管住 ≠ 写被管住】');
await app.query('begin');
await app.query('select set_config($1, $2, true)', ['app.visible_students', A]);
try {
  await app.query(`insert into ${TABLE} (id, ${OWNER_COL}) values ($1, $2)`, [
    `${ID_PREFIX}_illegal`,
    B,
  ]);
  console.log(`  ✗ 竟然插进了属于 ${B} 的行 —— 写路径没有拦住越权归属`);
  failed += 1;
  await app.query('rollback');
} catch (e) {
  console.log(`  ✓ 被拒：${e.code ?? ''} ${e.message}`);
  await app.query('rollback');
}

// ── 清理 ──────────────────────────────────────────────────────
// ⚠️ `= any($1)` 收的是**一个数组**，所以参数要再包一层：`[...ids, 'x']` 会变成
//    「N 个参数喂 1 个占位符」，驱动报 `bind message supplies N parameters`
//    —— 看着像 SQL 写错，其实是调用方把数组拆开了。
await admin.query(`delete from ${TABLE} where id like $1`, [`${ID_PREFIX}%`]);
const left = await admin.query(
  `select count(*)::int as n from ${TABLE} where id like $1`,
  [`${ID_PREFIX}%`],
);
console.log(`\n清理：残留探针行 ${left.rows[0].n} 行`);

await admin.end();
await app.end();

console.log('');
if (failed === 0) {
  console.log('✓ 全部判据通过 —— 隔离在两个身份之间**行为上**确实生效。');
  process.exit(0);
}
console.log(`✗ ${failed} 条判据没过 —— 上面带 ✗ 的每一条都要当问题处理，不要只看总数。`);
process.exit(1);
