/**
 * 错误码与状态词 —— 全项目**唯一**定义处。
 *
 * 状态词以字符串形式同时活在：DB 列值、RLS 可见集合计算、路由校验、客户端枚举。
 * 写错一个字母不报错，只是「永远匹配不到行」，症状长在别处。
 * 所以服务端每一个状态比较都从这里取词。
 */

/** 结伴关系状态机：pending → active / rejected，active → removed（软删，留痕）。 */
export const RELATIONSHIP_STATUS = Object.freeze({
  PENDING: 'pending',
  ACTIVE: 'active',
  REJECTED: 'rejected',
  REMOVED: 'removed',
});

/** 学习计划状态（与客户端枚举尚未完全对齐，映射层必须保留）。 */
export const PLAN_STATUS = Object.freeze({
  PENDING: 'pending',
  ACTIVE: 'active',
  REJECTED: 'rejected',
  COMPLETED: 'completed',
  EXPIRED: 'expired',
});

/** 家长打卡试卷状态。 */
export const QUIZ_STATUS = Object.freeze({
  PENDING: 'pending',
  DONE: 'done',
});

export const ERROR_CODES = Object.freeze({
  INVALID_ARGUMENT: 'invalid_argument',
  UNAUTHORIZED: 'unauthorized',
  FORBIDDEN: 'forbidden',
  NOT_FOUND: 'not_found',
  CONFLICT: 'conflict',
  INVALID_PATH: 'invalid_path',
  // ⚠️ 配额失败必须与网络抖动分开：两者症状都是「这次没成功」，
  //    但一个重试也没用、一个该重试。混成一个码会让客户端无限重试到封禁。
  QUOTA_EXCEEDED: 'quota_exceeded',
  NETWORK_ERROR: 'network_error',
  PROVIDER_ERROR: 'provider_error',
  STORAGE_ERROR: 'storage_error',
  INTERNAL: 'internal',
});

const DEFAULT_STATUS = Object.freeze({
  [ERROR_CODES.INVALID_ARGUMENT]: 400,
  [ERROR_CODES.UNAUTHORIZED]: 401,
  [ERROR_CODES.FORBIDDEN]: 403,
  [ERROR_CODES.NOT_FOUND]: 404,
  [ERROR_CODES.CONFLICT]: 409,
  [ERROR_CODES.INVALID_PATH]: 400,
  [ERROR_CODES.QUOTA_EXCEEDED]: 429,
  [ERROR_CODES.NETWORK_ERROR]: 502,
  [ERROR_CODES.PROVIDER_ERROR]: 502,
  [ERROR_CODES.STORAGE_ERROR]: 500,
  [ERROR_CODES.INTERNAL]: 500,
});

export class AppError extends Error {
  constructor(code, message, { status, retryable = false, cause, details } = {}) {
    super(message, cause ? { cause } : undefined);
    this.name = 'AppError';
    this.code = code;
    this.status = status ?? DEFAULT_STATUS[code] ?? 500;
    this.retryable = retryable;
    this.details = details;
  }
}

/** 网络/超时类错误可重试；配额、鉴权、参数类一律不可重试。 */
export function isRetryable(err) {
  if (err instanceof AppError) return err.retryable === true;
  const code = err?.code;
  return code === 'ECONNRESET' || code === 'ETIMEDOUT' || code === 'ECONNREFUSED';
}

/** 统一响应体：code / message / retryable 三字段固定，客户端据此决定是否重试。 */
export function toErrorBody(err) {
  if (err instanceof AppError) {
    return {
      error: {
        code: err.code,
        message: err.message,
        retryable: err.retryable,
        ...(err.details ? { details: err.details } : {}),
      },
    };
  }
  // 未预期的异常不把堆栈/内部信息回给客户端。
  return {
    error: {
      code: ERROR_CODES.INTERNAL,
      message: '服务内部错误',
      retryable: false,
    },
  };
}

export function statusOf(err) {
  return err instanceof AppError ? err.status : 500;
}
