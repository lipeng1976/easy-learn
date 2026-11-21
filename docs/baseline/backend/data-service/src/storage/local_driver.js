/**
 * 本地文件系统驱动 —— ★ 全后端**唯一**把相对路径拼成绝对路径的地方。
 *
 * 库里只存 relative_path；根目录由 STORAGE_ROOT 配置，经 resolveStoragePath()
 * 解析并二次校验仍在根内。其它模块一律只持有相对路径字符串。
 *
 * IMAGE_DRIVER 不是 local 时直接抛错，**绝不静默退回本地**。
 */

import fs from 'node:fs/promises';
import path from 'node:path';
import { resolveStoragePath } from '../../../shared/paths.js';
import { AppError, ERROR_CODES } from '../../../shared/errors.js';

export function assertLocalDriver(config) {
  if (config.imageDriver !== 'local') {
    throw new AppError(
      ERROR_CODES.STORAGE_ERROR,
      `当前 IMAGE_DRIVER=${config.imageDriver}，本地驱动不可用（不静默回退）`
    );
  }
}

export async function writeBytes(relativePath, bytes) {
  const absolute = resolveStoragePath(relativePath);
  await fs.mkdir(path.dirname(absolute), { recursive: true });
  try {
    // 'wx'：已存在即失败。存储键含 uuid，正常路径下不会撞；撞了说明有重放。
    await fs.writeFile(absolute, bytes, { flag: 'wx' });
  } catch (err) {
    if (err?.code === 'EEXIST') {
      throw new AppError(ERROR_CODES.CONFLICT, '存储键已存在', { cause: err });
    }
    throw new AppError(ERROR_CODES.STORAGE_ERROR, `写入附件失败：${err.message}`, { cause: err });
  }
  return { size: bytes.length };
}

export async function readBytes(relativePath) {
  const absolute = resolveStoragePath(relativePath);
  try {
    return await fs.readFile(absolute);
  } catch (err) {
    if (err?.code === 'ENOENT') {
      throw new AppError(ERROR_CODES.NOT_FOUND, '附件字节不存在（库里有行、盘上没文件）', { cause: err });
    }
    throw new AppError(ERROR_CODES.STORAGE_ERROR, `读取附件失败：${err.message}`, { cause: err });
  }
}

export async function deleteBytes(relativePath) {
  const absolute = resolveStoragePath(relativePath);
  try {
    await fs.unlink(absolute);
  } catch (err) {
    if (err?.code === 'ENOENT') return false;
    throw new AppError(ERROR_CODES.STORAGE_ERROR, `删除附件失败：${err.message}`, { cause: err });
  }
  return true;
}
