#!/usr/bin/env node

/**
 * 签发一个会话 token（运维 / 联调用）。
 *
 * 用法：
 *
 * ```bash
 * # 用与网关相同的密钥签发，默认 12 小时有效
 * AI_SESSION_SECRET=xxx node scripts/issue-session-token.mjs stu_001
 *
 * # 指定有效期，或直接传密钥
 * node scripts/issue-session-token.mjs stu_001 --ttl 3600 --secret xxx
 * ```
 *
 * 拿到的串放进客户端的 `AiIdentity.sessionToken`（或请求头
 * `Authorization: Bearer <token>`）即可。
 *
 * ## 为什么是脚本而不是一个端点
 *
 * 签发意味着「我承认这个学号」，它必须由**已经有身份判断能力的一方**来做。
 * 网关现在还不知道谁是学生、密码对不对 —— 账号体系仍在客户端本地。
 * 因此这里**不做**一个「输入学号就发 token」的公开端点：那等于把
 * `AI_REQUIRE_AUTH` 变成一个形式主义的开关，谁都能给自己签一个。
 * 正确顺序是：先有服务端登录（校验密码 → 调 `issueSessionToken`），
 * 再谈这个开关。
 */

import { issueSessionToken } from '../src/auth.js';

function parseArgs(argv) {
  const options = { studentId: '', secret: process.env.AI_SESSION_SECRET ?? '', ttl: 0 };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--secret') {
      options.secret = argv[index + 1] ?? '';
      index += 1;
    } else if (arg === '--ttl') {
      options.ttl = Number.parseInt(argv[index + 1] ?? '', 10);
      index += 1;
    } else if (!arg.startsWith('--') && options.studentId === '') {
      options.studentId = arg;
    }
  }
  return options;
}

const options = parseArgs(process.argv.slice(2));

if (options.studentId === '') {
  console.error('用法：AI_SESSION_SECRET=xxx node scripts/issue-session-token.mjs <studentId> [--ttl 秒] [--secret xxx]');
  process.exit(1);
}
if (options.secret === '') {
  console.error('缺少密钥：请设置 AI_SESSION_SECRET，或用 --secret 传入。');
  console.error('注意必须与网关环境里的 AI_SESSION_SECRET 一致，否则 token 一定校验失败。');
  process.exit(1);
}

try {
  const ttl = Number.isFinite(options.ttl) && options.ttl > 0 ? options.ttl : undefined;
  const token = issueSessionToken({
    secret: options.secret,
    studentId: options.studentId,
    ...(ttl === undefined ? {} : { ttlSeconds: ttl }),
  });
  // 只打印 token 本身，方便直接进管道（$(...)）。
  console.log(token);
} catch (error) {
  console.error(`签发失败：${error.message}`);
  process.exit(1);
}
