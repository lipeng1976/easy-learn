#!/usr/bin/env node
/**
 * 把 `sql/` 里的迁移应用到**环境变量指向的那个库** —— 本机或云端走同一条命令。
 *
 * ## 为什么需要它
 *
 * 在这之前，`runMigrations` 只被**本机路径**调用过（`scripts/dev-stack.mjs`
 * 与 `src/pg-local.js`，两者都自己起一个 embedded-postgres）。
 * 也就是说：**没有任何办法把表结构建到云数据库上** —— 而这是上线第一步。
 *
 * ## 它做什么 / 不做什么
 *
 * 做：连库 → 按文件名顺序执行 `sql/*.sql` → 用 `schema_migrations` 记账 → 报告。
 * 不做：不建库本身、不改业务数据、**不动任何已应用的迁移**（已应用的一律跳过）。
 * 所以它是**幂等**的：重复跑只输出「没有待应用的迁移」。
 *
 * ## 用法
 *
 *   # 先看会执行什么（连库只读，不写）
 *   node scripts/migrate.mjs --env-file .env.prod --dry-run
 *
 *   # 真执行（生产环境必须显式 --yes）
 *   node scripts/migrate.mjs --env-file .env.prod --yes
 *
 *   # 本机：直接用当前 shell 的环境变量
 *   PGHOST=127.0.0.1 PGPORT=55433 PGDATABASE=easy_learn PGUSER=postgres \
 *     PGPASSWORD=postgres node scripts/migrate.mjs
 *
 * ## 云上要配 `PG_OPS_USER`，不要用 `PGUSER`
 *
 * `.env.prod` 是**一份文件喂三个命令**（migrate / check-config / `s deploy`），
 * 而这里要管理员、函数上必须是 `app_rls`。同名一个变量、两个值，做不到。
 * 所以运维连接单独命名：
 *
 *   PG_OPS_USER=<管理员账号>        ← 只在你跑迁移时被读到
 *   PG_OPS_PASSWORD=<管理员口令>
 *   PGUSER=app_rls                  ← 上函数的那份
 *
 * 顺带的好处：`s.yaml` 只引用函数需要的变量，**管理员凭证不上云**。
 *
 * ## 两个必须知道的点
 *
 * 1. **要管理员身份**。`002_rls.sql` / `003_session.sql` 会创建
 *    `app_rls`（普通角色）与 `app_auth`（`BYPASSRLS`），后者只有超级用户
 *    才授得出来。所以这条命令用的连接**刻意是管理连接**，不是应用角色。
 * 2. **迁移建出来的角色口令是开发口令**（写在 sql 文件里，为的是本机可复现）。
 *    生产必须在迁移之后改掉 —— 命令末尾会把这句 SQL 打出来，别跳过。
 */
import pg from 'pg';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { cloudHost, loadEnv, valueOf } from './lib/env-file.mjs';
import { appliedMigrations, resolveMigrationTarget, runMigrations } from '../src/migrate.js';
import { sslOption } from '../src/db.js';
import { sqlDir } from '../src/pg-local.js';
import { isProduction } from '../../shared/env.js';

/**
 * 连接身份的说明文字 —— **必须打出来**。
 *
 * 「以为用的是管理员、其实用了应用角色」的症状是迁移跑到一半失败，
 * 而失败信息是 `permission denied to create role`：它看着像「权限不够」，
 * 不像「身份用错了」，于是人会去查账号权限，查半天。
 */
const IDENTITY_NOTE = {
  ops: 'PG_OPS_USER（运维连接 · 管理员）',
  app: 'PGUSER（**应用连接** · 不是管理员）',
  default: '默认 postgres（PG_OPS_USER 与 PGUSER 都没配）',
};

const here = path.dirname(fileURLToPath(import.meta.url));
const serviceRoot = path.resolve(here, '..');

const args = process.argv.slice(2);
const envFile = valueOf(args, '--env-file');
const dryRun = args.includes('--dry-run');
const confirmed = args.includes('--yes');

const { env, count, fromFile } = loadEnv(envFile);

// ⚠️ 迁移**只能从 VPC 外跑**（没有别的入口），所以这里把 host 换成**外网端点**：
//    配好 VPC 之后 `PGHOST` 是内网地址，从本机**能解析、但连不上**（实测 TCP 超时 6s），
//    而现象看起来像「白名单没放行」或「库挂了」—— 方向完全错。
//    规则与理由见 `lib/env-file.mjs` 的 `cloudHost()`，别在这里另写一套判断。
env.PGHOST = cloudHost(env);

const production = isProduction(env);

const target = resolveMigrationTarget(env);

console.log('迁移目标');
console.log(`  ${target.user}@${target.host}:${target.port}/${target.database}`);
console.log(`  身份：${IDENTITY_NOTE[target.identity]}`);
console.log(`  环境：${production ? '生产（NODE_ENV=production）' : '非生产'}`);
console.log(`  迁移目录：${sqlDir}`);
if (fromFile) console.log(`  环境变量文件：${envFile}（${count} 个键）`);
console.log('  （口令不会打印，连日志里也不会）\n');

// 生产上回落到 `PGUSER` 几乎总是错的，而且报错不指向真因：
// 应用角色建不出 `app_auth`（`BYPASSRLS` 只有超级用户授得出来），
// 失败信息是「permission denied to create role」—— 看着像「库没连对」。
if (production && target.identity !== 'ops') {
  console.error(
    `⚠️  生产环境却在用 PGUSER 连库迁移（${target.user}）。\n`
      + '    迁移要管理员身份：它要建带 BYPASSRLS 的 app_auth 角色。\n'
      + '    请在环境变量文件里加：\n'
      + '      PG_OPS_USER=<管理员账号>\n'
      + '      PG_OPS_PASSWORD=<管理员口令>\n'
      + '    这样 PGUSER 就能腾出来专给函数上用 app_rls（拿超级用户当应用账号，RLS 会失效）。\n',
  );
}

// 生产环境要求**显式确认**。
//
// 理由不是「迁移危险」——它幂等、只加不改。理由是：这条命令会把
// **角色与权限**一并建出来，而生产上「跑错库」的代价不是你一个人能承担的。
// 一次手滑把开发库的口令写进生产，或反过来，都不该靠运气避免。
if (production && !confirmed && !dryRun) {
  console.error(
    '拒绝执行：这是生产环境，需要显式确认。\n'
      + '  先看会做什么：node scripts/migrate.mjs --env-file <文件> --dry-run\n'
      + '  确认后执行：  node scripts/migrate.mjs --env-file <文件> --yes\n',
  );
  process.exit(2);
}

// `identity` 只是给人看的标签，不往驱动里传。
const { identity: _identity, ...conn } = target;

// SSL 与函数上**同一套规则**（`src/db.js` 的 `sslOption`）。
//
// 为什么迁移也要跟着：`PGSSLMODE` 只有一处定义，而 `.env.prod` 是**一份文件喂三个命令**。
// 如果只让函数读它，就会出现「同一份配置里写着要加密、迁移却走明文」的分裂 ——
// 将来云厂商把实例设成「仅接受 TLS」之后，症状是迁移连不上而函数正常
// （或反过来），排查方向会被带偏。
// 默认（未设 / `disable`）不传 ssl，与本机既有行为完全一致。
const ssl = sslOption(env.PGSSLMODE);
const client = new pg.Client({ ...conn, ...(ssl ? { ssl } : {}) });

/**
 * 连接层错误必须有人听。
 *
 * `pg.Client` 的 `error` 事件**没有人监听时会被当成未捕获异常** ——
 * 进程直接崩在一段 Node 内部堆栈里（`node:events:497 throw er`），
 * 而那段堆栈里**没有一个字**告诉你刚才在跑哪个迁移、走到第几步。
 * 实测就撞上过一次：一次 `Connection terminated unexpectedly` 让整个命令
 * 以一段驱动内部堆栈结束，排查只能靠猜。
 *
 * 这里把它变成一条带**阶段**的错误 —— 迁移脚本最需要的正是这个上下文。
 */
let phase = '连接';
client.on('error', (e) => {
  console.error(
    `\n✗ 数据库连接中断（当时的阶段：${phase}）。\n`
      + `  驱动报的是：${e.message}\n`
      + '  这一条来自**连接层**，不是某句 SQL 的语法或权限问题 —— 常见原因是网络抖动、\n'
      + '  或服务端把连接回收了。**重跑本命令是安全的**（幂等：已应用的会跳过）。\n'
      + '  若每次都断在同一个迁移，那才是代码问题，把上面那个阶段名报出来。\n',
  );
  process.exitCode = 1;
});

try {
  await client.connect();
} catch (e) {
  console.error(`连不上数据库：${e.message}`);
  console.error('检查 PGHOST / PGPORT / PGDATABASE / PGUSER / PGPASSWORD，以及白名单是否放行了你的出口 IP。');
  process.exit(1);
}

try {
  if (dryRun) {
    // 只读：把「已应用的」与「目录里的」比一比。
    // `schema_migrations` 可能还不存在（全新库），那是正常情况，不是错误。
    let applied = [];
    try {
      applied = (await appliedMigrations(client)).map((r) => r.name);
    } catch {
      console.log('（这个库里还没有 schema_migrations —— 看起来是全新库）\n');
    }
    const fs = await import('node:fs');
    const all = fs.readdirSync(sqlDir).filter((f) => f.endsWith('.sql')).sort();
    const pending = all.filter((f) => !applied.includes(f));
    console.log(`已应用 ${applied.length} 个，待应用 ${pending.length} 个：`);
    for (const f of pending) console.log(`  + ${f}`);
    if (pending.length === 0) console.log('  （没有待应用的迁移）');
    process.exit(0);
  }

  const applied = await runMigrations(client, sqlDir);
  if (applied.length === 0) {
    console.log('✓ 没有待应用的迁移（库已是最新）。');
  } else {
    console.log(`✓ 应用了 ${applied.length} 个迁移：`);
    for (const name of applied) console.log(`  + ${name}`);
  }

  const rows = await appliedMigrations(client);
  console.log(`\n库里共记录 ${rows.length} 个迁移。`);

  console.log(`
⚠️  接下来必须做的两件事（迁移脚本不会替你做）：

  1) **改掉两个角色的口令。** sql 文件里写的是开发口令（为的是本机可复现），
     而生产库上它们就是公开的：

       ALTER ROLE app_rls  WITH PASSWORD '<强口令，与 PG_PASSWORD 一致>';
       ALTER ROLE app_auth WITH PASSWORD '<另一个强口令，与 PG_AUTH_PASSWORD 一致>';

     数据服务用这两个角色连库（app_rls 走 RLS，app_auth 只碰三张账号表）。
     改完记得同步平台的「环境变量」，两处不一致的症状是「连接被拒」。

  2) **确认 RLS 真的在生效。** 用**非超级用户**的 app_rls 连一次库查一张表：
     超级用户会**静默绕过** RLS（连 FORCE ROW LEVEL SECURITY 都拦不住），
     所以「用主账号连库」等于整套隔离失效。数据服务的启动自检会查这一条，
     这里提前确认能省一轮来回。
`);
} catch (e) {
  console.error(`\n✗ ${e.message}`);
  process.exit(1);
} finally {
  await client.end().catch(() => {});
}
