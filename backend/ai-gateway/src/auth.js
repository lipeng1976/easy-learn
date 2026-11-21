import {
  issueSessionToken as issueShared,
  verifySessionToken as verifyShared,
} from '../../shared/token.js';

/**
 * 网关的会话 token 适配层。
 *
 * ## 实现去哪了
 *
 * 签名、校验、错误码判定全部在 `serverless/shared/token.js` ——
 * 数据服务用的是同一份。**为什么不留两份**：token 是客户端协议，
 * 两个服务各写一份的话，一次「格式微调」会让另一半悄悄不认，而症状是
 * 「AI 能用、数据接口全 401」这类要翻两边代码才能定位的问题。
 *
 * ## 这个文件为什么还存在
 *
 * 因为网关这侧的调用点（8 个模块 + `scripts/issue-session-token.mjs`）
 * 用的参数名是 `studentId`、返回值读的是 `identity.studentId`。
 * 共享层用的是中性名 `subject` / `role`（家长和老师没有学号，
 * 要装下三种角色就只能用 userId —— 见 R1）。
 *
 * 所以这里做一层**纯改名**的适配：不改语义、不加判断，
 * 网关的行为与切共享层之前逐字节相同。
 *
 * ⚠️ **S2 会拆掉这层适配**（R1：token 必须带 role）。那时候：
 * - `issueSessionToken` 改为 `subject` + `role`；
 * - `verifySessionToken` 传 `requireRole: true`，返回值多一个 `role`；
 * - 客户端登录链路同步升级，旧 token 走一个兼容期。
 * 现在不做的理由和班级功能一样：**没有调用方的接口，冻结的只是文本**。
 */

/**
 * 签发会话 token。参数与返回与旧实现完全一致。
 *
 * 注意这里**刻意不传 `role`** —— 共享层只在传了 role 时才写进载荷，
 * 所以签出来的 token 字节形态与升级前一致，
 * 已经在用的客户端不需要重新登录。
 */
export function issueSessionToken({
  secret,
  studentId,
  ttlSeconds = 12 * 3600,
  now = Date.now(),
  extra = {},
}) {
  return issueShared({ secret, subject: studentId, ttlSeconds, now, extra });
}

/**
 * 校验并解出身份。
 *
 * 同样**刻意不开 `requireRole`**：网关做的是配额与审计，不需要角色；
 * 而数据服务要拿 role 决定可见集合，所以那边开。同一个函数、两种用法，
 * 靠一个显式开关区分，好过两个函数各写一份判定。
 */
export function verifySessionToken(token, { secret, now = Date.now() } = {}) {
  const identity = verifyShared(token, { secret, now });
  return {
    studentId: identity.subject,
    issuedAt: identity.issuedAt,
    expiresAt: identity.expiresAt,
  };
}
