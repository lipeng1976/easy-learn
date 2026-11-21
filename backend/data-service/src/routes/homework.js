import {
  ApiError,
  ErrorCodes,
  badRequest,
  forbidden,
  notFound,
  storageQuotaExceeded,
} from '../../../shared/errors.js';
import { UserRoles } from '../../../shared/token.js';
import { MAX_COUNT, kindOfMime, labelOfKind, maxBytesFor } from '../attachments.js';
import { requireVisibleStudent } from '../auth.js';
import { binaryResponse } from '../http.js';
import { isServerImageKey } from '../imagestore.js';
import { newId, pick, rowToApi, rowsToApi } from '../mapper.js';
import { buildUpdate, changedTs, emptyPatchResult } from '../patch.js';
import { toBool, toInt, toText, toTimeWindow, toTs, requireText } from '../coerce.js';
import { notifyBoundPartners, parentIdsOf, NotificationTypes } from './notify.js';
import { deleteMistakesByHomework } from './review.js';
import { maybeResizeResponse } from './image_resize.js';

/**
 * 作业与作业照片。
 *
 * ## 这个文件里最重要的一件事：端点是**按 Repository 接口**列的，不是按业务动作
 *
 * 迁移计划 §4.3 当初给作业列了 `submit` 和 `check` 两个写端点。核过客户端代码后
 * **删掉了它们** —— 因为 `HomeworkRepository` 里根本没有这两个方法：
 *
 *   · 「提交作业」在 `StudentController.submitHomework` 里是**一次
 *     `updateHomework(patch)`**，掩码由控制器逐字段拼出来
 *     （status / submittedAt / submitBatchId / imageCount / imageUrl / needsGrading
 *      + `clearResult()`）；
 *   · 「批改完成」同样是**一次 `updateHomework(patch)`**
 *     （status / checkedAt / score / summary / wrongCount / gradingSource）。
 *
 * 也就是说这两件事是 **L1 的业务动作**，而 L2 只提供「按掩码写回」。
 * 照着业务动作去建端点的后果是：**服务端要把 L1 的规则抄一遍**，
 * 于是「什么时候算提交完成」「什么情况清空批改结果」有了两份实现，
 * 而它们一定会漂 —— 漂的表现是家长端看到的分数与孩子端不一致。
 *
 * 所以这里只有 `update`（掩码），没有 `submit` / `check`。
 * 同理一开始**没有 `delete`**：那时本地实现里没有删作业这条路（只有删它的照片），
 * 计划里那个 `delete` 是把「觉得该有」写成了「有」。
 * ⚠️ 后来它被**真的加上了**（2026-09-28，见 `deleteHomework`）——
 * 因为识别录入会认错字、也会把同一份作业认两遍，而录入之后没有删除动作可用。
 * 这条历史留着是因为它示范了一件事：**「当时没有」不等于「永远不该有」，
 * 但也不等于「现在就该照着计划补」** —— 补它的依据是需求变了，不是计划里写着。
 *
 * ## 掩码的线格式（与 `HomeworkPatch.toMap()` 逐字对应）
 *
 *     POST /data/homework/update  { "id": "hw_1", "score": null, "summary": "", "gradingSource": "" }
 *
 * **键出现 = 这次要写它**；值为 `null` = 写成 NULL。没出现的键一个字都不动。
 * `clearResult()` 产出的正是这种「显式空值」，所以「重新提交后清掉上一次的分数」
 * 在网络边界上是**保得住**的（陷阱 ② 的正面解，见 patch.js 的长注释）。
 */

/**
 * **新建**时可写的字段。
 *
 * ⚠️ 它与下面的 `PATCH_SPEC`（**更新**时可写）**刻意不同，不是漏配**。
 * 判据是「这个值由谁决定」：新建时 `title` / `subject` / `dueAt` 由客户端给，
 * 所以在这里；更新时哪些能改另有一套（见 `PATCH_SPEC` 的注释），
 * 一旦把两张表当成「应该一致」去对齐，整行覆盖的守卫就没了。
 */
const WRITABLE = [
  'title',
  'subject',
  'dueAt',
  'estimatedMinutes',
  'needsGrading',
  'aiEnabled',
  'summary',
  'imageUrl',
];

/**
 * `HomeworkPatch` 的字段 → 列 + 类型强制。
 *
 * 三类值要特别处理，都是**本地实现留下的形态**，不处理就会写坏数据或报难懂的错：
 *   · `needsGrading` —— `HomeworkPatch` 把它写成 `1/0`（SQLite 没有布尔），
 *     所以 `toBool` 必须接受数字；
 *   · 4 个 `NOT NULL DEFAULT ''` 的列 —— 客户端可能送 `null` 表示「写空」，
 *     而这一列的语义空值是**空串不是 NULL**（全库都依赖这个，见 DDL 约定③）；
 *   · `checkedAt` / `score` —— 这两个**必须能真的写成 NULL**，
 *     它们是「还没有批改结果」的唯一表达。
 */
const PATCH_SPEC = {
  // ⚠️ `title` / `subject` 是 2026-09-29 加的，**之前刻意没有**。
  //
  // `WRITABLE`（上面）是「**新建**时可写」，这里才是「**更新**时可写」——
  // 两者本来就该不同，不是漏配。当初把这两个排除在外，正是为了让
  // `assertKnownFields()` 拦住「客户端把整个作业对象发上来」那种整行覆盖
  // （那类误发一定同时带着 title / subject / dueAt）。
  //
  // 但守得太宽的代价是**存完就再也改不了**：拍照识别会认错字
  // （`练字→练习` 在 25 次实测里错 19 次，见 `doc/open-items.md` B27），
  // 学生在核对表单里能改，可一旦点了「确认保存全部」才发现错了，
  // 出路只剩「删了重录」。所以现在放开这两个。
  //
  // ⭐ **判据是「这个值由谁决定」**，不是「它属于哪张表」：
  // 标题与科目是**学生的输入**，本来就该可改；而 `dueAt` / `status` /
  // 批改结果是由**服务端或别的动作**决定的，客户端不该顺手写它们。
  // ⚠️ 所以整行覆盖的守卫**仍然有效** —— 一次误发整个作业对象照样 400
  // （它会带上 `dueAt` 这类不在表里的键）。收窄的只是「哪些算客户端的输入」。
  title: (v, f) => requireText(v, f),
  subject: (v, f) => requireText(v, f),
  status: (v, f) => textOrNull(v, f),
  wrongCount: (v, f) => toInt(v, f),
  imageUrl: (v, f) => toText(v) ?? '',
  submittedAt: (v, f) => toTs(v, f),
  checkedAt: (v, f) => toTs(v, f), // null 原样穿过 = 清空
  score: (v, f) => toInt(v, f), // 同上
  summary: (v, f) => toText(v) ?? '',
  imageCount: (v, f) => toInt(v, f),
  submitBatchId: (v, f) => toText(v) ?? '',
  gradingSource: (v, f) => toText(v) ?? '',
  needsGrading: (v, f) => toBool(v, f),
  // 作业的实际用时（秒）。**整份覆盖**，不是增量 —— 增量在重试下会重复累加，
  // 而「时间莫名变多」在界面上只是看起来像计时器算错了，没有任何报错。
  //
  // 负数直接 400：它在这一列里没有语义，写进去只会让「用时」出现一个
  // 说不通的数（客户端显示成 `-00:01:00`）。`null` 归 0，而不是写 NULL ——
  // 这一列是 `NOT NULL DEFAULT 0`，放过 null 会换来一次 500，
  // 而调用方根本表达不出「用时为空」这个意图。
  actualSeconds: (v, f) => {
    const n = toInt(v, f);
    if (n === null) return 0;
    if (n < 0) throw badRequest(`${f} 不能是负数（收到 ${n}）`);
    return n;
  },
};

function textOrNull(v, field) {
  if (v === null || v === undefined) return null;
  return requireText(v, field);
}

// 允许写入的状态值。
//
// ⚠️ `'timeout'` 是**历史遗留**：客户端从 2026-09-28 起不再产生它
// （那个状态废弃了 —— 它的触发条件 `now > dueAt` 里 dueAt 取的是
// 「打开作业页那一刻」，导致录入即「已超时」，见 `doc/open-items.md` B26）。
// 这里**刻意保留**：库里还躺着这个值的行，白名单一旦收窄，任何一次
// 「原值回写」的更新都会变成 400，而那会表现成「某份老作业改不动」。
// 客户端读出来会把它归一到「待完成」（`HomeworkStatus.parse`）。
const STATUSES = ['pending', 'checking', 'needFix', 'finished', 'timeout'];

const MAX_LIMIT = 200;
const DEFAULT_LIMIT = 50;

function clampLimit(raw) {
  const n = Number(raw ?? DEFAULT_LIMIT);
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_LIMIT;
  return Math.min(Math.floor(n), MAX_LIMIT);
}

/** 列表。
 *
 * 注意 `student_id = any($1)` 这行 —— 它**同时**做了两件事：
 *   ① 把过滤下推到数据库（而不是取全表回来在 JS 里筛）；
 *   ② 让「能看谁」由**服务端算出的集合**决定，客户端传什么都只是在这集合里挑。
 *
 * 即便如此，RLS 仍然在下面兜着底：$1 里若混进了不该有的 id，
 * policy 也会把它们挡掉。两层不是重复，是「显式意图」+「不可绕过的边界」。
 *
 * ⚠️ 这里**没有 `userRole == 'student' ? 全表 : 过滤` 那种分支**（陷阱⑥的形态）。
 * 客户端 `queryHomework(userRole)` 与 `queryHomeworkByStudentIds(ids)` 两个方法
 * 在服务端合并成一条查询：范围的来源只有一个 —— token 推导出的可见集合。
 *
 * ## 时间窗（可选）—— 「历史取不到」的修法
 *
 * 加 `from` / `to` 之前，这个函数是 `order by due_at desc limit 50`：
 * **一条作业存够 200 条（MAX_LIMIT）之后，更早的历史在接口层面就再也取不到**，
 * 而界面看起来一切正常（显示 50 条，只是那 50 条全是最近的）。
 * 这不是「慢」，是**结构性取不到** —— 典型的静默失败。
 * 完整的分析见 `doc/historical-data-plan.md` §1.3。
 *
 * 三条硬约束：
 *
 * ① **`from` / `to` 没有默认值**（`toTimeWindow` 里写死了这条）。给个「最近 90 天」
 *    当默认，是把「取不到」从慢/报错换成**静默地少数据**，比不改还坏。
 * ② **不传时间窗 = 现有行为逐字不变**（`limit 50`、`order by due_at desc`）。
 *    有一条断言专门守着这个兼容性，见 `test/calendar.test.js` 的
 *    「不带时间窗时行为与改动前完全一致」——有人加了默认窗口，那条会立刻红。
 * ③ **`limit` 仍然 clamp**。加了时间窗之后它的角色变了：不再是「取多少条历史」，
 *    而是「防止某一天数据异常多时把响应撑爆」。上限一个字没动。
 *
 * 时区：`due_at` 是 TIMESTAMPTZ，而「那一天」是用户所在时区的日。
 * **换算由客户端做**（它知道自己在哪个时区），传上来的是
 * `[本地日 00:00, 次日 00:00)` 对应的**两个 UTC 瞬时**；
 * 服务端只做 `due_at >= from and due_at < to`，**不做任何时区推断**。
 * 这条是被 R3 教出来的：「时间上行不带时区 → 服务端按服务端时区解释 →
 * 静默偏一整天」，所以 `toTs` 会拒绝没有时区的时间串。
 */
export async function listHomework(client, ctx, query) {
  const status = query?.status ? String(query.status) : null;
  if (status !== null && !STATUSES.includes(status)) {
    throw badRequest(`status 只能是 ${STATUSES.join(' / ')} 之一`);
  }

  const { from, to } = toTimeWindow(query);

  const r = await client.query(
    `select id, student_id, title, subject, status, due_at, estimated_minutes,
            actual_seconds,
            needs_grading, ai_enabled, wrong_count, score, summary,
            image_count, submit_batch_id, grading_source,
            submitted_at, checked_at
       from homework
      where student_id = any($1::text[])
        and ($3::text is null or status = $3)
        and ($4::timestamptz is null or due_at >= $4)
        and ($5::timestamptz is null or due_at < $5)
      order by due_at desc nulls last, id
      limit $2`,
    [ctx.students, clampLimit(query?.limit), status, from, to],
  );
  return { items: rowsToApi(r.rows) };
}

/**
 * 新建。
 *
 * R2（id 服务端生成）与「归属不可自报」两条都在这里落地：
 * 客户端送来的 id 直接忽略，studentId 必须落在可见集合里。
 */
export async function createHomework(client, ctx, body) {
  const studentId = requireVisibleStudent(ctx.visibleStudents, body.studentId);
  const fields = pick(body, WRITABLE);

  const r = await client.query(
    // ⚠️ `wrong_count` 显式写 0，而不是留给列默认值 —— 这是**对账脚本抓到的
    // 第一处真实差异**：本地 `insertHomework` 写 `wrongCount: 0`，而这里原来
    // 根本没把这一列列进 insert，于是同一份操作在服务端留下 NULL、在本地留下 0。
    //
    // 客户端目前读不出差别（`_homeworkFromMap` 有 `?? 0` 兜底），所以它**不会**
    // 表现为一个 bug —— 但「同一个逻辑值在两条链路存成不同东西」是真技术债：
    // 哪天服务端自己读这一列做统计（错题数、班级汇总），NULL 会当场变成一个
    // 数不到 0 的分母。对账的价值恰好在这里：它看见的是**存储层**，不是界面。
    `insert into homework (
       id, student_id, title, subject, image_url, due_at, estimated_minutes,
       needs_grading, ai_enabled, summary, status,
       wrong_count, image_count, submit_batch_id, grading_source
     ) values (
       $1, $2, $3, $4, $5, $6, $7,
       coalesce($8, true), $9, coalesce($10, ''), $11,
       0, 0, '', ''
     )
     returning *`,
    [
      newId(),
      studentId,
      fields.title ?? null,
      fields.subject ?? null,
      fields.imageUrl ?? null,
      toTs(fields.dueAt, 'dueAt'),
      fields.estimatedMinutes ?? null,
      toBool(fields.needsGrading, 'needsGrading'),
      toBool(fields.aiEnabled, 'aiEnabled'),
      fields.summary ?? null,
      // status 由服务端定：客户端传什么都无所谓，新作业一律从 pending 开始。
      'pending',
    ],
  );
  return { item: rowToApi(r.rows[0]) };
}

/**
 * 按掩码局部更新（`updateHomework(patch)`）。
 *
 * ## 这里有一道**只有服务端能做**的守卫：拒绝不认识的字段
 *
 * 掩码规则是「键出现就写」。它有个反直觉的失效模式：**客户端把整个作业对象
 * 发上来**（`jsonEncode(item.toMap())` 那种顺手写法）时，`title` / `subject` /
 * `dueAt` 全都会出现在 body 里，于是它们被当成掩码一起写回去 ——
 * 那不是「改坏了几个字段」，而是**整行覆盖**（连 `dueAt` 都覆盖成本地那份缓存值）。
 *
 * 而它不报错、看起来完全成功。所以 `assertKnownFields()` 会把
 * 「出现了不该出现的字段」变成一次 400。**这是把一类静默数据损坏换成一句报错。**
 */
export async function updateHomework(client, ctx, body) {
  const id = requireText(body.id, 'id');
  const mask = stripKeys(body, ['id']);

  const unknown = assertKnownFields(mask, PATCH_SPEC);
  if (unknown.length > 0) {
    throw badRequest(
      `这些字段不能通过本端点写：${unknown.join('、')}。`
        + '本端点是「字段掩码」语义：只接受 HomeworkPatch 的字段，且**键出现即要写** —— '
        + '把整个作业对象发上来会变成一次整行覆盖。',
    );
  }

  const update = buildUpdate({
    // 作用域同时靠 student_id 与 RLS：前者是显式意图，后者是不可绕过的边界。
    table: 'homework',
    spec: PATCH_SPEC,
    body: mask,
    where: 'id = $1 and student_id = any($2::text[])',
    whereValues: [id, ctx.students],
  });
  // 空掩码不是错误：接口契约写明「调用方应跳过、实现要容忍」。
  if (!update) return { ...emptyPatchResult(), id };

  // 先读一次旧行 —— **必须在 UPDATE 之前**，因为这段读只有一个用途：
  // 和更新后的行比较，看这次是不是一次**真实的状态变化**。
  //
  // 两条更省事的写法都不行：
  //   · 只看「掩码里有没有 submittedAt」→ 一次网络超时后的重试会**再通知一遍**
  //     （重试送的是同一份掩码，键当然还在）；
  //   · 用 `RETURNING` 连带取旧值 → PG 的 RETURNING 只能给新行，要取旧值得把
  //     `buildUpdate` 改写成 `WITH old AS (…) UPDATE … FROM old`，
  //     那会让一个通用的「拼 UPDATE」工具塞满这一处的特例。
  //
  // 比较「实际变了没有」而不是「客户端送了什么」，正好把重试挡在外面 ——
  // 与本项目「幂等靠可观察的状态，而不是靠客户端的自觉」是同一条思路。
  const before = await client.query(
    `select * from homework where id = $1 and student_id = any($2::text[])`,
    [id, ctx.students],
  );
  if (before.rowCount === 0) throw forbidden('找不到这份作业（或无权修改）');

  // 两次查询之间不会有别的写插进来：`withRequestContext` 已经开了事务，
  // 而 PG 默认隔离级别（READ COMMITTED）下这次 UPDATE 会取行锁。
  const r = await client.query(update.text, update.values);
  if (r.rowCount === 0) throw forbidden('找不到这份作业（或无权修改）');
  const next = r.rows[0];

  await emitHomeworkNotifications(client, ctx, before.rows[0], next, update.touched);

  return { updated: true, touched: update.touched, item: rowToApi(next) };
}

/**
 * 删除一份作业 —— 连同它的照片行与它带出来的错题，**一次事务**。
 *
 * ## 为什么当初「没有这个端点」是对的，而现在要做
 *
 * 文件头写过「计划里那个 `delete` 是把『觉得该有』写成了『有』」——
 * 那时核过 `HomeworkRepository`，里面确实只有「删它的照片」，没有删作业。
 * 现在它是**真实需求**：拍照识别会认错字，也会把同一份作业认两遍，
 * 而录入之后能做的只有一个「清空照片」，作业本身删不掉。
 *
 * ## 三张表为什么必须一起删，而且必须在这里删
 *
 * `homework` **没有任何外键指向它**（全库只有三条外键，都指 `app_user` /
 * `app_notification`）。所以「删掉作业行」不会级联任何东西，留下的是
 * **查不出来的孤儿**：照片行还在（配额照算）、错题还在错题本里
 * （点进去那个「来源作业」指向一份不存在的作业）。这类脏数据不报错，
 * 只让统计与配额慢慢偏掉 —— 与「清理遗留账号」是同一个坑。
 *
 * 反过来让客户端编排三次调用（删错题 / 删照片 / 删作业）同样是错的：
 * 中途断网留下的是**半截删除**，而界面上看不出删到了哪一步。
 * 单端点 + 单事务是唯一能说清「要么全删、要么全不删」的形状。
 *
 * 错题那条**复用 `review.deleteMistakesByHomework`**，不在这里重抄级联：
 * 它删的是 5 张表（错题 + 作答记录 + 判定影子 + 举一反三 + 讲解）。
 * 两处各写一份的话，「删一道错题要动哪几张表」就有了两个答案。
 *
 * ## 刻意不做的两件事
 *
 * - **盘上的照片字节不删**：理由与 `deleteHomeworkImages` 一字不差 ——
 *   删文件是文件系统 IO，而这段跑在 PG 事务里，回滚时文件已经没了。
 * - **已发出的积分与通知不撤回**：`point_ledger` 是账本，撤一笔会让余额
 *   与流水对不上；通知是「当时确实发生过」的凭据。两者都不按作业反查，
 *   所以删作业不会让它们报错 —— 积分流水存的是 `reason` 文本，
 *   通知点击是跳到对应 tab 而不是跳到那一条。
 *
 * ## 谁能删
 *
 * **只有学生本人**，两道：角色闸（家长 token 直接 403）+ 可见集合
 * （别人的作业查不到 ⇒ 也是 403）。家长端刻意不给这个入口，
 * 而服务端确实拦得住 —— 光靠界面不给按钮只是一条没人盯着的约定。
 */
export async function deleteHomework(client, ctx, body) {
  const id = requireText(body.id, 'id');

  // 角色闸：**这是学生端才有的动作**（家长端刻意不给入口）。
  //
  // 只在界面上不给入口是不够的 —— 家长自己的 `ctx.students` 就是
  // **孩子的可见集合**（`resolveVisibleStudents`），少了这一道，
  // 家长 token 可以直接删掉孩子的作业，而「家长端没有这个按钮」
  // 只是一条**界面约定**，没有任何东西盯着它。
  //
  // 与 `revoke`（只有家长能解除结伴）同一条口径：越界的那一方拿到 403，
  // 而不是「静默什么都没做」。
  if (ctx.role !== UserRoles.student) {
    throw forbidden('只有学生可以删除自己的作业');
  }

  // 再确认它在**我的可见集合**里。不确认直接删的话，客户端会以为删成功了，
  // 而它可能一行都没删掉 —— 界面上表现为「那条还在」，或「刷新之后又回来了」。
  const owned = await client.query(
    `select id, title from homework where id = $1 and student_id = any($2::text[])`,
    [id, ctx.students],
  );
  if (owned.rowCount === 0) throw forbidden('找不到这份作业（或无权删除）');

  // 顺序有讲究：错题必须**趁作业行还在的时候**按 homework_id 找出来 ——
  // 反过来的话，`review_mistake.homework_id` 就再也关联不上任何东西了。
  const mistakes = await deleteMistakesByHomework(client, ctx, { homeworkId: id });

  const images = await client.query(
    `delete from homework_image
      where student_id = any($1::text[]) and homework_id = $2`,
    [ctx.students, id],
  );

  const gone = await client.query(
    `delete from homework where id = $1 and student_id = any($2::text[])`,
    [id, ctx.students],
  );

  // 把「删掉了什么」如实回给客户端：只回一个 `deleted: true` 的话，
  // 「删了 1 份作业」与「其实什么都没匹配上」在响应里长得一模一样。
  return {
    deleted: true,
    id,
    title: owned.rows[0].title ?? '',
    homework: gone.rowCount,
    images: images.rowCount,
    mistakes: mistakes.mistakes,
    cascaded: mistakes.deleted,
  };
}

// ===== 事件 → 通知（陷阱⑦的服务端落点）=====
//
// 本地的「提交作业」「批改完成」两条通知是由**学生那台设备**写进本机的库的
// （`student_controller.dart` 的 `_notifyParents`）。两台手机之后那行通知
// 在家长手机上根本不存在 —— 所以它必须在这里生成。少了它，S4 把客户端切到
// 服务端的那一刻，家长端的通知会**静默消失**（没有报错，只是再也不来消息了）。

/**
 * 三条口径与 `HomeworkGradingMode.of` 逐字对应（`lib/models/homework_model.dart:88`）。
 *
 * ⚠️ 这是一处**刻意的重复**：那个方法是纯函数，输入就是这一行的
 * `needs_grading` / `ai_enabled` 两个持久化列，所以服务端能算出完全相同的结果。
 * 不重复的代价是家长收不到这半句话 —— 而客户端注释写明它「是家长判断
 * 『要不要等批改』的唯一依据」：少了它，家长会去等一个永远不来的结果。
 *
 * 之所以敢重复：它是**三行的纯函数**，而不是一条会漂的业务规则。
 * 若 `HomeworkGradingMode` 将来新增档位，这里要一起改（两处都写明了指回对方）。
 */
function gradingTail(hw) {
  if (!hw.needs_grading) return '这类作业不需要批改。';
  return hw.ai_enabled ? '正在批改。' : '当前未开启 AI 批改。';
}

function photoClause(batch, total) {
  if (batch <= 0) return '（本次未上传照片）';
  return total === batch
    ? `，本次上传 ${batch} 张照片`
    : `，本次上传 ${batch} 张照片（累计 ${total} 张）`;
}

/** 某次提交带了几张照片（`batch_id = 本次的 submit_batch_id`）。 */
async function photoCounts(client, homeworkId, batchId) {
  const r = await client.query(
    `select count(*)::int as total,
            count(*) filter (where batch_id = $2)::int as batch
       from homework_image
      where homework_id = $1`,
    [homeworkId, batchId ?? ''],
  );
  const total = r.rows[0].total;
  // `submit_batch_id` 为空时无法区分「本次」与「以往」（客户端只在提交路径上设它）。
  // 此时把全部照片算作本次 —— 如实反映「这一行现在挂着这些照片」，
  // 而不是报一句「本次未上传照片」去否认它们的存在。
  return { batch: batchId ? r.rows[0].batch : total, total };
}

/** 掩码里出现这些键，才可能构成「一次批改结果的写入」。 */
const GRADING_KEYS = ['status', 'checkedAt', 'score', 'summary', 'wrongCount', 'gradingSource'];

/**
 * 按**可观察到的状态变化**决定要不要生成通知。
 *
 * ## 为什么不能照抄本地实现的「通知失败不影响主流程」
 *
 * 本地 `_notifyParents` 用 try/catch 吞掉投递失败（`student_controller.dart:751`），
 * 理由是「通知投递失败不应影响提交主流程」。**这个写法在服务端是错的**：
 * 这几条 INSERT 跑在同一个 PG 事务里，而一条语句失败会让事务进入 aborted 状态 ——
 * 之后连 COMMIT 都会被拒（`current transaction is aborted`）。
 * 所以「吞掉异常继续」在这里不构成容错，只会把一次说清楚的失败
 * 变成一次更难懂的失败。
 *
 * 因此这里不做 try/catch，而是保证**收件人在结构上不可能被 policy 拒绝**：
 *   · 学生 → 自己的家长（`parentIdsOf` 只取关系已成立的行，`vocab.js` 的 `active`）；
 *   · 学生 → 自己（`target_user_id = 当前 userId`，policy 的第一条分支）；
 *   · 家长代改 → 自己的孩子 / 另一位家长（都是 bound partner）。
 * 而「一个都没结伴」的账号拿到的是**空收件人列表** → 一条都不插、也不抛
 * （见 notify.js）。于是「最不该失败的那一步」不会因为通知而失败。
 */
async function emitHomeworkNotifications(client, ctx, before, after, touched) {
  const title = after.title ?? '作业';

  // ① 提交：`submitted_at` 从「没有」或「另一个时刻」变成一个时刻。
  if (touched.includes('submittedAt') && changedTs(before.submitted_at, after.submitted_at)) {
    const { batch, total } = await photoCounts(client, after.id, after.submit_batch_id);
    await notifyBoundPartners(client, ctx, {
      to: await parentIdsOf(client, after.student_id),
      title: '孩子已提交作业',
      body: `《${title}》已提交${photoClause(batch, total)}，${gradingTail(after)}`,
      type: NotificationTypes.homework,
      relatedBizId: after.id,
    });
  }

  // ② 批改完成：`checked_at` 变成一个**新的非空**时刻。
  //    「变成空」= 清空上一次的结果（`clearResult()` 与提交是同一份掩码），
  //    那不是一次批改事件，所以这里要求目标值非空。
  const gradingTouched = touched.some((k) => GRADING_KEYS.includes(k));
  if (gradingTouched && after.checked_at && changedTs(before.checked_at, after.checked_at)) {
    const score = after.score ?? 0;
    const wrong = after.wrong_count ?? 0;

    await notifyBoundPartners(client, ctx, {
      to: await parentIdsOf(client, after.student_id),
      title: wrong === 0 ? '作业已完成' : '作业需要更正',
      body: wrong === 0
        ? `《${title}》批改完成，得分 ${score}，全部正确。`
        : `《${title}》批改完成，得分 ${score}，有 ${wrong} 道错题待更正。`,
      type: NotificationTypes.homework,
      relatedBizId: after.id,
    });

    // 学生自己也有一份（本地 `_notifySelf`，`student_controller.dart:756`）。
    // 它与上面那条**不是重复**：一条是「给家长看结果」，一条是「提醒学生去更正」，
    // 而这两群人在两台设备上 —— 这正是通知必须由服务端生成的理由本身。
    await notifyBoundPartners(client, ctx, {
      to: [after.student_id],
      title: wrong === 0 ? '作业已完成' : '作业待更正',
      body: `《${title}》得分 ${score}，错题 ${wrong} 道。`,
      type: NotificationTypes.homework,
      relatedBizId: after.id,
    });
  }
}

// ===== 作业照片（行）=====
//
// ⚠️ 这里管的是**行**，不是字节。`storageKey` 现在还是设备本地标识
// （原生端绝对路径 / Web 端 localStorage 键），换手机后它指向一个不存在的路径，
// 而读取失败是**静默返回 null** 的 —— 症状是照片位置一片空白、没有任何报错。
// 改成对象 key（`students/{id}/homework/{ulid}.jpg`）是 S5 的事。

const IMAGE_FIELDS = [
  'studentId',
  'homeworkId',
  'storageKey',
  'fileName',
  'fileSize',
  'mimeType',
  'ocrStatus',
  'ocrText',
  'batchId',
  'sortOrder',
];

/**
 * 客户端**允许送**的键。比 `IMAGE_FIELDS` 多一个 `id`。
 *
 * `id` 允许出现但**会被丢掉**（R2：id 服务端生成）。放行而不是报错的理由：
 * 客户端的 `HomeworkImageModel.toMap()` 天然带 `id`，为它报错会让
 * 「照模型发上来」这个最自然的写法失败，而失败原因（「id 不能送」）
 * 与它真正要表达的意思（「id 由服务端定」）其实是同一件事 ——
 * 用返回值说明更直接：响应里的 id 与请求里的不同。
 *
 * 但 `createdAt` 不同：它是**记录时间**（R3），客户端 `toMap()` 也会带它，
 * 而「服务端说了算」这件事必须让客户端知道 —— 静默忽略会让它以为自己设置了它。
 * 所以 `createdAt` 报错，`id` 忽略。
 */
const IMAGE_INPUT_KEYS = [...IMAGE_FIELDS, 'id'];

/**
 * 一行照片数据。`studentId` 由调用方**先解析好**再传进来 ——
 * 归属只能来自身份，不能来自 body 里另一个自报字段。
 */
function imageRow(body, studentId) {
  return {
    id: newId(),
    studentId,
    homeworkId: body.homeworkId === undefined || body.homeworkId === null
      ? null
      : String(body.homeworkId),
    storageKey: requireText(body.storageKey, 'storageKey'),
    fileName: toText(body.fileName) ?? '',
    fileSize: toInt(body.fileSize, 'fileSize') ?? 0,
    mimeType: toText(body.mimeType) ?? 'image/jpeg',
    ocrStatus: toText(body.ocrStatus) ?? 'pending',
    ocrText: toText(body.ocrText) ?? '',
    batchId: toText(body.batchId) ?? '',
    sortOrder: toInt(body.sortOrder, 'sortOrder') ?? 0,
  };
}

/**
 * 按附件类型分别校验数量上限（照片 9 / 音频 3 / 视频 1）。
 *
 * ## 为什么要在这里再判一次（客户端已经拦过）
 *
 * 客户端的拦截是**体验**，不是**边界**。没有这一道的话，任何绕过客户端的写法
 * （脚本、旧版本 App、改过的包）都能一次塞进几百个附件 —— 而每个附件都要
 * 占一行、一份存储，撞的是那个 3000 的配额。配额是「拦住失控」用的，
 * 不该让它去承担「本该在边界上被拒绝的请求」。
 *
 * ## 为什么用 `mimeType` 判而不是单独传一个 kind
 *
 * 因为 `mime_type` 是**已经在库里的那一列**（NOT NULL）。另传一个 kind 字段
 * 等于给同一个事实造第二个源，两者漂了就静默漏判 —— 而漏判的方向是
 * 「一个视频被当成图片送进视觉模型」，它不会报错，只会被模型丢掉。
 *
 * @param {Array<{mimeType: string}>} rows
 */
function assertAttachmentCounts(rows) {
  const counts = new Map();
  const unknown = new Set();
  for (const row of rows) {
    const kind = kindOfMime(row.mimeType);
    if (kind === null) unknown.add(String(row.mimeType));
    else counts.set(kind, (counts.get(kind) ?? 0) + 1);
  }

  if (unknown.size > 0) {
    throw badRequest(
      `不支持的附件类型：${[...unknown].join('、')}（只认 image/*、audio/*、video/*）`,
    );
  }

  for (const [kind, n] of counts) {
    const limit = MAX_COUNT.get(kind);
    if (limit !== undefined && n > limit) {
      throw badRequest(`单次最多提交 ${limit} 个${labelOfKind(kind)}，本次 ${n} 个`);
    }
  }
}

// ===== 照片配额 =====
//
// 上限来自 `IMAGE_QUOTA_PER_STUDENT`（默认 3000，见 image-store-factory.js），
// 由 `app.js` 挂在 `ctx.photoQuota` 上。判的是「**这个学生名下现在还有多少行照片**」。

/**
 * 某学生当前的用量 —— `{ used, quota, remaining }`。
 *
 * ## 为什么是 `student_id = $1`，而不是 `student_id = any(ctx.students)`
 *
 * 前者给出的正是「**这个学生**有多少张」，与**谁在问**无关。
 * 用可见集合的话，家长只看一个孩子时数字碰巧一样，同时带两个孩子时
 * 会把两个人的张数加起来 —— 于是「老大传满了，老二明明还有空却传不上去」。
 * 这种错很难查：它是按请求的**参数组合**偶发的，同一对家长换个用法就正常。
 *
 * ⚠️ RLS 仍然管着这里：`$1` 只会来自 `requireVisibleStudent` 解析过的取值，
 * 拿别人孩子的 id 来问用量只会得到 0 行（看不见就是查不到），而不是别人的用量。
 */
/**
 * 把「已用多少张」翻译成交给客户端的用量对象。
 *
 * **这是 `photoUsage` 唯一的构造点** —— 上传响应与写行响应都从这里出，
 * 形状只有一个（少一处复制就少一个「两边字段名漂了」的机会）。
 *
 * ## `used` 为什么由调用方给，而不是在这里查
 *
 * 因为两条路要报的时刻不同：上传报的是**写之前**（字节还没变成行），
 * 写行报的是**写之后**。写之后那个数不需要再查一次库 ——
 * `写之前的 used + 本次写入的行数` 就是它。
 * 多查一次不只是慢（同一个事务里再扫一遍），还会让人以为两次查询的
 * 结果一定不同，从而在一个本来确定的流程里引入「万一对不上」的疑虑。
 *
 * ## ⚠️ `nearLimit` 由服务端算
 *
 * 客户端只判这一个布尔，不必知道「接近」是怎么定义的。阈值
 * （`warnRemaining`）也一并回传，好处是**改阈值只有一处**：
 * 客户端自己抄一个 20 的话，改配额的人不会想到还有第二处要改。
 */
function describePhotoUsage(ctx, used) {
  const quota = ctx.photoQuota;
  const remaining = Math.max(0, quota - used);
  return {
    used,
    quota,
    remaining,
    warnRemaining: ctx.photoWarnRemaining,
    nearLimit: remaining <= ctx.photoWarnRemaining,
  };
}

async function photoQuotaState(client, ctx, studentId) {
  const r = await client.query(
    'select count(*)::int as n from homework_image where student_id = $1',
    [studentId],
  );
  // ⚠️ `count(*)` 是 bigint，`pg` 会把它返回成**字符串**（`"14"`）。
  // 上面那句 `::int` 就是为它写的 —— 少了它，`used + incoming` 会变成
  // 字符串拼接（`"9" + 1` → `"91"`），而症状只是「数字看起来怪」，不报错。
  return describePhotoUsage(ctx, r.rows[0].n);
}

/**
 * 配额判定：再加 `incoming` 张会不会越过上限，会就抛。
 * 返回值是**写入之前**的用量（调用方拿去回报给客户端做「快满了」提示）。
 *
 * ## 为什么两处都要判
 *
 * - **写行**（`saveHomeworkImages`）是**权威**的那一处：行才是「这个学生有几张
 *   照片」的定义，配额数的就是这个。
 * - **上传字节**（`uploadHomeworkImage`）是一次**预检**。字节没有行，
 *   所以它只能拿当前行数当代理。代价是它挡不住「只传字节、从不提交」
 *   这种绕过；收益是**失控的循环灌不进桶里**，而且学生在拍完照那一刻
 *   就知道结果，而不是把作业信息录完、点提交才失败。
 *
 * 只留后者会漏（无主字节照样把账单推上去）；只留前者则让失败发生在
 * 「该做的事都做完了」之后。两处都判是刻意重复，不是冗余。
 *
 * ## ⚠️ 并发下可能超出「一批」的量（已接受）
 *
 * 这是「先查后写」，没加锁。两个并发请求可以都读到 `used=9990`、各写 20 行
 * → 落到 10030。要精确就得 `pg_advisory_xact_lock` 按学生串行化。
 * **刻意不做**：这是拦失控的闸，不是财务口径；而一把锁会让
 * 「一个学生在两台设备上同时提交」互相等待。超出量有上界
 * （并发数 × 单批 30 张），相对 3000 可忽略。
 * 真要精确的账，看 `npm run report:storage` 的月报 —— 那里是读完再算，不是抢着写。
 */
async function assertPhotoQuota(client, ctx, studentId, incoming) {
  const state = await photoQuotaState(client, ctx, studentId);
  if (state.used + incoming <= state.quota) return state;

  throw storageQuotaExceeded(
    `该学生的照片数量已达上限（已用 ${state.used} / ${state.quota} 张，`
      + `本次还要再加 ${incoming} 张）。删掉一些旧照片再试，`
      + '或让运维调大 IMAGE_QUOTA_PER_STUDENT',
    { used: state.used, quota: state.quota, incoming, remaining: state.remaining },
  );
}

/**
 * 一次写入一张或多张（`saveHomeworkImage` / `saveHomeworkImages` 合并）。
 *
 * 合并的理由：两个方法在服务端是**同一条 INSERT**，差别只是行数。
 * 客户端一次提交本来就会带 1–N 张，分成两个端点只会让「交作业」多一次往返。
 */
export async function saveHomeworkImages(client, ctx, body) {
  const list = Array.isArray(body.images) ? body.images : [body];
  if (list.length === 0) throw badRequest('images 不能为空');
  // 这是一个**兜底总量**，不是产品口径 —— 真正的口径是按类型分别限
  // （见 `assertAttachmentCounts`）。留着它是因为「一次请求塞 5000 行」
  // 必须在**拼 SQL 之前**就被挡住，而不是等 unnest 去处理。
  if (list.length > 30) throw badRequest('一次最多写入 30 个附件');

  // 与作业更新同一个理由：认识不出的字段要当场报错。照片对象里最危险的一个是
  // `createdAt` —— 客户端 `toMap()` 会带上它，而它是**记录时间**，
  // 服务端说了算（R3）。静默忽略它比报错更坏：客户端会以为自己设置了它。
  const bad = new Set();
  for (const x of list) {
    for (const k of Object.keys(x ?? {})) {
      if (!IMAGE_INPUT_KEYS.includes(k)) bad.add(k);
    }
  }
  if (bad.size > 0) {
    throw badRequest(
      `照片对象里出现了不认识的字段：${[...bad].join('、')}。`
        + `允许的字段是：${IMAGE_INPUT_KEYS.join('、')}（createdAt 由服务端给，见 R3）。`,
    );
  }

  // 归属先解析一次：整批照片必须属于同一个学生（一次提交不会跨孩子）。
  const studentId = requireVisibleStudent(ctx.visibleStudents, body.studentId ?? list[0]?.studentId);
  const rows = list.map((x) => imageRow(x, studentId));
  // 类型与数量：整批一起判，理由与下面配额那条相同（半截写入比整批失败难查）。
  assertAttachmentCounts(rows);

  // 配额：**整批一起判**，绝不逐张判。
  //
  // 逐张判的话，前 20 张写进去了、第 21 张抛错 —— 落下一次「一半提交成功」。
  // 而客户端看到的是一个 409，它会以为整批都没写；同时库里已经有了 20 行。
  // 这种半截状态没有任何地方会说出来，正好是本项目最怕的那一类。
  // 注意 `list.length > 30` 已经在上面挡过一次，所以 `rows.length` 有上界。
  //
  // 接住返回值：它是**写入之前**的用量。拿它与 `rows.length` 就得到写完之后
  // 的用量，回给客户端做「快满了」提示（见 `describePhotoUsage`）。
  const before = await assertPhotoQuota(client, ctx, studentId, rows.length);

  // 一次 INSERT 多行 + unnest：行数固定为 list 长度，参数是十一个数组。
  // 用「逐行拼占位符」的写法在 30 张时会拼出 360 个占位符，
  // 而 unnest 版本与行数无关 —— 少一次「张数一多就变慢」的隐蔽拐点。
  //
  // `created_at` 用 now() 而不是让客户端给：它是**记录时间**（R3），
  // 客户端时钟不可信，而这一列只用于展示顺序与排查。
  const r = await client.query(
    `insert into homework_image (
       id, student_id, homework_id, storage_key, file_name, file_size,
       mime_type, ocr_status, ocr_text, batch_id, sort_order, created_at
     )
     select id, student_id, homework_id, storage_key, file_name, file_size,
            mime_type, ocr_status, ocr_text, batch_id, sort_order, now()
       from unnest(
         $1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::int[],
         $7::text[], $8::text[], $9::text[], $10::text[], $11::int[]
       ) as t(id, student_id, homework_id, storage_key, file_name, file_size,
              mime_type, ocr_status, ocr_text, batch_id, sort_order)
     returning *`,
    [
      rows.map((x) => x.id),
      rows.map((x) => x.studentId),
      rows.map((x) => x.homeworkId),
      rows.map((x) => x.storageKey),
      rows.map((x) => x.fileName),
      rows.map((x) => x.fileSize),
      rows.map((x) => x.mimeType),
      rows.map((x) => x.ocrStatus),
      rows.map((x) => x.ocrText),
      rows.map((x) => x.batchId),
      rows.map((x) => x.sortOrder),
    ],
  );

  // 回报**写入之后**的用量 —— 这是「照片快满了」这句提示唯一准确的时刻：
  // 上传那一步报的是写之前的行数（字节还没变成行），会低估一到几张。
  //
  // `before.used + rows.length` 是推算，**不重查一次库**：整个请求在一个事务里，
  // 这一段的可见性由上面的 INSERT 决定，重查只会得到同一个数。
  // 并发下仍可能偏出一批（已接受的取舍，见 `assertPhotoQuota` 的说明）。
  return {
    items: rowsToApi(r.rows),
    photoUsage: describePhotoUsage(ctx, before.used + rows.length),
  };
}

/**
 * 取照片行。两种口径合成一个端点（`queryHomeworkImages(studentId)` /
 * `queryHomeworkImagesByHomeworkId(homeworkId)`）—— 差别只是 where 的一个条件。
 */
export async function listHomeworkImages(client, ctx, query) {
  const homeworkId = query?.homeworkId ? String(query.homeworkId) : null;
  const r = await client.query(
    `select * from homework_image
      where student_id = any($1::text[])
        and ($2::text is null or homework_id = $2)
      order by created_at, sort_order, id`,
    [ctx.students, homeworkId],
  );
  return { items: rowsToApi(r.rows) };
}

/** 数量（`countHomeworkImages`）——家长端「已交 N 张」用，不该为此拉回整行。 */
export async function countHomeworkImages(client, ctx, query) {
  const homeworkId = requireText(query?.homeworkId, 'homeworkId');
  const r = await client.query(
    `select count(*)::int as n from homework_image
      where student_id = any($1::text[]) and homework_id = $2`,
    [ctx.students, homeworkId],
  );
  return { homeworkId, count: r.rows[0].n };
}

/** 按作业删掉它的照片（重新提交前清场）。 */
export async function deleteHomeworkImages(client, ctx, body) {
  const homeworkId = requireText(body.homeworkId, 'homeworkId');
  const r = await client.query(
    `delete from homework_image
      where student_id = any($1::text[]) and homework_id = $2`,
    [ctx.students, homeworkId],
  );
  // ⚠️ 这里**只删行，不删盘上的文件**。
  //
  // 不是漏了，是刻意的：删文件是**文件系统 IO**，而这段跑在 PG 事务里 ——
  // 事务回滚时文件已经删掉了，改不回来；删文件失败又会把一次正常的
  // 「重新提交前清场」变成一次报错。两种结果都比"留下一个没人引用的文件"更坏。
  //
  // 孤儿文件不占任何**用户可见**状态，收益是零风险；清理它属于运维
  // （按归档日期目录整体删，或跑一个「盘上有、库里没有」的巡检）。
  return { deleted: r.rowCount };
}

// ===== 作业照片（字节）=====
//
// 上面四条管**行**，下面两条管**字节**。分开的核心理由：
// 行在 PG 里（RLS 管得住、事务管得住），字节在文件系统里
// （没有事务、没有行级权限）。硬塞进同一个端点会得到
// 「字节写成了但行没写成」的半截状态 —— 而它在客户端看起来是
// 「照片传上去了却不在作业里」，又是一次静默的不一致。

/**
 * 上传一张照片的字节，返回要写进 `storage_key` 的**相对键**。
 *
 * 刻意**不写 `homework_image` 行**：拍完照的那一刻，学生往往还在录入作业，
 * `homeworkId` 都还没有。让上传只管字节、提交作业时再写行，
 * 才与客户端「先存图 → 提交时批量上报」的既有流程一致（改动面最小）。
 *
 * 代价是「传了图但没提交」会留下孤儿文件。这个方向是**可接受的**：
 * 孤儿文件不占用户可见状态，可按归档日期整体清理；反过来
 * （有行、没字节）才会让家长端出现一张永远打不开的图。
 *
 * ⚠️ 请求体是**原始字节**，元数据走 query —— 见 `scoped.query` / `scoped.rawBody`
 * 在 app.js 里的说明。所以这个 handler 不用第三个参数 `input`。
 *
 * ⚠️ **配额在这里只是预检**，用的是「当前行数」这个代理指标 ——
 * 它挡不住「只上传、从不提交」的代码（字节没有行，行数不涨）。
 * 也就是说 `IMAGE_QUOTA_PER_STUDENT` 管的是**「库里还有多少张照片」**，
 * 而不是「桶里花了多少钱」；后者要看 `npm run report:storage` 的月报。
 * 这个取舍是刻意的：要让配额反映字节，就得在每次上传时按学生累加
 * 一个游离于行之外的计数，而那个计数一旦与行不同步（比如删行时忘了减），
 * 就会变成「明明没几张照片却传不上去」—— 比多花点存储难查得多。
 */
export async function uploadHomeworkImage(client, ctx) {
  const store = requireImageStore(ctx);
  const query = ctx.query ?? {};
  // 归属只能来自身份：`studentId` 必须落在**本次请求的可见集合**里。
  // 学生的可见集合就是 `[自己]`，家长是他已结伴的孩子 —— 于是
  // 「学生往别人名下传照片」这件事在结构上不成立，不用额外写校验。
  const studentId = requireVisibleStudent(ctx.visibleStudents, query.studentId);
  const mimeType = requireText(query.mimeType, 'mimeType');

  // 配额预检放在写字节**之前**：超限时不该先把字节落进桶里再报错 ——
  // 那既白花了存储，又留下一个永远没有行去引用的孤儿对象。
  const photoUsage = await assertPhotoQuota(client, ctx, studentId, 1);

  const saved = await store.put({ studentId, bytes: ctx.rawBody, mimeType });
  return {
    studentId,
    fileName: toText(query.fileName) ?? '',
    ...saved,
    /**
     * 这个学生当前的用量 `{ used, quota, remaining }` —— **写之前**的数字
     * （上传不写行，所以 `used` 不变，这是如实的）。
     *
     * 刻意**不另开一个查询端点**：上传正是唯一需要这个数字的时刻，
     * 单开一条路只会多一次往返，而那个数字在别的时刻也没人看。
     * 客户端据此就能在「快满了」时提示 —— 这是 Q3「接近配额显式提示」
     * 那半边的数据来源（见 doc/historical-data-plan.md）。
     */
    photoUsage,
  };
}

/**
 * 签一个**客户端直传**的位置（大附件专用：音频、视频）。
 *
 * ## 为什么不能继续用 `uploadHomeworkImage`
 *
 * 那条路的字节是**穿过函数请求体**的。视频上限 100MB，而平台对请求体有限制
 * （本地 `dev-server` 实测 12MB，且平台会把二进制标成 base64 再解一遍），
 * 100MB 根本过不去。而且让函数替客户端转一手 100MB，是在为一个与业务
 * 无关的动作付执行时长与内存的钱。
 *
 * 所以大附件换一条路：**服务端只签名，客户端直接 PUT 到对象存储**，
 * 签完名服务端就不再经手字节。函数请求体上限与这个功能彻底无关。
 *
 * ## 签名之后的两步仍然存在
 *
 * 直传只解决「字节怎么过去」。客户端传完要拿这个 `storageKey` 回
 * `POST /data/homework/images` 写行 —— 与原本「先传字节、提交时写行」的
 * 结构一致，变的只是第一步。
 *
 * ## ⚠️ 只有对象存储后端能直传
 *
 * 文件系统后端（`IMAGE_DRIVER=fs`）**没有可直传的 HTTP 端点** —— 它不是一个
 * HTTP 服务。那种部署下如实回 `upload_not_configured`，**不给一个
 * 「看起来能用、上传时 404」的假 URL**（与网关 `uploads.js` 里
 * 「TOS 没配齐就报错而不是返回假 URL」同一条原则）。
 *
 * 也就是说：**本机（fs）能用小文件走函数那条路验通全链路，
 * 但 100MB 视频只有在 OSS 部署上才真的成立。** 这一点必须让调用方看得见 ——
 * 回包里的 `driver` 就是为此存在的。
 */
export async function signHomeworkAttachmentUpload(client, ctx, body) {
  const store = requireImageStore(ctx);
  const studentId = requireVisibleStudent(ctx.visibleStudents, body?.studentId);
  const mimeType = requireText(body?.mimeType, 'mimeType');

  const kind = kindOfMime(mimeType);
  if (kind === null) {
    throw badRequest(`不支持的附件类型：${mimeType}（只认 image/*、audio/*、video/*）`);
  }

  // 配额预检放在签名**之前**：已经到量的学生不该拿到一个能用的直传位置 ——
  // 那等于「绕过配额白传一个 100MB 的文件进去」，而且字节已经在桶里了，
  // 服务端连拒绝的机会都没有。
  const photoUsage = await assertPhotoQuota(client, ctx, studentId, 1);

  const maxBytes = maxBytesFor(store.maxBytesByKind, kind);
  if (typeof store.signDirectPut !== 'function') {
    throw new ApiError(
      ErrorCodes.uploadNotConfigured,
      '当前存储后端不支持直传（只有对象存储可以）。'
        + '若要用大附件，请把 IMAGE_DRIVER 配成 oss。',
      { status: 503, details: { driver: 'fs', kind } },
    );
  }

  const signed = store.signDirectPut({ studentId, mimeType, maxBytes });
  if (signed === null) {
    throw new ApiError(
      ErrorCodes.uploadNotConfigured,
      '对象存储未就绪，无法签发直传位置',
      { status: 503, details: { kind } },
    );
  }

  return {
    studentId,
    kind,
    ...signed,
    photoUsage,
  };
}

/**
 * 签一个**客户端直读**的位置（大附件专用：视频）。
 *
 * ## 为什么需要它 —— 与上传侧对称，但撞的是另一面墙
 *
 * 上传侧（`signHomeworkAttachmentUpload`）绕开的是**请求体**上限；
 * 这条绕开的是**响应体**上限。函数计算的响应体上限是 32 MiB，
 * 而视频上限 100 MB —— 于是超过 32 MiB 的视频**传得上去、取不回来**：
 * 播放时只显示「这个附件的字节暂时取不回来」，全程不报错。
 *
 * 这是**读回侧**的同一个问题，而上传侧早就为此改过设计。此前没被发现，
 * 是因为唯一的判据（`scripts/probe-media-e2e.mjs`）用**服务端签名**从 OSS
 * 读回 —— 它证明的是「字节真进桶了」，不是「App 取得回来」。判据选错了层。
 * 见 `doc/open-items.md` B32。
 *
 * ## 收 `id` 而不是 `storageKey` —— 与读取字节那条路同一条规矩
 *
 * 客户端能决定的只有「哪一行」，「那一行的字节在哪」由**数据库**说了算。
 * 于是路径穿越不是「记得校验」的问题，而是「没有入口」的问题。
 * 归属校验同样白送：RLS 之下不是自己（或自己孩子）的行根本查不出来。
 *
 * ## 只有对象存储后端能直读
 *
 * 文件系统后端**没有可直读的 HTTP 端点**（它不是一个 HTTP 服务），
 * 如实回 `upload_not_configured`，**不给一个「看起来能用、取时 404」的假地址**。
 * 客户端据此回退到 `GET /data/homework/images/file`（小文件仍能验通全链路）。
 *
 * ⚠️ 这条回退**不是**「本地开发才有的降级」：它是客户端唯一的兜底 ——
 * 超过 32 MiB 的附件在那种部署上本来就不该存在（fs 后端的本机上限是 12MB），
 * 所以那条路永远用不到 32 MiB 那一档。
 */
export async function signHomeworkAttachmentRead(client, ctx, query) {
  const store = requireImageStore(ctx);
  const id = requireText(query?.id, 'id');

  const r = await client.query(
    `select storage_key, mime_type from homework_image
      where id = $1 and student_id = any($2::text[])`,
    [id, ctx.students],
  );
  const row = r.rows[0];
  if (!row) throw notFound('照片不存在，或不在你的可见范围内');

  if (typeof store.signDirectGet !== 'function') {
    throw new ApiError(
      ErrorCodes.uploadNotConfigured,
      '当前存储后端不支持直读（只有对象存储可以）。'
        + '若要用大附件，请把 IMAGE_DRIVER 配成 oss。',
      {
        status: 503,
        retryable: false,
        details: { driver: 'fs', reason: 'direct_read_unsupported' },
      },
    );
  }

  const signed = store.signDirectGet(row.storage_key);
  if (signed === null) {
    // 两种「签不出来」，处置**不同**，所以分开报：
    // · 旧版设备本地标识 → 字节只在当初那台设备上，客户端该回退本地读（404 + reason）
    // · 对象存储未就绪 → 是配置问题，不该伪装成「照片没了」
    if (!isServerImageKey(row.storage_key)) {
      throw new ApiError(
        ErrorCodes.notFound,
        '该照片的字节不在服务端（这是旧版设备本地标识，字节只在当初那台设备上）',
        { status: 404, details: { reason: 'not_on_server', storageKey: row.storage_key } },
      );
    }
    throw new ApiError(
      ErrorCodes.uploadNotConfigured,
      '对象存储未就绪，无法签发直读位置',
      { status: 503, retryable: false, details: { reason: 'storage_not_ready' } },
    );
  }

  return {
    id,
    mimeType: row.mime_type,
    ...signed,
  };
}

/**
 * 按**记录 id** 取照片字节。
 *
 * 为什么收 `id` 而不是 `storageKey`：这样客户端能决定的只有「哪一行」，
 * 「那一行的字节在哪」由**数据库**说了算 —— 路径穿越防护因此不是
 * 「记得校验」的问题，而是「没有入口」的问题。少一个能出错的地方。
 *
 * RLS 在这里是白送的：不是自己（或自己孩子）的照片，这一行根本查不出来，
 * 自然落到 404。不必给图片单独写一套权限判断 —— 那套判断迟早会和
 * 其它表的可见性规则漂开。
 */
export async function readHomeworkImageBytes(client, ctx, query) {
  const store = requireImageStore(ctx);
  const id = requireText(query?.id, 'id');

  const r = await client.query(
    `select storage_key, mime_type from homework_image
      where id = $1 and student_id = any($2::text[])`,
    [id, ctx.students],
  );
  const row = r.rows[0];
  if (!row) throw notFound('照片不存在，或不在你的可见范围内');

  // `storage_key` 是旧版设备本地标识时，store 会抛一个带
  // `details.reason = 'not_on_server'` 的 404 —— 客户端据此**回退本地读取**。
  const bytes = await store.get(row.storage_key);

  // 缩图：客户端可传 `?w=` 请求更小尺寸（VPN / 弱网下更稳）。
  // 缩不动（没装 sharp、非图片、失败）一律回退原图 —— 绝不让缩图影响原图可用。
  const resized = await maybeResizeResponse(row.storage_key, row.mime_type, bytes, query);
  if (resized) return resized;
  return binaryResponse(row.mime_type, bytes);
}

/**
 * 取照片存储；没配就**如实说「没配」**。
 *
 * 不复用 `internal`：那是「代码有 bug」的语气，会让运维去翻日志查堆栈，
 * 而这里真实的情况是「少配了一个环境变量」，看错误码就知道该做什么。
 *
 * ⚠️ 判的是 `ready` 而不是「对象在不在」。
 * `imageStore` 从 `createImageStoreFor` 出来**永远是个对象** —— 后端没配好时
 * 它是个 `ready: false` 的对象。早先这里判 `!ctx.imageStore`，于是生产路径上
 * 这个分支**永远进不来**，未配置时一路走到 `put()` 里抛一个普通 Error，
 * 变成 500「服务端内部错误」：客户端看到 500 会以为是服务端炸了，
 * 而真相只是「这个功能没开」，本来回 `upload_not_configured` 客户端就能优雅降级。
 */
export function requireImageStore(ctx) {
  if (!ctx.imageStore?.ready) {
    throw new ApiError(
      ErrorCodes.uploadNotConfigured,
      '本服务未配置照片存储（IMAGE_DRIVER=fs 时缺 IMAGE_ROOT_DIR；=oss 时缺 OSS_BUCKET / '
        + 'OSS_REGION / OSS_ACCESS_KEY_ID / OSS_ACCESS_KEY_SECRET），照片的上传与读取不可用',
      { status: 503, retryable: false },
    );
  }
  return ctx.imageStore;
}

// ===== 小工具 =====

/** 去掉若干键，剩下的就是「掩码候选」。 */
function stripKeys(body, keys) {
  const out = {};
  for (const [k, v] of Object.entries(body ?? {})) {
    if (!keys.includes(k)) out[k] = v;
  }
  return out;
}

/** 返回掩码里**不认识**的字段（空数组表示都认识）。 */
function assertKnownFields(mask, spec) {
  return Object.keys(mask).filter((k) => !Object.prototype.hasOwnProperty.call(spec, k));
}
