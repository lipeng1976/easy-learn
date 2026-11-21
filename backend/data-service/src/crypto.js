import { randomBytes, createCipheriv, createDecipheriv, createHash } from 'node:crypto';

/**
 * 对称加密（AES-256-GCM），用于**可逆**存储第三方凭证（如 ima 的
 * clientid / apikey）。注意它与 `password.js` 的 scrypt **不是一回事**：
 * 口令哈希是不可逆的（校验时只能重算比对），而这里必须能把密文还原成
 * 明文 —— 因为服务端要拿明文 apikey 去调 ima OpenAPI。所以不能复用 scrypt。
 *
 * ## 为什么是 AES-GCM 而不是 AES-CBC / ECB
 *
 * GCM 是**带认证标签**的：任何对密文的篡改（哪怕一位）都会在解密时
 * 直接抛 `BAD_DECRYPT`，而不是吐出一段面目全非的明文让调用方误以为是
 * 正确的 apikey（那会在 ima 端表现为一个「偶发的、查不出原因」的 401）。
 * ECB 更不行 —— 它连相同的明文块都会加密成相同的密文块，等于把密钥长度
 * 之外的结构信息全泄露了。
 *
 * ## 存储格式
 *
 *     <iv-b64>:<tag-b64>:<ciphertext-b64>
 *
 * IV 每加密一次随机生成（12 字节，GCM 推荐值）。**绝不复用 IV 与同一把密钥**——
 * 复用会让攻击者用已知明文推出密钥流，整库凭证一起破。随机 IV 不涉密，
 * 明文存进密文串即可（和 `password.js` 把 salt 写进哈希串是同一思路）。
 *
 * ## 密钥来源
 *
 * 调用方负责把密钥传进来（依赖注入），本模块不读 `process.env` ——
 * 这样单元测试可以不依赖环境变量，直接传一个 32 字节的测试密钥。
 * 生产密钥来自 `IMA_CREDENTIAL_SECRET`（部署侧注入，绝不上库）。
 */

const ALGO = 'aes-256-gcm';
const IV_LENGTH = 12;

/** 把一个任意长度的密钥字符串归一成 AES-256 要求的 32 字节 Buffer。 */
function toKeyBuffer(key) {
  if (typeof key !== 'string' || key.length === 0) {
    throw new Error('IMA_CREDENTIAL_SECRET 未设置或为空：无法加解密第三方凭证');
  }
  // 用 SHA-256 把任意长度口令压成稳定的 32 字节，避免「密钥长度不对」的运行时错
  // （AES-256-GCM 要求密钥恰好 32 字节，直接用 Buffer.from 会随口令长度变化而爆
  // `Invalid key length`）。这层派生不增加安全性（密钥本身必须够随机），只是让
  // 调用方不必精确提供 32 字节。
  return createHash('sha256').update(key, 'utf8').digest();
}

/**
 * 加密明文。返回可入库的 `iv:tag:ct` 串。
 * @param {string} plain 明文（如 ima apikey）
 * @param {string} key 密钥（生产来自 IMA_CREDENTIAL_SECRET）
 * @returns {string}
 */
export function encryptSecret(plain, key) {
  const iv = randomBytes(IV_LENGTH);
  const cipher = createCipheriv(ALGO, toKeyBuffer(key), iv);
  const ct = Buffer.concat([cipher.update(String(plain), 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return [
    iv.toString('base64'),
    tag.toString('base64'),
    ct.toString('base64'),
  ].join(':');
}

/**
 * 解密。任何篡改都会抛错（GCM 认证失败），调用方据此判定「凭证损坏」并提示重连。
 * @param {string} payload `iv:tag:ct` 串
 * @param {string} key 密钥
 * @returns {string} 明文
 */
export function decryptSecret(payload, key) {
  if (typeof payload !== 'string' || payload.split(':').length !== 3) {
    throw new Error('凭证存储格式损坏（期望 iv:tag:ct）');
  }
  const [ivB64, tagB64, ctB64] = payload.split(':');
  const decipher = createDecipheriv(ALGO, toKeyBuffer(key), Buffer.from(ivB64, 'base64'));
  decipher.setAuthTag(Buffer.from(tagB64, 'base64'));
  const plain = Buffer.concat([
    decipher.update(Buffer.from(ctB64, 'base64')),
    decipher.final(),
  ]);
  return plain.toString('utf8');
}
