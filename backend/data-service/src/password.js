import { randomBytes, scrypt as scryptCallback, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';

const scrypt = promisify(scryptCallback);

/**
 * 口令哈希。
 *
 * ## 为什么必须有这个文件（迁移计划 §3.4③）
 *
 * 客户端现状是**明文比对**（`auth_service.dart:72`：`user['password'] != password`）。
 * 单机时代还说得过去 —— 库在用户自己的手机上，能读到它的人本来就能读到手机里的一切。
 * **上云之后这句话不成立**：一处 SQL 注入、一份误发的数据库备份、一个有只读权限的
 * 运维账号，都会把全体用户的口令以可读形式带走 —— 而用户的口令往往和别处是同一个。
 *
 * ## 为什么用 scrypt 而不是 bcrypt / argon2
 *
 * 这不是「哪个更强」的取舍，是**依赖面**的取舍：scrypt 在 `node:crypto` 里，
 * 零依赖。数据服务的其它部分（网关也是）刻意保持零依赖 —— 云函数部署时不用打包
 * node_modules，冷启动也短一截。bcrypt/argon2 都是 native 模块，要跟着 Node 版本走。
 *
 * scrypt 是内存硬的（`128 · N · r` 字节），挡住 GPU 批量爆破这件事它与 argon2 同级。
 * 真到了要换的那天，**存储格式自带参数**（见下），逐条惰性升级即可，不需要停机重算。
 *
 * ## 存储格式（自描述）
 *
 *     scrypt$<N>$<r>$<p>$<salt-b64url>$<hash-b64url>
 *
 * 把参数写进每一行，而不是写死在代码里：将来调高 N 时，老行仍然能被正确校验
 * （用它们自己的参数），新口令用新参数。若把参数写死在代码里，调参那天
 * **全体用户直接登不进来** —— 而这类改动通常发生在安全事件之后，最不能出事的时候。
 *
 * 用 `$` 分隔而不是 `:`：前者是口令哈希领域的惯例（crypt(3)），
 * 运维拿这个值去别处比对时不会误解析。
 */

/** 当前参数。调高 N 即可提升强度，老行不受影响（原因见上）。 */
const CURRENT = { n: 16384, r: 8, p: 1, keylen: 32 };

const SALT_BYTES = 16;
const FORMAT = 'scrypt';

/**
 * 服务端只守**长度**，不复制客户端那条「6-16 位数字和字母组合」的正则。
 *
 * 理由不是偷懒：复杂度规则是**产品策略**（它决定界面上怎么写提示），
 * 而策略会变。服务端如果也校验一遍，收紧规则的那天，所有老账号会在登录时
 * 被自己服务端拦下来 —— 因为他们当初注册时那条规则还没生效。
 * 服务端只回答「这是不是一个口令」，强度引导交给客户端。
 *
 * 上限 64 是防滥用：scrypt 的成本与口令长度无关，但请求体没上限就是另一个故事。
 */
export const PASSWORD_MIN_LENGTH = 6;
export const PASSWORD_MAX_LENGTH = 64;

/** 存储值是不是本模块认识的哈希格式。迁移脚本与对账用它挑出历史明文行。 */
export function isHashFormat(stored) {
  return typeof stored === 'string' && stored.startsWith(`${FORMAT}$`);
}

/**
 * 把一个明文口令变成可入库的哈希。
 *
 * 每次调用都用新的随机盐：两个用户碰巧用同一个口令，库里也是两个不同的值 ——
 * 否则「哈希相同」就等于「口令相同」，一次泄露能顺藤摸瓜找到一批同口令账号。
 */
export async function hashPassword(plain) {
  const salt = randomBytes(SALT_BYTES);
  const derived = await scrypt(plain, salt, CURRENT.keylen, {
    n: CURRENT.n,
    r: CURRENT.r,
    p: CURRENT.p,
    // 默认 maxmem 是 32MB，而 128·N·r = 16MB —— 调高 N 时这里会先炸。
    // 给两倍余量，让「调参」不会表现成一句难懂的 ERR_CRYPTO_INVALID_SCRYPT_PARAMS。
    maxmem: 128 * CURRENT.n * CURRENT.r * 2,
  });
  return [
    FORMAT,
    CURRENT.n,
    CURRENT.r,
    CURRENT.p,
    salt.toString('base64url'),
    derived.toString('base64url'),
  ].join('$');
}

/**
 * 校验口令。
 *
 * 返回对象而不是布尔值，是为了让调用方能区分两种「不通过」：
 * - `ok: false, reason: 'mismatch'` —— 口令不对，这是用户的日常；
 * - `ok: false, reason: 'malformed'` —— **这行数据坏了或还是明文**，
 *   这是服务端的问题，值得打一条日志（而客户端的提示必须与上一种完全相同，
 *   见下面「不泄露区别」的说明）。
 *
 * ⚠️ 无论哪种失败，调用方对外的文案必须**一模一样**。
 * 「该手机号未注册」和「密码错误」分开说的接口，等于一个免费的账号枚举器。
 */
export async function verifyPassword(plain, stored) {
  if (!isHashFormat(stored)) {
    // 历史明文行（S6 迁移前可能存在）与损坏行都走这里。
    // 刻意**不**退化成 `stored === plain` 明文比对 —— 那等于留了一条后门，
    // 而它会在某次「先把功能跑通」的改动里被当成正常路径。
    return { ok: false, reason: 'malformed' };
  }

  const parts = String(stored).split('$');
  if (parts.length !== 6) return { ok: false, reason: 'malformed' };
  const [, nRaw, rRaw, pRaw, saltRaw, hashRaw] = parts;
  const n = Number(nRaw);
  const r = Number(rRaw);
  const p = Number(pRaw);
  if (![n, r, p].every((v) => Number.isInteger(v) && v > 0)) {
    return { ok: false, reason: 'malformed' };
  }

  let salt;
  let expected;
  try {
    salt = Buffer.from(saltRaw, 'base64url');
    expected = Buffer.from(hashRaw, 'base64url');
  } catch {
    return { ok: false, reason: 'malformed' };
  }
  if (salt.length === 0 || expected.length === 0) {
    return { ok: false, reason: 'malformed' };
  }

  let actual;
  try {
    actual = await scrypt(plain, salt, expected.length, { n, r, p, maxmem: 128 * n * r * 2 });
  } catch {
    // 参数大到内存不够时 scrypt 会抛。当成一次不通过，但原因要如实报出来。
    return { ok: false, reason: 'malformed' };
  }

  // 定长比较（与 token 签名校验同一套理由）：`===` 在第一个不同字节处返回，
  // 理论上能被计时探测出前缀。
  if (actual.length !== expected.length) return { ok: false, reason: 'mismatch' };
  return timingSafeEqual(actual, expected)
    ? { ok: true, reason: null }
    : { ok: false, reason: 'mismatch' };
}

/**
 * 这一行是不是用**旧参数**算的。
 *
 * 给「登录时顺手升级」用：用户成功登录那一刻是唯一持有明文的时刻，
 * 也是唯一能把哈希换成新参数的时机。不做这件事的话，调高 N 只对新账号生效，
 * 而老账号（恰恰是存在最久、最可能已经泄露的那些）强度永远停在旧参数上。
 */
export function needsRehash(stored) {
  if (!isHashFormat(stored)) return true;
  const parts = String(stored).split('$');
  return Number(parts[1]) !== CURRENT.n
    || Number(parts[2]) !== CURRENT.r
    || Number(parts[3]) !== CURRENT.p;
}
