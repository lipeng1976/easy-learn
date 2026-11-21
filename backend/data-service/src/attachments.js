import { badRequest, payloadTooLarge } from '../../shared/errors.js';

/**
 * 作业附件的**类型、MIME 白名单与大小上限** —— 服务端的唯一定义处。
 *
 * ## 为什么不能只在 `imagestore.js` 里加几个 MIME
 *
 * 附件的类型要同时被三处用到：字节落盘（`imagestore.js` / `ossimagestore.js`）、
 * 上传前的大小预检（路由）、以及允许数量的校验。这三处原先各写各的
 * 白名单 —— 加一种类型要改三个地方，漏掉的那处**不会报错**，
 * 只表现为「某一类附件在某个后端上存不下来」。
 *
 * ## ⚠️ 与客户端是两份，必须逐字对齐
 *
 * 客户端那份在 `lib/constants/attachment_limits.dart`。Dart 与 JS 无法共享
 * 常量，所以 `WIRE` / `MIME_EXT` / `MAX_BYTES` 三张表两边各有一份，
 * **改一份就要改另一份**。这是本项目 `vocab.js` ↔ Dart 枚举那条规则的延伸
 * （「一个语义只许一个词、词只许一处定义」在跨语言时降级为「两处、且必须逐字相同」）。
 *
 * ## 与「AI 批改」的边界
 *
 * 这里放行音频与视频，**不代表模型能看它们**。批改只吃图片 ——
 * 网关 `media.js` 的白名单**仍然只有 image/\***，这是刻意的：
 * 让类型在这里宽、在模型那一侧窄，边界就只有一个地方要守（收集附件时按
 * `kindOfMime` 过滤成图片）。
 */

/** 落库的 kind 值。与客户端 `AttachmentKind.wire` 逐字相同。 */
export const ATTACHMENT_KINDS = ['image', 'audio', 'video'];

/**
 * MIME → 落盘扩展名。
 *
 * ⚠️ 与客户端 `AttachmentLimits.mimeExt` **逐字相同**。
 * 客户端按 MIME 上传、服务端按 MIME 查扩展名，两边不一致的后果是
 * 「选得中、传得上去、存不下来」。
 */
export const MIME_EXT = new Map([
  // —— 图片 ——
  ['image/jpeg', '.jpg'],
  ['image/jpg', '.jpg'],
  ['image/png', '.png'],
  ['image/webp', '.webp'],
  ['image/heic', '.heic'],
  ['image/heif', '.heic'],
  // —— 音频 ——
  ['audio/mpeg', '.mp3'],
  ['audio/mp4', '.m4a'],
  ['audio/aac', '.aac'],
  ['audio/wav', '.wav'],
  ['audio/x-wav', '.wav'],
  ['audio/ogg', '.ogg'],
  ['audio/webm', '.weba'],
  ['audio/amr', '.amr'],
  // —— 视频 ——
  ['video/mp4', '.mp4'],
  ['video/quicktime', '.mov'],
  ['video/webm', '.webm'],
  ['video/3gpp', '.3gp'],
]);

/**
 * 每个类型**单文件**的默认字节上限。
 *
 * ⚠️ 这是**默认值**，实际生效的是环境变量（见 `image-store-factory.js`）。
 * 默认值放在这里而不是工厂里：客户端那份表要对齐的也是这一组数。
 */
export const DEFAULT_MAX_BYTES = new Map([
  ['image', 8 * 1024 * 1024],
  ['audio', 20 * 1024 * 1024],
  // 2026-10-06 由 50MB 放宽到 100MB：50MB 配 5 分钟直传超时要求有效上行
  // ≥170KB/s，家用 Wi-Fi 晚间常达不到（实测「提交视频失败」）。必须与
  // 客户端 `attachment_limits.dart` 逐字对齐 —— 那边放宽时同轮把直传
  // 超时提到了 12 分钟（OSS 签名窗口 15 分钟，见 ossimagestore.js）。
  ['video', 100 * 1024 * 1024],
]);

/**
 * 每个类型**一次提交**的数量上限。
 *
 * 服务端用它做防呆（客户端已经拦过一道）：客户端被绕过时，
 * 没有这道校验的表现是「有人塞进 500 个附件，配额瞬间见底」。
 */
export const MAX_COUNT = new Map([
  ['image', 9],
  ['audio', 3],
  ['video', 1],
]);

/** 全部支持的 MIME（给错误信息用，别在别处再抄一份）。 */
export const SUPPORTED_MIME_TYPES = [...MIME_EXT.keys()];

/**
 * 按 MIME 前缀归类。**认不出返回 `null`，不兜底成 image** ——
 * 兜底会把一段音频按图片送进视觉模型，而模型对不认识的内容是**静默丢弃**的，
 * 表现为「这个附件在批改结果里凭空消失」（见 `doc/open-items.md` B29）。
 *
 * @param {string} mimeType
 * @returns {string|null} `'image' | 'audio' | 'video'` 或 null
 */
export function kindOfMime(mimeType) {
  const mime = String(mimeType ?? '').toLowerCase().trim();
  if (mime === '') return null;
  const slash = mime.indexOf('/');
  if (slash <= 0) return null;
  const kind = mime.slice(0, slash);
  return ATTACHMENT_KINDS.includes(kind) ? kind : null;
}

/**
 * 把 MIME 映射成落盘扩展名。认不出返回空串，**不编一个 `.bin` 出来**。
 * @param {string} mimeType
 */
export function extensionFor(mimeType) {
  return MIME_EXT.get(String(mimeType ?? '').toLowerCase()) ?? '';
}

/**
 * 上传内容的校验 —— **文件系统实现与对象存储实现共用这一段**。
 *
 * 两种后端的落点完全不同，但「什么算合法上传」必须是**同一个答案**：
 * 空内容、MIME 白名单、按类型分别的大小上限。分成两份写，两份就会漂，
 * 而漂的那一刻不会报错 —— 只是某一边悄悄放宽了限制。
 *
 * @param {object} args
 * @param {Buffer|Uint8Array} args.bytes
 * @param {string} args.mimeType
 * @param {Map<string, number>|Record<string, number>} [args.maxBytesByKind]
 *        每个类型的字节上限；缺省用 [DEFAULT_MAX_BYTES]
 * @returns {{ kind: string, mime: string, ext: string, maxBytes: number }}
 */
export function validateUpload({ bytes, mimeType, maxBytesByKind }) {
  if (!bytes || bytes.length === 0) throw badRequest('上传内容为空');

  const mime = String(mimeType ?? '').toLowerCase();
  const kind = kindOfMime(mime);
  const ext = extensionFor(mime);

  if (kind === null || ext === '') {
    throw badRequest(
      `不支持的附件类型：${mime || '(空)'}，仅支持 ${SUPPORTED_MIME_TYPES.join(' / ')}`,
    );
  }

  const maxBytes = readLimit(maxBytesByKind, kind, DEFAULT_MAX_BYTES.get(kind));
  if (bytes.length > maxBytes) {
    // 报错要带上**这个类型**的名字与上限：只说「文件过大」的话，
    // 用户不知道能传多大，也不知道是哪个文件的问题。
    throw payloadTooLarge(
      `单个${labelOfKind(kind)}不得超过 ${Math.round(maxBytes / 1024 / 1024)}MB`
        + `（本次 ${fmtMb(bytes.length)}）`,
      { kind, limit: maxBytes, received: bytes.length },
    );
  }

  return { kind, mime, ext, maxBytes };
}

function readLimit(source, kind, fallback) {
  if (source === undefined || source === null) return fallback;
  const value = typeof source.get === 'function' ? source.get(kind) : source[kind];
  return Number.isFinite(value) && value > 0 ? Number(value) : fallback;
}

/**
 * 取某个类型的字节上限（缺省回落到 [DEFAULT_MAX_BYTES]）。
 *
 * 给「签发直传位置」那条路用：那里没有字节可校验，但要把上限**回显给客户端**，
 * 让它在开始传之前就能拦住超大文件 —— 传了一半才失败，用户白等一场。
 *
 * @param {Map<string, number>|Record<string, number>|undefined} maxBytesByKind
 * @param {string} kind
 * @returns {number}
 */
export function maxBytesFor(maxBytesByKind, kind) {
  return readLimit(maxBytesByKind, kind, DEFAULT_MAX_BYTES.get(kind));
}

/** 类型的中文名。错误信息里要用，别在路由里另写一份。 */
export function labelOfKind(kind) {
  switch (kind) {
    case 'image':
      return '照片';
    case 'audio':
      return '音频';
    case 'video':
      return '视频';
    default:
      return '附件';
  }
}

/** 把字节数说成人话，用于错误信息。 */
export function humanSize(bytes) {
  if (bytes >= 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)}MB`;
  if (bytes >= 1024) return `${Math.round(bytes / 1024)}KB`;
  return `${bytes}B`;
}

function fmtMb(bytes) {
  return humanSize(bytes);
}
