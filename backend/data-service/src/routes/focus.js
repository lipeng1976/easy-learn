import { badRequest, forbidden } from '../../../shared/errors.js';
import { requireVisibleStudent } from '../auth.js';
import { rowsToApi, toDbKey } from '../mapper.js';
import { buildInsert, mapRow } from '../insert.js';
import { toInt, toText, toTs, requireText } from '../coerce.js';

/**
 * 专注计时流水。
 *
 * ## 它回答的是「今天在某个事上花了多久」
 *
 * `homework.actual_seconds` 也能回答「这份作业一共花了多久」，但它是**一份作业
 * 一个总数**：计划是按天重复的（今天读了、明天还要读），临时打卡干脆没有
 * 归属对象。所以这里存流水，一次会话一行。
 *
 * ## 幂等：一次会话一个 id，重复写 = 更新
 *
 * 计时页在暂停、离开应用、结束时各写一次（检查点）。**每次新增一条**的话，
 * 暂停三次就变成三条、时长翻三倍，而界面上只是「今天读了 1 小时」——
 * 没有任何报错。所以 `id` 由客户端在开会话时生成，这里按主键 upsert。
 *
 * ## 为什么允许客户端指定 id（而不是服务端生成）
 *
 * 服务端生成就拿不到「这一条是哪次会话」，检查点只能靠「同一学生 + 同一目标
 * + 同一天」去猜，而那在有两次同类会话时会把两次并成一次。
 * 客户端给 id 的代价是要防「拿着别人的 id 来写」—— 下面先查归属，撞上就 403。
 */

const FOCUS_KINDS = new Set(['homework', 'plan', 'free']);

const FOCUS_SPEC = {
  // 目标是三种之一。写错不静默回退成 'free'：一个拼错的 kind 会让这条记录
  // 从「作业投入」统计里消失，而它仍然躺在库里 —— 这类丢失最难查。
  kind: (v, f) => {
    const one = String(toText(v) ?? '').trim();
    if (!FOCUS_KINDS.has(one)) throw badRequest(`kind 只能是 ${[...FOCUS_KINDS].join('/')}`, f);
    return one;
  },
  sourceId: (v) => toText(v) ?? '',
  title: (v) => toText(v) ?? '',
  // `yyyy-MM-dd`，本地日。格式不对就 400：字典序比较是「按天取一段」的全部依据，
  // 一个 `2026-1-9` 会永远排在 `2026-01-10` 之后，表现为「昨天的记录取不到」。
  date: (v, f) => {
    const one = String(requireText(v, f) ?? '').trim();
    if (!/^\d{4}-\d{2}-\d{2}$/.test(one)) throw badRequest('date 必须是 yyyy-MM-dd', f);
    return one;
  },
  // 秒。负数没有意义（它只会来自时钟回拨或算错），小数在这一列是脏数据。
  seconds: (v, f) => {
    const one = toInt(v, f) ?? 0;
    if (one < 0) throw badRequest('seconds 不能为负', f);
    return one;
  },
  startedAt: (v, f) => toTs(v, f),
};

/** 按天取一段（含两端）。 */
export async function listFocusSessions(client, ctx, query) {
  const from = query?.from ? String(query.from) : null;
  const to = query?.to ? String(query.to) : null;
  if (from && !/^\d{4}-\d{2}-\d{2}$/.test(from)) throw badRequest('from 必须是 yyyy-MM-dd');
  if (to && !/^\d{4}-\d{2}-\d{2}$/.test(to)) throw badRequest('to 必须是 yyyy-MM-dd');

  const r = await client.query(
    `select * from focus_session
      where student_id = any($1::text[])
        and ($2::text is null or date >= $2)
        and ($3::text is null or date <= $3)
      order by date, started_at, id`,
    [ctx.students, from, to],
  );
  return { items: rowsToApi(r.rows) };
}

/** 写（或更新）一段专注。 */
export async function saveFocusSession(client, ctx, body) {
  const studentId = requireVisibleStudent(ctx.visibleStudents, body?.studentId);
  const id = String(requireText(body?.id, 'id') ?? '').trim();
  if (id === '') throw badRequest('缺少 id');

  // 「这个 id 是不是这个学生的」**不能在写之前查**：RLS 会把别人的行藏起来，
  // 于是「查不到」有两种含义（本来就没有 / 是别人的），而这两种要走的分支不同。
  // 所以改成写完再看一眼：自己写的行一定读得回来，读不回来就是撞了别人的 id。

  // 冲突时要更新哪些列，由「这次请求里真的带了哪些字段」决定 ——
  // 只更新送来的那些，缺失的列保持原值（客户端每次都送全量，但这不能靠约定）。
  const mapped = mapRow(body, FOCUS_SPEC);
  const setSql = Object.entries(mapped)
    .filter(([, v]) => v !== undefined)
    .map(([k]) => `${toDbKey(k)} = excluded.${toDbKey(k)}`)
    .join(', ');

  const stmt = buildInsert({
    table: 'focus_session',
    spec: FOCUS_SPEC,
    body,
    extras: [
      { column: 'id', value: id },
      { column: 'student_id', value: studentId },
    ],
    // 已存在 = 同一次会话又写了一次检查点，只更新秒数与时刻。
    //
    // ⚠️ 不带 `RETURNING`：它在 RLS 下要求新行**可读**，读不到会变成「0 行」
    // 而不是报错（见 `insert.js` 的说明）。这个端点的契约是「写完即可」，
    // 客户端要最新值走列表端点。
    onConflict:
      // 只有同一名学生才能更新这一行。少了这个 WHERE，拿着别人的 id 来写
      // 会在 RLS 下直接抛错（500，而不是一个有意义的拒绝）。
      ` on conflict (id) do update set ${setSql}, updated_at = now()`
      + ' where focus_session.student_id = excluded.student_id',
    returning: null,
  });
  await client.query(stmt.text, stmt.values);

  // 写完读回来。读不到 = 那一行属于别人（冲突被上面的 WHERE 挡掉了），
  // 这时必须 403 —— 静默返回成功的话，客户端以为存好了，时间却不见了。
  const written = await client.query('select 1 from focus_session where id = $1', [id]);
  if (!written.rows[0]) throw forbidden('这段专注不属于该学生');

  return { ok: true };
}
