/**
 * 语音合成（百炼 `qwen3-tts-flash`）。
 *
 * ## 为什么这条能力必须放在服务端
 *
 * 学生用的那台鸿蒙手机跑的是**卓易通**（鸿蒙 NEXT 的安卓兼容层）。
 * 鸿蒙 NEXT 的朗读能力是 `CoreSpeechKit`（ArkTS 原生接口），而卓易通
 * 没有实现安卓那套 `TextToSpeechService` —— 端上 `TextToSpeech` 这条路
 * 在那台机器上**根本不存在**：`speak()` 会把主线程卡住十几秒然后超时。
 *
 * 所以伴读只能改成「服务端合成音频、客户端只负责播放」。这条路与设备
 * 有没有 TTS 引擎完全无关，顺带还比系统 TTS 好听得多。
 *
 * ## 几个不能省的约束
 *
 * 1. **单次 ≤600 字符**（厂商硬限制），这里按 480 切，留出标点余量。
 * 2. **不能一次把整篇课文塞进去**：一篇课文 1500~3000 字，必须切段。
 *    切在句子边界上，否则一段音频会在词中间 abrupt 停止。
 * 3. **返回的 URL 24 小时后失效**，所以客户端要**下载成文件**再播，
 *    不能缓存 URL（缓存 URL 的后果是「昨天能听、今天点了没反应」）。
 * 4. **失败必须给出可分辨的码**：Key 没配（model_not_enabled）、
 *    凭证错（model_auth_failed）、厂商 5xx（model_unavailable）、
 *    超时（model_timeout）—— 客户端对它们的处置完全不同。
 */

import { ErrorCodes, GatewayError } from './errors.js';

/**
 * 单次请求允许的最大字数。超了直接拒 —— 语音合成按字符计费。
 *
 * 5000 这个数是**照最长的一篇课文定的**（Lesson 15「Of Beauty」正文 4696 字符）。
 * 当初写 3000 是想省着点，结果正好把这唯一一篇挡在门外：点伴读直接 400，
 * 而且文案是「单次最多合成 3000 字」—— 学生看不懂，只会以为这一篇坏了。
 * 5000 字约 0.4 元，当滥用闸门仍然够紧。
 */
export const TTS_MAX_INPUT_CHARS = 5000;

/**
 * 每一段交给厂商的字数。
 *
 * 厂商上限是 600，取 480 是为了**在句号处切得开**：正好卡 600 时，
 * 最后一句往往只能硬切，念出来会在半个词上断掉。
 */
export const TTS_SEGMENT_CHARS = 480;

/** 同一时刻最多向厂商发几条。QPS 限制不高的账号串行也能跑，但会拖到客户端超时。 */
const TTS_CONCURRENCY = 2;

/** 单段合成的超时。厂商侧正常 1~3 秒，给到 30 秒是为了扛住长段排队。 */
const TTS_SEGMENT_TIMEOUT_MS = 30000;

/**
 * 句末标点。中英文都收。
 *
 * 英文的 `.` 会在 `Mr.` / `e.g.` 处误判成句末 —— 代价只是多一段音频，
 * 反过来漏判的代价是整篇一口气念完、中间不换气，听感差得多。
 */
const SENTENCE_END = new Set(['。', '！', '？', '；', '\n', '.', '!', '?', ';']);

/**
 * 把长文本切成若干段，每段尽量 ≤ [maxChars]，且**切在句子边界**。
 *
 * 单句本身超长（没有标点的技术文本）时才硬切。
 */
export function splitForTts(text, maxChars = TTS_SEGMENT_CHARS) {
  const normalized = String(text ?? '').replace(/\r\n/g, '\n').trim();
  if (normalized === '') return [];

  // 先按句末标点切成句子（连续标点跟着同一句走，避免析出「。」这种一眼假的一段）。
  const sentences = [];
  let buffer = '';
  for (let i = 0; i < normalized.length; i += 1) {
    const ch = normalized[i];
    buffer += ch;
    if (!SENTENCE_END.has(ch)) continue;
    while (i + 1 < normalized.length && SENTENCE_END.has(normalized[i + 1])) {
      i += 1;
      buffer += normalized[i];
    }
    if (buffer.trim() !== '') sentences.push(buffer);
    buffer = '';
  }
  if (buffer.trim() !== '') sentences.push(buffer);

  // 再按长度把句子拼成段。
  const segments = [];
  let current = '';
  const flush = () => {
    const piece = current.trim();
    if (piece !== '') segments.push(piece);
    current = '';
  };

  for (const sentence of sentences) {
    if (sentence.length > maxChars) {
      // 单句超长：先把手里的攒段发掉，再硬切这一句。
      flush();
      for (let offset = 0; offset < sentence.length; offset += maxChars) {
        const piece = sentence.slice(offset, offset + maxChars).trim();
        if (piece !== '') segments.push(piece);
      }
      continue;
    }
    if ((current + sentence).length > maxChars) flush();
    current += sentence;
  }
  flush();
  return segments;
}

function ttsError(code, message, { status = 502, retryable = true } = {}) {
  return new GatewayError(code, message, { status, retryable });
}

/**
 * 合成一段。返回厂商给的音频地址。
 *
 * 不在这里下载音频：网关跑在函数计算/本机上，把几 MB 字节在进程里搬一遍
 * 只会拖慢响应；客户端本来就要落到本地文件（见文件头第 3 条约束）。
 */
async function synthesizeSegment({
  text,
  language,
  voice,
  apiKey,
  baseUrl,
  model,
  fetchImpl,
}) {
  const url = `${baseUrl}/api/v1/services/aigc/multimodal-generation/generation`;
  let response;
  try {
    response = await fetchImpl(url, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model,
        input: {
          text,
          voice,
          language_type: language === 'en' ? 'English' : 'Chinese',
          // ⚠️ 2026-11-07 实测：`format: 'mp3'` 与 `parameters.sample_rate`
          //    在 qwen3-tts-flash 上**都不生效** —— 返回的永远是
          //    24kHz / 16bit / 单声道 wav（≈48KB 每秒，1224 字 → 3 段 1.65MB）。
          //    仍然传着它：厂商哪天支持了就直接生效，客户端不用改。
          //    客户端据此改成**流式播放**，不先下载整个文件（见 ServerTts）。
          format: 'mp3',
        },
      }),
      signal: AbortSignal.timeout(TTS_SEGMENT_TIMEOUT_MS),
    });
  } catch (cause) {
    const timedOut = cause?.name === 'TimeoutError' || cause?.name === 'AbortError';
    throw ttsError(
      timedOut ? ErrorCodes.modelTimeout : ErrorCodes.modelUnavailable,
      timedOut
        ? `语音合成超时（${TTS_SEGMENT_TIMEOUT_MS / 1000}s）`
        : `语音合成请求发不出去：${cause?.message ?? cause}`,
    );
  }

  let body = null;
  try {
    body = await response.json();
  } catch {
    body = null;
  }

  if (!response.ok) {
    const vendorCode = String(body?.code ?? '');
    const vendorMessage = String(body?.message ?? '').slice(0, 200);
    // 401/403 是凭证问题，重试一百次也一样 —— 必须与「厂商抖了一下」分开。
    if (response.status === 401 || response.status === 403) {
      throw ttsError(
        ErrorCodes.modelAuthFailed,
        `语音合成凭证被拒绝（HTTP ${response.status}）：${vendorMessage || 'Key 无效或未开通'}`,
        { status: 502, retryable: false },
      );
    }
    if (vendorCode === 'ModelNotFound' || /model not exist/i.test(vendorMessage)) {
      throw ttsError(
        ErrorCodes.modelNotEnabled,
        `语音合成模型 ${model} 不可用：${vendorMessage || '该账号没有开通'}`,
        { status: 503, retryable: false },
      );
    }
    throw ttsError(
      ErrorCodes.modelUnavailable,
      `语音合成失败（HTTP ${response.status}）：${vendorMessage || '厂商未给出原因'}`,
    );
  }

  const audioUrl = body?.output?.audio?.url;
  if (typeof audioUrl !== 'string' || audioUrl === '') {
    // 200 但没有音频地址，是本项目里典型的「静默失败」形状：不报错、也没声音。
    throw ttsError(
      ErrorCodes.modelOutputInvalid,
      `语音合成没有返回音频地址（request_id=${body?.request_id ?? '无'}）`,
    );
  }
  // ⚠️ 厂商给的是 `http://dashscope-result-….oss-…aliyuncs.com/…`，而客户端的
  // 网络安全策略**只对回环地址放行明文**（`network_security_config.xml`，
  // 那一条是 just_audio 的本地代理要用的）。拿一个 http 的第三方地址去播，
  // 安卓会直接拒 —— 表现是「照片、视频都好好的，只有音频播不出来」。
  // 同一路径换成 https 实测可用（2026-11-07，HTTP 200、字节一致），
  // 所以在这里统一升级，客户端不需要知道这件事。
  return audioUrl.replace(/^http:\/\//i, 'https://');
}

/**
 * 把整篇文本合成成若干段音频。
 *
 * 返回值里的 `segments` **保持原文顺序**：客户端要按顺序播，
 * 顺序错了就是「第二段先念」。并发只发生在「段与段之间」，不改顺序。
 */
export async function synthesizeTts({
  text,
  language = 'zh',
  voice,
  apiKey,
  baseUrl,
  model,
  fetchImpl = globalThis.fetch,
}) {
  const normalized = String(text ?? '').trim();
  if (normalized === '') {
    throw new GatewayError(ErrorCodes.badRequest, 'text 不能为空', { status: 400 });
  }
  if (normalized.length > TTS_MAX_INPUT_CHARS) {
    throw new GatewayError(
      ErrorCodes.badRequest,
      `单次最多合成 ${TTS_MAX_INPUT_CHARS} 字（这次 ${normalized.length} 字）`,
      { status: 400 },
    );
  }
  if (!apiKey) {
    throw new GatewayError(
      ErrorCodes.modelNotEnabled,
      '网关没有配置百炼 API Key（BAILIAN_API_KEY），语音合成不可用',
      { status: 503, retryable: false },
    );
  }
  if (typeof fetchImpl !== 'function') {
    throw new GatewayError(ErrorCodes.internal, '运行时没有 fetch，语音合成无法发出请求', {
      status: 500,
    });
  }

  const chunks = splitForTts(normalized);
  if (chunks.length === 0) {
    throw new GatewayError(ErrorCodes.badRequest, 'text 里没有可朗读的内容', { status: 400 });
  }

  const urls = new Array(chunks.length);
  let cursor = 0;
  async function worker() {
    while (cursor < chunks.length) {
      const index = cursor;
      cursor += 1;
      urls[index] = await synthesizeSegment({
        text: chunks[index],
        language,
        voice,
        apiKey,
        baseUrl,
        model,
        fetchImpl,
      });
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(TTS_CONCURRENCY, chunks.length) }, () => worker()),
  );

  const expiresAt = Date.now() + 23 * 60 * 60 * 1000;
  return {
    segments: chunks.map((chunk, index) => ({
      index,
      text: chunk,
      url: urls[index],
      chars: chunk.length,
    })),
    characters: normalized.length,
    expiresAt,
    model,
    voice,
    language,
  };
}
