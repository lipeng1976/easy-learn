import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';

import { assertAuthRoleScoped, assertRlsEnforced, createPool } from '../src/db.js';
import { createApp } from '../src/app.js';
import { issueSessionToken } from '../../shared/token.js';

/**
 * S1 验收：连接池 + 事务身份 + RLS + 信封这条链路是通的。
 *
 * 三条契约路径（迁移计划 §5）：**读 / 写 / 重试幂等返回原结果**。
 * 其余用例是守门的边界 —— 它们验证的不是「功能能用」，
 * 而是「不该发生的不会发生」（越权、缺 role、跨学生幂等键）。
 *
 * 跑法：`npm test`（它先起本机 PG 再执行本文件）。
 *
 * ⚠️ S2 起 token 的形态变了：**必须带 `sid`，且那个会话得在库里活着**。
 * 光有签名不再够（不然谁都签一个不带 sid 的 token 就绕过了吊销）。
 * 所以下面的 `sessionFor()` 会先造会话行再签 token。
 */

const SECRET = 'test-secret-not-for-production';

/**
 * 连接信息来自环境变量，由 `scripts/run-tests.mjs` 提供。
 *
 * 测试**刻意不自己起 PG**：`node:test` 会再 spawn 一层子进程，而 postgres 是常驻进程，
 * 测试进程持有它会让运行器一直等不到句柄释放（详见 wrapper 里的注释）。
 * 顺带的好处是同一套测试可以直接指向云 PG —— 只要给 TEST_PG_* 环境变量。
 */
const PG = {
  host: process.env.TEST_PG_HOST,
  port: Number(process.env.TEST_PG_PORT ?? 0),
  database: process.env.TEST_PG_DATABASE,
  adminUser: process.env.TEST_PG_ADMIN_USER,
  adminPassword: process.env.TEST_PG_ADMIN_PASSWORD,
  appUser: process.env.TEST_PG_APP_USER,
  appPassword: process.env.TEST_PG_APP_PASSWORD,
  authUser: process.env.TEST_PG_AUTH_USER,
  authPassword: process.env.TEST_PG_AUTH_PASSWORD,
};

let adminPool;
let appPool;
let authPool;
let app;

/** 种子：两个学生 + 一个家长，家长同时绑定两个孩子。 */
const SEED = `
  insert into app_user (id, name, role, avatar) values
    ('stu_001', '林小宇', 'student', 'fox'),
    ('stu_002', '林小桐', 'student', 'rabbit'),
    ('par_001', '王老师', 'parent', 'teacher');

  insert into relationship (id, student_id, parent_id, sender_id, status) values
    ('rel_1', 'stu_001', 'par_001', 'par_001', 'active'),
    ('rel_2', 'stu_002', 'par_001', 'par_001', 'active');

  insert into homework (id, student_id, title, subject, status) values
    ('hw_1', 'stu_001', '语文作业', '语文', 'pending'),
    ('hw_2', 'stu_002', '数学作业', '数学', 'pending');
`;

/**
 * 造一个「活的」会话并签出对应的 token。
 *
 * 用运维连接直插 `user_session`：本文件要验的是**业务接口**，
 * 而注册与登录本身是 `auth.test.js` 的事。走注册流程会更"真实"，
 * 但那样每个业务用例都要先扛一次 scrypt（约几十毫秒 × 用例数），
 * 而它换不来任何本文件的覆盖。
 */
async function sessionFor(userId, role) {
  const sid = `sess_${userId}`;
  await adminPool.query(
    `insert into user_session (id, user_id, issued_at, expires_at)
     values ($1, $2, now(), now() + interval '1 hour')
     on conflict (id) do nothing`,
    [sid, userId],
  );
  return issueSessionToken({ secret: SECRET, subject: userId, role, sessionId: sid });
}

/** 学生 token 在 before 里现签 —— 会话行必须先有，所以不能是模块级常量。 */
let stuToken;
let stu2Token;
let parentToken;

async function call(method, pathname, { token, query, body } = {}) {
  const res = await app({
    method,
    pathname,
    query: query ?? {},
    headers: token === undefined ? {} : { authorization: `Bearer ${token}` },
    body: body ?? {},
  });
  return { status: res.status, json: JSON.parse(res.body) };
}

before(async () => {
  if (!PG.host || !PG.database) {
    throw new Error(
      '契约测试需要 PostgreSQL：请用 `npm test` 运行（它会起本机 PG），'
        + '或提供 TEST_PG_HOST / TEST_PG_DATABASE 等环境变量指向已有实例。',
    );
  }

  // 运维连接：超级用户，刻意绕过 RLS —— 只用于准备种子与断言「库里真实有几行」。
  adminPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.adminUser, password: PG.adminPassword, max: 2,
  });
  // 清空后重插，让本文件对「外部 PG 上重复运行」也是幂等的。
  // 删 app_user 会级联删掉它的会话行（ON DELETE CASCADE），所以下面的
  // sessionFor() 不会撞上上一轮留下的过期会话。
  await adminPool.query(`
    delete from homework;
    delete from point_ledger;
    delete from relationship;
    delete from app_user;
  `);
  await adminPool.query(SEED);

  // 应用连接：必须是普通角色，否则 RLS 静默失效。
  appPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.appUser, password: PG.appPassword, max: 4,
  });
  const roleName = await assertRlsEnforced(appPool);
  assert.equal(roleName, PG.appUser);

  // 鉴权连接：S2 起注册/登录/会话校验都走它。它的自检（越权面是否被收口）
  // 与 RLS 自检同等重要 —— 漏跑的症状是「本地全绿，上线才发现收口没生效」。
  authPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.authUser, password: PG.authPassword, max: 4,
  });
  const authRoleName = await assertAuthRoleScoped(authPool);
  assert.equal(authRoleName, PG.authUser);

  app = createApp({ pool: appPool, authPool, sessionSecret: SECRET });

  stuToken = await sessionFor('stu_001', 'student');
  stu2Token = await sessionFor('stu_002', 'student');
  parentToken = await sessionFor('par_001', 'parent');
});

after(async () => {
  await appPool?.end().catch(() => {});
  await authPool?.end().catch(() => {});
  await adminPool?.end().catch(() => {});
});

// ===== 契约一：读 =====

test('读：学生只看到自己的作业，看不到别人的（RLS 生效）', async () => {
  const res = await call('GET', '/data/homework', { token: stuToken });
  assert.equal(res.status, 200);
  assert.equal(res.json.ok, true);
  const ids = res.json.data.items.map((x) => x.id);
  assert.deepEqual(ids, ['hw_1']);
  assert.equal(res.json.data.items[0].studentId, 'stu_001', '返回的字段应是 camelCase');
});

test('读：家长看到两个孩子的作业', async () => {
  const res = await call('GET', '/data/homework', { token: parentToken });
  assert.equal(res.status, 200);
  const ids = res.json.data.items.map((x) => x.id).sort();
  assert.deepEqual(ids, ['hw_1', 'hw_2']);
});

test('读：家长可以按 studentId 在可见集合内筛选', async () => {
  const res = await call('GET', '/data/homework', {
    token: parentToken,
    query: { studentId: 'stu_002' },
  });
  assert.equal(res.status, 200);
  assert.deepEqual(res.json.data.items.map((x) => x.id), ['hw_2']);
});

test('越权：家长请求自己没绑定的学生，明确 403 而不是空列表', async () => {
  const res = await call('GET', '/data/homework', {
    token: parentToken,
    query: { studentId: 'stu_999' },
  });
  assert.equal(res.status, 403);
  assert.equal(res.json.error.code, 'forbidden');
});

// ===== 契约二：写 =====

test('写：新建作业成功，且 id 由服务端生成', async () => {
  const res = await call('POST', '/data/homework', {
    token: stuToken,
    body: { studentId: 'stu_001', title: '英语作业', subject: '英语', estimatedMinutes: 30 },
  });
  assert.equal(res.status, 200);
  const item = res.json.data.item;
  assert.equal(item.studentId, 'stu_001');
  assert.equal(item.status, 'pending', 'status 由服务端定，客户端说了不算');
  assert.equal(typeof item.estimatedMinutes, 'number', 'numeric 应当被转成数字而不是字符串');
  assert.match(item.id, /^[0-9a-f-]{36}$/, 'id 应是服务端生成的 uuid');
});

test('写：不能给不属于自己的学生布置作业', async () => {
  const res = await call('POST', '/data/homework', {
    token: stuToken,
    body: { studentId: 'stu_002', title: '越权作业' },
  });
  assert.equal(res.status, 403);
  assert.equal(res.json.error.code, 'forbidden');

  const check = await adminPool.query(`select count(*)::int n from homework where title = '越权作业'`);
  assert.equal(check.rows[0].n, 0, '被拒的写入不该落库');
});

// ===== 契约三：重试幂等返回原结果 =====

test('幂等：同一个 idempotencyKey 重试两次，返回同一笔而不是报冲突', async () => {
  const payload = {
    studentId: 'stu_001',
    action: 'checkin',
    points: 5,
    reason: '完成打卡',
    idempotencyKey: 'idem-checkin-2026-09-18',
  };

  const first = await call('POST', '/data/points/earn', { token: stuToken, body: payload });
  assert.equal(first.status, 200);
  assert.equal(first.json.data.created, true);

  // 模拟「第一次其实成功了、响应在路上丢了」后的重试。
  const retry = await call('POST', '/data/points/earn', { token: stuToken, body: payload });
  assert.equal(retry.status, 200, '重试必须成功 —— 回 409 会让客户端不知道到底成没成');
  assert.equal(retry.json.data.created, false, '第二次不应新建记录');
  assert.equal(
    retry.json.data.entry.id,
    first.json.data.entry.id,
    '重试必须拿到**同一笔**原结果',
  );

  const count = await adminPool.query(
    `select count(*)::int n from point_ledger where idempotency_key = $1`,
    [payload.idempotencyKey],
  );
  assert.equal(count.rows[0].n, 1, '库里只能有一条');
});

test('幂等：没有 key 的两笔都能入账（空 key 不参与防重）', async () => {
  const mk = () => ({
    studentId: 'stu_001', action: 'homework', points: 2, idempotencyKey: '',
  });
  const a = await call('POST', '/data/points/earn', { token: stuToken, body: mk() });
  const b = await call('POST', '/data/points/earn', { token: stuToken, body: mk() });
  assert.equal(a.json.data.created, true);
  assert.equal(b.json.data.created, true, '没有幂等键时不该被当成重放');
});

test('幂等：撤销之后可以重新发同一笔（原记录退出索引范围）', async () => {
  const key = 'idem-reverse-1';
  const first = await call('POST', '/data/points/earn', {
    token: stuToken,
    body: { studentId: 'stu_001', action: 'exercise', points: 3, idempotencyKey: key },
  });
  assert.equal(first.json.data.created, true);

  const rev = await call('POST', '/data/points/reverse', {
    token: stuToken,
    body: { entryId: first.json.data.entry.id },
  });
  assert.equal(rev.status, 200);
  assert.ok(rev.json.data.entry.reversedAt, '撤销后应带上 reversedAt');

  const again = await call('POST', '/data/points/earn', {
    token: stuToken,
    body: { studentId: 'stu_001', action: 'exercise', points: 3, idempotencyKey: key },
  });
  assert.equal(again.json.data.created, true, '撤销后重新打卡应当能记新的一笔');
  assert.notEqual(again.json.data.entry.id, first.json.data.entry.id);

  // 余额只算活着的记录：5(checkin) + 2 + 2(两笔无 key) + 3(重发) = 12
  const bal = await call('GET', '/data/points/balance', {
    token: stuToken,
    query: { studentId: 'stu_001' },
  });
  assert.equal(bal.json.data.balance, 12);
});

test('隔离：幂等键被别的学生占用时不返回对方的数据', async () => {
  // stu_002 用一个已经被 stu_001 用过的 key
  const res = await call('POST', '/data/points/earn', {
    token: stu2Token,
    body: { studentId: 'stu_002', action: 'checkin', points: 5, idempotencyKey: 'idem-checkin-2026-09-18' },
  });
  assert.equal(res.status, 403);
  assert.equal(res.json.error.code, 'forbidden');
});

// ===== 鉴权边界 =====

test('鉴权：没有 token → 401 unauthorized', async () => {
  const res = await call('GET', '/data/homework');
  assert.equal(res.status, 401);
  assert.equal(res.json.error.code, 'unauthorized');
});

test('鉴权：token 有效但缺 role → token_invalid（R1 的落地）', async () => {
  const noRole = issueSessionToken({ secret: SECRET, subject: 'stu_001' });
  const res = await call('GET', '/data/homework', { token: noRole });
  assert.equal(res.status, 401);
  assert.equal(
    res.json.error.code,
    'token_invalid',
    '缺 role 应判凭证不合格 —— 客户端正好该去重新登录拿带 role 的 token',
  );
});

test('鉴权：签名不对 → token_invalid', async () => {
  const forged = `${stuToken.split('.').slice(0, 2).join('.')}.deadbeef`;
  const res = await call('GET', '/data/homework', { token: forged });
  assert.equal(res.status, 401);
  assert.equal(res.json.error.code, 'token_invalid');
});

test('鉴权：过期 token → token_expired（与 invalid 分开）', async () => {
  // ⚠️ 这里必须带上 sessionId，否则会先撞上「缺会话标识」那条分支（S2 起
  // 校验链变长了：role → sid → exp），而这条用例想测的是**过期**那一步。
  // 会话 id 不需要真的存在 —— 过期在查库之前就判掉了。
  const expired = issueSessionToken({
    secret: SECRET, subject: 'stu_001', role: 'student',
    sessionId: 'sess_only_for_expiry_check', ttlSeconds: -10,
  });
  const res = await call('GET', '/data/homework', { token: expired });
  assert.equal(res.status, 401);
  assert.equal(res.json.error.code, 'token_expired');
});

test('路由：未知端点 404，方法不对 405', async () => {
  const notFound = await call('GET', '/data/unknown', { token: stuToken });
  assert.equal(notFound.status, 404);
  assert.equal(notFound.json.error.code, 'not_found');

  const wrongMethod = await call('DELETE', '/data/homework', { token: stuToken });
  assert.equal(wrongMethod.status, 405);
  assert.equal(wrongMethod.json.error.code, 'method_not_allowed');
});

test('健康检查不需要鉴权', async () => {
  const res = await call('GET', '/health');
  assert.equal(res.status, 200);
  assert.equal(res.json.data.service, 'data-service');
});
