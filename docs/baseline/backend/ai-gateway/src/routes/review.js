/**
 * /ai/review/tips —— 知识点提示。
 *
 * ⚠️ 降级规则（这个项目的硬要求）：
 *   · 模型没配置 → 走本地规则，但**必须**回 degraded:true + reason；
 *   · 模型调用失败 → 原样抛错（带 retryable），不把失败伪装成成功；
 *   · 降级结果**不写缓存**，否则下次模型恢复后仍一直读本地兜底。
 * 绝不拿本地模板冒充 AI 输出。
 */

import { sendJson, readJson, requireString } from '../../../shared/http.js';
import { AppError, ERROR_CODES } from '../../../shared/errors.js';
import { callModel, isProviderConfigured } from '../model_client.js';

function localTips({ subject, knowledgePoint }) {
  return [
    `先复述一遍「${knowledgePoint}」的定义，再自己做一题 ${subject} 的基础题。`,
    `把「${knowledgePoint}」和最近一次做错的题对照，找出卡住的那一步。`,
  ];
}

export async function reviewRoutes(req, res, { config, url }) {
  if (req.method !== 'POST' || url.pathname !== '/ai/review/tips') {
    throw new AppError(ERROR_CODES.INVALID_ARGUMENT, '不支持的 HTTP 方法或路径', { status: 405 });
  }
  const body = await readJson(req);
  const subject = requireString(body.subject, 'subject');
  const knowledgePoint = requireString(body.knowledgePoint, 'knowledgePoint');

  if (!isProviderConfigured(config)) {
    return sendJson(res, 200, {
      data: {
        tips: localTips({ subject, knowledgePoint }),
        degraded: true,
        reason: 'model_not_configured',
        cacheable: false,
      },
    });
  }

  const content = await callModel({
    system: '你是中小学陪练老师。只给 2~3 条简短、可执行的复习提示，不要写解析，不要编造题目。',
    user: `学科：${subject}\n知识点：${knowledgePoint}`,
  }, config);

  return sendJson(res, 200, {
    data: { tips: [content], degraded: false, cacheable: true },
  });
}
