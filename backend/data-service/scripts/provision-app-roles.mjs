#!/usr/bin/env node
/**
 * 把两个应用角色的口令设成环境变量文件里给的那两个，并保证它们的**属性**正确。
 *
 * ## 为什么需要它（以及为什么顺序是「先跑它、后跑 migrate」）
 *
 * `db/migrations/002_rls.sql` 与 `003_session.sql` 里那句 `CREATE ROLE ... PASSWORD`
 * 的口令由迁移器在事务内注入（本机开发栈的随机凭据），**SQL 里没有任何可用口令**；
 * 没注入、角色也不存在时 SQL 会显式报错，不会退回默认值。
 * 两处都被 `DO $$ IF NOT EXISTS (...) $$` 包着，所以**角色已存在时整句跳过**。
 *
 * 生产顺序只有一种：先本脚本、后迁移。角色带着环境变量里的强口令建出来，
 * 迁移里那句 CREATE ROLE 直接跳过，本机凭据一次都不会落到云端库上。
 *
 * 本脚本存在的意义就是把第二条路变成一条命令。
 *
 * ## 它只做口令，不重复定义角色属性
 *
 * 角色属性（`app_rls` 无 BYPASSRLS、`app_auth` 有 BYPASSRLS、都没有 CREATEDB/CREATEROLE）
 * 的**唯一定义处是那两个 sql 文件**。这里建角色时只写 `LOGIN PASSWORD` ——
 * 与 sql 里那句完全相同的子集，不多写一个属性。
 * 「顺手」在这里补一个 `CREATEDB` 之类，就会得到两个互相矛盾的属性来源。
 *
 * `ALTER ROLE app_auth BYPASSRLS` 是唯一一处例外，但它是**幂等的**，
 * 且 sql/003 自己也无条件执行同一句 —— 两边等价，不是第二份定义。
 *
 * ## 用法
 *
 *   node scripts/provision-app-roles.mjs --env-file .env.prod
 *   node scripts/provision-app-roles.mjs --env-file .env.prod --yes   # 生产需显式确认
 *
 * 读的键：`PG_OPS_USER` / `PG_OPS_PASSWORD`（管理员，只在本机用）、
 *        `PGPASSWORD`（给 app_rls）、`PG_AUTH_PASSWORD`（给 app_auth）。
 * 后两个就是函数上要配的那两个值 —— 同源，不会出现「库里改了、云端没改」。
 */
import pg from 'pg';

import { cloudHost, loadEnv, valueOf } from './lib/env-file.mjs';
import { resolveMigrationTarget } from '../src/migrate.js';
import { isProduction } from '../../shared/env.js';

/**
 * 历史公开弱口令，只作为**黑名单**用于最后一项验证：换完强口令后，
 * 用它们应该连不上。连得上说明 pg_hba 是 trust、口令认证根本没生效。
 * 它们不再被任何代码当作凭据使用；留在这里是为了继续挡住旧库/旧配置。
 */
const DEV_PASSWORDS = new Set(['app_rls_local_dev', 'app_auth_local_dev']);

/** 口令最短长度。比 24 短的随机串熵不足；人挑的口令更短。 */
const MIN_LENGTH = 24;

const args = process.argv.slice(2);
const envFile = valueOf(args, '--env-file');
const confirmed = args.includes('--yes');

const { env, count, fromFile } = loadEnv(envFile);

// ⚠️ 建角色**只能从 VPC 外跑**（没有别的入口），所以 host 换成**外网端点**：
//    配好 VPC 之后 `PGHOST` 是内网地址，从本机连不上。见 `lib/env-file.mjs` 的 `cloudHost()`。
env.PGHOST = cloudHost(env);

const production = isProduction(env);
const target = resolveMigrationTarget(env);

if (fromFile) console.log(`环境变量文件：${envFile}（${count} 个键）`);
console.log(`目标：${target.user}@${target.host}:${target.port}/${target.database}`);
console.log(`身份：${target.identity === 'ops' ? 'PG_OPS_USER（管理员）' : target.identity === 'app' ? 'PGUSER（**不是管理员**）' : '默认 postgres'}\n`);

// ── 连接身份：建角色 / 改口令都要管理人员 ─────────────────────
if (target.identity !== 'ops' && production) {
  console.error(
    '拒绝执行：生产环境必须用 PG_OPS_USER / PG_OPS_PASSWORD 连接。\n'
      + '  用应用角色改口令会得到 `permission denied`，而它看着像「角色不存在」。\n'
      + '  若角色都还没建，你更需要的正是管理员身份。\n',
  );
  process.exit(2);
}

// ── 口令校验：四条「必须拒绝」，每一条都对应一个真实的坏结果 ──
const wanted = [
  { role: 'app_rls', password: env.PGPASSWORD ?? '', key: 'PGPASSWORD' },
  { role: 'app_auth', password: env.PG_AUTH_PASSWORD ?? '', key: 'PG_AUTH_PASSWORD' },
];

const problems = [];
for (const w of wanted) {
  if (w.password === '') {
    problems.push(`${w.key} 没填 —— 无法为 ${w.role} 设口令`);
  } else if (DEV_PASSWORDS.has(w.password)) {
    problems.push(`${w.key} 填的是**源码里的开发口令**（写死在 sql/*.sql 里，等于公开）`);
  } else if (w.password.length < MIN_LENGTH) {
    problems.push(`${w.key} 只有 ${w.password.length} 个字符，至少要 ${MIN_LENGTH}`);
  }
}
if (wanted[0].password !== '' && wanted[0].password === wanted[1].password) {
  problems.push('PGPASSWORD 与 PG_AUTH_PASSWORD 是同一个值 —— 两个角色能力不同（app_auth 带 BYPASSRLS），口令必须分开');
}
if (env.PG_OPS_PASSWORD && wanted.some((w) => w.password === env.PG_OPS_PASSWORD)) {
  problems.push('应用角色的口令与管理员口令相同 —— 泄漏一处就等于泄漏全部');
}

if (problems.length > 0) {
  console.error('拒绝执行，配置有问题：');
  for (const p of problems) console.error(`  ✗ ${p}`);
  console.error('\n  生成两个强口令：');
  console.error('    node -e "const c=require(\'crypto\');console.log(c.randomBytes(24).toString(\'base64url\'))"');
  console.error('  然后分别填进 .env.prod 的 PGPASSWORD 与 PG_AUTH_PASSWORD。\n');
  process.exit(2);
}

if (production && !confirmed) {
  console.error(
    '拒绝执行：这是生产环境，需要显式确认。\n'
      + '  确认后执行：node scripts/provision-app-roles.mjs --env-file <文件> --yes\n'
      + '  （它会改两个角色的口令 —— 改完必须同步平台上的环境变量，否则函数连不上）\n',
  );
  process.exit(2);
}

// ── 干活 ────────────────────────────────────────────────────
const { identity: _identity, ...conn } = target;

/** 字面量转义。ALTER ROLE ... PASSWORD 不接受参数绑定，只能拼串。 */
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`;

const client = new pg.Client(conn);
try {
  await client.connect();
} catch (e) {
  console.error(`连不上数据库：${e.message}`);
  process.exit(1);
}

const created = [];
const altered = [];

try {
  for (const { role, password } of wanted) {
    const before = await client.query('select 1 from pg_roles where rolname = $1', [role]);
    if (before.rowCount === 0) {
      // 只写 LOGIN PASSWORD —— 与 sql 文件里那句相同的子集，属性留给迁移定义。
      await client.query(`CREATE ROLE ${role} LOGIN PASSWORD ${lit(password)}`);
      created.push(role);
    } else {
      await client.query(`ALTER ROLE ${role} WITH PASSWORD ${lit(password)}`);
      altered.push(role);
    }
  }

  // app_auth 的 BYPASSRLS 是结构必需品（登录时要读 app_user，而那张表的 policy
  // 依赖 current_setting('app.user_id') —— 没有身份时一行都读不到）。
  // 与 sql/003 里那句无条件 ALTER 等价，幂等。
  await client.query('ALTER ROLE app_auth BYPASSRLS');

  // 反向：app_rls **必须没有** BYPASSRLS。若有人手工给过，这里纠正并报出来 ——
  // 带 BYPASSRLS 的 app_rls 会让整套多家庭隔离**静默失效**。
  const ar = await client.query(
    "select rolsuper, rolbypassrls, rolcreatedb, rolcreaterole from pg_roles where rolname = 'app_rls'",
  );
  const a = ar.rows[0];
  if (a.rolsuper || a.rolbypassrls) {
    console.log('⚠️  app_rls 带 BYPASSRLS 或超级用户属性 —— 正在纠正（它必须被 RLS 管住）');
    await client.query('ALTER ROLE app_rls NOBYPASSRLS NOSUPERUSER');
  }
  if (a.rolcreatedb || a.rolcreaterole) {
    console.log('⚠️  app_rls 有 CREATEDB / CREATEROLE —— 正在收回（应用角色不需要）');
    await client.query('ALTER ROLE app_rls NOCREATEDB NOCREATEROLE');
  }

  console.log(`✓ 新建：${created.length ? created.join(', ') : '（无，角色已存在）'}`);
  console.log(`✓ 改口令：${altered.length ? altered.join(', ') : '（无）'}`);
  console.log('  （口令不打印，连日志里也不会）\n');
} catch (e) {
  console.error(`✗ ${e.message}`);
  await client.end().catch(() => {});
  process.exit(1);
}

// ── 属性的最终状态（人工核对用）──────────────────────────────
const roles = await client.query(`
  select rolname, rolsuper, rolbypassrls, rolcreatedb, rolcreaterole, rolcanlogin
    from pg_roles where rolname in ('app_rls','app_auth') order by rolname
`);
console.log('最终属性：');
for (const r of roles.rows) console.log('  ' + JSON.stringify(r));
console.log('  期望：app_rls {rolsuper:false, rolbypassrls:false} · app_auth {rolbypassrls:true}\n');

await client.end();

// ── 正反两侧验证 ────────────────────────────────────────────
// 正面：新口令能连上。反面：开发口令连不上（顺便证明口令认证真的在生效 ——
// 若 pg_hba 是 trust，开发口令也会「连上」，那时这条反面判据会红，
// 而它红得正是地方：任何口令都能连库本身就是一个必须知道的事实）。
async function tryLogin(role, password) {
  const c = new pg.Client({ ...conn, user: role, password });
  try {
    await c.connect();
    await c.end();
    return 'ok';
  } catch (e) {
    return e.code ?? e.message;
  }
}

console.log('验证：');
let failed = 0;
for (const { role, password } of wanted) {
  const r = await tryLogin(role, password);
  if (r === 'ok') console.log(`  ✓ ${role} 用新口令能连上`);
  else { console.log(`  ✗ ${role} 用新口令连不上：${r}`); failed++; }
}
for (const { role } of wanted) {
  const dev = role === 'app_rls' ? 'app_rls_local_dev' : 'app_auth_local_dev';
  const r = await tryLogin(role, dev);
  if (r === 'ok') {
    console.log(`  ✗ ${role} 用**开发口令**也连得上 —— 口令认证没生效（pg_hba 是否 trust？）`);
    failed++;
  } else {
    console.log(`  ✓ ${role} 用开发口令连不上（${r}）`);
  }
}

if (failed > 0) {
  console.error('\n有 1 项以上没通过 —— 上面的每条失败都说明了原因，别跳过。');
  process.exit(1);
}
console.log('\n✓ 两个应用角色已就绪。接下来跑迁移：');
console.log('    node scripts/migrate.mjs --env-file <同一个文件> --yes\n');
