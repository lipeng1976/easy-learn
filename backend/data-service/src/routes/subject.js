import { badRequest, forbidden } from '../../../shared/errors.js';
import { requireText, toInt, toText } from '../coerce.js';
import { SUBJECTS, SUBJECT_SET } from '../subjects.js';
import { MAX_SEED_CANDIDATES, collectCheckinSeeds } from './checkin.js';
import { studentScope } from './reading.js';

/**
 * 学科范围：**家长配一次，出题时直接用它**。
 *
 * ## 为什么需要这张表（而不复用打卡的临时参数）
 *
 * 原来家长每出一份题都要在设置页重选「学科 / 知识点 / 题量 / 难度」——
 * 同一份范围一周要重选七次，而它一周里几乎不变。范围因此从「出题表单」
 * 提升为**长期配置**：`/data/subject/scope` 存一份，出题（`/data/checkin/generate`）
 * 只读它，不再让人重复填。
 *
 * ## 科目是预留的
 *
 * 白名单是十科（与客户端 `HomeworkItemNormalizer.subjectNames` 逐字一致）。
 * 十科**都能配范围、都能出教材题**（11-12 起）；英语另有本地单词题（词表），
 * 在 `/word-scope` 配，不占这一行。这么做的原因是不想造「配置页只认四科」
 * 的第二套真相 —— 以后开哪一科，只改出题那一段。
 *
 * ## 读降级 / 写响亮
 *
 * 与 `routes/word.js` 同一口径：`026` 未迁移时列表与单读都按「未配置」返回
 * （页面每科显示未配，不弹红条，符合 11-07 的可选能力规矩）；
 * 写端点则明确报错 —— 那是家长点了保存正在等结果。
 */

/**
 * ⚠️ 必须与客户端 `HomeworkItemNormalizer.subjectNames` 逐字一致（`其他` 也在内）。
 * 真值在 `src/subjects.js`（教材导入也要用，放这里会形成循环 import）；
 * 这里再导出一次，保持 `import { SUBJECTS } from './subject.js'` 的老写法可用。
 */
export { SUBJECTS };

/** 与 `checkin_setup_page.countChoices` / `kCheckinDifficulties` 同一口径。 */
const DAILY_COUNTS = new Set([3, 5, 8]);
const DIFFICULTIES = new Set(['基础', '提高', '挑战']);

/** 与网关 `MAX_CHECKIN_ITEMS` / `MAX_SEED_POINTS` 同一个数。 */
const MAX_POINTS = 6;

/** 单条范围条目的长度上限：一屏内能编辑的「短清单」，不是一段话。 */
const MAX_POINT_LENGTH = 60;

/** 一天最多覆盖几节教材：更多就不是「每天练一组」，是一套卷子。 */
const UNITS_PER_DAY = new Set([1, 2, 3]);

function requireParent(ctx) {
  if (ctx.role !== 'parent') throw forbidden('只有家长可以设置学科范围');
}

function toScope(row) {
  return {
    studentId: row.student_id,
    subject: row.subject,
    dailyCount: Number(row.daily_count ?? 5),
    difficulty: row.difficulty ?? '基础',
    points: Array.isArray(row.points) ? row.points : [],
    // 教材（027）。`bookId` 为空 = 还没选教材，出题走手填范围/错题本。
    bookId: row.book_id ?? null,
    startUnitNo: Number(row.start_unit_no ?? 1),
    unitsPerDay: Number(row.units_per_day ?? 1),
    configured: true,
    updatedAt: row.updated_at ?? null,
  };
}

/** 未配置时的默认形状：题量/难度给默认值，出题时可原样用。 */
function emptyScope(studentId, subject) {
  return {
    studentId,
    subject,
    dailyCount: 5,
    difficulty: '基础',
    points: [],
    bookId: null,
    startUnitNo: 1,
    unitsPerDay: 1,
    configured: false,
    updatedAt: null,
  };
}

/**
 * 表没迁移时按空列表降级 —— 页面照常渲染，只是每科都显示未配。
 *
 * ⚠️ 两条查询：027 未跑时 `book_id` 这些列不存在，整条 select 会报
 * `42703`。退回去查 026 的列并补默认值 —— 否则「升级前已配好的范围」
 * 会全部变成「未配置」，家长以为配置丢了（比功能缺失更吓人）。
 */
async function listRows(client, studentId) {
  try {
    const r = await client.query(
      `select student_id, subject, daily_count, difficulty, points,
              book_id, start_unit_no, units_per_day, updated_at
         from subject_scope where student_id = $1`,
      [studentId],
    );
    return r.rows;
  } catch (e) {
    try {
      const r = await client.query(
        `select student_id, subject, daily_count, difficulty, points, updated_at
           from subject_scope where student_id = $1`,
        [studentId],
      );
      return r.rows;
    } catch (inner) {
      console.error(`[subject] 学科范围读不到（按未配置处理）: ${inner?.message ?? inner}`);
      return [];
    }
  }
}

// ===== 1. 列表 =====

/** 一个学生已配置的所有科目。只返回配过的行；没配的科目由客户端按白名单补。 */
export async function listSubjectScopes(client, ctx, query) {
  const studentId = studentScope(ctx, query?.studentId);
  const rows = await listRows(client, studentId);
  return { studentId, scopes: rows.map(toScope) };
}

// ===== 2. 单科 =====

export async function getSubjectScope(client, ctx, query) {
  const studentId = studentScope(ctx, query?.studentId);
  const subject = requireText(query?.subject, 'subject');
  if (!SUBJECT_SET.has(subject)) throw badRequest(`不认识的科目：${subject}`);

  const rows = await listRows(client, studentId);
  const hit = rows.find((row) => row.subject === subject);
  return { scope: hit ? toScope(hit) : emptyScope(studentId, subject) };
}

// ===== 3. 这一科的错题知识点（配置页的候选）=====

/**
 * 与 `GET /data/checkin/seeds` 同一段聚合，但**只取这一科**。
 *
 * 为什么不给原端点加 `subject` 参数：那条路的调用方（出题设置页）要的是
 * 全科候选，加参数等于让两个用途共用一个形状；这里多一条路由的成本只有
 * 一行注册，聚合逻辑仍是同一份函数（`collectCheckinSeeds`）。
 *
 * 只读、恒 2xx（读不到错题本 = 空列表）—— 配置页照样能手填。
 */
export async function listSubjectSeeds(client, ctx, query) {
  const studentId = studentScope(ctx, query?.studentId);
  const subject = requireText(query?.subject, 'subject');
  if (!SUBJECT_SET.has(subject)) throw badRequest(`不认识的科目：${subject}`);
  const seeds = await collectCheckinSeeds(client, studentId, subject);
  return { subject, seeds: seeds.slice(0, MAX_SEED_CANDIDATES) };
}

// ===== 4. 保存 =====

/**
 * 家长保存一科的范围。**整行覆盖**，不是补丁：
 * 界面上的「保存」就是把这一屏的四个值写下去，部分更新会让
 * 「家长清空了知识点」变成「什么都没发生」。
 */
export async function putSubjectScope(client, ctx, body) {
  requireParent(ctx);
  const studentId = studentScope(ctx, body?.studentId);
  const subject = requireText(body?.subject, 'subject');
  if (!SUBJECT_SET.has(subject)) throw badRequest(`不认识的科目：${subject}`);

  const dailyCount = toInt(body?.dailyCount, 'dailyCount') ?? 5;
  if (!DAILY_COUNTS.has(dailyCount)) {
    throw badRequest('每天题量只能是 3 / 5 / 8');
  }

  const difficulty = String(toText(body?.difficulty) ?? '').trim() || '基础';
  if (!DIFFICULTIES.has(difficulty)) {
    throw badRequest('难度只能是 基础 / 提高 / 挑战');
  }

  const rawPoints = Array.isArray(body?.points) ? body.points : [];
  const points = [];
  for (const one of rawPoints) {
    const point = String(toText(one) ?? '').trim();
    if (point === '') continue;
    if (point.length > MAX_POINT_LENGTH) {
      throw badRequest(`单条范围最多 ${MAX_POINT_LENGTH} 个字：${point.slice(0, 12)}…`);
    }
    if (!points.includes(point)) points.push(point); // 去重、保序（顺序即优先级）
  }
  if (points.length > MAX_POINTS) {
    throw badRequest(`最多 ${MAX_POINTS} 条范围，请先合并或删掉几条`);
  }

  // ===== 教材（可选）=====
  //
  // 配了教材就是「按课本进度出题」，此时 `points` 不再参与范围
  // （见 `generateCheckin` 里的优先级）；家长仍然可以留着当备注。
  const bookId = String(toText(body?.bookId) ?? '').trim();
  const startUnitNo = toInt(body?.startUnitNo, 'startUnitNo') ?? 1;
  const unitsPerDay = toInt(body?.unitsPerDay, 'unitsPerDay') ?? 1;
  if (!UNITS_PER_DAY.has(unitsPerDay)) throw badRequest('每天最多覆盖 3 节教材');
  if (startUnitNo < 1) throw badRequest('起始章节从 1 开始数');

  if (bookId !== '') {
    // 归属校验：不然家长能把别人孩子的书挂到自己孩子身上，
    // 而出题时按 RLS 读不到章节 —— 症状是「配了书但没范围」。
    const book = await client.query(
      'select id, subject, unit_count from subject_book where id = $1 and student_id = $2',
      [bookId, studentId],
    );
    if (book.rowCount === 0) throw badRequest('这本教材还没导入过，先在上面的教材列表里选一本');
    if (book.rows[0].subject !== subject) {
      throw badRequest(`这本教材是「${book.rows[0].subject}」的，不能挂到「${subject}」上`);
    }
    const last = Number(book.rows[0].unit_count ?? 0);
    if (last > 0 && startUnitNo > last) {
      throw badRequest(`这本教材只有 ${last} 节，起始章节不能超过它`);
    }
  }

  const r = await client.query(
    `insert into subject_scope
       (student_id, subject, daily_count, difficulty, points,
        book_id, start_unit_no, units_per_day, updated_at)
     values ($1, $2, $3, $4, $5::jsonb, $6, $7, $8, now())
     on conflict (student_id, subject) do update set
       daily_count = excluded.daily_count,
       difficulty = excluded.difficulty,
       points = excluded.points,
       book_id = excluded.book_id,
       start_unit_no = excluded.start_unit_no,
       units_per_day = excluded.units_per_day,
       updated_at = now()
     returning student_id, subject, daily_count, difficulty, points,
               book_id, start_unit_no, units_per_day, updated_at`,
    [
      studentId,
      subject,
      dailyCount,
      difficulty,
      JSON.stringify(points),
      bookId === '' ? null : bookId,
      startUnitNo,
      unitsPerDay,
    ],
  );
  return { scope: toScope(r.rows[0]) };
}
