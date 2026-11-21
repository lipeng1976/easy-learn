/**
 * 探针用的那张小图。**单一定义** —— 两个模型探针脚本共用这一份。
 *
 * ## 为什么要有这个文件（而不是每个脚本各写一个 base64 常量）
 *
 * 曾经 `probe-ark.mjs` 里内联的是一张 **1×1 的 PNG**。它在方舟上没出过问题
 * （视觉档当时压根没开通，所以那条路**从来没被跑过**）。
 * 2026-09-24 换成百炼之后，同一张图立刻暴露出问题：
 *
 * ```
 * <400> InternalError.Algo.InvalidParameter:
 *   The image length and width do not meet the model restrictions.
 *   [height:1 or width:1 must be larger than 10]
 * ```
 *
 * 也就是说：**这个错误看起来像「模型不可用 / 密钥不对」，实际是探针自己的测试数据不合格。**
 * 排查方向会被带偏到模型 ID 和鉴权上，而真相是那张图太小。
 * 而且它只在「换了一家厂商」时才出现 —— 两家对最小尺寸的要求不一样，
 * 而探针图是写死的。
 *
 * 所以这里改成**生成一张 96×96 的真图**，并把「最小尺寸」这件事的判据固定下来：
 * 边长必须明显大于任何厂商的下限（实测百炼要求 > 10px，取 96 留足余量）。
 *
 * ## 为什么手搓 PNG 而不是引一个图像库
 *
 * 网关本身**零依赖**（`package.json` 里只有 pg 之外的开发依赖），
 * 探测脚本不该为了「造一张 96×96 的图」拖进一棵依赖树。
 * PNG 的最小结构（签名 + IHDR + IDAT + IEND）用 `node:zlib` 就能拼出来，
 * 几十行、无外部依赖、结果确定。
 *
 * ## 图里画的是什么
 *
 * 白底 + 一个黑色矩形框 + 一条横线 —— 像作业本上的一格。
 * 这样它至少是一个「有内容可看」的图：视觉模型的探活才有意义
 * （1×1 的纯色图即使被接受，也只能证明「传参没报错」，证明不了它会看图）。
 */

import { deflateSync } from 'node:zlib';

/** 与网关内联图片用的 MIME 一致（见 `media.js` 里的 `data:<mime>;base64,`）。 */
export const PROBE_IMAGE_MIME = 'image/png';

/**
 * 边长。**必须明显大于各厂商的下限** —— 百炼实测要求长宽都 > 10px。
 * 96 是一个「够大、又只有几 KB」的值。
 */
export const PROBE_IMAGE_SIZE = 96;

function crc32(buf) {
  const table = [];
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  let crc = 0xffffffff;
  for (let i = 0; i < buf.length; i += 1) crc = table[(crc ^ buf[i]) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([len, body, crc]);
}

/**
 * 造一张 `size × size` 的真 PNG（真彩色、无 alpha、filter=None）。
 *
 * @param {number} [size] 边长，默认 `PROBE_IMAGE_SIZE`
 * @returns {Buffer}
 */
export function makeProbePng(size = PROBE_IMAGE_SIZE) {
  const rows = [];
  for (let y = 0; y < size; y += 1) {
    // 每行前置一个 filter byte（0 = None）—— PNG 的扫描线格式要求，不是填充。
    const row = Buffer.alloc(1 + size * 3);
    for (let x = 0; x < size; x += 1) {
      const box = x >= size * 0.2 && x < size * 0.8 && y >= size * 0.2 && y < size * 0.45;
      const line = y === Math.round(size * 0.65) && x >= size * 0.2 && x < size * 0.8;
      const v = box || line ? 0 : 255;
      row[1 + x * 3] = v;
      row[1 + x * 3 + 1] = v;
      row[1 + x * 3 + 2] = v;
    }
    rows.push(row);
  }

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // color type: truecolor
  ihdr[10] = 0; // compression
  ihdr[11] = 0; // filter
  ihdr[12] = 0; // interlace

  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(Buffer.concat(rows))),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

/** base64 形态的探针图（懒算一次，多个脚本复用）。 */
let cachedBase64 = '';

/** @returns {string} 探针图的 base64（不含 `data:` 前缀） */
export function probeImageBase64() {
  if (cachedBase64 === '') cachedBase64 = makeProbePng().toString('base64');
  return cachedBase64;
}

/**
 * 直接可塞进 `image_url.url` 的 data URI。
 *
 * 走内联而不是给一个 URL：网关默认就是内联模式，而
 * `data:<mime>;base64,...` 这条正是要验的路 —— 给 URL 就把它绕过去了。
 */
export function probeImageDataUri() {
  return `data:${PROBE_IMAGE_MIME};base64,${probeImageBase64()}`;
}
