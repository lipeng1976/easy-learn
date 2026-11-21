#!/usr/bin/env node
/**
 * 演示栈的「看一眼」探针：**登录 → 各端读到东西 → 家长看得到孩子的**。
 *
 * 与 `smoke-http.mjs` 的分工：那个自己起临时库、验的是「HTTP 这条路通不通」，
 * 跑完什么都不留；这个**打的是一个已经在跑的栈**，验的是
 * 「现在这份演示数据真的能看到、家长真的看得到」—— 演示前跑一次，
 * 免得打开浏览器才发现是空的。
 *
 * 跑法：`node scripts/probe-demo.mjs [--base=http://127.0.0.1:8788]`
 */
const args = new Set(process.argv.slice(2));
const BASE = [...args].find((a) => a.startsWith('--base='))?.slice(7)
  ?? process.env.DATA_BASE_URL
  ?? 'http://127.0.0.1:8788';

const log = (...p) => process.stdout.write(`${p.join(' ')}\n`);
const failures = [];

function check(name, cond, detail = '') {
  if (cond) log(`✓ ${name}${detail ? ` —— ${detail}` : ''}`);
  else {
    log(`✗ ${name}${detail ? ` —— ${detail}` : ''}`);
    failures.push(name);
  }
}

const get = (pathname, token) => fetch(new URL(pathname, BASE), {
  headers: token ? { authorization: `Bearer ${token}` } : {},
}).then((r) => r.json());

const post = (pathname, body, token) => fetch(new URL(pathname, BASE), {
  method: 'POST',
  headers: {
    'content-type': 'application/json',
    ...(token ? { authorization: `Bearer ${token}` } : {}),
  },
  body: JSON.stringify(body),
}).then((r) => r.json());

async function login(phone, role) {
  const j = await post('/auth/login', { phone, password: 'abc123', role });
  if (!j.ok) throw new Error(`${phone} 登录失败：${j.error?.code} ${j.error?.message ?? ''}`);
  return j.data;
}

try {
  const health = await get('/health');
  check('数据服务在跑', health.ok === true, BASE);
} catch {
  log(`✗ 连不上 ${BASE} —— 先把栈起起来：npm run dev:stack`);
  process.exit(1);
}

const student = await login('13800000001', 'student');
const parent = await login('13800000002', 'parent');
check('演示账号能登录', student.user.name === '林小宇' && parent.user.name === '王老师',
  `${student.user.name} / ${parent.user.name}`);

// 学生侧：作业、错题、计划、积分、心愿
const hw = await get('/data/homework', student.token);
const graded = hw.data.items.find((h) => h.score !== null && h.score !== undefined);
check('学生首页有作业', hw.data.items.length > 0, `${hw.data.items.length} 份`);
check('有一份已批改（演示要用）', Boolean(graded),
  graded ? `${graded.title} 得分 ${graded.score}` : '没有 score 不为空的作业');

const mistakes = await get('/data/review/mistakes', student.token);
check('错题池不空', mistakes.data.items.length > 0, `${mistakes.data.items.length} 条`);

const plans = await get('/data/study-plans', student.token);
check('学习计划不空', plans.data.items.length > 0, plans.data.items.map((p) => p.title).join(' / '));

const balance = await get(`/data/points/balance?studentId=${student.user.id}`, student.token);
check('积分有余额', (balance.data.balance ?? 0) > 0, `余额 ${balance.data.balance}`);

const wishes = await get('/data/wishes', student.token);
check('心愿不空', wishes.data.items.length > 0, wishes.data.items.map((w) => w.title).join(' / '));

// 家长侧：**这才是上云的意义** —— 孩子那台设备写的东西，家长这台能看到
const parentHw = await get(`/data/homework?studentId=${student.user.id}`, parent.token);
check('家长看得到孩子的作业', parentHw.data.items.length === hw.data.items.length,
  `家长 ${parentHw.data.items.length} / 学生 ${hw.data.items.length}`);

const parentMistakes = await get(`/data/review/mistakes?studentId=${student.user.id}`, parent.token);
check('家长看得到孩子的错题', parentMistakes.data.items.length === mistakes.data.items.length,
  `家长 ${parentMistakes.data.items.length} / 学生 ${mistakes.data.items.length}`);

// ⚠️ 家长首页上的「孩子」**不是**从作业列表推出来的，而是从**结伴关系**读出来的
// （`ParentController._loadBoundStudentHomework` ← `/data/relationship`）。
// 不测这一条会漏掉一种自相矛盾的演示事故：上面「家长看得到孩子的作业」全绿，
// 而家长首页上写着「尚未与任何学生结伴」、什么都不显示。
//
// 判据用服务端自己的词表（`vocab.js` 的 `active`）。2026-09-20 之前服务端用
// `accepted`、客户端用 `active`，两套词靠客户端仓库层翻译活着；现在两侧逐字相同，
// 这条判据不再需要跟着翻译走。
const parentRels = await get('/data/relationship', parent.token);
const relItems = parentRels.data?.items ?? [];
const activeRels = relItems.filter((r) => r.status === 'active');
check('家长读得到已结伴的关系', activeRels.length > 0,
  relItems.length ? `status=${relItems.map((r) => r.status).join(',')}` : '一条关系都没有');
check('关系指向的正是演示的那个孩子',
  activeRels.some((r) => r.studentId === student.user.id), student.user.id);

const childProfile = await get(`/data/users?ids=${student.user.id}`, parent.token);
check('家长读得到孩子档案（要把 id 显示成姓名）',
  (childProfile.data?.items ?? []).length === 1 && childProfile.data.items[0].name === '林小宇',
  (childProfile.data?.items ?? []).map((u) => u.name).join(' / ') || '没读到');

// 心愿有三个口径，**家长首页读的是 public**。只测学生那条（默认 created）
// 等于没测到家长这条路 —— 这条分支的 SQL 曾经参数个数与占位符对不上，
// 直接 500，而当时「心愿不空」是绿的。
for (const scope of ['created', 'public', 'unfulfilled']) {
  const w = await get(`/data/wishes?scope=${scope}`, parent.token);
  check(`家长读心愿 scope=${scope}`, w.ok === true && Array.isArray(w.data?.items),
    w.ok ? `${w.data.items.length} 条` : `${w.error?.code} ${w.error?.message ?? ''}`);
}

const notifications = await get('/data/notifications', parent.token);
check('家长收到了服务端生成的通知', notifications.data.items.length > 0,
  notifications.data.items.map((n) => n.title).join(' / ') || '一条都没有');

const comments = await get('/data/daily-comments', parent.token);
check('家长点评不空', comments.data.items.length > 0, `${comments.data.items.length} 条`);

// 越权面：家长不该看得到别人家孩子的（这里用一个学生 token 去读另一个学生）
const other = await login('13800000003', 'student');
const cross = await fetch(
  new URL(`/data/homework?studentId=${student.user.id}`, BASE),
  { headers: { authorization: `Bearer ${other.token}` } },
).then((r) => r.json());
check('另一个学生读不到别人的作业（403）',
  cross.ok === false && cross.error?.code === 'forbidden',
  `${cross.error?.code}`);

// 家长端「运行观察」页的第一步：读孩子的**判定记录**。
//
// 这一条以前不在任何判据里，而它一旦出问题，症状**不在它自己身上**：
// 那一页是「先读本地记录（`_loadLocal`）→ 再读云端看板（`_loadCloud`）」，
// 第一步抛了或挂住，第二步压根不会执行，界面上是**看板一直转圈** ——
// 看起来完全像网络问题（2026-09-20 排查这件事花的正是这个时间）。
//
// ⚠️ 必须带超时：如果它是挂住而不是报错，普通 fetch 会把整个探针一起挂死，
// 而「探针挂死」这个现象本身又会被误读成「服务没起来」。
let abOutcome;
try {
  const res = await fetch(
    new URL(`/data/review/judgement-ab?studentId=${student.user.id}`, BASE),
    { headers: { authorization: `Bearer ${parent.token}` }, signal: AbortSignal.timeout(8000) },
  );
  abOutcome = { status: res.status, body: await res.json().catch(() => ({})) };
} catch (e) {
  abOutcome = { status: 0, error: e.name === 'TimeoutError' ? '8s 超时（挂住）' : String(e.message) };
}
check('家长读得到孩子的判定记录（运行观察页的第一步）',
  abOutcome.body?.ok === true,
  abOutcome.body?.ok
    ? `${abOutcome.body.data?.items?.length ?? 0} 条`
    : `${abOutcome.status} ${abOutcome.error ?? ''} ${abOutcome.body?.error?.code ?? ''}`.trim());

// ===== AI 网关：数据服务签的票，网关认不认 =====
//
// 这一段是 `AI_REQUIRE_AUTH=true` 那条路唯一的**实盘**检查。
// 单元测试能证明「客户端把票发出去了」，证明不了「网关认这张票」——
// 那取决于两件事：两边用的是不是同一把 `AI_SESSION_SECRET`，
// 以及票的载荷两边理解是否一致。对不上的症状是**所有 AI 调用 401**，
// 而数据链路全绿，看起来像「AI 服务挂了」。
//
// 用 `/ai/metrics` 而不是某个模型端点：它要身份但**不占学生配额**，
// 验鉴权不该顺手烧掉孩子的批改额度。
//
// 网关没起就跳过（不判失败）—— 本机可以只起数据服务。
const AI_BASE = [...args].find((a) => a.startsWith('--ai-base='))?.slice(10)
  ?? process.env.AI_GATEWAY_URL
  ?? 'http://127.0.0.1:8787';

async function aiGet(pathname, token) {
  const res = await fetch(new URL(pathname, AI_BASE), {
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });
  return { status: res.status, body: await res.json().catch(() => ({})) };
}

let aiHealth = null;
try {
  aiHealth = await aiGet('/ai/health');
} catch {
  log('');
  log(`· AI 网关没起（${AI_BASE}），跳过鉴权检查`);
}

if (aiHealth) {
  log('');
  log(`— AI 网关（${AI_BASE}）`);
  check('AI 网关在跑', aiHealth.body.ok === true);

  const enforced = aiHealth.body.data?.auth?.enforced;
  // 这条是本节的前提：开关关着时下面两条**也会通过**，
  // 而它们通过的路径压根不是我们要验的那条。少了它，
  // 「票能被认」会被误读成「强鉴权没问题」，实际什么也没验到。
  check('网关确实开着强鉴权', enforced === true, `auth.enforced=${enforced}`);

  const withTicket = await aiGet('/ai/metrics', student.token);
  check('数据服务签的票，网关认', withTicket.body.ok === true,
    withTicket.body.ok
      ? '看板可取'
      : `${withTicket.status} ${withTicket.body.error?.code} ${withTicket.body.error?.message ?? ''}`);

  const noTicket = await aiGet('/ai/metrics');
  check('不带票被拒（401 unauthorized）',
    noTicket.status === 401 && noTicket.body.error?.code === 'unauthorized',
    `${noTicket.status} ${noTicket.body.error?.code ?? '(无错误码)'}`);
}

log('');
log(failures.length === 0 ? '演示数据齐了，可以打开客户端。' : `有 ${failures.length} 项没到位：${failures.join('、')}`);
process.exit(failures.length === 0 ? 0 : 1);
