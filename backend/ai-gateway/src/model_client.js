/**
 * 模型调用 —— 厂商凭证**只在这个进程里**，客户端永远拿不到。
 *
 * 两条硬规矩：
 *   1) 配额/鉴权失败 与 网络抖动必须分开：前者 retryable:false（重试也没用），
 *      后者 retryable:true。混成一个错误码会让客户端无限重试到被封禁。
 *   2) 降级结果必须标 degraded:true，绝不拿本地规则冒充模型输出。
 */

import { AppError, ERROR_CODES } from '../../shared/errors.js';

// 公开端点，不是密钥；密钥一律从 config 读。
const PROVIDERS = Object.freeze({
  bailian: 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
  ark: 'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
});

export function resolveProvider(config) {
  const provider = config.aiModelProvider;
  const endpoint = PROVIDERS[provider];
  if (!endpoint) {
    throw new AppError(ERROR_CODES.PROVIDER_ERROR, `未知的 AI_MODEL_PROVIDER：${provider}`);
  }
  const apiKey = provider === 'bailian' ? config.bailianApiKey : config.arkApiKey;
  const model = provider === 'bailian' ? config.bailianModel : config.arkModel;
  return { provider, endpoint, apiKey, model };
}

/** 凭证没配好时不报错，交给上层走「明确标记的降级」。 */
export function isProviderConfigured(config) {
  const { apiKey, model } = resolveProvider(config);
  return Boolean(apiKey && model && !apiKey.includes('CHANGE_ME'));
}

/**
 * 调用 chat/completions。
 * 用 AbortController 真正关掉 socket —— 只加 .timeout() 不关连接会挂住 90s。
 */
export async function callModel({ system, user, timeoutMs }, config) {
  const { endpoint, apiKey, model } = resolveProvider(config);
  if (!apiKey || apiKey.includes('CHANGE_ME')) {
    throw new AppError(ERROR_CODES.PROVIDER_ERROR, '模型凭证未配置', { retryable: false });
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs ?? config.aiGatewayTimeoutMs);
  let response;
  try {
    response = await fetch(endpoint, {
      method: 'POST',
      signal: controller.signal,
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model,
        messages: [
          { role: 'system', content: system },
          { role: 'user', content: user },
        ],
        temperature: 0.3,
      }),
    });
  } catch (err) {
    // 网络超时/断连：可重试。
    throw new AppError(ERROR_CODES.NETWORK_ERROR, `模型请求失败：${err.message}`, {
      retryable: true,
      cause: err,
    });
  } finally {
    clearTimeout(timer);
  }

  if (response.status === 429 || response.status === 402) {
    throw new AppError(ERROR_CODES.QUOTA_EXCEEDED, '模型配额不足或欠费', { retryable: false });
  }
  if (response.status === 401 || response.status === 403) {
    throw new AppError(ERROR_CODES.PROVIDER_ERROR, '模型凭证无效', { retryable: false });
  }
  if (response.status >= 500) {
    throw new AppError(ERROR_CODES.NETWORK_ERROR, `模型服务暂不可用（HTTP ${response.status}）`, {
      retryable: true,
    });
  }
  if (!response.ok) {
    throw new AppError(ERROR_CODES.PROVIDER_ERROR, `模型返回 HTTP ${response.status}`, {
      retryable: false,
    });
  }

  let payload;
  try {
    payload = await response.json();
  } catch (cause) {
    throw new AppError(ERROR_CODES.PROVIDER_ERROR, '模型返回不是合法 JSON', { cause });
  }
  const content = payload?.choices?.[0]?.message?.content;
  if (typeof content !== 'string' || content.trim() === '') {
    throw new AppError(ERROR_CODES.PROVIDER_ERROR, '模型返回内容为空');
  }
  return content;
}
