#!/usr/bin/env node
/**
 * **非数学科目出题的端到端冒烟** —— 真 HTTP + 真库 + 真模型。
 *
 * ## 为什么单开一条探针
 *
 * 11-12 之前只有数学接出题，其余科目色块显示「出题待开放」。那天定了口径：
 * **十科都出，题型只有选择题 / 判断题**。单元测试能证明「subject 传对了」，
 * 但证明不了三件真事：
 *   1. 语文 / 历史的知识点喂进去，模型**真的**按 choice/judge 出（不是出成
 *      「默写这句诗」那种本地判不了的题）；
 *   2. 题目的 `knowledge` 真的是给它的那几条（不是模型自己换了个说法）；
 *   3. 落库的 `subject` 是这一科 —— 写错的话记录里查不到这份历史题。
 *
 * ## 判据
 *
 *   1. 学生账号能登录 / 注册（不需要家长关系：自己给自己出题）
 *   2. `POST /data/checkin/generate` 对历史、语文都返回 200
 *   3. 每道题 `type ∈ {choice, judge}`（**没有填空 / 解答**）
 *   4. choice：恰好 4 个选项、answer ∈ A~D；judge：options=["正确","错误"]、answer ∈ T/F
 *   5. 每道题的 `knowledge` 都在请求给的知识点里
 *   6. 返回的 `quiz.subject` 就是选中的那一科
 *   7. 跑完删掉自己造的卷子（0 残留）
 *
 * ## 用法
 *
 *   node scripts/probe-subject-drill.mjs --env-file "D:/easy_learn_home/config/local.env"
 *
 * 自带清理：只碰手机号 `19900000009` 的冒烟账号与它今天新出的卷子。
 * ⚠️ 要消耗真实模型调用（约 2 次），别在循环里跑。
 */
import pg from 'pg';

import { cloudHost, loadEnv, valueOf } from './lib/env-file.mjs';

const BASE = (process.env.PROBE_BASE ?? 'http://127.0.0.1:8788').replace(/\/+$/, '');
const PASS = 'smoke123456';
const ACC = { phone: '19900000009', role: 'student', name: '科目出题冒烟' };

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
    throw new Error(
      `${method} ${path} 返回的不是 JSON（HTTP ${res.status}）：${text.slice(0, 200)}`,
    );
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

/** 每科给两条真实知识点；`expect` 用来断「题只考这两条」。 */
const CASES = [
  { subject: '历史', points: ['辛亥革命的意义', '五四运动'] },
  { subject: '语文', points: ['比喻与拟人的区别', '《静夜思》的主旨'] },
];

function checkQuestion(q, subject, allowed) {
  assert(q && typeof q === 'object', `${subject}：题目不是对象`);
  assert(
    q.type === 'choice' || q.type === 'judge',
    `${subject}：出现了本地判不了分的题型「${q.type}」（只允许 choice / judge）`,
  );
  assert(
    allowed.includes(q.knowledge),
    `${subject}：knowledge「${q.knowledge}」不在给定范围 ${allowed.join(' / ')} 里`,
  );
  if (q.type === 'choice') {
    assert(Array.isArray(q.options) && q.options.length === 4, `${subject}：选择题选项不是 4 个`);
    assert(['A', 'B', 'C', 'D'].includes(q.answer), `${subject}：选择题答案「${q.answer}」不是字母`);
  } else {
    assert(
      Array.isArray(q.options) && q.options.length === 2
        && q.options[0] === '正确' && q.options[1] === '错误',
      `${subject}：判断题选项必须是 ["正确","错误"]，实际 ${JSON.stringify(q.options)}`,
    );
    assert(['T', 'F'].includes(q.answer), `${subject}：判断题答案「${q.answer}」不是 T/F`);
  }
}

async function main() {
  console.log(`科目出题冒烟 · ${BASE}`);

  const auth = await ensureAccount();
  const token = auth?.token ?? auth?.session?.token;
  const studentId = auth?.user?.id ?? auth?.user?.userId;
  assert(token, '登录没拿到 token');
  assert(studentId, '登录没拿到 user.id');

  const createdIds = [];

  for (const one of CASES) {
    await check(`${one.subject}：能出题且只出选择 / 判断`, async () => {
      const data = await call('POST', '/data/checkin/generate', {
        token,
        body: {
          studentId,
          quizDate: todayLocal(),
          subject: one.subject,
          count: 3,
          // 指定范围 = 不依赖错题本（新账号本来也没有这一科的错题）。
          knowledgePoints: one.points,
        },
      });
      const quiz = data?.quiz;
      assert(quiz, '响应里没有 quiz');
      createdIds.push(quiz.id);

      assert(quiz.subject === one.subject, `入库科目是「${quiz.subject}」，不是「${one.subject}」`);
      assert(Array.isArray(quiz.questions) && quiz.questions.length > 0, '一道题都没出');
      for (const q of quiz.questions) checkQuestion(q, one.subject, one.points);
      return `${quiz.questions.length} 题 ${quiz.questions.map((q) => q.type).join('/')}`;
    });
  }

  // 清理：只删本次探针新建的那几份。**不按日期整批删** —— 同一个冒烟账号
  // 可能正被别人拿在手里做别的验证。
  const client = new pg.Client(dbConfig);
  await client.connect();
  try {
    const result = await client.query('delete from checkin_quiz where id = any($1::text[])', [
      createdIds,
    ]);
    ok('清理本次造的卷子', `${result.rowCount} 行`);
  } finally {
    await client.end();
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
