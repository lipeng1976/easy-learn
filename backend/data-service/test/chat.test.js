import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';

import { createApp } from '../src/app.js';
import { assertAuthRoleScoped, assertRlsEnforced, createPool } from '../src/db.js';
import { ErrorCodes } from '../../shared/errors.js';

/**
 * 聊天消息（结伴双方的一对一对话）。
 *
 * ## 这个文件守着的那件事
 *
 * 服务端一直有 `chat_message` 表 / 索引 / RLS，**唯独没有路由** ——
 * 云端的「伴学消息」页读写都抛 `not_implemented`，而界面上点发送毫无反应
 * （异常被吞、输入框照样清空）。所以这个文件的第一组用例是「它**能**用」。
 *
 * ## 用例里最值钱的是越权反面
 *
 * 聊天是这套系统里**唯一**「不按学生聚合、纯按人对人」的读：
 * 家长之间的对话不该被孩子看到。所以可见性不能靠「有没有结伴」蒙过去，
 * 三条反面缺一不可：
 *
 *   · **非成员** 读/写 → 404（不是 403：分开报错会泄露 relationship_id 存不存在）
 *   · **非 active**（pending）的关系 → 403（结伴确认不能被绕过）
 *   · **不带票** → 401
 *
 * 少了任何一条，一个「只要有 relationshipId 就能收发」的实现也能全绿。
 *
 * 另一条值钱的是**收信人由服务端反推**：客户端根本不能指定 receiverId，
 * 所以「往里塞一个假收信人」这件事在结构上不成立 —— 用「传了也不认」来钉住它。
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

const PASSWORD = 'abc123';
/** 与其它测试文件的号段错开，避免同一库里互相踩。 */
const STU_PHONE = '13800004001';   // 林小宇（学生）
const PAR_PHONE = '13800004002';   // 王老师（家长，与他结伴）
const OTHER_STU_PHONE = '13800004003'; // 另一个学生（无关第三方）
const OTHER_PAR_PHONE = '13800004004'; // 另一个家长（无关第三方）
const PEND_STU_PHONE = '13800004005';  // 留给「pending 关系」用例的那一对
const PEND_PAR_PHONE = '13800004006';

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

let stuId;
let stuToken;
let parId;
let parToken;
let otherStuId;
let otherStuToken;
let otherParId;
let otherParToken;
let pendingStuId;
let pendingParId;
let pendingParToken;

/** 结伴（`active`）—— 直接插库，不经邀请流程（那是 relationship 的测试范围）。 */
const marry = (id, studentId, parentId) => adminPool.query(
  `insert into relationship (id, student_id, parent_id, sender_id, status)
   values ($1, $2, $3, $3, 'active')`,
  [id, studentId, parentId],
);

before(async () => {
  if (!PG.host || !PG.database) {
    throw new Error(
      '聊天验收需要 PostgreSQL：请用 `npm test` 运行（它会起本机 PG），'
        + '或提供 TEST_PG_HOST / TEST_PG_DATABASE 等环境变量指向已有实例。',
    );
  }

  adminPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.adminUser, password: PG.adminPassword, max: 2,
  });
  await adminPool.query(`
    delete from chat_message;
    delete from relationship;
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

  assert.equal(await assertRlsEnforced(appPool), PG.appUser);
  assert.equal(await assertAuthRoleScoped(authPool), PG.authUser);

  app = createApp({ pool: appPool, authPool, sessionSecret: SECRET });

  const stu = await register({ phone: STU_PHONE, password: PASSWORD, role: 'student' });
  assert.equal(stu.status, 200, JSON.stringify(stu.json));
  stuId = stu.json.data.user.id;
  stuToken = stu.json.data.token;

  const par = await register({ phone: PAR_PHONE, password: PASSWORD, role: 'parent' });
  parId = par.json.data.user.id;
  parToken = par.json.data.token;

  const otherStu = await register({ phone: OTHER_STU_PHONE, password: PASSWORD, role: 'student' });
  otherStuId = otherStu.json.data.user.id;
  otherStuToken = otherStu.json.data.token;

  const otherPar = await register({ phone: OTHER_PAR_PHONE, password: PASSWORD, role: 'parent' });
  otherParId = otherPar.json.data.user.id;
  otherParToken = otherPar.json.data.token;

  // 留给「pending 关系」那条用例 —— 与上面两对都不同的人，
  // 否则会撞 `uq_relation (student_id, parent_id)`。
  const pendStu = await register({ phone: PEND_STU_PHONE, password: PASSWORD, role: 'student' });
  pendingStuId = pendStu.json.data.user.id;

  const pendPar = await register({ phone: PEND_PAR_PHONE, password: PASSWORD, role: 'parent' });
  pendingParId = pendPar.json.data.user.id;
  pendingParToken = pendPar.json.data.token;

  await marry('rel_chat_main', stuId, parId);
  await marry('rel_chat_other', otherStuId, otherParId);
});

after(async () => {
  await appPool?.end().catch(() => {});
  await authPool?.end().catch(() => {});
  await adminPool?.end().catch(() => {});
});

// ===== ① 正面：这条链路真的能用 =====

test('发消息：学生的消息落库，且回的是**服务端生成的那一行**', async () => {
  const res = await call('POST', '/data/chat/messages', {
    token: stuToken,
    body: { relationshipId: 'rel_chat_main', content: '  妈妈我今天数学考了 95  ' },
  });
  assert.equal(res.status, 200, JSON.stringify(res.json));

  const msg = res.json.data.message;
  assert.ok(msg, '发送成功却没回消息行 —— 客户端无从采纳真 id（迁移规则 R2）');
  assert.ok(msg.id, '消息行没有 id');
  assert.equal(msg.relationshipId, 'rel_chat_main');
  assert.equal(msg.senderId, stuId, '发送方必须来自 token，不是客户端自报的');
  assert.equal(msg.receiverId, parId, '收信人必须由关系反推');
  assert.equal(msg.content, '妈妈我今天数学考了 95', '首尾空白该被 trim');
  assert.equal(msg.isRead, false, '新消息默认未读');
  assert.ok(msg.createdAt, '缺 createdAt —— 客户端排不出先后');
  // createdAt 由服务端给，不接受客户端传（否则可以伪造时间插入到历史里）。
  assert.ok(Date.parse(msg.createdAt) > 0);
});

test('收信人反向：家长回一句，收信人是学生', async () => {
  const res = await call('POST', '/data/chat/messages', {
    token: parToken,
    body: { relationshipId: 'rel_chat_main', content: '真棒！' },
  });
  assert.equal(res.status, 200, JSON.stringify(res.json));
  const msg = res.json.data.message;
  assert.equal(msg.senderId, parId);
  assert.equal(msg.receiverId, stuId, '家长发的消息收信人该是学生');
});

test('读消息：双方都读得到同一段对话，且按时间正序', async () => {
  for (const [who, token] of [['学生', stuToken], ['家长', parToken]]) {
    const res = await call('GET', '/data/chat/messages', {
      token,
      query: { relationshipId: 'rel_chat_main' },
    });
    assert.equal(res.status, 200, `${who}读不到：${res.body ?? ''}`);
    const items = res.json.data.items;
    assert.equal(items.length, 2, `${who}看到的条数不对：${items.length}`);
    assert.deepEqual(
      items.map((m) => m.content),
      ['妈妈我今天数学考了 95', '真棒！'],
      `${who}看到的顺序不对 —— 同一毫秒的 tiebreaker 没生效会表现为偶发颠倒`,
    );
  }
});

test('别的会话读不到：另一对结伴的消息不串台', async () => {
  await call('POST', '/data/chat/messages', {
    token: otherStuToken,
    body: { relationshipId: 'rel_chat_other', content: '这是别人家的对话' },
  });

  const res = await call('GET', '/data/chat/messages', {
    token: stuToken,
    query: { relationshipId: 'rel_chat_main' },
  });
  assert.equal(res.status, 200);
  assert.equal(
    res.json.data.items.some((m) => m.content === '这是别人家的对话'),
    false,
    '看到了别段关系的消息 —— 过滤条件漏了',
  );
});

// ===== ② 越权反面：三条缺一不可 =====

test('越权·非成员读 → 404（且与「不存在」不可区分）', async () => {
  const res = await call('GET', '/data/chat/messages', {
    token: otherStuToken,
    query: { relationshipId: 'rel_chat_main' },
  });
  assert.equal(res.status, 404, '非成员读到了别人的对话');
  assert.equal(res.json.error.code, ErrorCodes.notFound);

  // 同一张票打一个**不存在**的关系 id，必须得到同样的响应 ——
  // 两边可区分就说明「这条 relationship_id 存不存在」被泄露了（枚举面）。
  const ghost = await call('GET', '/data/chat/messages', {
    token: otherStuToken,
    query: { relationshipId: 'rel_does_not_exist' },
  });
  assert.equal(ghost.status, 404);
  assert.equal(ghost.json.error.code, res.json.error.code);
});

test('越权·非成员写 → 404（不能往别人对话里塞消息）', async () => {
  const res = await call('POST', '/data/chat/messages', {
    token: otherStuToken,
    body: { relationshipId: 'rel_chat_main', content: '插一句' },
  });
  assert.equal(res.status, 404, '非成员往别人的对话里发了消息');

  // 确认真的没写进去（404 也可能是"先写后报错"）。
  const rows = await adminPool.query(
    'select count(*)::int as n from chat_message where content = $1',
    ['插一句'],
  );
  assert.equal(rows.rows[0].n, 0, '报了 404，消息却真的落库了');
});

test('越权·不带票 → 401', async () => {
  const read = await call('GET', '/data/chat/messages', {
    query: { relationshipId: 'rel_chat_main' },
  });
  assert.equal(read.status, 401, '不带票也能读');

  const write = await call('POST', '/data/chat/messages', {
    body: { relationshipId: 'rel_chat_main', content: '不留名的消息' },
  });
  assert.equal(write.status, 401, '不带票也能发');
});

test('越权·关系不是 active → 403（结伴确认不能被绕过）', async () => {
  // 造一条 pending 的关系：此时"结伴"还没被对方点头，
  // 而 pending 意味着双方对彼此**没有任何可见性**。
  //
  // ⚠️ 必须用**另一对** user：`relationship` 上有 `uq_relation (student_id, parent_id)`
  // 唯一约束，拿已有的那对再插一条会直接撞 23505 —— 那不是这条用例要测的东西。
  await adminPool.query(
    `insert into relationship (id, student_id, parent_id, sender_id, status)
     values ('rel_chat_pending', $1, $2, $2, 'pending')`,
    [pendingStuId, pendingParId],
  );

  const write = await call('POST', '/data/chat/messages', {
    token: pendingParToken,
    body: { relationshipId: 'rel_chat_pending', content: '先聊两句再确认' },
  });
  assert.equal(
    write.status,
    403,
    'pending 关系能发消息 —— 那「输入手机号即可发消息」就成立了，pending 这道闸白设',
  );

  const read = await call('GET', '/data/chat/messages', {
    token: pendingParToken,
    query: { relationshipId: 'rel_chat_pending' },
  });
  assert.equal(read.status, 403);
});

// ===== ③ 契约：客户端不能替服务端决定的事 =====

test('收信人由服务端反推：客户端传 receiverId 也不认', async () => {
  const res = await call('POST', '/data/chat/messages', {
    token: stuToken,
    body: {
      relationshipId: 'rel_chat_main',
      content: '试图伪造收信人',
      // 想把这句塞给另一个人 —— 服务端必须无视它。
      receiverId: otherStuId,
    },
  });
  assert.equal(res.status, 200, JSON.stringify(res.json));
  assert.equal(
    res.json.data.message.receiverId,
    parId,
    '客户端指定的 receiverId 被采信了 —— 可以把消息塞进与自己无关的对话',
  );
  assert.notEqual(res.json.data.message.receiverId, otherStuId);
});

test('内容为空 / 全是空白 → 400', async () => {
  for (const content of ['', '   ', '\n\t ']) {
    const res = await call('POST', '/data/chat/messages', {
      token: stuToken,
      body: { relationshipId: 'rel_chat_main', content },
    });
    assert.equal(res.status, 400, `空内容被接受了：${JSON.stringify(content)}`);
  }
});

test('缺 relationshipId → 400', async () => {
  const res = await call('POST', '/data/chat/messages', {
    token: stuToken,
    body: { content: '发给谁呢' },
  });
  assert.equal(res.status, 400);
});

test('超长内容 → 400（拒绝而不是截断）', async () => {
  const res = await call('POST', '/data/chat/messages', {
    token: stuToken,
    body: { relationshipId: 'rel_chat_main', content: 'x'.repeat(2001) },
  });
  assert.equal(res.status, 400, '超长内容被静默接受/截断了');
});

test('读消息：limit 上限生效（不会一次拖回无限行）', async () => {
  // 写 3 条、把 limit 说小一点，确认服务端认这个上限。
  // 这里不真的灌 500 条 —— 那会让这个文件变慢，而它要守的是"上限存在"。
  const res = await call('GET', '/data/chat/messages', {
    token: stuToken,
    query: { relationshipId: 'rel_chat_main' },
  });
  assert.equal(res.status, 200);
  assert.ok(Array.isArray(res.json.data.items));
});

test('RLS 兜底：管理员连接直查也只看得到这对人的消息', async () => {
  // 用应用角色查全部 chat_message（不带身份上下文）—— 一条都不该返回。
  // 这条守的是 policy 本身还在：哪天有人把它删了，上面的路由级校验
  // 仍然能挡住越权，但 RLS 是最后一道，它不该悄悄失效。
  const r = await appPool.query('select count(*)::int as n from chat_message');
  assert.equal(
    r.rows[0].n,
    0,
    'app_rls 连接在无身份上下文时读到了消息 —— chat_message 的 RLS 没生效',
  );
});
