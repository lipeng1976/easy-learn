/**
 * 运维工具：创建首个账号（或追加账号）。
 *
 * 用法（口令用环境变量传，别写进 shell history）：
 *   NEW_USER_PASSWORD='<强口令>' node scripts/create-user.mjs \
 *     --phone 13800000000 --name 学生姓名 --role student
 *
 * 也可用 --password 传，但会留在 shell history 里，不推荐。
 * ⚠️ 账号与口令**绝不写进种子 SQL 或版本库**；本脚本不在 CI / 部署流程里自动运行。
 * ⚠️ 用 PG_OPS_URL 直连（bypass RLS）：此时还没有任何用户身份，RLS 会 fail-closed。
 */

import { randomUUID } from 'node:crypto';
import { getConfig } from '../backend/shared/config.js';
import { hashPassword } from '../backend/data-service/src/password.js';

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    if (!key?.startsWith('--')) throw new Error(`无法识别的参数：${key}`);
    out[key.slice(2)] = argv[i + 1];
  }
  return out;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const phone = args.phone;
  const name = args.name;
  const role = args.role ?? 'student';
  const password = process.env.NEW_USER_PASSWORD ?? args.password;

  if (!phone || !name) throw new Error('缺少 --phone 或 --name');
  if (!['student', 'parent'].includes(role)) throw new Error('--role 只能是 student / parent');
  if (!password || password.length < 12) throw new Error('口令至少 12 字符（用 NEW_USER_PASSWORD 传入）');

  const config = getConfig('data');
  if (!config.pgOpsUrl) throw new Error('未配置 PG_OPS_URL');

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

  const id = randomUUID();
  await client.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      `INSERT INTO app_user (id, name, phone, role, avatar)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (phone) DO NOTHING
       RETURNING id`,
      [id, name, phone, role, role === 'student' ? 'student' : 'parent']
    );
    if (rows.length === 0) throw new Error('该手机号已存在，未做任何修改');
    await client.query(
      'INSERT INTO app_user_credential (user_id, password_hash) VALUES ($1, $2)',
      [id, hashPassword(password)]
    );
    await client.query('COMMIT');
    console.log(`[create-user] 已创建：id=${id} phone=${phone} role=${role}`);
    console.log('[create-user] 口令已哈希落库，未打印、未写文件');
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    await client.end();
  }
}

main().catch((err) => {
  console.error('[create-user] 失败：', err.message);
  process.exitCode = 1;
});
