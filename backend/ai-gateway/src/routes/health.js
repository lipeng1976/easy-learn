/**
 * AI 网关健康检查：不调模型、不连库。
 * 只回「厂商是否已配置」这个布尔，绝不回传任何凭证内容。
 */

import { sendJson } from '../../../shared/http.js';
import { AppError, ERROR_CODES } from '../../../shared/errors.js';
import { isProviderConfigured } from '../model_client.js';

export function healthRoute(req, res, { config }) {
  if (req.method !== 'GET') {
    throw new AppError(ERROR_CODES.INVALID_ARGUMENT, 'health 只支持 GET', { status: 405 });
  }
  sendJson(res, 200, {
    status: 'ok',
    service: 'ai-gateway',
    nodeEnv: config.nodeEnv,
    authRequired: config.requireAuth,
    provider: config.aiModelProvider,
    modelConfigured: isProviderConfigured(config),
    time: new Date().toISOString(),
  });
}
