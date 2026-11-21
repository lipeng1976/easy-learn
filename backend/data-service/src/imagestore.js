import { randomUUID } from 'node:crypto';
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';

import { ApiError, ErrorCodes, badRequest, notFound } from '../../shared/errors.js';
import { validateUpload } from './attachments.js';

/**
 * 作业照片的**字节存储**（文件系统实现）。
 *
 * ## 为什么需要它
 *
 * 在这之前，`homework_image.storage_key` 存的是**设备本地标识** ——
 * 原生端是绝对文件路径（写文稿目录），Web 端是浏览器存储的键。
 * 这两个值在**别的设备上必然读不到**，而读取失败是**静默返回 null** 的：
 * 家长看到的就是照片位置一片空白、没有任何报错。
 *
 * 换掉存储位置还不够，必须同时换掉**键的语义**：键从「某台设备上的位置」
 * 变成「相对本存储根目录的路径」。前者只对一台设备成立，后者对任何
 * 能访问这个根目录的进程都成立 —— 这才是家长端能读到图的原因。
 *
 * ## ⚠️ 文件系统只在「有本地磁盘的部署」上成立
 *
 * 本机开发、自建服务器、容器 + 挂载卷都可以。**Serverless 上没有持久磁盘**，
 * 函数实例回收后文件就没了（而且多实例之间不共享）。真上线要么挂 NAS/云盘，
 * 要么换对象存储 —— 所以本模块刻意做成**可替换的一层**，
 * 而不是把 `fs` 调用散进业务路由里。
 *
 * ## 键的格式（唯一权威在这里）
 *
 * ```
 * <YYYYMMDD>/<studentId>/<uuid><ext>      例：20260920/36e392cd-.../f3a1c2.jpg
 * ```
 *
 * - **日期分目录**：按天归档，便于运维按时间清理与排查。
 *   ⚠️ 这个日期**只用于归档，不参与任何业务判断** —— 所以服务端时区
 *   （本机是 GMT+8、Serverless 通常是 UTC）带来的差异是无害的。
 *   谁也别拿目录名去算「这是哪天的作业」，作业时间在 `homework` 表里。
 * - **按学生分目录**：便于按人清理，也避免不同学生撞键。
 * - **uuid 而不是递增序号**：并发不撞键，且不可被猜路径
 *   （递增序号等于把「猜别人作业照片」变成一件顺序尝试就能成功的事）。
 */

/**
 * 允许的类型、MIME → 扩展名、以及按类型分别的大小上限，**全部来自
 * `attachments.js`** —— 不要在这里再写一份白名单。
 *
 * ## 这里原来有什么
 *
 * 一张只含 6 个图片 MIME 的本地表，以及一份本地的 `validateUpload`。
 * 加音频/视频时如果继续在本地扩这张表，「哪些类型算合法」就会同时存在两份
 * （这一份 + 对象存储那一份），而**漂的那一刻不报错** ——
 * 只表现为「某一类附件在某个后端上存不下来」。现在只有一处。
 */

/** 服务端键的形状。**客户端只需要认 `^\d{8}/` 这个前缀**（见 Dart 侧 `image_key.dart`）。 */
const SERVER_KEY_PATTERN = /^\d{8}\/[A-Za-z0-9_-]+\/[A-Za-z0-9._-]+$/;

/**
 * 判断一个 storageKey 是不是**本存储能读的**服务端键。
 *
 * 专门用来把「旧的设备本地标识」挑出来：`memory://...`（Web 端浏览器存储键）、
 * `/data/user/...` 或 `C:\...`（原生端绝对路径）。这些不是错误数据 ——
 * 它们是那次改动之前写进去的，字节只存在于当时那台设备上，
 * **服务端永远拿不到**。所以读图路由遇到它们要如实回
 * 「这张图不在服务端」，让客户端回退到本地读取，而不是报一个笼统的 404。
 */
export function isServerImageKey(key) {
  if (key === undefined || key === null) return false;
  const k = String(key);
  if (k === '' || k.includes('\0')) return false;
  if (!SERVER_KEY_PATTERN.test(k)) return false;
  // 上面那条正则的字符类里含 `.`，所以 `20260920/abc/..` **也能通过它**。
  // 这个键危险得不明显：`resolveInside` 会把它解析成「根目录之内的
  // `20260920`」（而不是根目录之外），于是三道防线都放它进去，
  // 最后炸在读一个目录上（EISDIR → 500 internal）—— 一个和权限、
  // 和穿越都毫无关系的报错，查半天查不到这里。
  // 所以段级再收一次口：任何一段是 `.` 或 `..`，直接不算服务端键。
  return !k.split('/').some((seg) => seg === '.' || seg === '..');
}

/** 归档目录名 `YYYYMMDD`（服务端本地时区，见文件头说明）。 */
function archiveDirOf(epochMs) {
  const d = new Date(epochMs);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}${m}${day}`;
}

/**
 * 目录段的安全化。
 *
 * `studentId` 来自会话上下文（不是请求体），理论上已经是 uuid；
 * 但**「理论上」不能当作路径安全的前提** —— 一个含 `..` 或 `/` 的 studentId
 * 能让写入落到根目录之外，而那种错误在正常数据下永远不出现。
 * 所以这里按白名单过滤，而不是 trust。
 */
function safeSegment(value) {
  const s = String(value ?? '').replace(/[^A-Za-z0-9_-]/g, '');
  return s === '' ? 'unknown' : s;
}

/**
 * 造一个存储键 —— **键格式的唯一权威就是这里**（文件头那段说明）。
 *
 * 文件系统实现与对象存储实现都调它。两边的「存到哪」完全不同，
 * 但「键长什么样」必须逐字相同：`storage_key` 是**写进数据库的值**，
 * 一旦两种后端产出的键形状不同，切换后端就等于让老照片全部失联 ——
 * 而失联的表现是「照片位置一片空白」，没有一处会报错。
 *
 * 键一律用 `/` 分隔：它是**跨端的协议值**，不能跟着服务端操作系统漂
 * （Windows 上用 `path.join` 会得到 `\`，写进库后客户端与 Linux 部署都读不懂）。
 * 对象存储更是只认 `/`。
 */
export function buildStorageKey({ studentId, ext, epochMs }) {
  return `${archiveDirOf(epochMs)}/${safeSegment(studentId)}/${randomUUID()}${ext}`;
}

/**
 * @param {object} options
 * @param {string} options.rootDir 存储根目录的**绝对路径**。空串 = 未配置
 * @param {Map<string, number>|Record<string, number>} [options.maxBytesByKind]
 *        **按附件类型分别**的字节上限（`{ image, audio, video }`）。
 *        ⚠️ 从「一个 maxBytes 管所有类型」改成按类型分开，是因为一个数字
 *        同时管 8MB 的照片和 100MB 的视频只能是两者之一 —— 取大的照片不受保护，
 *        取小的视频传不上来。缺省值见 `attachments.js`。
 * @param {() => number} [options.now] 便于测试注入时间
 */
export function createImageStore({ rootDir, maxBytesByKind, now = () => Date.now() }) {
  const root = String(rootDir ?? '').trim();
  const ready = root !== '';
  const resolvedRoot = ready ? path.resolve(root) : '';

  /**
   * 启动自检：**宁可起不来，也不要在第一次上传时才炸**。
   *
   * 目录不存在就建（这是正常的首次运行）；建不出来、或者建出来却写不进去
   * （只读挂载、权限不对、盘满了），那就是一次部署配置错误 ——
   * 让它在启动时以一句话暴露，而不是在学生拍完照点提交的那一刻。
   */
  async function assertReady() {
    if (!ready) {
      return { ok: false, reason: 'IMAGE_ROOT_DIR 未配置（图片存储未启用）' };
    }
    try {
      await mkdir(resolvedRoot, { recursive: true });
      const probe = path.join(resolvedRoot, `.probe-${process.pid}`);
      await writeFile(probe, 'ok');
      await rm(probe, { force: true });
      return { ok: true, root: resolvedRoot };
    } catch (e) {
      return { ok: false, reason: `存储根目录不可用：${resolvedRoot}（${e.message}）` };
    }
  }

  function assertConfigured() {
    if (!ready) {
      // 复用 upload_not_configured 的语义：这是**配置问题**，
      // 运维看到就知道该去补哪个环境变量，而不用翻代码。
      throw new Error('IMAGE_ROOT_DIR 未配置');
    }
  }

  /** 相对键 → 绝对路径。越界一律当作不存在，不回显真实路径。 */
  function resolveInside(storageKey) {
    const target = path.resolve(resolvedRoot, storageKey);
    // `startsWith(root + sep)` 而不是 `startsWith(root)`：
    // 否则 `/srv/images-evil` 会被判成在 `/srv/images` 之内。
    if (target !== resolvedRoot && !target.startsWith(resolvedRoot + path.sep)) {
      return null;
    }
    return target;
  }

  return {
    ready,
    root: resolvedRoot,
    maxBytesByKind,
    assertReady,

    /**
     * 落盘一批字节，返回**相对键**（这是要写进 `homework_image.storage_key` 的值）。
     *
     * 写入是原子的：先写 `.tmp` 再 `rename`。理由是家长端可能**恰好**在
     * 写入过程中来读 —— 直接写目标文件的话，读到的会是一张**半截的图**，
     * 而且它在浏览器里表现为「图裂」，没有任何一处会报错。
     * 同一目录内的 rename 在 POSIX 与 Windows 上都是原子的。
     */
    async put({ studentId, bytes, mimeType }) {
      assertConfigured();
      // 空内容 / 超限 / MIME 白名单：与对象存储后端共用同一段判断，
      // 且上限**按类型分别取**（照片 8MB、音频 20MB、视频 100MB 不是同一个数）。
      const { kind, mime, ext } = validateUpload({ bytes, mimeType, maxBytesByKind });

      const storageKey = buildStorageKey({ studentId, ext, epochMs: now() });
      const absPath = resolveInside(storageKey);
      if (absPath === null) throw badRequest('非法的存储键');

      await mkdir(path.dirname(absPath), { recursive: true });
      const tmpPath = `${absPath}.tmp`;
      await writeFile(tmpPath, bytes);
      await rename(tmpPath, absPath);
      // `.tmp` 是给**运维**看的：盘上出现它说明有过一次中断的写入。
      // 不主动清理 —— 主动清理的代价是「万一 rename 还没完成就把它删了」。

      return { storageKey, byteSize: bytes.length, mimeType: mime, kind };
    },

    /**
     * 按相对键读回字节。
     *
     * `key` 必须先过 `isServerImageKey` —— 这样调用方就**不需要**把
     * 「旧的设备本地标识」当成一次 IO 失败来处理，而可以在更上层
     * 决定「回退本地读取」还是「如实报不存在」。
     */
    async get(storageKey) {
      assertConfigured();
      if (!isServerImageKey(storageKey)) {
        // ⚠️ 这里用 `ApiError` 而不是便利函数 `notFound(message)`：后者不接受 details，
        // 而 `details.reason` 正是**客户端区分两种 404 的唯一依据** ——
        // 「旧版设备本地标识」应当**回退到本地读取**（那台设备上还有），
        // 「文件真的没了」只能如实报不可用。两者症状完全相同（照片位置一片空白），
        // 处置却相反 —— 所以不能只回一个裸 404。
        throw new ApiError(
          ErrorCodes.notFound,
          '该照片的字节不在服务端（这是旧版设备本地标识，字节只在当初那台设备上）',
          { status: 404, details: { reason: 'not_on_server', storageKey } },
        );
      }
      const absPath = resolveInside(storageKey);
      if (absPath === null) throw notFound('照片不存在');
      try {
        return await readFile(absPath);
      } catch (e) {
        if (e.code === 'ENOENT') {
          // 与上面刻意用**不同的 reason**：走到这里说明键是服务端格式、
          // 路径也合法，只是文件不在了（被清理、或换了存储根目录）。
          // 这是**运维问题**，不是「请去本地找」。
          throw new ApiError(
            ErrorCodes.notFound,
            '照片文件不存在（可能已被清理，或存储根目录换过）',
            { status: 404, details: { reason: 'file_missing', storageKey } },
          );
        }
        throw e;
      }
    },
  };
}
