#!/usr/bin/env node
/**
 * 列出**云端 RDS 库**里的账号 —— `list-accounts.mjs` 的云端孪生兄弟。
 *
 * ── 为什么需要它 ────────────────────────────────────────────────────────────
 *
 * 项目里有**两份互不相通的库**（见 README「两种模式 = 两个互不相通的库」）：
 *   · 本机演示栈（`npm run dev:stack`，端口 55433）← `list-accounts.mjs` 管这个
 *   · 云端 RDS（`easylearn_db`）              ← 本脚本管这个
 *
 * 客户端连哪一份由**构建期**的 `DATA_API_BASE_URL` 决定 —— 所以「我注册的账号
 * 说没有注册」几乎总是「换了模式构建的客户端」，而回答这个问题需要能分别列出
 * 两侧的账号。`list-accounts.mjs` 硬编码 `127.0.0.1:55433`，对云端无能为力。
 *
 * ⚠️ **只读**，不写任何东西。
 *
 * ── 顺带的一个用途 ──────────────────────────────────────────────────────────
 *
 * 验 `POST /auth/login` 时必须用**这个库里真实存在的账号**（doc/aliyun-deploy-plan.md
 * §7.1：拿本地模式的账号去试会得到 401，而那**看起来像 VPC 配错了**）。
 * 所以「部署后拿什么账号去登录」这个问题由本脚本回答。
 *
 * 用法：
 *   node serverless/data-service/scripts/cloud-accounts.mjs
 *   ENV_FILE=.env.local node serverless/data-service/scripts/cloud-accounts.mjs
 *
 * 用 `PG_OPS_USER`（管理员，`rolbypassrls`）连 —— **故意**不用 `app_rls`：
 * 后者受 RLS 限制，看到的是一个**被过滤过的**名单，拿去当「库里有哪些账号」的
 * 答案会漏人，而漏掉不报错。
 */
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { Client } from 'pg';

import { cloudHost, loadEnv } from './lib/env-file.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../../..');

const envFile = process.env.ENV_FILE || '.env.prod';
const { env } = loadEnv(resolve(ROOT, envFile));

const client = new Client({
  // ⚠️ 走 `cloudHost()` = **外网端点**：本脚本在 VPC 外跑。见 `lib/env-file.mjs`。
  host: cloudHost(env),
  port: Number(env.PGPORT || 5432),
  database: env.PGDATABASE,
  user: env.PG_OPS_USER,
  password: env.PG_OPS_PASSWORD,
  // ⚠️ 与 app 保持一致：PGSSLMODE 是**单点**定义，别在这里另写一套判断。
  ssl: env.PGSSLMODE === 'require' ? { rejectUnauthorized: false } : undefined,
});

try {
  await client.connect();
} catch (e) {
  console.error(`✗ 连不上云端库 ${cloudHost(env)}/${env.PGDATABASE}：${e?.message ?? e}`);
  process.exit(1);
}

try {
  // ⚠️ `app_user` 上**没有** `created_at`（实测：`column u.created_at does not exist`）。
  //    本机的 `list-accounts.mjs` 早就用「先探列」绕过了这个，这里照做 ——
  //    直接写死列名会在**连上之后**才炸，而报错长得像「库结构不对」，
  //    容易误判成迁移没跑（迁移是好的，只是不同版本列不一样）。
  const cols = await client.query(
    `select column_name from information_schema.columns
      where table_name = 'app_user' and column_name = 'created_at'`,
  );
  const hasCreatedAt = cols.rows.length > 0;

  const { rows } = await client.query(`
    select u.id, u.name, u.phone, u.role, ${hasCreatedAt ? 'u.created_at,' : ''}
           (k.user_id is not null) as has_password
      from app_user u
      left join app_user_credential k on k.user_id = u.id
     order by u.role, u.phone nulls last
  `);

  console.log(`\n▸ 云端库 ${cloudHost(env)}/${env.PGDATABASE}（以 ${env.PG_OPS_USER} 身份读，不受 RLS 过滤）`);
  console.log(`  共 ${rows.length} 个账号\n`);

  if (rows.length === 0) {
    console.log('  （空）');
    console.log('');
    console.log('⚠️ 库里一个账号都没有 —— 这时 `POST /auth/login` 用**任何**手机号都回');
    console.log('   401「手机号、密码或身份不正确」，而那个 401 **不能**用来判断');
    console.log('   「VPC 通没通」（§7.1）。先去注册一个真账号：');
    console.log('     curl -s -X POST https://<数据服务域名>/auth/register \\');
    console.log(`       -H 'content-type: application/json' \\`);
    console.log(`       -d '{"phone":"13800000001","password":"abc123","name":"虫子","role":"student"}'`);
  } else {
    for (const u of rows) {
      console.log(`  ${String(u.name ?? '(无名)').padEnd(12)} ${String(u.phone ?? '(无手机号)').padEnd(14)}` +
        ` ${String(u.role ?? '-').padEnd(9)} ${u.has_password ? '有密码' : '无密码（微信类）'}`);
      console.log(`    id=${u.id}`);
    }
    console.log('');
    console.log('→ 验登录判据时，**从这里挑一个**（`has_password` 必须是「有密码」的那类）。');
  }
  console.log('');
} finally {
  await client.end();
}
