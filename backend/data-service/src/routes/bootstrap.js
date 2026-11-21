import { ErrorCodes, toApiError } from '../../../shared/errors.js';
import { translateDbError } from '../db.js';
import * as homework from './homework.js';
import * as notification from './notification.js';
import * as points from './points.js';
import * as relationship from './relationship.js';
import * as review from './review.js';
import * as studyPlan from './study_plan.js';
import * as wish from './wish.js';
import * as workout from './workout.js';

/**
 * 首屏聚合读（P2-2）。
 *
 * ## 它解决的问题
 *
 * 学生端首页要读 18 次、家长端更多（且随结伴孩子数**乘着涨**：照片与公开心愿
 * 是**按孩子逐个请求**的）。这些读在本机实测出来是 18 次往返 —— 本机往返
 * 0.2ms，所以没人会注意到；换到手机上（一次往返 60ms 起）它就是一个
 * 「点了登录要等一下才出东西」的量级。这个数字由 `tools/walkthrough-cloud.mjs`
 * 量出来并当成判据盯着（`build/demo-evidence/first-screen-requests.json`）。
 *
 * ## 硬约束一：每一段必须复用各路由**同一个** handler
 *
 * 这是本文件唯一不能妥协的设计。聚合端点最容易写坏的形态是
 * 「顺手在聚合里再写一遍 `select ... from homework`」—— 那一刻起
 * 「我能看到哪些作业」就有了两份实现，而它们会漂。
 * 漂的表现不是报错，是**同一个账号在首页看到的和点进去看到的不一样**。
 *
 * 所以下面每一段都是 `(client, ctx, query) => 那个路由导出的函数`，
 * **没有一行自己的 SQL**。`test/bootstrap.test.js` 把「逐行一致」钉成断言。
 *
 * ## 硬约束二：分段必须用 SAVEPOINT 隔离
 *
 * PG 里**一条语句失败会让整个事务进入 aborted 状态**，之后连 `COMMIT` 都被拒
 * （`current transaction is aborted, commands ignored until end of transaction block`）。
 * 所以「一段失败、其余照常」在 PG 里不是加个 try/catch 就行的 ——
 * 必须回滚到 savepoint 才能继续查下一段。
 *
 * 少了 savepoint 的后果很具体：某一张表因为一个历史数据问题查不出来，
 * 整个首屏变成**空白**，而失败原因只在那一条 error 里 —— 比聚合之前还差
 * （以前至少只有那一个模块是空的）。这是本项目最典型的静默失败形状，
 * 所以隔离是必须的，不是优化。
 *
 * ## 硬约束三：失败必须在响应里**逐段如实说出来**
 *
 * 每一段都带 `ok`。失败的段把 `code` / `message` 原样带出来（错误码是协议的一部分，
 * 见 `shared/errors.js`），并且段名同时汇总进顶层 `failed` 数组 —— 客户端
 * 只要看 `failed` 非空就知道「这次首屏有一部分是缺的」，不必逐段去遍历。
 *
 * 为什么不能「失败的段就当它是空列表」：那样「这个孩子真的没有错题」和
 * 「错题这一段查失败了」在客户端**长得一模一样**，而处置完全相反。
 * 这正是本项目反复出现的那类 bug（见 `doc/需求规格说明书.md` 的「静默失败清单」）。
 */

/**
 * 段定义。三种作用域，差别只在**用哪个 ctx 去跑同一个 handler**：
 *
 * - `broad` —— 一次，覆盖本次请求可见的全部学生（`ctx.students`）。
 *   「我能看到谁」由 token 推导，客户端传不了；
 * - `perStudent` —— 每个可见学生各跑一次，结果按学生 id 分桶。
 *   存在这一档是因为客户端**真的有按孩子逐个请求的循环**
 *   （家长端的照片与公开心愿），把整份数据按学生分桶带回去，
 *   那些循环就各自命中自己那一份；
 * - `narrow` —— 一次，只跑「当前正在看的那个孩子」。
 *   积分账本与分值属于「选中的孩子」而不是「全部孩子」，多带没有意义。
 *
 * ⚠️ `query` 参数只用来表达**口径**（scope / limit），**从来不表达权限** ——
 * 权限永远是 `ctx.students`。这两件事混在一起是陷阱⑥的形态：
 * 一旦某个 handler 从 `query.studentId` 取范围，越界就只差一个没写的 where。
 */
const SECTIONS = [
  // ===== 宽表：与「不带参数的对应端点」逐行一致 =====
  {
    name: 'relationship',
    scope: 'broad',
    run: (client, ctx) => relationship.listRelationships(client, ctx),
  },
  {
    name: 'homework',
    scope: 'broad',
    run: (client, ctx) => homework.listHomework(client, ctx, {}),
  },
  {
    name: 'notifications',
    scope: 'broad',
    run: (client, ctx) => notification.queryNotifications(client, ctx),
  },
  {
    name: 'workoutPlans',
    scope: 'broad',
    run: (client, ctx) => workout.listPlans(client, ctx, {}),
  },
  {
    name: 'workoutRecords',
    scope: 'broad',
    run: (client, ctx) => workout.listRecords(client, ctx, {}),
  },
  {
    name: 'reviewMistakes',
    scope: 'broad',
    run: (client, ctx) => review.listMistakes(client, ctx, {}),
  },
  {
    name: 'reviewPapers',
    scope: 'broad',
    run: (client, ctx) => review.listPapers(client, ctx),
  },
  {
    name: 'reviewAttempts',
    scope: 'broad',
    run: (client, ctx) => review.listAttempts(client, ctx, {}),
  },
  {
    name: 'reviewPractice',
    scope: 'broad',
    run: (client, ctx) => review.listPractice(client, ctx, {}),
  },
  {
    name: 'reviewSummaries',
    scope: 'broad',
    run: (client, ctx) => review.listSummaries(client, ctx),
  },
  {
    name: 'reviewExplains',
    scope: 'broad',
    run: (client, ctx) => review.listExplains(client, ctx, {}),
  },
  {
    name: 'studyPlans',
    scope: 'broad',
    run: (client, ctx) => studyPlan.listPlans(client, ctx, {}),
  },
  {
    name: 'studyPlanCheckins',
    scope: 'broad',
    run: (client, ctx) => studyPlan.listCheckins(client, ctx, {}),
  },
  {
    name: 'dailyComments',
    scope: 'broad',
    run: (client, ctx) => notification.queryDailyComments(client, ctx),
  },
  {
    name: 'wishesCreated',
    scope: 'broad',
    run: (client, ctx) => wish.listWishes(client, ctx, { scope: 'created' }),
  },
  {
    name: 'wishesUnfulfilled',
    scope: 'broad',
    run: (client, ctx) => wish.listWishes(client, ctx, { scope: 'unfulfilled' }),
  },

  // ===== 按学生分桶：对应客户端「按孩子循环」的两处 =====
  {
    name: 'homeworkImages',
    scope: 'perStudent',
    // 对应 `queryHomeworkImages(childId)`，即 `/data/homework/images?studentId=<孩子>`。
    // handler 本身只认 `ctx.students`，所以「挑一个孩子」是靠**收窄 ctx** 表达的。
    run: (client, ctx) => homework.listHomeworkImages(client, ctx, {}),
  },
  {
    name: 'wishesPublic',
    scope: 'perStudent',
    // 对应 `queryPublicWishesByStudent(childId)`。
    run: (client, ctx) => wish.listWishes(client, ctx, { scope: 'public' }),
  },

  // ===== 只跑「当前看着的那个孩子」 =====
  {
    name: 'pointLedger',
    scope: 'narrow',
    run: (client, ctx) => points.queryLedger(client, ctx, {}),
  },
  {
    name: 'pointRules',
    scope: 'narrow',
    run: (client, ctx) => points.listRules(client, ctx, {}),
  },
];

/**
 * 只把 ctx 的**学生范围**换掉，其余（role / userId / visibleStudents / now …）原样带着。
 *
 * 刻意不新建一个 ctx 对象：handler 里用到的字段有七八个，逐个重新拼一遍的结果是
 * 「今天忘了带 `now`、明天忘了带 `role`」，而症状分散在各段里。
 * 收窄范围是这件事**唯一**的意图，所以只碰那一个字段。
 *
 * `visibleStudents` 跟着一起收窄而不是留全集：`requireVisibleStudent` 之类
 * 的校验读的是它，两者不一致时会得到「能读到数据但写不了」这种半截状态。
 */
function scopeTo(ctx, studentId) {
  return { ...ctx, students: [studentId], visibleStudents: [studentId] };
}

/**
 * 跑一段，把它和其余段**隔开**。
 *
 * 这里唯一的技术要点是 savepoint：见文件头「硬约束二」。
 * 名字用递增序号而不是段名 —— 段名里有大写字母和点（`reviewMistakes`），
 * 直接拼进 SQL 会因为大小写折叠与非法字符出问题，而那是**为了可读性引入的 bug**。
 */
let savepointSeq = 0;

async function guarded(client, name, run) {
  const sp = `sp_boot_${(savepointSeq += 1)}`;
  await client.query(`savepoint ${sp}`);
  try {
    const value = await run();
    // 释放 savepoint 不是为了省内存（PG 里 savepoint 很便宜），
    // 是为了**不要在长事务里留下成千上万个嵌套层级** —— 一次聚合有 20 段。
    await client.query(`release savepoint ${sp}`);
    return { ok: true, value };
  } catch (e) {
    // ⚠️ 必须 `rollback to`，不能只 catch。事务此刻是 aborted 的，
    // 不回滚那么下一段的 `savepoint` 语句自己就会被拒 ——
    // 于是「一段失败」会升级成「从那一端起后面全失败」，而错误信息里
    // 说的是 `current transaction is aborted`，指的却是**上一段**的问题。
    await client.query(`rollback to savepoint ${sp}`);
    return { ok: false, error: sectionError(e, name) };
  }
}

/**
 * 段的失败信息。形状与 `ApiError.toEnvelope()` 的内层一致，客户端因此
 * 不需要为「聚合里的失败」单独写一套解析。
 *
 * ## 为什么先过一遍 `translateDbError`
 *
 * app.js 那条路是 `errorResponse(translateDbError(e), …)`。这里若直接用
 * `toApiError(e)`，**同一次失败会因为走没走聚合而得到不同的错误码**：
 * 例如数据库连不上时单端点是 `db_unavailable`，聚合里却是 `internal`。
 * 客户端对这两者的处置不同（前者可重试），于是「首页那次读可以自动重试、
 * 点进去那次不行」这种莫名其妙的差异就有了来源。
 *
 * `toApiError` 兜住非 ApiError 的异常：直接 `String(e)` 会把 PG 的堆栈或
 * SQL 片段漏给客户端，而客户端拿它什么都做不了。
 */
function sectionError(e, name) {
  const translated = translateDbError(e);
  const err = toApiError(translated);
  const out = { code: err.code, message: err.message, retryable: err.retryable };
  // `details` 是照片那条路区分「旧数据要回退本地读」与「文件真没了」的唯一依据
  // （见 `routes/homework.js`）。聚合里没有照片**字节**，但保留这条传递，
  // 免得将来某段用到它时被这里悄悄吃掉。
  if (err.details !== undefined) out.details = err.details;

  // **服务端必须留下痕迹**。请求本身是 200（其余段是好的），所以 app.js 的
  // catch 永远不会看到这条失败 —— 不打日志的话，「某一段一直在失败」这件事
  // 只存在于客户端的响应里，服务端日志干干净净。而这是最难查的一类问题：
  // 用户报「首页有时候少一块」，你去翻日志，什么都没有。
  if (err.code === ErrorCodes.internal) {
    console.error(`[bootstrap] 段 ${name} 失败:`, translated);
  }
  return out;
}

/**
 * @param {object} client 已带 RLS 身份的连接（事务已开）
 * @param {object} ctx `withRequestContext` 建的上下文，`students` 已按 `?studentId=` 收窄
 */
export async function readBootstrap(client, ctx) {
  const students = Array.isArray(ctx.students) ? ctx.students : [];
  // 一个可见学生都没有 = 账号还没结伴 / 家长还没有孩子。
  // 这不是错误：照常返回空段，客户端走「暂无数据」那条路。
  const actingStudentId = students[0] ?? '';

  const sections = {};
  const failed = [];

  for (const section of SECTIONS) {
    if (section.scope === 'broad') {
      const r = await guarded(client, section.name, () => section.run(client, ctx));
      sections[section.name] = r.ok
        ? { ok: true, items: listOf(r.value) }
        : { ok: false, error: r.error };
      if (!r.ok) failed.push(section.name);
      continue;
    }

    if (section.scope === 'narrow') {
      if (actingStudentId === '') {
        // 没有「当前学生」时给一个空段，而不是 `{ok:false}`：
        // 这不是一次失败，是「这个账号当前没有孩子可看」。
        sections[section.name] = { ok: true, items: [] };
        continue;
      }
      const r = await guarded(client, section.name, () => section.run(client, scopeTo(ctx, actingStudentId)));
      sections[section.name] = r.ok
        ? { ok: true, items: listOf(r.value) }
        : { ok: false, error: r.error };
      if (!r.ok) failed.push(section.name);
      continue;
    }

    // perStudent
    const byStudent = {};
    for (const sid of students) {
      const r = await guarded(client, `${section.name}:${sid}`, () => section.run(client, scopeTo(ctx, sid)));
      byStudent[sid] = r.ok
        ? { ok: true, items: listOf(r.value) }
        : { ok: false, error: r.error };
      // 失败的段名带上学生 id：家长有两个孩子时，「哪个孩子的照片读不出来」
      // 是排查的第一句话，而只写 `homeworkImages` 会让它变成一句要重新查的疑问。
      if (!r.ok) failed.push(`${section.name}:${sid}`);
    }
    sections[section.name] = { ok: true, byStudent };
  }

  return {
    actingStudentId,
    students,
    sections,
    failed,
  };
}

/**
 * 段里的行数组。
 *
 * 各 handler 都返回 `{items: [...]}`（`sections` 之外没有第二种形状），
 * 所以这里统一取 `items`；万一某段返回了别的形状，给空数组而不是 `undefined` ——
 * 客户端那侧 `data['items'] is! List → const []` 是同一条约定的另一半。
 */
function listOf(value) {
  const items = value?.items;
  return Array.isArray(items) ? items : [];
}
