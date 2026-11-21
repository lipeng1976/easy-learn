import { badRequest } from '../../../shared/errors.js';
import { requireVisibleStudent } from '../auth.js';

/**
 * 日历月摘要：`GET /data/calendar/summary?month=YYYY-MM&studentId=<可选>`
 *
 * ## 它解决的是什么问题
 *
 * 日历弹层要能「一眼看出这个月有没有数据」。如果只有按天的明细端点，会有两个后果：
 *   ① **打不了点**：翻到 8 月时，不知道 8 月哪天有数据，只能让人一格一格点；
 *   ② **连点几天就是连发几次请求**：家长翻了三个孩子、半年的日历 = 几十次请求。
 *
 * 所以拆成两个调用（见 `doc/historical-data-plan.md` §2.2）：
 *   · **按月摘要**（本文件）—— 每天**有几条**，用于打点与判断空月；
 *   · **按天明细**（已有的 `/data/homework?from=…&to=…` 等）—— 真点进去了才取。
 *
 * 这个分法让摘要很便宜：三个 `group by` 各扫一个月，回来的行数只有
 * 「有数据的天数」（最多 31 行 × 3 个键），而不是把整月明细塞进首屏。
 *
 * ## 为什么返回「计数」而不是「有没有」的布尔
 *
 * 计数是**免费的**（反正要 group by），而布尔把这个端点锁死了：
 * 将来想在日历格子上显示「3」，还得再加一个端点或者改形状。
 * 计数还有个副作用是排障时有用 ——「这个月有 12 条作业」比「这个月有作业」好查。
 *
 * ## 三个数字各自的「那一天」语义**不一样**（这是刻意的）
 *
 * | 键 | 来源 | 列 | 含义 |
 * |---|---|---|---|
 * | `homework` | `homework` | `due_at` | 那天**到期**的作业 |
 * | `workout` | `workout_record` | `start_at` | 那天**发生**的运动 |
 * | `checkin` | `study_plan_checkin` | `date` | 那天**打过卡**的计划数 |
 *
 * 作业与运动是 TIMESTAMPTZ，需要**按用户时区切成日**；打卡本来就是 DATE，
 * 直接就是日。**不能把它们统一处理** —— 见 §2.3 的长注释，
 * 「三页的某一天语义不一样，别硬统一」。
 *
 * ## 时区：客户端传 UTC 偏移，服务端按它切日
 *
 * TIMESTAMPTZ 在 PG 里是绝对时刻，「这是哪一天」取决于看的人在哪个时区。
 * 服务端**不知道**用户在哪个时区，也不该猜（R3 的教训：猜错就是静默偏一整天）。
 * 所以客户端把它的偏移传上来（`tzOffsetMinutes`，东八区是 `480`），
 * 服务端用 `AT TIME ZONE` 切日。
 *
 *     `due_at AT TIME ZONE interval '-480 minutes'` → 得到该用户在墙上的本地时刻
 *     再 `::date` 取日
 *
 * ⚠️ **为什么不直接让客户端传两个瞬时（像 `from`/`to` 那样）**：
 * 摘要要的是「这一个月里每天各几条」，用两个瞬时表达不了一个**按天分桶**的需求 ——
 * 分桶必须有「日」这个概念，而「日」是时区相关的。所以这一条必然要知道时区。
 *
 * ⚠️ **为什么不用服务端时区兜底**：`tzOffsetMinutes` 不给就报 400。
 * 兜底一个 UTC 会让东八区的用户「晚上 8 点后交的作业记到明天」——
 * 与 `toDate` 那条注释里警告的是同一个坑（「晚 8 点后打卡记到明天」）。
 *
 * ⚠️ 偏移用 `interval` 相加而不是 `AT TIME ZONE 'Asia/Shanghai'`：
 * 传 IANA 名字要服务端有 tzdata，而且客户端那侧本来就只知道偏移（`DateTime.timeZoneOffset`）。
 * 偏移的代价是**不处理夏令时**——中国没有夏令时，本项目当前只服务中国用户，
 * 这个代价是零。真要支持夏令时地区，那时得改成传 IANA 名字，别在这里打补丁。
 */

/** `YYYY-MM`。刻意只接受这一种形状。 */
const MONTH = /^\d{4}-(0[1-9]|1[0-2])$/;

/**
 * 时区偏移（分钟，东正西负）。
 *
 * 范围取 ±(24×60 − 1) —— 地球上的实际偏移在 −12:00 到 +14:00 之间，
 * 放宽到 ±1 天是为了不把「客户端算错了」误判成「超范围」，
 * 同时挡住 `NaN` / 巨大值（那些会让 PG 的 `interval` 计算出离谱的结果）。
 */
function toTzOffsetMinutes(v) {
  if (v === null || v === undefined || v === '') {
    throw badRequest(
      '缺少 tzOffsetMinutes。日历要按**用户时区**把时刻切成天，'
        + '服务端不猜时区（猜错就是静默偏一整天，见 R3），'
        + '所以客户端必须把偏移传上来（东八区传 480）。',
    );
  }
  const n = Number(v);
  if (!Number.isFinite(n) || !Number.isInteger(n)) {
    throw badRequest(`tzOffsetMinutes 必须是整数分钟数（收到「${v}」）`);
  }
  if (Math.abs(n) > 24 * 60) {
    throw badRequest(`tzOffsetMinutes 超出合理范围（收到 ${n}，应在 ±1440 之内）`);
  }
  return n;
}

/**
 * 月区间 `[月初 00:00, 次月初 00:00)` —— 但这里返回的是**墙上时间**的边界字符串，
 * 交给 SQL 去跟「切好日的本地时刻」比。
 *
 * 为什么不在这里算成 UTC 瞬时再比：那样得把 `AT TIME ZONE` 反过来用两次
 * （先切日、再转回瞬时），反而更容易写错。这里的做法是
 * 「把列**也**换算到墙上时间，两边都在墙上时间里比」——只需换算一次，
 * 而且**一眼能看出区间是对的**（月初到次月月初）。
 */
function monthBounds(month) {
  const [y, m] = month.split('-').map(Number);
  const nextY = m === 12 ? y + 1 : y;
  const nextM = m === 12 ? 1 : m + 1;
  const pad = (n) => String(n).padStart(2, '0');
  return { start: `${month}-01`, endExclusive: `${nextY}-${pad(nextM)}-01` };
}

/**
 * @param {object} client 已带 RLS 身份的连接
 * @param {object} ctx `withRequestContext` 建的上下文
 * @param {object} query `{ month, tzOffsetMinutes, studentId? }`
 */
export async function calendarSummary(client, ctx, query) {
  const month = String(query?.month ?? '').trim();
  if (!MONTH.test(month)) {
    throw badRequest(`month 必须是 YYYY-MM 形式（收到「${month}」）`);
  }
  const tz = toTzOffsetMinutes(query?.tzOffsetMinutes);

  // ⚠️ 这一条是本项目最容易写坏的地方（见 `bootstrap.js` 与陷阱⑥的说明）：
  // **接受 studentId，但它只能用来「收窄」，不能用来「扩大」**。
  // `requireVisibleStudent` 拿的是服务端算出的 `ctx.visibleStudents`，
  // 传一个不在集合里的 id 会被它挡掉（**403**）。范围本身永远是身份推导的。
  //
  // ⚠️ 这里曾经写成「（404）」—— 而 `requireVisibleStudent` 抛的是 `forbidden`。
  // 注释与代码不一致比代码写错更难查：下一个人会照着注释去写客户端的
  // 「404 → 显示空态」分支，然后永远走不到，于是越权请求在界面上变成
  // 「那个孩子这个月没数据」—— 又一处静默失败。
  // **改了行为就同步改注释，包括这里的状态码。**
  const students = query?.studentId
    ? [requireVisibleStudent(ctx.visibleStudents, String(query.studentId))]
    : ctx.students;

  const { start, endExclusive } = monthBounds(month);

  // 墙上时间 = 绝对时刻 + 偏移。东八区 +480 分钟，所以 `+ interval '480 minutes'`。
  // 用参数化成 `make_interval(mins => $n)` 而不是字符串拼接 ——
  // 拼接会让这个值（虽然已被校验成整数）进入 SQL 文本，破坏「参数只有 $n」这条规矩。
  const wall = 'make_interval(mins => $4::int)';

  // 三段查完在 JS 里按日期并成一张表。
  //
  // ⚠️ **不用一条 SQL 里的 `union all`**：三个来源的分母不同（三张表），
  // 用 union 拼出来的是「(日期, 类型, 计数)」的长表，再在 SQL 里 pivot 成宽表
  // 需要的是一串 `max(case when kind = …)`，读起来比三次查询难得多，
  // 而收益只是省两次往返 —— 本机 0.2ms，手机 60ms，一个月摘要一共 3 次。
  // 这里的选择标准和 `bootstrap.js` 一致：**可读性优先**，因为它决定了
  // 下一个人会不会写错。
  const [hw, wk, ck] = await Promise.all([
    client.query(
      `select ((due_at + ${wall})::date)::text as d, count(*)::int as n
         from homework
        where student_id = any($1::text[])
          and due_at is not null
          and (due_at + ${wall})::date >= $2::date
          and (due_at + ${wall})::date < $3::date
        group by 1`,
      [students, start, endExclusive, tz],
    ),
    client.query(
      `select ((start_at + ${wall})::date)::text as d, count(*)::int as n
         from workout_record
        where student_id = any($1::text[])
          and start_at is not null
          and (start_at + ${wall})::date >= $2::date
          and (start_at + ${wall})::date < $3::date
        group by 1`,
      [students, start, endExclusive, tz],
    ),
    // 打卡这一列本来就是 DATE（学生的本地日），**不需要也不该做时区换算** ——
    // 对它加偏移会把「9 月 30 日打卡」变成「9 月 29 日」或「10 月 1 日」。
    // 这正是 §2.3 那条「别硬统一」的具体一处。
    client.query(
      `select date::text as d, count(*)::int as n
         from study_plan_checkin
        where student_id = any($1::text[])
          and date >= $2::date
          and date < $3::date
        group by 1`,
      [students, start, endExclusive],
    ),
  ]);

  // 按日期并成一行一天。只输出**至少有一样数据**的天 ——
  // 「这个月哪天有数据」正是调用方要判断的，把 31 天的零值全带上
  // 只是让响应变长（而且调用方还得自己过滤掉全零的行）。
  const days = new Map();
  const bump = (rows, key) => {
    for (const row of rows) {
      const entry = days.get(row.d) ?? { date: row.d, homework: 0, workout: 0, checkin: 0 };
      entry[key] = row.n;
      days.set(row.d, entry);
    }
  };
  bump(hw.rows, 'homework');
  bump(wk.rows, 'workout');
  bump(ck.rows, 'checkin');

  return {
    month,
    // 回显时区偏移：客户端拿到响应能确认「服务端是按我以为的时区算的」，
    // 排查「打点偏了一天」时这是第一句话要看的字段。
    tzOffsetMinutes: tz,
    days: [...days.values()].sort((a, b) => (a.date < b.date ? 1 : -1)),
  };
}
