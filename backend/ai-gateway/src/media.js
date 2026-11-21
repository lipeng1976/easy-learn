import { badRequest, payloadTooLarge } from './errors.js';

/**
 * 允许的图片类型。
 *
 * 用白名单而不是黑名单：内联模式下图片会被拼成 `data:` URI 交给模型，
 * 放开类型等于允许客户端让模型去加载任意类型的内容。
 */
const ALLOWED_MIME = new Set([
  'image/jpeg',
  'image/jpg',
  'image/png',
  'image/webp',
  'image/heic',
  'image/heif',
]);

/** base64 的字符集校验。 */
const BASE64_PATTERN = /^[A-Za-z0-9+/\r\n]+={0,2}$/;

/**
 * 把客户端送来的图片载荷转成方舟的多模态 content 片段。
 *
 * 支持两种形态，与客户端 `AiImageTransport` 的两种模式一一对应：
 * - `{ base64, mimeType }` —— 内联模式，网关转成 `data:` URI
 * - `{ url }` —— 对象存储模式，直接把 URL 交给模型
 *
 * 为什么由网关拼 `data:` 前缀而不是客户端：这是「怎么交给模型」的实现细节。
 * 以后方舟支持 `file_id` 复用（同一张照片重复批改不重复计费），
 * 只需要改这里一个函数，客户端与契约都不用动。
 *
 * @returns {{parts: object[], imageCount: number, totalBytes: number, skipped: number}}
 */
export function normalizeImages(rawImages, config) {
  if (rawImages === undefined || rawImages === null) {
    return { parts: [], imageCount: 0, totalBytes: 0, skipped: 0 };
  }
  if (!Array.isArray(rawImages)) {
    throw badRequest('images 应为数组');
  }
  if (rawImages.length > config.maxImages) {
    throw payloadTooLarge(
      `单次最多 ${config.maxImages} 张照片，本次收到 ${rawImages.length} 张`,
      { limit: config.maxImages, received: rawImages.length },
    );
  }

  const parts = [];
  let totalBytes = 0;

  rawImages.forEach((raw, index) => {
    const at = `images[${index}]`;
    if (typeof raw !== 'object' || raw === null) {
      throw badRequest(`${at} 应为对象`);
    }

    const mimeType = String(raw.mimeType ?? '').toLowerCase();
    if (!ALLOWED_MIME.has(mimeType)) {
      throw badRequest(
        `${at}.mimeType 不支持：${mimeType || '(空)'}，仅支持 ${[...ALLOWED_MIME].join(' / ')}`,
      );
    }

    if (typeof raw.url === 'string' && raw.url !== '') {
      parts.push({
        type: 'image_url',
        image_url: { url: assertSafeUrl(raw.url, at), detail: 'high' },
      });
      return;
    }

    const base64 = typeof raw.base64 === 'string' ? raw.base64 : '';
    if (base64 === '') {
      throw badRequest(`${at} 既没有 url 也没有 base64`);
    }
    if (!BASE64_PATTERN.test(base64)) {
      throw badRequest(`${at}.base64 不是合法的 base64`);
    }

    // 从 base64 长度反推字节数，避免真的解码一次（3MB 的图解码要几毫秒，
    // 而这里只是为了一次限额判断）。
    const bytes = decodeLengthOf(base64);
    totalBytes += bytes;
    if (totalBytes > config.maxImageBytes) {
      // 单独回 413：客户端能自己修（少传几张、降分辨率），
      // 混进「模型故障」会被降级到本地模板，根因就被埋了。
      throw payloadTooLarge(
        `照片总体积超出上限 ${Math.round(config.maxImageBytes / 1024 / 1024)}MB`,
        { limit: config.maxImageBytes, received: totalBytes },
      );
    }

    parts.push({
      type: 'image_url',
      image_url: { url: `data:${mimeType};base64,${base64}`, detail: 'high' },
    });
  });

  return { parts, imageCount: parts.length, totalBytes, skipped: 0 };
}

/**
 * 对象存储 URL 的安全校验。
 *
 * 只允许 https：http 会被中间设备替换内容，而这是一份要交给模型判卷的作业照片。
 * 同时拒绝指向内网的地址 —— 云端模型会去取这个 URL，
 * 放通内网等于把网关当作探测内网的服务跳板。
 */
function assertSafeUrl(url, at) {
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    throw badRequest(`${at}.url 不是合法 URL`);
  }
  if (parsed.protocol !== 'https:') {
    throw badRequest(`${at}.url 必须是 https`);
  }
  if (isPrivateHost(parsed.hostname)) {
    throw badRequest(`${at}.url 指向内网地址，已拒绝`);
  }
  return url;
}

function isPrivateHost(hostname) {
  const host = hostname.toLowerCase();
  if (host === 'localhost' || host.endsWith('.local') || host.endsWith('.internal')) {
    return true;
  }
  const ipv4 = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (ipv4) {
    const [a, b] = ipv4.slice(1).map(Number);
    if (a === 10 || a === 127 || a === 0) return true;
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
    if (a === 169 && b === 254) return true;
  }
  return false;
}

/** base64 字符串解码后的字节数。 */
function decodeLengthOf(base64) {
  const padding = base64.endsWith('==') ? 2 : base64.endsWith('=') ? 1 : 0;
  return Math.floor((base64.length * 3) / 4) - padding;
}
