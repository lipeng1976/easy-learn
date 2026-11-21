#!/usr/bin/env node
/**
 * **真实词表探针**：拿真 ima 凭证 + 真库读 `教学资料/Wordlist` 下的 MD，
 * 走一遍 `findFolderByPath → listAllEntries → downloadMedia → parseWordlist`。
 *
 * 目的不是替代单测，而是回答「家长放进 ima 的那份 MD，服务端到底认不认」。
 * 端到端冒烟（`probe-word-e2e`）用的是手工插库的书，绕过了 ima 这一层，
 * 所以「导入区一片空白」这类问题它看不见 —— 2026-11-12 就是这样发现
 * 目录名是 `wordlist`（小写）而代码找 `Wordlist` 的。
 *
 * 用法：
 *   node scripts/probe-word-ima.mjs --env-file D:/easy_learn_home/config/local.env \
 *     --student <学生id> --parent <家长id>
 * 只读：不写库、不改 ima 内容。
 */
import pg from 'pg';

import { IMA_MEDIA_TYPE_MARKDOWN, downloadMedia } from '../src/ima_openapi.js';
import { flattenEntries, parseWordlist, titleFromFileName } from '../src/word_import.js';
import { findFolderByPath, listAllEntries, resolveReaderContext } from '../src/routes/reading.js';
import { cloudHost, loadEnv, valueOf } from './lib/env-file.mjs';

const args = process.argv.slice(2);
const { env } = loadEnv(valueOf(args, '--env-file'));
const studentId = valueOf(args, '--student') ?? '';

for (const k of Object.keys(env)) {
  if (k.startsWith('IMA_') || k.startsWith('PG')) process.env[k] = env[k];
}

const client = new pg.Client({
  host: cloudHost(env),
  port: Number(env.PGPORT ?? 5432),
  database: env.PGDATABASE ?? 'easy_learn',
  user: env.PG_OPS_USER || env.PGUSER,
  password: (env.PG_OPS_USER ? env.PG_OPS_PASSWORD : env.PGPASSWORD),
  ...(env.PGSSLMODE === 'require' ? sslOpt() : {}),
});

function sslOpt() {
  return { ssl: { rejectUnauthorized: false } };
}

const ctx = {
  userId: valueOf(args, '--parent') ?? '',
  role: 'parent',
  visibleStudents: [studentId],
  fetchImpl: fetch,
};

await client.connect();
try {
  const reader = await resolveReaderContext(client, ctx, studentId);
  if (!reader) {
    console.log('ima 上下文不可用（未开通 / 密钥缺失 / 表没迁移）');
    process.exit(2);
  }
  console.log(`读者 kbId=${reader.kbId}`);

  const folder = await findFolderByPath(reader, ['教学资料', 'Wordlist']);
  if (!folder) {
    console.log('找不到 教学资料/Wordlist');
    process.exit(3);
  }
  console.log(`找到目录 media_id=${folder.media_id} title=${folder.title ?? ''}`);

  const entries = await listAllEntries(reader, { kbId: reader.kbId, folderId: folder.media_id });
  console.log(`目录下条目 ${entries.length} 个：`);
  for (const item of entries) {
    console.log(`  - ${item.title ?? '(无标题)'} type=${item.media_type ?? item.mediaType} id=${item.media_id}`);
  }

  const mds = entries.filter(
    (item) => Number(item.media_type ?? item.mediaType) === IMA_MEDIA_TYPE_MARKDOWN,
  );
  if (mds.length === 0) {
    console.log('目录里没有 md 文件');
    process.exit(4);
  }

  for (const md of mds) {
    const fileName = String(md.title ?? 'words.md');
    const { bytes } = await downloadMedia({
      clientId: reader.clientId,
      apiKey: reader.apiKey,
      kbId: reader.kbId,
      mediaId: md.media_id,
      maxBytes: 2 * 1024 * 1024,
      fetchImpl: fetch,
    });
    const text = bytes.toString('utf8');
    const parsed = parseWordlist(text, { title: titleFromFileName(fileName, '') });
    const rows = flattenEntries(parsed);
    console.log(`\n=== ${fileName}（${bytes.length} 字节）===`);
    console.log(`标题=${parsed.title} 单元=${parsed.units.length} 词条=${rows.length} 警告=${parsed.warnings.length}`);
    if (parsed.warnings.length) {
      for (const w of parsed.warnings.slice(0, 5)) console.log(`  ! ${w}`);
    }
    for (const unit of parsed.units.slice(0, 3)) {
      console.log(`  ${unit.unit}：${unit.entries.length} 词，前 3：${unit.entries.slice(0, 3).map((e) => `${e.word}=${e.primaryMeaning}`).join(' / ')}`);
    }
    if (parsed.units.length > 3) {
      const last = parsed.units[parsed.units.length - 1];
      console.log(`  … 末单元 ${last.unit}：${last.entries.length} 词`);
    }
  }
} finally {
  await client.end();
}
