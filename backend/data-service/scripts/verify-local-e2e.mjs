// 端到端验收：本机数据服务 + 本机 PG + 本机附件目录，走真 HTTP。
//
// ── 它验证的是一条完整的用户路径 ────────────────────────────────────────
// 登录 → 读作业列表 → 读附件清单 → 取一张图的字节。
// 只查库不够：`/data/homework/images/file` 走的是 fs 后端，
// 「库里行数对、文件却读不出来」只有走一遍 HTTP 才能发现。
//
// ── 关于临时改密 ───────────────────────────────────────────────────────
// 真实账号的口令人不知道，所以这里做一次**可还原**的临时改密：
// 备份 hash → 设成 abc123 → 登录 → 最后在 finally 里**逐字还原并复核**。
// 只动本地副本，云端一行不碰。
//
// 用法：
//   node scripts/verify-local-e2e.mjs
//   node scripts/verify-local-e2e.mjs --base=http://127.0.0.1:8788 --student=<uuid> --phone=...
import fs from 'node:fs';
import path from 'node:path';
import pg from 'pg';
import { hashPassword } from '../src/password.js';

const argOf = (name, fallback = '') => {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : fallback;
};

const BASE = argOf('base', 'http://127.0.0.1:8788');
const STUDENT = argOf('student', '2654d216-ffd9-4b2a-aca4-01cdc83858f8');
const PHONE = argOf('phone', '18570346120');
const LOCAL_PORT = Number(argOf('local-port', '5433'));

function loadEnv(file) {
  const out = {};
  if (!fs.existsSync(file)) return out;
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const i = t.indexOf('=');
    if (i > 0) out[t.slice(0, i).trim()] = t.slice(i + 1);
  }
  return out;
}

const env = loadEnv(path.resolve('../../.env.prod'));

const db = new pg.Client({
  host: '127.0.0.1',
  port: LOCAL_PORT,
  database: env.PGDATABASE,
  user: env.PG_OPS_USER,
  password: env.PG_OPS_PASSWORD,
});
await db.connect();

const before = (
  await db.query('select password_hash from app_user_credential where user_id=$1', [STUDENT])
).rows[0]?.password_hash;
if (!before) {
  console.error('没找到该账号的凭证行');
  process.exit(1);
}
console.log(`已备份原口令哈希（长度 ${before.length}）`);

let failed = null;
let restoredOk = true;
try {
  await db.query('update app_user_credential set password_hash=$2 where user_id=$1', [
    STUDENT,
    await hashPassword('abc123'),
  ]);

  const loginRes = await fetch(`${BASE}/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ phone: PHONE, password: 'abc123' }),
    signal: AbortSignal.timeout(20000),
  });
  const login = await loginRes.json();
  console.log(`\n登录 http=${loginRes.status} ok=${login.ok}`);
  if (!login.ok) throw new Error(`登录失败：${JSON.stringify(login.error)}`);
  const token = login.data?.token ?? login.data?.session?.token;
  if (!token) throw new Error(`登录响应里没有 token：${Object.keys(login.data ?? {})}`);

  const h = { authorization: `Bearer ${token}` };

  // limit 必须显式给：默认 50 是分页上限，不是数据条数。
  const hwRes = await fetch(`${BASE}/data/homework?limit=200`, {
    headers: h,
    signal: AbortSignal.timeout(20000),
  });
  const hw = await hwRes.json();
  const hwList = hw.data?.items ?? hw.data?.homework ?? [];
  console.log(`作业列表 http=${hwRes.status} 条数=${hwList.length}`);
  if (!hw.ok) throw new Error(`作业列表失败：${JSON.stringify(hw.error)}`);
  if (hwList.length !== 88) throw new Error(`作业条数 ${hwList.length}，期望 88`);

  const imgRes = await fetch(`${BASE}/data/homework/images`, {
    headers: h,
    signal: AbortSignal.timeout(20000),
  });
  const img = await imgRes.json();
  const imgList = img.data?.items ?? [];
  console.log(`附件列表 http=${imgRes.status} 条数=${imgList.length}`);
  if (!img.ok) throw new Error(`附件列表失败：${JSON.stringify(img.error)}`);

  const first = imgList[0];
  if (first?.id) {
    const expect = first.fileSize ?? first.file_size;
    const fRes = await fetch(
      `${BASE}/data/homework/images/file?id=${encodeURIComponent(first.id)}`,
      { headers: h, signal: AbortSignal.timeout(30000) },
    );
    const buf = Buffer.from(await fRes.arrayBuffer());
    console.log(`取图 http=${fRes.status} bytes=${buf.length} 库里=${expect}`);
    if (fRes.status !== 200) throw new Error(`取图失败 http=${fRes.status}`);
    if (buf.length !== expect) throw new Error(`取图字节 ${buf.length} ≠ 库里 ${expect}`);
  }

  console.log('\n✅ 端到端链路通：登录 → 读作业 → 读附件清单 → 取图字节一致');
} catch (e) {
  failed = e;
  console.error(`\n❌ ${e.message}`);
} finally {
  await db.query('update app_user_credential set password_hash=$2 where user_id=$1', [STUDENT, before]);
  const after = (
    await db.query('select password_hash from app_user_credential where user_id=$1', [STUDENT])
  ).rows[0].password_hash;
  restoredOk = after === before;
  console.log(`\n口令已还原：${restoredOk ? '✅ 与原值逐字一致' : '🔴 不一致！'}`);
  await db.end();
  if (failed || !restoredOk) process.exitCode = 1;
}
