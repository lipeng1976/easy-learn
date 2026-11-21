import { createHash } from 'node:crypto';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { binaryResponse } from '../http.js';

/**
 * 作业照片「按请求宽度现场缩图」。
 *
 * ## 为什么需要它
 *
 * 手机拍的作业照片原图普遍 600KB–1MB。走 `IMAGE_DRIVER=fs` 的本机部署里，
 * 这些字节走 `GET /data/homework/images/file` 直发。在 VPN（如 Tailscale，
 * 虚拟网卡 MTU 仅 1280）这类链路上，**大响应最容易被 MTU 黑洞卡死**——
 * 小数据包（JSON、几百字节的控制请求）都正常，唯独几百 KB 的图拉不出来。
 *
 * 把图缩到合理宽度（手机屏 1280px 足够看清作业），字节量直接砍到两三成，
 * 单包都远小于路径 MTU，被卡的概率大幅下降。这是**根治**，不是重试兜底。
 *
 * ## 设计红线
 *
 * - **缩图失败绝不能影响原图**：sharp 没装、解码失败、磁盘缓存写不进，
 *   一律 `return null`，调用方继续走原图。`import('sharp')` 用动态导入 +
 *    try/catch，装不上也不让整条路由崩。
 * - **向后兼容**：客户端不传 `w` → 返回 `null` → 原图照旧；传了非法值 → 忽略。
 * - **磁盘缓存**：同一张图同一宽度只缩一次，避免网格缩略图 + 全屏 + 重试
 *   反复触发 sharp。缓存键含 `storageKey#w#q`，与「文件会不会被意外当成图」
 *   完全隔离（`.imgcache` 目录，store 的 `resolveInside` 不会认它）。
 */

const IMAGE_ROOT = process.env.IMAGE_ROOT_DIR || '';
const CACHE_DIR = IMAGE_ROOT ? path.join(IMAGE_ROOT, '.imgcache') : '';

function clampInt(v, min, max, fallback) {
  const n = parseInt(v, 10);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

/**
 * 返回缩好的二进制响应；不应缩 / 缩不动时返回 `null`（调用方回退原图）。
 *
 * @param {string} storageKey 用于缓存命名，不参与路径拼接（避免穿越）。
 * @param {string} mimeType   仅 image/jpeg、image/png 参与缩图。
 * @param {Buffer} original   原图字节。
 * @param {object} query      含可选 `w`（目标宽度）、`q`（质量 40–95）。
 */
export async function maybeResizeResponse(storageKey, mimeType, original, query) {
  const w = clampInt(query?.w, 200, 2400, 0);
  const q = clampInt(query?.q, 40, 95, 78);
  if (w <= 0 || !Buffer.isBuffer(original) || original.length === 0) return null;

  const lower = String(mimeType || '').toLowerCase();
  if (lower !== 'image/jpeg' && lower !== 'image/png') return null;

  let sharp;
  try {
    sharp = (await import('sharp')).default;
  } catch {
    return null;
  }

  const cacheFile = CACHE_DIR
    ? path.join(CACHE_DIR, `${createHash('sha1').update(`${storageKey}#${w}#${q}`).digest('hex')}.jpg`)
    : '';

  // 命中缓存直接回，省一次 CPU。
  if (cacheFile) {
    try {
      const cached = await readFile(cacheFile);
      if (cached && cached.length) {
        return binaryResponse(lower === 'image/png' ? 'image/png' : 'image/jpeg', cached);
      }
    } catch {
      // 缓存未命中，往下重新生成。
    }
  }

  try {
    const pipeline = sharp(original, { failOn: 'none', limitInputPixels: false }).resize({
      width: w,
      withoutEnlargement: true,
    });
    const out = lower === 'image/png'
      ? await pipeline.png({ quality: q, compressionLevel: 9, effort: 7 }).toBuffer()
      : await pipeline.jpeg({ quality: q, mozjpeg: true }).toBuffer();
    if (!out || !out.length) return null;

    if (cacheFile) {
      try {
        await mkdir(CACHE_DIR, { recursive: true });
        await writeFile(cacheFile, out);
      } catch {
        // 缓存写失败不致命，照常返回缩好的字节。
      }
    }
    return binaryResponse(lower === 'image/png' ? 'image/png' : 'image/jpeg', out);
  } catch {
    return null;
  }
}
