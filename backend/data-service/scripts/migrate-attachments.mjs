// 附件迁移：OSS → 本机磁盘（按 storage_key 原样落盘）。
//
// ── 为什么按 key 原样落盘 ────────────────────────────────────────────────
// 本地 `IMAGE_DRIVER=fs` 的读取路径是 `path.resolve(IMAGE_ROOT_DIR, storageKey)`，
// 而 `storageKey` 形如 `20260925/stu_xxx/uuid.jpg`。所以只要把对象按同名相对路径
// 放下，切到 fs 后端后**代码零改动就能读到**（见 `src/imagestore.js` 的 fs 实现）。
//
// ── 判据（少一条都不算搬完）─────────────────────────────────────────────
// ① 每个文件的字节数必须等于库里的 `file_size`（不是「下载成功」就算）；
// ② 落到盘上的文件数必须等于 `homework_image` 的行数；
// ③ 库里记了但 OSS 没有的键，必须**显式列出来**（静默跳过 = 以为搬完了）。
//
// 用法：
//   node scripts/migrate-attachments.mjs --out=D:/easy_learn_home/attachments
//   node scripts/migrate-attachments.mjs --dry            # 只列清单不下载
//   node scripts/migrate-attachments.mjs --limit=5        # 试跑前 5 个
import fs from 'node:fs';
import path from 'node:path';
import pg from 'pg';
import { createOssImageStore } from '../src/ossimagestore.js';
import { cloudHost } from './lib/env-file.mjs';

// ── 读 .env.prod（只取迁移需要的键）────────────────────────────────────
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

const argOf = (name, fallback = '') => {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : fallback;
};
const hasFlag = (name) => process.argv.includes(`--${name}`);

const env = {
  ...loadEnv(path.resolve('../../.env.prod')),
  ...loadEnv(path.resolve('../../.env.local')),
  ...loadEnv(path.resolve('../../.env')),
};

const OUT = path.resolve(argOf('out', 'D:/easy_learn_home/attachments'));
const DRY = hasFlag('dry');
const LIMIT = Number(argOf('limit', '0')) || 0;
const CONCURRENCY = Number(argOf('concurrency', '4')) || 4;

const db = new pg.Client({
  // 统一走 `cloudHost()`：内网/外网端点由那一处决定，
  // 各脚本自己写 `PGHOST_EXTERNAL || PGHOST` 迟早会漂成几种不同顺序。
  host: cloudHost(env),
  port: Number(env.PGPORT ?? 5432),
  database: env.PGDATABASE,
  // ⚠️ 必须用 BYPASSRLS 的角色：用 app_rls 读会被 RLS 过滤成「只有自己可见的几张」，
  // 表现是「迁移成功」但少了一大半 —— 这是本项目最容易静默出错的地方。
  user: env.PG_OPS_USER,
  password: env.PG_OPS_PASSWORD,
  ssl: env.PGSSLMODE === 'require' ? { rejectUnauthorized: false } : false,
  connectionTimeoutMillis: 15000,
});

const store = createOssImageStore({
  bucket: env.OSS_BUCKET,
  region: env.OSS_REGION,
  endpoint: env.OSS_ENDPOINT,
  accessKeyId: env.OSS_ACCESS_KEY_ID,
  accessKeySecret: env.OSS_ACCESS_KEY_SECRET,
  prefix: env.OSS_PREFIX ?? '',
});

await db.connect();
const { rows } = await db.query(
  `select storage_key, file_size, mime_type, student_id, created_at
     from homework_image order by created_at`,
);
await db.end();

const targets = LIMIT > 0 ? rows.slice(0, LIMIT) : rows;
console.log(`附件记录 ${rows.length} 条${LIMIT ? `，本次只处理前 ${targets.length} 条` : ''}`);
console.log(`输出目录 ${OUT}`);
console.log(`合计字节 ${rows.reduce((s, r) => s + (r.file_size ?? 0), 0).toLocaleString()}`);

if (DRY) {
  for (const r of targets) console.log(`  ${r.storage_key}  ${r.file_size} B  ${r.mime_type}`);
  console.log('\n（--dry：只列清单，未下载）');
  process.exit(0);
}

const result = { ok: 0, same: 0, sizeMismatch: [], missing: [], failed: [], bytes: 0 };

async function fetchOne(r) {
  const dest = path.join(OUT, r.storage_key);
  fs.mkdirSync(path.dirname(dest), { recursive: true });

  // 已存在且字节数对得上 → 跳过（断点续搬，重跑不会重复下载）
  if (fs.existsSync(dest) && fs.statSync(dest).size === r.file_size) {
    result.same += 1;
    result.bytes += r.file_size;
    return;
  }

  let bytes;
  try {
    bytes = await store.get(r.storage_key);
  } catch (e) {
    if (e?.code === 'not_found' || /NoSuchKey|404/.test(String(e?.message))) {
      result.missing.push(r.storage_key);
    } else {
      result.failed.push({ key: r.storage_key, error: String(e?.message ?? e) });
    }
    return;
  }

  fs.writeFileSync(dest, bytes);
  const actual = fs.statSync(dest).size;
  // ⭐ 判据是「字节数对得上」，不是「文件写出来了」。截断/损坏只有这条能发现。
  if (actual !== r.file_size) {
    result.sizeMismatch.push({ key: r.storage_key, expect: r.file_size, actual });
  } else {
    result.ok += 1;
    result.bytes += actual;
  }
}

// 有限并发：OSS 出网带宽是瓶颈，串行太慢，无上限又容易被限流。
let cursor = 0;
const workers = Array.from({ length: CONCURRENCY }, async () => {
  while (cursor < targets.length) {
    const i = cursor;
    cursor += 1;
    await fetchOne(targets[i]);
    if ((result.ok + result.same) % 25 === 0) {
      console.log(`  进度 ${result.ok + result.same}/${targets.length}`);
    }
  }
});
await Promise.all(workers);

console.log('\n════════ 结果 ════════');
console.log(`新下载        ${result.ok}`);
console.log(`已存在跳过    ${result.same}`);
console.log(`已落盘合计    ${result.ok + result.same} / ${targets.length}`);
console.log(`传输字节      ${result.bytes.toLocaleString()}`);
if (result.sizeMismatch.length) {
  console.log(`\n🔴 字节数不符 ${result.sizeMismatch.length} 个：`);
  for (const m of result.sizeMismatch) console.log(`  ${m.key}  期望 ${m.expect} 实际 ${m.actual}`);
}
if (result.missing.length) {
  console.log(`\n🔴 OSS 里不存在 ${result.missing.length} 个：`);
  for (const k of result.missing) console.log(`  ${k}`);
}
if (result.failed.length) {
  console.log(`\n🔴 失败 ${result.failed.length} 个：`);
  for (const f of result.failed) console.log(`  ${f.key}  ${f.error}`);
}
const clean =
  result.sizeMismatch.length === 0 &&
  result.missing.length === 0 &&
  result.failed.length === 0 &&
  result.ok + result.same === targets.length;
console.log(`\n${clean ? '✅ 判据全过' : '❌ 判据未过（见上）'}`);
process.exitCode = clean ? 0 : 1;
