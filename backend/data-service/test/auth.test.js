import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';

import {
  assertAuthRoleScoped,
  assertRlsEnforced,
  createPool,
  withAuthConnection,
  withRequestContext,
} from '../src/db.js';
import { createApp } from '../src/app.js';
import { isHashFormat } from '../src/password.js';
import { issueSessionToken } from '../../shared/token.js';

/**
 * S2 验收：账号、会话与结伴。
 *
 * 这个文件里的用例分四类，**第四类最值钱**：
 *   ① 注册 / 登录 / 改密 —— 功能能用；
 *   ② 会话可吊销 —— 登出真的登出、改密把别的设备踢下线；
 *   ③ 结伴闭环 —— 「家长看到孩子的作业」这条路径真的通了（S1 之前做不到）；
 *   ④ **不该发生的不会发生** —— 家长读不到孩子的口令哈希、改不了孩子的密码、
 *      越权的 UPDATE 影响 0 行、鉴权连接碰不到业务表。
 *
 * 第 ④ 类全部是**断言**，不是「人工检查过」。原因见 003/004 的注释：
 * 这类安全机制失效时**没有任何症状** —— 不报错、不影响功能，
 * 只会在某天变成一次数据泄露或一次越权。人眼看不出来，只能由测试守着。
 *
 * 跑法：`npm test`（先起本机 PG）。
 */

const SECRET = 'test-secret-not-for-production';

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

/** 刻意避开演示数据的号段（138000000xx），便于在同一库上对照排查。 */
const STU_PHONE = '13800002001';
const PAR_PHONE = '13800002002';
const OTHER_STU_PHONE = '13800002003';
const PASSWORD = 'abc123';

let adminPool;
let appPool;
let authPool;
let app;

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

const register = (body) => call('POST', '/auth/register', { body });
const login = (body) => call('POST', '/auth/login', { body });
const me = (token) => call('GET', '/auth/me', { token });
const sessionsOf = (token) => call('GET', '/auth/sessions', { token });
const logout = (token, body) => call('POST', '/auth/logout', { token, body });
const changePassword = (token, body) => call('POST', '/auth/password', { token, body });

// 跨用例共享的账号与会话。
let stuUserId;
let stuToken;
let parUserId;
let parToken;

before(async () => {
  if (!PG.host || !PG.database) {
    throw new Error(
      'S2 验收需要 PostgreSQL：请用 `npm test` 运行（它会起本机 PG），'
        + '或提供 TEST_PG_HOST / TEST_PG_DATABASE 等环境变量指向已有实例。',
    );
  }

  adminPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.adminUser, password: PG.adminPassword, max: 2,
  });
  // relationship 没有外键（客户端那张表本来就没有），所以要显式清；
  // 删 app_user 会级联带走 credential 与会话行。
  await adminPool.query(`
    delete from relationship;
    delete from homework;
    delete from point_ledger;
    delete from app_user;
  `);

  appPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.appUser, password: PG.appPassword, max: 4,
  });
  authPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.authUser, password: PG.authPassword, max: 4,
  });

  // 两个自检都要在这里跑：它们是「安全机制是否真的生效」的断言。
  // 不跑的话，本地全绿、上线才发现收口没生效 —— 而这类问题没有症状。
  assert.equal(await assertRlsEnforced(appPool), PG.appUser);
  assert.equal(await assertAuthRoleScoped(authPool), PG.authUser);

  app = createApp({ pool: appPool, authPool, sessionSecret: SECRET });
});

after(async () => {
  await appPool?.end().catch(() => {});
  await authPool?.end().catch(() => {});
  await adminPool?.end().catch(() => {});
});

// ===== ① 注册 / 登录 =====

test('注册：返回会话与用户，库里存的是哈希而不是明文', async () => {
  const res = await register({ phone: STU_PHONE, password: PASSWORD, role: 'student' });
  assert.equal(res.status, 200, JSON.stringify(res.json));
  const { token, user } = res.json.data;

  assert.ok(typeof token === 'string' && token.length > 20, '注册应当直接拿到会话');
  assert.equal(user.role, 'student');
  assert.equal(user.phone, STU_PHONE);
  assert.equal(user.name, '新学生');
  // 这两条是**硬边界**：哈希进了响应体不会有任何症状，只会在某天被人看到。
  assert.equal(user.passwordHash, undefined, '响应里绝不能出现口令哈希');
  assert.equal(user.password, undefined, '响应里绝不能出现明文口令');
  assert.ok(typeof user.passwordUpdatedAt === 'string', 'passwordUpdatedAt 要在注册这一刻就写上');

  const r = await adminPool.query(
    'select password_hash, password_updated_at from app_user_credential where user_id = $1',
    [user.id],
  );
  assert.equal(r.rowCount, 1, '凭证行必须存在（否则这个账号永远登不进来）');
  assert.ok(isHashFormat(r.rows[0].password_hash), `库里必须是带参数的哈希：${r.rows[0].password_hash}`);
  assert.ok(!r.rows[0].password_hash.includes(PASSWORD), '哈希里不该出现明文片段');

  const legacy = await adminPool.query(
    `select count(*)::int as n from information_schema.columns
      where table_name = 'app_user' and column_name in ('password_hash', 'password_updated_at')`,
  );
  assert.equal(legacy.rows[0].n, 0, '凭证列必须已经搬出 app_user（见 sql/004_credential.sql）');

  stuUserId = user.id;
  stuToken = token;
});

test('注册：手机号已占用时明确拒绝，且不会留下半截账号', async () => {
  const before = await adminPool.query('select count(*)::int as n from app_user');
  const res = await register({ phone: STU_PHONE, password: PASSWORD, role: 'parent' });
  assert.equal(res.status, 409, JSON.stringify(res.json));
  assert.equal(res.json.error.code, 'bad_request');
  assert.equal(res.json.error.details?.reason, 'phone_taken');
  const after = await adminPool.query('select count(*)::int as n from app_user');
  assert.equal(after.rows[0].n, before.rows[0].n, '失败的注册不该插入任何行');
});

test('注册：老师角色不开放自助注册（班级功能的前置依赖还没到）', async () => {
  const res = await register({ phone: '13800002099', password: PASSWORD, role: 'teacher' });
  assert.equal(res.status, 400, JSON.stringify(res.json));
});

test('登录：「账号不存在」与「密码错误」回复完全一致（不做账号枚举器）', async () => {
  const wrongPassword = await login({ phone: STU_PHONE, password: 'wrong123', role: 'student' });
  const noSuchUser = await login({ phone: '13800009876', password: PASSWORD, role: 'student' });
  const wrongRole = await login({ phone: STU_PHONE, password: PASSWORD, role: 'parent' });

  assert.equal(wrongPassword.status, 401);
  assert.equal(noSuchUser.status, 401);
  assert.equal(wrongRole.status, 401);
  // 三者必须**一字不差**：任何差别（码、文案、状态码）都是可探测的信号。
  const shape = (r) => [r.status, r.json.error.code, r.json.error.message].join('|');
  assert.equal(shape(noSuchUser), shape(wrongPassword));
  assert.equal(shape(wrongRole), shape(wrongPassword));
});

// ===== ② 两台设备与会话吊销 =====

test('两台设备：同一账号登录两次，各自独立会话，都能读到同一份数据', async () => {
  // 先清掉注册时那个会话，让计数有意义。
  await adminPool.query('delete from user_session where user_id = $1', [stuUserId]);

  const phone = await login({ phone: STU_PHONE, password: PASSWORD, role: 'student' });
  const tablet = await login({ phone: STU_PHONE, password: PASSWORD }); // 不传 role 也允许
  assert.equal(phone.status, 200, JSON.stringify(phone.json));
  assert.equal(tablet.status, 200, JSON.stringify(tablet.json));

  const t1 = phone.json.data.token;
  const t2 = tablet.json.data.token;
  assert.notEqual(t1, t2, '两台设备必须是两个不同的 token');

  // 「两台设备看到同一条数据」在 S2 能验的部分：同一个账号 id、同一批会话。
  assert.equal(phone.json.data.user.id, tablet.json.data.user.id);

  const list = await sessionsOf(t1);
  assert.equal(list.json.data.items.length, 2, '两个设备应当看到两条活跃会话');
  assert.equal(list.json.data.items.filter((x) => x.current).length, 1, '只有一条是「当前设备」');

  // 两个 token 都能通过鉴权。
  assert.equal((await me(t1)).status, 200);
  assert.equal((await me(t2)).status, 200);

  // 会话列表是**自己的**：别人的列表里不该出现我的会话。
  const other = await register({ phone: OTHER_STU_PHONE, password: PASSWORD, role: 'student' });
  const otherList = await sessionsOf(other.json.data.token);
  const mine = new Set(list.json.data.items.map((x) => x.id));
  assert.ok(
    otherList.json.data.items.every((x) => !mine.has(x.id)),
    '别人的会话列表里出现了我的会话 —— 会话表 RLS 没生效',
  );

  stuToken = t1;
});

test('登出：当前会话立刻失效，另一台设备不受影响', async () => {
  const phone = await login({ phone: STU_PHONE, password: PASSWORD });
  const tablet = await login({ phone: STU_PHONE, password: PASSWORD });

  // 先把「登录本身成立」断言掉：一个 undefined 的 token 得到的也是 401，
  // 若登录悄悄失败了，下面那条「别的设备还能用」会以完全误导的方式失败
  // —— 排查方向会被带到「登出踢了别人」上去。
  assert.equal(phone.status, 200, JSON.stringify(phone.json));
  assert.equal(tablet.status, 200, JSON.stringify(tablet.json));
  const t1 = phone.json.data.token;
  const t2 = tablet.json.data.token;
  assert.notEqual(t1, t2, '两次登录必须拿到两个不同的会话');

  const out = await logout(t1, { reason: '用户退出登录' });
  assert.equal(out.status, 200, JSON.stringify(out.json));
  assert.equal(out.json.data.revoked, true);

  const afterLogout = await me(t1);
  assert.equal(afterLogout.status, 401, '登出后旧 token 必须立刻失效');
  assert.equal(afterLogout.json.error.code, 'token_invalid');
  assert.match(afterLogout.json.error.message, /已失效/);

  const second = await me(t2);
  assert.equal(second.status, 200, `登出不该把别的设备一起踢下线：${JSON.stringify(second.json)}`);

  // 「重复登出还是 200」这个直觉是错的：第二次请求连**鉴权**都过不去
  // （会话已吊销 → token_invalid），走不到 handler 里那句 revoked 判断。
  // 这是「所有受保护端点都验会话」这条统一规则的自然结果 —— 不为 logout 开特例，
  // 因为特例正是「某天有人加了个不校验会话的端点」这类问题的起点。
  // 客户端的正确处置：登出流程里收到 401 也当作「已经登出」并清掉本地 token。
  const again = await logout(t1, {});
  assert.equal(again.status, 401);
  assert.equal(again.json.error.code, 'token_invalid');

  stuToken = t2;
});

test('改密：吊销全部旧会话，并给当前设备补发新 token', async () => {
  const phone = await login({ phone: STU_PHONE, password: PASSWORD });
  const tablet = await login({ phone: STU_PHONE, password: PASSWORD });
  const t1 = phone.json.data.token;
  const t2 = tablet.json.data.token;

  const res = await changePassword(t1, { currentPassword: PASSWORD, newPassword: 'xyz789' });
  assert.equal(res.status, 200, JSON.stringify(res.json));
  const fresh = res.json.data.token;
  assert.ok(typeof fresh === 'string');
  assert.ok(res.json.data.revokedSessions >= 2, '至少两个在线会话都该被吊销');

  // 当前设备拿新 token 继续用 —— 改密不该把操作者自己踢出去。
  assert.equal((await me(fresh)).status, 200, '当前设备必须拿到可用的新 token');
  // 另一台设备被踢下线。
  const kicked = await me(t2);
  assert.equal(kicked.status, 401);
  assert.match(kicked.json.error.message, /密码已修改/);

  // 旧密码登不进来，新密码可以。
  assert.equal((await login({ phone: STU_PHONE, password: PASSWORD })).status, 401);
  assert.equal((await login({ phone: STU_PHONE, password: 'xyz789' })).status, 200);

  // 改回来，后面的用例继续用 PASSWORD。
  const back = await changePassword(fresh, { currentPassword: 'xyz789', newPassword: PASSWORD });
  assert.equal(back.status, 200, JSON.stringify(back.json));
  stuToken = back.json.data.token;
});

test('伪造与降级：不带 sid / sid 不存在 / 会话已过期，三种都进不来', async () => {
  // ① 签名完全合法但没有 sid —— S1 那种 token 现在必须被拒。
  //    不拒的话，任何人签一个不带 sid 的 token 就绕过了整张会话表。
  const noSid = issueSessionToken({ secret: SECRET, subject: stuUserId, role: 'student' });
  const r1 = await me(noSid);
  assert.equal(r1.status, 401);
  assert.equal(r1.json.error.code, 'token_invalid');
  assert.match(r1.json.error.message, /缺少会话标识/);

  // ② 结构合法、签名合法，但会话不存在（比如已被清理）。
  const ghost = issueSessionToken({
    secret: SECRET, subject: stuUserId, role: 'student', sessionId: 'sess_not_a_real_session',
  });
  const r2 = await me(ghost);
  assert.equal(r2.status, 401);
  assert.equal(r2.json.error.code, 'token_invalid');
  assert.match(r2.json.error.message, /会话不存在/);

  // ③ 会话过期要回 token_expired（客户端可以续签），不能与「已吊销」混为一谈。
  const expiredSid = 'sess_expired_for_test';
  await adminPool.query(
    `insert into user_session (id, user_id, issued_at, expires_at)
     values ($1, $2, now() - interval '2 hours', now() - interval '1 hour')`,
    [expiredSid, stuUserId],
  );
  const stale = issueSessionToken({
    secret: SECRET, subject: stuUserId, role: 'student', sessionId: expiredSid,
  });
  const r3 = await me(stale);
  assert.equal(r3.status, 401);
  assert.equal(r3.json.error.code, 'token_expired', '过期要能与吊销区分开，客户端的处置不同');
});

// ===== ③ 结伴闭环 =====

test('结伴：邀请 → 确认 → 家长才能看到孩子的数据（S1 之前这条路径不成立）', async () => {
  const par = await register({ phone: PAR_PHONE, password: PASSWORD, role: 'parent' });
  assert.equal(par.status, 200, JSON.stringify(par.json));
  parUserId = par.json.data.user.id;
  parToken = par.json.data.token;

  // 造一条学生的作业，用来验证「家长看得到 / 看不到」。
  await adminPool.query(
    `insert into homework (id, student_id, title, subject, status)
     values ('hw_s2_1', $1, '语文作业', '语文', 'pending')`,
    [stuUserId],
  );

  // 结伴之前：家长明确被拒（403），而不是拿到一个空列表 ——
  // 后者会被当成「这孩子还没写作业」，把越权问题藏起来。
  const tooEarly = await call('GET', '/data/homework', {
    token: parToken, query: { studentId: stuUserId },
  });
  assert.equal(tooEarly.status, 403, JSON.stringify(tooEarly.json));

  // 家长按手机号邀请学生（这一步在客户端单机实现里必然失败，见 open-items §C1）。
  const invited = await call('POST', '/data/relationship/invite', {
    token: parToken, body: { targetPhone: STU_PHONE },
  });
  assert.equal(invited.status, 200, JSON.stringify(invited.json));
  const relId = invited.json.data.relationship.id;
  assert.equal(invited.json.data.relationship.status, 'pending');
  assert.equal(invited.json.data.relationship.parentId, parUserId);
  assert.equal(invited.json.data.relationship.studentId, stuUserId);

  // 被邀请方（学生）看得到这条待确认的邀请。
  const stuList = await call('GET', '/data/relationship', { token: stuToken });
  assert.ok(stuList.json.data.items.some((x) => x.id === relId), '学生应当看得到待确认的邀请');

  // ★ 对照组的**前半**：还没确认时，拿不到对方的资料（名字为空）。
  // `sql/008_relationship_peer_name.sql` 只放行 `active` 的关系 ——
  // 同意之前不暴露对方是谁，这是刻意的。少了这一条断言，
  // 把条件写成「只要有一行关系就行」也会全绿。
  const pendingRow = stuList.json.data.items.find((x) => x.id === relId);
  assert.equal(pendingRow.parentName, null, 'pending 阶段不该拿到对方名字（还没同意）');

  // 确认。状态词用 `active`（服务端词表见 `src/vocab.js`）。
  const accepted = await call('POST', '/data/relationship/status', {
    token: stuToken, body: { id: relId, status: 'active' },
  });
  assert.equal(accepted.status, 200, JSON.stringify(accepted.json));
  assert.equal(accepted.json.data.relationship.status, 'active');

  // 再试一次：状态机不该允许把已确认的关系又改一遍。
  const twice = await call('POST', '/data/relationship/status', {
    token: stuToken, body: { id: relId, status: 'rejected' },
  });
  assert.equal(twice.status, 403, '已确认的邀请不该能被再次处理');

  // ⚠️ 旧词 `accepted` 现在**必须被拒**。2026-09-20 把服务端那套词统一到
  // `active`（与客户端枚举名、与本地库里的值逐字相同）。这一条是那件事的判据：
  // 它同时钉住「确实改了」与「没有为兼容留一个别名」。
  // 留别名的代价是把「同一个语义两个词」永久留在系统里，而它的失败方式是**静默的**
  // （词写错不报错，只是永远匹配不到行）。
  // 校验发生在查库之前，所以这里与「关系已经不是 pending」无关 —— 是 400，不是 403。
  const legacy = await call('POST', '/data/relationship/status', {
    token: stuToken, body: { id: relId, status: 'accepted' },
  });
  assert.equal(legacy.status, 400, '旧词 accepted 应当被拒（词表已统一为 active）');

  // ★ 对照组的**后半**：确认之后，**双方都该看到对方的名字**（2026-09-20 修）。
  // 之前这里恒为空串：服务端 `listRelationships` 只回 id，客户端模型又只能填空串 ——
  // 症状是「结伴成功、状态也是 active、界面上对方那一栏是空的」，**不报任何错**。
  // 两处一起改：`sql/008_relationship_peer_name.sql` 放开结伴对端的读
  // （学生视角的 `visible_students` 只有自己，光 join 拿不到家长那一行），
  // 加上 `routes/relationship.js` 的 list 用 LEFT JOIN 把名字带出来。
  // 只改其中一处的失败方式很具体：join 到了但被 RLS 挡 → 仍是 null，测试会红。
  const stuActive = await call('GET', '/data/relationship', { token: stuToken });
  const forStudent = stuActive.json.data.items.find((x) => x.id === relId);
  assert.equal(forStudent.parentName, '新家长', '学生要能看到结伴家长的名字');

  const parActive = await call('GET', '/data/relationship', { token: parToken });
  const forParent = parActive.json.data.items.find((x) => x.id === relId);
  assert.equal(forParent.studentName, '新学生', '家长要能看到结伴学生的名字');

  // 结伴之后：家长能看到孩子的作业了 —— **这就是 S2 的验收证据**。
  const now = await call('GET', '/data/homework', {
    token: parToken, query: { studentId: stuUserId },
  });
  assert.equal(now.status, 200, JSON.stringify(now.json));
  assert.ok(now.json.data.items.some((x) => x.id === 'hw_s2_1'), '结伴后家长应当看得到孩子的作业');
});

test('结伴：重复邀请、邀请自己、角色不互补、未注册号码，四种都被拒', async () => {
  const again = await call('POST', '/data/relationship/invite', {
    token: parToken, body: { targetPhone: STU_PHONE },
  });
  assert.equal(again.status, 400);

  const self = await call('POST', '/data/relationship/invite', {
    token: parToken, body: { targetPhone: PAR_PHONE },
  });
  assert.equal(self.status, 400);

  // 学生邀请另一个学生 —— 角色不互补，结伴没有意义。
  const stuInvite = await call('POST', '/data/relationship/invite', {
    token: stuToken, body: { targetPhone: OTHER_STU_PHONE },
  });
  assert.equal(stuInvite.status, 400, JSON.stringify(stuInvite.json));

  const unknown = await call('POST', '/data/relationship/invite', {
    token: parToken, body: { targetPhone: '13900000000' },
  });
  assert.equal(unknown.status, 400);
});

test('解除结伴：家长单方解除 → 立刻失去可见性 → 重新结伴后连解除期间的数据也看得到', async () => {
  // 前置关系从**接口**里取，不依赖上一个 test 的局部变量 ——
  // 用例之间只共享账号与 token（同本文件已有的做法）。
  //
  // ⚠️ **本用例会改变共享状态**：它把关系解除、再重新结伴，退出时关系是 `active`
  // （与进来时相同）。所以它正常运行不会影响后面的用例。
  // 但它**失败时**会把关系停在 `removed`（重邀那一步走不到）——
  // 这时往下看：那条「安全边界」用例里有自己的前置修正，
  // 它不会再因为这里而变红（见那处的注释）。
  const list = await call('GET', '/data/relationship', { token: parToken });
  const active = list.json.data.items.find(
    (x) => x.status === 'active' && x.studentId === stuUserId,
  );
  assert.ok(active, '前置条件：应当有一条已成立的关系');
  const relId = active.id;

  // 解除之前的基线：家长看得到孩子的作业（与结尾那条断言同源，便于对照）。
  const before = await call('GET', '/data/homework', {
    token: parToken, query: { studentId: stuUserId },
  });
  assert.equal(before.status, 200, JSON.stringify(before.json));

  // ★ 基线的**另一半**，也是本用例里最容易写成「空转的绿」的地方：
  //   必须先证明「孩子提交作业 → 家长收到通知」这条路**真的会产生通知**，
  //   后面那句「解除后家长不再收到」才有意义。
  //   少了这一步，那条断言在任何实现下都会通过（包括「通知功能整个坏掉」）。
  const submitBefore = await call('POST', '/data/homework/update', {
    token: stuToken,
    body: { id: 'hw_s2_1', submittedAt: '2026-09-26T02:00:00.000Z' },
  });
  assert.equal(submitBefore.status, 200, JSON.stringify(submitBefore.json));

  const parNotifsBefore = await call('GET', '/data/notifications', { token: parToken });
  assert.ok(
    parNotifsBefore.json.data.items.some(
      (x) => x.title === '孩子已提交作业' && x.relatedBizId === 'hw_s2_1',
    ),
    '基线：结伴期内孩子提交作业，家长必须收到通知',
  );

  // ★ ① 学生**不能**解除 —— 只有家长能（产品决定 2026-09-26）。
  //    403 而不是 400：「这件事不归你做」与「参数写错了」是两回事，
  //    客户端要据此决定是提示还是静默。
  //
  //    ⚠️ **这里必须同时断言文案**，只断言 403 是一个**测不出东西的绿**：
  //    `revoke` 的 UPDATE 上有两道各自独立的保护 —— 角色闸
  //    （`ctx.role !== parent`）与作用域（`parent_id = ctx.userId`）——
  //    学生来调时**两道都会给 403**。删掉角色闸，这条断言照样通过
  //    （2026-09-26 实测：证伪 C 全绿，才发现断言是弱的），
  //    而那时错误文案从「只有家长可以解除结伴」退化成
  //    「找不到可解除的结伴关系（或无权操作）」——一句**对学生毫无信息量**的话。
  //    钉文案才钉得住「产品决定被表达出来了」这件事。
  const byStudent = await call('POST', '/data/relationship/revoke', {
    token: stuToken, body: { id: relId },
  });
  assert.equal(byStudent.status, 403, JSON.stringify(byStudent.json));
  assert.match(
    byStudent.json.error.message, /只有家长/,
    '应当是「这件事不归你做」的明确说法，而不是模糊的「找不到 / 无权操作」',
  );

  // ② 家长解除，状态落到 `removed`（服务端词表 2026-09-26 才有这个词）。
  const revoked = await call('POST', '/data/relationship/revoke', {
    token: parToken, body: { id: relId },
  });
  assert.equal(revoked.status, 200, JSON.stringify(revoked.json));
  assert.equal(revoked.json.data.relationship.status, 'removed');

  // ③ 再解除一次 → 已经不是 `active` 了，状态机不该允许。
  const twice = await call('POST', '/data/relationship/revoke', {
    token: parToken, body: { id: relId },
  });
  assert.equal(twice.status, 403, '已解除的关系不该能被再解除一次');

  // ★ ④ 解除的**后果**：家长拿不到孩子的数据了。
  //    ⚠️ 是 403（`requireVisibleStudent` 拒了），**不是空列表** ——
  //    两者差别很要紧：空列表会被家长读成「这孩子还没写作业」，
  //    而那正是这套系统里最常见的一类静默失败（功能对了，但长得像 bug）。
  const after = await call('GET', '/data/homework', {
    token: parToken, query: { studentId: stuUserId },
  });
  assert.equal(after.status, 403, JSON.stringify(after.json));

  // ⑤ 关系行本身**双方都还看得见**（RLS policy 里 `parent_id = 我` 那一半 +
  //    学生侧的 `student_id = 我自己`），状态是 `removed`。
  //    这是客户端「其他 / 已解除」那个分组的数据来源；少了它，
  //    被解除的一方只会发现家长"不见了"，而不知道发生了什么。
  const parList = await call('GET', '/data/relationship', { token: parToken });
  assert.equal(
    parList.json.data.items.find((x) => x.id === relId)?.status, 'removed',
  );
  const stuList = await call('GET', '/data/relationship', { token: stuToken });
  assert.equal(
    stuList.json.data.items.find((x) => x.id === relId)?.status, 'removed',
    '被解除的一方也要看得到「已解除」',
  );

  // ⑥ 被解除的一方收到通知。
  //    这条同时是 `notifyUser` 的**第一条用例** —— 那个函数的注释写着
  //    「目前没有任何调用点……真要开始用它，先给它补一条用例」。
  //    它最容易错的形态是**静默不发**：`counterpartIds` 只认 active，
  //    解除之后按默认推导去算收件人，会得到空数组 —— 不报错，对方什么都不知道。
  const stuNotifs = await call('GET', '/data/notifications', { token: stuToken });
  assert.ok(
    stuNotifs.json.data.items.some(
      (x) => x.type === 'relationship' && x.title === '结伴已解除',
    ),
    '被解除的一方应当收到通知',
  );

  // ⑦ **解除期间**孩子自己产生的数据（直接插一行，模拟他这几天照常写作业）。
  //    家长此刻看不到它，但它必须已经在库里 —— 后面两处对照都要用它。
  await adminPool.query(
    `insert into homework (id, student_id, title, subject, status)
     values ('hw_gap_1', $1, '解除期间的作业', '数学', 'pending')`,
    [stuUserId],
  );

  // ★ ⑦' 解除之后家长**也不再收到**孩子的通知 —— 可见性与通知必须同时断掉。
  //     这一段是**自动生效**的（`parentIdsOf` / `counterpartIds` 都只认 active，
  //     没有为解除改任何一行代码），正因为如此才更要有断言守着：
  //     「靠一个共享条件自动成立」的边界，在有人改那个条件时不会有任何提示。
  //
  //     ⚠️ 它必须放在**重新结伴之前** —— 放后面就变成在 active 状态下提交，
  //     通知当然会发出去，而断言会以「实现正确」的样子变红。
  //
  //     判据用 `relatedBizId` 精确定位到这一份作业，而不是数通知条数 ——
  //     条数会被上面那条基线通知污染（它还在列表里）。
  const submitDuringGap = await call('POST', '/data/homework/update', {
    token: stuToken,
    body: { id: 'hw_gap_1', submittedAt: '2026-09-26T03:00:00.000Z' },
  });
  assert.equal(submitDuringGap.status, 200, JSON.stringify(submitDuringGap.json));

  const parNotifs = await call('GET', '/data/notifications', { token: parToken });
  assert.equal(
    parNotifs.json.data.items.some((x) => x.relatedBizId === 'hw_gap_1'), false,
    '解除期间孩子产生的通知不该发给已解除的家长',
  );

  // ★ ⑧ 重新结伴。这一条钉的是 `uq_relation` 唯一约束有没有被处理 ——
  //    没处理时的症状是一句**与事实完全相反**的话：「你们已经结伴」，
  //    而关系明明是 `removed`。这是本次改动里最容易漏、也最难从代码上看出来的一步
  //    （`insert` 被唯一约束挡住，而报错文案看起来很正常）。
  const reinvited = await call('POST', '/data/relationship/invite', {
    token: parToken, body: { targetPhone: STU_PHONE },
  });
  assert.equal(reinvited.status, 200, JSON.stringify(reinvited.json));
  assert.equal(reinvited.json.data.relationship.status, 'pending');
  assert.equal(
    reinvited.json.data.relationship.id, relId,
    '复活的应当是**同一行**（唯一约束盯的是 student_id + parent_id，与手机号无关）',
  );

  const reaccepted = await call('POST', '/data/relationship/status', {
    token: stuToken, body: { id: relId, status: 'active' },
  });
  assert.equal(reaccepted.status, 200, JSON.stringify(reaccepted.json));

  // ★ ⑨ **本用例真正要回答的那个问题**：重新结伴后家长看到的是**全部历史**，
  //    包括解除期间孩子自己产生的那条。
  //
  //    这是确认过的**产品决定**（说明在 `vocab.js: RELATIONSHIP_STATUS.removed`），
  //    不是遗漏 —— 所以它值得一条断言：将来谁要把它改成「只看到重新结伴之后的」，
  //    会先在这里看到红，然后被迫读一遍那个决定的理由与代价（open-items B22）。
  const reconnected = await call('GET', '/data/homework', {
    token: parToken, query: { studentId: stuUserId },
  });
  assert.equal(reconnected.status, 200, JSON.stringify(reconnected.json));
  const ids = reconnected.json.data.items.map((x) => x.id);
  assert.ok(ids.includes('hw_s2_1'), '结伴期内产生的数据应当恢复可见');
  assert.ok(
    ids.includes('hw_gap_1'),
    '解除期间产生的数据**同样**可见 —— 产品决定，不是 bug',
  );
});

// ===== ④ 安全边界（全是断言，人工检查没有意义）=====

test('安全边界：家长读不到、也改不动孩子的口令凭证', async () => {
  // 先看**没设身份**时会读到什么：一条都没有。
  // 这是 RLS 的第一道保险 —— 连接池复用时漏设一次身份（那是个很难复现的 bug），
  // 后果是「查询返回空」而不是「返回全部账号」。
  const reached = await appPool.query(
    `select u.id, c.password_hash
       from app_user u left join app_user_credential c on c.user_id = u.id
      where u.id = $1`,
    [stuUserId],
  );
  assert.equal(reached.rowCount, 0, '未设身份的连接不该读到任何账号行');

  // ⚠️ 前置：**先确保关系是 active**，别假设。
  //
  // 本文件前面的用例会改变结伴关系（解除、重新结伴），所以「上一条用例收尾时
  // 恰好是 active」是一件不该被依赖的事。2026-09-26 之前这条用例就是这么活的：
  // 「解除结伴」那条一旦失败（它会把关系留在 `removed`），红点就会跑到这里来，
  // 报一句 `结伴后家长应当能看到孩子` —— 而这个失败与这条用例要守的安全边界
  // **毫无关系**。定位的人会先怀疑 RLS，而真正的原因在上一百行。
  //
  // 用 adminPool 直接拨回来是**构造前置**，不是绕过被测代码：
  // 这条用例要验的是「关系成立之后家长能读什么」（RLS policy），不是「怎么结伴」。
  await adminPool.query(
    `update relationship set status = 'active' where student_id = $1 and parent_id = $2`,
    [stuUserId, parUserId],
  );

  // 再用家长自己的身份开事务试一次 —— 这才是真实请求的形态。
  await withRequestContext(appPool, { userId: parUserId, role: 'parent', sessionId: 'x' }, async (client, ctx) => {
    assert.ok(ctx.visibleStudents.includes(stuUserId), '结伴后家长应当能看到孩子');

    const row = await client.query(
      `select id, name from app_user where id = $1`,
      [stuUserId],
    );
    assert.equal(row.rowCount, 1, '家长看得到孩子的基本资料（这是功能）');

    const cred = await client.query(
      'select password_hash from app_user_credential where user_id = $1',
      [stuUserId],
    );
    assert.equal(cred.rowCount, 0, '家长**读不到**孩子的凭证行（这是边界）');

    const write = await client.query(
      `update app_user_credential set password_hash = 'forged' where user_id = $1`,
      [stuUserId],
    );
    assert.equal(write.rowCount, 0, '家长**改不动**孩子的凭证（update 的行策略只放自己）');

    const tamper = await client.query(
      `update app_user set name = '被改掉了' where id = $1`,
      [stuUserId],
    );
    assert.equal(tamper.rowCount, 0, '家长改不动孩子的资料（读的范围不该授权写的范围）');
  });

  // 而孩子自己的凭证仍然可读可写 —— 上面的边界不能是「谁都碰不到」。
  await withRequestContext(appPool, { userId: stuUserId, role: 'student', sessionId: 'x' }, async (client) => {
    const cred = await client.query(
      'select password_hash from app_user_credential where user_id = $1',
      [stuUserId],
    );
    assert.equal(cred.rowCount, 1, '自己必须能读到自己的凭证（否则改密做不了）');
  });
});

test('安全边界：鉴权连接碰不到任何业务表', async () => {
  // 这是 003/004 那份 GRANT 白名单的运行时验证。
  // 一旦有人「顺手」给 app_auth 多授一张表，这里会失败 ——
  // 而那条路径绕过了 RLS，多一张表就多一片不受隔离的数据，且没有任何症状。
  await assert.rejects(
    () => withAuthConnection(authPool, (c) => c.query('select 1 from homework limit 1')),
    /permission denied/i,
    '鉴权连接读到 homework 了 —— 越权面被放开了',
  );
  await assert.rejects(
    () => withAuthConnection(authPool, (c) => c.query('select 1 from relationship limit 1')),
    /permission denied/i,
  );
});
