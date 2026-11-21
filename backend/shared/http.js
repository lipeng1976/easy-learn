/**
 * 两个服务共用的 HTTP 工具（只用 Node 内置模块，不引框架）。
 */

import { AppError, ERROR_CODES, toErrorBody, statusOf } from './errors.js';

const CORS_HEADERS = {
  // 本地 Flutter Web 联调需要；生产应由网关层按域名收敛，不要直接暴露 *。
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
};

export function sendJson(res, status, body, extraHeaders = {}) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
    'Cache-Control': 'no-store',
    ...CORS_HEADERS,
    ...extraHeaders,
  });
  res.end(payload);
}

export function sendError(res, err, log = console) {
  if (!(err instanceof AppError)) {
    // 未预期异常必须留痕迹，否则就是「静默失败」。
    log.error?.('[unhandled]', err);
  }
  sendJson(res, statusOf(err), toErrorBody(err));
}

export function sendNoContent(res) {
  res.writeHead(204, CORS_HEADERS);
  res.end();
}

/** 二进制响应（附件字节）；客户端只拿到字节，不接触任何路径。 */
export function sendBinary(res, bytes, { mimeType = 'application/octet-stream', fileName } = {}) {
  const headers = {
    'Content-Type': mimeType,
    'Content-Length': bytes.length,
    'Cache-Control': 'no-store',
    ...CORS_HEADERS,
  };
  if (fileName) {
    headers['Content-Disposition'] = `inline; filename="${String(fileName).replace(/["\r\n]/g, '')}"`;
  }
  res.writeHead(200, headers);
  res.end(bytes);
}

/** 解析 URL，返回 URL 对象；避免手写字符串切分带来的编码坑。 */
export function requestUrl(req) {
  return new URL(req.url ?? '/', 'http://localhost');
}

/** 读取并解析 JSON 请求体；超限直接抛 413，不静默截断。 */
export async function readJson(req, { maxBytes = 5 * 1024 * 1024 } = {}) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > maxBytes) {
      throw new AppError(ERROR_CODES.INVALID_ARGUMENT, '请求体过大', { status: 413 });
    }
    chunks.push(chunk);
  }
  if (size === 0) return {};
  const text = Buffer.concat(chunks).toString('utf8');
  try {
    const parsed = JSON.parse(text);
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error('body 必须是 JSON 对象');
    }
    return parsed;
  } catch (cause) {
    throw new AppError(ERROR_CODES.INVALID_ARGUMENT, '请求体不是合法的 JSON 对象', { cause });
  }
}

export function requireString(value, name, { allowEmpty = false } = {}) {
  if (typeof value !== 'string' || (!allowEmpty && value.trim() === '')) {
    throw new AppError(ERROR_CODES.INVALID_ARGUMENT, `${name} 必须是非空字符串`);
  }
  return value;
}
