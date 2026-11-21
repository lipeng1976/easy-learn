#!/usr/bin/env node
/**
 * **计划 → 复习的交接**：真 HTTP + 真库。
 *
 * ## 为什么单开一条探针
 *
 * 单元测试能证明「交卷时会写 review_mistake」，但证明不了四件真事：
 *   1. 那张表**真的存在 `source_ref` 列**（028 是否迁移成功）；
 *   2. 写进去的行能过 RLS / NOT NULL 约束（假 client 没有约束）；
 *   3. 题干、答案、知识点是**人看得懂**的样子（不是一串字母）；
 *   4. 同一份卷重复交卷**不会堆出重复错题**。
 *
 * ## 判据
 *
 *   1. 学生账号能登录 / 注册
 *   2. `POST /data/checkin/generate` 能出一份题（显式给知识点，不依赖错题本）
 *   3. 故意全答错后交卷 → `mistakes.added === 题数`
 *   4. 库里 `review_mistake` 按 `source_ref = quizId` 查到的行数 = 题数，
 *      `source_type = 'checkin'`，题干含选项，答案不是光秃秃一个字母，
 *      知识点与请求一致
 *   5. 重复交卷一次 → 行数**不变**（幂等）
 *   6. 跑完删掉自己造的卷、成绩、错题（0 残留）
 *
 * ## 用法
 *
 *   node scripts/probe-checkin-mistake.mjs --env-file "D:/easy_learn_home/config/local.env"
 *
 * ⚠️ 要消耗一次真实模型调用，别在循环里跑。
 */
import pg from 'pg';

import { cloudHost, loadEnv, valueOf } from './lib/env-file.mjs';

const BASE = (process.env.PROBE_BASE ?? 'http://127.0.0.1:8788').replace(/\/+$/, '');
const PASS = 'smoke123456';
const ACC = { phone: '19900000010', role: 'student', name: '错题回流冒烟' };

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
    ok(label, (await fn()) ?? '');
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

/** 故意选错：选择题换个字母，判断题反过来。 */
function wrongPick(q) {
  const answer = String(q.answer ?? '').trim().toUpperCase();
  if (q.type === 'judge') return answer === 'T' ? 'F' : 'T';
  const letters = ['A', 'B', 'C', 'D'];
  return letters.find((one) => one !== answer) ?? 'A';
}

async function main() {
  console.log(`计划→复习交接冒烟 · ${BASE}`);

  const auth = await ensureAccount();
  const token = auth?.token ?? auth?.session?.token;
  const studentId = auth?.user?.id ?? auth?.user?.userId;
  assert(token, '登录没拿到 token');
  assert(studentId, '登录没拿到 user.id');

  const points = ['辛亥革命的意义', '五四运动'];
  let quizId = null;
  let quizQuestions = [];
  /** 本次探针造出来的全部卷 —— 清理时逐个删，不按日期整批删。 */
  const quizIds = [];

  await check('出一份历史打卡（显式知识点，不依赖错题本）', async () => {
    const data = await call('POST', '/data/checkin/generate', {
      token,
      body: {
        studentId,
        quizDate: todayLocal(),
        subject: '历史',
        count: 2,
        knowledgePoints: points,
      },
    });
    const quiz = data?.quiz;
    assert(quiz?.id, '响应里没有 quiz.id');
    assert(Array.isArray(quiz.questions) && quiz.questions.length > 0, '一道题都没出');
    quizId = quiz.id;
    quizIds.push(quiz.id);
    // 出题响应就带答案与题干，后续交卷直接用这份快照 —— 不再从列表接口
    // 反查（列表的形状是 `[{quiz, result}]`，按扁平取会静默找不到）。
    quizQuestions = quiz.questions;
    return `${quizQuestions.length} 题 ${quizQuestions.map((q) => q.type).join('/')}`;
  });

  let expected = 0;

  await check('全答错交卷 → 服务端说「都进了错题本」', async () => {
    const answers = quizQuestions.map((q, index) => ({ index, picked: wrongPick(q) }));
    expected = answers.length;

    const result = await call('POST', '/data/checkin/submit', {
      token,
      body: { quizId, answers },
    });
    assert(result.score === 0, `故意全答错，得分却是 ${result.score}`);
    assert(
      result.mistakes?.added === expected,
      `应写 ${expected} 道错题，服务端说 ${JSON.stringify(result.mistakes)}`,
    );
    assert(result.mistakes?.failed === false, '错题归档失败了');
    return `${expected} 道`;
  });

  const client = new pg.Client(dbConfig);
  await client.connect();
  try {
    await check('库里真有这些错题，且来源/题干/答案都像人话', async () => {
      // 年级/学期是**快照**：错题列表默认按当前学期筛，不写就会永远躺在
      // 「未归档」里。这里不要求它非空（新注册的冒烟账号本来就没填），
      // 只要求**与账号上的值一致** —— 写死一个默认值同样是错的。
      const profile = await client.query('select grade, term from app_user where id = $1', [
        studentId,
      ]);
      const grade = String(profile.rows[0]?.grade ?? '');
      const term = String(profile.rows[0]?.term ?? '');

      const r = await client.query(
        `select id, subject, title, question_body, answer_key, original_answer,
                knowledge_point, source_type, source_ref, grade, term
           from review_mistake
          where source_ref = $1 and student_id = $2
          order by id`,
        [quizId, studentId],
      );
      assert(r.rowCount === expected, `库里有 ${r.rowCount} 行，期望 ${expected} 行`);
      for (const row of r.rows) {
        assert(row.source_type === 'checkin', `source_type 是「${row.source_type}」`);
        assert(row.subject === '历史', `科目是「${row.subject}」`);
        assert(String(row.question_body).trim() !== '', '题干是空的 —— 复习里没法重做');
        assert(
          /[A-D]\. /.test(String(row.question_body)) || /判断题/.test(String(row.question_body)),
          '题干里没有选项 / 没标判断题',
        );
        assert(String(row.answer_key).trim() !== '', '没有正确答案');
        assert(!/^[A-D]$/.test(String(row.answer_key)), '答案只有一个字母，离开原题看不懂');
        assert(points.includes(row.knowledge_point), `知识点「${row.knowledge_point}」不在范围里`);
        assert(
          row.grade === grade && row.term === term,
          `年级/学期快照与账号不一致（行 ${row.grade}/${row.term}，账号 ${grade}/${term}）`,
        );
      }
      return `${r.rowCount} 行 · ${r.rows[0].title}`;
    });

    await check('复习页读得到这些错题（列表接口 + RLS）', async () => {
      // 只写库不读库是不够的：复习页走的是 `GET /data/review/mistakes`，
      // 它经过 RLS 与 `rowsToApi` 的字段映射。写进去了但读不出来，
      // 在孩子眼里和「没记上」一模一样。
      const data = await call('GET', `/data/review/mistakes?studentId=${studentId}`, { token });
      const mine = (data.items ?? []).filter(
        (m) => m.sourceType === 'checkin' && points.includes(m.knowledgePoint),
      );
      assert(mine.length >= expected, `复习列表里只有 ${mine.length} 道打卡错题，期望 ${expected}`);
      for (const one of mine) {
        assert(String(one.questionBody ?? '').trim() !== '', '列表里的题干是空的');
        assert(String(one.answerKey ?? '').trim() !== '', '列表里没有正确答案');
      }
      return `${mine.length} 道`;
    });

    await check('重复交卷不会堆出重复错题（幂等）', async () => {
      const answers = quizQuestions.map((q, index) => ({ index, picked: wrongPick(q) }));
      await call('POST', '/data/checkin/submit', { token, body: { quizId, answers } });

      const r = await client.query(
        'select count(*)::int as n from review_mistake where source_ref = $1',
        [quizId],
      );
      assert(r.rows[0].n === expected, `重复交卷后有 ${r.rows[0].n} 行，期望 ${expected} 行`);
      return `仍是 ${expected} 行`;
    });

    // 学生自发起（不带 knowledgePoints）时必须读家长在范围页存的那份。
    // 这条要真库才能验：假 client 不执行 SQL，`scopePointsOf` 的 select
    // 写错了（列名、jsonb 类型、RLS）在单测里照样绿。
    await check('学生自发起（不带知识点）→ 用范围页存下来的那份', async () => {
      const geoPoints = ['地球的运动', '地图三要素'];
      await client.query(
        `insert into subject_scope (student_id, subject, daily_count, difficulty, points)
         values ($1, '地理', 3, '基础', $2::jsonb)
         on conflict (student_id, subject) do update
           set points = excluded.points, daily_count = excluded.daily_count`,
        [studentId, JSON.stringify(geoPoints)],
      );

      const data = await call('POST', '/data/checkin/generate', {
        token,
        body: { studentId, quizDate: todayLocal(), subject: '地理', count: 3 },
      });
      const quiz = data?.quiz;
      assert(quiz?.id, '响应里没有 quiz.id');
      quizIds.push(quiz.id);
      for (const q of quiz.questions) {
        assert(
          geoPoints.includes(q.knowledge),
          `知识点「${q.knowledge}」不在范围页配置里 —— 说明没读到 subject_scope.points`,
        );
      }
      return `${quiz.questions.length} 题都在范围内`;
    });
  } finally {
    // 清理：只删本次探针造的东西。不按日期/学生整批删 —— 同一个冒烟账号
    // 可能还被别的验证拿在手里。
    for (const id of quizIds) {
      await client.query('delete from review_mistake where source_ref = $1', [id]);
      await client.query('delete from checkin_result where quiz_id = $1', [id]);
      await client.query('delete from checkin_quiz where id = $1', [id]);
    }
    await client.query(
      "delete from subject_scope where student_id = $1 and subject = '地理'",
      [studentId],
    );
    await client.end();
    ok('清理本次造的卷 / 成绩 / 错题 / 范围');
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
