import { badRequest, forbidden, notFound } from '../../../shared/errors.js';
import { binaryResponse } from '../http.js';
import { requireImageStore } from './homework.js';
import { requireVisibleStudent } from '../auth.js';
import { rowToApi, rowsToApi } from '../mapper.js';
import { buildInsert, buildInsertMany, idAndServerColumns, SQL_NOW } from '../insert.js';
import { buildUpdate, changedTs, emptyPatchResult } from '../patch.js';
import { toBool, toInt, toNum, toText, toTs, requireText } from '../coerce.js';
import { notifyBoundPartners, parentIdsOf, NotificationTypes } from './notify.js';

/**
 * 复习闭环：一池（`review_mistake`）三路（`review_paper(_item)` / `explain_record` /
 * `ai_practice_question`）一个出口，外加作答证据、周期报告与判定影子比对。
 *
 * ## 三处必须在服务端做对、客户端做不对的事
 *
 * ① **删一道错题要一次删 5 张表**（陷阱③）。客户端编排 5 次调用的后果不是
 *    「慢」而是**孤儿行**：残留的 `review_attempt` 会让毕业判定错乱，
 *    残留的 `judgement_ab` 会让一致率多出一个查不到题目的分母。
 *    所以这里是**单端点 + 单事务**。
 *
 * ② **组卷必须是原子的**（卷 + 题目一次写入）。只写进卷没写进题目，
 *    得到一份点开就空的卷子 —— 而它的状态是 `draft`，从任何界面看都正常。
 *
 * ③ **一致率的分母要关联过滤**。`queryJudgementAB(studentId:)` 在本地是
 *    「只按 studentId 过滤、不与错题关联」，于是孤儿行直接进分母
 *    （接口注释里点名要求服务端自己补上这个关联）。
 *
 * ## 一个本轮定死的待定项
 *
 * `updateReviewMistakeState` 的参数在本地是「`null` = 本次不改」，且**没有任何
 * 字段能被清空**（`masteredAt` 之类只进不出）。接口注释把它标为「待定」。
 * 这里按 `HomeworkPatch` 的同一规则定死：**键出现即写，值为 null 即写成 NULL**。
 * 对现在的客户端是**超集**（它只会省略键，从不送 null），所以行为不变；
 * 等 S4 给 Dart 侧补一个 `ReviewMistakeStatePatch`，「撤销毕业」才有表达方式。
 *
 * 另：`created_at` 这类**记录时间**一律由数据库 `now()` 给（R3），
 * 客户端 `toMap()` 里带的那个被显式忽略 —— 它是设备本地时间，
 * 而它会被用来算「今天错了几道」。设备时钟偏一天，统计就偏一天。
 */

// ===== 字段清单 =====
//
// 默认值一律照客户端 `*Model.fromMap()` 的写法：本地实现读到缺失字段时回退到
// 这些值，所以服务端写入也补同样的值，两条链路的行才长得一样。
// —— 只在「某个字段从未被写过」时才有差别，而那正是对账最难查的情形。

const text = (v) => toText(v) ?? '';
const int0 = (v, f) => toInt(v, f) ?? 0;
const bool0 = (v, f) => toBool(v, f) ?? false;

const MISTAKE_SPEC = {
  subject: text,
  title: text,
  // 题干与短标题是两件事：title 是「作业标题 · 知识点」这种标签，
  // 把它当题干发给模型，讲解就只能是泛泛而谈。
  questionBody: text,
  // 原卷面题号（「第 20 题 (4)」里的 `20(4)`）：只用于展示，
  // 让家长能翻到作业本上的那一题。空串 = 没编号 / 老数据。
  questionNo: text,
  // 学生那次写出来的解题过程（批改时抄下来的原文，可能为空）。
  studentProcess: text,
  answerKey: text,
  sourceType: text,
  grade: text,
  term: text,
  imageCount: int0,
  originalAnswer: text,
  wrongReason: text,
  state: text,
  homeworkId: text,
  knowledgePoint: text,
  wrongCount: (v, f) => toInt(v, f) ?? 1,
  lastWrongAt: (v, f) => toTs(v, f),
  sourceHomeworkTitle: text,
  masteredAt: (v, f) => toTs(v, f),
  masteredBySelf: bool0,
  reviewRound: int0,
  lastReviewedAt: (v, f) => toTs(v, f),
};

/**
 * `updateReviewMistakeState` 的掩码字段 —— **与完整覆盖刻意分开**。
 *
 * 完整覆盖（`updateReviewMistake`）写全部 15 个字段；状态更新只写掩码里那几个。
 * 合成一个端点就会得到「传了什么就覆盖什么、没传的就清空」的接口 ——
 * 那正是 `wish` 接口注释里明确拒绝的「整行 replace」形态：学生在这台设备改状态、
 * 家长在另一台改知识点，后写的那次会把先写的抹掉，而且不报错。
 */
const MISTAKE_STATE_SPEC = {
  state: (v, f) => requireText(v, f),
  wrongCount: (v, f) => toInt(v, f),
  lastWrongAt: (v, f) => toTs(v, f),
  reviewRound: (v, f) => toInt(v, f),
  lastReviewedAt: (v, f) => toTs(v, f),
  masteredAt: (v, f) => toTs(v, f),
  masteredBySelf: (v, f) => toBool(v, f),
  knowledgePoint: (v, f) => toText(v),
  wrongReason: (v, f) => toText(v),
};

const PAPER_SPEC = {
  title: text,
  subject: text,
  knowledgePoints: text,
  status: text,
  itemCount: int0,
  passCount: int0,
  failCount: int0,
  exportedAt: (v, f) => toTs(v, f),
  submittedAt: (v, f) => toTs(v, f),
  gradedAt: (v, f) => toTs(v, f),
  closedAt: (v, f) => toTs(v, f),
  filePath: text,
  note: text,
};

const PAPER_ITEM_SPEC = {
  mistakeId: text,
  subject: text,
  knowledgePoint: text,
  questionTitle: text,
  questionBody: text,
  originalAnswer: text,
  wrongReason: text,
  answerKey: text,
  sortOrder: int0,
  studentAnswer: text,
  result: text,
  photoPath: text,
  comment: text,
  checkedAt: (v, f) => toTs(v, f),
};

const ATTEMPT_SPEC = {
  mistakeId: text,
  paperId: text,
  itemId: text,
  channel: (v) => toText(v) ?? 'paper',
  round: (v, f) => toInt(v, f) ?? 1,
  answer: text,
  correct: bool0,
  score: int0,
  comment: text,
};

const PRACTICE_SPEC = {
  sourceMistakeId: text,
  knowledgePoint: text,
  subject: text,
  title: text,
  content: text,
  answer: text,
  difficulty: (v) => toText(v) ?? '基础',
  studentAnswer: text,
  state: (v) => toText(v) ?? 'pending',
  round: (v, f) => toInt(v, f) ?? 1,
  checkedAt: (v, f) => toTs(v, f),
  // 题型与选项。默认值与列默认一致：加这两列之前生成的题全是解答题，
  // 按 `solution` 走与以前完全一样；默认成 choice 会让老题变成
  // 「没有选项的选择题」，学生点不了任何东西。
  questionType: (v) => toText(v) ?? 'solution',
  // 选项以 JSON 文本存。**不接受数组原样落库**：`text` 列收到数组时
  // pg 会把它字符串化成 `{...}` 形式，读回来就不是 JSON 了。
  optionsJson: (v) => {
    if (typeof v === 'string') return v;
    if (Array.isArray(v)) return JSON.stringify(v);
    return '[]';
  },
  // 配图（图形 DSL）。没有图就是 NULL —— **不要写成 '{}'**：
  // 「有没有图」以后要靠 `figure_json IS NULL` 一眼数出来，
  // 而空对象会让每道纯文字题都看起来像「有一张解析不出来的图」。
  figureJson: (v) => {
    if (v === null || v === undefined || v === '') return null;
    if (typeof v === 'string') return v;
    if (typeof v === 'object') return JSON.stringify(v);
    return null;
  },
};

const EXPLAIN_SPEC = {
  mistakeId: text,
  knowledgePoint: text,
  channel: (v) => toText(v) ?? 'ai',
  summary: text,
  staySeconds: int0,
};

const JUDGEMENT_SPEC = {
  mistakeId: text,
  channel: (v) => toText(v) ?? 'paper',
  subject: text,
  knowledgePoint: text,
  modelVerdict: text,
  ruleVerdict: text,
};

const SUMMARY_SPEC = {
  scope: (v) => toText(v) ?? 'paper',
  scopeKey: (v) => toText(v) ?? '',
  totalCount: int0,
  passCount: int0,
  masteredCount: int0,
  remainCount: int0,
  passRate: (v, f) => toNum(v, f) ?? 0,
  weakPoints: text,
  body: text,
};

/** 一次批量写最多多少行 —— 与服务端单条语句的参数上限无关，是**业务**上限。 */
const MAX_BATCH = 100;

function batchOf(body) {
  const list = Array.isArray(body.items) ? body.items : [body];
  if (list.length === 0) throw badRequest('items 不能为空');
  if (list.length > MAX_BATCH) throw badRequest(`一次最多写入 ${MAX_BATCH} 行`);
  return list;
}

// ===== 错题池 =====

/**
 * 错题列表。
 *
 * 本地有两个方法（`queryReviewMistakes()` 与 `queryReviewMistakesByHomeworkId()`），
 * 差别只是 where 的一个条件 → 服务端合成一条（读按场景聚合）。
 *
 * ⚠️ 状态筛选由客户端传值，但**范围不由客户端定**：范围永远来自 token。
 */
export async function listMistakes(client, ctx, query) {
  const homeworkId = query?.homeworkId ? String(query.homeworkId) : null;
  const state = query?.state ? String(query.state) : null;
  const r = await client.query(
    `select * from review_mistake
      where student_id = any($1::text[])
        and ($2::text is null or homework_id = $2)
        and ($3::text is null or state = $3)
      order by created_at desc nulls last, id`,
    [ctx.students, homeworkId, state],
  );
  return { items: rowsToApi(r.rows) };
}

/** 写入错题（一张或一批）。id 逐行由服务端生成（R2）。 */
export async function insertMistakes(client, ctx, body) {
  const list = batchOf(body);
  const studentId = requireVisibleStudent(ctx.visibleStudents, body.studentId ?? list[0]?.studentId);

  // 逐条插入而不是一条多行 INSERT：图片要挂到**服务端生成的那个 id** 上，
  // 而 `INSERT ... RETURNING` 与输入的对应关系只能靠顺序约定。批量通常只有
  // 1–3 条（一次批改/一次拍题），用几条语句换掉一整类「图挂错题」的失败，值。
  //
  // 这里不需要显式事务：`withRequestContext` 已经为每个请求开了 begin/commit，
  // 所以「写题 + 写图」在服务端是原子的。
  const inserted = [];
  for (const item of list) {
    // ⚠️ `idAndServerColumns()` 返回的是 `{perRow, extras}` —— 那是
    // `buildInsertMany` 的形状。`buildInsert` 只认扁平的 `extras`，
    // 直接 spread 会把 `perRow.id` 丢掉：INSERT 撞上 `id NOT NULL`，
    // 而报错说的是「列不能为空」，看着像迁移没给默认值。
    const serverColumns = idAndServerColumns({ studentId });
    const stmt = buildInsert({
      table: 'review_mistake',
      spec: MISTAKE_SPEC,
      body: item,
      extras: [
        { column: 'id', value: serverColumns.perRow.id() },
        ...serverColumns.extras,
      ],
    });
    const r = await client.query(stmt.text, stmt.values);
    const row = r.rows[0];
    inserted.push(row);

    const images = Array.isArray(item?.images) ? item.images : [];
    if (images.length > 0) {
      await insertMistakeImagesFor(client, studentId, row.id, images);
      const counted = await client.query(
        'update review_mistake set image_count = $1 where id = $2 returning image_count',
        [images.length, row.id],
      );
      row.image_count = counted.rows[0]?.image_count ?? images.length;
    }
  }
  return { items: rowsToApi(inserted) };
}

/** 校验并写入一道错题的图片。调用方负责事务与「题属于谁」。 */
async function insertMistakeImagesFor(client, studentId, mistakeId, images) {
  for (const [index, image] of images.entries()) {
    const storageKey = requireText(image?.storageKey, 'images.storageKey');
    const mimeType = toText(image?.mimeType) ?? 'image/jpeg';
    const fileSize = toInt(image?.fileSize) ?? 0;
    const sortOrder = toInt(image?.sortOrder) ?? index;
    await client.query(
      `insert into review_mistake_image
         (id, student_id, mistake_id, storage_key, mime_type, file_size, sort_order)
       values ($1, $2, $3, $4, $5, $6, $7)`,
      [
        globalThis.crypto.randomUUID(),
        studentId,
        mistakeId,
        storageKey,
        mimeType,
        fileSize,
        sortOrder,
      ],
    );
  }
}

/** 某道错题的图片列表。mistakeId 必填 —— 没有它就是一个跨学生的全表扫描。 */
export async function listMistakeImages(client, ctx, query) {
  const mistakeId = requireText(query?.mistakeId, 'mistakeId');
  const r = await client.query(
    `select * from review_mistake_image
      where mistake_id = $1 and student_id = any($2::text[])
      order by sort_order asc, created_at asc`,
    [mistakeId, ctx.students],
  );
  return { items: rowsToApi(r.rows) };
}

/** 给已有错题补图（录入后追加、或第一次写题时图还没上传完）。 */
export async function insertMistakeImages(client, ctx, body) {
  const list = Array.isArray(body?.items) ? body.items : [];
  if (list.length === 0) throw badRequest('items 不能为空');
  const mistakeId = requireText(list[0]?.mistakeId, 'mistakeId');
  const studentId = requireVisibleStudent(ctx.visibleStudents, body.studentId);

  // 先确认这道题我看得到：直接插图片会得到一行「指向别人错题」的记录，
  // 而它在按 mistakeId 查时会被 RLS 挡掉——图写了，永远读不出来。
  const owned = await client.query(
    `select id from review_mistake where id = $1 and student_id = $2`,
    [mistakeId, studentId],
  );
  if (owned.rowCount === 0) throw forbidden('找不到这道错题（或无权修改）');

  await insertMistakeImagesFor(client, studentId, mistakeId, list);
  const counted = await client.query(
    `update review_mistake
        set image_count = (select count(*) from review_mistake_image where mistake_id = $1)
      where id = $1
      returning image_count`,
    [mistakeId],
  );
  return { inserted: list.length, imageCount: counted.rows[0]?.image_count ?? 0 };
}

export async function deleteMistakeImage(client, ctx, body) {
  const id = requireText(body?.id, 'id');
  const r = await client.query(
    `delete from review_mistake_image
      where id = $1 and student_id = any($2::text[])
      returning mistake_id`,
    [id, ctx.students],
  );
  if (r.rowCount === 0) throw notFound('图片不存在，或不在你的可见范围内');
  const mistakeId = r.rows[0].mistake_id;
  await client.query(
    `update review_mistake
        set image_count = (select count(*) from review_mistake_image where mistake_id = $1)
      where id = $1`,
    [mistakeId],
  );
  return { deleted: true, id, mistakeId };
}

/** 错题图片字节。路径与 `homework/images/file` 分开，避免把两张表的 id 混用。 */
export async function readMistakeImageBytes(client, ctx, query) {
  const store = requireImageStore(ctx);
  const id = requireText(query?.id, 'id');

  const r = await client.query(
    `select storage_key, mime_type from review_mistake_image
      where id = $1 and student_id = any($2::text[])`,
    [id, ctx.students],
  );
  const row = r.rows[0];
  if (!row) throw notFound('图片不存在，或不在你的可见范围内');

  const bytes = await store.get(row.storage_key);
  return binaryResponse(row.mime_type, bytes);
}

/** 整体覆盖一条错题（`updateReviewMistake`）——写全部 15 个字段。 */
export async function overwriteMistake(client, ctx, body) {
  const id = requireText(body.id, 'id');
  const update = buildUpdate({
    table: 'review_mistake',
    spec: MISTAKE_SPEC,
    body,
    where: 'id = $1 and student_id = any($2::text[])',
    whereValues: [id, ctx.students],
  });
  if (!update) return { ...emptyPatchResult(), id };
  const r = await client.query(update.text, update.values);
  if (r.rowCount === 0) throw forbidden('找不到这道错题（或无权修改）');
  return { item: rowToApi(r.rows[0]) };
}

/** 状态与随行字段的部分更新（`updateReviewMistakeState`）。掩码规则见文件头。 */
export async function updateMistakeState(client, ctx, body) {
  const id = requireText(body.id, 'id');
  const update = buildUpdate({
    table: 'review_mistake',
    spec: MISTAKE_STATE_SPEC,
    body,
    where: 'id = $1 and student_id = any($2::text[])',
    whereValues: [id, ctx.students],
  });
  // 掩码为空时这里**报错**而不是静默返回：这个端点的语义就是「改状态」，
  // 而 state 本身是必填的 —— 走到这里说明调用方连 state 都没给。
  if (!update) throw badRequest('缺少 state');
  const r = await client.query(update.text, update.values);
  if (r.rowCount === 0) throw forbidden('找不到这道错题（或无权修改）');
  return { touched: update.touched, item: rowToApi(r.rows[0]) };
}

/**
 * 删一道错题 —— **连同它的全部从属数据**，一次事务。
 *
 * 五张表：`review_mistake` / `review_attempt` / `judgement_ab` /
 * `ai_practice_question` / `explain_record`。
 *
 * 顺序无所谓（表之间没有外键），但**必须在同一个事务里**：中途失败留下的是
 * 一类查不出来的脏数据 —— 它不报错，只是让统计数字慢慢偏掉。
 */
export async function deleteMistake(client, ctx, body) {
  const id = requireText(body.id, 'id');

  // 先确认这道题我看得到。直接删不报错的话，客户端会以为删成功了，
  // 而它可能一道题都没删掉 —— 界面上「什么都没发生」。
  const owned = await client.query(
    `select id from review_mistake where id = $1 and student_id = any($2::text[])`,
    [id, ctx.students],
  );
  if (owned.rowCount === 0) throw forbidden('找不到这道错题（或无权删除）');

  const count = await cascadeDeleteMistake(client, id);
  return { deleted: true, id, cascaded: count };
}

/**
 * 错题及其从属表的级联删除（按错题 id）。调用方负责开事务与鉴权。
 *
 * 表的数量**刻意不写死在注释里**：P1 加了 `review_mistake_image` 之后
 * 就变成了 6 张，而写死「五表」的那种注释会把下一次加表的人引到错的地方。
 */
async function cascadeDeleteMistake(client, id) {
  const count = {};
  for (const [table, column] of [
    ['review_attempt', 'mistake_id'],
    ['judgement_ab', 'mistake_id'],
    ['ai_practice_question', 'source_mistake_id'],
    ['explain_record', 'mistake_id'],
    // 错题图片：题都不在了，图留着既占空间又会留下查不到题目的字节引用。
    ['review_mistake_image', 'mistake_id'],
  ]) {
    const r = await client.query(`delete from ${table} where ${column} = $1`, [id]);
    count[table] = r.rowCount;
  }
  const m = await client.query('delete from review_mistake where id = $1', [id]);
  count.review_mistake = m.rowCount;
  return count;
}

/**
 * 清掉某次作业带出来的全部错题（重新提交时重算）。
 *
 * ## 这里修正了本地实现的一处不对称，并因此是一次**有意的行为变化**
 *
 * 本地实现**只删 `review_mistake`**（`database_service.dart:3407`），
 * 而它的兄弟 `deleteReviewMistake` 删 5 张表。留下的孤儿有实际后果：
 * `review_attempt` 残留让毕业判定错乱，`judgement_ab` 残留让一致率
 * 多出一个「查不到题目」的分母。
 *
 * 触发路径是真实存在的：批改写错题与影子记录 → 学生重交 → 删旧错题 →
 * 新错题再写一批 → **同一道题的判定被重复计入一致率**。
 *
 * 接口注释与迁移计划都写明「上云前必须统一：服务端按 homeworkId 做单端点级联删除」，
 * 所以这里就是级联。⚠️ **两条链路因此会在这件事上不一致**：
 * 对账脚本必须把它写进「已知的有意差异」，直到 S4 客户端切到云端实现
 * （那时本地那份实现整体弃用，差异自然消失）。
 */
export async function deleteMistakesByHomework(client, ctx, body) {
  const homeworkId = requireText(body.homeworkId, 'homeworkId');

  // 先取这批错题的 id：从属表里存的是 **mistake_id** 而不是 homework_id
  // （`judgement_ab` 连 homework_id 都没有），所以级联必须按错题 id 做。
  const found = await client.query(
    `select id from review_mistake where homework_id = $1 and student_id = any($2::text[])`,
    [homeworkId, ctx.students],
  );

  const total = { review_attempt: 0, judgement_ab: 0, ai_practice_question: 0, explain_record: 0 };
  for (const row of found.rows) {
    const c = await cascadeDeleteMistake(client, row.id);
    for (const k of Object.keys(total)) total[k] += c[k];
  }

  return {
    homeworkId,
    mistakes: found.rowCount,
    deleted: {
      reviewAttempt: total.review_attempt,
      judgementAb: total.judgement_ab,
      aiPracticeQuestion: total.ai_practice_question,
      explainRecord: total.explain_record,
    },
  };
}

// ===== 组卷 =====

export async function listPapers(client, ctx) {
  const r = await client.query(
    `select * from review_paper
      where student_id = any($1::text[])
      order by created_at desc nulls last, id`,
    [ctx.students],
  );
  return { items: rowsToApi(r.rows) };
}

/**
 * 取卷内题目。
 *
 * `review_paper_item` 是**快照**：在卷的题不许删、不许改内容，
 * 否则历史卷子会随着错题本变化而变形。它自己不带学生列，可见性**顺父卷判**。
 */
export async function listPaperItems(client, ctx, query) {
  const paperId = requireText(query?.paperId, 'paperId');
  const r = await client.query(
    `select * from review_paper_item
      where paper_id = $1
      order by sort_order, id`,
    [paperId],
  );
  return { items: rowsToApi(r.rows) };
}

/**
 * 建卷 + 写题目，**一次原子写入**（`insertReviewPaperWithItems`）。
 *
 * 拆成两次调用的问题是「只写进卷没写进题目」——一份点开就空的卷子，
 * 而它的状态是 `draft`，从任何界面看都完全正常。
 */
export async function createPaper(client, ctx, body) {
  const paper = body.paper ?? body;
  const items = Array.isArray(body.items) ? body.items : [];
  if (items.length > MAX_BATCH) throw badRequest(`卷内题目一次最多 ${MAX_BATCH} 道`);

  const studentId = requireVisibleStudent(ctx.visibleStudents, body.studentId ?? paper.studentId);

  // 卷与题目的归属**必须一致**：卷能写进 A 名下、题目写进 B 名下的话，
  // 一份卷会在两个孩子的页面里各露一半。
  const mismatched = items.filter((x) => {
    const s = x?.studentId;
    return s !== undefined && s !== null && String(s) !== '' && String(s) !== studentId;
  });
  if (mismatched.length > 0) throw badRequest('卷内题目的 studentId 与卷子不一致');

  const paperId = globalThis.crypto.randomUUID();
  const ins = buildInsert({
    table: 'review_paper',
    spec: PAPER_SPEC,
    body: paper,
    extras: [
      { column: 'id', value: paperId },
      { column: 'student_id', value: studentId },
      { column: 'created_at', value: SQL_NOW },
    ],
  });
  const paperRow = await client.query(ins.text, ins.values);

  let itemRows = [];
  if (items.length > 0) {
    // `review_paper_item` 没有 created_at —— 用 `createdAt: false` 关掉它，
    // 再把 paper_id 作为广播列加上。
    const stmt = buildInsertMany({
      table: 'review_paper_item',
      spec: PAPER_ITEM_SPEC,
      rows: items,
      ...idAndServerColumns({ createdAt: false, extras: [{ column: 'paper_id', value: paperId }] }),
    });
    const r = await client.query(stmt.text, stmt.values);
    itemRows = r.rows;
  }

  return { paper: rowToApi(paperRow.rows[0]), items: rowsToApi(itemRows) };
}

export async function updatePaper(client, ctx, body) {
  const id = requireText(body.id, 'id');
  const update = buildUpdate({
    table: 'review_paper',
    spec: PAPER_SPEC,
    body,
    where: 'id = $1 and student_id = any($2::text[])',
    whereValues: [id, ctx.students],
  });
  if (!update) return { ...emptyPatchResult(), id };

  // 与 `homework.updateHomework` 同一个模式：**先读旧行**，用「前后是否真的变了」
  // 决定要不要生成通知。只看「掩码里有没有 gradedAt」会让一次网络重试
  // 重复通知一遍家长。
  const before = await client.query(
    `select * from review_paper where id = $1 and student_id = any($2::text[])`,
    [id, ctx.students],
  );
  if (before.rowCount === 0) throw forbidden('找不到这份卷子（或无权修改）');

  const r = await client.query(update.text, update.values);
  if (r.rowCount === 0) throw forbidden('找不到这份卷子（或无权修改）');
  const after = r.rows[0];

  // 批改完成 = `graded_at` 变成一个**新的非空**时刻。
  // 「变成空」= 撤销批改（本地 `ReviewController` 里没有这条路，但掩码允许），
  // 那不是一次批改事件，所以要求目标值非空。
  if (update.touched.includes('gradedAt') && after.graded_at
      && changedTs(before.rows[0].graded_at, after.graded_at)) {
    await emitReviewNotifications(client, ctx, after);
  }

  return { paper: rowToApi(after) };
}

/**
 * 改一道卷内题目（批改时逐题写回）。
 *
 * 这里**不加 student_id 条件**：这张表没有学生列，可见性由 RLS 顺着父卷判。
 * 显式再加一个子查询反而会与 policy 重复 —— 两层一旦有分歧，就会出现
 * 「policy 放行、显式条件拦住」这种最难查的不一致。
 */
export async function updatePaperItem(client, ctx, body) {
  const id = requireText(body.id, 'id');
  const update = buildUpdate({
    table: 'review_paper_item',
    spec: PAPER_ITEM_SPEC,
    body,
    where: 'id = $1',
    whereValues: [id],
  });
  if (!update) return { ...emptyPatchResult(), id };
  const r = await client.query(update.text, update.values);
  if (r.rowCount === 0) throw forbidden('找不到这道题（或无权修改）');
  return { item: rowToApi(r.rows[0]) };
}

// ===== 作答证据 =====

export async function listAttempts(client, ctx, query) {
  const mistakeId = query?.mistakeId ? String(query.mistakeId) : null;
  const r = await client.query(
    `select * from review_attempt
      where student_id = any($1::text[])
        and ($2::text is null or mistake_id = $2)
      order by created_at desc nulls last, id`,
    [ctx.students, mistakeId],
  );
  return { items: rowsToApi(r.rows) };
}

/**
 * 写作答记录（一条或一批）—— 毕业判定的**唯一依据**。
 *
 * `correct` / `score` 是判定结果，服务端只负责存：判对错的规则在客户端
 * （`ReviewService` 的 L1）。这里唯一不信任的是**归属**。
 */
export async function insertAttempts(client, ctx, body) {
  const list = batchOf(body);
  const studentId = requireVisibleStudent(ctx.visibleStudents, body.studentId ?? list[0]?.studentId);

  const stmt = buildInsertMany({
    table: 'review_attempt',
    spec: ATTEMPT_SPEC,
    rows: list,
    ...idAndServerColumns({ studentId }),
  });
  const r = await client.query(stmt.text, stmt.values);
  return { items: rowsToApi(r.rows) };
}

// ===== AI 练习 =====

export async function listPractice(client, ctx, query) {
  const sourceMistakeId = query?.sourceMistakeId ? String(query.sourceMistakeId) : null;
  const r = await client.query(
    `select * from ai_practice_question
      where student_id = any($1::text[])
        and ($2::text is null or source_mistake_id = $2)
      order by created_at desc nulls last, id`,
    [ctx.students, sourceMistakeId],
  );
  return { items: rowsToApi(r.rows) };
}

/**
 * 用一批新题**替换**某道错题的练习题（`replacePracticeQuestions`）。
 *
 * 语义是**替换不是追加**：追加会让同一道错题越攒越多旧题，
 * 而「举一反三」的口径是「这批题就是这道题的全部练习」。
 * 删除与插入必须在同一事务里 —— 中间失败会得到一道「一道题都没有」的错题，
 * 而它在界面上与「还没生成过」长得一模一样。
 */
export async function replacePractice(client, ctx, body) {
  const sourceMistakeId = requireText(body.sourceMistakeId, 'sourceMistakeId');
  const questions = Array.isArray(body.questions) ? body.questions : [];
  if (questions.length > MAX_BATCH) throw badRequest(`一次最多写入 ${MAX_BATCH} 道练习题`);

  const studentId = requireVisibleStudent(
    ctx.visibleStudents,
    body.studentId ?? questions[0]?.studentId,
  );

  await client.query('delete from ai_practice_question where source_mistake_id = $1', [sourceMistakeId]);
  if (questions.length === 0) return { items: [], replaced: sourceMistakeId };

  const stmt = buildInsertMany({
    table: 'ai_practice_question',
    spec: PRACTICE_SPEC,
    rows: questions.map((x) => ({ ...x, sourceMistakeId })),
    ...idAndServerColumns({ studentId }),
  });
  const r = await client.query(stmt.text, stmt.values);
  return { replaced: sourceMistakeId, items: rowsToApi(r.rows) };
}

export async function updatePractice(client, ctx, body) {
  const id = requireText(body.id, 'id');
  const update = buildUpdate({
    table: 'ai_practice_question',
    spec: PRACTICE_SPEC,
    body,
    where: 'id = $1 and student_id = any($2::text[])',
    whereValues: [id, ctx.students],
  });
  if (!update) return { ...emptyPatchResult(), id };
  const r = await client.query(update.text, update.values);
  if (r.rowCount === 0) throw forbidden('找不到这道练习题（或无权修改）');
  return { item: rowToApi(r.rows[0]) };
}

// ===== 讲解留痕 =====

export async function listExplains(client, ctx, query) {
  const mistakeId = query?.mistakeId ? String(query.mistakeId) : null;
  const r = await client.query(
    `select * from explain_record
      where student_id = any($1::text[])
        and ($2::text is null or mistake_id = $2)
      order by created_at desc nulls last, id`,
    [ctx.students, mistakeId],
  );
  return { items: rowsToApi(r.rows) };
}

/**
 * 写讲解记录。
 *
 * **讲解不构成毕业**（看懂 ≠ 会做），所以这里不碰 `review_mistake` 的任何字段 ——
 * 一个「顺手把状态改成 reviewing」的动作会让掌握率虚高，而它看起来像是
 * 一个贴心的补充。
 */
export async function insertExplain(client, ctx, body) {
  const studentId = requireVisibleStudent(ctx.visibleStudents, body.studentId);
  const ins = buildInsert({
    table: 'explain_record',
    spec: EXPLAIN_SPEC,
    body,
    extras: [
      { column: 'id', value: globalThis.crypto.randomUUID() },
      { column: 'student_id', value: studentId },
      { column: 'created_at', value: SQL_NOW },
    ],
  });
  const r = await client.query(ins.text, ins.values);
  return { item: rowToApi(r.rows[0]) };
}

// ===== 周期报告 =====

export async function listSummaries(client, ctx) {
  const r = await client.query(
    `select * from review_summary
      where student_id = any($1::text[])
      order by generated_at desc nulls last, id`,
    [ctx.students],
  );
  return { items: rowsToApi(r.rows) };
}

/**
 * 写周期报告 —— **同一个 (学生, 口径, 周期键) 只留一份**。
 *
 * ## 这里的结构比本地实现硬
 *
 * 本地是「id 由客户端按 `sum_{studentId}_{scopeKey}` 拼出来 + REPLACE」，
 * 也就是「一个周期一份」这件事**靠 id 的命名约定**维持，库里没有任何约束。
 * 换个客户端、或者哪天 id 的拼法变了，同一周就会静静攒出十几份报告，
 * 而它们每一份看起来都对。
 *
 * 服务端加一条 `UNIQUE (student_id, scope, scope_key)`（`sql/006_review.sql`），
 * 再用 `ON CONFLICT … DO UPDATE` 覆盖写入 —— 于是「重复生成只保留最新一份」
 * 不再依赖任何命名约定。
 *
 * id 仍由服务端生成（R2），但**确定性地**拼成 `sum_{studentId}_{scope}_{scopeKey}`：
 * 同一个周期永远是同一个 id（于是 upsert 与 id 一致，不会出现「PK 撞了但唯一键没撞」
 * 那种自相矛盾的情形），排查时看到 id 也知道是哪一期。
 */
export async function upsertSummary(client, ctx, body) {
  const studentId = requireVisibleStudent(ctx.visibleStudents, body.studentId);
  const scope = toText(body.scope) ?? 'paper';
  const scopeKey = (toText(body.scopeKey) ?? '').trim();
  if (scopeKey === '') throw badRequest('缺少 scopeKey（周期键）');

  const ins = buildInsert({
    table: 'review_summary',
    spec: SUMMARY_SPEC,
    body,
    extras: [
      { column: 'id', value: `sum_${studentId}_${scope}_${scopeKey}` },
      { column: 'student_id', value: studentId },
      { column: 'generated_at', value: SQL_NOW },
    ],
    onConflict: `on conflict (student_id, scope, scope_key) do update set
      total_count = excluded.total_count,
      pass_count = excluded.pass_count,
      mastered_count = excluded.mastered_count,
      remain_count = excluded.remain_count,
      pass_rate = excluded.pass_rate,
      weak_points = excluded.weak_points,
      body = excluded.body,
      generated_at = now()`,
  });
  const r = await client.query(ins.text, ins.values);
  return { item: rowToApi(r.rows[0]) };
}

// ===== 判定影子比对（A/B）=====

/**
 * 影子比对记录。
 *
 * ## 比本地实现多做一步：**按错题关联过滤**
 *
 * 本地 `queryJudgementAB(studentId:)` **不与 `review_mistake` 关联**
 * （`database_service.dart:2211`），孤儿行直接进入一致率的分母 ——
 * 分母变大而分子不变，一致率被**系统性低估**，而且查不出原因。
 * 接口注释明确写了「上传实现若要按 studentId 聚合，需要自己在服务端做关联过滤」，
 * 所以按 studentId 聚合时补上 inner join。
 *
 * 按 `mistakeId` 查时**不加**这个条件：那条路径的调用方手里就有错题，
 * 而且它需要能看到「错题刚被删、记录还没清」这种中间态（排查时有用）。
 * 两种口径并存是有意的 —— 它们的用途本来就不同。
 */
export async function listJudgementAB(client, ctx, query) {
  const mistakeId = query?.mistakeId ? String(query.mistakeId) : null;
  if (mistakeId !== null) {
    const r = await client.query(
      `select * from judgement_ab
        where student_id = any($1::text[]) and mistake_id = $2
        order by created_at desc nulls last, id`,
      [ctx.students, mistakeId],
    );
    return { items: rowsToApi(r.rows) };
  }
  const r = await client.query(
    `select j.* from judgement_ab j
       join review_mistake m on m.id = j.mistake_id
      where j.student_id = any($1::text[])
      order by j.created_at desc nulls last, j.id`,
    [ctx.students],
  );
  return { items: rowsToApi(r.rows) };
}

/**
 * 批量写影子比对记录（**只观察、不改判定**）。
 *
 * 一条记录 = 一次比对，不是一次作答（举一反三交 3 题就有 3 行）。
 * 这样一致率的分母才等于模型真正判定过的题数。
 */
export async function insertJudgementAB(client, ctx, body) {
  const list = batchOf(body);
  const studentId = requireVisibleStudent(ctx.visibleStudents, body.studentId ?? list[0]?.studentId);

  const stmt = buildInsertMany({
    table: 'judgement_ab',
    spec: JUDGEMENT_SPEC,
    rows: list,
    ...idAndServerColumns({ studentId }),
  });
  const r = await client.query(stmt.text, stmt.values);
  return { items: rowsToApi(r.rows) };
}

// ===== 事件 → 通知 =====

/**
 * 一轮复习批改完成后通知家长与学生（陷阱⑦的服务端落点）。
 *
 * 对应本地 `review_controller.dart` 里那段（约 1326 行）：它往**本机**的库写两条
 * 通知（一条给家长、一条给学生），所以两台手机之后家长收不到。
 *
 * ## 与本地实现的一处**刻意的信息减少**
 *
 * 本地文案里有一句「N 道已移出错题库 / 错题已回到待复习池」，且 N > 0 时标题用
 * 「错题毕业」。**服务端算不出 N**：它取决于这一轮里有多少道错题从
 * `reviewing/verifying` 走到 `mastered`，而那是客户端后续在 `updateMistakeState`
 * 里一道道写回来的 —— 服务端在这一步只看得到卷子这一行，看不见那些流转。
 *
 * 编一个数出来比少说一句坏得多（这条通知会被家长当成「孩子进步了」的证据），
 * 所以这里只说能说的：通过几道、未通过几道，标题一律用中性的
 * 「复习结果」/「复习批改完成」。将来若要恢复「错题毕业」，正确做法是让客户端
 * 在 `updatePaper` 的掩码里带上这个计数，**而不是在服务端猜**。
 */
async function emitReviewNotifications(client, ctx, after) {
  const title = after.title ?? '复习卷';
  const passCount = after.pass_count ?? 0;
  const failCount = after.fail_count ?? 0;
  const body = `《${title}》已完成批改：通过 ${passCount} 道，未通过 ${failCount} 道。`;

  await notifyBoundPartners(client, ctx, {
    to: await parentIdsOf(client, after.student_id),
    title: '复习批改完成',
    body,
    type: NotificationTypes.review,
    relatedBizId: after.id,
  });

  // 学生自己也有一份。与作业那条同理：一条给家长看结果，一条是提醒学生
  // 「这一轮的结果出来了」，而这两群人在两台设备上。
  await notifyBoundPartners(client, ctx, {
    to: [after.student_id],
    title: '复习结果',
    body,
    type: NotificationTypes.review,
    relatedBizId: after.id,
  });
}
