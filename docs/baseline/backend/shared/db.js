/**
 * PostgreSQL 连接池与 RLS 事务边界。
 *
 * ⚠️ 两条命门：
 *   1) 应用连接必须用非 superuser 的 app_rls 角色。superuser 会绕过 RLS，
 *      连 FORCE ROW LEVEL SECURITY 也拦不住，而且**不报错**。
 *   2) 身份变量必须用 set_config(..., true)／SET LOCAL，只在事务内生效。
 *      用会话级 SET 会让连接池把上一个人的身份带给下一个请求。
 *
 * pg 用动态 import：health 端点不连库，因此**未装依赖也能起服务**，
 * 便于区分「服务没起来」和「库没连上」。
 */

import { getConfig } from './config.js';
import { AppError, ERROR_CODES } from './errors.js';

let poolPromise = null;

export async function getPool() {
  if (!poolPromise) poolPromise = createPool();
  return poolPromise;
}

async function createPool() {
  const config = getConfig();
  let pg;
  try {
    pg = await import('pg');
  } catch (cause) {
    throw new AppError(
      ERROR_CODES.STORAGE_ERROR,
      '缺少 pg 依赖，请先在工程根目录执行 npm install',
      { cause }
    );
  }
  const Pool = pg.Pool ?? pg.default?.Pool;
  const ssl = config.pgSslMode === 'require' || config.pgSslMode === 'verify-full'
    ? { rejectUnauthorized: false }
    : false;
  const pool = new Pool({
    connectionString: config.databaseUrl,
    max: config.pgPoolMax,
    ssl,
    connectionTimeoutMillis: 5000,
  });
  pool.on('error', (err) => console.error('[pg] idle client error', err));
  return pool;
}

/**
 * 在带 RLS 身份的事务里执行 fn(client)。
 * visibleStudents 为空数组时写空串 → app_csv_setting() 返回空数组 → 0 行（fail-closed）。
 */
export async function withTenant({ userId, visibleStudents = [] }, fn) {
  if (!userId) {
    throw new AppError(ERROR_CODES.UNAUTHORIZED, '缺少用户身份，不能开启数据库事务');
  }
  const pool = await getPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT set_config($1, $2, true)', ['app.user_id', String(userId)]);
    await client.query('SELECT set_config($1, $2, true)', [
      'app.visible_students',
      visibleStudents.filter(Boolean).join(','),
    ]);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch { /* 连接已断，无需再报 */ }
    throw err;
  } finally {
    client.release();
  }
}

/** 健康检查用的轻量探针；不设身份，只验证连接串可用。 */
export async function pingDatabase() {
  const pool = await getPool();
  const { rows } = await pool.query('SELECT 1 AS ok');
  return rows[0]?.ok === 1;
}

export async function closePool() {
  if (poolPromise) {
    const pool = await poolPromise;
    await pool.end();
    poolPromise = null;
  }
}
