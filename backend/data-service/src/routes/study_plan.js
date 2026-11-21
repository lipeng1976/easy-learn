import { badRequest, forbidden } from '../../../shared/errors.js';
import { UserRoles } from '../../../shared/token.js';
import { requireVisibleStudent } from '../auth.js';
import { rowToApi, rowsToApi } from '../mapper.js';
import { buildInsert } from '../insert.js';
import { toDate, toEnum, toText, toTs, requireText } from '../coerce.js';
import { STUDY_PLAN_STATUSES } from '../vocab.js';
import { notifyBoundPartners, parentIdsOf, NotificationTypes } from './notify.js';

/**
 * 学习计划与每日打卡。
 *
 * ## 这个文件里有一条**藏在数据访问方法里**的业务规则，必须照搬
 *
 * `StudyPlanRepository.queryStudyPlans` 的两个分支是不对称的
 * （`database_service.dart:2457`）：
 *
 *     final visible = (row) => userRole == 'student' || row['userRole'] == userRole;
 *     // 学生可见自己的全部计划（含家长发来待确认的）；家长仅看家长侧记录
 *
 * 也就是：**学生看到全部计划，家长只看自己发出的**。接口注释专门警告过
 * 「换实现的人会以为 Student 分支那个全表查询是笔误，顺手修成过滤 ——
 * 于是学生看不到家长发来的计划了」。
 *
 * 服务端的等价规则（**按 token 判，不照抄「student 就返回全表」**）：
 *
 *     student_id = any(visible_students)                -- 范围永远来自身份
 *     and (ctx.role = 'student' or user_role = ctx.role) -- 学生的全量 / 家长的只自己发的
 *
 * 「全表」在这里退化成「我自己的全部」—— 单机单库下这两者是同一件事，
 * 而多租户下前者是**跨学生越权**。这是把陷阱⑥下推之后，规则本身一个字没变。
 */

const PLAN_SPEC = {
  title: (v) => (v === null || v === undefined ? null : String(v)),
  content: (v) => (v === null || v === undefined ? null : String(v)),
  startAt: (v, f) => toTs(v, f),
  endAt: (v, f) => toTs(v, f),
  type: (v) => (v === null || v === undefined ? null : String(v)),
  status: (v) => (v === null || v === undefined ? null : String(v)),
  cycleType: (v) => toText(v) ?? 'daily',
  customWeekdays: (v) => toText(v),
  rejectReason: (v) => toOptionalText(v),
};

/**
 * `rejectReason` 在客户端是字符串（空串表示「没有拒绝理由」），
 * 而接口注释写明「传空串会被规范化成 null（查询端按 NULL 判断）」。
 * 这条规范化必须留在服务端：读端按 NULL 判断，写端如果落的是空串，
 * 「这个计划有没有被拒绝过」就再也查不出来了。
 */
function toOptionalText(v) {
  if (v === null || v === undefined) return null;
  const s = String(v).trim();
  return s === '' ? null : s;
}

// ===== 计划 =====

export async function listPlans(client, ctx, query) {
  const status = query?.status ? String(query.status) : null;
  const r = await client.query(
    `select * from study_plan
      where student_id = any($1::text[])
        and ($2::text is null or status = $2)
        and ($3::text is null or user_role = $3)
      order by start_at desc nulls last, id`,
    // 学生传 null（= 不加这个条件 → 看到自己的全部）；家长传 'parent'（只看自己发的）。
    [ctx.students, status, ctx.role === UserRoles.student ? null : ctx.role],
  );
  return { items: rowsToApi(r.rows) };
}

/** 新建计划。`user_role` 由服务端写（家长发起的记 parent，学生自建记 student）。 */
export async function insertPlan(client, ctx, body) {
  const studentId = requireVisibleStudent(ctx.visibleStudents, body.studentId);
  const ins = buildInsert({
    table: 'study_plan',
    spec: PLAN_SPEC,
    body,
    extras: [
      { column: 'id', value: globalThis.crypto.randomUUID() },
      { column: 'student_id', value: studentId },
      { column: 'user_role', value: ctx.role },
    ],
  });
  const r = await client.query(ins.text, ins.values);
  const item = r.rows[0];

  // 事件 → 通知：家长布置计划要让孩子看到（本地是两台设备各写各的库，所以家长发的计划孩子那边永远收不到）。
  //
  // ⚠️ 收件人**显式指定为 `studentId`**，不能用默认的「按关系推导」——
  // 家长有两个孩子时，默认推导会把「给老大的计划」同时通知给老二。
  // 这里是 `notification.js` 里同一个坑的第二次出现：**默认推导的维度是「发起者」，
  // 而业务要的维度是「这件事关于谁」**，两者只在独生子女家庭里恰好重合。
  if (ctx.role === UserRoles.parent) {
    await notifyBoundPartners(client, ctx, {
      to: [studentId],
      title: '新的学习计划',
      body: `${item.title ?? '学习计划'} 等你确认`,
      type: NotificationTypes.studyPlan,
      relatedBizId: item.id,
    });
  }
  return { item: rowToApi(item) };
}

/**
 * 改计划状态（确认 / 拒绝 / 完成）。
 *
 * ⚠️ 接口注释：「**本方法不做状态机校验**，只把 `status` 列写下去。
 * 调用方是否校验、校验到什么程度由控制器决定。上云时要把这件事**明确归到一层**，
 * 不要出现『两边都以为对方在拦』。」
 *
 * 这里明确归到**客户端（L1）**：服务端只校验 status 是已知值（拦拼写错误），
 * 不校验流转是否合法（pending → 完成 这种跳步在这里是允许的）。
 * 理由：流转规则与「拒绝理由要不要清」绑在一起，那属于产品的判断，
 * 而它已经在 `ReviewService`/控制器那一侧了。服务端再判一次就会出现两个真相。
 */
const PLAN_STATUSES = STUDY_PLAN_STATUSES;

export async function updatePlanStatus(client, ctx, body) {
  const id = requireText(body.id, 'id');
  const status = toEnum(body.status, 'status', PLAN_STATUSES);
  if (status === null) throw badRequest('缺少 status');

  // `rejectReason` 只在传入时写入；传空串规范成 NULL（读端按 NULL 判断）。
  const hasReason = 'rejectReason' in body;
  const values = [id, ctx.students, status];
  let sql = `update study_plan set status = $3`;
  if (hasReason) {
    values.push(toOptionalText(body.rejectReason));
    sql += `, reject_reason = $${values.length}`;
  }
  sql += ` where id = $1 and student_id = any($2::text[]) returning *`;

  const r = await client.query(sql, values);
  if (r.rowCount === 0) throw forbidden('找不到这个计划（或无权修改）');
  return { item: rowToApi(r.rows[0]) };
}

// ===== 打卡 =====

/**
 * 打卡列表。可选区间 `[from, to]`。
 *
 * ## 这里的 `from`/`to` 是**纯日期**，而且是**闭区间** —— 与作业/运动那两条不同
 *
 * 三条列表端点里只有这条不需要改（时间参数本来就在），但它的形状与另外两条
 * **不一样**，而这个不一样是有理由的，不是历史残留：
 *
 * | | 参数形制 | 区间 | 为什么 |
 * |---|---|---|---|
 * | 作业 / 运动 | ISO **瞬时**（带时区） | 左闭**右开** | 列是 `timestamptz`，比的是时刻 |
 * | 打卡 | `YYYY-MM-DD` **纯日期** | 左闭**右闭** | 列是 `date`，比的是「哪一天」 |
 *
 * `study_plan_checkin.date` 是 DATE 而不是 TIMESTAMPTZ，它的语义是
 * **学生所在时区的今天**（`coerce.js` 的 `toDate` 专门解释过这件事：
 * 服务端**不生成**这个值，因为它算不出「学生在哪个时区」）。
 *
 * 既然两端比的都是「日」而不是「时刻」，那就**不该**硬套成瞬时的左闭右开：
 * 客户端要传 `[2026-09-01, 2026-09-30]` 这种区间，还得自己把「本月最后一天」
 * 换算成「次月 1 号 00:00」再减一微秒 —— 那个减法必然有人写错，
 * 而写错的表现是**每月丢掉最后一天**，只在月底才看得出来。
 *
 * ⚠️ 所以 `to` 在这一条上是**含**的（闭区间），传 `2026-09-30` 能查到 9 月 30 日。
 * 这和 §2.3 那张表是一回事：**三页的「某一天」语义各不相同，别硬统一。**
 *
 * 同样没有默认值：不传 = 全部（现状）。见 `coerce.js` 的 `toTimeWindow`。
 */
export async function listCheckins(client, ctx, query) {
  const planId = query?.planId ? String(query.planId) : null;
  const from = query?.from ? toDate(query.from, 'from') : null;
  const to = query?.to ? toDate(query.to, 'to') : null;
  // `from > to` 报 400 而不是回空 —— 理由同 `toTimeWindow`：
  // 回空会让家长以为那段时间没打卡，而真相是参数传反了。
  if (from !== null && to !== null && from > to) {
    throw badRequest(`from 不能晚于 to（收到 from=${from}、to=${to}）`);
  }
  const r = await client.query(
    `select * from study_plan_checkin
      where student_id = any($1::text[])
        and ($2::text is null or plan_id = $2)
        and ($3::date is null or date >= $3)
        and ($4::date is null or date <= $4)
      order by date desc, id`,
    [ctx.students, planId, from, to],
  );
  return { items: rowsToApi(r.rows) };
}

/**
 * 打卡（`insertStudyPlanCheckin`）—— **幂等，而且幂等是结构性的**。
 *
 * ## 保证来自唯一约束，不是「先查后插」
 *
 * `UNIQUE (plan_id, date)` 加上原子 upsert —— 与积分那条是同族（陷阱①）。
 * 丢掉这个语义的症状很具体：**打卡数翻倍**，而且不报错（客户端重试、
 * 用户双击各插一条）。所以这里用 `on conflict … do nothing` + 回查，
 * **把已有那一行原样返回**（R6：重试返回原结果，而不是 409）。
 *
 * ## 一个必须选定的行为：重打同一天时 id 变不变
 *
 * 接口注释写了这个选择：「`INSERT OR REPLACE` 会换掉整行（含 id），
 * 而 Web 实现是原地替换。两种写法对读端不可区分（读端只按 planId+date 认），
 * 所以两边都合法——但服务端实现要选一种并写进契约，别引入第三种行为。」
 *
 * 服务端选 **原地替换：id 不变，行保留**。理由是 HTTP 下重试是常态，
 * 而「每次重试都换一个 id」会让基于 id 的幂等（以及排查时的日志对照）失效。
 *
 * ## `date` 由客户端给，服务端只校验形制
 *
 * 它的语义是**学生所在时区的今天**，而服务端不知道学生在哪个时区
 * （见 R3 的时区真坑：按 UTC 算会「晚 8 点后打卡记到明天」）。
 * 所以这个值必须由客户端给 —— 与其余所有时间戳的处置相反，
 * 而把这条差异写在这里，是因为它看起来像是「客户端又在自报数据」。
 */
export async function checkin(client, ctx, body) {
  const studentId = requireVisibleStudent(ctx.visibleStudents, body.studentId);
  const planId = requireText(body.planId, 'planId');
  const date = toDate(body.date, 'date');
  if (date === null) throw badRequest('缺少 date（学生所在时区的今天，YYYY-MM-DD）');

  const r = await client.query(
    `insert into study_plan_checkin (id, plan_id, student_id, date, created_at)
     values ($1, $2, $3, $4, now())
     on conflict (plan_id, date) do nothing
     returning *`,
    [globalThis.crypto.randomUUID(), planId, studentId, date],
  );

  if (r.rowCount > 0) {
    // 事件 → 通知：打卡要告诉家长（本地实现写的是本机的库，家长在另一台手机上收不到）。
    //
    // ⚠️ 收件人同样**显式指定**，理由与 `insertPlan` 完全一样：默认推导是「与发起者
    // 结伴的人」，而这里要的是「这件事关于的那个学生的家长」。两者在「学生给自己
    // 打卡」这个正常路径上恰好重合，所以默认推导**看起来**是对的 —— 但那正是它危险
    // 的地方：它只在某条路径走偏（例如家长代为打卡）时才错，而那时没人会发现。
    //
    // 类型用 `studyPlan` 而不是自造一个 `checkin`：客户端的 `NotificationType`
    // 只认七个展示域，认不出就静默回落成 `system`（见 notify.js 的说明）。
    await notifyBoundPartners(client, ctx, {
      to: await parentIdsOf(client, studentId),
      title: '学习计划打卡',
      body: `${date} 的学习打卡已完成`,
      type: NotificationTypes.studyPlan,
      relatedBizId: planId,
    });
    return { created: true, item: rowToApi(r.rows[0]) };
  }

  const existing = await client.query(
    `select * from study_plan_checkin where plan_id = $1 and date = $2`,
    [planId, date],
  );
  if (existing.rowCount === 0) {
    // 唯一约束撞了，但回查不到 —— 只可能是那一行不在我的可见范围内。
    // 与积分幂等键被别家占用是同一类：数据一致，是这次调用越了界。
    throw forbidden('这个计划在这一天已被别的学生打卡');
  }
  return { created: false, item: rowToApi(existing.rows[0]) };
}

/** 取消打卡。按**自然键**（计划 + 日期）删，不是按 id。 */
export async function deleteCheckin(client, ctx, body) {
  const planId = requireText(body.planId, 'planId');
  const date = toDate(body.date, 'date');
  if (date === null) throw badRequest('缺少 date');

  const r = await client.query(
    `delete from study_plan_checkin
      where plan_id = $1 and date = $2 and student_id = any($3::text[])`,
    [planId, date, ctx.students],
  );
  return { deleted: r.rowCount };
}
