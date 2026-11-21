#!/usr/bin/env node
/**
 * 拿到一台**新数据库**时的第一件事：把「能不能连、我是谁、权限够不够、现在是什么状态」
 * 一次问清。全只读（权限检查用**事务内干跑 + 回滚**），不改这台库。
 *
 * ## 为什么需要它，而不是"直接跑迁移试试"
 *
 * 「跑迁移试试」把三类完全不同的失败混成一句话：
 *   · 网络/白名单不通 → 连不上
 *   · 凭证不对 → 认证失败
 *   · **身份用错了**（应用角色 vs 管理员）→ `permission denied`，
 *     而它看着像「权限没配」或「库没连对」，会带人查错方向（实测踩过）
 *   · 版本/托管服务的差异 → 某个特权语句不被允许
 * 一次问清，这四类当场分开。
 *
 * ## 它回答的问题
 *
 * 1. **连得上吗**（并且**SSL 到底支不支持** —— 决定 `PGSSLMODE` 只能填什么）
 * 2. **我是谁**：`rolsuper` / `rolbypassrls` / 继承了什么角色
 *    → 决定这个账号**能不能上函数**（带 `rolbypassrls` 的会让 RLS **静默失效**）
 * 3. **权限够不够**：把迁移里真正会执行的特权语句**干跑一遍**
 * 4. **库现在什么状态**：表数 / 迁移数 / 启用 RLS 的表数 / 策略数
 * 5. **配置该怎么填**：`max_connections` → 实例上限；库名、owner
 *
 * ## 用法
 *
 *   node scripts/probe-db-access.mjs --env-file ../../.env.prod
 *   PGHOST=... PGUSER=... PGPASSWORD=... node scripts/probe-db-access.mjs
 *
 * 有 `PG_OPS_USER` 就用它（管理员），否则用 `PGUSER`。**它会明确打出用的是哪个** ——
 * 「以为在用管理员、其实用了应用角色」正是要防的那件事。
 */
import { readdirSync } from 'node:fs';

import pg from 'pg';

import { cloudHost, loadEnv, valueOf } from './lib/env-file.mjs';

const args = process.argv.slice(2);
const { env, count, fromFile } = loadEnv(valueOf(args, '--env-file'));

const usingOps = (env.PG_OPS_USER ?? '') !== '';
const user = usingOps ? env.PG_OPS_USER : (env.PGUSER ?? 'postgres');
const password = usingOps ? env.PG_OPS_PASSWORD : env.PGPASSWORD;

const base = {
  // ⚠️ `cloudHost()`：本脚本在 VPC 外跑 → 走**外网端点**。见 `lib/env-file.mjs`。
  host: cloudHost(env),
  port: Number(env.PGPORT ?? 5432),
  database: env.PGDATABASE ?? 'easy_learn',
};

console.log('═══════════════════════════════════════════════════════════════');
console.log('  数据库体检（只读；权限检查在事务内干跑并回滚）');
console.log('═══════════════════════════════════════════════════════════════\n');
console.log(`  目标：${user}@${base.host}:${base.port}/${base.database}`);
console.log(`  身份来源：${usingOps
  ? 'PG_OPS_USER（运维 / 管理员）'
  : (env.PGUSER ? 'PGUSER（**应用角色** —— 建角色/建表多半不够权限）' : '默认 postgres（两个变量都没配）')}`);
if (fromFile) console.log(`  环境变量文件：${valueOf(args, '--env-file')}（${count} 个键）`);
console.log('  （口令不会打印）\n');

// ── 1. 连接：并且把「SSL 到底支不支持」问出来 ───────────────────
// 这条必须单独判：云 PG 常见两种形态，而配置写错的后果是「函数连不上库」。
//   · 只接受 TLS：不传 ssl → 报 pg_hba 的 `no encryption`，**看着像白名单没放行**
//   · 不支持 TLS：传了 ssl → 服务端回 'N'，驱动报 `does not support SSL connections`
async function connect(useSsl) {
  const c = new pg.Client({
    ...base, user, password,
    ...(useSsl ? { ssl: { rejectUnauthorized: false } } : {}),
    connectionTimeoutMillis: 15000,
  });
  await c.connect();
  return c;
}

let client;
let sslState;
try {
  client = await connect(true);
  sslState = 'ok';
} catch (e) {
  const first = e.message;
  try {
    client = await connect(false);
    sslState = /does not support SSL/i.test(first) ? 'unsupported' : 'rejected-then-plain';
  } catch (e2) {
    console.log(`✗ 连不上。\n    带 SSL：${first}\n    不带 SSL：${e2.code ?? ''} ${e2.message}\n`);
    console.log('  对照表：');
    console.log('    ETIMEDOUT / ECONNREFUSED / ENOTFOUND → 网络层：白名单没放行，或地址/端口不对');
    console.log('    28P01 password authentication failed  → 凭证层：账号或口令不对');
    console.log('    28000 / "no pg_hba.conf entry"        → 白名单，或该账号只能走加密连接');
    console.log('    3D000 database does not exist         → 库名不对');
    process.exit(2);
  }
}

console.log('【1 连接】');
if (sslState === 'ok') {
  console.log('  ✓ 连上了（SSL 可用）→ 配置里可以填 `PGSSLMODE=require`');
} else if (sslState === 'unsupported') {
  console.log('  ⚠️ **这台库不接受 SSL 连接**（服务端回 N）。');
  console.log('     → 配置里 `PGSSLMODE` **只能填 `disable`**，填 `require` 会让函数连不上库。');
  console.log('       想加密：控制台开 SSL（通常免费），再把值改成 require，**然后重跑一次迁移验证**。');
  console.log('     → 现在这条链路上的口令与全部业务数据是**明文**的。');
} else {
  console.log('  ⚠️ 带 SSL 没连上、不带 SSL 连上了 —— 确认一下服务端的报错到底是什么再定。');
}
console.log('');

const q = async (label, sql, params) => {
  try {
    const r = await client.query(sql, params);
    console.log(`【${label}】`);
    for (const row of r.rows) console.log('   ' + JSON.stringify(row));
    if (r.rows.length === 0) console.log('   （无行）');
    console.log('');
    return r.rows;
  } catch (e) {
    console.log(`【${label}】失败：${e.code ?? ''} ${e.message}\n`);
    return null;
  }
};

// ── 2. 身份 ────────────────────────────────────────────────────
const me = (
  await q('2 我是谁（决定这个账号能不能上函数）', `
    select current_user as current_user,
           current_setting('is_superuser') as is_superuser,
           r.rolsuper, r.rolcreaterole, r.rolcreatedb,
           r.rolreplication, r.rolbypassrls, r.rolcanlogin,
           r.rolconnlimit
      from pg_roles r where r.rolname = current_user
  `)
)?.[0];

// 继承的角色：托管库的「高权限账号」通常是普通账号 + 被授予一个近似超管的角色
const granted = await q('它继承了什么角色（高权限账号的形态就藏在这里）', `
  select r.rolname as granted_role, r.rolsuper, r.rolcreaterole, r.rolbypassrls
    from pg_auth_members m
    join pg_roles r on r.oid = m.roleid
   where m.member = (select oid from pg_roles where rolname = current_user)
   order by r.rolname
`);

// ⚠️ 上面这段会打出 `app_auth ... rolbypassrls: true`。**那是刻意设计，不是缺陷** ——
// 不注明的话，下一个人看到就会"顺手修"，而修掉它登录直接坏。
// 反向也一样要说清：`app_rls` 带 BYPASSRLS 才是真缺陷。
if ((granted ?? []).some((r) => String(r.granted_role).startsWith('app_'))) {
  const hasAuth = granted.some((r) => r.granted_role === 'app_auth' && r.rolbypassrls === true);
  const rlsBypass = granted.find((r) => r.granted_role === 'app_rls' && r.rolbypassrls === true);
  console.log('  ℹ️ 怎么看上面这几行：');
  if (hasAuth) {
    console.log('     · `app_auth` 带 BYPASSRLS 是**刻意设计**：登录时必须读 `app_user`，而那张表的');
    console.log('       策略依赖 `current_setting(\'app.user_id\')` —— 还没有身份时一行都读不到。');
    console.log('       它被**表级白名单**框住（只有 app_user / user_session / app_user_credential），');
    console.log('       且启动时 `assertAuthRoleScoped()` 会逐表确认 —— 见 sql/003_session.sql。');
  }
  if (rlsBypass) {
    console.log('     🚨 `app_rls` 带了 BYPASSRLS —— **这才是真缺陷**（整套多家庭隔离静默失效）。');
    console.log('        跑 `node scripts/provision-app-roles.mjs` 收回。');
  }
  console.log('');
}

await q('全库谁是真超管（对照用）', `
  select rolname, rolcanlogin from pg_roles where rolsuper order by rolname
`);

if (me && (me.rolsuper === true || me.rolbypassrls === true)) {
  console.log('  🚨 **这个账号不能配到应用上**：它的 `rolsuper` 或 `rolbypassrls` 为 true ——');
  console.log('     带这两个属性之一的角色会让行级隔离**静默失效**（不报错、照常返回全部行）。');
  console.log('     应用要连的是迁移建出来的普通角色。\n');
}

// ── 3. 库与权限 ────────────────────────────────────────────────
await q('3 库与 schema 的归属', `
  select current_database() as db,
         pg_get_userbyid(d.datdba) as db_owner
    from pg_database d where d.datname = current_database()
`);
await q('public schema 的 ACL（应用角色应当只有 U，没有 C）', `
  select pg_get_userbyid(nspowner) as owner, nspacl::text as acl
    from pg_namespace where nspname = 'public'
`);

// ── 4. 规模与语义 ──────────────────────────────────────────────
const sizing = (
  await q('4 规模（用来套「实例上限 × 连接池 < max_connections」）', `
    select current_setting('max_connections')::int as max_connections,
           (select count(*)::int from pg_stat_activity) as current_connections,
           current_setting('server_version') as pg_version,
           current_setting('TimeZone') as tz,
           now() as now,
           current_setting('password_encryption') as password_encryption
  `)
)?.[0];

// ── 5. 权限干跑（事务内，全部回滚）─────────────────────────────
console.log('【5 权限干跑】每个都在事务里执行后立刻回滚 —— 不留痕迹');
console.log('   目的是把「迁移跑到一半才失败」提前成「现在就知道」\n');

const dry = async (label, stmts) => {
  try {
    await client.query('begin');
    for (const s of stmts) await client.query(s);
    await client.query('rollback');
    console.log(`  ✓ ${label}`);
  } catch (e) {
    await client.query('rollback').catch(() => {});
    console.log(`  ✗ ${label}\n      ${e.code ?? ''} ${e.message}`);
  }
};

const stamp = Date.now().toString(36).slice(-6);
await dry('CREATE ROLE ... LOGIN PASSWORD（迁移建应用角色要用）', [
  `create role __probe_r_${stamp} login password 'x'`,
]);
await dry('CREATE ROLE ... BYPASSRLS（**只有超管/带该属性的角色**才做得成）', [
  `create role __probe_b_${stamp} login password 'x' bypassrls`,
]);
await dry('ALTER ROLE ... BYPASSRLS（迁移里的兜底句）', [
  `create role __probe_a_${stamp} login password 'x'`,
  `alter role __probe_a_${stamp} bypassrls`,
]);
await dry('CREATE EXTENSION pgcrypto（若迁移用到）', [
  'create extension if not exists pgcrypto',
]);

const leftover = await q('干跑之后确认没留下东西（应当都是 0）', `
  select (select count(*)::int from pg_roles where rolname like '__probe%') as leftover_roles,
         (select count(*)::int from pg_extension where extname = 'pgcrypto') as installed_ext
`);
console.log('');

// ── 6. 现状 ────────────────────────────────────────────────────
await q('6 现状：迁移 / 表 / 隔离', `
  select (select count(*)::int from information_schema.tables
           where table_schema = 'public') as tables,
         (select to_regclass('public.schema_migrations') is not null) as has_migrations_table
`);
await q('启用 RLS 的表（`relforcerowsecurity` 为 false 意味**表 owner 可以绕过**）', `
  select count(*)::int as rls_enabled,
         count(*) filter (where c.relforcerowsecurity)::int as rls_forced
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relrowsecurity
`);
await q('策略数', `select count(*)::int as policies from pg_policies where schemaname = 'public'`);

// 迁移**进度** —— 只说「有 schema_migrations 表」是不够的：一个只跑了前 5 条的库
// 也会显示 `has_migrations_table: true`，而缺的那几条代表「表/策略根本不存在」。
// 它的症状不是启动失败，而是运行期某个接口 500、或恰好少一层隔离 —— 所以必须与
// 仓库里的 sql 文件**对照**才能看出缺口。
let repoMigrations = null;
try {
  repoMigrations = readdirSync(new URL('../sql/', import.meta.url))
    .filter((f) => f.endsWith('.sql'))
    .sort();
} catch {
  repoMigrations = null; // 脚本被复制到别处跑、找不到 sql 目录 —— 不因此失败
}

let appliedMigrations = null;
try {
  appliedMigrations = (await client.query('select name from schema_migrations order by name'))
    .rows.map((r) => r.name);
} catch (e) {
  if (e.code !== '42P01') throw e; // 42P01 = undefined_table：全新库还没建迁移表，是正常状态
}

if (appliedMigrations === null) {
  console.log('【迁移】库里还没有 schema_migrations 表 → 这是一台**全新的库**。');
  console.log('  跑 `node scripts/migrate.mjs` 建表 + 建策略即可（注意：**先建角色后迁移**）。\n');
} else if (repoMigrations === null) {
  console.log(`【迁移】库里已应用 ${appliedMigrations.length} 条（读不到仓库 sql 目录，无法对照缺口）：`);
  console.log(`  ${appliedMigrations.join(' · ')}\n`);
} else {
  const missing = repoMigrations.filter((m) => !appliedMigrations.includes(m));
  const extra = appliedMigrations.filter((m) => !repoMigrations.includes(m));
  console.log(`【迁移：仓库里 ${repoMigrations.length} 个 · 库里应用 ${appliedMigrations.length} 个】`);
  if (!missing.length && !extra.length) {
    console.log('  ✓ 与仓库完全一致（不多不少）。');
  }
  if (missing.length) {
    console.log(`  ✗ 库里缺 ${missing.length} 条 —— 它们建的表/策略**现在不存在**，而这一点不会报错：`);
    for (const m of missing) console.log(`      ${m}`);
    console.log('      → 跑 `node scripts/migrate.mjs` 补齐（幂等，只跑缺的那几条）。');
  }
  if (extra.length) {
    console.log(`  ⚠️ 库里有 ${extra.length} 条仓库里没有的记录（手工改过库？或这份代码比库旧？）：`);
    for (const m of extra) console.log(`      ${m}`);
  }
}
console.log('');

// ── 结论 ───────────────────────────────────────────────────────
console.log('═══════════════════════════════════════════════════════════════');
console.log('  该往配置里填什么');
console.log('═══════════════════════════════════════════════════════════════');
console.log(`  host        = ${base.host}`);
console.log('                ⚠️ 这是**外网端点**（本机在 VPC 外，只能走它）——');
console.log('                   函数侧要填的是**内网端点**，两个名字不一样：见 .env.prod 的 PGHOST / PGHOST_EXTERNAL。');
console.log(`  PGPORT      = ${base.port}`);
console.log(`  PGDATABASE  = ${base.database}   ← 按实际库名填，别照抄代码里的默认值`);
console.log(`  PGSSLMODE   = ${sslState === 'ok' ? 'require' : 'disable'}   ← 依据上面的 SSL 结论`);
if (sizing) {
  const limit = Math.floor(sizing.max_connections / 8);
  console.log(`  PG_POOL_MAX / PG_AUTH_POOL_MAX = 5 / 3（默认）`);
  console.log(`     ⚠️ 实例上限 ≤ **${limit}**（= ${sizing.max_connections} ÷ 8）`);
  console.log(`        换算错的表现是**高峰期大面积超时**，看着像接口变慢，其实连不上库。`);
}
console.log('');

await client.end().catch(() => {});
if (leftover && (leftover[0].leftover_roles !== 0 || leftover[0].installed_ext !== 0)) {
  console.log('⚠️ 干跑留下了残留（上面的数字不是 0）—— 请手工清掉。');
  process.exit(1);
}
