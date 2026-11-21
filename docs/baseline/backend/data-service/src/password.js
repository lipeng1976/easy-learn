/**
 * 口令哈希：Node 内置 scrypt，无第三方依赖。
 *
 * 存储格式：scrypt$<saltHex>$<hashHex>
 * 不存明文、不用通用快速哈希（MD5/SHA）、不自己实现密码学。
 * ⚠️ 账号与口令由运维脚本 scripts/create-user.mjs 在运行期创建，
 *    **绝不写进种子 SQL 或版本库**。
 */

import { randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';

const KEY_LENGTH = 64;
const SALT_LENGTH = 16;

export function hashPassword(plain) {
  if (typeof plain !== 'string' || plain.length === 0) {
    throw new Error('口令不能为空');
  }
  const salt = randomBytes(SALT_LENGTH);
  const derived = scryptSync(plain, salt, KEY_LENGTH);
  return `scrypt$${salt.toString('hex')}$${derived.toString('hex')}`;
}

/** 校验失败返回 false，不抛异常、不区分「账号不存在」与「密码错误」。 */
export function verifyPassword(plain, stored) {
  if (typeof plain !== 'string' || typeof stored !== 'string') return false;
  const parts = stored.split('$');
  if (parts.length !== 3 || parts[0] !== 'scrypt') return false;
  try {
    const salt = Buffer.from(parts[1], 'hex');
    const expected = Buffer.from(parts[2], 'hex');
    if (salt.length !== SALT_LENGTH || expected.length !== KEY_LENGTH) return false;
    const actual = scryptSync(plain, salt, expected.length);
    return timingSafeEqual(expected, actual);
  } catch {
    return false;
  }
}
