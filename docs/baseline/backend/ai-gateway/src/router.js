/**
 * AI 网关路由。
 *   /health      公开，不调模型
 *   其余 /ai/*   生产必须带 Bearer 票据；票据校验与数据服务共用 shared/session.js
 */

import { AppError, ERROR_CODES } from '../../shared/errors.js';
import { requestUrl } from '../../shared/http.js';
import { readSession } from '../../shared/session.js';
import { healthRoute } from './routes/health.js';
import { reviewRoutes } from './routes/review.js';

export async function handleRequest(req, res, { config }) {
  const url = requestUrl(req);
  const pathname = url.pathname;

  if (pathname === '/health') return healthRoute(req, res, { config });
  if (!pathname.startsWith('/ai/')) {
    throw new AppError(ERROR_CODES.NOT_FOUND, `未知路径：${pathname}`);
  }

  const session = readSession(req, config);
  if (pathname.startsWith('/ai/review')) {
    return reviewRoutes(req, res, { config, url, session });
  }

  throw new AppError(
    ERROR_CODES.NOT_FOUND,
    `AI 路由尚未迁入本基线：${pathname}（见 docs/source-index.md）`
  );
}
