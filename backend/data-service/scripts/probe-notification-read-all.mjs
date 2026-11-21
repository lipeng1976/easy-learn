#!/usr/bin/env node
/**
 * 「消息通知全部已读」探针 —— 真 PG（事务内）+ 真 HTTP。
 *
 * ## 为什么需要它
 *
 * `test/notification_mark_all*.dart` 验的是客户端的本地库与控制器；
 * 服务端那条 `insert … select … where not exists` 从没在**真 PG**
 * 上跑过。RLS、`on conflict` 的落点、列名 —— 假 client 全都测不出来。
 *
 * ## 零残留
 *
 * 整段包在 `BEGIN … ROLLBACK` 里，跑完库里一条探针通知都不留。
 *
 * ## 判据
 *   1. 路由已加载：无票调 `POST /data/notifications/read-all` 必须 401
 *      （404 = 旧进程还没重启，这是本项目判断「新端点生效没」的老办法）
 *   2. 批量标记把自己可见的未读全部标掉
 *   3. **别人的专属通知一条没动**（这是最容易写错的一处：
 *      漏掉 `target_user_id = 我 or ''` 会顺手标掉别人）
 *   4. 第二次调用返回 0（幂等）
 *   5. ROLLBACK 后探针行 0 条
 *
 * ## 用法
 *   node scripts/probe-notification-read-all.mjs \
 *     --env-file "D:/easy_learn_home/config/local.env"
 */
import assert from 'node:assert/strict';

import pg from 'pg';

import { cloudHost, parseEnvFile } from './lib/env-file.mjs';
import { markAllNotificationsRead } from '../src/routes/notification.js';

const args = process.argv.slice(2);
const envIndex = args.indexOf('--env-file');
const envPath = envIndex >= 0 ? args[envIndex + 1] : 'D:/easy_learn_home/config/local.env';
const env = { ...parseEnvFile(envPath), ...process.env };

const basePort = Number(env.PORT || 8788);
const base = `http://127.0.0.1:${basePort}`;

const probeIds = ['probe_readall_mine', 'probe_readall_broadcast', 'probe_readall_other'];

async function main() {
  // 1) 路由是否已加载 —— 401 才算「新代码在跑」，404 是旧进程。
  const noAuth = await fetch(`${base}/data/notifications/read-all`, { method: 'POST' });
  console.log(`1. 无票 HTTP ${noAuth.status}`);
  assert.equal(noAuth.status, 401, '无票必须 401；404 = 数据服务还是旧进程，先重启');

  const client = new pg.Client({
    // 必须走 cloudHost：云上 PGHOST 是实例名，直连要换成 PGHOST_EXTERNAL，
    // 否则脚本在运维机上跑不起来（`scripts/` 下的硬规则，有判据盯着）。
    host: cloudHost(env),
    port: Number(env.PGPORT || 5433),
    database: env.PGDATABASE,
    user: env.PG_OPS_USER || env.PGUSER,
    password: env.PG_OPS_PASSWORD || env.PGPASSWORD,
    ssl: env.PGSSLMODE === 'require' ? { rejectUnauthorized: false } : undefined,
  });
  await client.connect();

  try {
    await client.query('begin');

    const users = await client.query(
      "select id from app_user order by role, id limit 2",
    );
    assert.ok(users.rowCount >= 2, '需要至少两个账号来验「别人的通知不被标」');
    const me = users.rows[0].id;
    const other = users.rows[1].id;

    // 清掉可能残留的同名探针行（事务内，回滚后无影响）
    await client.query('delete from app_notification where id = any($1::text[])', [probeIds]);
    await client.query(
      `insert into app_notification (id, title, body, target_user_id, type)
       values ($1, '探针-我的', 'x', $2, 'system'),
              ($3, '探针-广播', 'x', '', 'system'),
              ($4, '探针-别人的', 'x', $5, 'system')`,
      [probeIds[0], me, probeIds[1], probeIds[2], other],
    );

    // 不做「先清空该用户已读」这种粗暴操作：探针插的三条是全新 id，
    // 本来就不可能已读，所以 marked ≥ 2 是确定成立的。
    const result = await markAllNotificationsRead(client, { userId: me });
    console.log(`2. marked = ${result.marked}`);
    assert.ok(result.marked >= 2, '「我的 + 广播」至少两条该被标');

    const visibleUnread = await client.query(
      `select count(*)::int as n from app_notification n
        where (n.target_user_id = $1 or n.target_user_id = '')
          and not exists (select 1 from app_notification_read r
                           where r.notification_id = n.id and r.user_id = $1)`,
      [me],
    );
    assert.equal(visibleUnread.rows[0].n, 0, '我可见的未读应该清零');

    const otherRead = await client.query(
      `select count(*)::int as n from app_notification_read
        where notification_id = $1 and user_id = $2`,
      [probeIds[2], me],
    );
    assert.equal(otherRead.rows[0].n, 0, '别人的专属通知不该被我标已读');
    console.log('3. 别人的专属通知未被动');

    const again = await markAllNotificationsRead(client, { userId: me });
    assert.equal(again.marked, 0, '第二次应为 0（幂等）');
    console.log('4. 第二次 marked = 0');
  } finally {
    await client.query('rollback');
    const left = await client.query(
      'select count(*)::int as n from app_notification where id = any($1::text[])',
      [probeIds],
    );
    await client.end();
    assert.equal(left.rows[0].n, 0, 'ROLLBACK 后不该有残留');
    console.log('5. ROLLBACK 后残留 0 条');
  }

  console.log('\nALL PASS');
}

main().catch((e) => {
  console.error('PROBE FAILED:', e.message);
  process.exit(1);
});
