#!/usr/bin/env node
/**
 * 【临时只读探针】量这批错题的「爆炸半径」。
 *
 * 已证实：视觉档模型在算式核对上不可靠，会把做对的题判成错、并把它写进错题库。
 * 那就要问：**已经有多少条这样的错题进了库？** 这决定这件事的优先级。
 *
 * 判据分两档，从「模型自己承认判错」这一档开始 —— 它不需要我复核，最硬：
 *   A 档 · 自我矛盾：wrong_reason 里模型自己写着「其实做对了 / 不应判错 / 碰巧对了」
 *   B 档 · 口径错位：把「书写不规范」类投诉写进了 items
 *        （漏单位 / 没写答句 / 书写 / 不够完整 / 不严谨）—— 按项目口径应进 formatIssues
 * ⚠️ 只读。用完即删。
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

const A = '其实做对了|做对了！|不应判错|不应放入错题|不应进|碰巧对了|碰巧也对了|经复核该题解答正确|此处应移除';
const B = '漏写单位|没写单位|未写单位|漏单位|没写答句|未写答句|书写|不够完整|不严谨|不规范|格式问题|跳步';

try {
  const tot = await client.query(`
    select count(*)::int as n,
           min(created_at) as first_at,
           max(created_at) as last_at,
           count(distinct student_id)::int as students,
           count(distinct homework_id)::int as homeworks
      from review_mistake
  `);
  const t = tot.rows[0];
  console.log(`\n▸ review_mistake 全表：${t.n} 条  学生 ${t.students} 人  作业 ${t.homeworks} 份`);
  console.log(`  时间跨度 ${t.first_at?.toISOString?.()} → ${t.last_at?.toISOString?.()}`);

  const a = await client.query(
    `select id, created_at, subject, knowledge_point, title, original_answer, wrong_reason
       from review_mistake
      where wrong_reason ~ $1
      order by created_at desc`,
    [A],
  );
  console.log(`\n██ A 档 · 模型自己在错因里承认「这题做对了」（最硬的一档）：${a.rowCount} 条`);
  for (const r of a.rows) {
    console.log(`\n  ${r.created_at?.toISOString?.()}  ${r.subject ?? '-'} · ${r.title ?? '-'}`);
    console.log(`  学生答：${JSON.stringify(r.original_answer)}`);
    console.log(`  错因  ：${String(r.wrong_reason).replace(/\s+/g, ' ').slice(0, 240)}`);
  }

  const b = await client.query(
    `select count(*)::int as n
       from review_mistake
      where wrong_reason ~ $1`,
    [B],
  );
  console.log(`\n██ B 档 · 错因是「书写/格式」类投诉（按项目口径本应进 formatIssues）：${b.rows[0].n} 条`);

  const daily = await client.query(`
    select date_trunc('day', created_at)::date as d, count(*)::int as n
      from review_mistake
     group by 1 order by 1 desc limit 10
  `);
  console.log('\n██ 按天分布');
  for (const r of daily.rows) console.log(`  ${r.d}  ${r.n} 条`);
  console.log('');
} finally {
  await client.end();
}
