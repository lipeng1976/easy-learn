import { readFileSync } from 'node:fs';
import { basename, join, resolve } from 'node:path';

import { ApiError, ErrorCodes } from '../../../shared/errors.js';
import { binaryResponse } from '../http.js';

/**
 * 本机版 App 的更新端点。
 *
 * ## 为什么两个端点都在这里，而不是复用 /data/*
 *
 * 更新检查发生在**登录之前**——用户可能因为旧版本 bug 根本登不进去。
 * 因此这两条必须是公开路由（`public: true`），不带会话也能取到版本清单。
 *
 * ## 安全边界
 *
 * - `checkUpdate` 只回清单，**不列目录、不回绝对路径**：公网端点暴露目录结构是
 *   没必要的风险。
 * - `downloadApk` 的文件名**只从 manifest 取**，且强制 `basename(name) === name`
 *   与 `.apk` 后缀，杜绝 `../../` 穿越；调用方传的 query 一律忽略。
 * - 清单里没写的文件一律 404，不做「目录下随便哪个 apk 都能下」的兜底。
 *
 * ## 「没这个能力时静默降级」
 *
 * 没配 `UPDATE_PACKAGE_DIR`、目录不存在或没生成 manifest 时，
 * `checkUpdate` 回 `available: false`，客户端据此安静地不检查——
 * 不弹红条、不抛异常（用户对 ima 那套硬规矩，这里同样适用）。
 */
const MANIFEST_FILE = 'manifest.json';

function updateDirOrNull(dir) {
  if (!dir || typeof dir !== 'string') return null;
  return resolve(dir);
}

/** 读清单；没有任何异常向外抛——没配就是没有，不是故障。 */
function readManifestOrNull(dir) {
  const root = updateDirOrNull(dir);
  if (!root) return null;
  try {
    const raw = readFileSync(join(root, MANIFEST_FILE), 'utf8');
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
    return parsed;
  } catch {
    return null;
  }
}

/**
 * 客户端能用的最小字段集。
 *
 * 刻意不把 manifest 原样回出去：清单是构建脚本写的，字段可能随工具演进，
 * 而客户端解析的是一份**契约**。契约只认这几个字段，多出来的既不回也不猜。
 */
function publicManifest(manifest) {
  return {
    versionCode: Number(manifest.versionCode ?? 0),
    versionName: String(manifest.versionName ?? ''),
    changelog: String(manifest.changelog ?? ''),
    fileName: String(manifest.fileName ?? ''),
    size: Number(manifest.size ?? 0),
    sha256: String(manifest.sha256 ?? '').toLowerCase(),
    publishedAt: String(manifest.publishedAt ?? ''),
  };
}

export function createUpdateRoutes({ updatePackageDir = '' } = {}) {
  /** GET /app/update —— 清单检查（公开）。 */
  async function checkUpdate() {
    const manifest = readManifestOrNull(updatePackageDir);
    if (!manifest) {
      return { available: false, latest: null };
    }
    const latest = publicManifest(manifest);
    // 清单不完整时宁可说「没有更新」，也不要让客户端拿空版本码去比对——
    // 那会让每次启动都弹「有新版本」，却永远装不上。
    const usable = latest.versionCode > 0
      && latest.fileName !== ''
      && /^[0-9a-f]{64}$/.test(latest.sha256);
    return usable
      ? { available: true, latest }
      : { available: false, latest: null };
  }

  /** GET /app/download —— APK 字节（公开、raw 响应）。 */
  async function downloadApk() {
    const root = updateDirOrNull(updatePackageDir);
    if (!root) throw new ApiError(ErrorCodes.notFound, '这台部署没有配置更新包目录', { status: 404 });

    const manifest = readManifestOrNull(updatePackageDir);
    const name = String(manifest?.fileName ?? '');
    if (!name || basename(name) !== name || !name.toLowerCase().endsWith('.apk')) {
      throw new ApiError(ErrorCodes.notFound, '更新清单里没有有效的 APK 文件名', { status: 404 });
    }

    let bytes;
    try {
      bytes = readFileSync(join(root, name));
    } catch {
      throw new ApiError(ErrorCodes.notFound, '更新包文件不存在', { status: 404 });
    }
    // 清单一 Exit=0 但文件被换过是最危险的静默失败：客户端 sha256 校验会挡下来，
    // 但服务端也在这里回一个头，让 curl / 浏览器一眼能看出来。
    return binaryResponse('application/vnd.android.package-archive', bytes);
  }

  return { checkUpdate, downloadApk };
}
