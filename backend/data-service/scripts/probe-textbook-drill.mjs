#!/usr/bin/env node
/**
 * **教材章节出题的端到端冒烟** —— 真 HTTP + 真库 + 真模型。
 *
 * ## 为什么单开这一条（11-12 事故）
 *
 * 中国历史配好了教材（`subject_book` 22 节），家长点历史色块却每次都报
 * 「错题本还是空的」。原因不是错题本 —— 是**骨架 MD 里一行「考点：」都没有**，
 * 取点函数把整本书判成「没配考点」返回 null，再退回错题本；而历史这种
 * **还没学过所以不可能有错题**的科目，那条路根本不存在。
 *
 * 修法是「章节标题本身就是知识点」。这件事单测能证明，但证明不了三件真事：
 *   1. 真库里的教材行（summary 为空）能被取出来；
 *   2. 模型看见「第 1 课 远古时期的人类活动」这种标题，**真的**出得出
 *      choice / judge，且 `knowledge` 一字不差；
 *   3. 出完题 `subject_scope.start_unit_no` 真的往后推了 —— 不然天天考同一节。
 *
 * ## 用法
 *
 *   node scripts/probe-textbook-drill.mjs --env-file "D:/easy_learn_home/config/local.env"
 *
 * 自带清理：只碰手机号 `19900000009` 的冒烟账号，以及本次插入的
 * `tb_probe_*` 教材行和本次新出的卷子。
 * ⚠️ 消耗 1 次真实模型调用。
 */
import { randomUUID } from 'node:crypto';

import pg from 'pg';

import { cloudHost, loadEnv, valueOf } from './lib/env-file.mjs';

const BASE = (process.env.PROBE_BASE ?? 'http://127.0.0.1:8788').replace(/\/+$/, '');
const PASS = 'smoke123456';
const ACC = { phone: '19900000009', role: 'student', name: '教材出题冒烟' };
const SUBJECT = '历史';
/** 模拟真实的中国历史骨架：**只有章节标题，没有「考点：」行**。 */
const UNITS = [
  { unitNo: 1, title: '第 1 课 远古时期的人类活动' },
  { unitNo: 2, title: '第 2 课 原始农业与史前社会' },
];

const args = process.argv.slice(2);
const { env } = loadEnv(valueOf(args, '--env-file'));

const dbConfig = {
  host: cloudHost(env),
  port: Number(env.PGPORT ?? 5432),
  database: env.PGDATABASE ?? 'easy_learn',
  user: env.PG_OPS_USER || env.PGUSER,
  password: (env.PG_OPS_USER ? env.PG_OPS_PASSWORD : env.PGPASSWORD) ?? env.PGPASSWORD,
  ...(env.PGSSLMODE === 'require' ? { ssl: { rejectUnauthorized: false } } : {}),
};

let passed = 0;
const failures = [];

function ok(label, extra = '') {
  passed += 1;
  console.log(`  ✓ ${label}${extra ? `  ${extra}` : ''}`);
}

function fail(label, detail) {
  failures.push(`${label} —— ${detail}`);
  console.log(`  ✗ ${label}`);
  console.log(`      ${detail}`);
}

async function check(label, fn) {
  try {
    const detail = await fn();
    ok(label, detail ?? '');
  } catch (e) {
    fail(label, e?.message ?? String(e));
  }
}

function assert(cond, message) {
  if (!cond) throw new Error(message);
}

function todayLocal() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

async function call(method, path, { token, body } = {}) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    throw new Error(`${method} ${path} 返回的不是 JSON（HTTP ${res.status}）：${text.slice(0, 200)}`);
  }
  if (!res.ok || json?.ok === false) {
    const err = new Error(
      `${method} ${path} → HTTP ${res.status} ${json?.error?.code ?? ''} ${json?.error?.message ?? ''}`,
    );
    err.code = json?.error?.code;
    err.status = res.status;
    throw err;
  }
  return json?.data;
}

async function ensureAccount() {
  const login = async () => call('POST', '/auth/login', { body: { phone: ACC.phone, password: PASS } });
  try {
    return await login();
  } catch (e) {
    if (e.status !== 400 && e.status !== 401) throw e;
  }
  try {
    return await call('POST', '/auth/register', {
      body: { phone: ACC.phone, password: PASS, role: ACC.role, name: ACC.name },
    });
  } catch (e) {
    if (e.code === 'phone_taken' || e.status === 409) return login();
    throw e;
  }
}

async function main() {
  console.log(`教材章节出题冒烟 · ${BASE}`);

  const auth = await ensureAccount();
  const token = auth?.token ?? auth?.session?.token;
  const studentId = auth?.user?.id ?? auth?.user?.userId;
  assert(token, '登录没拿到 token');
  assert(studentId, '登录没拿到 user.id');

  const bookId = `tb_probe_${randomUUID().replace(/-/g, '').slice(0, 12)}`;
  const createdQuizIds = [];

  const client = new pg.Client(dbConfig);
  await client.connect();

  try {
    // 先清掉这个冒烟账号以前留下的探针数据（可能上次跑一半崩了）。
    await client.query("delete from subject_book where student_id = $1 and id like 'tb_probe_%'", [studentId]);

    await client.query(
      `insert into subject_book
         (id, student_id, subject, title, source, source_media_id, source_path, unit_count)
       values ($1, $2, $3, '中国历史·探针', 'ima', '', '', $4)`,
      [bookId, studentId, SUBJECT, UNITS.length],
    );
    for (const unit of UNITS) {
      await client.query(
        `insert into subject_unit (id, book_id, student_id, unit_no, title, summary, page_hint)
         values ($1, $2, $3, $4, $5, '', '')`,
        [`tu_probe_${randomUUID().replace(/-/g, '').slice(0, 12)}`, bookId, studentId, unit.unitNo, unit.title],
      );
    }
    // 每天 1 节、从第 1 节开始 —— 与家长在配置页选的一致。
    await client.query(
      `insert into subject_scope (student_id, subject, points, daily_count, difficulty,
                                  book_id, start_unit_no, units_per_day)
       values ($1, $2, '[]'::jsonb, 3, '基础', $3, 1, 1)
       on conflict (student_id, subject) do update
         set book_id = excluded.book_id, start_unit_no = 1, units_per_day = 1,
             points = '[]'::jsonb, daily_count = 3, difficulty = '基础', updated_at = now()`,
      [studentId, SUBJECT, bookId],
    );
    ok('造好一本「只有章节标题」的历史教材', `${UNITS.length} 节，summary 全空`);

    await check('不传知识点也能出题（旧实现这里会 400 no_seed）', async () => {
      const data = await call('POST', '/data/checkin/generate', {
        token,
        body: { studentId, quizDate: todayLocal(), subject: SUBJECT, count: 2, difficulty: '基础' },
      });
      const quiz = data?.quiz;
      assert(quiz, '响应里没有 quiz');
      createdQuizIds.push(quiz.id);

      assert(quiz.subject === SUBJECT, `入库科目是「${quiz.subject}」，不是「${SUBJECT}」`);
      assert(Array.isArray(quiz.questions) && quiz.questions.length > 0, '一道题都没出');

      const allowed = [UNITS[0].title];
      for (const q of quiz.questions) {
        assert(
          q.type === 'choice' || q.type === 'judge',
          `出现了本地判不了分的题型「${q.type}」`,
        );
        assert(
          allowed.includes(q.knowledge),
          `knowledge「${q.knowledge}」不在本次章节范围 ${allowed.join(' / ')} 里`,
        );
        if (q.type === 'choice') {
          assert(Array.isArray(q.options) && q.options.length === 4, '选择题选项不是 4 个');
          assert(['A', 'B', 'C', 'D'].includes(q.answer), `答案「${q.answer}」不是字母`);
        } else {
          assert(['T', 'F'].includes(q.answer), `判断题答案「${q.answer}」不是 T/F`);
        }
      }
      return `${quiz.questions.length} 题 ${quiz.questions.map((q) => q.type).join('/')} · 知识点「${allowed[0]}」`;
    });

    await check('出完题游标推进到下一节（否则天天考同一课）', async () => {
      const r = await client.query(
        'select start_unit_no from subject_scope where student_id = $1 and subject = $2',
        [studentId, SUBJECT],
      );
      const start = Number(r.rows[0]?.start_unit_no ?? 0);
      assert(start === 2, `start_unit_no 应该是 2（下一节），实际 ${start}`);
      return 'start_unit_no = 2';
    });
  } finally {
    // 清理：只删本次造的（`tb_probe_*` 与本次返回的卷子），不按日期整批删。
    if (createdQuizIds.length > 0) {
      await client.query('delete from checkin_quiz where id = any($1::text[])', [createdQuizIds]);
    }
    await client.query("delete from subject_book where student_id = $1 and id like 'tb_probe_%'", [studentId]);
    await client.query('delete from subject_scope where student_id = $1 and subject = $2', [studentId, SUBJECT]);
    await client.end();
    ok('清理探针数据', `${createdQuizIds.length} 份卷子 + 1 本教材 + 1 行范围`);
  }

  console.log('');
  if (failures.length > 0) {
    console.log(`✗ ${failures.length} 条失败 / ${passed} 条通过`);
    for (const one of failures) console.log(`  · ${one}`);
    process.exitCode = 1;
    return;
  }
  console.log(`✓ 全部通过（${passed} 条）`);
}

await main();
