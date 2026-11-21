#!/usr/bin/env node
/**
 * 错题档案导出 —— 服务端 PG → markdown（供 ima 知识库「错题档案」用）
 *
 * 用法：
 *   node tools/export-mistakes-ima.mjs [--student <id>] [--out <文件>] [--env <local.env>]
 *
 * 数据源是本机部署的服务端 PG（D:\easy_learn_home），不是手机本地库 ——
 * 手机沙盒里的 easy_learn_v2.db PC 上摸不到。
 *
 * 隐私口径：只放「知识点 + 题干 + 错因」，不放学生姓名、不放原题照片。
 *
 * 判据（导出后必须自查）：
 *   ① 输出的条目数 == 库里该学生的错题数（一行不多一行不少）；
 *   ② 每个知识点小节内的条目数与该知识点聚合行数一致；
 *   ③ 同义知识点被合并（「解一元一次方程/方程求解/解方程」只出现一次）。
 */

import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

const require = createRequire(import.meta.url);
// pg 是数据服务的依赖，复用同一份安装，不在仓库根重复装。
const PG_PATH = 'D:/workbuddy-project/projects/easy_learn_db/serverless/data-service/node_modules/pg';
const { Client } = require(PG_PATH);

const DEFAULT_STUDENT = '2654d216-ffd9-4b2a-aca4-01cdc83858f8'; // 李雨霏
const DEFAULT_ENV = 'D:/easy_learn_home/config/local.env';

/**
 * 同义知识点归一表。
 *
 * 为什么需要它：knowledge_point 是错题录入时模型生成的**自由文本**，
 * 同一个概念会出现多个名字（已实测：「解一元一次方程」「方程求解」
 * 「解方程」三条并列）。不归一回直接导出，档案在 ima 里就是散的，
 * 加权选题也会把同一个弱项算成三个小项。
 *
 * 口径：只合并「名字不同、明显同一概念」的；归一到右侧的**已有名字**，
 * 不造新名字。拿不准的一律不合并 —— 合并错比不合并更糟。
 */
const KP_ALIAS = {
  解一元一次方程: '解一元一次方程',
  方程求解: '解一元一次方程',
  解方程: '解一元一次方程',
  列方程解应用题: '列方程解应用题',
  一元一次方程应用: '列方程解应用题',
  和倍问题: '列方程解应用题',
  相遇问题: '列方程解应用题',
  有理数乘除: '有理数乘除与混合运算',
  有理数乘除混合运算: '有理数乘除与混合运算',
  有理数加减: '有理数加减与混合运算',
  有理数加减混合运算: '有理数加减与混合运算',
  有理数乘方运算: '幂的运算',
  积的乘方逆运算: '幂的运算',
};

const STATE_LABEL = {
  pending: '待复习',
  reviewing: '复习中',
  mastered: '已掌握',
};

function parseArgs(argv) {
  const args = { student: DEFAULT_STUDENT, env: DEFAULT_ENV, out: null };
  for (let i = 2; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--student') args.student = argv[++i];
    else if (a === '--out') args.out = argv[++i];
    else if (a === '--env') args.env = argv[++i];
    else throw new Error(`未知参数：${a}`);
  }
  return args;
}

function readEnvFile(path) {
  const out = {};
  for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const m = /^([A-Z_][A-Z0-9_]*)=(.*)$/.exec(line.trim());
    if (m) out[m[1]] = m[2];
  }
  return out;
}

function normalizeKp(raw) {
  const kp = (raw ?? '').trim();
  if (kp === '') return '(未标注)';
  return KP_ALIAS[kp] ?? kp;
}

/**
 * 日期只保留 YYYY-MM-DD。
 *
 * ⚠️ 不能直接 `String(v).slice(0, 10)`：timestamptz 列经 pg 驱动返回的是
 * Date 对象，那样切出来是 "Sun Oct 25"（已实测）。这里按**本地时间**拼，
 * 不用 toISOString（UTC 会把晚上的记录算到第二天）。
 */
function dateOnly(v) {
  if (!v) return '';
  const d = v instanceof Date ? v : new Date(v);
  if (Number.isNaN(d.getTime())) return String(v).slice(0, 10);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function buildMarkdown(rows, exportedAt) {
  // 聚合：知识点 -> 条目
  const byKp = new Map();
  for (const r of rows) {
    const kp = normalizeKp(r.knowledge_point);
    if (!byKp.has(kp)) byKp.set(kp, []);
    byKp.get(kp).push(r);
  }
  // 排序：先按该知识点累计错误次数，再按条目数，都降序
  const groups = [...byKp.entries()].map(([kp, items]) => ({
    kp,
    items,
    totalWrong: items.reduce((s, r) => s + (r.wrong_count ?? 0), 0),
  }));
  groups.sort((a, b) => b.totalWrong - a.totalWrong || b.items.length - a.items.length);

  const lines = [];
  lines.push('# 错题档案（按知识点聚合）');
  lines.push('');
  lines.push(`- 导出于：${exportedAt}`);
  lines.push(`- 错题总数：${rows.length} 条；知识点：${groups.length} 个`);
  lines.push('- 说明：同一知识点下按错误次数降序；题干缺失的条目标注「（无题干）」。');
  lines.push('');
  lines.push('## 知识点总览');
  lines.push('');
  lines.push('| 知识点 | 条目数 | 累计错误次数 |');
  lines.push('| --- | --- | --- |');
  for (const g of groups) {
    lines.push(`| ${g.kp} | ${g.items.length} | ${g.totalWrong} |`);
  }
  lines.push('');

  for (const g of groups) {
    lines.push(`## ${g.kp}`);
    lines.push('');
    for (const r of g.items) {
      const title = (r.title ?? '').trim();
      const body = (r.question_body ?? '').trim();
      const stem = body !== '' ? body : title;
      const no = (r.question_no ?? '').trim();
      const head = [`### ${no !== '' ? `第 ${no} 题` : title || '（无标题）'}`];
      lines.push(...head);
      lines.push('');
      if (stem !== '') {
        lines.push(`- 题干：${stem.replace(/\s+/g, ' ').slice(0, 300)}`);
      } else {
        lines.push('- 题干：（无题干）');
      }
      const reason = (r.wrong_reason ?? '').trim();
      if (reason !== '') lines.push(`- 错因：${reason.replace(/\s+/g, ' ').slice(0, 300)}`);
      const answer = (r.answer_key ?? '').trim();
      if (answer !== '') lines.push(`- 正确答案：${answer.replace(/\s+/g, ' ').slice(0, 120)}`);
      const src = (r.source_homework_title ?? '').trim();
      if (src !== '') lines.push(`- 来源作业：${src}`);
      const state = STATE_LABEL[r.state] ?? r.state ?? '';
      lines.push(`- 状态：${state}；错误次数：${r.wrong_count ?? 1}；最近做错：${dateOnly(r.last_wrong_at) || dateOnly(r.created_at) || '未知'}`);
      lines.push('');
    }
  }
  return lines.join('\n');
}

async function main() {
  const args = parseArgs(process.argv);
  const env = readEnvFile(args.env);
  const client = new Client({
    host: env.PGHOST ?? '127.0.0.1',
    port: Number(env.PGPORT ?? 5433),
    database: env.PGDATABASE ?? 'easylearn_db',
    user: env.PG_OPS_USER ?? 'easylearn_admin',
    password: env.PG_OPS_PASSWORD ?? '',
  });
  await client.connect();
  try {
    const res = await client.query(
      `select id, subject, title, question_body, question_no, wrong_reason, answer_key,
              knowledge_point, wrong_count, last_wrong_at, created_at, state, source_homework_title
         from review_mistake
        where student_id = $1
        order by wrong_count desc, last_wrong_at desc nulls last, created_at desc`,
      [args.student],
    );
    const rows = res.rows;
    if (rows.length === 0) {
      console.error('EMPTY 该学生在库里没有错题，不生成文件（空文件会让 ima 解析出一条无内容条目）');
      process.exit(2);
    }
    const exportedAt = new Date().toISOString().slice(0, 19).replace('T', ' ');
    const md = buildMarkdown(rows, exportedAt);
    const out = resolve(
      args.out ??
        `D:/学习资料/数学/${exportedAt.slice(0, 10).replace(/-/g, '')}/错题档案-${exportedAt.slice(0, 10)}.md`,
    );
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, md, 'utf8');

    // 判据 ①：条目数
    const stemCount = md.split('\n').filter((l) => l.startsWith('- 题干：')).length;
    console.log('ROWS', rows.length);
    console.log('OUT', out);
    console.log('BYTES', Buffer.byteLength(md, 'utf8'));
    console.log('STEM_COUNT', stemCount);
    if (stemCount !== rows.length) {
      console.error('MISMATCH 题干行数与错题数不一致');
      process.exit(3);
    }
    // 判据 ③：同义词只剩一个名字
    const dupAlias = ['方程求解', '解方程', '一元一次方程应用', '有理数乘除混合运算'].filter(
      (alias) => new RegExp(`^## ${alias}$`, 'm').test(md),
    );
    if (dupAlias.length > 0) {
      console.error('ALIAS_LEFT', dupAlias.join(','));
      process.exit(4);
    }
    console.log('OK');
  } finally {
    await client.end();
  }
}

main().catch((e) => {
  console.error('FAIL', e.message);
  process.exit(1);
});
