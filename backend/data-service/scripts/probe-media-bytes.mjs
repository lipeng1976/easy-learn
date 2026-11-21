#!/usr/bin/env node
/**
 * 【只读探针】**把库里真实存着的音视频字节取出来看一眼**（列行 + 嗅探格式）。
 *
 * 与 `probe-media-e2e.mjs` 的分工：那支**造**数据走一遍链路（上传→读回→清理），
 * 这支**看**库里现有的是什么 —— 当客户端说「这个文件播不了」时，第一步要回答的
 * 是「服务端那份字节本身是不是好的、大小对不对、是不是它说的那个格式」。
 *
 * 2026-10-03 就是靠它把「音频播不出」里的**文件那一支**排除掉的：
 * 2,816,702 B 与行里记的大小一致、头部是 `ID3`、sha256 稳定 ⇒ 文件是好的，
 * 问题在播放器那条路（见 `doc/open-items.md` B34）。
 *
 * ⚠️ 只读：只 select + 从对象存储 get，不写任何东西。
 * ⚠️ `fetch failed` 之类的一次性网络错误在本项目是已知现象，原样重试即可。
 */
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';

import { Client } from 'pg';

import { createOssImageStore } from '../src/ossimagestore.js';
import { cloudHost, loadEnv } from './lib/env-file.mjs';

const ROOT = resolve(import.meta.dirname, '../../..');
const { env } = loadEnv(resolve(ROOT, process.env.ENV_FILE || '.env.prod'));

function sniff(buf) {
  const hex = buf.subarray(0, 16).toString('hex');
  const ascii = buf.subarray(0, 12).toString('latin1').replace(/[^\x20-\x7e]/g, '.');
  let guess = '?';
  if (buf.length >= 3 && buf.subarray(0, 3).toString('latin1') === 'ID3') guess = 'MP3 (ID3 头)';
  else if (buf[0] === 0xff && (buf[1] & 0xe0) === 0xe0) guess = 'MPEG 音频帧同步 (0xFFEx)';
  else if (buf.subarray(4, 8).toString('latin1') === 'ftyp') guess = `ISO-BMFF (${buf.subarray(8, 12).toString('latin1')})`;
  else if (buf.subarray(0, 4).toString('latin1') === 'OggS') guess = 'Ogg';
  else if (buf.subarray(0, 4).toString('latin1') === 'RIFF') guess = `RIFF/${buf.subarray(8, 12).toString('latin1')}`;
  else if (buf.subarray(0, 5).toString('latin1') === '#!AMR') guess = 'AMR';
  else if (hex.startsWith('1a45dfa3')) guess = 'Matroska/WebM';
  return { guess, hex, ascii };
}

const client = new Client({
  host: cloudHost(env),
  port: Number(env.PGPORT || 5432),
  database: env.PGDATABASE,
  user: env.PG_OPS_USER,
  password: env.PG_OPS_PASSWORD,
  ssl: env.PGSSLMODE === 'require' ? { rejectUnauthorized: false } : undefined,
});
await client.connect();

const cols = await client.query(
  `select column_name from information_schema.columns where table_name='homework_image' order by ordinal_position`,
);
const names = cols.rows.map((r) => r.column_name);
console.log(`▸ homework_image 列：${names.join(', ')}`);

const orderBy = names.includes('created_at') ? 'created_at desc nulls last'
  : names.includes('sort_order') ? 'sort_order desc' : 'id';
const sizeCol = names.includes('file_size') ? 'file_size' : 'null::int as file_size';

const rows = await client.query(
  `select id, student_id, homework_id, storage_key, file_name, ${sizeCol},
          mime_type, batch_id
     from homework_image
    order by ${orderBy}
    limit 60`,
);

const media = rows.rows.filter((r) => /^(audio|video)\//.test(r.mime_type ?? ''));
console.log(`\n▸ 最近 ${rows.rowCount} 行里，音视频 ${media.length} 条\n`);
for (const r of rows.rows) {
  const tag = /^audio\//.test(r.mime_type ?? '') ? 'AUDIO' : /^video\//.test(r.mime_type ?? '') ? 'VIDEO' : '     ';
  console.log(`  ${tag} ${String(r.mime_type ?? '-').padEnd(12)} ${String(r.file_size ?? '-').padStart(9)} `
    + `${String(r.file_name ?? '-').slice(0, 26).padEnd(28)} ${String(r.storage_key).slice(0, 46)}`);
}

if (media.length === 0) {
  console.log('\n⚠️ 库里没有音视频附件 —— 那真机上播的那条是本地草稿，不是服务端这条。');
  await client.end();
  process.exit(0);
}

const store = createOssImageStore({
  bucket: env.OSS_BUCKET,
  region: env.OSS_REGION,
  endpoint: env.OSS_ENDPOINT,
  accessKeyId: env.OSS_ACCESS_KEY_ID,
  accessKeySecret: env.OSS_ACCESS_KEY_SECRET,
  prefix: env.OSS_PREFIX ?? '',
});

console.log('\n▸ 逐条取回真实字节（服务端签名直读，与 App 走的同一个对象）\n');
const doneKinds = new Set();
for (const r of media) {
  const kind = (r.mime_type ?? '').startsWith('audio/') ? 'AUDIO' : 'VIDEO';
  if (doneKinds.has(kind)) continue; // 每类抽一条就够
  doneKinds.add(kind);
  let buf = null;
  try {
    buf = await store.get(r.storage_key);
  } catch (e) {
    console.log(`  ✗ ${kind} ${String(r.id).slice(0, 8)} 取不回：${e.message}`);
    continue;
  }
  const s = sniff(buf);
  const recSize = r.file_size == null ? null : Number(r.file_size);
  const sizeOk = recSize == null ? '（行里没记大小）' : recSize === buf.length ? '一致' : `**不一致（行里 ${recSize}）**`;
  console.log(`  ${kind} id=${String(r.id).slice(0, 8)} ${r.file_name}`);
  console.log(`      mime=${r.mime_type}  实收=${buf.length} B  行里大小=${recSize ?? '-'} → ${sizeOk}`);
  console.log(`      首 16 字节 hex=${s.hex}  ascii="${s.ascii}"`);
  console.log(`      嗅探=${s.guess}  sha256=${createHash('sha256').update(buf).digest('hex').slice(0, 16)}`);
  if (kind === 'AUDIO') {
    console.log(`      末 8 字节 hex=${buf.subarray(Math.max(0, buf.length - 8)).toString('hex')}`);
  }
}

await client.end();
