/**
 * ★ 相对路径规则 —— 全后端**唯一**实现。
 *
 * 与数据库侧的 `CREATE DOMAIN rel_path`（db/001_schema.sql）逐条对应：
 *   · 允许空串（历史行 / 未上传完）
 *   · 不许以 / 或 \ 开头、不许盘符、不许反斜杠、不许含 ..、不许以 / 结尾
 *
 * 根目录只在 config.js 的 STORAGE_ROOT 配置。数据库里**永远**只存相对路径。
 * 唯一把相对路径拼成绝对路径的地方是 data-service/src/storage/local_driver.js。
 */

import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { getConfig } from './config.js';

export const ERR_INVALID_PATH = 'ERR_INVALID_PATH';

export class PathError extends Error {
  constructor(message, code = ERR_INVALID_PATH) {
    super(message);
    this.name = 'PathError';
    this.code = code;
  }
}

/**
 * 校验相对路径。合法则原样返回，不合法抛 PathError。
 * 不做「自动修正」——静默修正会让错误数据在库里活下来。
 */
export function assertRelative(value) {
  if (typeof value !== 'string') {
    throw new PathError(`相对路径必须是字符串，收到 ${typeof value}`);
  }
  const v = value.trim();
  if (v === '') return '';
  if (v.startsWith('/') || v.startsWith('\\')) {
    throw new PathError(`不允许绝对路径：${v}`);
  }
  if (/^[A-Za-z]:/.test(v)) {
    throw new PathError(`不允许盘符路径：${v}`);
  }
  if (v.includes('\\')) {
    throw new PathError(`路径分隔符必须统一为 /，不允许反斜杠：${v}`);
  }
  if (v.includes('..')) {
    throw new PathError(`不允许 .. 上跳：${v}`);
  }
  if (v.endsWith('/')) {
    throw new PathError(`路径必须指向文件而不是目录：${v}`);
  }
  return v;
}

/**
 * 归一化相对路径：反斜杠→/、去掉前导 ./、压缩重复斜杠，然后走同一套校验。
 * 只用于**旧数据迁移 / 外部输入**；新数据一律直接 assertRelative。
 */
export function normalizeRelative(value) {
  if (typeof value !== 'string') throw new PathError(`相对路径必须是字符串，收到 ${typeof value}`);
  let v = value.trim().replace(/\\/g, '/');
  while (v.startsWith('./')) v = v.slice(2);
  v = v.replace(/\/{2,}/g, '/');
  return assertRelative(v);
}

/** 生成标准存储键：YYYYMMDD/<studentId>/<uuid>.<ext> */
export function toStorageKey({ studentId, ext = 'bin', at = new Date(), random = randomUUID }) {
  if (!/^[A-Za-z0-9_-]+$/.test(studentId)) {
    throw new PathError(`studentId 含非法字符：${studentId}`);
  }
  const cleanExt = String(ext).replace(/^\./, '').toLowerCase();
  if (!/^[A-Za-z0-9]+$/.test(cleanExt)) {
    throw new PathError(`扩展名含非法字符：${ext}`);
  }
  // 用本地年月日分目录（业务日期同样由客户端给本地日，避免 UTC 偏一天）。
  const day = [
    at.getFullYear(),
    String(at.getMonth() + 1).padStart(2, '0'),
    String(at.getDate()).padStart(2, '0'),
  ].join('');
  return assertRelative(`${day}/${studentId}/${random()}.${cleanExt}`);
}

/** 取存储根目录；rootOverride 仅供测试/一次性脚本使用。 */
export function storageRoot(rootOverride) {
  return path.resolve(rootOverride ?? getConfig().storageRoot);
}

/**
 * 相对路径 → 绝对路径。
 * ⚠️ 拼完必须二次校验仍在根目录内：DB 约束可能被绕过（运维直连、旧数据、
 *    未来某段代码没走 assertRelative），最终防线必须在文件系统边界上。
 */
export function resolveStoragePath(relative, rootOverride) {
  const root = storageRoot(rootOverride);
  const rel = assertRelative(relative);
  if (rel === '') throw new PathError('相对路径为空，无法解析为文件');
  const absolute = path.resolve(root, rel);
  const back = path.relative(root, absolute);
  if (back === '' || back === '..' || back.startsWith(`..${path.sep}`) || path.isAbsolute(back)) {
    throw new PathError(`解析结果越出存储根目录：${relative}`);
  }
  return absolute;
}

/**
 * 绝对路径 → 相对路径（入库前用）。
 * 已经是相对路径的输入直接归一化返回。根外的绝对路径一律抛错，不静默截断。
 */
export function toRelativePath(value, rootOverride) {
  if (typeof value !== 'string') throw new PathError(`路径必须是字符串，收到 ${typeof value}`);
  const raw = value.trim();
  if (!path.isAbsolute(raw) && !/^[A-Za-z]:/.test(raw)) {
    return normalizeRelative(raw);
  }
  const root = storageRoot(rootOverride);
  const absolute = path.resolve(raw);
  const rel = path.relative(root, absolute);
  if (rel === '' || rel === '..' || rel.startsWith(`..${path.sep}`) || path.isAbsolute(rel)) {
    throw new PathError(`文件不在 STORAGE_ROOT 内，无法转成相对路径：${raw}`);
  }
  return normalizeRelative(rel.split(path.sep).join('/'));
}

/** 启动时确保根目录存在且是目录（写权限由实际写入时暴露）。 */
export function ensureStorageRoot(rootOverride) {
  const root = storageRoot(rootOverride);
  fs.mkdirSync(root, { recursive: true });
  if (!fs.statSync(root).isDirectory()) {
    throw new PathError(`STORAGE_ROOT 不是目录：${root}`);
  }
  return root;
}
