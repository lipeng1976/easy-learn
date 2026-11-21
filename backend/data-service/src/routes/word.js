import { randomUUID } from 'node:crypto';

import { badRequest, forbidden, notFound } from '../../../shared/errors.js';
import { requireText, toDate, toInt, toText } from '../coerce.js';
import { IMA_MEDIA_TYPE_MARKDOWN, downloadMedia } from '../ima_openapi.js';
import { flattenEntries, parseWordlist, titleFromFileName } from '../word_import.js';
import {
  findFolderByPath,
  listAllEntries,
  resolveReaderContext,
  studentScope,
} from './reading.js';

/**
 * 英语单词打卡：教材词表导入 → 练习范围 → 成绩摘要。
 *
 * ## 职责边界（`doc/word-checkin-design.md`）
 *
 * 服务端 = **词表真值 + 练习范围 + 成绩摘要**；出题、判分、错词权重、发音
 * 全在客户端本地。所以这里**没有**「生成题目」的端点，也不复算判分：
 * 题目由同一份词表按日期种子确定性生成，服务端没有题目快照。
 *
 * ## ima 是可选的：「没开通」不能是错误
 *
 * 与 `routes/reading.js` 同一条 11-07 硬规矩。词表只在家长点「导入」时碰一次
 * ima，之后全落 PG、客户端再缓存进本地。`GET /data/word/books` 因此恒 2xx：
 * 没连 ima 时回 `connected:false`，但**已导入的书仍然列出来**（`imported`），
 * 家长照样能切书、孩子照样能打卡。
 *
 * 三个只读端点（books / scope / daily GET）在 `025` 未迁移时按「空」降级，
 * 不写页面级 error；写端点失败则响亮报错 —— 那是家长/学生主动点了按钮在等结果。
 *
 * ## 两个「必须响亮失败」的地方
 *
 *   ① 词表一条词条都解析不出来 → 拒绝导入，不存 0 词的书；
 *   ② `PUT /data/word/scope` 的 bookId 不属于该学生、unitMode 越界、
 *      单元名不存在 → 4xx，绝不让范围静默指向别人的书。
 */

/** ima 侧词表目录，与 `教学资料/English`（故事书）平级。 */
const WORD_FOLDER_PATH = ['教学资料', 'Wordlist'];

/** 词表远小于故事书（3.4MB）；2MB 留足余量，也和提示词里写的一致。 */
const MAX_WORDLIST_BYTES = 2 * 1024 * 1024;

const UNIT_MODES = new Set(['current', 'learned', 'selected', 'all']);
const DAILY_COUNTS = new Set([5, 10, 15]);

function requireParent(ctx) {
  if (ctx.role !== 'parent') throw forbidden('只有家长可以设置单词练习范围');
}

export function toBook(row) {
  return {
    id: row.id,
    title: row.title,
    unitCount: Number(row.unit_count ?? 0),
    wordCount: Number(row.word_count ?? 0),
    sourcePath: row.source_path ?? '',
    // 词的年级学期：配置页用来比对「这本词表是不是当前年级的」。
    grade: row.grade ?? '',
    term: row.term ?? '',
    createdAt: row.created_at,
  };
}

/** 已导入的书。表没迁移（`025` 未跑）时按空列表降级，不让可选功能弹红条。 */
async function listImportedBooks(client, studentId) {
  try {
    const r = await client.query(
      `select id, title, unit_count, word_count, source_path, created_at, source_media_id, grade, term
         from word_book where student_id = $1 order by created_at desc`,
      [studentId],
    );
    return r.rows;
  } catch (e) {
    console.error(`[word] 已导入书列表读不到（按空处理）: ${e?.message ?? e}`);
    return [];
  }
}

function toImportedBook(row) {
  return { ...toBook(row), sourceMediaId: row.source_media_id ?? '' };
}

/** 某本书的单元名，按 MD 出现顺序（不按标题文本排序）。 */
async function listUnits(client, bookId, studentId) {
  const r = await client.query(
    `select unit from word_entry
      where book_id = $1 and student_id = $2
      group by unit order by min(unit_order)`,
    [bookId, studentId],
  );
  return r.rows.map((row) => row.unit);
}

/** 书必须属于这个学生：越界 403，不能靠 RLS 静默变空（静默 = 家长以为没导入）。 */
async function requireOwnedBook(client, bookId, studentId) {
  const r = await client.query(
    'select id, title from word_book where id = $1 and student_id = $2',
    [bookId, studentId],
  );
  if (r.rowCount === 0) throw forbidden('这本书不属于当前学生');
  return r.rows[0];
}

// ===== 1. 可导入的词表 =====

/** ima `教学资料/Wordlist` 下的 md 文件 + 已导入的书。恒 2xx。 */
export async function listAvailableWordlists(client, ctx, query) {
  const studentId = studentScope(ctx, query?.studentId);
  const folderPath = WORD_FOLDER_PATH.join('/');
  const importedRows = await listImportedBooks(client, studentId);
  const imported = importedRows.map(toImportedBook);
  const fallback = { connected: false, folderPath, books: [], imported, reason: 'ima_unavailable' };

  const reader = await resolveReaderContext(client, ctx, studentId);
  if (!reader) return fallback;

  try {
    const folder = await findFolderByPath(reader, WORD_FOLDER_PATH);
    if (!folder) {
      return { connected: true, folderPath, books: [], imported, reason: 'folder_missing' };
    }
    const entries = await listAllEntries(reader, {
      kbId: reader.kbId,
      folderId: folder.media_id,
    });
    const importedByMedia = new Map(
      importedRows
        .filter((row) => String(row.source_media_id ?? '') !== '')
        .map((row) => [row.source_media_id, row]),
    );
    const books = entries
      .filter((item) => Number(item.media_type ?? item.mediaType) === IMA_MEDIA_TYPE_MARKDOWN)
      .map((item) => {
        const hit = importedByMedia.get(item.media_id);
        return {
          mediaId: item.media_id,
          fileName: item.title ?? '',
          title: titleFromFileName(item.title, '未命名词表'),
          importedBookId: hit?.id ?? null,
          importedWordCount: hit ? Number(hit.word_count ?? 0) : 0,
        };
      });
    return { connected: true, folderPath, books, imported };
  } catch (e) {
    // 已连上、这次没读到：入口要留着给家长刷新重试，所以仍是 connected:true。
    console.error(`[word] 读 ima 目录失败（保留入口）: ${e?.message ?? e}`);
    return { connected: true, folderPath, books: [], imported, reason: 'ima_read_error' };
  }
}

// ===== 2. 导入 =====

/**
 * 导入（或覆盖更新）一本词表。
 *
 * ⚠️ 覆盖时**保留 book.id**：`word_scope.book_id` 指着它，删掉重建会让家长
 * 设好的范围静默指向一本不存在的书。这是 `025` 文件头写明的那条约束。
 */
export async function importWordlist(client, ctx, body) {
  const studentId = studentScope(ctx, body?.studentId);
  const mediaId = requireText(body?.mediaId, 'mediaId');
  // 词的年级学期：来自导入时的显式选择，**不解析 ima 路径**。空串允许。
  const grade = String(toText(body?.grade) ?? '').trim();
  const term = String(toText(body?.term) ?? '').trim();

  const reader = await resolveReaderContext(client, ctx, studentId);
  if (!reader) {
    // 只有家长真的点了「导入」才走得到这里（没开通时入口是隐藏的）。
    throw badRequest('当前没有可用的 ima 知识库，暂时不能导入新词表；已经导入的词表照常可以打卡。');
  }

  let fileName = String(toText(body?.fileName) ?? '').trim();
  if (fileName === '') {
    const folder = await findFolderByPath(reader, WORD_FOLDER_PATH);
    if (folder) {
      const entries = await listAllEntries(reader, {
        kbId: reader.kbId,
        folderId: folder.media_id,
      });
      const hit = entries.find(
        (item) => item.media_id === mediaId
          && Number(item.media_type ?? item.mediaType) === IMA_MEDIA_TYPE_MARKDOWN,
      );
      fileName = String(hit?.title ?? '');
    }
  }
  if (fileName === '') fileName = 'words.md';

  const { bytes } = await downloadMedia({
    clientId: reader.clientId,
    apiKey: reader.apiKey,
    fetchImpl: ctx.fetchImpl,
    kbId: reader.kbId,
    mediaId,
    maxBytes: MAX_WORDLIST_BYTES,
  });

  const parsed = parseWordlist(bytes.toString('utf8'), {
    title: titleFromFileName(fileName, ''),
  });
  const rows = flattenEntries(parsed);
  // 唯一「响亮失败」：存一本 0 词的书，页面会显示「今日 0 题」却不给任何解释。
  if (rows.length === 0) {
    throw badRequest(
      `这份词表（${fileName}）里没有识别到任何词条。需要按「word | 音标 | 中文」`
        + ' 分单元书写，详见 doc/word-checkin-ima-prompt.md。',
    );
  }

  const title = String(toText(body?.title) ?? '').trim() || parsed.title;
  const existing = await client.query(
    'select id from word_book where student_id = $1 and source_media_id = $2',
    [studentId, mediaId],
  );

  let bookId;
  if (existing.rowCount > 0) {
    bookId = existing.rows[0].id;
    await client.query('delete from word_entry where book_id = $1', [bookId]);
    await client.query(
      `update word_book set title = $2, source_path = $3, unit_count = $4,
              word_count = $5, grade = $6, term = $7, updated_at = now() where id = $1`,
      [
        bookId,
        title,
        `${WORD_FOLDER_PATH.join('/')}/${fileName}`,
        parsed.units.length,
        rows.length,
        grade,
        term,
      ],
    );
  } else {
    bookId = `wb_${randomUUID()}`;
    await client.query(
      `insert into word_book
         (id, student_id, owner_user_id, title, source, source_media_id, source_path, unit_count, word_count, grade, term)
       values ($1, $2, $3, $4, 'ima', $5, $6, $7, $8, $9, $10)`,
      [
        bookId,
        studentId,
        ctx.userId,
        title,
        mediaId,
        `${WORD_FOLDER_PATH.join('/')}/${fileName}`,
        parsed.units.length,
        rows.length,
        grade,
        term,
      ],
    );
  }

  // 几百条词条一次插入（云上逐条 insert 是几百次网络往返）。
  const payload = rows.map((entry) => ({
    id: `we_${bookId}_${String(entry.unitOrder).padStart(3, '0')}_${String(entry.sortNo).padStart(3, '0')}`,
    unit: entry.unit,
    unit_order: entry.unitOrder,
    word: entry.word,
    phonetic: entry.phonetic,
    meaning: entry.meaning,
    primary_meaning: entry.primaryMeaning,
    normalized_word: entry.normalizedWord,
    sort_no: entry.sortNo,
  }));
  await client.query(
    `insert into word_entry
       (id, book_id, student_id, unit, unit_order, word, phonetic, meaning,
        primary_meaning, normalized_word, sort_no)
     select x.id, $1, $2, x.unit, x.unit_order, x.word, x.phonetic, x.meaning,
            x.primary_meaning, x.normalized_word, x.sort_no
       from jsonb_to_recordset($3::jsonb) as x(
         id text, unit text, unit_order int, word text, phonetic text, meaning text,
         primary_meaning text, normalized_word text, sort_no int
       )`,
    [bookId, studentId, JSON.stringify(payload)],
  );

  // 首次导入自动建范围行；已有范围不覆盖（换书是家长的显式动作）。
  // 覆盖导入后若原来的「当前单元」在新词表里不存在，重置到第 1 单元 ——
  // 否则范围会静默指向一个不存在的单元，客户端过滤出 0 题。
  const unitNames = parsed.units.map((unit) => unit.unit);
  await client.query(
    `insert into word_scope (student_id, book_id, current_unit)
     values ($1, $2, $3)
     on conflict (student_id) do nothing`,
    [studentId, bookId, unitNames[0] ?? ''],
  );
  await client.query(
    `update word_scope
        set current_unit = $3, selected_units = '[]'::jsonb, updated_at = now()
      where student_id = $1 and not (current_unit = any($2::text[]))`,
    [studentId, unitNames, unitNames[0] ?? ''],
  );

  const row = await client.query('select * from word_book where id = $1', [bookId]);
  return {
    book: toBook(row.rows[0]),
    imported: true,
    unitCount: parsed.units.length,
    wordCount: rows.length,
    warnings: parsed.warnings,
  };
}

// ===== 3. 下发词表 =====

/** 客户端本地缓存用：一次给全（一本教材通常几百词，远小于一本故事书）。 */
export async function listWordEntries(client, ctx, query) {
  const bookId = requireText(query?.bookId, 'bookId');
  const studentId = studentScope(ctx, query?.studentId);
  const book = await requireOwnedBook(client, bookId, studentId);
  const r = await client.query(
    `select id, unit, unit_order, word, phonetic, meaning, primary_meaning,
            normalized_word, sort_no
       from word_entry where book_id = $1 and student_id = $2
      order by unit_order, sort_no`,
    [bookId, studentId],
  );
  const entries = r.rows.map((row) => ({
    id: row.id,
    unit: row.unit,
    unitOrder: Number(row.unit_order),
    word: row.word,
    phonetic: row.phonetic,
    meaning: row.meaning,
    primaryMeaning: row.primary_meaning,
    normalizedWord: row.normalized_word,
    sortNo: Number(row.sort_no),
  }));
  const units = [];
  const seen = new Set();
  for (const entry of entries) {
    if (seen.has(entry.unit)) continue;
    seen.add(entry.unit);
    units.push({ unit: entry.unit, unitOrder: entry.unitOrder });
  }
  return { bookId, title: book.title, units, entries };
}

// ===== 4. 练习范围 =====

const EMPTY_SCOPE = {
  studentId: '',
  bookId: '',
  bookTitle: '',
  unitMode: 'learned',
  currentUnit: '',
  selectedUnits: [],
  dailyCount: 10,
  units: [],
  configured: false,
};

/** 读范围。表没迁移时按「没配置」降级，绝不抛错。 */
export async function getWordScope(client, ctx, query) {
  const studentId = studentScope(ctx, query?.studentId);
  let row = null;
  try {
    const r = await client.query('select * from word_scope where student_id = $1', [studentId]);
    row = r.rows[0] ?? null;
  } catch (e) {
    console.error(`[word] 范围读不到（按未配置处理）: ${e?.message ?? e}`);
  }
  if (!row) return { ...EMPTY_SCOPE, studentId, units: [] };

  let units = [];
  let bookTitle = '';
  if (row.book_id) {
    try {
      const b = await client.query(
        'select title from word_book where id = $1 and student_id = $2',
        [row.book_id, studentId],
      );
      bookTitle = String(b.rows[0]?.title ?? '');
      units = await listUnits(client, row.book_id, studentId);
    } catch (e) {
      console.error(`[word] 范围的书读不到（按空处理）: ${e?.message ?? e}`);
    }
  }
  return {
    studentId,
    bookId: row.book_id ?? '',
    bookTitle,
    unitMode: row.unit_mode ?? 'learned',
    currentUnit: row.current_unit ?? '',
    selectedUnits: Array.isArray(row.selected_units) ? row.selected_units : [],
    dailyCount: Number(row.daily_count ?? 10),
    units,
    configured: true,
  };
}

/** 家长写范围。`requireParent` + 归属 / 白名单 / 单元存在性三道校验。 */
export async function putWordScope(client, ctx, body) {
  requireParent(ctx);
  const studentId = studentScope(ctx, body?.studentId);
  const bookId = requireText(body?.bookId, 'bookId');
  await requireOwnedBook(client, bookId, studentId);
  const units = await listUnits(client, bookId, studentId);
  if (units.length === 0) throw badRequest('这本书里没有任何单元');

  const unitMode = String(toText(body?.unitMode) ?? '').trim();
  if (!UNIT_MODES.has(unitMode)) throw badRequest('unitMode 只能是 current/learned/selected/all');

  const dailyCount = toInt(body?.dailyCount, 'dailyCount') ?? 10;
  if (!DAILY_COUNTS.has(dailyCount)) throw badRequest('dailyCount 只能是 5 / 10 / 15');

  const currentUnit = String(toText(body?.currentUnit) ?? '').trim() || units[0];
  if (!units.includes(currentUnit)) throw badRequest(`currentUnit 不存在：${currentUnit}`);

  const rawSelected = Array.isArray(body?.selectedUnits) ? body.selectedUnits : [];
  const selectedUnits = rawSelected.map((one) => String(one).trim()).filter(Boolean);
  if (selectedUnits.some((one) => !units.includes(one))) {
    throw badRequest('selectedUnits 里有这本书不存在的单元');
  }
  if (unitMode === 'selected' && selectedUnits.length === 0) {
    throw badRequest('selected 模式至少要选一个单元');
  }

  await client.query(
    `insert into word_scope
       (student_id, book_id, unit_mode, current_unit, selected_units, daily_count, updated_at)
     values ($1, $2, $3, $4, $5::jsonb, $6, now())
     on conflict (student_id) do update set
       book_id = excluded.book_id,
       unit_mode = excluded.unit_mode,
       current_unit = excluded.current_unit,
       selected_units = excluded.selected_units,
       daily_count = excluded.daily_count,
       updated_at = now()`,
    [studentId, bookId, unitMode, currentUnit, JSON.stringify(selectedUnits), dailyCount],
  );
  return getWordScope(client, ctx, { studentId });
}

// ===== 5. 成绩摘要 =====

/** 客户端提交当日摘要。幂等：断网重试 / 双端提交都以最后一次为准。 */
export async function postWordDaily(client, ctx, body) {
  const studentId = studentScope(ctx, body?.studentId);
  const rawDay = requireText(body?.day, 'day');
  const day = toDate(rawDay, 'day');
  if (!day) throw badRequest('day 必须是 yyyy-MM-dd');

  const total = toInt(body?.total, 'total') ?? 0;
  const correct = toInt(body?.correct, 'correct') ?? 0;
  const streak = toInt(body?.streak, 'streak') ?? 0;
  if (total < 0 || correct < 0 || streak < 0) throw badRequest('total/correct/streak 不能为负数');
  if (correct > total) throw badRequest('correct 不能大于 total');

  const rawWrong = Array.isArray(body?.wrongWords) ? body.wrongWords : [];
  const wrongWords = rawWrong
    .map((one) => ({
      word: String(one?.word ?? '').trim(),
      count: Number(one?.count ?? 0),
    }))
    .filter((one) => one.word !== '')
    .slice(0, 5);

  const r = await client.query(
    `insert into word_daily_result
       (student_id, day, total, correct, streak, wrong_words, synced_at)
     values ($1, $2::date, $3, $4, $5, $6::jsonb, now())
     on conflict (student_id, day) do update set
       total = excluded.total,
       correct = excluded.correct,
       streak = excluded.streak,
       wrong_words = excluded.wrong_words,
       synced_at = now()
     returning day::text as day, total, correct, streak, wrong_words`,
    [studentId, day, total, correct, streak, JSON.stringify(wrongWords)],
  );
  return { result: r.rows[0] };
}

/** 历史摘要。`day::text` 防 DATE 被 JSON 转成前一天；时间窗不给默认值。 */
export async function listWordDaily(client, ctx, query) {
  const studentId = studentScope(ctx, query?.studentId);
  const from = toDate(query?.from, 'from');
  const to = toDate(query?.to, 'to');
  if (from && to && from > to) throw badRequest('from 不能晚于 to');

  let limit = toInt(query?.limit, 'limit') ?? 30;
  if (limit <= 0) limit = 30;
  if (limit > 200) limit = 200;
  const offset = Math.max(0, toInt(query?.offset, 'offset') ?? 0);

  // ⚠️ `$2::date` 而不是 `::text`：写成 text 会得到 `42883 date >= text`，
  // 且假 client 证明不了 SQL 能跑（真库判据另见 probe）。
  const where = ['student_id = $1'];
  const params = [studentId];
  if (from) { params.push(from); where.push(`day >= $${params.length}::date`); }
  if (to) { params.push(to); where.push(`day <= $${params.length}::date`); }

  let rows;
  try {
    params.push(limit + 1, offset);
    const r = await client.query(
      `select day::text as day, total, correct, streak, wrong_words, synced_at
         from word_daily_result
        where ${where.join(' and ')}
        order by day desc
        limit $${params.length - 1} offset $${params.length}`,
      params,
    );
    rows = r.rows;
  } catch (e) {
    console.error(`[word] 成绩摘要读不到（按空处理）: ${e?.message ?? e}`);
    return { results: [], hasMore: false, reason: 'word_tables_unavailable' };
  }
  const hasMore = rows.length > limit;
  return {
    results: rows.slice(0, limit).map((row) => ({
      day: row.day,
      total: Number(row.total ?? 0),
      correct: Number(row.correct ?? 0),
      streak: Number(row.streak ?? 0),
      wrongWords: Array.isArray(row.wrong_words) ? row.wrong_words : [],
      syncedAt: row.synced_at,
    })),
    hasMore,
  };
}
