import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';

import { assertAuthRoleScoped, assertRlsEnforced, createPool, withRequestContext } from '../src/db.js';
import { createApp } from '../src/app.js';
import { buildInsert } from '../src/insert.js';
import { issueSessionToken } from '../../shared/token.js';

/**
 * S3 验收：把 9 组 Repository 都换成服务端实现之后，那些**只有在多用户下才暴露**
 * 的失效模式不会发生。
 *
 * 本文件刻意不复测「功能能用」（那是 §6 对账脚本的事，它比对的是两边库里的行）。
 * 它守的是下面这几类**不报错、只是结果不对**的问题：
 *
 *   ① 掩码两态被抹平（`null` = 清空 vs 缺席 = 不动）—— 症状是「重新提交后
 *      家长仍看到上一次的旧分数」；
 *   ② 越权读写（客户端自报 studentId / userId / userRole）—— 症状是「别人的
 *      红点自己消失了」这类静默的错；
 *   ③ 通知由客户端生成 → 换成两台手机后**家长一条也收不到**；
 *   ④ 已读状态放在广播行上 → 学生点掉一条广播，家长那边的未读数一起消失；
 *   ⑤ 级联删除漏表 → 孤儿行让毕业判定与 A/B 一致率的**分母**悄悄变大；
 *   ⑥ 幂等靠客户端 id 命名约定而非数据库约束 —— 换个客户端就失效。
 *
 * 跑法：`npm test`（wrapper 起本机 PG、跑迁移、再执行本文件）。
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

let adminPool;
let appPool;
let authPool;
let app;

/**
 * 种子：两个孩子 + 一个家长（家长绑定两个孩子）+ 一个**谁也没绑**的学生。
 *
 * `stu_003` 是刻意留的：本文件里至少有三条用例需要「一个正常的、合法的身份，
 * 但它与任何人都没有关系」——
 *   · 未结伴的学生提交作业**不能失败**（通知发不出去是正常状态，不是错误）；
 *   · 未结伴的学生的通知列表必须是空的（广播除外），但**不能报错**；
 *   · 家长不能给「别人家的孩子」写点评。
 * 少了这个账号，这三件事就只能靠读代码相信。
 */
const SEED = `
  insert into app_user (id, name, role, avatar) values
    ('stu_001', '林小宇', 'student', 'fox'),
    ('stu_002', '林小桐', 'student', 'rabbit'),
    ('stu_003', '陈小单', 'student', 'cat'),
    ('par_001', '王老师', 'parent', 'teacher');

  insert into relationship (id, student_id, parent_id, sender_id, status) values
    ('rel_1', 'stu_001', 'par_001', 'par_001', 'active'),
    ('rel_2', 'stu_002', 'par_001', 'par_001', 'active');

  insert into homework (id, student_id, title, subject, status) values
    ('hw_1', 'stu_001', '语文作业', '语文', 'pending'),
    ('hw_2', 'stu_002', '数学作业', '数学', 'pending');
`;

/**
 * 本文件碰过的每一张表都要清 —— 不只是种子那几张。
 *
 * 理由与 `contract.test.js` 里那句「让本文件对重复运行幂等」一样，但这里更严格：
 * 本文件会往复习、心愿、计划、通知等表里写行，而**它们都不与 `app_user` 有外键**，
 * 于是「删 app_user 再重插」不会带走它们。不显式清掉的话，第二次运行的断言
 * （尤其是 `count(*) = 1` 这类）会数到上一轮留下的行，症状是「单独跑通过、
 * 连着跑就失败」—— 而这种失败最容易被人当成 flaky 忽略掉。
 *
 * 顺序：先清子表（`app_notification_read` 对 `app_notification` 有外键）。
 */
const TRUNCATE = `
  delete from app_notification_read;
  delete from app_notification;
  delete from daily_comment;
  delete from chat_message;
  delete from point_ledger;
  delete from point_rule;
  delete from homework_image;
  delete from review_attempt;
  delete from judgement_ab;
  delete from ai_practice_question;
  delete from explain_record;
  delete from review_paper_item;
  delete from review_summary;
  delete from review_paper;
  delete from review_mistake;
  delete from wish;
  delete from study_plan_checkin;
  delete from study_plan;
  delete from workout_record;
  delete from workout_plan;
  delete from homework;
  delete from relationship;
  delete from user_session;
  delete from app_user;
`;

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

let stuToken;
let stu2Token;
let stu3Token;
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

const tokenOf = { stu_001: () => stuToken, stu_002: () => stu2Token, stu_003: () => stu3Token };

/** 建一份「要批改且开着 AI」的作业 —— 提交通知的文案依赖这两个开关。 */
async function newHomework(studentId, title) {
  const res = await call('POST', '/data/homework', {
    token: tokenOf[studentId](),
    body: { studentId, title, needsGrading: true, aiEnabled: true },
  });
  assert.equal(res.status, 200, JSON.stringify(res.json));
  return res.json.data.item.id;
}

/** 某一类通知的真实行数（走运维连接：它绕过 RLS，数的是库里到底有几行）。 */
async function notifCount(relatedBizId, title) {
  const r = await adminPool.query(
    `select count(*)::int n from app_notification
      where related_biz_id = $1 and title = $2`,
    [relatedBizId, title],
  );
  return r.rows[0].n;
}

/** 从通知列表里挑出某条业务的那几条。 */
async function notifsOf(token, relatedBizId) {
  const res = await call('GET', '/data/notifications', { token });
  assert.equal(res.status, 200, JSON.stringify(res.json));
  return res.json.data.items.filter((x) => x.relatedBizId === relatedBizId);
}

before(async () => {
  if (!PG.host || !PG.database) {
    throw new Error(
      'S3 测试需要 PostgreSQL：请用 `npm test` 运行（它会起本机 PG），'
        + '或提供 TEST_PG_HOST / TEST_PG_DATABASE 等环境变量指向已有实例。',
    );
  }

  adminPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.adminUser, password: PG.adminPassword, max: 2,
  });
  await adminPool.query(TRUNCATE);
  await adminPool.query(SEED);

  appPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.appUser, password: PG.appPassword, max: 4,
  });
  assert.equal(await assertRlsEnforced(appPool), PG.appUser);

  authPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.authUser, password: PG.authPassword, max: 4,
  });
  assert.equal(await assertAuthRoleScoped(authPool), PG.authUser);

  app = createApp({ pool: appPool, authPool, sessionSecret: SECRET });

  stuToken = await sessionFor('stu_001', 'student');
  stu2Token = await sessionFor('stu_002', 'student');
  stu3Token = await sessionFor('stu_003', 'student');
  parentToken = await sessionFor('par_001', 'parent');
});

after(async () => {
  await appPool?.end().catch(() => {});
  await authPool?.end().catch(() => {});
  await adminPool?.end().catch(() => {});
});

// ===== ① 掩码两态：null = 清空、缺席 = 一个字都不动 =====

test('掩码：score/checkedAt 用 null 清空，而没出现的键保持原值', async () => {
  const hw = await newHomework('stu_001', '掩码作业');

  const first = await call('POST', '/data/homework/update', {
    token: stuToken,
    body: {
      id: hw,
      score: 90,
      checkedAt: '2026-09-18T17:30:00+08:00',
      summary: '旧摘要',
      wrongCount: 2,
      gradingSource: 'ai',
    },
  });
  assert.equal(first.status, 200, JSON.stringify(first.json));
  assert.equal(first.json.data.item.score, 90);
  assert.equal(first.json.data.item.summary, '旧摘要');

  // 关键的一步：`null` 必须被当成「写成 NULL」，而**不是**「本次不改这个字段」。
  const cleared = await call('POST', '/data/homework/update', {
    token: stuToken,
    body: { id: hw, score: null, checkedAt: null },
  });
  assert.equal(cleared.status, 200, JSON.stringify(cleared.json));
  assert.equal(cleared.json.data.item.score, null, 'score 应当被清空');
  assert.equal(cleared.json.data.item.checkedAt, null, 'checkedAt 应当被清空');
  assert.equal(
    cleared.json.data.item.summary,
    '旧摘要',
    'summary 没出现在掩码里，必须一个字都不动 —— 这条断言就是陷阱②的回归测试',
  );
  assert.deepEqual(
    cleared.json.data.touched.slice().sort(),
    ['checkedAt', 'score'],
    'touched 只应包含本次真正写了的字段',
  );
});

test('掩码：空掩码是「什么都不改」而不是错误', async () => {
  const hw = await newHomework('stu_001', '空掩码作业');
  const res = await call('POST', '/data/homework/update', { token: stuToken, body: { id: hw } });
  assert.equal(res.status, 200, '空掩码回 400 会让调用方以为写失败了');
  assert.equal(res.json.data.updated, false);
  assert.deepEqual(res.json.data.touched, []);
});

test('掩码：把整个作业对象发上来会被拒（否则是一次静默的整行覆盖）', async () => {
  const hw = await newHomework('stu_001', '整行覆盖作业');
  // `dueAt` 在**创建**白名单（`WRITABLE`）里，但**不在掩码白名单**
  // （`PATCH_SPEC`）里 —— 客户端把整个作业对象顺手发上来时
  // （`jsonEncode(item.toMap())` 那种写法），这里的 400 是唯一的信号。
  //
  // ⚠️ 2026-09-29 起 `title` / `subject` **已经放行**（识别会认错字，
  // 学生必须能改，见 `PATCH_SPEC` 的注释），所以本用例改用 `dueAt`
  // 来演示整行覆盖。**判据没变**：一次请求里只要带了「不由客户端输入
  // 决定」的字段，就必须**整体拒绝**，而不是「认识的写了、不认识的忽略」
  // —— 后者会让 `title` 悄悄写进去，那正是半成功的整行覆盖。
  const res = await call('POST', '/data/homework/update', {
    token: stuToken,
    body: {
      id: hw,
      dueAt: '2026-12-31T00:00:00+08:00',
      title: '被改掉的标题',
    },
  });
  assert.equal(res.status, 400);
  assert.equal(res.json.error.code, 'bad_request');
  assert.match(res.json.error.message, /不能通过本端点写/);
  assert.match(res.json.error.message, /dueAt/, '报错要点名是哪个字段');

  // ⭐ 这条断言是本用例真正的价值：**整条请求被拒**，所以同一次请求里的
  // `title` 也一个字都没落地。少了它，「400 了」与「400 之后还写了一半」
  // 分不出来。
  const after = await adminPool.query('select title from homework where id = $1', [hw]);
  assert.equal(after.rows[0].title, '整行覆盖作业', '被拒的请求不该改动任何字段');
});

test('掩码：title / subject 可以改 —— 识别认错字之后的唯一补救', async () => {
  // 「练字一张」被读成「练习一张」，同一张图 25 次错 19 次，而且语义更通顺
  // （见 `doc/open-items.md` B27）。识别后那张核对表单里能改，可一旦点了
  // 「确认保存全部」才发现错了，之前就只剩「删了重录」。
  const hw = await newHomework('stu_001', '练字一张');

  const res = await call('POST', '/data/homework/update', {
    token: stuToken,
    body: { id: hw, title: '练习一张', subject: '英语' },
  });
  assert.equal(res.status, 200, JSON.stringify(res.json));
  assert.deepEqual(
    res.json.data.touched.slice().sort(),
    ['subject', 'title'],
    'touched 只应包含本次真正写了的字段',
  );

  const after = await adminPool.query(
    'select title, subject from homework where id = $1',
    [hw],
  );
  assert.equal(after.rows[0].title, '练习一张');
  assert.equal(after.rows[0].subject, '英语');
});

test('掩码：科目不能改成空串（它不是「清空」，是一个无效的科目）', async () => {
  const hw = await newHomework('stu_001', '科目空值作业');
  // 断「前后相等」而不是「等于某个值」：`newHomework` 只传 title，
  // 科目在库里本来是 NULL —— 写死期望值会把用例绑在 helper 的实现上。
  const before = await adminPool.query(
    'select subject from homework where id = $1',
    [hw],
  );
  const res = await call('POST', '/data/homework/update', {
    token: stuToken,
    body: { id: hw, subject: '' },
  });
  assert.equal(res.status, 400, '空科目应当被拒，而不是写成一个空字符串');
  assert.match(res.json.error.message, /subject/, '错误信息必须点名是哪个字段');

  const after = await adminPool.query(
    'select subject from homework where id = $1',
    [hw],
  );
  assert.equal(
    after.rows[0].subject,
    before.rows[0].subject,
    '被拒的请求不该改动任何字段',
  );
});

test('实际用时：整份覆盖（不是增量）、列表带上、负数 400', async () => {
  const hw = await newHomework('stu_001', '计时作业');

  const first = await call('POST', '/data/homework/update', {
    token: stuToken,
    body: { id: hw, actualSeconds: 754 },
  });
  assert.equal(first.status, 200, JSON.stringify(first.json));
  assert.equal(
    first.json.data.item.actualSeconds,
    754,
    '响应里要带上新值 —— 客户端用它更新卡片，不再多查一次',
  );

  // 列表也必须带。卡片是刷列表刷出来的：只改响应不带列表，
  // 学生看到的是「计时结束回到列表，实际用时还是空的」。
  const list = await call('GET', '/data/homework', { token: stuToken });
  assert.equal(list.status, 200, JSON.stringify(list.json));
  const listed = list.json.data.items.find((item) => item.id === hw);
  assert.equal(listed?.actualSeconds, 754, '列表接口漏了 actual_seconds');

  // ⭐ 整份覆盖：再写 800 就是 800。若实现成增量，一份 40 分钟的作业
  // 重试一次会变成 80 分钟 —— 而界面上只表现为「计时器算错了」。
  const second = await call('POST', '/data/homework/update', {
    token: stuToken,
    body: { id: hw, actualSeconds: 800 },
  });
  assert.equal(second.status, 200, JSON.stringify(second.json));
  const row = await adminPool.query(
    'select actual_seconds from homework where id = $1',
    [hw],
  );
  assert.equal(row.rows[0].actual_seconds, 800, '不是增量累加');

  // 负数没有语义；写进去卡片会显示成 `-00:01:00`。
  const negative = await call('POST', '/data/homework/update', {
    token: stuToken,
    body: { id: hw, actualSeconds: -5 },
  });
  assert.equal(negative.status, 400);
  assert.match(negative.json.error.message, /actualSeconds/);

  const after = await adminPool.query(
    'select actual_seconds from homework where id = $1',
    [hw],
  );
  assert.equal(after.rows[0].actual_seconds, 800, '被拒的请求不该改动这一列');
});

test('专注流水：一次会话一行，重复保存是更新而不是新增', async () => {
  const id = 'fs_case_1';
  const base = {
    token: stuToken,
    body: { id, kind: 'free', title: '阅读', date: '2026-10-19', seconds: 600, startedAt: '2026-10-19T10:00:00.000Z' },
  };

  const first = await call('POST', '/data/focus-session/save', {
    token: base.token,
    body: { ...base.body, studentId: 'stu_001' },
  });
  assert.equal(first.status, 200, JSON.stringify(first.json));

  // ⭐ 检查点会写很多次。若实现成「每次新增一行」，
  // 暂停三次 = 三条 = 时长翻三倍，而界面上只是「今天读了 30 分钟」—— 没有报错。
  const again = await call('POST', '/data/focus-session/save', {
    token: base.token,
    body: { ...base.body, studentId: 'stu_001', seconds: 900 },
  });
  assert.equal(again.status, 200, JSON.stringify(again.json));

  const rows = await adminPool.query('select * from focus_session where id = $1', [id]);
  assert.equal(rows.rows.length, 1, '同一次会话只能有一行');
  assert.equal(rows.rows[0].seconds, 900, '最后一次写入生效');

  const list = await call('GET', '/data/focus-session', {
    token: stuToken,
    query: { from: '2026-10-19', to: '2026-10-19' },
  });
  assert.equal(list.status, 200, JSON.stringify(list.json));
  const found = list.json.data.items.find((r) => r.id === id);
  assert.equal(found?.seconds, 900, '列表端点要能读回来');
  assert.equal(found?.kind, 'free');

  // 窗口之外：**取不到**。「今天读了多少」多算了昨天的，家长看到的是假数字。
  const outside = await call('GET', '/data/focus-session', {
    token: stuToken,
    query: { from: '2026-10-20', to: '2026-10-20' },
  });
  assert.ok(
    !outside.json.data.items.some((r) => r.id === id),
    '日期窗口必须真的过滤',
  );

  await adminPool.query('delete from focus_session where id = $1', [id]);
});

test('专注流水：字段校验（kind / date / seconds）与越权 id', async () => {
  const ok = { studentId: 'stu_001', date: '2026-10-19', seconds: 60, title: '运动', startedAt: '2026-10-19T10:00:00.000Z' };

  const badKind = await call('POST', '/data/focus-session/save', {
    token: stuToken,
    body: { id: 'fs_kind', ...ok, kind: 'homeworkX' },
  });
  assert.equal(badKind.status, 400, '拼错的 kind 不能静默回退成 free');

  const badDate = await call('POST', '/data/focus-session/save', {
    token: stuToken,
    body: { id: 'fs_date', ...ok, kind: 'free', date: '2026-1-9' },
  });
  assert.equal(badDate.status, 400, '非 yyyy-MM-dd 会让按天取一段失效');

  const negative = await call('POST', '/data/focus-session/save', {
    token: stuToken,
    body: { id: 'fs_neg', ...ok, kind: 'free', seconds: -1 },
  });
  assert.equal(negative.status, 400);

  // 别人名下的 id：403，而不是「更新了 0 行然后回成功」。
  const mine = 'fs_owner';
  await call('POST', '/data/focus-session/save', {
    token: stuToken,
    body: { id: mine, ...ok, kind: 'free' },
  });
  const stolen = await call('POST', '/data/focus-session/save', {
    token: stu2Token,
    body: { id: mine, studentId: 'stu_002', kind: 'free', date: '2026-10-19', seconds: 999, title: '偷', startedAt: '2026-10-19T10:00:00.000Z' },
  });
  assert.equal(stolen.status, 403, '拿别人的会话 id 来写必须被拒');
  const kept = await adminPool.query('select seconds, student_id from focus_session where id = $1', [mine]);
  assert.equal(kept.rows[0].seconds, 60, '被拒的请求不能改动那一行');

  await adminPool.query('delete from focus_session where id = $1', [mine]);
});

test('专注流水：RLS —— 别人的记录取不到，也写不进去', async () => {
  const id = 'fs_rls';
  await call('POST', '/data/focus-session/save', {
    token: stuToken,
    body: { id, studentId: 'stu_001', kind: 'free', title: '阅读', date: '2026-10-19', seconds: 300, startedAt: '2026-10-19T10:00:00.000Z' },
  });

  const others = await call('GET', '/data/focus-session', {
    token: stu2Token,
    query: { from: '2026-10-19', to: '2026-10-19' },
  });
  assert.equal(others.status, 200);
  assert.ok(
    !others.json.data.items.some((r) => r.id === id),
    '另一个学生不该看到这条流水',
  );

  assert.equal(await assertRlsEnforced(appPool), PG.appUser, 'focus_session 的隔离依赖 app 角色不带 BYPASSRLS');

  await adminPool.query('delete from focus_session where id = $1', [id]);
});

test('类型强制：不带时区的时间戳被明确拒绝，而不是按服务端时区静默偏移', async () => {
  const hw = await newHomework('stu_001', '时区作业');
  const res = await call('POST', '/data/homework/update', {
    token: stuToken,
    body: { id: hw, submittedAt: '2026-09-18T17:30:00' },
  });
  assert.equal(res.status, 400);
  assert.match(res.json.error.message, /submittedAt/, '错误信息必须点名是哪个字段');
  assert.match(res.json.error.message, /时区/);
});

// ===== ③ 通知由服务端生成（陷阱⑦）=====

test('提交作业：家长收到通知，学生自己收不到这一条', async () => {
  const hw = await newHomework('stu_001', '提交通知作业');

  const res = await call('POST', '/data/homework/update', {
    token: stuToken,
    body: {
      id: hw,
      status: 'checking',
      submittedAt: '2026-09-18T09:00:00+08:00',
      submitBatchId: 'batch_1',
    },
  });
  assert.equal(res.status, 200, JSON.stringify(res.json));

  const mine = await notifsOf(parentToken, hw);
  const submitted = mine.filter((x) => x.title === '孩子已提交作业');
  assert.equal(submitted.length, 1, '家长应当收到恰好一条提交通知');
  assert.equal(submitted[0].type, 'homework');
  assert.equal(submitted[0].isRead, false);
  assert.match(
    submitted[0].body,
    /正在批改。/,
    '要批改且开着 AI 时必须说「正在批改」—— 这是家长判断「要不要等」的依据',
  );

  // 学生这一侧看**不到**「孩子已提交作业」这条（它不是发给学生的）。
  const stu = await notifsOf(stuToken, hw);
  assert.equal(
    stu.filter((x) => x.title === '孩子已提交作业').length,
    0,
    'target_user_id 是家长的通知不该出现在学生列表里',
  );
});

test('提交作业：重放同一份掩码不会重复通知', async () => {
  const hw = await newHomework('stu_002', '重放通知作业');
  const body = {
    id: hw,
    status: 'checking',
    submittedAt: '2026-09-18T09:05:00+08:00',
  };

  const first = await call('POST', '/data/homework/update', { token: stu2Token, body });
  assert.equal(first.status, 200);
  assert.equal(await notifCount(hw, '孩子已提交作业'), 1);

  // 模拟「第一次其实写成功了、响应在路上丢了」后的重试：同一份掩码再来一次。
  // 值没变 → 不是一次状态变化 → 不该再通知一遍。
  const retry = await call('POST', '/data/homework/update', { token: stu2Token, body });
  assert.equal(retry.status, 200);
  assert.equal(
    await notifCount(hw, '孩子已提交作业'),
    1,
    '幂等必须是「按可观察的状态变化」，只看掩码里有 submittedAt 就会重复通知',
  );
});

test('批改完成：家长与学生各收到一条，文案各说各的', async () => {
  const hw = await newHomework('stu_001', '批改通知作业');
  await call('POST', '/data/homework/update', {
    token: stuToken,
    body: { id: hw, status: 'checking', submittedAt: '2026-09-18T09:10:00+08:00' },
  });

  const graded = await call('POST', '/data/homework/update', {
    token: stuToken,
    body: {
      id: hw,
      status: 'finished',
      checkedAt: '2026-09-18T09:20:00+08:00',
      score: 95,
      wrongCount: 0,
      summary: '全部正确',
    },
  });
  assert.equal(graded.status, 200, JSON.stringify(graded.json));

  const parentSees = (await notifsOf(parentToken, hw)).filter((x) => x.title === '作业已完成');
  assert.equal(parentSees.length, 1);
  assert.match(parentSees[0].body, /批改完成，得分 95，全部正确。/);

  const stuSees = (await notifsOf(stuToken, hw)).filter((x) => x.title === '作业已完成');
  assert.equal(stuSees.length, 1, '学生自己也该收到一条（本地是 _notifySelf）');
  assert.match(stuSees[0].body, /得分 95，错题 0 道。/);
});

test('清空批改结果（checkedAt=null）不算一次批改事件，不发通知', async () => {
  const hw = await newHomework('stu_001', '清空结果作业');
  await call('POST', '/data/homework/update', {
    token: stuToken,
    body: {
      id: hw, status: 'finished', checkedAt: '2026-09-18T09:30:00+08:00', score: 80, wrongCount: 1,
    },
  });
  const before = await notifCount(hw, '作业需要更正');
  assert.equal(before, 1);

  // 重新提交 = 同一份掩码里清掉上一次的结果。
  const cleared = await call('POST', '/data/homework/update', {
    token: stuToken,
    body: { id: hw, status: 'checking', checkedAt: null, score: null, wrongCount: null },
  });
  assert.equal(cleared.status, 200, JSON.stringify(cleared.json));
  assert.equal(cleared.json.data.item.checkedAt, null);
  assert.equal(
    await notifCount(hw, '作业需要更正'),
    1,
    '清空结果不是一次批改完成，不该再通知一遍',
  );
});

test('未结伴的学生提交作业：正常成功，只是没有人需要被通知', async () => {
  const hw = await newHomework('stu_003', '未结伴作业');
  const res = await call('POST', '/data/homework/update', {
    token: stu3Token,
    body: {
      id: hw, status: 'checking', submittedAt: '2026-09-18T09:40:00+08:00',
    },
  });
  // 这一条最要紧：通知发不出去是**正常状态**，绝不能让它把交作业这一步弄失败。
  assert.equal(res.status, 200, JSON.stringify(res.json));
  assert.equal(res.json.data.item.status, 'checking');

  const stu3 = await call('GET', '/data/notifications', { token: stu3Token });
  assert.equal(stu3.status, 200);
  assert.equal(stu3.json.data.items.length, 0, '没结伴的人不该凭空多出通知（也不该报错）');
});

// ===== ④ 已读状态按 (通知, 用户) 拆开 =====

test('已读：一条广播被学生点掉后，家长那边仍然是未读', async () => {
  // 广播（target_user_id = ''）只能由运维连接造 —— 服务端没有「发广播」这个接口。
  await adminPool.query(
    `insert into app_notification (id, title, body, target_user_id, type)
     values ('notif_bc_1', '系统公告', '请更新 App', '', 'system')`,
  );

  const before = await notifsOf(stuToken, '');
  assert.equal(before.length, 1);
  assert.equal(before[0].isRead, false);

  const read = await call('POST', '/data/notifications/read', {
    token: stuToken,
    body: { id: 'notif_bc_1' },
  });
  assert.equal(read.status, 200, JSON.stringify(read.json));
  assert.equal(read.json.data.marked, true);

  const stuAfter = (await notifsOf(stuToken, '')).find((x) => x.id === 'notif_bc_1');
  assert.equal(stuAfter.isRead, true, '学生点过之后自己这边应当已读');

  const parentAfter = (await notifsOf(parentToken, '')).find((x) => x.id === 'notif_bc_1');
  assert.equal(
    parentAfter.isRead,
    false,
    '这就是「已读不能放在广播行上」的回归测试：学生点掉它，家长的未读数不该跟着消失',
  );
});

test('已读：重复标记幂等，且 read_at 取第一次的时刻', async () => {
  const first = await call('POST', '/data/notifications/read', {
    token: stuToken,
    body: { id: 'notif_bc_1' },
  });
  assert.equal(first.status, 200);
  const second = await call('POST', '/data/notifications/read', {
    token: stuToken,
    body: { id: 'notif_bc_1' },
  });
  assert.equal(second.status, 200);
  assert.equal(
    second.json.data.read.readAt,
    first.json.data.read.readAt,
    'read_at 是「第一次读到它的时刻」，重复点击不该把它推后',
  );
});

test('已读：不能标记一条不是发给自己的通知', async () => {
  await adminPool.query(
    `insert into app_notification (id, title, body, target_user_id, type)
     values ('notif_for_parent', '给家长的', '只给 par_001', 'par_001', 'system')`,
  );

  const res = await call('POST', '/data/notifications/read', {
    token: stuToken,
    body: { id: 'notif_for_parent' },
  });
  assert.equal(res.status, 403);
  assert.equal(res.json.error.code, 'forbidden');

  const rows = await adminPool.query(
    `select count(*)::int n from app_notification_read
      where notification_id = 'notif_for_parent' and user_id = 'stu_001'`,
  );
  assert.equal(rows.rows[0].n, 0, '被拒的标记不该留下已读行');
});

// ===== ⑤ 复习：级联删除、原子建卷、报告去重、孤儿过滤 =====

/** 造一道错题并把它的四张从属表都填上，返回错题 id 与各自的 id。 */
async function seedMistakeWithChildren(studentId, homeworkId) {
  const token = tokenOf[studentId]();
  const m = await call('POST', '/data/review/mistakes/insert', {
    token,
    body: { studentId, subject: '数学', title: '错题一', homeworkId, state: 'pending' },
  });
  assert.equal(m.status, 200, JSON.stringify(m.json));
  const mistakeId = m.json.data.items[0].id;

  const a = await call('POST', '/data/review/attempts/insert', {
    token,
    body: { studentId, items: [{ mistakeId, channel: 'paper', round: 1, answer: 'x', correct: false }] },
  });
  assert.equal(a.status, 200, JSON.stringify(a.json));

  const e = await call('POST', '/data/review/explains/insert', {
    token,
    body: { studentId, mistakeId, summary: '讲了一遍', staySeconds: 30 },
  });
  assert.equal(e.status, 200, JSON.stringify(e.json));

  const j = await call('POST', '/data/review/judgement-ab/insert', {
    token,
    body: { studentId, items: [{ mistakeId, modelVerdict: 'wrong', ruleVerdict: 'wrong' }] },
  });
  assert.equal(j.status, 200, JSON.stringify(j.json));

  const p = await call('POST', '/data/review/practice/replace', {
    token,
    body: { studentId, sourceMistakeId: mistakeId, questions: [{ title: '举一反三', content: '1+1=?' }] },
  });
  assert.equal(p.status, 200, JSON.stringify(p.json));

  return { mistakeId, attemptId: a.json.data.items[0].id, explainId: e.json.data.item.id };
}

test('练习题：题型与选项存得住、读得回（读回的不是 pg 的数组字面量）', async () => {
  // 选项以 JSON **文本**存。这条判据盯的正是「存成什么形状」：
  // 如果把数组原样交给 `text` 列，pg 会把它写成 `{2,3,4,5}` 这种
  // 数组字面量 —— 读回来 `JSON.parse` 直接抛，客户端只会看到「没有选项」，
  // 而库里那一行看起来是「有值」的。全程没有任何报错。
  const { mistakeId } = await seedMistakeWithChildren('stu_001', 'hw_pq');

  const put = await call('POST', '/data/review/practice/replace', {
    token: stuToken,
    body: {
      studentId: 'stu_001',
      sourceMistakeId: mistakeId,
      questions: [
        {
          title: '选择',
          content: '下列方程中，解为 x=2 的是（ ）',
          answer: 'A',
          questionType: 'choice',
          optionsJson: JSON.stringify(['2x+1=5', '3x-1=4', 'x/2=2', '4x=6']),
        },
        {
          title: '解答',
          content: '解方程 2x+1=5',
          answer: 'x=2',
          questionType: 'solution',
        },
      ],
    },
  });
  assert.equal(put.status, 200, JSON.stringify(put.json));

  const items = put.json.data.items;
  assert.equal(items.length, 2);
  assert.equal(items[0].questionType, 'choice');
  assert.equal(
    items[0].optionsJson,
    JSON.stringify(['2x+1=5', '3x-1=4', 'x/2=2', '4x=6']),
  );
  // 没传题型的题落到解答题 —— 这是加这一列之前所有历史题的口径。
  assert.equal(items[1].questionType, 'solution');
  assert.equal(items[1].optionsJson, '[]');
});

test('练习题：选项直接传数组也按 JSON 存（不接受 pg 的数组字面量）', async () => {
  const { mistakeId } = await seedMistakeWithChildren('stu_001', 'hw_pq2');
  const put = await call('POST', '/data/review/practice/replace', {
    token: stuToken,
    body: {
      studentId: 'stu_001',
      sourceMistakeId: mistakeId,
      questions: [
        {
          title: '选择',
          content: '题干',
          answer: 'B',
          questionType: 'choice',
          optionsJson: ['1', '2', '3', '4'],
        },
      ],
    },
  });
  assert.equal(put.status, 200, JSON.stringify(put.json));
  assert.equal(put.json.data.items[0].optionsJson, '["1","2","3","4"]');
});

test('练习题：图形 DSL 存得住、读得回；没图必须是 null 而不是 "{}"', async () => {
  // 判据盯两件事：
  //  ① 传对象能原样读回（客户端 `PracticeFigure.parse` 靠它画图）；
  //  ② **没图的题落 NULL** —— 若写成 `'{}'`，每道纯文字题都会看起来
  //     「有一张解析不出来的图」，而 `figure_json IS NULL` 再也数不出真实数量。
  const { mistakeId } = await seedMistakeWithChildren('stu_001', 'hw_pq3');
  const figure = {
    type: 'plane',
    points: [{ name: 'A', x: 0, y: 0 }, { name: 'B', x: 4, y: 0 }, { name: 'C', x: 4, y: 3 }],
    polygons: [['A', 'B', 'C']],
    dims: [{ from: 'A', to: 'B', text: '4' }],
    vars: [{ name: 'a', value: 4 }],
  };

  const put = await call('POST', '/data/review/practice/replace', {
    token: stuToken,
    body: {
      studentId: 'stu_001',
      sourceMistakeId: mistakeId,
      questions: [
        { title: '带图', content: '如图，求面积', answer: '6', figureJson: figure },
        { title: '没图', content: '1+1=?', answer: '2' },
      ],
    },
  });
  assert.equal(put.status, 200, JSON.stringify(put.json));

  const [withFigure, plain] = put.json.data.items;
  assert.equal(typeof withFigure.figureJson, 'string');
  assert.deepEqual(JSON.parse(withFigure.figureJson), figure);
  assert.equal(plain.figureJson, null);

  // 再读一次（换一条查询路径），确认不是「写接口回显、库里其实没有」。
  const list = await call('GET', '/data/review/practice', {
    token: stuToken,
    query: { sourceMistakeId: mistakeId },
  });
  assert.equal(list.status, 200, JSON.stringify(list.json));
  const readBack = list.json.data.items.find((q) => q.title === '带图');
  assert.deepEqual(JSON.parse(readBack.figureJson), figure);
});

test('级联：删一道错题会连同它的 5 张从属表一起清干净', async () => {
  const { mistakeId } = await seedMistakeWithChildren('stu_001', 'hw_1');

  const del = await call('POST', '/data/review/mistakes/delete', {
    token: stuToken,
    body: { id: mistakeId },
  });
  assert.equal(del.status, 200, JSON.stringify(del.json));
  assert.equal(del.json.data.deleted, true);
  assert.equal(del.json.data.cascaded.review_attempt, 1);
  assert.equal(del.json.data.cascaded.explain_record, 1);
  assert.equal(del.json.data.cascaded.judgement_ab, 1);
  assert.equal(del.json.data.cascaded.ai_practice_question, 1);

  // 逐表数一遍：**孤儿不报错**,只是让统计数字慢慢偏掉，所以必须直接查库。
  for (const [table, column] of [
    ['review_mistake', 'id'],
    ['review_attempt', 'mistake_id'],
    ['explain_record', 'mistake_id'],
    ['judgement_ab', 'mistake_id'],
    ['ai_practice_question', 'source_mistake_id'],
  ]) {
    const r = await adminPool.query(
      `select count(*)::int n from ${table} where ${column} = $1`,
      [mistakeId],
    );
    assert.equal(r.rows[0].n, 0, `${table} 里还有孤儿行`);
  }
});

// ===== 错题原题照片（review_mistake_image）=====
//
// 这张表和 `homework_image` 是两张表，不是一张：作业被删掉之后错题还在，
// 原题照片也必须还在。合成一张的后果是「删作业 → 错题点开没有原图」，
// 而那条错题的题干可能本来就是从照片里认出来的。

/** 造一道带两张原题照片的错题，返回 id。 */
async function seedMistakeWithPhotos(studentId) {
  const token = tokenOf[studentId]();
  const m = await call('POST', '/data/review/mistakes/insert', {
    token,
    body: {
      studentId,
      subject: '数学',
      title: '拍照录入的题',
      questionBody: '解方程：$2x+5=13$',
      sourceType: 'scan',
      grade: '初一',
      term: '上',
      images: [
        { storageKey: 'memory://students/x/m1.jpg', mimeType: 'image/jpeg', fileSize: 10, sortOrder: 0 },
        { storageKey: 'memory://students/x/m2.jpg', mimeType: 'image/jpeg', fileSize: 20, sortOrder: 1 },
      ],
    },
  });
  assert.equal(m.status, 200, JSON.stringify(m.json));
  return { mistakeId: m.json.data.items[0].id, item: m.json.data.items[0] };
}

test('错题原题照片：挂在服务端生成的 id 上，读回顺序与字节描述一致', async () => {
  const { mistakeId, item } = await seedMistakeWithPhotos('stu_001');

  // 客户端送来的 id 会被忽略（id 由服务端生成）。图片必须挂到**服务端那个**
  // id 上 —— 挂错的表现是「题和两张不相干的图关联」，而接口一律 200。
  assert.ok(item.id, '服务端必须回一个 id');
  assert.equal(item.questionBody, '解方程：$2x+5=13$');
  assert.equal(item.sourceType, 'scan');
  assert.equal(item.grade, '初一');
  assert.equal(item.term, '上');
  assert.equal(item.imageCount, 2);

  const list = await call('GET', '/data/review/mistake-images', {
    token: stuToken,
    query: { mistakeId },
  });
  assert.equal(list.status, 200, JSON.stringify(list.json));
  assert.deepEqual(
    list.json.data.items.map((image) => [image.storageKey, image.sortOrder]),
    [
      ['memory://students/x/m1.jpg', 0],
      ['memory://students/x/m2.jpg', 1],
    ],
  );
});

test('错题原题照片：别的学生查不到，且不是「200 + 别人的图」', async () => {
  const { mistakeId } = await seedMistakeWithPhotos('stu_001');

  // stu_003 与 stu_001 没有任何关系。RLS 应当把它过滤成空列表，
  // 而不是报错 —— 报错会让界面显示「加载失败」，空列表才是「这题没有图」。
  const other = await call('GET', '/data/review/mistake-images', {
    token: stu3Token,
    query: { mistakeId },
  });
  assert.equal(other.status, 200, JSON.stringify(other.json));
  assert.deepEqual(
    other.json.data.items,
    [],
    '越权读到别人的原题照片 = 学生的卷子被另一个家庭看到',
  );

  // 也不能借「追加图片」接口往别人的题上挂图：那会写出一行永远读不出来的记录。
  const append = await call('POST', '/data/review/mistake-images/insert', {
    token: stu3Token,
    body: {
      studentId: 'stu_003',
      items: [{ mistakeId, storageKey: 'memory://evil.jpg', mimeType: 'image/jpeg' }],
    },
  });
  assert.equal(append.status, 403, JSON.stringify(append.json));
});

test('级联：删一道错题会连它的原题照片一起清干净', async () => {
  const { mistakeId } = await seedMistakeWithPhotos('stu_001');

  const del = await call('POST', '/data/review/mistakes/delete', {
    token: stuToken,
    body: { id: mistakeId },
  });
  assert.equal(del.status, 200, JSON.stringify(del.json));
  assert.equal(del.json.data.cascaded.review_mistake_image, 2);

  // 直接查库，而不是相信那个 200：孤儿行不报错，只是让照片永远占着空间。
  const rows = await adminPool.query(
    'select count(*)::int n from review_mistake_image where mistake_id = $1',
    [mistakeId],
  );
  assert.equal(rows.rows[0].n, 0);
});

test('级联：删作业会连它的照片行与错题（含 5 张从属表）一起清干净', async () => {  const hw = await newHomework('stu_003', '待删除的作业');
  const { mistakeId } = await seedMistakeWithChildren('stu_003', hw);

  const img = await call('POST', '/data/homework/images', {
    token: stu3Token,
    body: {
      studentId: 'stu_003',
      homeworkId: hw,
      storageKey: 'memory://students/stu_003/homework/img_del.jpg',
      fileName: '待删.jpg',
      fileSize: 10,
      mimeType: 'image/jpeg',
    },
  });
  assert.equal(img.status, 200, JSON.stringify(img.json));

  const del = await call('POST', '/data/homework/delete', {
    token: stu3Token,
    body: { id: hw },
  });
  assert.equal(del.status, 200, JSON.stringify(del.json));
  assert.equal(del.json.data.deleted, true);
  assert.equal(del.json.data.homework, 1);
  assert.equal(del.json.data.images, 1);
  assert.equal(del.json.data.mistakes, 1);

  // 逐表数一遍，而不是只看那个接口回了 200。
  //
  // `homework` 表**没有任何外键指向它**（全库三条外键都指 `app_user` /
  // `app_notification`），所以「只删了作业行」也会全部返回 200 ——
  // 留下的是**孤儿行**：照片还占着配额、错题还在错题本里指着一份不存在的作业。
  // 孤儿不报错，只看接口返回的话这条用例永远测不出级联有没有做。
  for (const [table, column, value] of [
    ['homework', 'id', hw],
    ['homework_image', 'homework_id', hw],
    ['review_mistake', 'homework_id', hw],
    ['review_attempt', 'mistake_id', mistakeId],
    ['explain_record', 'mistake_id', mistakeId],
    ['judgement_ab', 'mistake_id', mistakeId],
    ['ai_practice_question', 'source_mistake_id', mistakeId],
  ]) {
    const r = await adminPool.query(
      `select count(*)::int n from ${table} where ${column} = $1`,
      [value],
    );
    assert.equal(r.rows[0].n, 0, `${table} 里还留着孤儿行`);
  }
});

test('删作业的两道权限：家长拦在角色闸，别的学生拦在可见集合', async () => {
  // ① 家长 —— **角色闸**。
  //
  // ⚠️ 这一条必须用「家长自己孩子的作业」。换成别人的作业时，可见集合
  // （`stu_003` 不在 par_001 的可见集合里）也会挡住它，于是这条断言
  // 在角色闸被整段删掉之后**照样是绿的** —— 那就是一条测不出东西的绿。
  const childHw = await newHomework('stu_002', '家长不该删的作业');
  const byParent = await call('POST', '/data/homework/delete', {
    token: parentToken,
    body: { id: childHw },
  });
  assert.equal(byParent.status, 403, JSON.stringify(byParent.json));
  assert.match(byParent.json.error.message, /只有学生/);

  // ② 另一个学生 —— **可见集合**（他和这份作业之间没有任何关系）。
  const hw = await newHomework('stu_003', '别人动不了的作业');
  const byOther = await call('POST', '/data/homework/delete', {
    token: stuToken,
    body: { id: hw },
  });
  assert.equal(byOther.status, 403, JSON.stringify(byOther.json));
  assert.match(byOther.json.error.message, /找不到这份作业/);

  // 两处都回了 403 —— 但**作业必须还在**。只断状态码的话，
  // 「拦住了」与「其实删掉了、只是顺带回了个错」分不出来。
  const still = await adminPool.query(
    'select count(*)::int n from homework where id = $1',
    [hw],
  );
  assert.equal(still.rows[0].n, 1, '越权请求竟然真的把作业删掉了');

  // ③ 本人删得掉；再删一次是 403 而不是静默成功 ——
  //    静默成功会让界面显示「已删除」，而那条作业其实早就没了。
  const mine = await call('POST', '/data/homework/delete', {
    token: stu3Token,
    body: { id: hw },
  });
  assert.equal(mine.status, 200, JSON.stringify(mine.json));

  const again = await call('POST', '/data/homework/delete', {
    token: stu3Token,
    body: { id: hw },
  });
  assert.equal(again.status, 403, JSON.stringify(again.json));
  assert.match(again.json.error.message, /找不到这份作业/);
});

test('级联：按作业删错题会一并清掉作答记录（这是相对本机实现的有意差异）', async () => {
  const { mistakeId } = await seedMistakeWithChildren('stu_001', 'hw_1');

  const del = await call('POST', '/data/review/mistakes/delete-by-homework', {
    token: stuToken,
    body: { homeworkId: 'hw_1' },
  });
  assert.equal(del.status, 200, JSON.stringify(del.json));
  assert.ok(del.json.data.mistakes >= 1);
  assert.ok(
    del.json.data.deleted.reviewAttempt >= 1,
    '本机实现只删 review_mistake，服务端改成级联 —— 对账脚本必须把这条记为已知差异',
  );

  const orphans = await adminPool.query(
    `select count(*)::int n from review_attempt where mistake_id = $1`,
    [mistakeId],
  );
  assert.equal(orphans.rows[0].n, 0);
});

test('建卷：卷内题目写失败时整份卷子回滚（不留「点开就空的草稿」）', async () => {
  const before = await adminPool.query(
    `select count(*)::int n from review_paper where student_id = 'stu_001' and title = '原子卷'`,
  );

  const res = await call('POST', '/data/review/papers/create', {
    token: stuToken,
    body: {
      studentId: 'stu_001',
      paper: { title: '原子卷', subject: '数学' },
      // 第二道题的 checkedAt 不合法 → 组装语句时就抛，而卷子那一条已经发出去过了。
      items: [
        { mistakeId: 'x', sortOrder: 1 },
        { mistakeId: 'y', sortOrder: 2, checkedAt: '这不是时间' },
      ],
    },
  });
  assert.equal(res.status, 400);

  const after = await adminPool.query(
    `select count(*)::int n from review_paper where student_id = 'stu_001' and title = '原子卷'`,
  );
  assert.equal(after.rows[0].n, before.rows[0].n, '卷与题目必须在同一个事务里，失败就整体不留痕');
});

test('报告：同一 (学生, 口径, 周期键) 只留一份，重复生成覆盖而不是堆积', async () => {
  const mk = (pass) => ({
    studentId: 'stu_001',
    scope: 'week',
    scopeKey: '2026-W38',
    totalCount: 10,
    passCount: pass,
    masteredCount: pass,
    remainCount: 10 - pass,
    passRate: pass / 10,
  });

  const first = await call('POST', '/data/review/summaries/upsert', { token: stuToken, body: mk(6) });
  assert.equal(first.status, 200, JSON.stringify(first.json));

  const second = await call('POST', '/data/review/summaries/upsert', { token: stuToken, body: mk(7) });
  assert.equal(second.status, 200, JSON.stringify(second.json));
  assert.equal(
    second.json.data.item.id,
    first.json.data.item.id,
    'id 是确定性的：同一周期永远是同一个 id',
  );

  const rows = await adminPool.query(
    `select count(*)::int n from review_summary
      where student_id = 'stu_001' and scope = 'week' and scope_key = '2026-W38'`,
  );
  assert.equal(rows.rows[0].n, 1, '靠数据库唯一键去重，而不是靠客户端拼 id 的约定');
});

test('报告：缺 scopeKey 要明确报错（否则唯一键会退化成空串，所有周期挤成一行）', async () => {
  const res = await call('POST', '/data/review/summaries/upsert', {
    token: stuToken,
    body: { studentId: 'stu_001', scope: 'week', totalCount: 1 },
  });
  assert.equal(res.status, 400);
  assert.match(res.json.error.message, /scopeKey/);
});

test('A/B 一致率：按学生聚合时排除孤儿记录，按错题查时保留', async () => {
  // 指向一个不存在的错题 —— 模拟「错题被删、影子记录还没清」。
  const ghost = await call('POST', '/data/review/judgement-ab/insert', {
    token: stuToken,
    body: { studentId: 'stu_001', items: [{ mistakeId: 'ghost_mistake', modelVerdict: 'a', ruleVerdict: 'b' }] },
  });
  assert.equal(ghost.status, 200, JSON.stringify(ghost.json));
  const ghostId = ghost.json.data.items[0].id;

  const board = await call('GET', '/data/review/judgement-ab', { token: stuToken });
  assert.equal(board.status, 200);
  assert.equal(
    board.json.data.items.filter((x) => x.id === ghostId).length,
    0,
    '孤儿行进了分母就把一致率系统性拉低了，而且查不出原因',
  );

  const byMistake = await call('GET', '/data/review/judgement-ab', {
    token: stuToken,
    query: { mistakeId: 'ghost_mistake' },
  });
  assert.equal(byMistake.status, 200);
  assert.equal(byMistake.json.data.items.length, 1, '按错题查要能看到中间态（排查时有用）');
});

// ===== ⑥ 幂等：靠数据库约束，不靠客户端的 id 拼法 =====

test('打卡：同一天重复打卡返回原行，且 id 不变', async () => {
  const plan = await call('POST', '/data/study-plans', {
    token: stuToken,
    body: { studentId: 'stu_001', title: '计划A', status: 'pending' },
  });
  assert.equal(plan.status, 200, JSON.stringify(plan.json));
  const planId = plan.json.data.item.id;

  const first = await call('POST', '/data/study-plans/checkin', {
    token: stuToken,
    body: { studentId: 'stu_001', planId, date: '2026-09-18' },
  });
  assert.equal(first.status, 200, JSON.stringify(first.json));
  assert.equal(first.json.data.created, true);

  const retry = await call('POST', '/data/study-plans/checkin', {
    token: stuToken,
    body: { studentId: 'stu_001', planId, date: '2026-09-18' },
  });
  assert.equal(retry.status, 200);
  assert.equal(retry.json.data.created, false);
  assert.equal(retry.json.data.item.id, first.json.data.item.id, '重打同一天时 id 不变（原地替换）');

  const rows = await adminPool.query(
    `select count(*)::int n from study_plan_checkin where plan_id = $1 and date = '2026-09-18'`,
    [planId],
  );
  assert.equal(rows.rows[0].n, 1);
});

test('打卡：日期形制不对就报错（服务端不替客户端猜「今天」）', async () => {
  const res = await call('POST', '/data/study-plans/checkin', {
    token: stuToken,
    body: { studentId: 'stu_001', planId: 'whatever', date: '2026-02-31' },
  });
  assert.equal(res.status, 400);
  assert.match(res.json.error.message, /date/);
});

test('运动记录：客户端带来的 id 就是幂等键，重复上报返回同一行', async () => {
  const body = {
    id: 'wr_dup_1',
    studentId: 'stu_001',
    title: '跑步',
    minutes: 30,
    startAt: '2026-09-18T07:00:00+08:00',
  };
  const first = await call('POST', '/data/workouts/records', { token: stuToken, body });
  assert.equal(first.status, 200, JSON.stringify(first.json));
  assert.equal(first.json.data.created, true);

  const retry = await call('POST', '/data/workouts/records', { token: stuToken, body });
  assert.equal(retry.status, 200);
  assert.equal(retry.json.data.created, false);
  assert.equal(retry.json.data.item.id, 'wr_dup_1');

  const rows = await adminPool.query(`select count(*)::int n from workout_record where id = 'wr_dup_1'`);
  assert.equal(rows.rows[0].n, 1);
});

test('运动记录：同一个 id 不能被另一个学生占用', async () => {
  const res = await call('POST', '/data/workouts/records', {
    token: stu2Token,
    body: { id: 'wr_dup_1', studentId: 'stu_002', title: '偷来的 id', minutes: 10 },
  });
  assert.equal(res.status, 403);
  assert.equal(res.json.error.code, 'forbidden');
});

// ===== ② 越权 =====

test('越权：学生改不了别人的作业', async () => {
  const res = await call('POST', '/data/homework/update', {
    token: stuToken,
    body: { id: 'hw_2', score: 100 },
  });
  assert.equal(res.status, 403);
  assert.equal(res.json.error.code, 'forbidden');
});

test('越权：按 studentId 请求别人的数据 → 403 而不是空列表', async () => {
  const res = await call('GET', '/data/homework', {
    token: stuToken,
    query: { studentId: 'stu_002' },
  });
  assert.equal(res.status, 403, '空列表会让客户端以为「他真的没有作业」');
});

test('越权：家长不能给别人的孩子写每日点评', async () => {
  const res = await call('POST', '/data/daily-comments', {
    token: parentToken,
    body: { studentId: 'stu_003', rating: 'A', content: '越界点评' },
  });
  assert.equal(res.status, 403);
  assert.equal(res.json.error.code, 'forbidden');

  const rows = await adminPool.query(`select count(*)::int n from daily_comment where student_id = 'stu_003'`);
  assert.equal(rows.rows[0].n, 0);
});

// ===== 每日点评：写进去 + 定向通知 =====

test('每日点评：写给指定的那个孩子，并只通知他', async () => {
  const res = await call('POST', '/data/daily-comments', {
    token: parentToken,
    body: { studentId: 'stu_001', rating: 'A', content: '今天很专心' },
  });
  assert.equal(res.status, 200, JSON.stringify(res.json));
  const commentId = res.json.data.item.id;
  assert.equal(res.json.data.item.studentId, 'stu_001');

  // 家长有两个孩子，而点评是写给老大的 —— 通知必须只发给老大。
  const notices = await adminPool.query(
    `select target_user_id from app_notification where related_biz_id = $1`,
    [commentId],
  );
  assert.deepEqual(
    notices.rows.map((x) => x.target_user_id),
    ['stu_001'],
    '默认按「发起者」推导会把给老大的点评同时通知给老二',
  );

  // 家长看得到两个孩子的点评；另一个孩子看不到写给他哥的那一条。
  const forParent = await call('GET', '/data/daily-comments', { token: parentToken });
  assert.equal(forParent.json.data.items.length, 1);

  const forStu2 = await call('GET', '/data/daily-comments', { token: stu2Token });
  assert.equal(forStu2.json.data.items.length, 0, '点评按学生过滤，不能整表返回再让客户端自己筛');
});

// ===== 心愿：显式清空契约与角色来自 token =====

test('心愿：清空申请用显式标志，用 null 表达清空要报错', async () => {
  const created = await call('POST', '/data/wishes', {
    token: stuToken,
    body: { studentId: 'stu_001', title: '一辆自行车', pointCost: 100 },
  });
  assert.equal(created.status, 200, JSON.stringify(created.json));
  const id = created.json.data.item.id;
  assert.equal(created.json.data.item.userRole, 'student', 'user_role 由服务端按 token 写');

  const bad = await call('POST', '/data/wishes/redeem', {
    token: stuToken,
    body: { id, redeemedAt: null },
  });
  assert.equal(bad.status, 400, '「清空」是一个会动余额的意图，不能在网络边界上含糊过去');

  const requested = await call('POST', '/data/wishes/redeem', {
    token: stuToken,
    body: { id, pointCost: 100, redeemRequestedAt: '2026-09-18T10:00:00+08:00' },
  });
  assert.equal(requested.status, 200, JSON.stringify(requested.json));
  assert.ok(requested.json.data.item.redeemRequestedAt);
  assert.equal(await notifCount(id, '孩子想兑换心愿'), 1);

  const cleared = await call('POST', '/data/wishes/redeem', {
    token: stuToken,
    body: { id, clearRedeemRequest: true },
  });
  assert.equal(cleared.status, 200, JSON.stringify(cleared.json));
  assert.equal(cleared.json.data.item.redeemRequestedAt, null);
  assert.equal(cleared.json.data.item.pointCost, 100, '没出现在掩码里的列不该被顺手改掉');
});

test('心愿：scope=created 用的是 token 里的角色，不是客户端自报的', async () => {
  const stu = await call('GET', '/data/wishes', { token: stuToken, query: { scope: 'created' } });
  assert.equal(stu.status, 200);
  assert.ok(stu.json.data.items.length >= 1, '学生自己许的心愿应当看得到');

  // 客户端仍然传 userRole（S4 之前不改），但服务端一概不读 ——
  // 家长即使声称自己是学生，也读不到学生那一侧的心愿。
  const par = await call('GET', '/data/wishes', {
    token: parentToken,
    query: { scope: 'created', userRole: 'student', studentId: 'stu_001' },
  });
  assert.equal(par.status, 200);
  assert.equal(
    par.json.data.items.filter((x) => x.userRole === 'student').length,
    0,
    'userRole 由客户端给时就是一个越权口子（陷阱⑥的反面）',
  );
});

test('积分：撤销写一条负数冲正，余额回到 0，且账上留痕', async () => {
  const key = 's3-revoke-1';
  const earn = await call('POST', '/data/points/earn', {
    token: stuToken,
    body: { studentId: 'stu_001', action: 'exercise', points: 7, idempotencyKey: key },
  });
  assert.equal(earn.status, 200, JSON.stringify(earn.json));
  const entryId = earn.json.data.entry.id;

  const rev = await call('POST', '/data/points/reverse', {
    token: stuToken,
    body: { entryId },
  });
  assert.equal(rev.status, 200, JSON.stringify(rev.json));
  assert.equal(rev.json.data.revoked, true);
  assert.ok(rev.json.data.entry.reversedAt, '原记录必须被标记 reversedAt');
  assert.equal(rev.json.data.reversal.points, -7, '冲正必须是一条负数记录');
  assert.equal(rev.json.data.reversal.reversalOf, entryId);
  assert.equal(rev.json.data.reversal.idempotencyKey, '', '冲正不参与幂等（它由原记录唯一确定）');

  const bal = await call('GET', '/data/points/balance', {
    token: stuToken,
    query: { studentId: 'stu_001' },
  });
  assert.equal(bal.json.data.balance, 0, '余额要把「已撤销」和「冲正行」两边都排除掉');

  // 撤销之后同一笔可以重发（原记录已退出部分唯一索引的范围）。
  const again = await call('POST', '/data/points/earn', {
    token: stuToken,
    body: { studentId: 'stu_001', action: 'exercise', points: 7, idempotencyKey: key },
  });
  assert.equal(again.json.data.created, true);
});

test('积分：家长可以配分值，没配过的动作不留行', async () => {
  const before = await call('GET', '/data/points/rules', { token: parentToken });
  assert.equal(before.status, 200);
  assert.equal(
    before.json.data.items.filter((x) => x.studentId === 'stu_001' && x.action === 'exercise').length,
    0,
    '没配过就是没有行 —— 默认值属于业务规则，不能有两个来源',
  );

  const set = await call('POST', '/data/points/rules', {
    token: parentToken,
    body: { studentId: 'stu_001', action: 'exercise', points: 5, enabled: true },
  });
  assert.equal(set.status, 200, JSON.stringify(set.json));

  const again = await call('POST', '/data/points/rules', {
    token: parentToken,
    body: { studentId: 'stu_001', action: 'exercise', points: 8, enabled: false },
  });
  assert.equal(again.status, 200, JSON.stringify(again.json));
  assert.equal(again.json.data.rule.points, 8);

  const rows = await adminPool.query(
    `select count(*)::int n from point_rule where student_id = 'stu_001' and action = 'exercise'`,
  );
  assert.equal(rows.rows[0].n, 1, '复合键唯一 → 重复配置是覆盖不是新增');
});

// ===== 路由表本身的守门 =====

// ===== 通知的 RLS 边界（不是「功能能用」，而是「不该发生的不会发生」）=====
//
// 这几条测的是 **policy 本身**，而不是某个处理函数：处理函数只会写「服务端算出来的」
// 收件人，所以它们永远走不到被拒的那条路径 —— 而安全边界的价值恰恰在于
// 「万一哪天有人把请求体里的字段接进来」。所以这里绕过处理函数，
// 用真实身份在真实事务里直接试插。
//
// ⚠️ 这段也是**那次实测的产物**：`005_notification.sql` 的第一版 policy 把
// 「能通知谁」写成 policy 内部的两段 RLS 子查询，实测被拒（以学生身份给结伴家长
// 插通知时报 `new row violates row-level security policy`）。改成「应用声明
// 收件人集合 + policy 只做数组包含判断」之后通过 —— 没有这几条用例，
// 那次失败只会表现为「作业提交接口 500」，而 500 不指向任何可推理的原因。
//
// ⚠️ 同一段代码后来又踩了**第二个**坑，所以下面的探针长成了现在这个样子：
// 第一版探针只 insert、**不声明收件人**，于是它测的是一个**真实调用方式里
// 不存在**的场景；改成声明之后仍然失败，最后定位到 `RETURNING`
// （见 `returning` 这个入参与下面那条专门的用例）。

/**
 * 在真实身份下试插一条通知，**返回结果而不是抛**。
 *
 * 用 savepoint 而不是 try/catch 直接吞异常：一条语句失败会让 PG 事务进入
 * aborted 状态，之后连 COMMIT 都会被拒（`current transaction is aborted`）。
 * 所以「吞掉异常继续」在事务里根本走不通，必须回滚到 savepoint ——
 * 这也正是 `notify.js` 里明确拒绝 try/catch 的原因（那里宁可让失败抛出去）。
 *
 * @param {string} userId 以谁的身份
 * @param {string} role
 * @param {object} o
 * @param {string} o.id 通知 id
 * @param {string} o.targetUserId 收件人
 * @param {string[]} [o.declare] 本次事务声明的收件人集合 —— 生产代码里由
 *        `notify.js` 的 `allowTargets()` 做。**不传就等于没声明**，
 *        那是「不该发生的场景」，用来验证 fail-closed。
 * @param {string|null} [o.returning] 列清单，**不含 `returning` 关键字**
 *        （`buildInsert` 自己拼）；传 `null` 得到「不读回」的语句形态
 */
async function probeNotifyInsert(userId, role, { id, targetUserId, declare, returning = '*' }) {
  return withRequestContext(appPool, { userId, role }, async (client) => {
    if (declare) {
      await client.query('select set_config($1, $2, true)', ['app.notify_targets', declare.join(',')]);
    }
    const who = await client.query(
      `select current_setting('app.user_id', true)     as me,
              current_setting('app.visible_students', true) as vs,
              current_setting('app.notify_targets', true)    as nt`,
    );
    await client.query('savepoint probe');
    try {
      const ins = buildInsert({
        table: 'app_notification',
        spec: {},
        row: {
          id,
          title: '边界探针',
          body: 'x',
          targetUserId,
          type: 'system',
          relatedBizId: 'notify_probe',
          isRead: false,
          createdAt: new Date(),
        },
        returning,
      });
      await client.query(ins.text, ins.values);
      await client.query('release savepoint probe');
      return { ok: true, me: who.rows[0].me, visibleStudents: who.rows[0].vs, declared: who.rows[0].nt };
    } catch (e) {
      await client.query('rollback to savepoint probe');
      return { ok: false, code: e.code, message: e.message, me: who.rows[0].me };
    }
  });
}

test('通知边界：自己 / 广播 / 声明的结伴家长 / 声明的结伴孩子 四种都写得进去', async () => {
  // 生产代码在写通知前一定会先声明收件人（`notify.js` 的 `allowTargets()`），
  // 所以这里也声明 —— 探针必须复刻**真实调用方式**，否则它测的是别的什么东西。
  const self = await probeNotifyInsert('stu_001', 'student', {
    id: 'nprobe_self', targetUserId: 'stu_001', returning: null,
  });
  assert.equal(self.ok, true, `给自己写通知应当通过：${self.message ?? ''}`);
  assert.equal(self.visibleStudents, 'stu_001', '身份必须先被正确放进事务');

  const broadcast = await probeNotifyInsert('stu_001', 'student', {
    id: 'nprobe_bc', targetUserId: '', returning: null,
  });
  assert.equal(broadcast.ok, true, `写广播应当通过：${broadcast.message ?? ''}`);

  const toParent = await probeNotifyInsert('stu_001', 'student', {
    id: 'nprobe_parent', targetUserId: 'par_001',
    declare: ['par_001'], returning: null,
  });
  assert.equal(toParent.ok, true, `声明后给结伴家长写通知应当通过：${toParent.message ?? ''}`);
  assert.equal(toParent.declared, 'par_001', '声明集合必须先落到事务里');

  const toChild = await probeNotifyInsert('par_001', 'parent', {
    id: 'nprobe_child', targetUserId: 'stu_002',
    declare: ['stu_002'], returning: null,
  });
  assert.equal(toChild.ok, true, `声明后给结伴孩子写通知应当通过：${toChild.message ?? ''}`);
});

test('通知边界：无关第三方一律被 RLS 拒绝（fail-closed）', async () => {
  // 学生给另一个学生（他们没有关系，也没有被声明）
  const peer = await probeNotifyInsert('stu_001', 'student', {
    id: 'nprobe_peer', targetUserId: 'stu_002', returning: null,
  });
  assert.equal(peer.ok, false, '学生不该能给另一个学生写通知');
  assert.equal(peer.code, '42501');
  assert.match(
    peer.message,
    /row-level security/,
    '必须是 RLS 拒绝；若是 permission denied 就说明是授权写错了，而不是策略在守门',
  );

  // 家长给「别人家」的孩子（stu_003 谁也不绑）
  const stranger = await probeNotifyInsert('par_001', 'parent', {
    id: 'nprobe_stranger', targetUserId: 'stu_003', returning: null,
  });
  assert.equal(stranger.ok, false, '家长不该能给别人的孩子写通知');
  assert.equal(stranger.code, '42501');

  // 声明里只有 A，却写给 B —— 声明是**集合**，不是「本次放行」
  const mismatched = await probeNotifyInsert('stu_001', 'student', {
    id: 'nprobe_mismatch', targetUserId: 'stu_002',
    declare: ['par_001'], returning: null,
  });
  assert.equal(mismatched.ok, false, '声明了别人不等于能写给这个人');
  assert.equal(mismatched.code, '42501');

  const rows = await adminPool.query(
    `select count(*)::int n from app_notification where related_biz_id = 'notify_probe'`,
  );
  assert.equal(
    rows.rows[0].n,
    4,
    '库里只该留下那四条通过的探针（自己 / 广播 / 结伴家长 / 结伴孩子）；被拒的三条不该落库',
  );
});

/**
 * `RETURNING` 与读策略的耦合 —— **这是不能把 `RETURNING` 加回来的原因**。
 *
 * 这条用例守的是一个**排查方向会跑偏**的失效：跨用户写通知时带 `RETURNING`，
 * 报错说的是 `new row violates row-level security policy`，于是人会去改
 * **INSERT** 策略 —— 而 INSERT 策略完全放行（收件人已经声明过）。
 * 真正的原因是 `RETURNING` 要求新行能被**读**策略看见。
 *
 * 保留它，等于把「我们已经知道这件事」变成「下次改错了会当场失败」。
 */
test('通知：跨用户插入带 RETURNING 会被读策略拒（所以 notify.js 不读回）', async () => {
  const crossUser = await probeNotifyInsert('stu_001', 'student', {
    id: 'nprobe_ret_other', targetUserId: 'par_001', declare: ['par_001'],
  });
  assert.equal(
    crossUser.ok,
    false,
    '写给别人的通知带 RETURNING 会被拒 —— 若这条变成通过，说明读策略被放宽了，'
      + '而那是另一个决定，不能悄悄发生',
  );
  assert.equal(crossUser.code, '42501');

  // 只取一列也一样被拒：卡住的是**行级**可见性，不是列。
  const oneCol = await probeNotifyInsert('stu_001', 'student', {
    id: 'nprobe_ret_id', targetUserId: 'par_001', declare: ['par_001'], returning: 'id',
  });
  assert.equal(oneCol.ok, false, 'returning id 与 returning * 在行级可见性上没有区别');
  assert.equal(oneCol.code, '42501');

  // 对照组：只把收件人换成自己，同样带 RETURNING → 通过。
  // 这一格是关键 —— 它把成因锁在「新行读不出来」而不是「RETURNING 本身有问题」。
  const selfWithReturning = await probeNotifyInsert('stu_001', 'student', {
    id: 'nprobe_ret_self', targetUserId: 'stu_001',
  });
  assert.equal(
    selfWithReturning.ok,
    true,
    '写给自己的通知可读，所以带 RETURNING 也能通过；这一格不成立说明成因判断错了',
  );
});

test('路由：预留端点回 501 not_implemented，而不是 404', async () => {
  const res = await call('POST', '/auth/login-wechat', { body: { code: 'x' } });
  assert.equal(res.status, 501, '回 404 会让人去查「是不是部署漏了这段代码」');
  assert.equal(res.json.error.code, 'not_implemented');
  assert.equal(res.json.error.retryable, false, '「还没做」不该被当成偶发失败去退避重试');
});

test('路由：通知没有客户端写入端点（通知只能由服务端生成）', async () => {
  const res = await call('POST', '/data/notifications', {
    token: stuToken,
    body: { title: '我自己造一条', body: 'x' },
  });
  // 405 而不是 404：这条路**存在但不接受 POST**（只接受 GET）。
  // 让写入这件事没有端点，比「有端点但回 403」更少一个将来被误用的口子 ——
  // 而且 405 把「支持 GET」一并说了出来，排查时不用去翻路由表。
  assert.equal(res.status, 405);
  assert.equal(res.json.error.code, 'method_not_allowed');
  assert.match(res.json.error.message, /GET/);
});
