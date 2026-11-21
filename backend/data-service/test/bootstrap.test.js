import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';

import { createPool } from '../src/db.js';
import { createApp } from '../src/app.js';
import { issueSessionToken } from '../../shared/token.js';

/**
 * 首屏聚合读（P2-2）的验收。
 *
 * ## 这个文件真正在防的是什么
 *
 * 聚合端点有**两种**坏法，而它们都很安静：
 *
 * ① **悄悄长出第二份实现**。有人为了图快，在 `bootstrap.js` 里直接写一句
 *    `select ... from homework`，而不是转调 `routes/homework.js`。功能当场是好的，
 *    测试也过 —— 直到某天有人改了单端点那条（加了 `limit`、改了可见性口径），
 *    于是**首屏看到的和点进去看到的不是同一份数据**。
 *    → 所以这里的判据是「**逐行等价**」：每一段必须与对应单端点返回的那一份
 *      完全一致，而不是「看起来差不多」。
 *
 * ② **一段失败拖垮全部**。PG 的一条语句失败会让事务 aborted，之后连 COMMIT 都被拒。
 *    没有 savepoint 的话，一张表的权限问题会让整个首屏变成空白 —— 而它**只有一条
 *    error 可看**，客户端那边表现为「什么都没读到」。这比不做聚合还差。
 *    → 所以这里**真的制造一次失败**（收回一张表的 SELECT 权限，得到 42501，
 *      正是本项目在真实环境里见过的那个错），再断言其余段照常返回。
 *
 * 跑法：`npm test`（先起本机 PG 再执行本文件）。
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

let stu1Token;
let stu2Token;
let parentToken;

/**
 * 段名 → 对应**单端点**的 (方法, 路径)。这张表就是「等价」这个词的定义。
 *
 * ⚠️ 下面有一条断言盯着「这张表覆盖了响应里出现的每一个段名」。
 * 少了它，服务端新加一段而这里忘了补，会得到一次**静默的漏检**：
 * 新段没人对照，但它看起来一切正常。
 */
const BROAD_EQUIV = {
  relationship: '/data/relationship',
  homework: '/data/homework',
  notifications: '/data/notifications',
  workoutPlans: '/data/workouts/plans',
  workoutRecords: '/data/workouts/records',
  reviewMistakes: '/data/review/mistakes',
  reviewPapers: '/data/review/papers',
  reviewAttempts: '/data/review/attempts',
  reviewPractice: '/data/review/practice',
  reviewSummaries: '/data/review/summaries',
  reviewExplains: '/data/review/explains',
  studyPlans: '/data/study-plans',
  studyPlanCheckins: '/data/study-plans/checkins',
  dailyComments: '/data/daily-comments',
  wishesCreated: '/data/wishes',
  wishesUnfulfilled: '/data/wishes',
};

/** 段名 → 单端点路径 + 每个学生各自的 query。 */
const PER_STUDENT_EQUIV = {
  homeworkImages: (sid) => ['/data/homework/images', { studentId: sid }],
  wishesPublic: (sid) => ['/data/wishes', { scope: 'public', studentId: sid }],
};

/** 段名 → 单端点路径（作用于「当前看着的那个孩子」）。 */
const NARROW_EQUIV = {
  pointLedger: (sid) => ['/data/points/ledger', { studentId: sid }],
  pointRules: (sid) => ['/data/points/rules', { studentId: sid }],
};

/** 宽表段里需要带 query 才能与聚合对上的那两条。 */
const BROAD_QUERY = {
  wishesCreated: { scope: 'created' },
  wishesUnfulfilled: { scope: 'unfulfilled' },
};

const SEED = `
  insert into app_user (id, name, role, avatar) values
    ('stu_001', '林小宇', 'student', 'fox'),
    ('stu_002', '林小桐', 'student', 'rabbit'),
    ('stu_003', '别人家的孩子', 'student', 'cat'),
    ('par_001', '王老师', 'parent', 'teacher');

  insert into relationship (id, student_id, parent_id, sender_id, status) values
    ('rel_1', 'stu_001', 'par_001', 'par_001', 'active'),
    ('rel_2', 'stu_002', 'par_001', 'par_001', 'active');

  insert into homework (id, student_id, title, subject, status) values
    ('hw_1', 'stu_001', '语文作业', '语文', 'pending'),
    ('hw_2', 'stu_002', '数学作业', '数学', 'pending'),
    ('hw_3', 'stu_003', '别人的作业', '英语', 'pending');

  insert into homework_image
    (id, student_id, homework_id, storage_key, file_name, file_size, mime_type, ocr_status, ocr_text, sort_order) values
    ('img_1', 'stu_001', 'hw_1', 'students/stu_001/homework/a.jpg', 'a.jpg', 1024, 'image/jpeg', 'done', '', 0),
    ('img_2', 'stu_002', 'hw_2', 'students/stu_002/homework/b.jpg', 'b.jpg', 2048, 'image/jpeg', 'done', '', 0);

  insert into wish (id, title, is_public, student_id, user_role, point_cost) values
    ('w_1', '想要一本课外书', true,  'stu_001', 'student', 20),
    ('w_2', '想要一个足球',   false, 'stu_001', 'student', 30),
    ('w_3', '想要一盒彩笔',   true,  'stu_002', 'student', 10),
    ('w_4', '别人家的心愿',   true,  'stu_003', 'student', 5),
    -- 两条**家长发起**的心愿。scope=created 是「我这一侧发起的」，
    -- 按 user_role = ctx.role 筛 —— 只种学生那两条的话，家长拿到的
    -- 永远是一个空列表，而看起来像是聚合漏了这一段。
    ('w_5', '爸爸许的：去动物园', false, 'stu_001', 'parent', 40),
    ('w_6', '妈妈许的：学游泳',   false, 'stu_002', 'parent', 50);

  insert into point_ledger (id, student_id, action, points, reason, idempotency_key) values
    ('pl_1', 'stu_001', 'homework_done', 5, '完成作业', 'k1'),
    ('pl_2', 'stu_001', 'checkin',      3, '打卡',     'k2'),
    ('pl_3', 'stu_002', 'checkin',      3, '打卡',     'k3');

  insert into point_rule (student_id, action, points) values
    ('stu_001', 'checkin', 4),
    ('stu_002', 'checkin', 2);

  -- 与 wish 同一类种子缺口：listPlans 对家长按 user_role = ctx.role 筛
  -- （学生侧传 null、看自己的全部；家长只看自己发的）。只种学生发起的两条，
  -- 家长那边**永远是空列表**，而空列表与空列表也「逐行一致」——
  -- 等价断言会静静通过，什么都验不到。所以学生侧与家长侧各两条。
  insert into study_plan (id, title, status, user_role, student_id) values
    ('sp_1', '每日阅读', 'active', 'student', 'stu_001'),
    ('sp_2', '每日口算', 'active', 'student', 'stu_002'),
    ('sp_3', '爸爸定的：背单词', 'active', 'parent', 'stu_001'),
    ('sp_4', '妈妈定的：练字',   'active', 'parent', 'stu_002');

  insert into daily_comment (id, rating, content, student_id) values
    ('dc_1', 'good', '今天很认真', 'stu_001');
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

/** 取一次聚合。返回 `data` 部分（`{actingStudentId, students, sections, failed}`）。 */
async function bootstrap(token, query = {}) {
  const res = await call('GET', '/data/bootstrap', { token, query });
  assert.equal(res.status, 200, `聚合端点应 200，实际 ${res.status}：${JSON.stringify(res.json)}`);
  assert.equal(res.json.ok, true);
  return res.json.data;
}

/** 取一次单端点的 `items`。 */
async function itemsOf(token, pathname, query = {}) {
  const res = await call('GET', pathname, { token, query });
  assert.equal(res.status, 200, `${pathname} 应 200，实际 ${res.status}`);
  return res.json.data.items;
}

before(async () => {
  if (!PG.host || !PG.database) {
    throw new Error(
      '聚合端点测试需要 PostgreSQL：请用 `npm test` 运行（它会起本机 PG），'
        + '或提供 TEST_PG_HOST / TEST_PG_DATABASE 等环境变量指向已有实例。',
    );
  }

  adminPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.adminUser, password: PG.adminPassword, max: 2,
  });
  appPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.appUser, password: PG.appPassword, max: 4,
  });
  authPool = createPool({
    host: PG.host, port: PG.port, database: PG.database,
    user: PG.authUser, password: PG.authPassword, max: 2,
  });

  // 对「在同一个 PG 上重复运行」幂等：先清后插。
  // 删 app_user 会级联删掉会话行，所以下面的 sessionFor 不会撞上过期会话。
  await adminPool.query(`
    delete from point_ledger;
    delete from point_rule;
    delete from homework_image;
    delete from daily_comment;
    delete from study_plan;
    delete from wish;
    delete from homework;
    delete from relationship;
    delete from app_user;
  `);
  await adminPool.query(SEED);

  stu1Token = await sessionFor('stu_001', 'student');
  stu2Token = await sessionFor('stu_002', 'student');
  parentToken = await sessionFor('par_001', 'parent');

  app = createApp({ pool: appPool, authPool, sessionSecret: SECRET });
});

after(async () => {
  // 失败注入那一条会把权限收掉，这里兜底恢复 —— 否则**同一轮里排在后面的测试文件**
  // 会莫名其妙地查不到 wish，而错误信息指向的是那边的代码。
  await adminPool.query('grant select on wish to app_rls').catch(() => {});
  await appPool?.end();
  await authPool?.end();
  await adminPool?.end();
});

// ===== ① 逐段等价 =====

test('宽表段与对应单端点**逐行一致**（学生）', async () => {
  const data = await bootstrap(stu1Token);
  for (const [name, path] of Object.entries(BROAD_EQUIV)) {
    const single = await itemsOf(stu1Token, path, BROAD_QUERY[name] ?? {});
    assert.deepEqual(
      data.sections[name].items,
      single,
      `段 ${name} 与 ${path} 不一致 —— 说明聚合里长出了第二份查询实现`,
    );
  }
});

test('宽表段与对应单端点**逐行一致**（家长）', async () => {
  const data = await bootstrap(parentToken);
  for (const [name, path] of Object.entries(BROAD_EQUIV)) {
    const single = await itemsOf(parentToken, path, BROAD_QUERY[name] ?? {});
    assert.deepEqual(data.sections[name].items, single, `段 ${name} 与 ${path} 不一致`);
  }
});

test('按学生分桶的段逐个孩子都与单端点一致', async () => {
  const data = await bootstrap(parentToken);
  assert.deepEqual(data.students.slice().sort(), ['stu_001', 'stu_002']);

  for (const [name, pick] of Object.entries(PER_STUDENT_EQUIV)) {
    for (const sid of data.students) {
      const [path, query] = pick(sid);
      const single = await itemsOf(parentToken, path, query);
      assert.deepEqual(
        data.sections[name].byStudent[sid].items,
        single,
        `段 ${name} 的 ${sid} 桶与 ${path} 不一致`,
      );
    }
  }
});

test('narrow 段对「当前这个孩子」与单端点一致', async () => {
  const data = await bootstrap(parentToken, { studentId: 'stu_002' });
  // 显式挑了 stu_002，它就应当是「当前看着的那个」
  assert.equal(data.actingStudentId, 'stu_002');
  assert.deepEqual(data.students, ['stu_002']);

  for (const [name, pick] of Object.entries(NARROW_EQUIV)) {
    const [path, query] = pick('stu_002');
    const single = await itemsOf(parentToken, path, query);
    assert.deepEqual(data.sections[name].items, single, `段 ${name} 与 ${path} 不一致`);
  }
});

test('每一条有数据的段都**不是空的**（否则上面的等价是 []===[]，什么都没验到）', async () => {
  // 这条判据是为了让「等价」这个断言有分量：种子里的 homework / wish /
  // point_ledger / homework_image / study_plan 都有行，若哪天种子被清掉，
  // 上面对照会**全部退化成空列表之间的比较，永远通过**。
  const data = await bootstrap(parentToken);
  assert.ok(data.sections.homework.items.length >= 2, 'homework 段应有种子数据');
  assert.ok(data.sections.wishesCreated.items.length >= 2, 'wishesCreated 段应有种子数据');
  assert.ok(data.sections.studyPlans.items.length >= 2, 'studyPlans 段应有种子数据');
  assert.ok(
    data.sections.homeworkImages.byStudent.stu_001.items.length >= 1,
    'homeworkImages 的 stu_001 桶应有种子数据',
  );
  assert.ok(data.sections.pointLedger.items.length >= 1, 'pointLedger 段应有种子数据');
});

// ===== ② 可见性（两级都要，缺一半就都能过）=====

test('学生看不到别的学生的行（正面：自己的在；反面：别人的不在）', async () => {
  const data = await bootstrap(stu1Token);
  const hwIds = data.sections.homework.items.map((h) => h.id);
  assert.ok(hwIds.includes('hw_1'), '自己的作业应当在');
  assert.ok(!hwIds.includes('hw_2'), '同学的作业不该在');

  // 反面同时打在「连桶都不该有」上：学生只有一个可见学生，
  // 所以按学生分桶的段只应出现自己那一个桶。
  assert.deepEqual(data.students, ['stu_001']);
  assert.deepEqual(Object.keys(data.sections.homeworkImages.byStudent), ['stu_001']);
  assert.equal(data.sections.homeworkImages.byStudent.stu_002, undefined);
});

test('家长看得到结伴的两个孩子，看不到未结伴的第三个', async () => {
  const data = await bootstrap(parentToken);
  const hwIds = data.sections.homework.items.map((h) => h.id);
  assert.ok(hwIds.includes('hw_1') && hwIds.includes('hw_2'), '两个结伴孩子的作业都应在');
  assert.ok(!hwIds.includes('hw_3'), '未结伴孩子的作业不该在');

  const wishIds = data.sections.wishesPublic.byStudent.stu_001.items.map((w) => w.id);
  assert.ok(wishIds.includes('w_1'), '公开心愿应在');
  assert.ok(!wishIds.includes('w_2'), '非公开心愿不该出现在 public 口径里');
});

test('不带票 → 401（可见性判据必须配这个反面，否则「永远放行」也能过）', async () => {
  const res = await call('GET', '/data/bootstrap');
  assert.equal(res.status, 401);
  assert.equal(res.json.ok, false);
});

test('越界的 studentId → 403，而不是「查不到数据的 200」', async () => {
  const res = await call('GET', '/data/bootstrap', {
    token: parentToken,
    query: { studentId: 'stu_003' },
  });
  assert.equal(res.status, 403);
  assert.equal(res.json.error.code, 'forbidden');
});

// ===== ③ 一段失败不拖垮其余 =====

test('一段查不动时：其余段照常返回，失败那一段**如实上报**', async () => {
  // 真的制造一次失败，而不是 mock 一个异常：
  // 收回 app_rls 对 wish 的 SELECT，于是三段 wish 相关的段会得到
  // **42501 permission denied** —— 正是本项目在真实环境里见过的那种错
  // （PG 被强杀后重启的那一小段窗口，见 doc/open-items.md §D）。
  await adminPool.query('revoke select on wish from app_rls');
  try {
    const data = await bootstrap(parentToken);

    // 失败的段：两段 wish 相关的都在 failed 里被点到名（public 那段按学生展开）
    assert.ok(data.failed.includes('wishesCreated'), `failed 应含 wishesCreated：${data.failed}`);
    assert.ok(data.failed.includes('wishesUnfulfilled'));
    assert.ok(
      data.failed.some((f) => f.startsWith('wishesPublic:')),
      `failed 应含 wishesPublic:<学生>：${data.failed}`,
    );
    assert.equal(data.sections.wishesCreated.ok, false);
    assert.equal(data.sections.wishesCreated.error.code, 'internal');

    // **其余段必须照常** —— 这一半才是 savepoint 存在的理由。
    // 没有 savepoint 时事务已 aborted，下面每一条都会连着失败。
    assert.equal(data.sections.homework.ok, true);
    assert.ok(data.sections.homework.items.length >= 2, 'homework 段应当仍有数据');
    assert.equal(data.sections.studyPlans.ok, true);
    assert.equal(data.sections.homeworkImages.byStudent.stu_001.ok, true);
    assert.equal(data.sections.pointLedger.ok, true);

    // 失败段之外的段名一个都不该进 failed
    for (const name of ['homework', 'notifications', 'studyPlans', 'pointRules']) {
      assert.ok(!data.failed.includes(name), `${name} 不该被标成失败`);
    }
  } finally {
    await adminPool.query('grant select on wish to app_rls');
  }

  // 恢复之后再取一次：全绿。这是对上面那次失败是**注入出来的**的对照 ——
  // 少了它，「wish 本来就没数据」也能让上面那些断言通过。
  const healed = await bootstrap(parentToken);
  assert.deepEqual(healed.failed, [], '恢复权限后不应有任何失败段');
  assert.ok(healed.sections.wishesCreated.items.length >= 2);
});

// ===== ④ 这张对照表自己不能过期 =====

test('响应里的每一个段名都被本文件的对照表覆盖', async () => {
  const data = await bootstrap(parentToken);
  const covered = new Set([
    ...Object.keys(BROAD_EQUIV),
    ...Object.keys(PER_STUDENT_EQUIV),
    ...Object.keys(NARROW_EQUIV),
  ]);
  const actual = Object.keys(data.sections);
  const uncovered = actual.filter((n) => !covered.has(n));
  assert.deepEqual(
    uncovered,
    [],
    `这些段没有对应的等价断言：${uncovered.join('、')} —— `
      + '新加一段就要在 BROAD_EQUIV / PER_STUDENT_EQUIV / NARROW_EQUIV 里补一条，'
      + '否则它会永远没人对照，而表面上一切正常',
  );
  assert.equal(actual.length, covered.size, '对照表里有已经不存在的段名');
});
