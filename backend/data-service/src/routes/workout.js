import { badRequest, forbidden } from '../../../shared/errors.js';
import { requireVisibleStudent } from '../auth.js';
import { rowToApi, rowsToApi } from '../mapper.js';
import { buildInsert } from '../insert.js';
import { toBool, toInt, toText, toTimeWindow, toTs, requireText } from '../coerce.js';

/**
 * 运动计划与运动记录。
 *
 * ## 这个文件里有一个**R2 的例外**，而且是接口注释点名要求保留的
 *
 * `WorkoutRepository` 的原始说明：
 *
 *   > **幂等键就是 `record.id`**（建表时 `id` 是主键）。这条很重要：
 *   > 上云后客户端重试是常态，只要重试时**复用同一个 id**，重复提交就会撞主键
 *   > 而不是插出两条运动记录——「今天跑了几次」不会被网络抖动改成两次。
 *   > 所以**别把 id 改成服务端生成的新值**：那会把唯一的幂等键弄丢。
 *
 * 这与 R2（id 服务端生成）直接冲突，而它的理由是真的：运动记录是**打卡类**数据，
 * 「今天跑了几次」会被重复插入直接改坏，而客户端重试在移动网络下是常态。
 *
 * 处置：**接受客户端自带的 id，但把它当「幂等键」用，不当「身份」用**。
 *   ① 写入用 `on conflict (id) do nothing`，命中就回查原行 → 重试返回同一行（R6）；
 *   ② 回查**不加 student_id 条件**，让 RLS 决定可不可见 —— 于是
 *      「id 撞上了别人的记录」表现为回查不到 → 403，而**不是**覆盖或泄露。
 *
 * 这就是积分那条幂等键的同一套形态，只是键从 `idempotencyKey` 改成了 `id`。
 * 唯一的差别：这里的 id 由客户端提供，所以它可以被**猜测**；
 * 但猜到别人的 uuid 只会换来一个 403，拿不到任何数据。
 *
 * 其余两张表（计划）同理。
 */

const PLAN_SPEC = {
  title: (v) => (v === null || v === undefined ? null : String(v)),
  project: (v) => (v === null || v === undefined ? null : String(v)),
  weekdays: (v) => (v === null || v === undefined ? null : String(v)),
  targetMinutes: (v, f) => toInt(v, f),
  isActive: (v, f) => toBool(v, f) ?? true,
  startDate: (v, f) => toTs(v, f),
  endDate: (v, f) => toTs(v, f),
  // ⚠️ 这两列存的是 '17:30' 这种**展示串**，不是时刻（DDL 的刻意不映射）。
  // 改成 TIME 读回来会变成 '17:30:00'，前端显示会跟着变。
  startTime: (v) => toText(v),
  endTime: (v) => toText(v),
  cycleType: (v) => toText(v),
  customWeekdays: (v) => toText(v),
};

const RECORD_SPEC = {
  project: (v) => (v === null || v === undefined ? null : String(v)),
  // `startAt` / `endAt` 是**业务时间**（学生实际做的时刻，客户端给），
  // 不是记录时间 —— 所以它们不由服务端 now() 覆盖，只校验范围（R3）。
  startAt: (v, f) => toTs(v, f),
  endAt: (v, f) => toTs(v, f),
  minutes: (v, f) => toInt(v, f),
  feedback: (v) => (v === null || v === undefined ? null : String(v)),
  planId: (v) => toText(v),
};

export async function listPlans(client, ctx, query) {
  const activeOnly = query?.activeOnly === true || query?.activeOnly === 'true';
  const r = await client.query(
    `select * from workout_plan
      where student_id = any($1::text[])
        and (not $2::boolean or is_active)
      order by start_date desc nulls last, id`,
    [ctx.students, activeOnly],
  );
  return { items: rowsToApi(r.rows) };
}

/**
 * 运动记录列表。可选时间窗 `[from, to)`，语义与 `homework.listHomework` 一致
 * （**无默认值**、不传 = 现状、左闭右开、时区换算由客户端做）。
 *
 * 口径差别只有一个，但它很关键：作业按 `due_at`（**到期日**）筛，
 * 运动记录按 `start_at`（**实际发生的时刻**）筛。
 * 「那天到期」与「那天发生」在运动这一侧是两件事 ——
 * 所以日历上运动那一路有两条来源：记录（按 start_at）+ 计划（按周期规则推导）。
 * 详见 `doc/historical-data-plan.md` §2.3，**三页的「某一天」语义不要硬统一**。
 *
 * 已有的 `idx_workout_record_student (student_id, start_at DESC)` 正好是
 * 时间窗要的形状，所以这条路径**不需要补索引**（同 009 迁移的说明）。
 */
export async function listRecords(client, ctx, query) {
  const limit = Math.min(Number(query?.limit ?? 100) || 100, 500);
  const { from, to } = toTimeWindow(query);
  const r = await client.query(
    `select * from workout_record
      where student_id = any($1::text[])
        and ($3::timestamptz is null or start_at >= $3)
        and ($4::timestamptz is null or start_at < $4)
      order by start_at desc nulls last, id
      limit $2`,
    [ctx.students, limit, from, to],
  );
  return { items: rowsToApi(r.rows) };
}

/**
 * 新建运动计划 / 记录 —— **id 由客户端带**（见文件头的 R2 例外）。
 *
 * `id` 缺失时服务端补一个（不报错）：那种调用只可能来自手写的调试请求，
 * 而它对「重试」本来也没有幂等要求。**但两种路径的语义不同**，
 * 所以要体现在返回值里（`created` 与 `reused`），别让调用方去猜。
 */
async function insertWithClientId(client, ctx, body, { table, spec, label }) {
  const studentId = requireVisibleStudent(ctx.visibleStudents, body.studentId);
  const id = String(body.id ?? '').trim() || globalThis.crypto.randomUUID();

  const ins = buildInsert({
    table,
    spec,
    body,
    extras: [
      { column: 'id', value: id },
      { column: 'student_id', value: studentId },
    ],
    // ⚠️ `onConflict` 会被原样拼在 `values (...)` 之后，所以**必须自带 `on conflict` 前缀**。
    // 只写 `(id) do nothing` 得到的是 `values (...)'(id) do nothing'` —— 一个 42601 语法错误，
    // 而它读起来像是「冲突子句写错了」，实际是前缀少了。
    onConflict: 'on conflict (id) do nothing',
  });
  const r = await client.query(ins.text, ins.values);

  if (r.rowCount > 0) return { created: true, item: rowToApi(r.rows[0]) };

  // 幂等命中：把原行返回（R6）。**条件里不带 student_id** ——
  // 能不能看到由 RLS 决定。别人的记录在这里表现为「查不到」→ 403。
  const existing = await client.query(`select * from ${table} where id = $1`, [id]);
  if (existing.rowCount === 0) {
    throw forbidden(`这个 id 已被别的学生占用（${label}的 id 是幂等键，不能代表两个人）`);
  }
  return { created: false, reused: true, item: rowToApi(existing.rows[0]) };
}

export async function insertPlan(client, ctx, body) {
  return insertWithClientId(client, ctx, body, { table: 'workout_plan', spec: PLAN_SPEC, label: '运动计划' });
}

export async function insertRecord(client, ctx, body) {
  return insertWithClientId(client, ctx, body, { table: 'workout_record', spec: RECORD_SPEC, label: '运动记录' });
}

/** 启用 / 停用计划。传的是**目标值**，不是「切换」（重复调用结果相同）。 */
export async function setPlanActive(client, ctx, body) {
  const id = requireText(body.id, 'id');
  const isActive = toBool(body.isActive, 'isActive');
  if (isActive === null) throw badRequest('缺少 isActive');

  const r = await client.query(
    `update workout_plan set is_active = $3
      where id = $1 and student_id = any($2::text[])
      returning *`,
    [id, ctx.students, isActive],
  );
  if (r.rowCount === 0) throw forbidden('找不到这个运动计划（或无权修改）');
  return { item: rowToApi(r.rows[0]) };
}
