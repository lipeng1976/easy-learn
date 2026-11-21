import { ApiError, ErrorCodes, toApiError } from '../../shared/errors.js';

/**
 * HTTP 信封。**与 ai-gateway 保持同一套形状** —— 客户端只写一次解析逻辑，
 * 两个服务各造一种信封会让客户端里长出两套错误处理分支。
 *
 * 成功：`{ ok: true, data, meta? }`
 * 失败：`{ ok: false, error: { code, message, retryable, details?, requestId? } }`
 */
export function okEnvelope(data, meta) {
  const body = { ok: true, data };
  if (meta !== undefined) body.meta = meta;
  return body;
}

export function jsonResponse(status, body) {
  return {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
    body: JSON.stringify(body),
  };
}

/**
 * 二进制响应（作业照片的字节）。
 *
 * ## 为什么不塞进 `jsonResponse` 用参数区分
 *
 * 图片响应**不能包信封**。客户端拿到它是要直接喂给 `Image.memory` 的，
 * 多一层 JSON 包装就多一次解码；更要紧的是，一旦包了信封，
 * 「这张响应是图片还是一段错误」就变成**必须先解析才知道**的事 ——
 * 而浏览器在图片加载失败时不会给你这个机会，它只会显示一张裂图。
 *
 * ## 缓存头为什么是 `private`
 *
 * 这是学生作业照片。`public` 会让中间的任何共享缓存（CDN、公司代理）
 * 把它存下来并可能回给另一个用户 —— 那是数据泄露，不是性能优化。
 * `max-age` 给一个短值，只为让同一页里反复渲染同一张图时不重复拉。
 */
export function binaryResponse(contentType, buffer) {
  return {
    status: 200,
    headers: {
      'content-type': String(contentType ?? '') || 'application/octet-stream',
      'content-length': String(buffer.length),
      'cache-control': 'private, max-age=300',
    },
    body: buffer,
  };
}

/** 请求 id：日志与客户端报错信息里都能对上，排查时省一次猜。 */
export function newRequestId() {
  return `req_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

/**
 * 把任意异常收敛成 HTTP 响应。
 *
 * 注意这里**不吞掉 ApiError 的语义**：`code` / `retryable` 是客户端协议的一部分
 * （它据此决定重试还是降级），不能因为「统一处理」而拍平成 500。
 */
export function errorResponse(cause, requestId) {
  const err = toApiError(cause);
  const envelope = err.toEnvelope(requestId);
  // 只有服务端自身的 bug 才值得打日志；4xx 是调用方的问题，打日志会淹没真信号。
  if (err.code === ErrorCodes.internal) {
    console.error(`[${requestId}] 未预期的异常:`, cause);
  }
  return jsonResponse(err.status, envelope);
}

/** 解析 JSON 请求体。空体当成空对象，非 JSON 直接判 bad_request。 */
export function parseJsonBody(raw) {
  const text = String(raw ?? '').trim();
  if (text === '') return {};
  try {
    const parsed = JSON.parse(text);
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new ApiError(ErrorCodes.badRequest, '请求体必须是 JSON 对象');
    }
    return parsed;
  } catch (e) {
    if (e instanceof ApiError) throw e;
    throw new ApiError(ErrorCodes.badRequest, '请求体不是合法 JSON');
  }
}
