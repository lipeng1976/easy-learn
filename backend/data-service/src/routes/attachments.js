/**
 * /data/attachments —— ★ 相对路径规范的完整落地示例。
 *
 * 链路：客户端只传 id / 元数据 → 服务端生成相对键 → 写字节 → 库里只存相对路径
 *      → 读取时按 id 查行（RLS 过滤）→ local_driver 拼绝对路径 → 返回字节。
 * 客户端**没有**传路径的入口，所以「路径穿越」在这里不是一个「记得校验」的问题。
 */

import { randomUUID } from 'node:crypto';
import { sendJson, sendBinary, readJson, requireString } from '../../../shared/http.js';
import { AppError, ERROR_CODES } from '../../../shared/errors.js';
import { withTenant } from '../../../shared/db.js';
import { toStorageKey } from '../../../shared/paths.js';
import { assertLocalDriver, writeBytes, readBytes } from '../storage/local_driver.js';

const PREFIX = '/data/attachments';
const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;

export async function attachmentRoutes(req, res, { config, url, identity }) {
  assertLocalDriver(config);
  const pathname = url.pathname;

  // ── 上传 ───────────────────────────────────────────────────────────────
  if (req.method === 'POST' && pathname === PREFIX) {
    const body = await readJson(req, { maxBytes: MAX_UPLOAD_BYTES * 2 });
    const studentId = requireString(body.studentId, 'studentId');
    if (!identity.visibleStudents.includes(studentId)) {
      throw new AppError(ERROR_CODES.FORBIDDEN, '该学生不在当前用户的可见集合内');
    }
    const fileName = requireString(body.fileName, 'fileName');
    const mimeType = requireString(body.mimeType, 'mimeType');
    const contentBase64 = requireString(body.contentBase64, 'contentBase64');
    const bytes = Buffer.from(contentBase64, 'base64');
    if (bytes.length === 0 || bytes.length > MAX_UPLOAD_BYTES) {
      throw new AppError(ERROR_CODES.INVALID_ARGUMENT, '附件为空或超过 10 MiB');
    }

    const ext = (fileName.includes('.') ? fileName.split('.').pop() : 'bin').toLowerCase();
    const relativePath = toStorageKey({ studentId, ext });
    await writeBytes(relativePath, bytes);

    const id = randomUUID();
    // ⚠️ 写接口 RETURNING 回来的那一行必须被采纳，不要用本地占位 id。
    //    否则症状是「刚提交看不到、重登就好」，且不报错。
    const row = await withTenant(identity, async (client) => {
      const { rows } = await client.query(
        `INSERT INTO homework_image
           (id, student_id, homework_id, relative_path, file_name, file_size,
            mime_type, ocr_status, ocr_text, batch_id, sort_order)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
         RETURNING id, student_id, relative_path, file_name, mime_type, file_size, created_at`,
        [
          id, studentId, body.homeworkId ?? '', relativePath, fileName,
          bytes.length, mimeType, 'pending', '', body.batchId ?? '', 0,
        ]
      );
      return rows[0];
    });
    return sendJson(res, 201, { data: row });
  }

  // ── 按 id 读字节（客户端不传路径）────────────────────────────────────────
  if (req.method === 'GET' && pathname.startsWith(`${PREFIX}/`)) {
    const rawId = pathname.slice(PREFIX.length + 1);
    const id = decodeURIComponent(rawId);
    if (!id || id.includes('/')) {
      throw new AppError(ERROR_CODES.INVALID_ARGUMENT, '附件 id 不合法');
    }
    const row = await withTenant(identity, async (client) => {
      const { rows } = await client.query(
        `SELECT id, relative_path, file_name, mime_type
         FROM homework_image WHERE id = $1`,
        [id]
      );
      return rows[0];
    });
    if (!row) throw new AppError(ERROR_CODES.NOT_FOUND, '附件不存在或不可见');
    const bytes = await readBytes(row.relative_path);
    return sendBinary(res, bytes, { mimeType: row.mime_type, fileName: row.file_name });
  }

  // ── 列表（只回相对路径，不回绝对路径）────────────────────────────────────
  if (req.method === 'GET' && pathname === PREFIX) {
    const studentId = requireString(url.searchParams.get('studentId') ?? '', 'studentId');
    if (!identity.visibleStudents.includes(studentId)) {
      throw new AppError(ERROR_CODES.FORBIDDEN, '该学生不在当前用户的可见集合内');
    }
    const rows = await withTenant(identity, async (client) => {
      const { rows } = await client.query(
        `SELECT id, student_id, relative_path, file_name, mime_type, file_size, created_at
         FROM homework_image WHERE student_id = $1
         ORDER BY created_at DESC LIMIT 100`,
        [studentId]
      );
      return rows;
    });
    return sendJson(res, 200, { data: rows });
  }

  throw new AppError(ERROR_CODES.INVALID_ARGUMENT, '不支持的 HTTP 方法或路径', { status: 405 });
}
