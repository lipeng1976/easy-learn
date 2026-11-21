#!/usr/bin/env node
/**
 * **打卡 + ima 的端到端冒烟** —— 走的是 App 真正会走的那条路（HTTP）。
 *
 * 单元测试用假 client，证明的是「SQL 发对了」；RLS 探针证明的是「策略拦得住」。
 * 两者都证明不了**这条链路拼起来能不能跑通**：登录拿票 → 存题 → 读题 →
 * 交卷 → 复算分数 → 家长看到结果。中间任何一环的字段名对不上，前面的测试
 * 全都照样绿，只有真机上才会表现为「点了没反应」。
 *
 * ## 判据
 *
 *   1. 家长 / 学生都能登录拿到票
 *   2. `GET /data/ima/status` 默认 `unconnected` —— opt-in 真的默认关闭
 *   3. 学生读 ima 状态是 200（不是 403/500）—— 学生只读放行成立
 *   4. 存题成功，且返回的是服务端认可的那一行（R2）
 *   5. **未交卷时也带 `answer` / `analysis`** —— 交卷要在本机立刻判对错
 *   6. 下发的那份与库里那份一致（同一个快照）
 *   7. 交卷后分数由服务端复算：客户端谎报 `score:99` 也不采信
 *   8. 服务端复算的分数与客户端判分规则算出来的一致（两处口径不漂）
 *   9. 家长能看到孩子的打卡结果（RLS 可见性）
 *  10. 无关系的路人看不到（0 条）
 *  11. 全程跑完数据库 0 残留
 *
 * ## 用法
 *
 *   node scripts/probe-checkin-e2e.mjs --env-file "D:/easy_learn_home/config/local.env"
 *
 * 需要一个**已启动的数据服务**（默认 `http://127.0.0.1:8788`，可用 `PROBE_BASE` 改）。
 * 自带清理：只碰手机号前缀 `199000000` 的三个冒烟账号。
 */
import pg from 'pg';

import { cloudHost, loadEnv, valueOf } from './lib/env-file.mjs';

const BASE = (process.env.PROBE_BASE ?? 'http://127.0.0.1:8788').replace(/\/+$/, '');
const PASS = 'smoke123456';

/** 三个冒烟账号：家长、学生、路人（路人用于验证隔离）。 */
const ACC = {
  parent: { phone: '19900000001', role: 'parent', name: '冒烟家长' },
  student: { phone: '19900000002', role: 'student', name: '冒烟学生' },
  loner: { phone: '19900000003', role: 'student', name: '冒烟路人' },
};

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
let skipped = 0;
const failures = [];

function ok(label, extra = '') {
  passed += 1;
  console.log(`  ✓ ${label}${extra ? `  ${extra}` : ''}`);
}

/**
 * 跳过 —— **不算通过**。
 *
 * 用它的地方只有一类：这台部署根本没接 AI 网关（`model_not_enabled`）。
 * 那时代码可能是对的，但这条判据**什么都没证明**，所以单独计数，
 * 让「跳过 N 条」出现在结论里，而不是悄悄混进「全绿」。
 */
function skip(label, reason) {
  skipped += 1;
  console.log(`  – ${label}  [跳过：${reason}]`);
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

/**
 * 在 `YYYY-MM-DD` 上前后移动天数，仍按**本地日**算。
 *
 * 探针要用「前一天」跑家长指定范围那条路。
 *
 * ⚠️ 2026-10-27 起同一天已经**可以有多份**（不再覆盖），漏用前一天也不会
 * 冲掉前面的卷；但仍保留这个习惯：后面的判据都按「当天几份」数数量，
 * 多一份少一份都会让计数断言变得难读。
 */
function shiftLocal(date, days) {
  const [y, m, d] = date.split('-').map(Number);
  const t = new Date(y, m - 1, d + days);
  const p = (n) => String(n).padStart(2, '0');
  return `${t.getFullYear()}-${p(t.getMonth() + 1)}-${p(t.getDate())}`;
}

/** 调接口：返回解析后的 data，非 2xx 抛带 code 的错误。 */
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

/** 登录，账号不存在则注册。返回 { token, user }。 */
async function ensureAccount(acc) {
  const login = async () =>
    call('POST', '/auth/login', { body: { phone: acc.phone, password: PASS } });
  try {
    return await login();
  } catch (e) {
    // 只有「账号不存在/密码不对」才会走到注册；其它错误（500）必须冒出来。
    if (e.status !== 400 && e.status !== 401) throw e;
  }
  try {
    return await call('POST', '/auth/register', {
      body: { phone: acc.phone, password: PASS, role: acc.role, name: acc.name },
    });
  } catch (e) {
    // 并发/残留账号：再登一次，还不行就真的失败。
    if (e.code === 'phone_taken' || e.status === 409) return login();
    throw e;
  }
}

const QUESTIONS = [
  {
    type: 'choice',
    stem: '$1+1=?$',
    options: ['1', '2', '3', '4'],
    answer: 'B',
    knowledge: '有理数混合运算',
    analysis: '直接相加',
  },
  {
    type: 'choice',
    stem: '$2\\times 3=?$',
    options: ['5', '6', '7', '8'],
    answer: 'B',
    knowledge: '有理数混合运算',
    analysis: '乘法口诀',
  },
  {
    type: 'judge',
    stem: '判断：$0.5=\\frac{1}{2}$',
    options: ['正确', '错误'],
    answer: '对',
    knowledge: '分数的意义',
    analysis: '同一个数',
  },
];

async function main() {
  console.log('═══════════════════════════════════════════════════════════════');
  console.log('  打卡 / ima · 端到端冒烟（真 HTTP + 真数据库）');
  console.log('═══════════════════════════════════════════════════════════════\n');
  console.log(`  服务：${BASE}`);
  console.log(`  库  ：${dbConfig.host}:${dbConfig.port}/${dbConfig.database}\n`);

  const pool = new pg.Pool({ ...dbConfig, max: 2 });

  // ── 准备：账号 + 结伴关系 ──
  const parent = await ensureAccount(ACC.parent);
  const student = await ensureAccount(ACC.student);
  const loner = await ensureAccount(ACC.loner);
  console.log(`  家长 ${parent.user.id}`);
  console.log(`  学生 ${student.user.id}`);
  console.log(`  路人 ${loner.user.id}\n`);

  // 家长 ↔ 学生：active（家长能看到孩子）；路人不建关系。
  // ⚠️ relationship 的 id / sender_id 都是 NOT NULL 且没有默认值 —— 少给就直接崩，
  //    而报错会在「准备阶段」，看上去像环境坏了。
  const relId = (tag) => `probe_rel_${tag}`;
  await pool.query(
    `insert into relationship (id, student_id, parent_id, sender_id, status)
     values ($1, $2, $3, $3, 'active')
     on conflict (student_id, parent_id) do update set status = 'active'`,
    [relId('p_s'), student.user.id, parent.user.id],
  );
  // 路人：保留一条 removed 关系，确保「有行但未结伴」也看不到
  // （比「完全没有行」更接近真实场景：解除结伴后行还在）。
  await pool.query(
    `insert into relationship (id, student_id, parent_id, sender_id, status)
     values ($1, $2, $3, $3, 'removed')
     on conflict (student_id, parent_id) do update set status = 'removed'`,
    [relId('p_l'), loner.user.id, parent.user.id],
  );

  const quizDate = todayLocal();

  // ── 1. ima opt-in 默认关闭 ──
  console.log('  ── ima 状态 ──');
  await check('家长读到 ima 状态为 unconnected（opt-in 默认关闭）', async () => {
    const s = await call('GET', '/data/ima/status', { token: parent.token });
    assert(s.status === 'unconnected', `实际是 ${s.status}`);
    assert(Array.isArray(s.kbs), 'kbs 不是数组');
    return `status=${s.status} kbs=${s.kbs.length}`;
  });

  await check('学生读 ima 状态是 200，且同样 unconnected（只读放行，不炸）', async () => {
    const s = await call('GET', '/data/ima/status', { token: student.token });
    assert(s.status === 'unconnected', `实际是 ${s.status}`);
    return `status=${s.status}`;
  });

  // ⚠️ 上面两条判据**分不清**「真的查了库」和「role 不认识、直接兜底」——
  //    两条路都返回 unconnected。这一条才分得开：
  //
  //    · handler 签名对（收到真 ctx）→ role='parent' 通过守卫 → 调 ima 网关 →
  //      假密钥被拒 → `ima_auth_failed`
  //    · handler 签名错位（把 PG Client 当 ctx）→ role 是 undefined →
  //      先撞「只有家长可以连接」→ 403 `forbidden`
  //
  //    这个 bug 真的发生过：三个 ima 端点全写成 `(ctx, body)`，而 app.js 统一
  //    按 `(client, ctx, input)` 调用。单测直接传 fakeCtx（还顺手塞了 ctx.client）
  //    所以全绿，真机上家长点「连接」必然 403。
  await check('家长用假密钥连接 ima → ima_auth_failed（不是 403「只有家长」）', async () => {
    let code = null;
    let status = null;
    try {
      await call('POST', '/data/ima/connect', {
        token: parent.token,
        body: { clientid: 'probe-fake-client', apikey: 'probe-fake-key' },
      });
    } catch (e) {
      code = e.code;
      status = e.status;
    }
    assert(
      code !== 'forbidden',
      '连接被 403 挡下了 —— 说明 handler 没收到真实身份（签名错位）',
    );
    assert(
      code === 'ima_auth_failed' || code === 'ima_unavailable' || code === 'ima_request_failed',
      `期望 ima 侧的失败，实际 HTTP ${status} code=${code}`,
    );
    return `code=${code}`;
  });

  await check('学生调 connect → 403（角色守卫真的在拦，不是摆设）', async () => {
    let denied = false;
    try {
      await call('POST', '/data/ima/connect', {
        token: student.token,
        body: { clientid: 'x', apikey: 'y' },
      });
    } catch (e) {
      denied = e.code === 'forbidden' || e.status === 403;
    }
    assert(denied, '学生居然能连 ima');
    return '403';
  });

  await check('家长 disconnect → 200 unconnected（同样验证身份没串）', async () => {
    const out = await call('POST', '/data/ima/disconnect', { token: parent.token });
    assert(out.status === 'unconnected', `实际 ${out.status}`);
    return 'status=unconnected';
  });

  // ── 2. 服务端出题 ──
  //
  // 出题在**服务端**完成（聚合错题 → 调模型 → 落库），客户端一次请求拿到题。
  // 题目**带答案**：交卷那一刻要在孩子设备上立刻判对错，不等这趟网络。
  // 「答题时看不到答案」由客户端渲染层保证，这里是服务端，测不到那件事。
  console.log('\n  ── 打卡：服务端出题 ──');

  // 先给这个学生造一条错题：没有错题时 generate 会（正确地）回 `no_seed`。
  await pool.query(
    `insert into review_mistake (id, subject, title, wrong_reason, student_id, knowledge_point, wrong_count, created_at)
     values ($1, '数学', '探针错题', '移项没变号', $2, '解一元一次方程', 2, now())
     on conflict (id) do update set wrong_count = 2`,
    ['probe_mistake_checkin', student.user.id],
  );

  let generated = null;
  try {
    generated = await call('POST', '/data/checkin/generate', {
      token: student.token,
      body: { studentId: student.user.id, quizDate, subject: '数学', count: 3 },
    });
  } catch (e) {
    if (e.code === 'model_not_enabled') {
      skip('服务端出题', '这台部署没接 AI 网关（AI_GATEWAY_BASE_URL 为空）');
    } else {
      // 模型临时不可用也是失败：这条判据跑不了，就不该报「全绿」。
      fail('服务端出题', `${e.code ?? 'unknown'} ${e.message}`);
    }
  }

  if (generated) {
    await check('出题返回的题目带 answer / analysis（本机判分要用）', async () => {
      const qs = generated.quiz.questions;
      assert(Array.isArray(qs) && qs.length > 0, '一道题都没出');
      for (const [i, q] of qs.entries()) {
        assert('answer' in q, `第 ${i + 1} 题没有 answer —— 本机判分会把它判成错`);
        assert('analysis' in q, `第 ${i + 1} 题没有 analysis`);
        assert(typeof q.stem === 'string' && q.stem !== '', `第 ${i + 1} 题题干是空的`);
      }
      return `${qs.length} 题均带答案`;
    });

    await check('下发的那份与库里那份一致（同一个快照，不另拼）', async () => {
      assert(generated.quiz.id.startsWith('ck_'), `id 不像服务端生成的：${generated.quiz.id}`);
      const row = await pool.query(
        'select questions from checkin_quiz where id = $1',
        [generated.quiz.id],
      );
      assert(row.rowCount === 1, '库里没有这份打卡');
      const stored = row.rows[0].questions;
      assert(
        JSON.stringify(stored) === JSON.stringify(generated.quiz.questions),
        '下发的题与库里那份不一致 —— 判分和看到的题迟早会不一样',
      );
      return `id=${generated.quiz.id} 库存 ${stored.length} 题，逐字一致`;
    });

    await check('紧接着 GET 读题，带同一份答案（不是只有出题响应给了）', async () => {
      const out = await call(
        'GET',
        `/data/checkin/quiz?studentId=${encodeURIComponent(student.user.id)}&quizDate=${quizDate}`,
        { token: student.token },
      );
      assert(Array.isArray(out.quizzes) && out.quizzes.length > 0, '没读到刚出的题');
      const quiz = out.quizzes[0].quiz;
      assert(quiz.questions.length > 0, '读到的卷没有题目');
      for (const [i, q] of quiz.questions.entries()) {
        assert('answer' in q, `第 ${i + 1} 题没带 answer —— 孩子交卷后只能干等网络`);
      }
      return `${quiz.questions.length} 题均带答案`;
    });
  }

  // ── 2b. 家长指定范围（方案 A）──
  //
  // 家长选学科 / 知识点 / 难度 → 服务端按范围出题并落库 → 孩子打开就做。
  // 用**前一天**的日期：不是怕覆盖（2026-10-27 起同一天已可多份），
  // 而是让后面「当天有几份」的计数保持清爽。
  const prevDate = shiftLocal(quizDate, -1);
  console.log('\n  ── 打卡：家长指定范围 ──');

  await check('家长能拿到孩子错题的知识点候选（含累计错次）', async () => {
    const out = await call(
      'GET',
      `/data/checkin/seeds?studentId=${encodeURIComponent(student.user.id)}`,
      { token: parent.token },
    );
    assert(Array.isArray(out.seeds), 'seeds 不是数组');
    const hit = out.seeds.find((s) => s.knowledge === '解一元一次方程');
    assert(hit, `候选里没有探针造的知识点：${JSON.stringify(out.seeds)}`);
    assert(hit.wrongCount === 2, `错次应为 2，实际 ${hit.wrongCount}`);
    return `${out.seeds.length} 个候选`;
  });

  let manual = null;
  try {
    manual = await call('POST', '/data/checkin/generate', {
      token: parent.token,
      body: {
        studentId: student.user.id,
        quizDate: prevDate,
        subject: '数学',
        count: 3,
        // 第二个知识点故意是这个学生**没有错题记录**的：
        // 家长按自己判断让孩子提前练，这条路不该被 no_seed 拦住。
        knowledgePoints: ['解一元一次方程', '有理数混合运算'],
        difficulty: '提高',
      },
    });
  } catch (e) {
    if (e.code === 'model_not_enabled') {
      skip('家长指定范围出题', '这台部署没接 AI 网关');
    } else {
      fail('家长指定范围出题', `${e.code ?? 'unknown'} ${e.message}`);
    }
  }

  if (manual) {
    await check('出题结果落在指定范围内，难度也生效', async () => {
      assert(manual.quiz.difficulty === '提高', `难度丢了：${manual.quiz.difficulty}`);
      const allowed = new Set(['解一元一次方程', '有理数混合运算']);
      assert(manual.quiz.questions.length > 0, '一道题都没出');
      for (const [i, q] of manual.quiz.questions.entries()) {
        assert(
          allowed.has(q.knowledge),
          `第 ${i + 1} 题跑出了指定范围：${q.knowledge}`,
        );
      }
      return `${manual.quiz.questions.length} 题 · ${manual.quiz.difficulty}`;
    });

    await check('库里那份也带难度（事后能看出当时要的是哪一档）', async () => {
      const row = await pool.query(
        'select difficulty from checkin_quiz where id = $1',
        [manual.quiz.id],
      );
      assert(row.rowCount === 1, '库里没有这份打卡');
      assert(row.rows[0].difficulty === '提高', `实际 ${row.rows[0].difficulty}`);
      return `difficulty=${row.rows[0].difficulty}`;
    });

    await check('学生读回家长出的这份，范围与难度一致', async () => {
      const out = await call(
        'GET',
        `/data/checkin/quiz?studentId=${encodeURIComponent(student.user.id)}&quizDate=${prevDate}`,
        { token: student.token },
      );
      assert(Array.isArray(out.quizzes) && out.quizzes.length > 0, '学生读不到家长出的题');
      const quiz = out.quizzes[0].quiz;
      assert(quiz.difficulty === '提高', `难度 ${quiz.difficulty}`);
      const allowed = new Set(['解一元一次方程', '有理数混合运算']);
      assert(
        quiz.questions.every((q) => allowed.has(q.knowledge)),
        '读回来的题跑出了范围',
      );
      return `${quiz.questions.length} 题`;
    });
  }

  // ── 3. 学生存题 ──
  console.log('\n  ── 打卡：存题 ──');
  const quizId = `probe_${Date.now()}`;
  // 服务端认可的那一行。**后续所有操作都用它**，不用客户端自己生成的 id ——
  // 这正是 R2 的用法。2026-10-27 起覆盖改成「删旧行 + 插新行、id 换新」：
  // 只换内容不换主键会让握着旧卷的客户端交卷时被新题复算（串题事故）。
  let savedId = '';
  await check('学生存题成功，返回服务端认可的那一行', async () => {
    const out = await call('POST', '/data/checkin/quiz', {
      token: student.token,
      body: {
        id: quizId,
        studentId: student.user.id,
        quizDate,
        subject: '数学',
        questions: QUESTIONS,
      },
    });
    savedId = out.quiz.id;
    assert(savedId !== '', '没返回 id');
    assert(out.quiz.questions.length === 3, `题目数 ${out.quiz.questions.length}`);
    return `id=${savedId} 题数=${out.quiz.questions.length}`;
  });

  await check('同一天再发起一份：多一份独立试卷，旧卷不被删除', async () => {
    // 当前这一天已经有几份（第 1 节自动出的那份不会因为再出题而被删了），
    // 所以判据用「多一份」而不是写死数量 —— 写死的话，将来前面多一份就红。
    const before = await call(
      'GET',
      `/data/checkin/quiz?studentId=${encodeURIComponent(student.user.id)}&quizDate=${quizDate}`,
      { token: student.token },
    );
    const beforeCount = before.quizzes.length;
    const out = await call('POST', '/data/checkin/quiz', {
      token: student.token,
      body: {
        id: `${quizId}_again`,
        studentId: student.user.id,
        quizDate,
        subject: '数学',
        questions: QUESTIONS,
      },
    });
    assert(
      out.quiz.id === `${quizId}_again`,
      `服务端必须采纳这次给的 id，实际回 ${out.quiz.id}`,
    );
    // 🔴 2026-10-27 语义变更：一次出题 = 一份独立试卷。
    // 旧卷**不许被删**（删掉等于家长多出一套就把孩子正在做的那套抹了），
    // 串题防护改由「每次新 id」承担。这里直接验「旧卷还在」。
    const got = await call(
      'GET',
      `/data/checkin/quiz?studentId=${encodeURIComponent(student.user.id)}&quizDate=${quizDate}`,
      { token: student.token },
    );
    const ids = got.quizzes.map((e) => e.quiz.id);
    assert(ids.includes(savedId), `旧卷 ${savedId} 不见了 —— 不许删旧行`);
    assert(ids.includes(`${quizId}_again`), '新卷不在列表里');
    assert(
      got.quizzes.length === beforeCount + 1,
      `应比出题前多一份（${beforeCount} → ${beforeCount + 1}），实际 ${got.quizzes.length}`,
    );
    // 后续判据统一用**这一份**：按 id 找，不按数组下标猜。
    savedId = out.quiz.id;
    return `并存：${beforeCount} → ${got.quizzes.length} 份`;
  });

  // ── 4. 未交卷读题：带答案 ──
  console.log('\n  ── 打卡：读题（未交卷）──');
  await check('未交卷时也带 answer / analysis（交卷要在本机立刻判对错）', async () => {
    const out = await call(
      'GET',
      `/data/checkin/quiz?studentId=${encodeURIComponent(student.user.id)}&quizDate=${quizDate}`,
      { token: student.token },
    );
    assert(Array.isArray(out.quizzes) && out.quizzes.length > 0, '没读到题');
    // ⚠️ 按 id 找这一份，别用 `quizzes[0]`：同一天现在可以有好几份，
    // 下标指着谁完全取决于创建顺序（这是个会静默读错卷的坑）。
    const entry = out.quizzes.find((e) => e.quiz.id === savedId);
    assert(entry, `读不到刚存的那份 ${savedId}`);
    assert(entry.result === null, '还没交卷却有 result');
    for (const [i, q] of entry.quiz.questions.entries()) {
      assert('answer' in q, `第 ${i + 1} 题没带 answer —— 本机判分会把它判成错`);
      assert('analysis' in q, `第 ${i + 1} 题没带 analysis`);
      assert(typeof q.stem === 'string' && q.stem !== '', `第 ${i + 1} 题题干是空的`);
      assert(Array.isArray(q.options) && q.options.length >= 2, `第 ${i + 1} 题选项不足`);
    }
    return `3 题均带答案`;
  });

  // ── 5. 交卷：服务端复算 ──
  console.log('\n  ── 打卡：交卷 ──');
  await check('客户端谎报 score:99 也不采信，服务端复算出 2/3', async () => {
    const out = await call('POST', '/data/checkin/submit', {
      token: student.token,
      body: {
        // 用**服务端认可的那个 id**（不是客户端自己生成的）—— R2 的正确用法。
        quizId: savedId,
        // 第 1、3 题对，第 2 题故意错
        answers: [
          { index: 0, picked: 'B' },
          { index: 1, picked: 'A' },
          { index: 2, picked: 'T' },
        ],
        // 谎报：服务端必须无视它
        score: 99,
        total: 99,
      },
    });
    assert(out.score === 2, `分数应为 2，实际 ${out.score}`);
    assert(out.total === 3, `总分应为 3，实际 ${out.total}`);
    assert(out.items.length === 3, `逐题结果应有 3 条，实际 ${out.items.length}`);
    const wrong = out.items.find((it) => it.index === 1);
    assert(wrong && wrong.correct === false, '第 2 题应判错');
    return `${out.score}/${out.total}`;
  });

  // ── 6. 交卷后读题：带答案（复盘）──
  console.log('\n  ── 打卡：读题（已交卷）──');
  await check('交卷后读题带答案与逐题明细（复盘要看对错）', async () => {
    const out = await call(
      'GET',
      `/data/checkin/quiz?studentId=${encodeURIComponent(student.user.id)}&quizDate=${quizDate}`,
      { token: student.token },
    );
    assert(Array.isArray(out.quizzes) && out.quizzes.length > 0, '没读到题');
    const entry = out.quizzes.find((e) => e.quiz.id === savedId);
    assert(entry, `读不到刚交的那份 ${savedId}`);
    const result = entry.result;
    assert(result && result.score === 2, '读回的分数不是 2');
    assert(entry.quiz.questions[0].answer === 'B', `第 1 题答案 ${entry.quiz.questions[0].answer}`);
    // 🔴 2026-10-27 用户报的：重开页面只剩一句汇总，看不到哪个题错。
    // 服务端必须从存档派生逐题明细回传。
    assert(Array.isArray(result.items) && result.items.length === 3, `明细应有 3 条，实际 ${result.items?.length}`);
    const wrong = result.items.find((it) => it.index === 1);
    assert(wrong && wrong.correct === false, '第 2 题的明细应判错');
    assert(wrong.picked === 'A' && wrong.answer === 'B', '明细里要有选了什么、该选什么');
    return 'answer/analysis/items 同在';
  });

  await check('服务端复算与客户端判分规则一致（两处口径不漂）', async () => {
    const out = await call(
      'GET',
      `/data/checkin/quiz?studentId=${encodeURIComponent(student.user.id)}&quizDate=${quizDate}`,
      { token: student.token },
    );
    const entry = out.quizzes.find((e) => e.quiz.id === savedId);
    // 照抄 `CheckinSubmitResult.judge` 的规则：trim + 大写 + 相等，空作答算错。
    // ⚠️ 这是**规则的复刻**，不是 Dart 代码本身 —— 它能抓「服务端改了比对口径
    // 却没同步客户端」，抓不了「Dart 写错」。后者由客户端单测守。
    const pickedByIndex = { 0: 'B', 1: 'A', 2: 'T' };
    const mine = entry.quiz.questions.reduce((acc, q, i) => {
      const answer = String(q.answer ?? '').trim().toUpperCase();
      const picked = String(pickedByIndex[i] ?? '').trim().toUpperCase();
      return acc + (picked !== '' && picked === answer ? 1 : 0);
    }, 0);
    assert(
      mine === entry.result.score,
      `客户端规则算 ${mine}，服务端存 ${entry.result.score} —— 判分口径漂了`,
    );
    return `${mine}/${entry.quiz.questions.length} 两边一致`;
  });

  // ── 7. 家长看结果 + 隔离 ──
  console.log('\n  ── 结果可见性 ──');
  await check('家长能看到孩子的打卡结果', async () => {
    const out = await call(
      'GET',
      `/data/checkin/results?studentId=${encodeURIComponent(student.user.id)}&from=${quizDate}&to=${quizDate}`,
      { token: parent.token },
    );
    assert(out.items.length === 1, `应有 1 条，实际 ${out.items.length}`);
    assert(out.items[0].score === 2, `分数 ${out.items[0].score}`);
    return `1 条 ${out.items[0].score}/${out.items[0].total}`;
  });

  await check('无关系的路人看不到这条打卡（0 条）', async () => {
    const out = await call(
      'GET',
      `/data/checkin/results?from=${quizDate}&to=${quizDate}`,
      { token: loner.token },
    );
    assert(out.items.length === 0, `路人看到 ${out.items.length} 条`);
    return '0 条';
  });

  await check('路人拿孩子的 studentId 直接问 → 403（不是静默空列表）', async () => {
    let denied = false;
    try {
      await call(
        'GET',
        `/data/checkin/results?studentId=${encodeURIComponent(student.user.id)}&from=${quizDate}&to=${quizDate}`,
        { token: loner.token },
      );
    } catch (e) {
      denied = e.status === 403 || e.code === 'forbidden';
    }
    assert(denied, '路人居然读到了别人家孩子的结果');
    return '403';
  });

  // ── 8. 一天多份（不再按科目排他）──
  //
  // 2026-10-27 起一次出题 = 一份独立试卷：同一天、**同一科目**也可以并存，
  // 旧的题与成绩一律保留（`sql/022_checkin_drop_subject_unique.sql` 删了
  // 唯一键，服务端 `insertCheckinQuiz` 只插不删）。
  //
  // 这里验三件事，缺一条都会让「家长多出一套」变成静默事故：
  //   ① 加一份英语 → 三份共存，数学已交卷的成绩不受影响；
  //   ② 同科目（数学）再出一份 → 四份，**旧数学卷与它的成绩都还在**；
  //   ③ 谁都没被删 —— 逐条按 id 查，不靠数量猜。
  console.log('\n  ── 打卡：一天多份 ──');
  const englishId = `probe_${Date.now()}_en`;
  await check('同一天再存一份英语：多一份，数学的成绩不被殃及', async () => {
    const beforeEn = await call(
      'GET',
      `/data/checkin/quiz?studentId=${encodeURIComponent(student.user.id)}&quizDate=${quizDate}`,
      { token: student.token },
    );
    const enBase = beforeEn.quizzes.length;
    await call('POST', '/data/checkin/quiz', {
      token: student.token,
      body: {
        id: englishId,
        studentId: student.user.id,
        quizDate,
        subject: '英语',
        questions: QUESTIONS,
      },
    });
    const out = await call(
      'GET',
      `/data/checkin/quiz?studentId=${encodeURIComponent(student.user.id)}&quizDate=${quizDate}`,
      { token: student.token },
    );
    assert(
      Array.isArray(out.quizzes) && out.quizzes.length === enBase + 1,
      `应比存英语前多一份（${enBase} → ${enBase + 1}），实际 ${out.quizzes?.length}`,
    );
    const math = out.quizzes.find((e) => e.quiz.id === savedId);
    const eng = out.quizzes.find((e) => e.quiz.id === englishId);
    assert(math && math.result && math.result.score === 2, '数学已交卷的成绩不能被英语出题殃及');
    assert(eng, '英语那份应在');
    return `${out.quizzes.length} 份共存，数学成绩完好`;
  });

  await check('同科目再出一份：多一份，旧卷与旧成绩都还在（不覆盖）', async () => {
    const beforeMath = await call(
      'GET',
      `/data/checkin/quiz?studentId=${encodeURIComponent(student.user.id)}&quizDate=${quizDate}`,
      { token: student.token },
    );
    const mathBase = beforeMath.quizzes.length;
    const out = await call('POST', '/data/checkin/quiz', {
      token: student.token,
      body: {
        id: `${quizId}_math3`,
        studentId: student.user.id,
        quizDate,
        subject: '数学',
        questions: QUESTIONS,
      },
    });
    const got = await call(
      'GET',
      `/data/checkin/quiz?studentId=${encodeURIComponent(student.user.id)}&quizDate=${quizDate}`,
      { token: student.token },
    );
    assert(
      got.quizzes.length === mathBase + 1,
      `同一科目再出一份应比之前多一份（${mathBase} → ${mathBase + 1}），实际 ${got.quizzes.length}`,
    );
    const ids = got.quizzes.map((e) => e.quiz.id);
    assert(ids.includes(savedId), `旧数学卷 ${savedId} 被删了 —— 一次出题=一份试卷，不许覆盖`);
    assert(ids.includes(out.quiz.id), '新数学卷不在列表里');
    const oldMath = got.quizzes.find((e) => e.quiz.id === savedId);
    assert(
      oldMath.result && oldMath.result.score === 2,
      '旧卷的成绩必须原样保留（覆盖语义下这里会变成 null）',
    );
    assert(got.quizzes.some((e) => e.quiz.id === englishId), '英语那份必须原封不动');
    return `${got.quizzes.length} 份并存，旧数学的成绩仍在`;
  });

  // ── 清理 ──
  console.log('\n  ── 清理 ──');
  const ids = [parent.user.id, student.user.id, loner.user.id];
  const cleanup = await pool.connect();
  try {
    await cleanup.query('begin');
    await cleanup.query(
      `delete from checkin_result where student_id = any($1::text[])`,
      [ids],
    );
    await cleanup.query(`delete from checkin_quiz where student_id = any($1::text[])`, [ids]);
    // 探针自己造的错题（出题判据用的锚点）
    await cleanup.query(`delete from review_mistake where student_id = any($1::text[])`, [ids]);
    await cleanup.query(
      `delete from relationship where parent_id = any($1::text[]) or student_id = any($1::text[])`,
      [ids],
    );
    await cleanup.query(
      `delete from app_user_credential where user_id = any($1::text[])`,
      [ids],
    );
    // 会话行（003_session.sql 里叫 user_session；缺表不算失败）
    try {
      await cleanup.query(`delete from user_session where user_id = any($1::text[])`, [ids]);
    } catch {
      /* 没有这张表就跳过 */
    }
    await cleanup.query(`delete from app_user where id = any($1::text[])`, [ids]);
    await cleanup.query('commit');
  } catch (e) {
    await cleanup.query('rollback').catch(() => {});
    throw e;
  } finally {
    cleanup.release();
  }

  const left = await pool.query(
    `select
       (select count(*) from app_user where phone = any($1::text[])) as users,
       (select count(*) from checkin_quiz where id = $2) as quizzes,
       (select count(*) from review_mistake where student_id = any($3::text[])) as mistakes`,
    [[ACC.parent.phone, ACC.student.phone, ACC.loner.phone], savedId, ids],
  );
  await check('跑完数据库 0 残留', async () => {
    const r = left.rows[0];
    assert(Number(r.users) === 0, `还剩 ${r.users} 个账号`);
    assert(Number(r.quizzes) === 0, `还剩 ${r.quizzes} 份打卡`);
    assert(Number(r.mistakes) === 0, `还剩 ${r.mistakes} 条探针造的错题`);
    return 'users=0 quizzes=0 mistakes=0';
  });

  await pool.end();

  console.log('\n───────────────────────────────────────────────────────────────');
  if (failures.length === 0) {
    console.log(
      `  全部通过：${passed} 条判据${skipped > 0 ? `（另有 ${skipped} 条跳过，见上）` : ''}`,
    );
    console.log('───────────────────────────────────────────────────────────────\n');
    process.exit(0);
  }
  console.log(`  通过 ${passed} 条，失败 ${failures.length} 条${skipped > 0 ? `，跳过 ${skipped} 条` : ''}：`);
  for (const f of failures) console.log(`    · ${f}`);
  console.log('───────────────────────────────────────────────────────────────\n');
  process.exit(1);
}

main().catch((e) => {
  console.error(`\n探针异常中止：${e?.stack ?? e}\n`);
  process.exit(2);
});
