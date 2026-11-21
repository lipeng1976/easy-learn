/**
 * 按序执行 db/*.sql。
 *
 * 由根目录 scripts/init-db.mjs 复用（它额外负责用 env 设置应用角色口令），
 * 也可独立运行：npm run migrate -w @easy-learn/data-service
 *
 * ⚠️ DDL 需要建表权限，所以这里用 PG_OPS_URL（运维连接），
 *    不是应用连接 DATABASE_URL —— 应用角色不该有 DDL 权限。
 */

import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { getConfig, PROJECT_ROOT } from '../../shared/config.js';

export const SCHEMA_FILES = Object.freeze(['001_schema.sql', '002_seed.sql']);

export function readSchemaSql() {
  return SCHEMA_FILES.map((file) => {
    const absolute = path.join(PROJECT_ROOT, 'db', file);
    if (!fs.existsSync(absolute)) throw new Error(`缺少数据库脚本：${absolute}`);
    return { file, sql: fs.readFileSync(absolute, 'utf8') };
  });
}

/** 在**调用方的事务里**执行；不自带 BEGIN/COMMIT，失败由调用方回滚。 */
export async function applySchema(client, log = console) {
  for (const { file, sql } of readSchemaSql()) {
    await client.query(sql);
    log.log?.(`[migrate] applied ${file}`);
  }
}

async function runStandalone() {
  const config = getConfig('data');
  if (!config.pgOpsUrl) {
    throw new Error('未配置 PG_OPS_URL。DDL 必须用运维连接执行，见 docs/environment.md。');
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
    await applySchema(client);
    await client.query('COMMIT');
    console.log('[migrate] 全部完成');
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    await client.end();
  }
}

const isCli = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isCli) {
  runStandalone().catch((err) => {
    console.error('[migrate] 失败：', err.message);
    process.exitCode = 1;
  });
}
