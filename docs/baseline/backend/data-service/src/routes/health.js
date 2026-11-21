/**
 * 健康检查：**不连数据库、不读存储**。
 * 用途：区分「服务没起来」和「库没连上」。因此未 npm install 也能起服务。
 * ⚠️ 不回传 STORAGE_ROOT 的绝对路径，避免把部署机目录结构暴露给客户端。
 */

import { sendJson } from '../../../shared/http.js';
import { AppError, ERROR_CODES } from '../../../shared/errors.js';

export function healthRoute(req, res, { config }) {
  if (req.method !== 'GET') {
    throw new AppError(ERROR_CODES.INVALID_ARGUMENT, 'health 只支持 GET', { status: 405 });
  }
  sendJson(res, 200, {
    status: 'ok',
    service: 'data-service',
    nodeEnv: config.nodeEnv,
    authRequired: config.requireAuth,
    imageDriver: config.imageDriver,
    storageConfigured: true,
    database: 'not connected (health 不连库)',
    time: new Date().toISOString(),
  });
}
