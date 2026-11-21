import { resolve } from 'node:path';
import { Client } from 'pg';
import { cloudHost, loadEnv } from './lib/env-file.mjs';

const ROOT = resolve(import.meta.dirname, '../../..');
const { env } = loadEnv(resolve(ROOT, '.env.prod'));

const client = new Client({
  host: cloudHost(env),
  port: Number(env.PGPORT || 5432),
  database: env.PGDATABASE,
  user: env.PG_OPS_USER,
  password: env.PG_OPS_PASSWORD,
  ssl: env.PGSSLMODE === 'require' ? { rejectUnauthorized: false } : undefined,
});
await client.connect();

const hwIds = process.argv.slice(2).length ? process.argv.slice(2) : ['cc216d8a', 'c2b9f1bf'];

const h = await client.query(`
  select id::text as id, subject, title, score, checked_at, submitted_at, student_id::text as sid
    from homework
   where id::text like any($1::text[])
   order by submitted_at desc
`, [hwIds.map((id) => `${id}%`)]);
console.log('═══ 作业 ═══');
console.table(h.rows);

const m = await client.query(`
  select h.id::text as hw_id, h.title, h.score,
         m.id::text as mistake_id,
         m.knowledge_point, m.original_answer, m.wrong_reason, m.created_at
    from homework h
    left join review_mistake m on m.homework_id = h.id
   where h.id::text like any($1::text[])
   order by h.submitted_at desc, m.created_at
`, [hwIds.map((id) => `${id}%`)]);
console.log('\n═══ 错题（阿里的批改结果）═══');
if (m.rowCount === 0) console.log('(无错题记录)');
else console.table(m.rows.map((r) => ({
  hw: r.hw_id.slice(0, 8),
  title: r.title,
  score: r.score,
  knowledge_point: String(r.knowledge_point || '').slice(0, 20),
  original_answer: String(r.original_answer || '').replace(/\s+/g, ' ').slice(0, 40),
  wrong_reason: String(r.wrong_reason || '').replace(/\s+/g, ' ').slice(0, 80),
  created_at: r.created_at?.toISOString?.(),
})));

await client.end();
