#!/usr/bin/env node
/**
 * 【临时只读探针】列出库里可用的作业照片 —— 为「批改矩阵」找**多题型**素材。
 *
 * 目的：现有定标素材只有数学「有理数乘法」一个题型（P28/P29 同一本练习册）。
 * 要把「把 homeworkCheck 挪到 light 档」这条修法的证据做实，需要**别的科目/别的题型**。
 *
 * ⚠️ 只读（全部 select）。不下载图片，只列 storage key / 作业元信息，
 *    由人先看一眼再决定下哪几张 —— 避免把无关学生的作业照片批量拉下来。
 */
import { resolve } from 'node:path';

import { Client } from 'pg';

import { cloudHost, loadEnv } from './lib/env-file.mjs';

const ROOT = resolve(import.meta.dirname, '../../..');
const { env } = loadEnv(resolve(ROOT, process.env.ENV_FILE || '.env.prod'));

const client = new Client({
  host: cloudHost(env),
  port: Number(env.PGPORT || 5432),
  database: env.PGDATABASE,
  user: env.PG_OPS_USER,
  password: env.PG_OPS_PASSWORD,
  ssl: env.PGSSLMODE === 'require' ? { rejectUnauthorized: false } : undefined,
});
await client.connect();

try {
  const hw = await client.query(`
    select h.id, h.student_id, h.subject, h.title, h.score, h.due_at, h.submitted_at, h.checked_at,
           (select count(*) from homework_image i where i.homework_id = h.id)::int as imgs
      from homework h
     order by h.submitted_at desc nulls last
  `);
  console.log(`\n▸ homework 全表 ${hw.rowCount} 份\n`);
  console.log('  id         学生         科目   标题                 分数  照片  submitted_at');
  for (const r of hw.rows) {
    console.log(`  ${String(r.id).slice(0, 8)}   ${String(r.student_id).slice(0, 8)}   `
      + `${String(r.subject ?? '-').padEnd(5)} ${String(r.title ?? '-').slice(0, 18).padEnd(20)}`
      + `${String(r.score ?? '-').padEnd(5)} ${String(r.imgs).padEnd(4)} ${r.submitted_at?.toISOString?.() ?? '-'}`);
  }

  const bySubject = await client.query(`
    select coalesce(subject,'(空)') as subject, count(*)::int as n,
           count(distinct student_id)::int as students
      from homework group by 1 order by n desc
  `);
  console.log('\n▸ 按科目分布');
  for (const r of bySubject.rows) console.log(`   ${r.subject}  ${r.n} 份  ${r.students} 名学生`);

  const cols = await client.query(`
    select column_name, data_type from information_schema.columns
     where table_name = 'homework_image' order by ordinal_position
  `);
  console.log(`\n▸ homework_image 列：${cols.rows.map((r) => r.column_name).join(', ')}`);

  const imgs = await client.query(`
    select i.* from homework_image i order by i.file_size desc nulls last
  `);
  console.log(`\n▸ homework_image 全表 ${imgs.rowCount} 行（大→小）`);
  for (const r of imgs.rows) {
    const key = r.storage_key ?? r.object_key ?? r.key ?? '(无 key 列)';
    console.log(`   hw=${String(r.homework_id).slice(0, 8).padEnd(9)} student=${String(r.student_id ?? '-').slice(0, 8).padEnd(9)}`
      + ` ${String(key).padEnd(52)} ${r.mime_type ?? '-'} ${r.file_size ?? '-'}`);
  }
} finally {
  await client.end();
}
