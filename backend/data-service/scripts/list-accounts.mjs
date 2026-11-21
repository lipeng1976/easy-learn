// 列出本机服务端库里的账号 —— 排查「我注册的账号去哪了」的第一站。
//
// ⚠️ **只读**，不写任何东西。
// ⚠️ 需要 `npm run dev:stack` 正开着：它是持有本机 PG 的那个进程。
//
// 用法：
//   npm run accounts              # 查演示栈的库（55433）
//   npm run accounts -- --port=55434   # 查别的端口（比如测试库）
//
// 为什么需要它：客户端连的是「本地库」还是「服务端库」，取决于构建时的
// `DATA_API_BASE_URL`（见仓库 README「两种模式 = 两个互不相通的库」）。
// 现象是「之前注册的账号说没有注册」，而数据其实好好地在另一侧。
// 这条命令能**立刻**回答「服务端这边到底有哪些账号」。
import pg from 'pg';
import { LOCAL_PG } from '../src/pg-local.js';

const arg = process.argv.find((a) => a.startsWith('--port='));
const port = arg ? Number(arg.slice('--port='.length)) : LOCAL_PG.port;

const c = new pg.Client({
  host: '127.0.0.1',
  port,
  user: LOCAL_PG.admin.user,
  password: LOCAL_PG.admin.password,
  database: LOCAL_PG.database,
});

try {
  await c.connect();
} catch (e) {
  console.error(`连不上 127.0.0.1:${port} 上的 PostgreSQL：${e?.message ?? e}`);
  console.error('');
  console.error('这个库由 dev-stack 持有，先把它开着：');
  console.error('  cd serverless/data-service && npm run dev:stack');
  process.exit(1);
}

try {
  const cols = await c.query(
    `select column_name from information_schema.columns
      where table_name = 'app_user' and column_name in ('created_at', 'phone')`,
  );
  const hasCreatedAt = cols.rows.some((r) => r.column_name === 'created_at');

  const users = await c.query(
    `select u.id, u.name, u.phone, u.role,
            (k.user_id is not null) as has_password
       from app_user u
       left join app_user_credential k on k.user_id = u.id
      order by u.phone nulls last`,
  );

  console.log(`服务端库 127.0.0.1:${port}/${LOCAL_PG.database}，共 ${users.rowCount} 个账号：`);
  console.log('');
  for (const u of users.rows) {
    console.log(
      `  ${u.name}  ${u.phone ?? '(无手机号)'}  ${u.role}` +
        `  ${u.has_password ? '有密码' : '无密码（微信类账号）'}`,
    );
    console.log(`    id=${u.id}`);
  }

  const sess = await c.query(
    `select u.name, u.phone, max(s.issued_at) as last_seen, count(*)::int as times
       from user_session s
       left join app_user u on u.id = s.user_id
      group by u.name, u.phone
      order by last_seen desc`,
  );
  console.log('');
  console.log('登录过的账号（按最近一次排序）：');
  for (const s of sess.rows) {
    console.log(
      `  ${s.name ?? '(未知)'} / ${s.phone ?? '(无)'}  最近 ${s.last_seen}  共 ${s.times} 次`,
    );
  }

  console.log('');
  console.log('提示：这里只有**云模式**注册的账号。用本地模式（不带 DATA_API_BASE_URL）');
  console.log('      构建的客户端注册的账号在设备自己那边（浏览器 localStorage / App 私有目录），');
  console.log('      不会出现在这张表里 —— 反过来也一样。');
  if (!hasCreatedAt) {
    // 表里没有建号时间列，这句只是免得下一个人以为漏查了
    console.log('（app_user 没有 created_at 列，看不出建号时间，只能看会话时间。）');
  }
} finally {
  await c.end();
}
