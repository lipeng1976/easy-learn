/**
 * /auth/* —— 公开路由（登录时还没有身份）。
 * 账号由运维脚本 scripts/create-user.mjs 在运行期创建，种子 SQL 里没有任何账号。
 */

import { sendJson, readJson, requireString } from '../../../shared/http.js';
import { AppError, ERROR_CODES } from '../../../shared/errors.js';
import { login, verifySession, authenticate } from '../auth.js';

export async function authRoutes(req, res, { config, url }) {
  const pathname = url.pathname;

  if (req.method === 'POST' && pathname === '/auth/login') {
    const body = await readJson(req);
    const result = await login(body, config);
    return sendJson(res, 200, { data: result });
  }

  // 自检端点：给运维确认「这把票是不是本环境签的」，不泄露密钥。
  if (req.method === 'POST' && pathname === '/auth/verify') {
    const body = await readJson(req);
    const token = requireString(body.token, 'token');
    const payload = verifySession(token, config.sessionSecret);
    return sendJson(res, 200, {
      data: {
        userId: payload.sub,
        name: payload.name,
        role: payload.role,
        visibleStudents: payload.vs,
        expiresAt: new Date(payload.exp * 1000).toISOString(),
      },
    });
  }

  if (req.method === 'GET' && pathname === '/auth/me') {
    return sendJson(res, 200, { data: authenticate(req, config) });
  }

  if (pathname.startsWith('/auth/')) {
    throw new AppError(ERROR_CODES.NOT_FOUND, `未知认证端点：${pathname}`, { status: 404 });
  }
  throw new AppError(ERROR_CODES.INVALID_ARGUMENT, '不支持的 HTTP 方法', { status: 405 });
}
