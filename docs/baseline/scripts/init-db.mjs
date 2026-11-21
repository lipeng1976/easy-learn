/**
 * 数据库初始化：应用角色 → DDL → 种子，全部在一个事务里。
 *
 * 用法：npm run db:init
 * 前置：已创建空库；.env 里配好 PG_OPS_URL / APP_RLS_PASSWORD。
 *
 * ★ 角色口令只从 APP_RLS_PASSWORD 读，用 quoteLiteral 转义后拼进
 *   ALTER ROLE（PG 的 utility 语句不支持绑定参数）。DDL 文件里没有口令。
 */

import { getConfig } from '../backend/shared/config.js';
import { applySchema } from '../backend/data-service/scripts/migrate.mjs';

// DDL 里的角色名是固定字面量（SQL 读不到环境变量）。
// 若这里改名，必须同步改 db/001_schema.sql 的全部 CREATE ROLE / GRANT / POLICY 授权。
const DDL_APP_ROLE = 'app_rls';

function quoteIdent(value) {
  return `"${String(value).replace(/"/g, '""')}"`;
}

function quoteLiteral(value) {
  return `'${String(value).replace(/'/g, "''")}'`;
}

async function main() {
  const config = getConfig('data');
  if (!config.pgOpsUrl) {
    throw new Error('未配置 PG_OPS_URL。DDL 需要建表权限，必须用运维连接执行。');
  }
  if (config.pgAppRole !== DDL_APP_ROLE) {
    throw new Error(
      `PG_APP_ROLE=${config.pgAppRole}，但 DDL 固定使用 ${DDL_APP_ROLE}。` +
      '如需改名，请同步修改 db/001_schema.sql 与本文件。'
    );
  }

  let pg;
  try {
    pg = await import('pg');
  } catch (cause) {
    throw new Error('缺少 pg 依赖，请先在工程根目录执行 npm install', { cause });
  }
  const Client = pg.Client ?? pg.default?.Client;
  const client = new Client({
    connectionString: config.pgOpsUrl,
    ssl: config.pgSslMode === 'require' || config.pgSslMode === 'verify-full'
      ? { rejectUnauthorized: false }
      : false,
  });

  await client.connect();
  try {
    await client.query('BEGIN');

    const { rows } = await client.query(
      'SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = $1', [DDL_APP_ROLE]
    );
    if (rows.length === 0) {
      await client.query(`CREATE ROLE ${quoteIdent(DDL_APP_ROLE)} LOGIN`);
      console.log(`[init-db] 创建应用角色 ${DDL_APP_ROLE}`);
    }

    const password = config.appRlsPassword;
    if (!password || password.includes('CHANGE_ME')) {
      throw new Error('APP_RLS_PASSWORD 未填写（或仍是占位符 CHANGE_ME），拒绝初始化。');
    }
    await client.query(
      `ALTER ROLE ${quoteIdent(DDL_APP_ROLE)} LOGIN PASSWORD ${quoteLiteral(password)}`
    );
    console.log('[init-db] 应用角色口令已设置（口令不进 SQL 文件、不打印）');

    await applySchema(client);
    await client.query('COMMIT');
    console.log('[init-db] 完成：DDL 终态 + 字典种子，事务已提交');
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    await client.end();
  }
}

main().catch((err) => {
  console.error('[init-db] 失败：', err.message);
  process.exitCode = 1;
});
