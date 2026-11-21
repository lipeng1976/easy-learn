/**
 * 路由分工：
 *   /health          公开，不连库
 *   /auth/*          公开，走认证逻辑（登录时还没有身份）
 *   其余 /data/*     必须鉴权，身份只从签名的会话票据取
 */

import { AppError, ERROR_CODES } from '../../shared/errors.js';
import { requestUrl } from '../../shared/http.js';
import { authenticate } from './auth.js';
import { healthRoute } from './routes/health.js';
import { authRoutes } from './routes/auth.js';
import { attachmentRoutes } from './routes/attachments.js';

export async function handleRequest(req, res, { config }) {
  const url = requestUrl(req);
  const pathname = url.pathname;

  if (pathname === '/health') return healthRoute(req, res, { config });
  if (pathname.startsWith('/auth/')) return authRoutes(req, res, { config, url });

  if (!pathname.startsWith('/data/')) {
    throw new AppError(ERROR_CODES.NOT_FOUND, `未知路径：${pathname}`);
  }

  const identity = authenticate(req, config);
  if (pathname.startsWith('/data/attachments')) {
    return attachmentRoutes(req, res, { config, url, identity });
  }

  throw new AppError(
    ERROR_CODES.NOT_FOUND,
    `业务路由尚未迁入本基线：${pathname}（见 docs/source-index.md）`
  );
}
