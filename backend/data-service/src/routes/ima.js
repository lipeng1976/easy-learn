import { ApiError, badRequest, forbidden } from '../../../shared/errors.js';
import { requireVisibleStudent } from '../auth.js';
import { withRequestContext } from '../db.js';
import * as ima from '../ima_openapi.js';
import {
  getStudentImaConfig,
  upsertImaCredential,
  setImaCredentialStatus,
  upsertImaStudentKb,
  decryptCredential,
  encryptCredential,
} from '../ima_repository.js';

/**
 * ima 连接端点（多家庭·多学生独立知识库 + 可选同步）。
 *
 * 设计见 `doc/ima-integration-design.md`。四条铁律：
 *   ① 无 ima 账号 → 不连接，`ima_status` 默认 `unconnected`，核心功能零影响；
 *   ② 凭证只在服务端**加密存储**，明文只存在于调用 ima 的那一瞬；
 *   ③ 密钥错 / ima 不可用 → 连接失败、且**绝不写入 active 凭证**（事务回滚）；
 *   ④ **配置主体是学生**（2026-11-08 定稿）：一切读写入口都是 `studentId`，
 *      `studentId → ima_student_kb → 配置人凭证`。父母共管同一个孩子时读到
 *      同一行、同一个 KB；切孩子状态跟着切；绝不按当前登录家长反推。
 */

/** 加解密密钥来自环境变量，绝不进库、绝不打日志。 */
const IMA_SECRET_ENV = 'IMA_CREDENTIAL_SECRET';

/**
 * 写操作的目标学生（connect / disconnect）。
 *
 * 新客户端总是带 `studentId`。旧 APK 不带时退到可见列表的第一个孩子
 * —— 关键是**只配这一个**，而不是退回「遍历所有孩子各建一个库」。
 * 越界 id 由 `requireVisibleStudent` 抛 403，不能靠 RLS 静默变空：
 * 写配置必须看得见拒绝。
 */
function resolveWritableStudentId(ctx, input) {
  const visible = ctx.visibleStudents ?? [];
  const requested = String(input?.studentId ?? '').trim();
  if (requested !== '') return requireVisibleStudent(visible, requested);
  if (visible.length === 0) throw badRequest('缺少 studentId');
  return visible[0];
}

/**
 * 只读状态的目标学生。
 *
 * ⚠️ 这个方法**永不抛错**：status 是页面加载就打的只读请求，
 * 按 11-07 硬规矩「没有 ima 不能出错」，越界 / 缺参都按「没开通」返回。
 * 学生端固定查自己；家长端用请求里当前伴学的学生。
 *
 * 旧 APK 不带 studentId 时，挑第一个**有配置**的可见学生 —— 比固定取第一个
 * 准（多孩子家庭里可能只有老二配过），而且依然只读、只回一个学生的状态。
 */
async function pickStudentForStatus(client, ctx, input) {
  const visible = ctx.visibleStudents ?? [];
  if (ctx.role === 'student') {
    return visible.includes(ctx.userId) ? ctx.userId : null;
  }
  const requested = String(input?.studentId ?? '').trim();
  if (requested !== '') return visible.includes(requested) ? requested : null;
  for (const id of visible) {
    if (await getStudentImaConfig(client, id)) return id;
  }
  return visible[0] ?? null;
}

function requireSecret() {
  const secret = process.env[IMA_SECRET_ENV];
  if (!secret) {
    // 这是服务端部署缺口，不是用户操作错误：用 500 类错误码提示运维。
    throw new ApiError(
      'server_config_missing',
      '服务端未配置 IMA_CREDENTIAL_SECRET，无法安全存储 ima 凭证',
      { status: 500 },
    );
  }
  return secret;
}

async function getStudentName(client, studentId) {
  const r = await client.query('select name from app_user where id = $1', [studentId]);
  return r.rows[0]?.name ?? studentId;
}

/** 只读展示用的名字：查不到就退 id，绝不把一次状态查询拖成错误。 */
async function safeStudentName(client, studentId) {
  try {
    return await getStudentName(client, studentId);
  } catch (_) {
    return studentId;
  }
}

/** 从 PG 取某学生错题（供 backfill）。受 RLS 约束（ctx.client 已设身份）。 */
async function fetchMistakesFromDb(client, studentId) {
  const r = await client.query(
    `select id, subject, title, question_body, question_no, wrong_reason, answer_key,
            knowledge_point, wrong_count, last_wrong_at, created_at, state, source_homework_title
       from review_mistake where student_id = $1
      order by wrong_count desc, last_wrong_at desc nulls last, created_at desc`,
    [studentId],
  );
  return r.rows;
}

/**
 * 从 PG 取某学生**已提交**的打卡（供 backfill 与提交后台推送）。
 *
 * 一条打卡一行，不是一题一行：ima 档案是给人翻的，一天十个小节
 * `## 2026-10-27` 会把它读成十天的记录。分数直接写成 `4/5`——
 * `buildCheckinsMarkdown` 的 `correct` 支持字符串，正是为这种「不是对错、
 * 而是一个比例」的结果留的。
 *
 * 没提交的（`pending`）不推：那是「今天的题已经出了」，不是「今天做过了」。
 * 把它推上去会让家长看到一条空打卡，反而以为孩子做完了。
 */
async function fetchCheckinsFromDb(client, studentId) {
  const r = await client.query(
    `select q.quiz_date::text as date, q.subject, q.questions, r.answers, r.score, r.total
       from checkin_quiz q
       join checkin_result r on r.quiz_id = q.id
      where q.student_id = $1
      order by q.quiz_date desc
      limit 200`,
    [studentId],
  );

  return r.rows.map((row) => {
    const questions = Array.isArray(row.questions) ? row.questions : [];
    const points = [...new Set(questions.map((q) => String(q?.knowledge ?? '').trim()))]
      .filter((point) => point !== '');
    return {
      date: row.date,
      subject: row.subject ?? '',
      knowledge: points.slice(0, 4).join('、'),
      question: `每日概念打卡（${row.total} 题）`,
      correct: `${row.score}/${row.total}`,
    };
  });
}

/**
 * 「这个学生的 ima 配置是什么」——按学生查，不按登录人猜。
 *
 * 🔴 旧实现的两条错路（§2.3）：
 *   · 家长分支直接返回 `ctx.userId` → 母亲交卷时推的是自己名下（没有）的凭证，
 *     父亲配好的库一次也推不上去；
 *   · 学生分支 `select parent_id ... limit 1` 无排序 → 父母共管时可能取到
 *     没配的那一位，交卷成功但档案**静默不推**。
 * 现在统一走 `studentId → ima_student_kb → 配置人凭证`，与「谁在提交」无关。
 *
 * ⚠️ 显式接 `client` 而不是从 `ctx.client` 取：app.js 对受保护路由统一调用
 *    `handler(client, ctx, input)`，而 `ctx` 里**没有** client 字段
 *    （见 db.js 的 `{ userId, role, sessionId, visibleStudents }`）。
 */
async function resolveConfigForStudent(client, ctx, studentId) {
  // 越权保护：交卷链路传进来的 quiz.student_id 必须确实在本次请求可见范围。
  if (!(ctx.visibleStudents ?? []).includes(studentId)) return null;
  return getStudentImaConfig(client, studentId);
}

/**
 * 把某个学生的错题 + 打卡推到 ima。
 *
 * ## 这是「可选同步」，所以它**永不抛错**
 *
 * 未连接、密钥失效、ima 挂了、密钥变量没配 —— 全部返回 `{synced:false, reason}`
 * 并打到日志里。调用方（提交打卡、连接后的 backfill）都不该因为「档案没推上去」
 * 而失败：学生做题这件事与「家长的知识库有没有更新」是两件事，
 * 后者失败不该让前者回滚。
 *
 * 返回结构化原因而不是 boolean，是因为排查时第一句话就是
 * 「为什么没同步」——`false` 回答不了这个问题。
 */
export async function syncStudentArchive(client, ctx, studentId) {
  // ⚠️ 11-07：整个函数体都必须待在 try 里。
  // 「永不抛错」不能只兜住 ima 的网络调用 —— resolveOwnerForStudent /
  // getImaCredential / getStudentName 也都在查 PG。生产库若漏跑 017/018，
  // 那条 42P01 会从这里冒泡，把**已经判完分的交卷**变成 500。
  // 现在无论 ima 侧发生什么，交卷拿到的都只是 `{synced:false, reason}`。
  try {
    const cfg = await resolveConfigForStudent(client, ctx, studentId);
    if (!cfg) return { synced: false, reason: 'no_owner' };
    if (!ima.shouldSync(cfg.status)) {
      return { synced: false, reason: `ima_status=${cfg.status}` };
    }

    const secret = process.env[IMA_SECRET_ENV];
    if (!secret) return { synced: false, reason: 'no_secret' };

    let dec;
    try {
      dec = decryptCredential({ clientidEnc: cfg.clientidEnc, apikeyEnc: cfg.apikeyEnc }, secret);
    } catch (e) {
      console.error(`[ima] 凭证解密失败 owner=${cfg.ownerUserId}: ${e?.message ?? e}`);
      return { synced: false, reason: 'decrypt_failed' };
    }

    const displayName = await getStudentName(client, studentId);
    try {
      await ima.syncStudentData({
        imaStatus: cfg.status,
        credential: dec,
        studentId,
        displayName,
        fetchMistakes: (sid) => fetchMistakesFromDb(client, sid),
        fetchCheckins: (sid) => fetchCheckinsFromDb(client, sid),
        fetchImpl: ctx.fetchImpl,
      });
      return { synced: true };
    } catch (e) {
      console.error(`[ima] 推送失败 student=${studentId}: ${e?.message ?? e}`);
      return { synced: false, reason: 'ima_error', message: e?.message ?? String(e) };
    }
  } catch (e) {
    // 表没建 / RLS / 连接池异常：一律按「没开通」处理，绝不拖垮主流程。
    console.error(`[ima] 可选同步意外失败 student=${studentId}: ${e?.message ?? e}`);
    return { synced: false, reason: 'ima_error', message: e?.message ?? String(e) };
  }
}

/**
 * 交卷后的 ima 后台归档队列。
 *
 * ## 为什么不能 `void syncStudentArchive(...)`
 *
 * 请求事务结束就把连接归还池里了。挂起的 promise 若还拿着那条 client，
 * 会在**别人的事务**上继续查 —— 那是最难查的一类串号（身份串、可见学生串，
 * 而且单请求测试全绿）。所以后台任务必须用自己的连接，走完整的
 * `withRequestContext(pool, identity, ...)`：SET LOCAL 身份、查可见学生、
 * 结束释放，和正常请求走同一条安全路径。
 *
 * ## 为什么串行
 *
 * ima 归档是**全量重建**（KB 查找 + 每科上传 MD），单次网络上限 15s/COS 60s。
 * 并行排几个学生会把连接池占满，交卷本身反而拿不到连接——那就把
 * 「可选同步」变成了「主流程故障」。同一学生重复排队的后来者覆盖前者：
 * 全量重建只要跑最新那一次，旧的没有意义。
 */
export function createImaArchiveQueue({ pool, logger = console }) {
  /** studentId -> { identity, fetchImpl } */
  const pending = new Map();
  // 存 promise 而不是 bool：schedule() 内部已经启动 drain，测试/运维想等它
  // 排空时 `await q.drain()` 必须等到同一轮结束，不能拿到一个假的「已完成」。
  let running = null;

  async function runOne(studentId) {
    const job = pending.get(studentId);
    if (!job) return;
    pending.delete(studentId);
    try {
      await withRequestContext(pool, job.identity, async (client, ctx) => {
        await syncStudentArchive(
          client,
          { ...ctx, fetchImpl: job.fetchImpl },
          studentId,
        );
      });
    } catch (e) {
      // 连接池借不到 / begin / commit 失败：绝不让未捕获的 rejection 冒到进程级。
      logger.error?.(`[ima] 后台归档失败 student=${studentId}: ${e?.message ?? e}`);
    }
  }

  function drain() {
    if (running) return running;
    running = (async () => {
      while (pending.size > 0) {
        await runOne(pending.keys().next().value);
      }
    })().finally(() => {
      running = null;
    });
    return running;
  }

  function schedule({ studentId, identity, fetchImpl }) {
    if (!studentId || !identity) return;
    pending.set(studentId, { identity, fetchImpl });
    // 不 await：交卷已经返回。drain 内每条任务都自己兜错。
    void drain().catch((e) => {
      logger.error?.(`[ima] 后台归档队列异常：${e?.message ?? e}`);
    });
  }

  return {
    schedule,
    drain,
    get pendingCount() { return pending.size; },
  };
}

/**
 * 连接 ima（受保护端点，走应用连接）。
 *
 * ⭐ 按学生配置（2026-11-08）：**一次只配请求里那一个学生**，不再遍历
 * `visibleStudents` 给所有孩子各建一个库。父母共管时，另一位家长看到的是
 * 同一行 `ima_student_kb`；这里若发现该学生已有 active 配置，直接复用返回，
 * 不联网、不建库、不写第二份凭证 —— 冲突从模型上消失。
 *
 * 流程：定位学生 → 已有配置则复用 → 加密 → 先建这一个学生的 KB（验证密钥）
 * → 写凭证 active + 一行 KB 映射（同事务）→ backfill（失败仅记日志）。
 */
export async function connectIma(client, ctx, body) {
  // 配置入口只在家长端；学生调用直接拒绝（学生端只读状态）。
  if (ctx.role !== 'parent') {
    throw forbidden('只有家长可以连接 ima 知识库');
  }
  const studentId = resolveWritableStudentId(ctx, body);

  // ⚠️ 复用检查放在 requireSecret / 密钥校验**之前**：另一位家长误触「连接」
  // 时，不该因为本机没配加密密钥就吃一个 500，更不该再建一个库。
  const existing = await getStudentImaConfig(client, studentId);
  if (existing && ima.shouldSync(existing.status)) {
    return {
      status: existing.status,
      kbs: [{ studentId, kbId: existing.kbId, kbName: existing.kbName }],
      studentId,
      studentName: await safeStudentName(client, studentId),
      ownerUserId: existing.ownerUserId,
      available: true,
      reused: true,
    };
  }
  // 映射还在、但配置人是另一位家长且状态非 active（如 expired / 已断开）：
  // 绝不能在本家长名下另写一份凭证再 `on conflict(student_id) do update` 覆盖
  // 归属（§2.3 的老 bug）。给一句能照做的提示，由配置人去更新密钥。
  if (existing && existing.ownerUserId !== ctx.userId) {
    throw badRequest('该学生的 ima 由另一位家长配置，请由配置人更新密钥');
  }

  const secret = requireSecret();
  const clientid = String(body?.clientid ?? '').trim();
  const apikey = String(body?.apikey ?? '').trim();
  if (clientid === '' || apikey === '') {
    throw badRequest('clientid 与 apikey 都不能为空');
  }

  const ownerUserId = ctx.userId;
  const fetchImpl = ctx.fetchImpl;

  // 第一步：只建这**一个**学生的 KB（真实调用 ima，顺带验证密钥）。
  // 失败会冒泡为错误响应；因在写凭证之前发生，事务回滚，不留 half-baked 凭证。
  // 重连时 `ensureStudentKb` 会按库名幂等查重，命中即复用，不会建第二个库。
  const displayName = await getStudentName(client, studentId);
  const { kbId, kbName } = await ima.ensureStudentKb({
    clientId: clientid,
    apiKey: apikey,
    fetchImpl,
    studentId,
    displayName,
  });
  // kbName 只用 ensureStudentKb 返回的那一份：库名只允许 `buildKbName` 一处生成。
  const kbs = [{ studentId, kbId, kbName }];

  // 第二步：写凭证 active + 该学生一行 KB 映射（同事务）。
  const enc = encryptCredential({ clientid, apikey }, secret);
  await upsertImaCredential(client, {
    ownerUserId,
    clientidEnc: enc.clientidEnc,
    apikeyEnc: enc.apikeyEnc,
    status: ima.IMA_STATUS.ACTIVE,
    kbOwnerName: kbName,
  });
  await upsertImaStudentKb(client, { studentId, ownerUserId, kbId, kbName });

  // 第三步：backfill（错题 + 打卡）。不阻断连接 —— 失败仅记日志，
  // 数据仍在 PG，下次提交或重连会再推一遍（上传是覆盖写，重复没有副作用）。
  await syncStudentArchive(client, ctx, studentId);

  return {
    status: ima.IMA_STATUS.ACTIVE,
    kbs,
    studentId,
    studentName: displayName,
    ownerUserId,
    available: true,
  };
}

/**
 * 断开 ima：按学生找到配置人，把那一行凭证标记 `unconnected`，保留 KB 映射。
 * 此后所有推送在 `shouldSync` 守卫处静默跳过，核心功能不受影响。
 */
export async function disconnectIma(client, ctx, body) {
  if (ctx.role !== 'parent') {
    throw forbidden('只有家长可以断开 ima 知识库');
  }
  const studentId = resolveWritableStudentId(ctx, body);

  // 断开也是「可选功能」：表没建 / 库连不上时不该让家长端飘红。
  try {
    const existing = await getStudentImaConfig(client, studentId);
    if (!existing) return { status: ima.IMA_STATUS.UNCONNECTED, studentId };
    // RLS 只放行配置人改自己的凭证行（017），另一位家长改不动；
    // 与其静默失败（点了没反应），不如明确说明该找谁。状态本身两家共享。
    if (existing.ownerUserId !== ctx.userId) {
      throw forbidden('该学生的 ima 由另一位家长配置，请由配置人断开');
    }
    await setImaCredentialStatus(client, existing.ownerUserId, ima.IMA_STATUS.UNCONNECTED);
  } catch (e) {
    if (e instanceof ApiError) throw e;
    console.error(`[ima] 断开失败（按未连接处理）: ${e?.message ?? e}`);
  }
  return { status: ima.IMA_STATUS.UNCONNECTED, studentId };
}

/** 这个部署是否具备 ima 能力（没配密钥 = 整个服务没开通 ima）。 */
function imaFeatureAvailable() {
  return Boolean(process.env[IMA_SECRET_ENV]);
}

/**
 * 查询**当前伴学学生**的连接状态与他的 KB。
 *
 * ⚠️ 11-07：这是**页面加载就会打**的只读请求，必须永不抛错。
 * 表未迁移 / RLS / 网络异常 / 越界 studentId 一律按「没开通」返回，
 * 否则个人信息页与设置页会因为一个可选功能飘红。
 * `available=false` 告诉客户端把入口整体藏起来：功能可以没有，但不能报错。
 *
 * ⭐ 11-08：状态**按学生**算，返回的 `kbs` 只含这个学生那一个库。
 * 父母共管、学生只读，走的都是 `studentId → 映射 → 配置人凭证` 同一条路。
 */
export async function getImaStatus(client, ctx, input = {}) {
  const available = imaFeatureAvailable();
  const fallback = {
    status: ima.IMA_STATUS.UNCONNECTED,
    kbs: [],
    ownerUserId: null,
    studentId: null,
    available,
  };
  // 整个部署没开通 ima：连库都不碰，避免「没跑 017」时每次进页面刷一条 42P01。
  if (!available) return fallback;
  try {
    const studentId = await pickStudentForStatus(client, ctx, input);
    if (!studentId) return fallback;
    // 名字只取一次，两个分支共用：没配置时也要显示「当前学生：李小明」，
    // 否则设置页只能拿 UUID 顶上去，家长看不出正在配哪个孩子。
    const studentName = await safeStudentName(client, studentId);
    const cfg = await getStudentImaConfig(client, studentId);
    if (!cfg) return { ...fallback, studentId, studentName };
    return {
      status: cfg.status,
      kbs: [{ studentId, kbId: cfg.kbId, kbName: cfg.kbName }],
      ownerUserId: cfg.ownerUserId,
      studentId,
      studentName,
      available,
    };
  } catch (e) {
    console.error(`[ima] 状态查询失败（按未开通处理）: ${e?.message ?? e}`);
    return fallback;
  }
}
