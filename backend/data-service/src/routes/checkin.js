import { randomUUID } from 'node:crypto';

import {
  ApiError,
  ErrorCodes,
  badRequest,
  notFound,
  quizVersionConflict,
} from '../../../shared/errors.js';
import { requireVisibleStudent } from '../auth.js';
import { requireText, toEnum, toInt, toStringArray, toText } from '../coerce.js';
import { syncStudentArchive } from './ima.js';
import { advanceUnitCursor, resolveTextbookPoints } from './textbook.js';

/**
 * 每日概念打卡。
 *
 * ## 答案随题下发，靠界面挡住
 *
 * 题目（含 `answer` / `analysis`）会一起发到孩子设备上。这不是疏忽：
 * 交卷时要在**本机立刻**判出对错，那台设备上就得有判定依据；否则
 * 交完卷还得等云端返回，弱网时那几秒钟的转圈能把人烦死。
 *
 * 「看不到」由客户端渲染层保证 —— 答题态只渲染题干与选项。所以
 * 改客户端页面时要记得：**答题分支里绝不能碰 `answer` / `analysis`**，
 * 那条约束由 `test/checkin_page_test.dart` 守着。
 *
 * 代价说清楚：能抓包或调试的人可以看到答案。这不是考试，接受。
 *
 * ## 判分在这里**复算**，不信客户端传来的分数
 *
 * 客户端本地判分是为了即时反馈（不等网络），但入库的分数由服务端按题目快照
 * 重新算一遍。理由不是防作弊（本轮不是考试），而是防**算错**：
 * 客户端判分逻辑一旦与题目结构对不上（比如选项被重新排序），
 * 学生看到「4/5」而库里存着 5 —— 两个数字此后会一直打架，
 * 家长端、ima 档案、统计各说各的，且没有任何报错。
 *
 * 两处判分必须同口径：答案与作答都先 `trim().toUpperCase()`，再比字符串相等；
 * 空作答恒为错（不给「没选算对」留口子）。客户端侧的同一规则见
 * `CheckinSubmitResult.judge`。
 *
 * ## 一次出题 = 一份独立试卷（2026-10-27 起）
 *
 * **没有「一天一科目只许一份」这回事了**（`sql/022_checkin_drop_subject_unique.sql`
 * 已删掉 `uq_checkin_quiz` 唯一键）。家长想出几套就出几套，每套是一条
 * 独立的 `checkin_quiz` 行、各有各的 id 与成绩，学生挨个做。
 *
 * 为什么这条要写清楚：早先的「覆盖当天同科目旧卷」是为了解决串题，但它把
 * 两件事绑死了 —— 「防串题」其实只需要**每次换新 id**（旧 id 交卷 404），
 * 不需要**删掉旧卷**。删旧卷等于家长多出一份就把上一份和孩子的成绩一起
 * 抹了，孩子正做到一半那份直接消失，家长端也只剩最新那份，很反直觉。
 * 现在「防串题」由「id 每次新生成」保证，「多份并存」由「不删旧行」保证。
 */

const MAX_QUESTIONS = 10;
const CHOICE_LETTERS = ['A', 'B', 'C', 'D', 'E', 'F'];

/**
 * 出题难度。词表与复核/举一反三那条链路的 `difficulty` **完全一致**
 * （`ai-gateway/src/prompts.js` 的 reviewPractice 也用这三个词），
 * 不另造「简单 / 中等 / 困难」—— 同一个概念在档案里叫两个名字，
 * 统计时就永远对不上，而且两边都不会报错。
 */
const DIFFICULTIES = ['基础', '提高', '挑战'];

/**
 * 家长一次最多指定几个知识点。
 *
 * 6 不是随便定的：网关的 `MAX_CHECKIN_ITEMS` 就是 6，超过它会整单 400。
 * 两处必须同步，否则服务端放行、网关拒收，用户看到的是「出题失败」
 * 而原因在一个他碰不到的服务里。上限的语义也说得通 —— 知识点再多，
 * 题量会被摊薄成「每个只碰一下」，那叫浏览不叫复习。
 */
const MAX_SEED_POINTS = 6;

/** 家长选知识点时看到的候选条数。比能选的 6 个多，否则等于没得选。 */
export const MAX_SEED_CANDIDATES = 30;

/**
 * 打卡列表的单页上限。
 *
 * 分页只在「已完成」那条路上用（复盘往回翻）；50 是随手划十几次也翻不完的量，
 * 再大就该换成真正的游标分页了 —— 但现在一天最多几份，offset 足够。
 */
const PAGE_MAX = 50;

/** 列表过滤：不传 = 全部（老客户端只给 `quizDate` 时行为与原来一致）。 */
const STATUS_FILTERS = ['all', 'pending', 'done'];

const isDate = (value) => /^\d{4}-\d{2}-\d{2}$/.test(value);

/**
 * 知识点的比较口径：**去掉所有空白再比**。
 *
 * 教材章节标题是「第 7 课 百家争鸣」（人写的中文习惯留空格），模型转一手
 * 很容易写成「第7课 百家争鸣」。严格相等会把它判成越界、整单丢掉，而家长
 * 看到的只是一句「模型这次没给出合格题目」—— 真正的原因看不见。
 *
 * 只归一空白和大小写，不做语义近似：`分数运算` 与 `分数的运算` 仍然算两个，
 * 那属于家长的配置问题，不该由服务端替他猜。
 */
const knowledgeKey = (value) =>
  String(value ?? '').replace(/[\s\u3000]+/g, '').toLowerCase();

function requireDate(value, field, { fallback = '' } = {}) {
  const one = String(toText(value) ?? fallback).trim();
  if (one === '') throw badRequest(`${field} 不能为空`);
  if (!isDate(one)) throw badRequest(`${field} 必须是 yyyy-MM-dd`);
  return one;
}

/**
 * 题目校验：**只接受本地判分得了的两种题型**。
 *
 * 这不是「模型给什么就存什么」的透传层。网关已经拦过一遍（见
 * `pruneCheckinQuestions`），但那条路可以被绕过（老客户端、手写请求），
 * 而库里一旦存了填空/解答题，判分会永远算成错 —— 静默且不可救。
 */
function normalizeQuestions(raw) {
  if (!Array.isArray(raw) || raw.length === 0) {
    throw badRequest('questions 应为非空数组');
  }
  if (raw.length > MAX_QUESTIONS) {
    throw badRequest(`一次最多 ${MAX_QUESTIONS} 道题`);
  }

  const questions = raw.map((item, index) => {
    const at = `第 ${index + 1} 题`;
    if (!item || typeof item !== 'object') throw badRequest(`${at} 不是对象`);

    const stem = String(toText(item.stem) ?? '').trim();
    if (stem === '') throw badRequest(`${at} 缺题干`);

    const knowledge = String(toText(item.knowledge) ?? '').trim();
    if (knowledge === '') throw badRequest(`${at} 缺知识点`);

    const type = item.type === 'judge' ? 'judge' : item.type === 'choice' ? 'choice' : '';
    if (type === '') throw badRequest(`${at} 的题型只能是 choice / judge`);

    const analysis = String(toText(item.analysis) ?? '').trim();

    if (type === 'judge') {
      const rawAnswer = String(toText(item.answer) ?? '').trim().toUpperCase();
      const answer = ['T', 'TRUE', '对', '正确', '√', 'V'].includes(rawAnswer)
        ? 'T'
        : ['F', 'FALSE', '错', '错误', '×', 'X'].includes(rawAnswer)
          ? 'F'
          : '';
      if (answer === '') throw badRequest(`${at} 的判断题答案无法识别：${item.answer}`);
      return { type, stem, options: ['正确', '错误'], answer, knowledge, analysis };
    }

    const options = Array.isArray(item.options)
      ? item.options.map((o) => String(toText(o) ?? '').trim()).filter((o) => o !== '')
      : [];
    if (options.length < 2) throw badRequest(`${at} 的选择题选项不足 2 个`);

    const rawAnswer = String(toText(item.answer) ?? '').trim().toUpperCase();
    const letter = (rawAnswer.match(/[A-F]/) ?? [''])[0];
    if (letter === '') throw badRequest(`${at} 的答案不是选项字母：${item.answer}`);
    if (CHOICE_LETTERS.indexOf(letter) >= options.length) {
      throw badRequest(`${at} 的答案 ${letter} 超出选项数 ${options.length}`);
    }
    return { type, stem, options, answer: letter, knowledge, analysis };
  });

  return questions;
}

/**
 * 落库一份**独立**试卷。
 *
 * 两个入口共用：`saveCheckinQuiz`（调用方给题）与 `generateCheckin`
 * （服务端自己出题）。**落库只留一处**，否则两处口径迟早分叉。
 *
 * ## 不做任何「覆盖」（2026-10-27）
 *
 * 原先这里先 `delete checkin_result` + `delete checkin_quiz` 再插入，用来
 * 「同日同科目只留一份」。那个语义已经被废除：家长一次出题就是一份新卷，
 * 同一天同一科目出十套就有十份，每份各自作答、各自出分。所以这里只有一条
 * INSERT —— **绝不能**再按 `(student_id, quiz_date, subject)` 删任何东西，
 * 否则家长多出一套会把孩子正在做的那套连同成绩一起删掉。
 *
 * 串题防护不再依赖「删旧行」，而是依赖**调用方每次生成新 id**：
 * 旧卷的 id 依然指向旧卷本身（题目没变），交卷能对上；如果客户端手里是
 * 已经被丢弃的卷，那只可能是 id 抄错，由交卷校验的「每题恰好一份」拦下。
 */
async function insertCheckinQuiz(
  client,
  { id, studentId, ownerUserId, quizDate, subject, difficulty, questions },
) {
  const result = await client.query(
    `insert into checkin_quiz
       (id, student_id, owner_user_id, quiz_date, subject, difficulty, questions, status)
     values ($1, $2, $3, $4, $5, $6, $7::jsonb, 'pending')
     returning id, student_id, quiz_date::text as quiz_date,
               subject, difficulty, questions, status`,
    [
      id,
      studentId,
      ownerUserId,
      quizDate,
      subject,
      difficulty,
      JSON.stringify(questions),
    ],
  );
  return result.rows[0];
}

/**
 * 发起一份打卡试卷 —— 题目由调用方给。
 *
 * ⚠️ **客户端已经不走这条了**（改走 `generate`，题在服务端出）。
 * 保留它是为了「已经有题、只想落一份」的场景与测试；两条路共用同一个
 * `insertCheckinQuiz`，落库口径不会分叉。
 *
 * 每次调用都是**一份新的独立试卷**：不删除、不覆盖同日同科目的旧卷
 * （见 `insertCheckinQuiz`）。调用方**必须采纳返回值里的 id**（R2）——
 * 自己编的 id 若重了会撞主键报错，而旧 id 交卷会指向旧那份卷。
 */
export async function saveCheckinQuiz(client, ctx, body) {
  const studentId = requireVisibleStudent(ctx.visibleStudents, body?.studentId);
  const quizDate = requireDate(body?.quizDate, 'quizDate');
  const subject = String(toText(body?.subject) ?? '').trim();
  // 两条入口同口径：`generate` 也走这个白名单。
  const difficulty = toEnum(body?.difficulty, 'difficulty', DIFFICULTIES) ?? '';
  const questions = normalizeQuestions(body?.questions);

  const id = String(requireText(body?.id, 'id') ?? '').trim();
  if (id === '') throw badRequest('缺少 id');
  if (id.length > 64) throw badRequest('id 过长');

  const row = await insertCheckinQuiz(client, {
    id,
    studentId,
    ownerUserId: String(ctx.userId ?? ''),
    quizDate,
    subject,
    difficulty,
    questions,
  });

  // R2：写接口必须把服务端认可的那一行返回 —— 客户端用它拿真正的主键。
  return {
    quiz: {
      id: row.id,
      studentId: row.student_id,
      quizDate: row.quiz_date,
      subject: row.subject,
      difficulty: row.difficulty,
      questions: row.questions,
      status: row.status,
    },
  };
}

/**
 * 从云端错题本聚合出题锚点，**全部**返回（按累计错次降序）。
 *
 * 这段逻辑原先在客户端（`CheckinController._defaultSeeds`），搬过来的同时
 * 保持**同一口径**：按知识点累计错次、保留最长的那条错因。
 *
 * 返回全部而不是「前 6 个」：家长选知识点时要看到候选列表，
 * 只给 6 个候选再让人从里面挑 6 个，等于没得选。截断交给
 * [resolveCheckinSeeds]（出题）与 [listCheckinSeeds]（候选）各自决定。
 *
 * 不过滤 `state`：客户端那边也没过滤，两处口径必须一致，否则「家长发起」
 * 与「学生自发起」会拿到不同的知识点集合，而两边看到的界面一模一样。
 */
/**
 * 错题本聚合出的知识点候选（按累计错次降序）。
 *
 * [subject] 非空时**只取这一科**：学科配置页要按科目列范围，
 * 把数学的知识点列在语文下面会让家长以为孩子语文错过「整式化简」。
 * 空串保持旧行为（全部科目）—— `GET /data/checkin/seeds` 的出题页用它。
 */
export async function collectCheckinSeeds(client, studentId, subject = '') {
  const params = [studentId];
  let where = `student_id = $1 and coalesce(knowledge_point, '') <> ''`;
  const one = String(subject ?? '').trim();
  if (one !== '') {
    params.push(one);
    where += ` and subject = $${params.length}`;
  }

  const result = await client.query(
    `select knowledge_point, wrong_count, wrong_reason
       from review_mistake
      where ${where}`,
    params,
  );

  const counts = new Map();
  const reasons = new Map();
  for (const row of result.rows) {
    const point = String(row.knowledge_point ?? '').trim();
    if (point === '') continue;
    // `wrong_count` 可能是 0（历史数据）：那种情况下按「错过一次」算，
    // 否则这个知识点会永远排最后、永远轮不到考。
    const wrong = Number(row.wrong_count) > 0 ? Number(row.wrong_count) : 1;
    counts.set(point, (counts.get(point) ?? 0) + wrong);
    const reason = String(row.wrong_reason ?? '').trim();
    if (reason.length > (reasons.get(point)?.length ?? 0)) reasons.set(point, reason);
  }

  return [...counts.entries()]
    // 同分时按知识点名排：SQL 不保证行序，没有这条兜底，
    // 同样的错题本在两次请求里可能出不同顺序的题（测试里也不稳定）。
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0], 'zh'))
    .map(([knowledge, wrongCount]) => ({
      knowledge,
      wrongCount,
      wrongReason: reasons.get(knowledge) ?? '',
    }));
}

/**
 * 家长指定的知识点：去空、去重、保序，超过上限就 400。
 *
 * **顺序有意义** —— 它就是「先考哪个」的优先级，所以不能排序。
 */
function normalizeKnowledgePoints(raw) {
  const list = toStringArray(raw, 'knowledgePoints');
  if (list === null) return [];

  const out = [];
  const seen = new Set();
  for (const item of list) {
    const point = String(toText(item) ?? '').trim();
    if (point === '' || seen.has(point)) continue;
    seen.add(point);
    out.push(point);
  }
  if (out.length > MAX_SEED_POINTS) {
    throw badRequest(
      `knowledgePoints 最多 ${MAX_SEED_POINTS} 个（收到 ${out.length} 个）`,
    );
  }
  return out;
}

/**
 * 挑出这次真正要考的知识点。
 *
 * 家长指定了就按他给的顺序来；没指定（学生自发起）就取错得最多的前几个。
 *
 * 指定了、但错题本里**没有记录**的知识点会保留（`wrongCount = 0`）。
 * 这是刻意的：家长可能想让孩子提前练还没掌握的内容，而错题本只能反映
 * 「已经错过什么」。防线在家长端 —— 那里会标出「还没有错题记录」，
 * 让家长知道这个选择意味着什么。
 */
function resolveCheckinSeeds(candidates, requested) {
  if (requested.length === 0) return candidates.slice(0, MAX_SEED_POINTS);

  const byPoint = new Map(candidates.map((seed) => [seed.knowledge, seed]));
  return requested.map(
    (knowledge) =>
      byPoint.get(knowledge) ?? { knowledge, wrongCount: 0, wrongReason: '' },
  );
}

/**
 * 家长在「学科范围」里存下来的知识点（`subject_scope.points`）。
 *
 * 学生自己点「出 5 道题」时不带 `knowledgePoints`，服务端必须补上这一份 ——
 * 否则家长配置的范围只对家长自己的入口生效，孩子那条路按别的来源出题，
 * 而两条路的界面长得一模一样，谁也看不出差别。
 *
 * **读失败一律返回空数组**（026 未迁移、表不在）：范围是可选配置，
 * 不能因为一张表不在就让出题整条挂掉；真没有范围时由调用方给明确提示。
 */
async function scopePointsOf(client, studentId, subject) {
  try {
    const r = await client.query(
      'select points from subject_scope where student_id = $1 and subject = $2',
      [studentId, subject],
    );
    const raw = r.rows[0]?.points;
    if (!Array.isArray(raw)) return [];
    const out = [];
    for (const item of raw) {
      const point = String(toText(item) ?? '').trim();
      if (point !== '' && !out.includes(point)) out.push(point);
      if (out.length >= MAX_SEED_POINTS) break;
    }
    return out;
  } catch {
    return [];
  }
}

/**
 * 服务端直接出题：教材 / 家长指定范围 → 调 AI 网关 → 校验 → 落库 → 返回题目。
 *
 * ## 为什么要有这条端点
 *
 * 让「聚合哪几个知识点」只有一个口径，客户端也不用先有本地错题本。
 * 在此之前出题在客户端完成，客户端要把本地错题聚合成锚点再上传 ——
 * 那份口径与云端错题表是两套数据源，选出来的知识点集合会不一样，
 * 而两边界面长得一模一样。
 *
 * 下发的 `questions` **带 `answer` / `analysis`**：孩子交卷时要在本机
 * 立刻判对错，不等网络。看不到答案靠客户端渲染层保证（见客户端
 * `CheckinQuestion.answer` 的说明）。
 *
 * ## 拒收时的处置
 *
 * 模型违约（题不够、结构不对、答案不在选项里）不写库，直接报
 * `schema_violation`（可重试）。**不退回客户端出题** —— 那会让同一个
 * 动作有两条实现，出问题时分不清走的是哪条；而且客户端出题失败时
 * 用户看到的仍然是「没有题目」，看不出差别。
 */
export async function generateCheckin(client, ctx, body) {
  const studentId = requireVisibleStudent(ctx.visibleStudents, body?.studentId);
  const quizDate = requireDate(body?.quizDate, 'quizDate');
  const subject = String(toText(body?.subject) ?? '').trim() || '数学';
  const requested = toInt(body?.count, 'count');
  const count = Math.min(Math.max(requested ?? 5, 1), MAX_QUESTIONS);

  // 计划的内容只有两个来源：**教材**（按章节推进）或**家长指定的知识点**
  // （发起页里临时勾的，或范围页里存下来的）。错题本属于「复习」那条线，
  // 不是这里的书源 —— 以前没有范围时会静默回落到同科错题，于是
  // 「历史还没学过 ⇒ 不可能有错题 ⇒ 每点一次 400」，而家长明明配好了课本。
  //
  // 空串难度 = 没要求（学生自发起走这条），不硬塞一个「基础」。
  let requestedPoints = normalizeKnowledgePoints(body?.knowledgePoints);
  const difficulty = toEnum(body?.difficulty, 'difficulty', DIFFICULTIES) ?? '';

  if (!ctx.aiGateway || typeof ctx.aiGateway.postJson !== 'function') {
    throw new ApiError(
      ErrorCodes.modelNotEnabled,
      '这台部署没有接上 AI 网关（AI_GATEWAY_BASE_URL），每日打卡暂时出不了题',
      { retryable: false, details: { configMissing: 'AI_GATEWAY_BASE_URL' } },
    );
  }

  // **教材优先**：家长在范围页选了书和起始章，就是「按课本进度出」。
  // 此时 `knowledgePoints`（= 范围页里手填的那几条）不再参与 —— 否则
  // 两套范围会混在一起，家长看到「我明明配了课本却考了手填的那条」。
  // 取不到（没配教材 / 章节没写考点 / 027 未迁移）就走下面两条来源。
  const textbook = await resolveTextbookPoints(client, studentId, subject, MAX_SEED_POINTS);
  if (textbook) {
    requestedPoints = textbook.points;
    if (textbook.titleOnlyPoints?.length) {
      // 教材骨架里没写「考点：」行，只能拿章节标题当知识点。题出得对不对
      // 全看这一条 —— 以后家长说「历史出的题跑偏了」，先看这里。
      console.log(
        `[checkin] ${subject}：${textbook.titleOnlyPoints.length}/${textbook.points.length} `
          + '个知识点取自章节标题（骨架 MD 里没有「考点：」行）',
      );
    }
  }

  // 学生自发起不带 `knowledgePoints`：这时读**家长在范围页存下来的那一份**。
  // 少了这一步，家长配好的范围只对「家长自己点色块」生效，孩子点
  // 「出 5 道题」却按别的东西出 —— 两边界面一模一样，没人看得出差别。
  if (!textbook && requestedPoints.length === 0) {
    requestedPoints = await scopePointsOf(client, studentId, subject);
  }

  if (requestedPoints.length === 0) {
    // 到这里就是「这科一条范围都没有」：没配教材、没填知识点。
    // 历史、政治这类**还没学过所以不可能有错题**的科目最容易撞上 ——
    // 所以文案不能只说「先录几道错题」：那条路对它们根本不存在。
    //
    // 不编造题目去凑一次打卡，也**不拿错题本兜底**：错题本属于复习，
    // 拿它出打卡等于把两条线的来源混在一起，家长看不出来。
    throw new ApiError(
      ErrorCodes.badRequest,
      `${subject}还没有出题范围：给这一科选一本教材（按章节出），或者填两个知识点。`,
      { details: { reason: 'no_seed', subject } },
    );
  }

  // 候选只用来补「错过几次 / 错因」这两个字段（模型据此调难度），
  // **不再作为来源**：范围为空时上面已经报错了。
  // ⚠️ 必须带上 `subject`：不传会把全科错题聚成一锅。
  const candidates = await collectCheckinSeeds(client, studentId, subject);
  const seeds = resolveCheckinSeeds(candidates, requestedPoints);

  const generated = await ctx.aiGateway.postJson('/ai/checkin/generate', {
    authHeader: ctx.authHeader ?? '',
    studentId,
    body: { subject, count, difficulty, items: seeds },
  });

  const raw = generated?.data?.questions;
  if (!Array.isArray(raw) || raw.length === 0) {
    throw new ApiError(
      ErrorCodes.schemaViolation,
      'AI 网关没有返回任何可用的打卡题目',
      { status: 502, retryable: true },
    );
  }

  // 网关已经 prune 过一遍，这里再校验一次：这一层挡的是**网关自己的 bug**
  // （比如将来改了题结构却忘了改答案范围）。校验失败是服务端问题，
  // 不能报成 400 —— 那会让客户端以为是自己请求写错了。
  let questions;
  try {
    questions = normalizeQuestions(raw);
  } catch (cause) {
    throw new ApiError(
      ErrorCodes.schemaViolation,
      'AI 返回的题目结构不合格，本次没有存题',
      { status: 502, retryable: true, cause: cause instanceof Error ? cause : undefined },
    );
  }

  // 家长指定了范围，就**只收范围内的题**。
  //
  // 模型偶尔会「顺手」多出一道相关的、但没被要求的知识点。放行它等于
  // 静默违背家长的意图，而界面上看不出来（那道题本身看起来完全合理）。
  // 单条越界只弃自己（与网关 prune 的口径一致），全越界才整单失败。
  if (requestedPoints.length > 0) {
    // 比较时归一空白（见 `knowledgeKey`），命中后**改回请求里的原文**：
    // 客户端和错题归档都按 knowledge 字符串关联，存模型的小变体会对不上。
    const canonical = new Map();
    for (const point of requestedPoints) canonical.set(knowledgeKey(point), point);

    const inRange = [];
    for (const question of questions) {
      const matched = canonical.get(knowledgeKey(question.knowledge));
      if (matched === undefined) continue;
      inRange.push(matched === question.knowledge ? question : { ...question, knowledge: matched });
    }
    if (inRange.length === 0) {
      throw new ApiError(
        ErrorCodes.schemaViolation,
        'AI 出的题都不在指定知识点范围内，本次没有存题',
        { status: 502, retryable: true },
      );
    }
    questions = inRange;
  }

  const row = await insertCheckinQuiz(client, {
    // 服务端自己生成 id：客户端不再参与。**每次出题都是一份新卷**，
    // id 天然唯一，同一天同科目可以并存任意多份（不再覆盖旧卷）。
    id: `ck_${randomUUID()}`,
    studentId,
    ownerUserId: String(ctx.userId ?? ''),
    quizDate,
    subject,
    difficulty,
    questions,
  });

  // 教材游标只在**入库成功之后**推进。失败还推的话，家长点一次没出成、
  // 再点一次，范围已经往后跳了一节 —— 那一节从此再也不会被考到。
  if (textbook) {
    await advanceUnitCursor(client, studentId, subject, textbook.nextStart);
  }

  return {
    quiz: {
      id: row.id,
      studentId: row.student_id,
      quizDate: row.quiz_date,
      subject: row.subject,
      difficulty: row.difficulty,
      // 题目**带答案**下发（含 `analysis`）。取舍见文件头「答案为什么下发」。
      questions: row.questions,
      status: row.status,
    },
    // 只回计数：网关的 `rejected` 里有**被拒的坏题原文**，那是调试信息，
    // 不是这次打卡的一部分。混进来会让「这道题为什么没出」看起来像出了。
    generated: {
      kept: questions.length,
      seeds: seeds.length,
      mode: requestedPoints.length === 0 ? 'auto' : 'manual',
    },
  };
}

/**
 * 出题候选：家长挑知识点时看到的列表。
 *
 * 与出题走**同一段聚合逻辑**（[collectCheckinSeeds]），只是不截到 6 个 ——
 * 家长要从更大的集合里选。这里如果另写一份查询，两处的「错次」
 * 迟早算成不一样，而家长会以为是数据丢了。
 */
export async function listCheckinSeeds(client, ctx, query) {
  const studentId = requireVisibleStudent(ctx.visibleStudents, query?.studentId);
  // `subject` 可选，与 `collectCheckinSeeds` 同一个口径：家长发起页切到
  // 「语文」时不能再列出数学的候选（勾上就会拿它去出语文题）。
  // 不传保持旧行为（全科合并）—— 老客户端还在这么调。
  const subject = String(toText(query?.subject) ?? '').trim();
  const all = await collectCheckinSeeds(client, studentId, subject);
  return {
    seeds: all.slice(0, MAX_SEED_CANDIDATES),
    total: all.length,
  };
}

/**
 * 从落库的原始作答 + 题目快照，重建**逐题判定明细**。
 *
 * ## 为什么读的时候派生、不在提交时另存一份
 *
 * `checkin_result.answers` 存的就是 `[{index, picked}]`，题目快照里有
 * `answer` / `knowledge` —— 明细是这两份数据的**纯函数**，再存一份列
 * 只会多出一处会漂的副本。判定口径与 `submitCheckin` 复算、客户端
 * `CheckinSubmitResult.judge` 三处同一条：`trim()` + 大写 + 相等，
 * 空作答恒为错。
 *
 * 没有它，重开页面时（分数从库里读回）逐题明细就是空的 ——
 * 孩子和家长都只能看到一句「有 1 题要再看看」，
 * 看不到到底是哪题、选了什么、该选什么（2026-10-27 用户报的就是这个）。
 */
function deriveCheckinItems(questions, answers) {
  const pickedByIndex = new Map(
    (Array.isArray(answers) ? answers : [])
      .filter((item) => item && typeof item === 'object')
      .map((item) => [Number(item.index), String(item.picked ?? '')]),
  );
  return questions.map((q, index) => {
    const mine = String(pickedByIndex.get(index) ?? '').trim().toUpperCase();
    const answer = String(q?.answer ?? '').toUpperCase();
    return {
      index,
      knowledge: String(q?.knowledge ?? ''),
      picked: mine,
      answer,
      correct: mine !== '' && mine === answer,
    };
  });
}

/**
 * 打卡列表（跨天）—— 未完成与已完成分开取。
 *
 * ## 为什么不再按天
 *
 * 原来只取 `quizDate` 那一天。家长头天晚上出的题，孩子第二天早上打开
 * 一份也看不到，而计划页入口卡按「今天没题」亮着绿标「待完成」 ——
 * 用户 2026-10-29 报的「看得到未完成、点进去没有」就是这两处口径打架。
 * 现在出题与**做题**解耦：家长出过的卷子一直等着孩子，直到他做完。
 *
 * 参数（都可选：
 *  · `status` = `all` / `pending` / `done`（默认 all）
 *  · `subject` = 只看这一科（空 = 全部；见下面的说明）
 *  · `limit` = 0 表示不限；最大 {@link PAGE_MAX}
 *  · `offset` 翻页偏移
 *
 * 返回 `{quizzes, total, hasMore}`：`total` 是**过滤后的总数**，
 * 客户端靠它显示「共 N 份」并判断还有没有下一页。
 *
 * 题目**始终带答案**（含 `analysis`）：孩子交卷时要在本机立刻判对错，
 * 那台设备上就得有判定依据。答案不显示在界面上，由客户端负责。
 *
 * 已交卷的那份，`result.items` 是**逐题明细**（见 [deriveCheckinItems]）——
 * 没有它，重开页面只能看到一句汇总分数，复盘无从谈起。
 */
export async function getCheckinQuiz(client, ctx, query) {
  const studentId = requireVisibleStudent(ctx.visibleStudents, query?.studentId);

  // `quizDate` 仍然接受，但**不再必填**。
  //
  // 2026-10-29 之前这个接口的语义是「取今天的全部打卡」；家长头天出的题，
  // 孩子第二天打开就一份也看不到，计划页却按「今天没题」亮着绿标「待完成」
  // —— 用户报的「看得到未完成、点进去没有」就是这条。现在改成**跨天列表**，
  // 日期只是个可选过滤（老客户端还在传，行为退化成原来的「看那一天」）。
  const quizDate = query?.quizDate ? requireDate(query.quizDate, 'quizDate') : null;
  const status = toEnum(query?.status, 'status', STATUS_FILTERS) ?? 'all';

  // 按科目取（2026-11-12）：学生的「已完成」在页面上按科目分组，点进某一科
  // 只看这一科的记录。**不校验白名单**：这里只是个过滤词，认不出来就是空列表，
  // 而白名单校验属于「写」的规矩 —— 读接口为了一个拼错的历史科目名回 400，
  // 只会让页面整块报错，什么也修不了。
  const subject = String(toText(query?.subject) ?? '').trim();

  // `limit = 0` 表示不限（未完成那份要全量：通常一两份，且漏掉最老的那份
  // 恰好就是孩子最该补的）。
  const limit = toInt(query?.limit, 'limit') ?? 0;
  if (limit < 0 || limit > PAGE_MAX) throw badRequest(`limit 必须在 0~${PAGE_MAX} 之间`);
  const offset = toInt(query?.offset, 'offset') ?? 0;
  if (offset < 0) throw badRequest('offset 不能为负');

  // 「做完没有」以**成绩行在不在**为准，不看 `status` 字段。
  //
  // 两者理论上同步（`submitCheckin` 在同一事务里都写），但一旦出现脏数据，
  // 页面是按成绩行判断「能不能重答」的。查询口径必须与渲染口径一致，
  // 否则会出现「列在未完成里、点进去却是成绩单」这种自相矛盾的界面。
  const doneExpr = '(r.quiz_id is not null)';
  const baseParams = [studentId, quizDate];
  let statusSql = '';
  if (status !== 'all') {
    // 走参数而不是把 true/false 拼进 SQL：拼进去没法从 params 看出过滤条件，
    // 假 client 的用例也就只能断「SQL 里出现过字符串」——那种断言在过滤写反时照样绿。
    baseParams.push(status === 'done');
    statusSql = ` and (${doneExpr} = $${baseParams.length}::boolean)`;
  }
  let subjectSql = '';
  if (subject !== '') {
    baseParams.push(subject);
    subjectSql = ` and q.subject = $${baseParams.length}`;
  }
  const where =
    `q.student_id = $1 and ($2::text is null or q.quiz_date = $2::date)` +
    `${statusSql}${subjectSql}`;

  // 排序按「用户接下来要做什么」定，不是按技术上的方便：
  //  · 未完成 → 出题时间**正序**：家长先出的先做，不被最新那份一直插队；
  //  · 已完成 → 交卷时间**倒序**：复盘看的是最近做的。
  const orderBy =
    status === 'done'
      ? 'r.submitted_at desc nulls last, q.created_at desc, q.id desc'
      : 'q.created_at asc, q.id asc';

  const counted = await client.query(
    `select count(*)::int as total
       from checkin_quiz q
       left join checkin_result r on r.quiz_id = q.id
      where ${where}`,
    baseParams,
  );
  const total = counted.rows[0]?.total ?? 0;

  const params = [...baseParams];
  let pageSql = '';
  if (limit > 0) {
    params.push(limit, offset);
    pageSql = ` limit $${params.length - 1} offset $${params.length}`;
  }

  const result = await client.query(
    `select q.id, q.student_id, q.quiz_date::text as quiz_date,
            q.subject, q.difficulty, q.questions, q.status,
            r.answers, r.score, r.total, r.submitted_at
       from checkin_quiz q
       left join checkin_result r on r.quiz_id = q.id
      where ${where}
      order by ${orderBy}${pageSql}`,
    params,
  );

  const quizzes = result.rows.map((row) => {
    const questions = Array.isArray(row.questions) ? row.questions : [];
    return {
      quiz: {
        id: row.id,
        studentId: row.student_id,
        quizDate: row.quiz_date,
        subject: row.subject,
        difficulty: row.difficulty,
        // 已交卷与未交卷都带答案 —— 判分在客户端是本机做的，
        // 拿不到答案就等于交完卷还要等云端，弱网时转圈转到怀疑人生。
        questions: row.questions,
        status: row.status,
      },
      result:
        row.submitted_at !== null && row.submitted_at !== undefined
          ? {
              answers: row.answers,
              score: row.score,
              total: row.total,
              submittedAt: row.submitted_at,
              items: deriveCheckinItems(questions, row.answers),
            }
          : null,
    };
  });

  // `total` 是**过滤后的总数**（不受 limit/offset 影响），分页要它算还剩多少；
  // `limit = 0` 时本来就是一整份，`hasMore` 恒 false。
  return {
    quizzes,
    total,
    hasMore: limit > 0 && offset + quizzes.length < total,
  };
}

/**
 * 已完成的打卡**按科目汇总**（学生端「已完成」那半页的大色块用）。
 *
 * ## 为什么需要一个聚合接口
 *
 * 页面上「数学 12 份 / 语文 5 份」这种数字必须是真数。用 `getCheckinQuiz`
 * 自己数的话只有两条路：① 只数已加载的那一页（分页 10 条时数字会骗人）；
 * ② `limit=0` 一次全拉回来（每份都带题干、答案、解析，几十份就是几百 KB）。
 * 两条都不行，所以让库 `group by` 一次算完 —— 返回的是**计数与最近一次成绩**，
 * 不含题目。
 *
 * ## 只统计**已交卷**的
 *
 * `join checkin_result` 是内连接（不是 left join）：没有成绩行就意味着没做完，
 * 归「未完成」那半页管。两个半页各统计各的，数字加起来正好等于总数。
 *
 * 科目为空的历史行归到「其他」—— 与 `getCheckinQuiz` 的渲染口径一致，
 * 否则那些卷子会从分组里消失。
 */
export async function listCheckinSummary(client, ctx, query) {
  const studentId = requireVisibleStudent(ctx.visibleStudents, query?.studentId);

  const r = await client.query(
    `select coalesce(nullif(trim(q.subject), ''), '其他') as subject,
            count(*)::int as done,
            max(r.submitted_at) as last_submitted_at,
            (array_agg(r.score order by r.submitted_at desc nulls last))[1] as last_score,
            (array_agg(r.total order by r.submitted_at desc nulls last))[1] as last_total
       from checkin_quiz q
       join checkin_result r on r.quiz_id = q.id
      where q.student_id = $1
      group by 1
      order by max(r.submitted_at) desc nulls last, 1`,
    [studentId],
  );

  return {
    studentId,
    subjects: r.rows.map((row) => ({
      subject: row.subject,
      done: Number(row.done ?? 0),
      lastSubmittedAt: row.last_submitted_at ?? null,
      lastScore: row.last_score === null || row.last_score === undefined
        ? null
        : Number(row.last_score),
      lastTotal: row.last_total === null || row.last_total === undefined
        ? null
        : Number(row.last_total),
    })),
  };
}

/**
 * 打卡题 → 错题本的题干。
 *
 * 错题本里的 `question_body` 是**重做与原题讲解的唯一依据**（`title` 只是
 * 列表上的短标签）。只存 stem 会把选项丢掉：一道选择题脱离选项之后
 * 无法重做，举一反三也没有了语境。
 */
function mistakeBodyOf(question) {
  const stem = String(question?.stem ?? '').trim();
  if (String(question?.type ?? '') === 'judge') {
    return stem === '' ? '' : `${stem}\n\n（判断题）`;
  }
  const options = Array.isArray(question?.options) ? question.options : [];
  const lines = [];
  for (let i = 0; i < options.length; i++) {
    const option = String(options[i] ?? '').trim();
    if (option === '') continue;
    lines.push(`${CHOICE_LETTERS[i] ?? '?'}. ${option}`);
  }
  return lines.length === 0 ? stem : `${stem}\n\n${lines.join('\n')}`;
}

/**
 * 作答值 → 人话：选择题 `B` → `B. 选项原文`，判断题 `T/F` → `正确/错误`。
 *
 * 只存一个字母的话，错题详情里「你的答案 B / 正确答案 C」离开原题就看不懂了。
 */
function answerTextOf(question, value) {
  const raw = String(value ?? '').trim().toUpperCase();
  if (raw === '') return '';
  if (String(question?.type ?? '') === 'judge') {
    if (raw === 'T') return '正确';
    if (raw === 'F') return '错误';
    return raw;
  }
  const index = CHOICE_LETTERS.indexOf(raw);
  const option = index >= 0 && Array.isArray(question?.options)
    ? String(question.options[index] ?? '').trim()
    : '';
  return option === '' ? raw : `${raw}. ${option}`;
}

/**
 * 把这次打卡做错的题写进错题本（`review_mistake`）。
 *
 * ## 为什么在这里写，而不是让客户端再调一次写接口
 *
 * 交卷是**唯一**知道「哪题错了、选了什么」的地方，且它已经在一次事务里。
 * 让客户端补一次请求，中间断网就会出现「成绩存了、错题没进」——
 * 学生以为自己已经进复习队列，复习页里却没有，而且没有任何提示。
 *
 * ## 幂等
 *
 * 同一份卷重复交卷时，先删掉这份卷上一次产出的错题（`source_ref = quizId`），
 * 再按这次的真实错题重写。只按 id 去重清不掉「上次错、这次对」的那几题。
 *
 * ## 失败不拖垮交卷
 *
 * 整段包在 savepoint 里：错题本写失败（028 未迁移、RLS 配置不对）时
 * 只回滚这一段，**成绩照常保存**。孩子刚才做完的题比错题归档重要得多；
 * 但也不能静默 —— 返回值里带 `failed`，客户端会如实说「错题没记上」。
 */
let mistakeSavepointSeq = 0;

async function recordCheckinMistakes(client, quiz, wrongItems) {
  if (wrongItems.length === 0) return { added: 0, failed: false };

  const sp = `sp_checkin_mistake_${(mistakeSavepointSeq += 1)}`;
  await client.query(`savepoint ${sp}`);
  try {
    await client.query(
      "delete from review_mistake where student_id = $1 and source_ref = $2 and source_type = 'checkin'",
      [quiz.student_id, quiz.id],
    );

    // 年级/学期快照：错题列表默认按当前学期筛，不写这两列的话这道题
    // 会永远躺在「未归档」里 —— 页面不报错，只是翻不出来。
    let grade = '';
    let term = '';
    try {
      const profile = await client.query(
        'select grade, term from app_user where id = $1',
        [quiz.student_id],
      );
      grade = String(profile.rows[0]?.grade ?? '');
      term = String(profile.rows[0]?.term ?? '');
    } catch {
      // 读不到就不带快照，比因此整段失败要好。
    }

    const subject = String(quiz.subject ?? '').trim();
    const quizDate = String(quiz.quiz_date ?? '').trim();

    for (const item of wrongItems) {
      const question = item.question;
      const knowledge = String(question?.knowledge ?? '').trim();
      const pickedText = answerTextOf(question, item.picked);
      await client.query(
        `insert into review_mistake
           (id, student_id, subject, title, question_body, answer_key,
            original_answer, wrong_reason, state, knowledge_point, wrong_count,
            last_wrong_at, source_homework_title, source_type, grade, term,
            source_ref)
         values ($1, $2, $3, $4, $5, $6, $7, $8, 'pending', $9, 1,
                 now(), $10, 'checkin', $11, $12, $13)`,
        [
          `rm_${quiz.id}_${item.index}`,
          quiz.student_id,
          subject,
          `每日打卡 · ${knowledge === '' ? subject : knowledge}`,
          mistakeBodyOf(question),
          answerTextOf(question, question?.answer),
          pickedText,
          pickedText === '' ? '' : `打卡时选了「${pickedText}」`,
          knowledge,
          `每日打卡 ${quizDate}`.trim(),
          grade,
          term,
          quiz.id,
        ],
      );
    }

    await client.query(`release savepoint ${sp}`);
    return { added: wrongItems.length, failed: false };
  } catch (e) {
    // 必须 `rollback to`：事务此刻是 aborted 的，不回滚的话后面
    // 「提交成功」那条路的任何查询都会被拒，表现成整次交卷失败。
    await client.query(`rollback to savepoint ${sp}`);
    console.error(
      '[checkin] 错题没能写进错题本（成绩已保存）：',
      e instanceof Error ? e.message : e,
    );
    return { added: 0, failed: true };
  }
}

/**
 * 提交作答。
 *
 * `answers` 只需要 `[{index, picked}]` —— 分数、总分、每题对错都由这里算，
 * 客户端传来的任何计数一律忽略（连读都不读，免得以后有人「顺手用一下」）。
 *
 * 做错的题会在同一事务里写进 `review_mistake`（`source_type = 'checkin'`）：
 * **计划里做错的题就是复习的原料**，这条链断了，孩子做错的题只能靠家长
 * 手工再录一遍。
 */
export async function submitCheckin(client, ctx, body) {
  const quizId = String(requireText(body?.quizId, 'quizId') ?? '').trim();
  if (quizId === '') throw badRequest('缺少 quizId');

  const found = await client.query(
    `select id, student_id, subject, quiz_date::text as quiz_date, questions
       from checkin_quiz
      where id = $1 and student_id = any($2::text[])`,
    [quizId, ctx.students ?? []],
  );
  if (!found.rows[0]) throw notFound('打卡不存在，或不属于当前账号');
  const quiz = found.rows[0];

  const questions = Array.isArray(quiz.questions) ? quiz.questions : [];
  if (questions.length === 0) throw badRequest('这份打卡没有题目');

  const rawAnswers = Array.isArray(body?.answers) ? body.answers : [];
  const picked = new Map();
  // 🔴 每一份作答都必须合法落在题目范围内（2026-10-27 串题事故的纵深防御）：
  // 以前这里对越界 index `continue` —— 8 题的作答交到换成 5 题的行上，
  // 多出的 3 份被静默裁掉，剩下 5 份拿新题判分。客户端交卷前有
  // `allAnswered` 挡着，正常就是**每题恰好一份**；对不上的唯一现实来源
  // 就是「手里的卷和服务端这份不是同一份」，必须报错而不是裁剪。
  let malformed = false;
  for (const item of rawAnswers) {
    if (!item || typeof item !== 'object') {
      malformed = true;
      break;
    }
    const index = toInt(item.index, 'index');
    // ⚠️ `toInt` 缺值时返回 **null**（不是 undefined）。写 `index === undefined`
    // 会让「没带 index」的项漏过去，最后被 set 成 key=null。
    if (index === null || index < 0 || index >= questions.length) {
      malformed = true;
      break;
    }
    const value = String(toText(item.picked) ?? '').trim().toUpperCase();
    if (value === '') {
      malformed = true;
      break;
    }
    picked.set(index, value);
  }
  if (malformed || picked.size !== questions.length) {
    throw quizVersionConflict(
      '提交的作答与当前题目对不上，题目可能已被重新出过，请重新打开打卡',
    );
  }

  let score = 0;
  const items = questions.map((q, index) => {
    const answer = String(q?.answer ?? '').toUpperCase();
    const mine = picked.get(index) ?? '';
    const correct = mine !== '' && mine === answer;
    if (correct) score += 1;
    return {
      index,
      knowledge: q?.knowledge ?? '',
      picked: mine,
      answer,
      correct,
    };
  });
  const total = questions.length;

  await client.query(
    `insert into checkin_result (quiz_id, student_id, answers, score, total)
     values ($1, $2, $3::jsonb, $4, $5)
     on conflict (quiz_id) do update
       set answers = excluded.answers,
           score   = excluded.score,
           total   = excluded.total,
           submitted_at = now()`,
    [
      quizId,
      quiz.student_id,
      JSON.stringify(
        items.map((item) => ({ index: item.index, picked: item.picked })),
      ),
      score,
      total,
    ],
  );
  await client.query(
    `update checkin_quiz set status = 'done', updated_at = now() where id = $1`,
    [quizId],
  );

  // 做错的题进错题本（计划 → 复习的唯一入口）。
  // 放在成绩落库之后：先保住孩子的作答，再谈归档。
  const wrongItems = items
    .filter((item) => !item.correct)
    .map((item) => ({ index: item.index, picked: item.picked, question: questions[item.index] }));
  const mistakes = await recordCheckinMistakes(client, quiz, wrongItems);

  // 可选同步：连了 ima 才推，未连接/失败都不影响「提交成功」这件事。
  // 必须 await（不是 fire-and-forget）：请求结束后连接就归还池里了，
  // 挂起的 promise 会在别人的事务上继续跑 —— 那是最难查的一类串号。
  const imaSync = await syncStudentArchive(client, ctx, quiz.student_id);

  return { quizId, score, total, items, mistakes, ima: imaSync };
}

/**
 * 历史打卡（供家长查看与 ima 归档）。
 *
 * `from` / `to` **不给默认值**：默认「最近 7 天」会让「取不到」表现成
 * 「最近没打卡」，而真正的原因可能是时间窗算错了。调用方明确给区间。
 */
export async function listCheckinResults(client, ctx, query) {
  const studentId = query?.studentId
    ? requireVisibleStudent(ctx.visibleStudents, query.studentId)
    : '';
  const from = query?.from ? requireDate(query.from, 'from') : null;
  const to = query?.to ? requireDate(query.to, 'to') : null;
  if (from && to && from > to) throw badRequest('from 不能晚于 to');

  const result = await client.query(
    `select q.id as quiz_id, q.student_id, q.quiz_date::text as quiz_date,
            q.subject, q.questions, r.answers, r.score, r.total, r.submitted_at
       from checkin_quiz q
       join checkin_result r on r.quiz_id = q.id
      where q.student_id = any($1::text[])
        and ($2::text is null or q.quiz_date >= $2::date)
        and ($3::text is null or q.quiz_date <= $3::date)
        and ($4::text = '' or q.student_id = $4)
      order by q.quiz_date desc, q.id`,
    [ctx.students ?? [], from, to, studentId],
  );

  return {
    items: result.rows.map((row) => ({
      quizId: row.quiz_id,
      studentId: row.student_id,
      quizDate: row.quiz_date,
      subject: row.subject,
      questions: row.questions,
      answers: row.answers,
      score: row.score,
      total: row.total,
      submittedAt: row.submitted_at,
    })),
  };
}
