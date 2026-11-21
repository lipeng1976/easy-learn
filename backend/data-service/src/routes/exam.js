/**
 * 试卷错题：ima `教学资料/试卷错题/` 下的 MD → `review_mistake`。
 *
 * 与教材 / 词表导入是同一套骨架（`resolveReaderContext` → `downloadMedia` →
 * 解析 → 幂等落库），差别只在**写哪张表**：
 * - 教材 / 词表写「范围」（`subject_book` / `word_book`），供计划出题取知识点；
 * - 试卷错题写「错题本」（`review_mistake`），供复习侧组卷与举一反三直接用。
 *
 * 🔴 三条删除 / 插入 SQL 都必须带 `student_id` + `source_type='ima_exam'`：
 * 少了前者跨学生删错人，少了后者会把手工录入 / 作业批改 / 打卡回流的错题
 * 一起删掉 —— 而且页面不会报错，只是「错题突然少了一大片」。
 */
import { randomUUID } from 'node:crypto';
import { badRequest } from '../../../shared/errors.js';
import { requireText } from '../coerce.js';
import { downloadMedia, IMA_MEDIA_TYPE_MARKDOWN } from '../ima_openapi.js';
import {
  EXAM_MISTAKE_FOLDER_PATH,
  EXAM_MISTAKE_FORMAT_HINT,
  EXAM_MISTAKE_MAX_BYTES,
  EXAM_MISTAKE_SOURCE_TYPE,
  parseExamMistakes,
} from '../exam_mistake_import.js';
import {
  findFolderByPath,
  listAllEntries,
  resolveReaderContext,
  studentScope,
} from './reading.js';

const FOLDER_PATH_TEXT = EXAM_MISTAKE_FOLDER_PATH.join('/');

/** 已导入的文件 → 各自产出了几条错题。只看本来源，别把别的来源算进来。 */
async function importedCounts(client, studentId) {
  const r = await client.query(
    `select source_ref, count(*)::int as n
       from review_mistake
      where student_id = $1 and source_type = $2 and source_ref <> ''
      group by source_ref`,
    [studentId, EXAM_MISTAKE_SOURCE_TYPE],
  );
  return new Map(r.rows.map((row) => [row.source_ref, Number(row.n ?? 0)]));
}

/** 列出可导入的试卷错题 MD。ima 不可用时恒 2xx + connected:false。 */
export async function listExamMistakeFiles(client, ctx, query) {
  const studentId = studentScope(ctx, query?.studentId);
  const counts = await importedCounts(client, studentId);
  const unavailable = {
    connected: false,
    folderPath: FOLDER_PATH_TEXT,
    files: [],
    reason: 'ima_unavailable',
  };

  const reader = await resolveReaderContext(client, ctx, studentId);
  if (!reader) return unavailable;

  try {
    const folder = await findFolderByPath(reader, EXAM_MISTAKE_FOLDER_PATH);
    if (!folder) {
      return {
        connected: true,
        folderPath: FOLDER_PATH_TEXT,
        files: [],
        reason: 'folder_missing',
      };
    }
    const entries = await listAllEntries(reader, {
      kbId: reader.kbId,
      folderId: folder.media_id,
    });
    const files = entries
      .filter((item) => Number(item.media_type ?? item.mediaType) === IMA_MEDIA_TYPE_MARKDOWN)
      .map((item) => ({
        mediaId: item.media_id,
        fileName: String(item.title ?? ''),
        importedCount: counts.get(item.media_id) ?? 0,
      }));
    return { connected: true, folderPath: FOLDER_PATH_TEXT, files };
  } catch (e) {
    console.error(`[exam] 读 ima 目录失败（保留入口）: ${e?.message ?? e}`);
    return {
      connected: true,
      folderPath: FOLDER_PATH_TEXT,
      files: [],
      reason: 'ima_read_error',
    };
  }
}

/** 学生当前的年级 / 学期快照。读不到就留空，不让整次导入失败。 */
async function profileGradeTerm(client, studentId) {
  try {
    const r = await client.query('select grade, term from app_user where id = $1', [studentId]);
    return {
      grade: String(r.rows[0]?.grade ?? ''),
      term: String(r.rows[0]?.term ?? ''),
    };
  } catch {
    return { grade: '', term: '' };
  }
}

/**
 * 导入一份试卷。同一个 mediaId 再次导入 = 先删旧行再写，不翻倍。
 *
 * `homework_id` 刻意留空（默认 ''）：它不是作业，塞一个 id 进去会让
 * 作业详情页查一条永远不存在的行。
 */
export async function importExamMistakes(client, ctx, body) {
  const studentId = studentScope(ctx, body?.studentId);
  const mediaId = requireText(body?.mediaId, 'mediaId');

  const reader = await resolveReaderContext(client, ctx, studentId);
  if (!reader) {
    throw badRequest('当前没有可用的 ima 知识库，暂时不能导入试卷错题；已经录入的错题照常能复习。');
  }

  const { bytes } = await downloadMedia({
    clientId: reader.clientId,
    apiKey: reader.apiKey,
    fetchImpl: ctx.fetchImpl,
    kbId: reader.kbId,
    mediaId,
    maxBytes: EXAM_MISTAKE_MAX_BYTES,
  });

  const parsed = parseExamMistakes(bytes.toString('utf8'));
  if (parsed.items.length === 0) {
    throw badRequest(
      `这份 MD 里没有识别到任何错题（也可能误选了 App 自动生成的「错题档案」镜像）。${EXAM_MISTAKE_FORMAT_HINT}`,
    );
  }

  const gradeTerm = await profileGradeTerm(client, studentId);
  const removed = await client.query(
    `delete from review_mistake
      where student_id = $1 and source_type = $2 and source_ref = $3`,
    [studentId, EXAM_MISTAKE_SOURCE_TYPE, mediaId],
  );

  for (const item of parsed.items) {
    await client.query(
      `insert into review_mistake
         (id, student_id, subject, title, question_body, question_no, student_process,
          answer_key, original_answer, wrong_reason, state, knowledge_point, wrong_count,
          last_wrong_at, source_homework_title, source_type, grade, term, image_count,
          source_ref)
       values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'pending', $11, $12,
               now(), $13, $14, $15, $16, 0, $17)`,
      [
        `rm_exam_${randomUUID().replace(/-/g, '').slice(0, 16)}`,
        studentId,
        item.subject,
        item.title,
        item.questionBody,
        item.questionNo,
        item.studentProcess,
        item.answerKey,
        item.originalAnswer,
        item.wrongReason,
        item.knowledgePoint,
        item.wrongCount,
        item.sourceHomeworkTitle || parsed.examTitle,
        EXAM_MISTAKE_SOURCE_TYPE,
        gradeTerm.grade,
        gradeTerm.term,
        mediaId,
      ],
    );
  }

  return {
    mediaId,
    examTitle: parsed.examTitle,
    subject: parsed.subject,
    imported: parsed.items.length,
    removed: Number(removed?.rowCount ?? 0),
  };
}

/** 撤销某份试卷导入的错题。幂等：没导入过也返回成功（removed:0）。 */
export async function revokeExamMistakes(client, ctx, body) {
  const studentId = studentScope(ctx, body?.studentId);
  const mediaId = requireText(body?.mediaId, 'mediaId');
  const r = await client.query(
    `delete from review_mistake
      where student_id = $1 and source_type = $2 and source_ref = $3`,
    [studentId, EXAM_MISTAKE_SOURCE_TYPE, mediaId],
  );
  return { mediaId, removed: Number(r?.rowCount ?? 0) };
}
