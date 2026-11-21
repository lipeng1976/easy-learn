#!/usr/bin/env node
/**
 * 演示数据（服务端版）。
 *
 * ## 为什么是脚本而不是一份 SQL 种子
 *
 * 演示数据有两个用途，而 **SQL 只能满足其中一个**：
 * 一是「打开界面有东西看」，二是「这条链路的每一步都真的通」。
 * 灌 SQL 能造出好看的数据，但它绕过注册、结伴、批改这些端点 ——
 * 于是演示时看到的每一条数据都是「脚本直接写进库的」，接口通不通一无所知。
 *
 * 所以这里**全部走 HTTP**，一条 SQL 都不写。代价是慢一点、要处理幂等；
 * 收益是演示数据本身就是一次端到端自测：脚本能跑完，说明注册 → 登录 →
 * 结伴 → 布置作业 → 提交 → 批改 → 记错题 → 打卡 → 积分 → 心愿 → 点评
 * 这条链路上的端点**全部是通的**。
 *
 * ## 幂等
 *
 * 可以反复跑。判重一律用**业务自然键**（作业标题、计划标题、错题标题…）
 * 而不是「跑过一次就写个标记」—— 后者在手动删掉某条数据之后会永远补不回来。
 * 积分与打卡是天然幂等的（幂等键 / 唯一约束），直接交给服务端判。
 *
 * 跑法：`npm run seed:demo`（需要服务已经在跑）
 */
import { LOCAL_PG } from '../src/pg-local.js';

/** 演示账号。密码与客户端本地种子（`local_seed_service.dart`）保持一致。 */
export const DEMO = {
  password: 'abc123',
  student: { phone: '13800000001', name: '林小宇', role: 'student' },
  student2: { phone: '13800000003', name: '林小桐', role: 'student' },
  parent: { phone: '13800000002', name: '王老师', role: 'parent' },
};

const DEFAULT_BASE = `http://127.0.0.1:${process.env.PORT ?? 8788}`;

/** 本地日期 `YYYY-MM-DD`（学生所在时区的「今天」）。 */
function today(offsetDays = 0) {
  const d = new Date(Date.now() + offsetDays * 86400000);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

const isoIn = (days, hour = 20) => {
  const d = new Date(Date.now() + days * 86400000);
  d.setHours(hour, 0, 0, 0);
  return d.toISOString();
};

/**
 * 这个时间戳是不是**今天**（本地日）。
 *
 * 判重只看业务自然键（标题）是不够的：客户端把作业按 `dueAt` 那一天分组
 * （`homework_tab.dart` 的 `_isSameDay(item.dueAt, 选中日期)`，首页与家长端
 * 同理），所以「昨天灌的作业」在今天照样算「已存在」，而它在界面上**一条都不显示**。
 * 两个判断单独看都对，合起来就是「演示栈放一晚上，第二天打开说今天没作业」——
 * 数据都在，只是全留在昨天。演示栈每次启动都会跑一遍这个脚本，
 * 所以这里必须把「今天有没有」也算进幂等判据。
 */
function isToday(iso) {
  if (!iso) return false;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return false;
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}` === today();
}

/**
 * 一次 HTTP 调用。
 *
 * 失败时把**服务端的错误码与文案**原样抛出：这个脚本的价值一半在于
 * 「跑不通时能立刻指出是哪一步断的」，把错误吞成一句「seeding failed」
 * 会把这个价值抹掉。
 */
async function call(base, method, pathname, { token, body, query } = {}) {
  const url = new URL(pathname, base);
  for (const [k, v] of Object.entries(query ?? {})) {
    if (v !== undefined && v !== null && v !== '') url.searchParams.set(k, String(v));
  }
  const res = await fetch(url, {
    method,
    headers: {
      ...(body === undefined ? {} : { 'content-type': 'application/json' }),
      ...(token === undefined ? {} : { authorization: `Bearer ${token}` }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok || json.ok === false) {
    const code = json?.error?.code ?? `http_${res.status}`;
    throw new Error(`${method} ${pathname} → ${code}：${json?.error?.message ?? '(无文案)'}`);
  }
  return json.data ?? {};
}

/** 登录；没注册过就注册。返回 `{ token, user }`。 */
async function ensureAccount(base, { phone, role, name }, log) {
  try {
    const data = await call(base, 'POST', '/auth/login', { body: { phone, password: DEMO.password } });
    log(`账号已存在：${name}（${phone}）`);
    return { token: data.token, user: data.user };
  } catch {
    const data = await call(base, 'POST', '/auth/register', {
      body: { phone, password: DEMO.password, role, name },
    });
    log(`新建账号：${name}（${phone}）`);
    return { token: data.token, user: data.user };
  }
}

/** 确保「家长 ↔ 学生」已结伴。邀请由家长发起、学生确认 —— 与真实流程一致。 */
async function ensureRelationship(base, parent, student, log) {
  const { items = [] } = await call(base, 'GET', '/data/relationship', { token: parent.token });
  const mine = items.filter((r) => r.studentId === student.user.id);
  if (mine.some((r) => r.status === 'active')) {
    log(`已结伴：${parent.user.name} ↔ ${student.user.name}`);
    return;
  }
  const pending = mine.find((r) => r.status === 'pending');
  const rel = pending ?? (await call(base, 'POST', '/data/relationship/invite', {
    token: parent.token,
    body: { targetPhone: student.user.phone },
  })).relationship;
  await call(base, 'POST', '/data/relationship/status', {
    token: student.token,
    body: { id: rel.id, status: 'active' },
  });
  log(`结伴完成：${parent.user.name} ↔ ${student.user.name}`);
}

/** 取某学生的作业，按标题索引。 */
async function homeworkIndex(base, token, studentId) {
  const { items = [] } = await call(base, 'GET', '/data/homework', {
    token,
    query: { studentId },
  });
  return new Map(items.map((h) => [h.title, h]));
}

/**
 * 一份「已完成批改」的作业。
 *
 * 刻意不调某个「批改」端点，而是**两次 updateHomework(patch)** ——
 * 与客户端 `StudentController` 完全一致：提交是一次掩码、批改结果又是一次。
 * 演示数据因此顺便证明了「掩码语义在网络边界上保得住」。
 */
async function ensureGradedHomework(base, student, log) {
  const index = await homeworkIndex(base, student.token, student.user.id);
  const existing = index.get('数学练习册 P32');
  // 判重必须带**日期**（见 `isToday`）：作业的 `dueAt` 不能改，
  // 它不在 `PATCH_SPEC` 里（服务端故意的，防止客户端把整行覆盖掉），
  // 所以「让今天有作业」的唯一合法做法是**补一份今天的**。
  // 昨天那份留作历史 —— 真实的作业流水本来也是每天一份。
  if (existing && isToday(existing.dueAt)) {
    log(`作业已存在：${student.user.name} / 数学练习册 P32（今天）`);
    return existing;
  }

  const { item } = await call(base, 'POST', '/data/homework', {
    token: student.token,
    body: {
      studentId: student.user.id,
      title: '数学练习册 P32',
      subject: '数学',
      dueAt: isoIn(0, 23),
      estimatedMinutes: 25,
      needsGrading: true,
      aiEnabled: true,
    },
  });

  const batchId = `demo-${Date.now()}`;
  // ① 提交：与 `StudentController.submitHomework` 拼的掩码逐字段一致。
  await call(base, 'POST', '/data/homework/update', {
    token: student.token,
    body: {
      id: item.id,
      status: 'checking',
      submittedAt: new Date().toISOString(),
      submitBatchId: batchId,
      imageCount: 1,
      needsGrading: true,
      gradingSource: '',
      checkedAt: null,
      score: null,
      summary: '',
    },
  });
  // ② 批改完成：同样是一次掩码。
  await call(base, 'POST', '/data/homework/update', {
    token: student.token,
    body: {
      id: item.id,
      status: 'finished',
      checkedAt: new Date().toISOString(),
      score: 86,
      summary: '计算基本正确，第 3 题单位换算漏了一步，建议再练一练。',
      wrongCount: 2,
      gradingSource: 'cloud',
      needsGrading: false,
    },
  });
  log(`作业已布置并批改：${student.user.name} / 数学练习册 P32（86 分）`);
  return { ...item, id: item.id };
}

/** 两条错题 —— 由上面那份批改结果带出来（`homeworkId` 指向它）。 */
async function ensureMistakes(base, student, homework, log) {
  const { items = [] } = await call(base, 'GET', '/data/review/mistakes', { token: student.token });
  // 判重按**题面**而不是 `homeworkId`：上面那份作业现在是每天补一份新的
  // （见 `ensureGradedHomework`），按 id 判会让同样的两道题一天进一次错题本，
  // 一周下来「错题本」里躺着 14 条一模一样的记录 —— 那不是错题本，是日志。
  // 题面才是错题的自然键：同一道题不该因为换了一份作业就变成两道错题。
  if (items.some((m) => m.title === '3.5 千米 = ? 米')) {
    log(`错题已存在：${student.user.name}`);
    return;
  }
  await call(base, 'POST', '/data/review/mistakes/insert', {
    token: student.token,
    body: {
      studentId: student.user.id,
      items: [
        {
          homeworkId: homework.id,
          subject: '数学',
          title: '3.5 千米 = ? 米',
          originalAnswer: '350 米',
          wrongReason: '单位换算时把「千米 → 米」当成了「千米 → 百米」',
          knowledgePoint: '长度单位换算',
          sourceHomeworkTitle: '数学练习册 P32',
          state: 'pending',
          wrongCount: 1,
          lastWrongAt: new Date().toISOString(),
        },
        {
          homeworkId: homework.id,
          subject: '数学',
          title: '24 ÷ 6 × 2',
          originalAnswer: '2',
          wrongReason: '没有按从左到右的顺序算，先算了乘法',
          knowledgePoint: '四则混合运算',
          sourceHomeworkTitle: '数学练习册 P32',
          state: 'pending',
          wrongCount: 1,
          lastWrongAt: new Date().toISOString(),
        },
      ],
    },
  });
  log(`错题已入池：${student.user.name}（2 条）`);
}

async function ensureStudyPlan(base, student, log) {
  const { items = [] } = await call(base, 'GET', '/data/study-plans', {
    token: student.token,
    query: { studentId: student.user.id },
  });
  let plan = items.find((p) => p.title === '每日 20 分钟口算');
  if (!plan) {
    ({ item: plan } = await call(base, 'POST', '/data/study-plans', {
      token: student.token,
      body: {
        studentId: student.user.id,
        title: '每日 20 分钟口算',
        content: '每天 20 道两位数乘除法，错的抄进错题本',
        startAt: isoIn(-3, 8),
        endAt: isoIn(27, 22),
        type: 'daily',
        // 服务端词表见 `src/vocab.js`。`active` 两侧同词（2026-09-20 统一前
        // 服务端用 `accepted`）；但**其余的词仍不同** —— 客户端的
        // `pendingStudentConfirm` / `withdrawn` 在服务端没有对应值，
        // 所以客户端上行仍要经过一层翻译，不能直接送 `.name`。
        status: 'active',
        cycleType: 'daily',
      },
    }));
    log(`学习计划已创建：${student.user.name} / 每日 20 分钟口算`);
  } else {
    log(`学习计划已存在：${student.user.name} / 每日 20 分钟口算`);
  }

  await call(base, 'POST', '/data/study-plans/checkin', {
    token: student.token,
    body: { studentId: student.user.id, planId: plan.id, date: today() },
  });
  log(`今日打卡：${student.user.name} / ${today()}`);
}

/** 积分与打卡是天然幂等的（幂等键 / 唯一约束），直接交给服务端判。 */
async function ensurePoints(base, student, log) {
  await call(base, 'POST', '/data/points/earn', {
    token: student.token,
    body: {
      studentId: student.user.id,
      action: 'homework_finished',
      points: 10,
      reason: '完成「数学练习册 P32」',
      idempotencyKey: 'demo:homework:P32',
      refType: 'homework',
    },
  });
  await call(base, 'POST', '/data/points/earn', {
    token: student.token,
    body: {
      studentId: student.user.id,
      action: 'study_plan_checkin',
      points: 5,
      reason: '学习计划打卡',
      idempotencyKey: `demo:checkin:${today()}`,
      refType: 'study_plan',
    },
  });
  const { balance } = await call(base, 'GET', '/data/points/balance', {
    token: student.token,
    query: { studentId: student.user.id },
  });
  log(`积分：${student.user.name} 当前 ${balance}`);
}

async function ensureWish(base, student, log) {
  const { items = [] } = await call(base, 'GET', '/data/wishes', {
    token: student.token,
    query: { studentId: student.user.id },
  });
  if (items.some((w) => w.title === '周末去动物园')) {
    log(`心愿已存在：${student.user.name} / 周末去动物园`);
    return;
  }
  await call(base, 'POST', '/data/wishes', {
    token: student.token,
    body: {
      studentId: student.user.id,
      title: '周末去动物园',
      description: '用 50 积分换一次周末去动物园',
      pointCost: 50,
      isPublic: true,
      expectedDate: isoIn(7, 9),
    },
  });
  log(`心愿已许下：${student.user.name} / 周末去动物园`);
}

async function ensureDailyComment(base, parent, student, log) {
  const { items = [] } = await call(base, 'GET', '/data/daily-comments', { token: parent.token });
  if (items.some((c) => c.studentId === student.user.id)) {
    log(`点评已存在：${student.user.name}`);
    return;
  }
  await call(base, 'POST', '/data/daily-comments', {
    token: parent.token,
    body: {
      studentId: student.user.id,
      rating: 'A',
      content: '今天主动把错题抄进了错题本，口算也进步了，继续保持。',
    },
  });
  log(`家长点评已发布：${student.user.name}`);
}

/**
 * 灌一份可演示的数据。
 *
 * @param {{base?: string, log?: (msg: string) => void}} options
 */
export async function seedDemo({ base = DEFAULT_BASE, log = () => {} } = {}) {
  const student = await ensureAccount(base, DEMO.student, log);
  const student2 = await ensureAccount(base, DEMO.student2, log);
  const parent = await ensureAccount(base, DEMO.parent, log);

  await ensureRelationship(base, parent, student, log);
  await ensureRelationship(base, parent, student2, log);

  const hw = await ensureGradedHomework(base, student, log);
  await ensureMistakes(base, student, hw, log);
  await ensureStudyPlan(base, student, log);
  await ensurePoints(base, student, log);
  await ensureWish(base, student, log);

  // 第二个孩子留一份**待完成**的作业：演示时用来看「学生端有什么要做」。
  // 同样按「今天有没有」判（见 `isToday`）—— 只看标题的话，第二天它会变成
  // 一份昨天到期的作业，而学生的「今天」列表里什么都没有。
  //
  // `dueAt` 定在 23:00 而不是更早：未提交又过了截止时间的作业会被客户端的
  // 超时扫描改成 `timeout`（`StudentController._sweepOverdue`），
  // 而那是一次**真写库**的副作用。定在当天末尾，白天和傍晚跑演示时
  // 它都还是「待完成」，这也正是这份数据存在的意义。
  const index2 = await homeworkIndex(base, student2.token, student2.user.id);
  const pending2 = index2.get('语文背诵《静夜思》');
  if (!pending2 || !isToday(pending2.dueAt)) {
    await call(base, 'POST', '/data/homework', {
      token: student2.token,
      body: {
        studentId: student2.user.id,
        title: '语文背诵《静夜思》',
        subject: '语文',
        dueAt: isoIn(0, 23),
        estimatedMinutes: 15,
        needsGrading: false,
        aiEnabled: true,
      },
    });
    log(`作业已布置：${student2.user.name} / 语文背诵《静夜思》（今天）`);
  }
  await ensureDailyComment(base, parent, student, log);

  return { base, accounts: { student, student2, parent } };
}

// ===== CLI =====
if (import.meta.url === `file://${process.argv[1]?.replace(/\\/g, '/')}`) {
  const base = process.env.DATA_BASE_URL ?? DEFAULT_BASE;
  const log = (m) => process.stdout.write(`[seed] ${m}\n`);
  try {
    await seedDemo({ base, log });
    log('完成');
  } catch (e) {
    log(`失败：${e.message}`);
    log(`提示：服务是否已经在跑？（${base}，PG 端口 ${LOCAL_PG.port}）`);
    process.exitCode = 1;
  }
}
