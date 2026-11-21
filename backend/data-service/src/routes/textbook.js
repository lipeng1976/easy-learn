import { randomUUID } from 'node:crypto';

import { badRequest, notFound } from '../../../shared/errors.js';
import { requireText, toText } from '../coerce.js';
import { IMA_MEDIA_TYPE_MARKDOWN, downloadMedia } from '../ima_openapi.js';
import { TEXTBOOK_FORMAT_HINT, parseTextbookSkeleton, splitPoints } from '../textbook_import.js';
import { SUBJECT_SET } from '../subjects.js';
import {
  findFolderByPath,
  listAllEntries,
  resolveReaderContext,
  studentScope,
} from './reading.js';

/**
 * 学科教材：从 ima 导入「骨架 MD」→ 落库成章节 → 出题时当范围。
 *
 * ## 和 `routes/word.js` 的关系：同构，不是同一件事
 *
 * 词表那套是「一本教材 → 每个单元一组单词」，教材这套是「一本书 → 每章一行
 * 考点」。形状像，但存的东西不同（词条有音标和释义，章节只有考点清单），
 * 所以表分开；而**导入流程**照抄：找文件夹 → 列 md → 下载 → 解析 → 幂等落库。
 *
 * ## 目录约定
 *
 * `教学资料/教材/<学科>/`，一本教材一个 `.md`。
 *
 * 为什么按学科分一层子目录：配置页要只列「本科目的书」。靠文件名前缀猜学科
 * （`数学-人教版.md`）在家长改个名字之后就失效了，而且失效时是**静默**的
 * ——那本数学书会出现在语文的列表里，或者反过来干脆不出现。
 *
 * ⚠️ 目录名匹配忽略大小写（`findFolderByPath` 里统一处理）：人手敲的目录
 * 大小写不该决定功能在不在。12 日 `wordlist` / `Wordlist` 已经栽过一次。
 *
 * ## ima 是可选的
 *
 * 列表 2xx + `connected:false`（客户端藏入口）；导入才响亮失败
 * （家长点了按钮在等结果）。已导入的书**永远列出来**，即使 ima 已经断开。
 */

/** ima 侧教材根目录（下面按学科再分一层）。 */
const TEXTBOOK_FOLDER_PATH = ['教学资料', '教材'];

/** 骨架文件很小（几十 KB）；超过这个数说明传的不是骨架。 */
const MAX_TEXTBOOK_BYTES = 2 * 1024 * 1024;

function requireSubject(raw) {
  const subject = String(toText(raw) ?? '').trim();
  if (!SUBJECT_SET.has(subject)) throw badRequest(`不认识的科目：${subject}`);
  return subject;
}

export function toBook(row) {
  return {
    id: row.id,
    studentId: row.student_id,
    subject: row.subject,
    title: row.title,
    source: row.source ?? 'ima',
    sourceMediaId: row.source_media_id ?? '',
    unitCount: Number(row.unit_count ?? 0),
    // 书的年级学期：配置页用来比对「这本书是不是当前年级的」。
    // 空串 = 导入时还没这个字段（老数据 / 029 之前的书）。
    grade: row.grade ?? '',
    term: row.term ?? '',
    createdAt: row.created_at ?? null,
  };
}

function toUnit(row) {
  return {
    id: row.id,
    bookId: row.book_id,
    unitNo: Number(row.unit_no ?? 0),
    title: row.title ?? '',
    summary: row.summary ?? '',
    pageHint: row.page_hint ?? '',
  };
}

async function findTextbookFolder(reader, subject) {
  return findFolderByPath(reader, [...TEXTBOOK_FOLDER_PATH, subject]);
}

/** 表没迁移（027 未跑）时按「没有教材」降级 —— 配置页少一块，不报错。 */
async function listImported(client, studentId, subject) {
  try {
    const r = await client.query(
      `select id, student_id, subject, title, source, source_media_id, unit_count, grade, term, created_at
         from subject_book
        where student_id = $1 and subject = $2
        order by created_at desc`,
      [studentId, subject],
    );
    return r.rows;
  } catch (e) {
    console.error(`[textbook] 教材读不到（按没有教材处理）: ${e?.message ?? e}`);
    return [];
  }
}

// ===== 1. 这一科的书（已导入 + ima 里可导入的）=====

export async function listTextbooks(client, ctx, query) {
  const studentId = studentScope(ctx, query?.studentId);
  const subject = requireSubject(query?.subject);
  const folderPath = [...TEXTBOOK_FOLDER_PATH, subject].join('/');

  const imported = (await listImported(client, studentId, subject)).map(toBook);

  const reader = await resolveReaderContext(client, ctx, studentId);
  if (!reader) {
    // 没开通 ima 是正常状态：把已导入的照常返回，让「换书」还能用。
    return { connected: false, folderPath, subject, books: imported, available: [], reason: 'ima_unavailable' };
  }

  try {
    const folder = await findTextbookFolder(reader, subject);
    if (!folder) {
      return { connected: true, folderPath, subject, books: imported, available: [], reason: 'folder_missing' };
    }
    const entries = await listAllEntries(reader, { kbId: reader.kbId, folderId: folder.media_id });
    const byMedia = new Map(imported.filter((one) => one.sourceMediaId).map((one) => [one.sourceMediaId, one]));
    const available = entries
      .filter((item) => Number(item.media_type ?? item.mediaType) === IMA_MEDIA_TYPE_MARKDOWN)
      .map((item) => {
        const hit = byMedia.get(item.media_id);
        return {
          mediaId: item.media_id,
          fileName: item.title ?? '',
          importedBookId: hit?.id ?? null,
          unitCount: hit?.unitCount ?? 0,
        };
      });
    return { connected: true, folderPath, subject, books: imported, available };
  } catch (e) {
    console.error(`[textbook] 读 ima 目录失败（保留入口）: ${e?.message ?? e}`);
    return { connected: true, folderPath, subject, books: imported, available: [], reason: 'ima_read_error' };
  }
}

// ===== 2. 导入一本 =====

/**
 * 下载 → 解析 → 落库。
 *
 * **幂等**：同一个 `mediaId` 再次导入，覆盖章节但保留 `id`。
 * 保留 id 是因为 `subject_scope.book_id` 指着它 —— 删掉重建会让家长的
 * 「从第 3 章开始」静默失效（配置还在，指向一个不存在的书）。
 */
export async function importTextbook(client, ctx, body) {
  const studentId = studentScope(ctx, body?.studentId);
  const subject = requireSubject(body?.subject);
  const mediaId = requireText(body?.mediaId, 'mediaId');
  // 书的年级学期：来自导入时的显式选择（客户端年级+学期选择器），
  // **不解析 ima 路径** —— 家长命名千奇百怪，解析必碎。空串允许（老调用方）。
  const grade = String(toText(body?.grade) ?? '').trim();
  const term = String(toText(body?.term) ?? '').trim();

  const reader = await resolveReaderContext(client, ctx, studentId);
  if (!reader) {
    throw badRequest('当前没有可用的 ima 知识库，暂时不能导入教材；已经导入的教材照常能出题。');
  }

  // 文件名用于兜底书名（骨架里没有 `# 书名` 时）。
  let fileName = String(toText(body?.fileName) ?? '').trim();
  if (fileName === '') {
    const folder = await findTextbookFolder(reader, subject);
    if (folder) {
      const entries = await listAllEntries(reader, { kbId: reader.kbId, folderId: folder.media_id });
      const hit = entries.find(
        (item) => item.media_id === mediaId
          && Number(item.media_type ?? item.mediaType) === IMA_MEDIA_TYPE_MARKDOWN,
      );
      fileName = String(hit?.title ?? '');
    }
  }
  if (fileName === '') fileName = 'textbook.md';

  const { bytes } = await downloadMedia({
    clientId: reader.clientId,
    apiKey: reader.apiKey,
    fetchImpl: ctx.fetchImpl,
    kbId: reader.kbId,
    mediaId,
    maxBytes: MAX_TEXTBOOK_BYTES,
  });

  const fallbackTitle = fileName.replace(/\.(md|markdown)$/i, '').trim();
  const parsed = parseTextbookSkeleton(bytes.toString('utf8'), { title: fallbackTitle });
  if (parsed.units.length === 0) {
    // 不存一本 0 章的书：存进去之后配置页会列出它，家长选了却出不了题。
    throw badRequest(`这本书里没有识别到任何章节。${TEXTBOOK_FORMAT_HINT}`);
  }

  const existing = await client.query(
    'select id from subject_book where student_id = $1 and source_media_id = $2',
    [studentId, mediaId],
  );
  const bookId = existing.rows[0]?.id ?? `tb_${randomUUID()}`;
  const title = String(toText(body?.title) ?? '').trim() || parsed.title || fallbackTitle;

  if (existing.rowCount > 0) {
    await client.query(
      `update subject_book
          set title = $2, source_path = $3, unit_count = $4, grade = $5, term = $6, updated_at = now()
        where id = $1`,
      [bookId, title, `${TEXTBOOK_FOLDER_PATH.join('/')}/${subject}/${fileName}`, parsed.units.length, grade, term],
    );
    await client.query('delete from subject_unit where book_id = $1', [bookId]);
  } else {
    await client.query(
      `insert into subject_book
         (id, student_id, subject, title, source, source_media_id, source_path, unit_count, grade, term)
       values ($1, $2, $3, $4, 'ima', $5, $6, $7, $8, $9)`,
      [
        bookId,
        studentId,
        subject,
        title,
        mediaId,
        `${TEXTBOOK_FOLDER_PATH.join('/')}/${subject}/${fileName}`,
        parsed.units.length,
        grade,
        term,
      ],
    );
  }

  // 一条 insert 写完全部章节：一套书几十行，逐条往返没有必要，
  // 而且中途失败会留下「导了一半」的教材。
  const values = [];
  const params = [];
  parsed.units.forEach((unit, i) => {
    const base = i * 7;
    values.push(`($${base + 1}, $${base + 2}, $${base + 3}, $${base + 4}, $${base + 5}, $${base + 6}, $${base + 7})`);
    params.push(
      `tu_${randomUUID().replace(/-/g, '').slice(0, 12)}`,
      bookId,
      studentId,
      unit.unitNo,
      unit.title,
      unit.summary,
      unit.pageHint,
    );
  });
  await client.query(
    `insert into subject_unit (id, book_id, student_id, unit_no, title, summary, page_hint)
     values ${values.join(', ')}`,
    params,
  );

  const r = await client.query('select * from subject_book where id = $1', [bookId]);
  return { book: toBook(r.rows[0]), imported: existing.rowCount === 0, units: parsed.units.length };
}

// ===== 删除一本已导入的书（教材换版 / 导错了重来）=====

/**
 * ima 里换了一份新的骨架 MD，旧的那本仍留在 `subject_book` —— 配置页会
 * 并排列出两本书，家长不知道该选哪本。以前 App 里**没有删除入口**，
 * 只能直接改库；这条端点让「换教材」变成家长自己能完成的动作。
 *
 * ## 为什么删书必须顺手清 `subject_scope`
 *
 * `subject_scope.book_id` 没有外键（027）。删掉书之后它仍指着那个已不存在的
 * id，`resolveTextbookPoints` 查不到章节就安静回 null，出题退回手填范围 ——
 * 而界面上「教材」那一栏还显示着书名。家长看见的是「配好了却按错题本出题」，
 * 属于最难查的静默失败。所以在**同一个事务里**把指向它的范围清掉，并把
 * `start_unit_no` 归 1（换书后旧章号没有意义）。
 *
 * ## 事务与可见范围
 *
 * 请求外层 `withRequestContext` 已经 BEGIN/COMMIT，这里不再自己开事务：
 * 任何一条失败都由外层 rollback，不会出现「书删了、章节还在」。
 * RLS 之外仍显式带 `student_id`：家长可见集合里可以有两个孩子，
 * 光靠 RLS 不足以表达「只删这位学生的这本书」。
 */
export async function deleteTextbook(client, ctx, body) {
  const studentId = studentScope(ctx, body?.studentId);
  const bookId = requireText(body?.bookId, 'bookId').trim();

  const found = await client.query(
    'select id, title from subject_book where id = $1 and student_id = $2',
    [bookId, studentId],
  );
  if (found.rowCount === 0) {
    // 不能「删不到也算成功」：家长看见书消失了，刷新一下又回来。
    throw notFound('这本教材已经不在了，请刷新后重试');
  }

  const title = String(found.rows[0]?.title ?? '');
  await client.query(
    'delete from subject_unit where book_id = $1 and student_id = $2',
    [bookId, studentId],
  );
  await client.query(
    'delete from subject_book where id = $1 and student_id = $2',
    [bookId, studentId],
  );
  const scope = await client.query(
    `update subject_scope
        set book_id = null, start_unit_no = 1, updated_at = now()
      where student_id = $1 and book_id = $2`,
    [studentId, bookId],
  );
  return {
    bookId,
    title,
    scopeCleared: Number(scope?.rowCount ?? 0) > 0,
  };
}

// ===== 3. 这本书的章节 =====

export async function listUnits(client, ctx, query) {
  const studentId = studentScope(ctx, query?.studentId);
  const bookId = requireText(query?.bookId, 'bookId');
  try {
    const r = await client.query(
      `select id, book_id, unit_no, title, summary, page_hint
         from subject_unit
        where book_id = $1 and student_id = $2
        order by unit_no`,
      [bookId, studentId],
    );
    return { bookId, units: r.rows.map(toUnit) };
  } catch (e) {
    console.error(`[textbook] 章节读不到（按空处理）: ${e?.message ?? e}`);
    return { bookId, units: [] };
  }
}

// ===== 4. 出题用：这一科当前该考哪几节 =====

/**
 * 取「今天该考的考点」。
 *
 * ## 规则
 *
 * 家长的配置是「从第 N 章开始，每天 M 节」。`start_unit_no` 同时是游标：
 * 每成功出一次题，往后推 M 节（由 [advanceUnitCursor] 做）。
 *
 * ## 章节标题本身就是知识点
 *
 * 骨架 MD 里的「考点：」行是**可选**的（见 `textbook_import.js`）。家长导入的
 * 中国历史 22 节课很可能只有 `## 第7课 百家争鸣`，一行考点都没写 —— 这时
 * 旧的实现会把整本书当成「没配考点」返回 null，再退回错题本；而历史这种
 * 科目**本来就不会有错题**（还没学过），于是点一次报一次「错题本还是空的」。
 * 教材看起来配好了，实际从没生效过。
 *
 * 所以一节至少产出一个点：写了考点就拆考点，没写就用**章节标题**。
 * 「第7课 百家争鸣」对模型是完整语境，出题质量反而比自己编的考点词稳。
 *
 * ## 什么时候仍然返回 null
 *
 * 没配教材 / 书被删了 / 这几节的标题和考点都空 —— 才回 null，调用方退回
 * 「家长手填范围 / 错题本聚合」那条老路。**不要因为教材配置有问题就出不了题**：
 * 这是「更好的范围」，不是「唯一的范围」。
 *
 * @param {number} limit 最多取几个知识点（与网关 `MAX_CHECKIN_ITEMS` 同口径，
 *   由调用方传入，这里不重复定义那个数）。
 */
export async function resolveTextbookPoints(client, studentId, subject, limit = 6) {
  let scope;
  try {
    const r = await client.query(
      `select book_id, start_unit_no, units_per_day
         from subject_scope where student_id = $1 and subject = $2`,
      [studentId, subject],
    );
    scope = r.rows[0];
  } catch (e) {
    // 027 未迁移：没有这几列，按「没配教材」处理。
    return null;
  }
  if (!scope?.book_id) return null;

  const start = Math.max(1, Number(scope.start_unit_no ?? 1));
  const perDay = Math.min(Math.max(Number(scope.units_per_day ?? 1), 1), 3);

  let rows;
  try {
    const r = await client.query(
      `select unit_no, title, summary
         from subject_unit
        where book_id = $1 and student_id = $2 and unit_no >= $3
        order by unit_no
        -- 多取几节：「阅读」「写作」这类板块名会被跳过（见 GENERIC_UNIT_TITLES），
        -- 只按 units_per_day 取的话，碰上一串板块名就一个点都凑不出来。
        limit $4`,
      [scope.book_id, studentId, start, perDay * 4],
    );
    rows = r.rows;
  } catch (e) {
    return null;
  }
  if (rows.length === 0) return null;

  // 每节至少一个点：有考点拆考点，没考点用章节标题兜底。
  //
  // ⚠️ 不能「全都没考点就整本作废」：历史/政治这类科目的骨架常常只写了
  // 目录，而它们也**不会先有错题**，作废就等于这科永远出不了题。
  const points = [];
  const fromTitle = [];
  const adopted = [];
  for (const row of rows) {
    if (adopted.length >= perDay || points.length >= limit) break;
    const one = unitPoints(row, limit);
    if (one.points.length === 0) continue;
    adopted.push(Number(row.unit_no));
    if (one.fromTitle) fromTitle.push(one.points[0]);
    for (const point of one.points) {
      if (points.length >= limit) break;
      if (!points.includes(point)) points.push(point);
    }
  }
  if (points.length === 0) return null;

  return {
    bookId: scope.book_id,
    points,
    unitNos: adopted,
    unitTitles: adopted.map((no) => rows.find((row) => Number(row.unit_no) === no)?.title ?? ''),
    // 游标 = **实际采用**的最后一节 + 1，而不是 `start + perDay`：
    // 中间跳过板块名时，按配置步长推进会跳过一整节正文。
    nextStart: adopted.length > 0 ? Math.max(...adopted) + 1 : start + perDay,
    // 有几个点是「拿章节标题顶的」—— 调用方据此在出题提示词里补一句
    // 「按这一节的教材内容出」，而不是让模型只看见一个孤零零的标题。
    titleOnlyPoints: fromTitle,
  };
}

/**
 * 教材里「不是知识点」的板块名。
 *
 * 语文书的目录长这样：`阅读` → `1 春` → `2 济南的冬天` → … → 又一个 `阅读`。
 * 拿「阅读」当知识点，模型会出「阅读方法」这类通识题 —— 与课文无关，
 * 而界面上完全看不出来（题本身是通顺的）。
 *
 * 白名单式列举，不做模糊判断：多认一个板块名只是少考一节，错认一个正文章节
 * 会让那节课永远考不到。
 */
const GENERIC_UNIT_TITLES = new Set([
  '阅读', '写作', '综合性学习', '口语交际', '名著导读',
  '课外古诗词诵读', '单元检测', '复习', '小结', '语文园地',
]);

/** 这一节能出什么点：先拆考点，没有考点才用标题；板块名不算内容。 */
function unitPoints(row, limit) {
  const fromSummary = splitPoints(row.summary, limit);
  if (fromSummary.length > 0) return { points: fromSummary, fromTitle: false };

  const title = String(row.title ?? '').trim();
  if (title === '' || GENERIC_UNIT_TITLES.has(title)) {
    return { points: [], fromTitle: false };
  }
  return { points: [title], fromTitle: true };
}

/**
 * 出完题把游标往后推。
 *
 * ⚠️ 只在**入库成功之后**调用：失败还推的话，家长点一次没出成、再点一次，
 * 范围已经往后跳了一节 —— 那一节从此再也不会被考到。
 *
 * 越过最后一节就停在最后一节（不回绕）：回绕会让「快考试了」的家长
 * 忽然收到第 1 章。
 */
export async function advanceUnitCursor(client, studentId, subject, nextStart) {
  if (!nextStart) return;
  try {
    const r = await client.query(
      `select max(unit_no) as last from subject_unit
        where book_id = (select book_id from subject_scope where student_id = $1 and subject = $2)`,
      [studentId, subject],
    );
    const last = Number(r.rows[0]?.last ?? 0);
    const target = last > 0 ? Math.min(nextStart, last) : nextStart;
    await client.query(
      `update subject_scope set start_unit_no = $3, updated_at = now()
        where student_id = $1 and subject = $2`,
      [studentId, subject, target],
    );
  } catch (e) {
    // 推不动只是「下次还考这一节」，比让这次出题失败好。
    console.error(`[textbook] 推进章节游标失败（本次出题不受影响）: ${e?.message ?? e}`);
  }
}
