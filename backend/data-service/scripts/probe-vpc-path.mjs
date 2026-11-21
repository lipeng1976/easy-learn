#!/usr/bin/env node
/**
 * 验「云函数连数据库**到底走内网还是公网**」。
 *
 * ── 为什么需要它 ────────────────────────────────────────────────────────────
 *
 * 给函数配 `vpcConfig` 的全部意义就是：让它的库连接**从 VPC 内网出去**，
 * 这样 RDS 白名单只需要放行**交换机网段 CIDR**（一个固定值），
 * 而不是去追 FC 那个**动态**的公网出口 IP。
 *
 * ⚠️ 但这件事**在函数侧看不出来**：`/auth/login` 返回 200（真的查到库了）时，
 *    你无法区分它是「走内网查到的」还是「走公网查到的」——
 *    两种返回**一模一样**。所以判据只能在**库侧**看。
 *
 * 怎么判：`pg_stat_activity.client_addr` 是**每个连接的对端 IP**。
 *   · 私有地址（10./192.168./172.16-31.）= 走 VPC 内网 ✓ 配对了
 *   · 只有公网地址                          = VPC **白配了**，看着却完全正常
 * 本机（开发机）的出口是**公网**地址，所以要看到**两条来源**：
 * 一条私有（函数）、一条公网（你自己跑这个脚本）。
 *
 * 决定性的一行是 `PG_AUTH_USER`（`app_auth`）那条：它是**登录专用身份**，
 * 只有数据服务在注册/登录时会用它 —— 看到它的来源 IP 就等于直接看到
 * 「函数连库走的是内网还是公网」，不用去改生产代码。
 *
 * ── ⚠️⚠️ 必须用管理员身份连本脚本（曾经在这里栽过）──────────────────────────
 *
 * 2026-09-24 实测：**同一个集群，两种身份看到的行数差 21 倍**。
 *
 *   · 以 `app_rls`（普通角色，`rolsuper=false` `rolbypassrls=false`）看
 *     → **只看得到自己那 1 条会话**（`select count(*)` = 1）；
 *   · 以 `PG_OPS_USER`（`easylearn_admin`，`rolbypassrls=true`）看 → **22 条**。
 *
 * 也就是说：脚本以前用 `app_rls` 连，`app_auth` 明明在库里开着连接，
 * 输出却是「⚠️ 没看到 app_auth 的连接」—— **假阴性**。
 * 它给出的建议（「先打一次 /auth/login 再跑」）于是永远无效，
 * 而现象是「函数似乎从不连库」，正好指向错误的方向（去查 VPC 配错）。
 *
 * ⚠️ 这条陷阱的形态值得记住：**判据本身被权限悄悄剪掉了尾巴**，
 *    不报错、不警告，只是**少了几行** —— 而「少几行」最容易被读成
 *    「那些行不存在」。凡是「看不到某物」的判据，都要先确认
 *    **自己有没有资格看到它**。
 *
 * 所以本脚本改用 `PG_OPS_USER`（只读查询，不写任何东西），
 * 并在输出里显式打印「当前身份能否看到别人的会话」。
 *
 * 用法：
 *   node serverless/data-service/scripts/probe-vpc-path.mjs
 *   ENV_FILE=.env.local node serverless/data-service/scripts/probe-vpc-path.mjs
 */
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { Client } from 'pg';

import { cloudHost, loadEnv } from './lib/env-file.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../../..');

const envFile = process.env.ENV_FILE || '.env.prod';
const { env } = loadEnv(resolve(ROOT, envFile));

/** 私有网段：阿里云 VPC 一般是 172.16.0.0/12。 */
function isPrivate(ip) {
  return /^10\./.test(ip) || /^192\.168\./.test(ip) || /^172\.(1[6-9]|2\d|3[01])\./.test(ip);
}

const client = new Client({
  // ⚠️ 本脚本是**在 VPC 外**跑的（要读 `pg_stat_activity` 就得当管理员从外面连），
  //    所以必须用 `cloudHost()` 走**外网端点** —— 不能直接读 `env.PGHOST`：
  //    那个在配好 VPC 之后是内网地址，从本机**能解析、连不上**（TCP 超时），
  //    而现象看起来像「白名单没放行」，方向完全错。
  host: cloudHost(env),
  port: Number(env.PGPORT || 5432),
  database: env.PGDATABASE,
  // ⚠️ 管理员身份，不是 app_rls —— 理由见文件头「必须用管理员身份」那段。
  user: env.PG_OPS_USER,
  password: env.PG_OPS_PASSWORD,
  // ⚠️ 与 app 保持一致：PGSSLMODE 是**单点**定义，别在这里另写一套判断。
  ssl: env.PGSSLMODE === 'require' ? { rejectUnauthorized: false } : undefined,
});

await client.connect();

const me = await client.query(
  'select current_user::text as u, rolsuper, rolbypassrls from pg_roles where rolname = current_user',
);
const who = me.rows[0];

const { rows } = await client.query(
  `
  select client_addr::text                                   as client_addr,
         usename::text                                       as usename,
         coalesce(application_name, '')::text                as app,
         state::text                                         as state,
         count(*)::int                                       as conns
  from pg_stat_activity
  where backend_type = 'client backend'
    and datname = current_database()
    and client_addr is not null
  group by client_addr, usename, application_name, state
  order by client_addr, usename
  `,
);

await client.end();

console.log(`\n▸ 库：${cloudHost(env)}/${env.PGDATABASE}`);
console.log('  （本脚本从**本机**连，走外网端点；函数侧走 `PGHOST` 内网地址）');
console.log(`   本脚本以 **${who.u}** 身份读（rolsuper=${who.rolsuper} rolbypassrls=${who.rolbypassrls}）`);
if (!who.rolsuper && !who.rolbypassrls) {
  console.log('   ⚠️⚠️ 这个身份**看不到别人的会话** → 下面的名单是残缺的，判据无效！');
}
console.log(`\n连到本库 ${env.PGDATABASE} 的来源（IP × 数据库身份）：`);

let appAuthRows = [];
for (const r of rows) {
  const priv = isPrivate(r.client_addr);
  const isAuth = r.usename === env.PG_AUTH_USER;
  if (isAuth) appAuthRows.push(r);
  const tag = isAuth ? '  ⭐ 这条来自**数据服务**（登录/注册身份）' : '';
  console.log(
    `  ${r.client_addr.padEnd(18)} ${String(r.usename).padEnd(16)} ` +
      `连接 ${String(r.conns).padEnd(3)} ${priv ? '私有 → **走 VPC 内网** ✓' : '公网 → 走了公网出口'}` +
      `${r.app ? `  app=${r.app}` : ''}  ${r.state}${tag}`,
  );
}

console.log('');
if (appAuthRows.length === 0) {
  console.log(`⚠️ 没看到 \`${env.PG_AUTH_USER}\` 的连接。`);
  console.log('   先确认**自己有没有资格看到它**（上面那行 rolbypassrls）；');
  console.log('   有资格还是看不到，再打一次接口（池子 idleTimeout=30s，来得及）：');
  console.log(`     curl -s -o /dev/null -X POST https://<数据服务域名>/auth/login \\`);
  console.log(`       -H 'content-type: application/json' -d '{"phone":"<真账号>","password":"<口令>"}'`);
  console.log('   ⚠️ 必须用**真账号**（库里存在的）—— 不存在的号也回 401，');
  console.log('      那个 401 **证明不了**库通没通（doc/aliyun-deploy-plan.md §7.1）。');
} else {
  const pub = appAuthRows.filter((r) => !isPrivate(r.client_addr));
  const priv = appAuthRows.filter((r) => isPrivate(r.client_addr));
  const list = appAuthRows.map((r) => `\`${r.client_addr}\``).join('、');
  console.log(`⭐ **决定性的那几行**：数据服务（\`${env.PG_AUTH_USER}\`）的连接来自 ${list}`);
  if (priv.length > 0) {
    console.log('   → 有私有地址 = **函数确实走 VPC 内网**。白名单放行交换机网段就够了。');
  }
  if (pub.length > 0) {
    console.log('   → **有公网地址 = 这些连接没走内网**（VPC 对它们是白配的）。');
    console.log('     注意它此刻**仍然能用**，所以不会有人发现 —— 但放行它的是');
    console.log('     RDS 白名单里某条**过宽**的规则，而 FC 的公网出口 IP 是**会变**的。');
    console.log('     修法：把 `.env.prod` 的 `PGHOST` 换成 RDS 的**内网地址**');
    console.log('     （控制台「数据库连接」页里私网那条）。它与外网那条**不是同一个域名**，');
    console.log('     实例 ID 尾部就差两个字符 —— **别以为是笔误**（实测两者解析结果完全不同）。');
    console.log('     ⚠️ 内网地址从本机**能解析、但连不上**是正常的：本脚本走 `cloudHost()`');
    console.log('        取的是外网端点（`PGHOST_EXTERNAL`），别用 DNS 能否 ping 通来判断对错。');
  }
}
console.log('');
