import { createHmac, timingSafeEqual } from 'node:crypto';

import { authNotConfigured, tokenExpired, tokenInvalid } from './errors.js';

/**
 * 会话 token：让 `AI_REQUIRE_AUTH=true`（网关）与数据服务的鉴权
 * 成为一个**真的**开关。ai-gateway 与 data-service 共用这一份实现。
 *
 * ## 它解决的是什么问题
 *
 * 在此之前，网关靠客户端自己声明的 `X-Student-Id` 做配额与审计 ——
 * 那个值可以随手改成别人的学号，于是：
 * - 配额可以绕过（换一个学号就是新额度）
 * - 审计会指向错误的人（「小明今天花了 800 次」可能根本不是小明）
 *
 * token 的作用只有一个：**让身份由服务端出具，而不是由客户端申报**。
 *
 * ## 它不解决什么（S2 已经把这一半补上）
 *
 * 本文件产出的 token **自身**是无状态的：验签就完事，服务端无法作废它。
 * S1 的时候这意味着三件事做不到 —— 退出登录、改密后踢掉别的设备、丢了手机立刻失效。
 *
 * S2 的解法是**不改造本模块**，而是给载荷加一个 `sid` 字段，由数据服务侧
 * 在验签之后再查一次会话表是否还活着（`data-service/src/session.js`）：
 * 签名负责「这串字节没被改过」（便宜、无状态），会话表负责「这个凭证还能用吗」（可吊销）。
 * 两件事分开做，比把会话状态塞进 token 里正确得多。
 *
 * ⚠️ 因此**签发端的作用范围变了**：
 * - data-service 签发的 token **必须**带 `sid`（它同时写了会话行）；
 * - ai-gateway 侧暂时仍签不带 `sid` 的 token（配额与审计够用），
 *   所以校验时 `requireSession` 默认是 false —— 那个开关是给调用方按场景打开的。
 *
 * ## 形态
 *
 * ```
 * {base64url(payload)}.{hex(hmac-sha256(secret, base64url(payload)))}
 * ```
 *
 * 用「签名 + 明文载荷」而不是加密，是因为载荷里只有身份与过期时间，
 * 没有需要保密的内容 —— 而可读的载荷在排查时省掉一次解码。
 */

const VERSION = 'v1';

/** 允许的身份 id 字符集，与 guard 保持一致。 */
const SUBJECT_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

/** 会话 id 字符集。比身份 id 宽松一点（前缀 + uuid），但仍然只允许看得懂的字符。 */
const SESSION_ID_PATTERN = /^[A-Za-z0-9_-]{1,80}$/;

/**
 * 系统里的角色。
 *
 * ⚠️ **`teacher` 现在放进来，但本期不签发。** 这是刻意的（迁移计划 §10.5）：
 * 班级由老师创建 → 建班端点授权 = `role === 'teacher'`，
 * 所以老师角色是班级功能的完整前置依赖。
 *
 * 现在放一个枚举值的成本是**零**；等老师真来了再补，要动的是
 * 「签发端 + 全部校验点 + 一个旧 token 兼容期」（已经发出去的 token 里没有 role，
 * 服务端分不清「老 token」和「伪造的缺字段 token」）。
 */
export const UserRoles = {
  student: 'student',
  parent: 'parent',
  teacher: 'teacher',
};

const KNOWN_ROLES = new Set(Object.values(UserRoles));

function base64url(input) {
  return Buffer.from(input, 'utf8').toString('base64url');
}

function sign(secret, body) {
  return createHmac('sha256', secret).update(body).digest('hex');
}

/**
 * 签发一个会话 token。
 *
 * @param {object} options
 * @param {string} options.secret 签名密钥
 * @param {string} options.subject 身份 id（`app_user.id`）。
 *   注意不再是 `studentId` —— 家长和老师没有学号，用 userId 才装得下三种角色（R1）。
 * @param {string} [options.role] 见 UserRoles。**数据服务要求它必须存在**；
 *   网关侧暂时允许缺省，以便与尚未升级的客户端共存。
 * @param {string} [options.sessionId] 服务端会话 id（`user_session.id`）。
 *   **数据服务签发时必须给** —— 给了才能吊销。见文件头的说明。
 */
export function issueSessionToken({
  secret,
  subject,
  role,
  sessionId,
  ttlSeconds = 12 * 3600,
  now = Date.now(),
  extra = {},
}) {
  if (!secret) throw new Error('issueSessionToken 需要 secret');
  if (!SUBJECT_PATTERN.test(String(subject ?? ''))) {
    throw new Error(`subject 不合法：${subject}`);
  }
  if (role !== undefined && !KNOWN_ROLES.has(role)) {
    throw new Error(`未知角色：${role}（允许：${[...KNOWN_ROLES].join(', ')}）`);
  }
  if (sessionId !== undefined && !SESSION_ID_PATTERN.test(String(sessionId))) {
    throw new Error(`sessionId 不合法：${sessionId}`);
  }

  const payload = {
    v: 1,
    sub: String(subject),
    iat: Math.floor(now / 1000),
    exp: Math.floor(now / 1000) + ttlSeconds,
    // 只有传了才写进载荷 —— 保持网关既有 token 的字节形态不变，
    // 否则「升级服务端」会让所有在用的 token 立刻变成另一种形状。
    ...(role === undefined ? {} : { role }),
    ...(sessionId === undefined ? {} : { sid: String(sessionId) }),
    ...extra,
  };
  const body = base64url(JSON.stringify(payload));
  return `${VERSION}.${body}.${sign(secret, body)}`;
}

/**
 * 校验并解出身份。
 *
 * 抛出的错误码是**有语义的**：`token_expired` 让客户端去续签，
 * `token_invalid` 让客户端去重新登录。两者不能混。
 *
 * @param {object} [options]
 * @param {boolean} [options.requireRole=false]
 *   为 true 时，载荷里没有合法 `role` 直接判无效。
 *   **数据服务必须开这个** —— 它要拿 role 决定能看哪些数据，
 *   少了 role 就只能靠猜测，而猜错的后果是越权。
 * @param {boolean} [options.requireSession=false]
 *   为 true 时，载荷里必须有 `sid`。**数据服务必须开这个**：
 *   不开的话，任何人拿密钥签一个不带 sid 的 token 就绕过了吊销，
 *   而「绕过吊销」这件事没有任何症状 —— 等价于 S2 白做。
 *
 *   注意这里只检查**载荷里有没有 sid**，不查库。
 *   「这个 sid 还活着吗」是 `data-service/src/session.js` 的事：本模块不碰数据库，
 *   它连 pg 都不依赖（网关也在用它）。
 */
export function verifySessionToken(token, {
  secret,
  now = Date.now(),
  requireRole = false,
  requireSession = false,
} = {}) {
  if (!secret) {
    throw authNotConfigured(
      '服务端未配置会话签名密钥（AI_SESSION_SECRET），无法校验会话凭证'
        + '（若不需要强制鉴权，请把 AI_REQUIRE_AUTH 置为 false）',
    );
  }

  const raw = String(token ?? '').trim();
  if (raw === '') throw tokenInvalid('缺少会话 token');

  const parts = raw.split('.');
  if (parts.length !== 3 || parts[0] !== VERSION) {
    throw tokenInvalid('会话 token 结构不合法');
  }
  const [, body, signature] = parts;

  const expected = Buffer.from(sign(secret, body), 'utf8');
  const actual = Buffer.from(signature, 'utf8');
  // 长度不等时 timingSafeEqual 会抛，先挡掉。这里用**定长比较**而不是
  // `===`：字符串比较会在第一个不同字符处返回，理论上能被计时探测。
  if (expected.length !== actual.length) throw tokenInvalid('会话 token 签名不匹配');
  if (!timingSafeEqual(expected, actual)) {
    throw tokenInvalid('会话 token 签名不匹配');
  }

  let payload;
  try {
    payload = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
  } catch {
    throw tokenInvalid('会话 token 载荷无法解析');
  }

  if (payload === null || typeof payload !== 'object') {
    throw tokenInvalid('会话 token 载荷格式异常');
  }
  if (!SUBJECT_PATTERN.test(String(payload.sub ?? ''))) {
    throw tokenInvalid('会话 token 里的身份 id 不合法');
  }

  const role = payload.role === undefined ? undefined : String(payload.role);
  if (requireRole) {
    // 注意：这里判 tokenInvalid 而不是 unauthorized —— 缺 role 的 token
    // 无法建立身份，属于「凭证本身不合格」，客户端正确的动作是重新登录
    // （重新登录会拿到带 role 的新 token）。
    if (role === undefined) throw tokenInvalid('会话 token 缺少角色，请重新登录');
    if (!KNOWN_ROLES.has(role)) throw tokenInvalid(`会话 token 里的角色不可识别：${role}`);
  } else if (role !== undefined && !KNOWN_ROLES.has(role)) {
    throw tokenInvalid(`会话 token 里的角色不可识别：${role}`);
  }

  const rawSid = payload.sid === undefined ? undefined : String(payload.sid);
  if (rawSid !== undefined && !SESSION_ID_PATTERN.test(rawSid)) {
    throw tokenInvalid('会话 token 里的会话标识不合法');
  }
  if (requireSession && rawSid === undefined) {
    // 与「缺 role」同一族：凭证本身不合格，客户端正确的动作是重新登录
    // （重新登录会拿到带 sid 的新 token）。
    // 这一条是数据服务的必经之路 —— 没有它，自己签一个不带 sid 的 token
    // 就绕过了整张会话表，「可吊销」这件事等于没做。
    throw tokenInvalid('会话 token 缺少会话标识，请重新登录');
  }

  const expiresAt = Number(payload.exp ?? 0);
  if (!Number.isFinite(expiresAt) || expiresAt <= 0) {
    throw tokenInvalid('会话 token 缺少有效期');
  }
  // 先判过期再判其它：一个已过期的 token 就算结构完全正确，
  // 也不该被当成「合法但没权限」，否则客户端会拿到 invalid 而去重新登录。
  if (expiresAt * 1000 <= now) {
    throw tokenExpired();
  }

  return {
    subject: String(payload.sub),
    role,
    sessionId: rawSid,
    issuedAt: Number(payload.iat ?? 0) * 1000,
    expiresAt: expiresAt * 1000,
  };
}
