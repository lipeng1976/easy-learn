/**
 * 会话票据与认证。
 *
 * 票据是无状态 HMAC（v1.<payload>.<sig>），签名密钥只来自 config.sessionSecret。
 * 两个服务必须用同一把密钥，否则一边签的票另一边验不过。
 *
 * 票据里带 visibleStudents：认证后不必再查一次库即可开 RLS 事务。
 * 代价是关系解除后旧票在 TTL 内仍有效 —— 这是明确的取舍，缩短
 * SESSION_TTL_HOURS 或迁入原工程的 user_session 撤销逻辑可收紧。
 */

import crypto from 'node:crypto';
import { AppError, ERROR_CODES } from '../../shared/errors.js';
import { getPool, withTenant } from '../../shared/db.js';
import { signSession, verifySession } from '../../shared/session.js';
import { verifyPassword } from './password.js';

// 票据签发/校验的真身在 shared/session.js（两个服务共用，不许各写一份）。
// re-export 只为兼容本服务路由的既有引用。
export { verifySession } from '../../shared/session.js';

/**
 * 从请求头解析身份。
 * 开发模式（AI_REQUIRE_AUTH=false）返回一个明确的本地身份，便于联调；
 * 生产模式必须有 Bearer 票据，身份只从签名里取，**不信客户端自报的 studentId**。
 */
export function authenticate(req, config) {
  if (!config.requireAuth) {
    return {
      userId: 'dev-local',
      name: '本地开发',
      role: 'student',
      visibleStudents: ['dev-local'],
      dev: true,
    };
  }
  const header = req.headers?.authorization ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
  if (!token) throw new AppError(ERROR_CODES.UNAUTHORIZED, '缺少 Bearer 会话票据');
  const payload = verifySession(token, config.sessionSecret);
  return {
    userId: payload.sub,
    name: payload.name ?? '',
    role: payload.role ?? '',
    visibleStudents: payload.vs.filter((v) => typeof v === 'string' && v !== ''),
    dev: false,
  };
}

/**
 * 登录。认证查询走 DDL 里的 SECURITY DEFINER 函数：
 * 此时还没有身份，RLS 会 fail-closed，必须由函数以建表者身份查凭证。
 * 失败信息统一为「手机号或密码不正确」，不区分账号是否存在。
 */
export async function login({ phone, password }, config) {
  if (typeof phone !== 'string' || phone.trim() === '' ||
      typeof password !== 'string' || password === '') {
    throw new AppError(ERROR_CODES.INVALID_ARGUMENT, 'phone 与 password 均不能为空');
  }
  const pool = await getPool();
  const { rows } = await pool.query('SELECT * FROM auth_lookup_credential($1)', [phone.trim()]);
  const row = rows[0];
  const denied = new AppError(ERROR_CODES.UNAUTHORIZED, '手机号或密码不正确');
  if (!row || !verifyPassword(password, row.out_password_hash)) throw denied;

  const userId = row.out_user_id;
  const { rows: vsRows } = await pool.query('SELECT auth_visible_students($1) AS ids', [userId]);
  const visibleStudents = (vsRows[0]?.ids ?? []).filter(Boolean);

  const ttlHours = config.sessionTtlHours;
  const expiresAt = new Date(Date.now() + ttlHours * 3600 * 1000);
  const token = signSession(
    { userId, name: row.out_name, role: row.out_role, visibleStudents, ttlHours },
    config.sessionSecret
  );

  // 留痕：一次登录一行。user_session 的 RLS 只允许写 user_id = 自己的行。
  await withTenant({ userId, visibleStudents }, async (client) => {
    await client.query(
      `INSERT INTO user_session (id, user_id, expires_at, client)
       VALUES ($1, $2, $3, $4)`,
      [crypto.randomUUID(), userId, expiresAt, 'login']
    );
  });

  return {
    token,
    expiresAt: expiresAt.toISOString(),
    user: { id: userId, name: row.out_name, role: row.out_role },
    visibleStudents,
  };
}
