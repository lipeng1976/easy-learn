import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';

import { createPool } from '../src/db.js';
import { createApp } from '../src/app.js';
import { issueSessionToken } from '../../shared/token.js';

/**
 * 历史数据的**时间窗查询**与**日历月摘要**（`doc/historical-data-plan.md` 阶段 1）。
 *
 * ## 这个文件真正在防的是什么
 *
 * 起因是一条体验问题：「日历只有当周的，没法查历史」。查下去发现真正的窟窿是
 * **查询没有时间窗能力**：`listHomework` 是 `order by due_at desc limit 50`
 * （上限 200），所以**一个学生攒够 200 条作业之后，更早的历史在接口层面就取不到了**。
 * 而界面看起来完全正常 —— 列表显示 50 条，只是那 50 条全是最近的。
 * 这是本项目最典型的静默失败形状：**没有一处报错，功能却已经坏了。**
 *
 * 这个文件用三个「形状」把修法钉住：
 *
 * ① **老数据真的取得到**（正面）。造 250 条跨 2 年的作业 —— 超过 `MAX_LIMIT=200` ——
 *    然后断言：不带时间窗时**恰好**回 50 条且都是最近的；带 2015 年那一年的时间窗时，
 *    **最老那条在里面**。这一条是全部改动存在的理由。
 *
 * ② **不带时间窗时行为一字不变**（兼容）。这是**最重要的一条**，因为它是
 *    「`from`/`to` 不能有默认值」这条规矩的守门人。有人把「最近 90 天」写成默认值，
 *    功能当场看着更好（响应更小、更快），而后果是 90 天前的数据**从结果里消失**，
 *    列表看起来仍然是完整的（它就是不满，页面下方是「暂无更多」），
 *    用户会认为「那段时间没记录」。这条断言会立刻把它变成红色。
 *
 * ③ **反面：越界与乱参数都要报错，不要静默回空**。
 *    `from > to` 回 400 而不是 `items: []` —— 回空的后果是「家长以为那段时间没记录」。
 *    别的学生的数据 → 取不到（且**不是因为他不存在**而取不到，是因为 RLS/R2）。
 *
 * ## 为什么把「不带时间窗 = 50 条」写成 `equal` 而不是 `<=50`
 *
 * `<= 50` 在「默认时间窗是最近 90 天」那种改动下**照样通过**（因为 90 天内就只有
 * 那几十条），于是守门人失效。必须是 `equal(50)`：它同时钉住了「有上限」与
 * 「上限就是 50」两件事，任何把窗口变小的改动都会让这个数字掉下来。
 *
 * ## 为什么造 250 条而不是「几条」
 *
 * 因为**要越界才验得到**。`limit 50` + 只造 60 条数据的话，
 * 「时间窗能取到老数据」这条断言在**没实现时间窗**的代码上也会绿
 * （60 条全在前 50 里，老的那几条本来就在）。
 * 250 条跨 2 年，2015 年那批**必然**落在第 51 条之后 —— 这是判据的可证伪性所在。
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

/** 东八区。所有「本地日 → UTC 瞬时」的换算都由**测试**做（模拟客户端）。 */
const TZ_OFFSET_MINUTES = 480;
const TZ = '+08:00';

/**
 * 「本地日」→ `[那天 00:00, 次日 00:00)` 的两个**带时区**的瞬时。
 *
 * 这是客户端该做的那一步（服务端不做时区推断，见 `coerce.js` 的 `toTimeWindow`）。
 * 测试里也照这个约定走，否则测的就不是真实调用形态。
 */
function localDayWindow(dateStr, tz = TZ) {
  const [y, m, d] = dateStr.split('-').map(Number);
  const next = new Date(Date.UTC(y, m - 1, d + 1));
  const pad = (n) => String(n).padStart(2, '0');
  const nextStr = `${next.getUTCFullYear()}-${pad(next.getUTCMonth() + 1)}-${pad(next.getUTCDate())}`;
  return { from: `${dateStr}T00:00:00${tz}`, to: `${nextStr}T00:00:00${tz}` };
}

/**
 * 种子。刻意**造到超过 `MAX_LIMIT`（200）**，因为「取不到老数据」这件事
 * 只有越界之后才存在 —— 见文件头「为什么造 250 条」。
 *
 * 分布：
 *   · `stu_001` —— 250 条，其中 240 条落在 2026 年、10 条落在 2015 年（**老数据**）；
 *   · `stu_002` —— 3 条，用来验「别的学生的数据取不到」；
 *   · `stu_003` —— 1 条，与 `stu_001`/`stu_002` 都没结伴，验「未结伴的取不到」。
 */
const HOMEWORK_TOTAL = 250;
const HOMEWORK_RECENT = 240;
const HOMEWORK_OLDEST_DATE = '2015-08-15';

/**
 * `listHomework` 的 `MAX_LIMIT` / `DEFAULT_LIMIT`，**手抄**自 `routes/homework.js`。
 *
 * 为什么不 import：那两个是模块私有常量（没 export），而它们**正是被测的口径本身**。
 * 从被测文件里 import 过来会让「有人把 50 改成 30」这类改动**同时改掉断言** ——
 * 判据就跟着被测代码漂了，等于没守。
 * 手抄的代价是「改了就红」，而那恰恰是我们要的：改上限必须是一次**有意识的**决定。
 *
 * 同理 [WORKOUT_LIMIT] 抄自 `routes/workout.js` 的默认 `limit`。
 */
const MAX_LIMIT = 200;
const DEFAULT_LIMIT = 50;

const SEED_USERS = `
  insert into app_user (id, name, role, avatar) values
    ('stu_001', '林小宇', 'student', 'fox'),
    ('stu_002', '林小桐', 'student', 'rabbit'),
    ('stu_003', '别人家的孩子', 'student', 'cat'),
    ('par_001', '王老师', 'parent', 'teacher');

  insert into relationship (id, student_id, parent_id, sender_id, status) values
    ('rel_1', 'stu_001', 'par_001', 'par_001', 'active'),
    ('rel_2', 'stu_002', 'par_001', 'par_001', 'active');
`;

/**
 * 用 `generate_series` 造 250 条作业 —— 逐条 insert 会让这个文件慢到没人愿意跑，
 * 而慢的测试等于没有测试。
 *
 * ⚠️ 日期用**固定的** `2026-xx-xx`，不用 `now()`：
 * 「最老的那条是哪一天」是下面几条断言的核心，用相对时间会让断言
 * （以及那条「最老日期」的反向判据）随运行日期漂移。
 * 唯一的例外是这一批的**排序**依赖 `due_at desc`，而只要这批日期都在
 * 2015 那批之后就够了 —— 不需要跟"今天"有任何关系。
 */
const SEED_HOMEWORK = `
  insert into homework (id, student_id, title, subject, status, due_at)
  select
    'hw_recent_' || (i + 1),
    'stu_001',
    '作业 ' || (i + 1),
    '数学',
    'pending',
    -- 240 条落在 2026-01-01 起的连续 240 天里（第 1 条 = 01-01、
    -- 第 240 条 = 08-28）。用 i * interval '1 day'
    -- 保证两两不同（重复的 due_at 会让「第 51 条是哪一条」变得不确定）。
    --
    -- ⚠️ 同样**从 0 起**（理由见下面老作业那段的说明）：
    -- generate_series 从 1 起会让第 1 条落在 01-02，与注释差一天。
    timestamptz '2026-01-01 09:00:00${TZ}' + (i * interval '1 day')
  from generate_series(0, ${HOMEWORK_RECENT - 1}) as i;

  -- 10 条**最老的**。这 10 条是判据的中心：它们必然排在 250 条里的最后，
  -- 所以「不带时间窗取不到、带了时间窗取得到」这件事在它们身上才成立。
  --
  -- ⚠️⚠️ generate_series(0, 9) —— **从 0 起**，不是 1。
  --
  -- 第一版写的是 (1, 10)，于是「第 i 条 = 起点 + i 天」，第 1 条落在
  -- **08-16** 而不是名字暗示的 08-15。四处断言（单日窗口、月摘要、
  -- 「最老的那条」）都因此差了一天，而报错只说「应恰好回那一天」/「0 !== 1」，
  -- 完全看不出是差一天。同一类错误在 2026 那批上又咬了一次。
  --
  -- 从 0 起之后，第 1 条就**真的**在 HOMEWORK_OLDEST_DATE 那一天，
  -- 常量名与事实一致 —— 否则那个名字迟早会骗到下一个读它的人。
  insert into homework (id, student_id, title, subject, status, due_at)
  select
    'hw_old_' || (i + 1),
    'stu_001',
    '很久以前的作业 ' || (i + 1),
    '语文',
    'finished',
    timestamptz '${HOMEWORK_OLDEST_DATE} 09:00:00${TZ}' + (i * interval '1 day')
  from generate_series(0, 9) as i;

  insert into homework (id, student_id, title, subject, status, due_at) values
    ('hw_other_1', 'stu_002', '同学甲今天的作业', '数学', 'pending',
     timestamptz '2026-09-22 09:00:00${TZ}'),
    ('hw_other_2', 'stu_002', '同学甲昨天的作业', '数学', 'pending',
     timestamptz '2026-09-21 09:00:00${TZ}'),
    -- 这条落在**老数据那一年**里，但没有结伴 —— 所以「按 2015 年查」时
    -- 它必须**不出现**。这是「时间窗不放大范围」的正面证据：
    -- 一个只看时间不看身份的实现会把它带出来。
    ('hw_other_old', 'stu_003', '别人家 2015 年的作业', '英语', 'pending',
     timestamptz '${HOMEWORK_OLDEST_DATE} 09:00:00${TZ}')
`;

/**
 * 运动记录：用来验「第二条端点的时间窗也真的生效」。
 *
 * ⚠️ 要**造过越界量**（105 条 > `listRecords` 的默认 `limit 100`）。
 * 只造三五条的话，「不带时间窗取不到 2015 那两条」这条断言在**没实现时间窗**
 * 的代码上也会绿 —— 因为根本没发生截断。这与作业那批必须造 250 条是同一个理由。
 *
 * `wr_new_*` 用 `now()` 反推，保证它们**永远是最近的**（不会被 2015 那批超过）。
 */
const WORKOUT_LIMIT = 100;
const WORKOUT_RECENT = 105;

const SEED_WORKOUT = `
  insert into workout_record (id, student_id, project, start_at, minutes) values
    ('wr_old_1', 'stu_001', '跑步', timestamptz '2015-08-16 07:00:00${TZ}', 30),
    ('wr_old_2', 'stu_001', '跳绳', timestamptz '2015-08-17 07:00:00${TZ}', 15),
    ('wr_other_1', 'stu_003', '篮球', timestamptz '2015-08-16 07:00:00${TZ}', 40);

  -- 105 条「最近」的记录：从今天往前推，每天一条。
  -- ⚠️ 用 now() 而不是固定日期 —— 这批的作用是「把老数据挤出前 100」，
  -- 只要它们比 2015 那批新就够了，具体是哪天无所谓。
  --
  -- ⚠️⚠️ 上面这句注释里**千万不要**把 now 写成带反引号的代码样式：
  -- 这一段是 JS 模板字符串，注释里的反引号会**提前闭合模板**，
  -- 报错是「SyntaxError: Unexpected identifier」（第一次踩在
  -- i * interval 的那个单引号写法上）。
  -- SQL 注释里不要用 markdown 反引号，这是本文件的硬规矩。
  insert into workout_record (id, student_id, project, start_at, minutes)
  select
    'wr_new_' || i,
    'stu_001',
    '跑步',
    now() - (i * interval '1 day'),
    20
  from generate_series(1, ${WORKOUT_RECENT}) as i;
`;

/**
 * 打卡：`date` 是**纯日期**列，验它不被时区换算影响。
 *
 * ⚠️ `sp_other` 这个「别人家的计划」不是多余的 —— 它是被 `uq_checkin` 逼出来的。
 *
 * `uq_checkin` 是 **`UNIQUE (plan_id, date)`，不含 `student_id`**（见 001_schema.sql:298）。
 * 也就是说「同一个计划的同一天」**全局只能有一行**，不论是谁打的卡。
 * 第一版把 `ck_other` 也挂在 `sp_1` + `2015-08-15` 上（想表达「别人家也有打卡」），
 * 结果与 `ck_1` 的自然键完全相同 → 同一批 values 里自己撞自己：
 *
 *     duplicate key value violates unique constraint "uq_checkin"
 *     detail: Key (plan_id, date)=(sp_1, 2015-08-15) already exists.
 *
 * 症状很值得记：**它整片挂在 `before` 钩子上**（24 条用例每条都报同一句话），
 * 看起来像 24 个独立失败。而顺着「是不是别的文件留下的残留」去查会一无所获 ——
 * 测试库每次都是 `rm -rf` 后重新 initdb 的（见 pg-local.js 的 withLocalPostgres），
 * 根本不存在残留。**先怀疑自己的种子，再去怀疑环境。**
 *
 * 想表达「另一个学生的打卡不可见」，正确做法是**换一个 plan**（换自然键的一半），
 * 而不是换 student_id（它不在约束里）。
 */
const SEED_CHECKIN = `
  insert into study_plan (id, title, status, user_role, student_id) values
    ('sp_1', '每日阅读', 'active', 'student', 'stu_001'),
    ('sp_other', '别人家的计划', 'active', 'student', 'stu_003');

  insert into study_plan_checkin (id, plan_id, student_id, date) values
    ('ck_1', 'sp_1', 'stu_001', date '2015-08-15'),
    ('ck_2', 'sp_1', 'stu_001', date '2026-09-22'),
    ('ck_3', 'sp_1', 'stu_001', date '2026-09-21'),
    -- 与 ck_1 **同一天**，但换了 plan_id —— 所以自然键不撞，
    -- 而 stu_003 没结伴，所以它必须不出现在任何人的结果里。
    ('ck_other', 'sp_other', 'stu_003', date '2015-08-15');
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

/** 取一次单端点的 `items`（断言 200）。 */
async function itemsOf(token, pathname, query = {}) {
  const res = await call('GET', pathname, { token, query });
  assert.equal(
    res.status,
    200,
    `${pathname} 应 200，实际 ${res.status}：${JSON.stringify(res.json)}`,
  );
  return res.json.data.items;
}

before(async () => {
  if (!PG.host || !PG.database) {
    throw new Error(
      '时间窗测试需要 PostgreSQL：请用 `npm test` 运行（它会起本机 PG），'
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
  //
  // ⚠️ **必须把这几张表清干净，不能只靠 `delete from app_user` 的级联。**
  // 这两个表**没有**指向 app_user 的外键（001 里
  // `student_id TEXT NOT NULL DEFAULT ''`，只是个字符串列）——
  // 所以「删账号」不会带走它们，同一个 PG 上先跑过的文件留下的
  // `sp_1` / 打卡行会与本文件的种子撞 `uq_checkin (plan_id, date)`。
  //
  // 症状值得记下来：**它挂在 `before` 钩子上，24 条用例每条都报同一句话**，
  // 看起来像「24 个独立的失败」，实际只有一个原因。
  // 这种「一个前置条件炸掉一整片」的形态要认得出来 ——
  // 先去数「失败数是不是等于用例数」，是的话就直接查前置条件。
  //
  // ## 为什么是「全清」而不是「按 student_id 清」
  //
  // 第一版按 `student_id in ('stu_001', ...)` 清，**没清干净**（仍然撞）。
  // 追下去要花时间，而收益为零：这是测试库，`data.test.js` 本来就是全清打法
  // （见那个文件的 before）。测试里的清理**宁可粗一点** ——
  // 「多删了几行别人的测试数据」的代价是别人自己会重新种，
  // 而「少删了几行」的代价是一整片用例静默地测着别的东西。
  await adminPool.query(`
    delete from study_plan_checkin;
    delete from study_plan;
    delete from workout_record;
    delete from homework;
    delete from relationship;
    delete from app_user;
  `);
  await adminPool.query(SEED_USERS);
  await adminPool.query(SEED_HOMEWORK);
  await adminPool.query(SEED_WORKOUT);
  await adminPool.query(SEED_CHECKIN);

  stu1Token = await sessionFor('stu_001', 'student');
  stu2Token = await sessionFor('stu_002', 'student');
  parentToken = await sessionFor('par_001', 'parent');

  app = createApp({ pool: appPool, authPool, sessionSecret: SECRET });
});

after(async () => {
  await appPool?.end();
  await authPool?.end();
  await adminPool?.end();
});

// ===== ① 老数据真的取得到（这是整个改动存在的理由）=====

test('种子确实越界了：250 条作业超过 MAX_LIMIT（200）—— 否则下面的判据是空的', async () => {
  // 这条断言是**给后面几条铺路的**。少了它，「带时间窗能取到老数据」这件事
  // 在 250 这个数字被改小（比如有人为了跑得快改成 30 条）之后会**静默失效**：
  // 30 条全在前 50 里，老数据本来就能取到，断言照样绿。
  const r = await adminPool.query(
    `select count(*)::int as total,
            count(*) filter (where due_at < timestamptz '2020-01-01')::int as old
       from homework where student_id = 'stu_001'`,
  );
  assert.equal(r.rows[0].total, HOMEWORK_TOTAL, `stu_001 应有 ${HOMEWORK_TOTAL} 条作业`);
  assert.ok(
    r.rows[0].old >= 10,
    '必须有足够多的老数据 —— 否则「带时间窗能取到老数据」验的是不存在的东西',
  );
  assert.ok(
    r.rows[0].total > 200,
    '总条数必须超过 MAX_LIMIT(200)，否则「不带时间窗取不到历史」这个前提不成立',
  );
});

test('不带时间窗：**恰好** 50 条，且全是最近的那一批（守住现状）', async () => {
  // ⚠️ 这是「`from`/`to` 不能有默认值」这条规矩的守门人。
  // 用 `equal(50)` 而不是 `<= 50`：默认窗口一旦被加进来（比如「最近 90 天」），
  // 90 天内只有 240 条里的前 90 条 → 仍然返回 50 条，`<=50` 照样过。
  // 必须同时断言「返回的就是最近的那 50 条」，才能把窗口缩小这件事抓住。
  const items = await itemsOf(stu1Token, '/data/homework');
  assert.equal(items.length, 50, '不传 from/to 时必须仍然是 limit 50（现状）');

  // 「最近的那 50 条」= 按 due_at 倒序的前 50 条。逐条核，别只看长度。
  const expected = await adminPool.query(
    `select id from homework
      where student_id = 'stu_001'
      order by due_at desc nulls last, id
      limit 50`,
  );
  assert.deepEqual(
    items.map((h) => h.id),
    expected.rows.map((r) => r.id),
    '不传时间窗时返回的必须是「按 due_at 倒序的前 50 条」—— 顺序或口径变了就是兼容性被破坏',
  );

  // 老数据**确实不在**里面。这条才是「历史取不到」的直接证据。
  assert.ok(
    !items.some((h) => h.id.startsWith('hw_old_')),
    '2015 年的那批不该出现在「不带时间窗」的结果里 —— 这正是改动前的坏行为',
  );
});

test('带时间窗：能取到 2015 年那批**最老的**（修好之后的核心能力）', async () => {
  // 按「2015 年那十天」查 —— 时间窗能覆盖到最老的那条。
  const { from, to } = localDayWindow(HOMEWORK_OLDEST_DATE);
  // `to` 要覆盖 10 天，所以往后推 10 个本地日。
  const wide = localDayWindow('2015-08-25');
  const items = await itemsOf(stu1Token, '/data/homework', { from, to: wide.to });

  assert.equal(items.length, 10, '2015-08-15 起的 10 条老作业都应当在');
  assert.ok(items.some((h) => h.id === 'hw_old_1'), '**最老的那条必须取得到**');
  assert.ok(items.some((h) => h.id === 'hw_old_10'), '最后一条老作业也应当在');
  // 反面：2026 年那批不该混进来（时间窗是**真的在过滤**，不是「窗口一给就全返回」）。
  assert.ok(
    !items.some((h) => h.id.startsWith('hw_recent_')),
    '2026 年的作业不该出现在 2015 年的时间窗里 —— 否则说明时间窗根本没生效',
  );
});

test('带时间窗：2026 年那批也能按天精确定位（单日窗口只回一条）', async () => {
  // `hw_recent_1` 的到期日 = 种子的起点 `2026-01-01`（种子用 generate_series(0, …)，
  // 所以第 1 条就在起点那天 —— 见种子段的说明）。
  const { from, to } = localDayWindow('2026-01-01');
  const items = await itemsOf(stu1Token, '/data/homework', { from, to });

  assert.equal(items.length, 1, '单日窗口应恰好回那一天的作业');
  assert.equal(items[0].id, 'hw_recent_1');
});

test('带时间窗 + 显式 limit：窗口决定**范围**，limit 决定**条数**（两个维度）', async () => {
  // ⚠️ 这条原本写成「带时间窗就该把 240 条全给我」，**那个期望是错的**。
  // 时间窗只改变**取哪些**，不改变 `limit`（默认 50、上限 200）。
  // 把两件事混在一起会让这条断言看起来在验「时间窗生效」，
  // 实际验的是「时间窗顺手把上限也放开了」—— 而后者是**不想要**的行为：
  // 一次拉全表正是 `MAX_LIMIT` 要防的。
  //
  // 所以这条要验的是**两个维度的独立性**：
  //   · 窗口给得再大，条数仍受 limit 管（默认 50）；
  //   · 显式放大 limit，也确实能拿到更多（说明窗口内的数据**真的**多于 50）。
  //
  // ⚠️ 窗口取 2026-01-01 起 240 天 = 覆盖全部 240 条。
  // 不带 limit → 恰好 50；给 limit=200 → 恰好 200（受 MAX_LIMIT 封顶）。
  const { from } = localDayWindow('2026-01-01');
  const end = localDayWindow('2026-09-30');

  const capped = await itemsOf(stu1Token, '/data/homework', { from, to: end.to });
  assert.equal(
    capped.length,
    DEFAULT_LIMIT,
    '窗口内数据多于 DEFAULT_LIMIT 时，不给 limit 就仍然是 50 —— '
      + '给时间窗**不隐含**把上限放开（一次拉全表是 MAX_LIMIT 要防的）',
  );

  const bigger = await itemsOf(stu1Token, '/data/homework', {
    from,
    to: end.to,
    limit: String(MAX_LIMIT),
  });
  assert.equal(
    bigger.length,
    MAX_LIMIT,
    '显式给 limit=200 时取满 200 条 —— 说明窗口内**确实**有那么多数据，'
      + '否则「不带窗口 50 条」与「带了窗口还是 50 条」就分不出差别了',
  );

  // 超出上限的值被夹到 MAX_LIMIT（而不是报错、也不是照单全收）。
  const huge = await itemsOf(stu1Token, '/data/homework', {
    from,
    to: end.to,
    limit: '9999',
  });
  assert.equal(huge.length, MAX_LIMIT, 'limit 超过上限要被夹住（防一次拉全表）');

  // ⚠️ 反面：`limit=200` 取的是**按 due_at 倒序的前 200 条**，也就是最近的 200 条。
  // 窗口最早那几天（01-01 附近）**取不到** —— 这是 `order by due_at desc` 的必然结果，
  // 也正是「必须能按天/narrow 窗口再查一次」的理由：
  // 想拿某一天的明细，就要把窗口收到那一天，而不是指望大窗口一次拉完。
  assert.ok(
    !bigger.some((h) => h.id === 'hw_recent_1'),
    '大窗口 + limit 200 拿不到窗口最老的那条（它被更新的 200 条挤出去了）—— '
      + '所以「按天取明细」不能省',
  );
});

test('边界是左闭右开：`to` 那一天的 00:00 不含在内', async () => {
  // 查 2026-01-01 **那一天**：`hw_recent_1`（01-01 09:00）在内、
  // `hw_recent_2`（01-02 09:00）不在。窗口是 [01-01 00:00, 01-02 00:00)。
  const { from, to } = localDayWindow('2026-01-01');
  const items = await itemsOf(stu1Token, '/data/homework', { from, to });
  const ids = items.map((h) => h.id);
  assert.deepEqual(ids, ['hw_recent_1']);

  // 把 `to` 改成 01-01 09:00（= `hw_recent_1` 的**到期时刻**）：左闭右开
  // ⇒ `due_at < to` 为 false ⇒ **不返回**。这条把「右开」钉死，
  // 换成右闭（`<=`）的实现会在这里红。
  const half = await itemsOf(stu1Token, '/data/homework', {
    from,
    to: `2026-01-01T09:00:00${TZ}`,
  });
  assert.equal(half.length, 0, '窗口右端是「不含」—— 到期时刻正好等于 to 的那条不该返回');
});

test('只给 from（不给 to）：从中途到最新的全部，仍然受 limit 上限保护', async () => {
  const { from } = localDayWindow('2026-08-01');
  const items = await itemsOf(stu1Token, '/data/homework', { from });
  assert.ok(items.length > 0, '只给 from 是合法用法');
  // 不带 to 时 limit 仍然是 50（默认值），所以这里最多 50 条。
  // 这条是「单个端点是合法用法，但**不隐含**把上限放开」的证据。
  assert.ok(items.length <= 50, '只给 from 时 limit 仍然生效（防止一次拉全表）');
});

// ===== ② 运动记录的时间窗（第二条端点，同样的规矩）=====

test('运动记录：不带时间窗取不到 2015 年那两条，带时间窗取得到', async () => {
  // ⚠️ 第一版只种了 4 条运动记录，然后断言「不带窗取不到 2015 那两条」——
  // 那是**假的**：`listRecords` 的默认 `limit` 是 **100**，4 条根本不会被截断，
  // 所以不带窗时 2015 那两条**本来就在**结果里。那条断言在我自己写的
  // 「这条断言不足以证明问题」自检里当场变红了 —— 这正是它存在的意义。
  //
  // 现在种 105 条近期记录越过 100 的线，于是「越界」这件事**真的**成立：
  // 不带窗只回最近 100 条，2015 那两条必然落在外面。
  const all = await itemsOf(stu1Token, '/data/workouts/records');
  assert.equal(all.length, WORKOUT_LIMIT, '运动列表的默认 limit 是 100');
  assert.ok(
    !all.some((r) => r.id === 'wr_old_1'),
    '105 条近期记录把 2015 那两条挤出了前 100 —— 这才是「历史取不到」',
  );

  const { from } = localDayWindow('2015-08-16');
  const win = localDayWindow('2015-08-18');
  const items = await itemsOf(stu1Token, '/data/workouts/records', { from, to: win.to });
  const ids = items.map((r) => r.id).sort();
  assert.deepEqual(ids, ['wr_old_1', 'wr_old_2'], '2015-08-16/17 那两条应当在窗口里');
  // `wr_other_1` 是同一天、但属于**没结伴的别人** —— 它不该出现。
  // 这条是「时间窗不放大范围」的正面证据（只看时间不看身份的实现会把它带出来）。
  assert.ok(!ids.includes('wr_other_1'), '未结伴学生的记录不该出现在时间窗结果里');
});

// ===== ③ 反面：参数问题要报错，不要静默回空 =====

test('from > to → 400（不是空列表）', async () => {
  const res = await call('GET', '/data/homework', {
    token: stu1Token,
    query: { from: `2026-09-22T00:00:00${TZ}`, to: `2026-09-01T00:00:00${TZ}` },
  });
  assert.equal(res.status, 400, 'from 晚于 to 应报 400 —— 回空会被理解成「那段时间没记录」');
  assert.equal(res.json.ok, false);
});

test('from/to 不带时区 → 400（不按服务端时区猜，避免静默偏一整天）', async () => {
  const res = await call('GET', '/data/homework', {
    token: stu1Token,
    query: { from: '2026-09-01T00:00:00' },
  });
  assert.equal(res.status, 400, '不带时区的时间串必须被拒绝（R3 的教训）');
  assert.equal(res.json.ok, false);
});

// ===== ④ 可见性：时间窗**不放大范围** =====

test('学生看不到别的学生的行（含「同一年、但没结伴」那条）', async () => {
  const { from } = localDayWindow(HOMEWORK_OLDEST_DATE);
  const wide = localDayWindow('2015-08-25');
  const items = await itemsOf(stu1Token, '/data/homework', { from, to: wide.to });
  const ids = items.map((h) => h.id);

  assert.ok(ids.includes('hw_old_1'), '自己的老作业应当在');
  assert.ok(
    !ids.includes('hw_other_old'),
    '别人家 2015 年的作业不该在 —— 时间窗给了也拿不到别人的数据',
  );
});

test('家长按时间窗查：看得到两个结伴孩子的，看不到第三个的', async () => {
  const { from } = localDayWindow(HOMEWORK_OLDEST_DATE);
  const wide = localDayWindow('2015-08-25');
  const items = await itemsOf(parentToken, '/data/homework', { from, to: wide.to });
  const ids = items.map((h) => h.id);

  // 孩子的两条（stu_001 的老作业 + 同一天属于 stu_002 的？没有 —— stu_002 只有 9 月的）
  assert.ok(ids.includes('hw_old_1'), '结伴孩子的老作业家长应当看得到');
  assert.ok(!ids.includes('hw_other_old'), '未结伴孩子的作业家长不该看到');

  // 反向再验一次：家长在两个孩子的集合上按 2026-09-22 查，两个孩子的都在。
  const day = localDayWindow('2026-09-22');
  const today = await itemsOf(parentToken, '/data/homework', day);
  const todayIds = today.map((h) => h.id);
  assert.ok(
    todayIds.includes('hw_other_1'),
    '同一天里，stu_002（另一个结伴孩子）的作业应当在家长的结果里',
  );
});

test('别人的 ticket 拿不到自己的数据（越权反面）', async () => {
  const { from } = localDayWindow(HOMEWORK_OLDEST_DATE);
  const wide = localDayWindow('2015-08-25');
  const items = await itemsOf(stu2Token, '/data/homework', { from, to: wide.to });
  assert.deepEqual(items, [], 'stu_002 在 2015 年没有数据 —— 不该看到 stu_001 的');
});

// ===== ⑤ 日历月摘要 =====

test('月摘要：返回当月每天各几条，只有有数据的天', async () => {
  const res = await call('GET', '/data/calendar/summary', {
    token: stu1Token,
    query: { month: '2026-09', tzOffsetMinutes: TZ_OFFSET_MINUTES },
  });
  assert.equal(res.status, 200, JSON.stringify(res.json));
  assert.equal(res.json.ok, true);

  const { days } = res.json.data;
  assert.ok(Array.isArray(days), 'days 应当是数组');

  // 种子里 2026 那批作业是从 2026-01-01 起连续 240 天 → 最后一天是 2026-08-28。
  // 所以 2026-09 **没有任何作业**；这个月只有打卡（SEED_CHECKIN 的 09-21 / 09-22）。
  // 这正好是一个好用例：**摘要只报有数据的天**，别把 31 天都铺出来。
  assert.ok(
    !days.some((d) => d.homework > 0),
    '2026-09 没有作业（作业那批到 08-28 为止）—— 静默多报说明区间算错了',
  );

  const d22 = days.find((d) => d.date === '2026-09-22');
  assert.ok(d22, '2026-09-22 应当出现在摘要里（那天有打卡）');
  assert.equal(d22.checkin, 1, '那天 1 条打卡');
  assert.equal(d22.homework, 0, '那天没有作业 —— 计数为 0 而不是缺字段');
});

test('月摘要：作业月份的计数与按天明细**互相印证**', async () => {
  // 摘要说某天有 N 条作业，就用明细端点去把这一天拉出来核对。
  // 这条断言防的是「摘要与明细两套口径」—— 日历上打了点、点进去却是空的，
  // 是这一版最可能出的静默 bug（两个端点各写了一遍「那一天」的定义）。
  //
  // ⚠️ **不要写死是哪一天**。第一版写的是 `2026-01-01`，而种子是
  // `2026-01-01 09:00 + i * interval '1 day'`（i 从 1 起）——
  // 所以第一条作业其实在 **01-02**，那天在摘要里根本不存在。
  // 「从摘要里挑一个真有作业的日子」既躲开了这个差一天，
  // 也让这条断言在种子改了之后**依然成立**（它要验的是两套口径一致，
  // 不是「种子第一天在哪」）。
  const res = await call('GET', '/data/calendar/summary', {
    token: stu1Token,
    query: { month: '2026-01', tzOffsetMinutes: TZ_OFFSET_MINUTES },
  });
  assert.equal(res.status, 200);

  const day = res.json.data.days.find((d) => d.homework > 0);
  assert.ok(day, '2026-01 应当至少有一天有作业 —— 否则这条互相印证的断言是空的');

  const { from, to } = localDayWindow(day.date);
  const items = await itemsOf(stu1Token, '/data/homework', { from, to });
  assert.equal(
    items.length,
    day.homework,
    `摘要说 ${day.date} 有 ${day.homework} 条，明细却回了 ${items.length} 条 —— 两套口径漂了`,
  );
  // 反面：明细回来的那几条，到期日本身也必须落在这一天。
  //
  // ⚠️ 第一版这里写的是 `items.every((h) => h.dueAt.startsWith(day.date) || true)` ——
  // 那个 `|| true` 让整条断言**恒真**，等于没写。凡是「加了兜底就永远通过」的断言，
  // 都是把自己写给自己的心理安慰。判据必须能红。
  //
  // 断言用 `items.length > 0` 前置保证它非空（上面的 equal 已经保证，
  // 但这里显式写出来，免得以后有人改了上面那条之后这条静默失效）。
  assert.ok(items.length > 0, '这一天应当真的取得到明细');
  for (const h of items) {
    assert.ok(
      h.dueAt.startsWith(day.date),
      `${h.id} 的到期日 ${h.dueAt} 不在摘要说的 ${day.date} —— 两端点对「那一天」的定义漂了`,
    );
  }
});

test('月摘要：没有数据的天**不返回**（调用方据此判断空月）', async () => {
  const res = await call('GET', '/data/calendar/summary', {
    token: stu1Token,
    query: { month: '2015-09', tzOffsetMinutes: TZ_OFFSET_MINUTES },
  });
  assert.equal(res.status, 200);
  // 2015 年 9 月没有任何数据 —— 空数组是「这个月没有」，不是错误。
  assert.deepEqual(res.json.data.days, [], '没有数据的月份返回空数组（客户端据此显示空态）');
});

test('月摘要：2015 年那个月有数据（打点的正面证据）', async () => {
  const res = await call('GET', '/data/calendar/summary', {
    token: stu1Token,
    query: { month: '2015-08', tzOffsetMinutes: TZ_OFFSET_MINUTES },
  });
  assert.equal(res.status, 200);
  const day = res.json.data.days.find((d) => d.date === '2015-08-15');
  assert.ok(day, '2015-08-15 应当有打点（1 条作业 + 1 条打卡）');
  assert.equal(day.homework, 1);
  assert.equal(day.checkin, 1, '打卡那一列是 DATE，不该被时区换算挪走');
  assert.equal(day.workout, 0, '那天没有运动记录 —— 计数为 0 而不是缺字段');
});

test('月摘要：负偏移把东八区早上的记录推到**前一天**（时区切日真的在生效）', async () => {
  // `hw_old_1` 的到期时刻 = 2015-08-15 09:00+08:00 = 2015-08-15 01:00Z。
  // 用 −12:00 的偏移看：墙上时间 = 2015-08-14 13:00 → 落在 **08-14**。
  // 这就是「服务端不猜时区」的价值：换个偏移，打点就换一天，而且是对的。
  const res = await call('GET', '/data/calendar/summary', {
    token: stu1Token,
    query: { month: '2015-08', tzOffsetMinutes: -12 * 60 },
  });
  assert.equal(res.status, 200);
  const { days } = res.json.data;

  const d14 = days.find((d) => d.date === '2015-08-14');
  assert.ok(
    d14,
    '在 UTC−12 下，08-15 09:00+08:00 那批应当落到 08-14 —— 说明切日用的是传上来的偏移',
  );
  assert.equal(d14.homework, 1, '作业那一条挪到了 08-14');

  // ⚠️ **08-15 仍然有数据，而且是「两类混在一起」的** —— 这条不是「顺手加的反面」，
  // 它正是「两个来源的处置不同」的现场证据：
  //   · 作业的 `due_at` 是 TIMESTAMPTZ，要**换算到墙上时间**再切日 → 跟着偏移走；
  //   · 打卡的 `date` 是 DATE，语义就是「学生所在的那一天」→ **不换算**。
  //
  // 具体到这天（偏移 −12:00，比 +08:00 少 20 小时）：
  //   · `hw_old_1`（08-15 09:00+08:00）→ 08-14 13:00 → 挪到 **08-14**；
  //   · `hw_old_2`（08-16 09:00+08:00）→ 08-15 13:00 → 落在 **08-15** ← 就是它；
  //   · `ck_1`（DATE 2015-08-15）→ 不动，仍在 **08-15**。
  // 所以 08-15 = 1 条作业 + 1 条打卡。
  //
  // ⚠️ 第一版这里写的是「不该同时出现 08-15」（预期 homework=0）——**那个期望是错的**，
  // 我漏算了「整批数据都会整体前移一天，于是原本属于 08-16 的那条压到 08-15」。
  // 教训：偏移一变，**整批**行一起动，不能只盯着「第一条挪到哪儿」。
  const d15 = days.find((d) => d.date === '2015-08-15');
  assert.ok(d15, '打卡那行是 DATE、不换算，所以 08-15 依然存在');
  assert.equal(d15.checkin, 1, '08-15 的打卡没被偏移挪走');
  assert.equal(
    d15.homework,
    1,
    '原本 08-16 的那条作业在 −12:00 下压到了 08-15（整批一起前移一天）',
  );

  // 反向钉住「整批都挪了」：偏移下 08-25 那天不该再有作业
  // （+08:00 下 `hw_old_10` 在 08-24，−12:00 下它在 08-23）。
  assert.ok(
    !days.some((d) => d.date === '2015-08-25'),
    '−12:00 下没有哪条落在 08-25 —— 说明整批都动了，不是只动了第一条',
  );
});

test('月摘要：month 形制不对 → 400', async () => {
  for (const month of ['2026-9', '2026-13', '202609', 'abc', '']) {
    const res = await call('GET', '/data/calendar/summary', {
      token: stu1Token,
      query: { month, tzOffsetMinutes: TZ_OFFSET_MINUTES },
    });
    assert.equal(res.status, 400, `month=「${month}」应当 400`);
  }
});

test('月摘要：不给 tzOffsetMinutes → 400（服务端不猜时区）', async () => {
  const res = await call('GET', '/data/calendar/summary', {
    token: stu1Token,
    query: { month: '2026-09' },
  });
  assert.equal(res.status, 400, '缺 tzOffsetMinutes 必须报错 —— 兜底一个 UTC 就是静默偏一整天');
  assert.match(res.json.error.message, /tzOffsetMinutes/);
});

test('月摘要：越界学生 → 403（不是空摘要，也不是 404）', async () => {
  // `stu_003` 没跟 `par_001` 结伴。
  //
  // ⚠️ 期望是 **403 不是 404** —— 第一版我按「不存在的资源」写了 404，跑出来是 403。
  // 服务端这里走的是 `requireVisibleStudent`（`src/auth.js`），它对全仓所有端点
  // 统一抛 **forbidden**：这个学生**确实存在**，只是不在你的可见集合里。
  // 语义上 403 才对（「我知道你是谁，但这不是你的」），而且与写操作的归属校验
  // **同一个函数、同一个状态码** —— 读和写用两套码会让客户端要处理两遍。
  //
  // 更要紧的是这条断言**防的那个静默失败**：如果越界时回一个空摘要，
  // 家长会以为「那个孩子这个月没数据」，而不是「我没权限看那个孩子」。
  // 空摘要与「真的没数据」长得一模一样 —— 所以必须是错误，且不能被压成 200。
  const res = await call('GET', '/data/calendar/summary', {
    token: parentToken,
    query: { month: '2015-08', tzOffsetMinutes: TZ_OFFSET_MINUTES, studentId: 'stu_003' },
  });
  assert.equal(res.status, 403, '越界学生应 403（与写操作的归属校验同一个口径）');
  // 响应体里**不能**有 days —— 有的话调用方可能把它当成「这个月是空的」。
  assert.equal(res.json.data, undefined, '错误响应里不该带 data.days 那种「看起来像结果」的字段');
});

test('月摘要：家长挑一个结伴孩子，摘要只算那个孩子', async () => {
  // `stu_002` 只有 2 条 9 月作业、没有 2015 年的数据。挑他查 2015-08 应为空。
  const mine = await call('GET', '/data/calendar/summary', {
    token: parentToken,
    query: { month: '2015-08', tzOffsetMinutes: TZ_OFFSET_MINUTES, studentId: 'stu_002' },
  });
  assert.equal(mine.status, 200);
  assert.deepEqual(mine.json.data.days, [], 'stu_002 在 2015-08 没有数据');

  // 同一个家长、同一个月，挑 stu_001 则有数据 —— 证明 studentId 真的在收窄。
  const other = await call('GET', '/data/calendar/summary', {
    token: parentToken,
    query: { month: '2015-08', tzOffsetMinutes: TZ_OFFSET_MINUTES, studentId: 'stu_001' },
  });
  assert.equal(other.status, 200);
  assert.ok(other.json.data.days.length > 0, '挑选另一个孩子后有数据 —— studentId 确实生效');
});

test('月摘要：无票 → 401', async () => {
  const res = await call('GET', '/data/calendar/summary', {
    query: { month: '2026-09', tzOffsetMinutes: TZ_OFFSET_MINUTES },
  });
  assert.equal(res.status, 401);
});

// ===== ⑥ 索引真的建上了（§3.3：索引是判据的一部分）=====

test('009 迁移建上了三个时间索引（缺了就是 seq scan 兜底）', async () => {
  const r = await adminPool.query(
    `select indexname from pg_indexes
      where schemaname = 'public'
        and indexname in (
          'idx_homework_student_due_at',
          'idx_review_mistake_student_last_wrong',
          'idx_study_plan_student_start_at'
        )
      order by indexname`,
  );
  assert.deepEqual(
    r.rows.map((x) => x.indexname),
    [
      'idx_homework_student_due_at',
      'idx_review_mistake_student_last_wrong',
      'idx_study_plan_student_start_at',
    ],
    '三个时间索引必须存在 —— 时间窗查询靠它们，见 sql/009_history_time_indexes.sql',
  );
});
