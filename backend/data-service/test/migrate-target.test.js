import { test } from 'node:test';
import assert from 'node:assert/strict';

import { resolveMigrationTarget } from '../src/migrate.js';

/**
 * 迁移用哪个身份连库 —— **一个变量名不能挂两个值**。
 *
 * ## 这个文件在守什么
 *
 * `.env.prod` 是**一份文件喂三个命令**：`migrate.mjs`（要管理员）、
 * `check-config.mjs`、`s deploy`（函数上必须是 `app_rls`）。
 *
 * 而迁移**必须**是管理员：`002_rls.sql` / `003_session.sql` 要建 `app_auth`
 * （`BYPASSRLS`），那个属性只有超级用户授得出来。
 *
 * 于是 `PGUSER` 上同时挂着两个互相冲突的值。`loadEnv()` 又是**文件优先**
 * （见 `scripts/lib/env-file.mjs`），shell 里临时覆盖无效 ——
 * 所以靠「跑的时候改一下」是做不到的，必须让运维连接**有自己的名字**。
 *
 * 守两件事：
 *   ① 配了 `PG_OPS_USER` 就用它，`PGUSER` 腾出来专给函数（`app_rls`）；
 *   ② 配了 `PG_OPS_USER` 却漏配 `PG_OPS_PASSWORD` 时**绝不回落** `PGPASSWORD`
 *      —— 那会拿应用角色的口令去连管理员账号，报 `password authentication failed`，
 *      和「口令写错了」长得一模一样，排查方向直接跑偏。
 *      宁可空口令，连不上，报错指向真因。
 *
 * 跑法：`npm test`（不需要 PG）。
 */

const BASE = {
  PGHOST: 'pgm-test.pg.rds.aliyuncs.com',
  PGPORT: '5432',
  PGDATABASE: 'easy_learn',
};

test('地址三项与身份无关：不管用哪套身份，连的都是同一个库', () => {
  const t = resolveMigrationTarget({ ...BASE, PG_OPS_USER: 'admin' });
  assert.equal(t.host, 'pgm-test.pg.rds.aliyuncs.com');
  assert.equal(t.port, 5432);
  assert.equal(t.database, 'easy_learn');
});

test('PG_OPS_USER 存在时用它，口令取 PG_OPS_PASSWORD', () => {
  const t = resolveMigrationTarget({
    ...BASE,
    PG_OPS_USER: 'ops_admin',
    PG_OPS_PASSWORD: 'ops-secret',
    // 函数用的那套同时在，**不许**掺进来
    PGUSER: 'app_rls',
    PGPASSWORD: 'app-secret',
  });
  assert.equal(t.identity, 'ops');
  assert.equal(t.user, 'ops_admin');
  assert.equal(t.password, 'ops-secret');
});

test('⚠️ 配了 PG_OPS_USER 但漏配口令：口令为空，**绝不**退回去用 PGPASSWORD', () => {
  // 这是本文件最重要的一条。回落会拿 app_rls 的口令去连管理员账号，
  // 报错是 `password authentication failed for user "ops_admin"` ——
  // 它长得像「口令写错了」，于是人会去翻口令，而真因是「少配了一行」。
  const t = resolveMigrationTarget({
    ...BASE,
    PG_OPS_USER: 'ops_admin',
    PGPASSWORD: 'app-secret',
    PGUSER: 'app_rls',
  });
  assert.equal(t.identity, 'ops');
  assert.equal(t.user, 'ops_admin');
  assert.equal(t.password, '', '漏配运维口令时必须为空，不能回落到应用口令');
});

test('没配 PG_OPS_USER 时回落到 PGUSER —— 本机用法零行为变化', () => {
  const t = resolveMigrationTarget({
    ...BASE,
    PGUSER: 'postgres',
    PGPASSWORD: 'postgres',
  });
  assert.equal(t.identity, 'app');
  assert.equal(t.user, 'postgres');
  assert.equal(t.password, 'postgres');
});

test('一个都没配时兜底 postgres，并把这件事报成 default', () => {
  const t = resolveMigrationTarget({ ...BASE });
  assert.equal(t.identity, 'default');
  assert.equal(t.user, 'postgres');
  assert.equal(t.password, '');
});

test('PG_OPS_USER 写成空串 = 没配（env 文件里留空是常事）', () => {
  const t = resolveMigrationTarget({
    ...BASE,
    PG_OPS_USER: '',
    PG_OPS_PASSWORD: '',
    PGUSER: 'app_rls',
    PGPASSWORD: 'app-secret',
  });
  assert.equal(t.identity, 'app');
  assert.equal(t.user, 'app_rls');
  assert.equal(t.password, 'app-secret');
});

test('identity 只有三种取值 —— 它是给运维看的标签，不是连接参数', () => {
  const seen = new Set([
    resolveMigrationTarget({ ...BASE, PG_OPS_USER: 'a' }).identity,
    resolveMigrationTarget({ ...BASE, PGUSER: 'a' }).identity,
    resolveMigrationTarget({ ...BASE }).identity,
  ]);
  assert.deepEqual([...seen].sort(), ['app', 'default', 'ops']);
});
