/**
 * 会话票据 —— 两个服务**共用**。
 *
 * 为什么在 shared：数据服务签票、AI 网关验票。若两边各写一份校验，
 * 迟早会在某次改动里分叉，而分叉的后果是「一边签的票另一边验不过」——
 * 表现为 401，但没有任何配置错误提示。
 *
 * 票据是无状态 HMAC：v1.<payload>.<sig>，密钥只来自 config.sessionSecret。
 */

import crypto from 'node:crypto';
import { AppError, ERROR_CODES } from './errors.js';

const TOKEN_VERSION = 'v1';

function b64url(buffer) {
  return Buffer.from(buffer).toString('base64url');
}

export function signSession({ userId, name = '', role = '', visibleStudents = [], ttlHours }, secret) {
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    v: TOKEN_VERSION,
    sub: userId,
    name,
    role,
    vs: visibleStudents,
    iat: now,
    exp: now + ttlHours * 3600,
    jti: crypto.randomUUID(),
  };
  const body = b64url(JSON.stringify(payload));
  const sig = crypto.createHmac('sha256', secret).update(`${TOKEN_VERSION}.${body}`).digest();
  return `${TOKEN_VERSION}.${body}.${b64url(sig)}`;
}

export function verifySession(token, secret) {
  const parts = typeof token === 'string' ? token.split('.') : [];
  if (parts.length !== 3 || parts[0] !== TOKEN_VERSION) {
    throw new AppError(ERROR_CODES.UNAUTHORIZED, '无效的会话票据');
  }
  const [, body, signature] = parts;
  const expected = crypto.createHmac('sha256', secret).update(`${TOKEN_VERSION}.${body}`).digest();
  let actual;
  try {
    actual = Buffer.from(signature, 'base64url');
  } catch {
    throw new AppError(ERROR_CODES.UNAUTHORIZED, '无效的会话票据');
  }
  if (actual.length !== expected.length || !crypto.timingSafeEqual(actual, expected)) {
    throw new AppError(ERROR_CODES.UNAUTHORIZED, '会话票据签名不匹配');
  }
  let payload;
  try {
    payload = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
  } catch {
    throw new AppError(ERROR_CODES.UNAUTHORIZED, '会话票据内容损坏');
  }
  if (!payload.sub || !Number.isFinite(payload.exp) || payload.exp <= Date.now() / 1000) {
    throw new AppError(ERROR_CODES.UNAUTHORIZED, '会话已过期，请重新登录');
  }
  if (!Array.isArray(payload.vs)) payload.vs = [];
  return payload;
}

/** 从请求头解析票据，返回 payload；开发模式返回 null 表示「无需鉴权」。 */
export function readSession(req, config) {
  if (!config.requireAuth) return null;
  const header = req.headers?.authorization ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
  if (!token) throw new AppError(ERROR_CODES.UNAUTHORIZED, '缺少 Bearer 会话票据');
  return verifySession(token, config.sessionSecret);
}
