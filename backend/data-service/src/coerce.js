import { badRequest } from '../../shared/errors.js';

/**
 * 请求体字段的类型强制。
 *
 * ## 为什么必须有这一层
 *
 * 客户端有两个来源会送「类型看着像、其实不对」的值：
 *
 * ① **本地实现留下来的形态**。SQLite 没有 BOOLEAN，`needsGrading` 在
 *    `HomeworkPatch` 里被写成 `value ? 1 : 0`；`gradingSource` 在本地是个枚举，
 *    过一遍 JSON 就变成字符串。上云后这些值会原样到达服务端 ——
 *    如果直接塞进参数，PG 那边的报错是 `invalid input syntax for type boolean: "1"`
 *    这类**指向数据库而不是指向调用方**的信息，排查会从错的方向开始。
 *
 * ② **`fromJson` 的宽松**。`num.tryParse` 对 `'abc'` 返回 null，对 `30.5` 返回 30.5；
 *    而列是 INTEGER。静默截断比报错坏得多 —— 它会写进一个「看着对」的数字。
 *
 * 所以这里的原则是：**只接受能无损解释的值，其余一律 400 并说清是哪个字段**。
 * 不做「尽力而为的转换」——那种转换的失败方式是静默的。
 *
 * 三个所有函数共有的约定：
 *  · `null` / `undefined` **原样穿过**（是否允许写成空由调用方的掩码层决定）；
 *  · 错误信息里**必须带字段名**（否则客户端拿到一句「参数不合法」无从下手）；
 *  · 不做 trim 之外的规范化（空串与 null 的语义差别是业务决定的，见 R4）。
 */

/** 空值判定：`undefined`、`null`、以及**全空白的字符串**都算没给值。 */
function isEmpty(v) {
  return v === undefined || v === null || (typeof v === 'string' && v.trim() === '');
}

/**
 * 文本。`null` 穿过；数字与布尔允许（客户端可能把 id 写成数字）。
 *
 * ⚠️ 不做「空串 → null」的转换：客户端**依赖空串**（DDL 的
 * `TEXT NOT NULL DEFAULT ''` 就是因为这个），把它偷偷换成 null 会让
 * `WHERE x = ''` 这类查询突然查不到东西。
 */
export function toText(v) {
  if (v === null || v === undefined) return null;
  if (typeof v === 'string') return v;
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  return null; // 交给调用方按「不可解释」处理
}

/** 必填文本：给了就必须能解释成非空文本。 */
export function requireText(v, field) {
  if (isEmpty(v)) throw badRequest(`缺少 ${field}`);
  const s = toText(v);
  if (s === null) throw badRequest(`${field} 必须是文本`);
  return s;
}

/** 整数。接受 `30`、`"30"`；拒绝 `30.5`、`"abc"`、`{}`。 */
export function toInt(v, field) {
  if (isEmpty(v)) return null;
  const n = typeof v === 'number' ? v : Number(String(v).trim());
  if (!Number.isFinite(n)) throw badRequest(`${field} 必须是数字`);
  if (!Number.isInteger(n)) throw badRequest(`${field} 必须是整数（收到 ${v}）`);
  return n;
}

/** 必填整数。 */
export function requireInt(v, field) {
  const n = toInt(v, field);
  if (n === null) throw badRequest(`缺少 ${field}`);
  return n;
}

/**
 * 布尔。
 *
 * **必须同时接受 `1/0`**：本地实现把布尔存成整数（`HomeworkPatch.needsGrading`
 * 写的就是 `value ? 1 : 0`），客户端原样上行时送来的就是数字。
 * 只认 `true/false` 的实现在这里会 400，而症状是「关掉批改开关后保存失败」。
 *
 * 反过来说，**字符串 `"true"` 也接受** —— 它只可能来自手写的调试请求，
 * 放行它不会造成数据错误，拒绝它却会让排查者以为是服务端 bug。
 */
export function toBool(v, field) {
  if (v === null || v === undefined) return null;
  if (typeof v === 'boolean') return v;
  if (typeof v === 'number') {
    if (v === 1) return true;
    if (v === 0) return false;
    throw badRequest(`${field} 必须是布尔值（收到 ${v}）`);
  }
  if (typeof v === 'string') {
    const s = v.trim().toLowerCase();
    if (s === 'true' || s === '1') return true;
    if (s === 'false' || s === '0') return false;
  }
  throw badRequest(`${field} 必须是布尔值`);
}

/**
 * 时间戳（TIMESTAMPTZ）。
 *
 * ## 这里刻意做了一件「不宽容」的事：**拒绝没有时区的时间串**
 *
 * 客户端 121 处 `toIso8601String()` 全库 0 处 `toUtc()` —— 它现在送的是
 * `2026-09-18T17:30:00`，**不带 Z 也不带偏移**。PG 会拿服务端的 TimeZone
 * 去解释它，于是「学生 17:30 开始运动」在库里变成另一个时刻，而且**不报错**。
 *
 * 两种处置：
 *   · 宽容 —— 当成本地时间（那就得知道客户端在哪个时区，服务端不知道）；
 *   · 拒绝 —— 要求 `Z` 或 `+08:00`，让客户端把时区**说清楚**。
 *
 * 选后者。它对客户端是硬要求（S4 要发 `toUtc().toIso8601String()`），
 * 但它把一类静默偏移换成了**一次带字段名的 400**。宽容的代价是
 * 订正起来只能靠肉眼看数据，而这条数据已经开始参与统计了。
 *
 * ⚠️ 唯一的例外见 DDL：`study_plan_checkin.date` 是 DATE 不是时刻，
 * 走下面的 [toDate]（它的语义是「学生所在时区的今天」，服务端不生成它）。
 */
const HAS_ZONE = /(?:Z|[+-]\d{2}:?\d{2})$/i;

export function toTs(v, field) {
  if (isEmpty(v)) return null;
  if (v instanceof Date) return v;

  const s = String(v).trim();
  if (!HAS_ZONE.test(s)) {
    throw badRequest(
      `${field} 必须带时区（如 2026-09-18T09:30:00Z 或 2026-09-18T17:30:00+08:00），收到的是「${s}」。`
        + '不带时区的时间会被按服务端时区解释，产生一整天的静默偏移（见迁移计划 §R3）。',
    );
  }
  const t = Date.parse(s);
  if (Number.isNaN(t)) throw badRequest(`${field} 不是合法的时间戳（收到「${s}」）`);
  return new Date(t);
}

/**
 * 纯日期（`YYYY-MM-DD`）。
 *
 * 用于 `study_plan_checkin.date`：它的语义是**学生所在时区的今天**，
 * 是唯一约束 `(plan_id, date)` 的一部分。服务端**不生成**这个值，
 * 只校验形制 —— 用 `now()` 或 UTC 日期去算会「晚 8 点后打卡记到明天」，
 * 而那会直接改变打卡天数。
 */
const PLAIN_DATE = /^\d{4}-\d{2}-\d{2}$/;

export function toDate(v, field) {
  if (isEmpty(v)) return null;
  // 客户端可能送完整时间戳（本地实现里 date 就是字符串），取日期部分是不对的 ——
  // 那等于用服务端的解释覆盖客户端的意思。只接受纯日期。
  const s = String(v).trim();
  if (!PLAIN_DATE.test(s)) {
    throw badRequest(`${field} 必须是 YYYY-MM-DD 形式的纯日期（收到「${s}」）`);
  }
  const [y, m, d] = s.split('-').map(Number);
  const probe = new Date(Date.UTC(y, m - 1, d));
  // 2026-02-31 这类「形制对、日子不存在」的值会被 Date 顺延到下个月，
  // 查出顺延就说明输入不合法。
  if (probe.getUTCFullYear() !== y || probe.getUTCMonth() !== m - 1 || probe.getUTCDate() !== d) {
    throw badRequest(`${field} 不是一个真实存在的日期（收到「${s}」）`);
  }
  return s;
}

/**
 * 时间窗 `[from, to)` —— **刻意不提供默认值**。
 *
 * ## 为什么不给默认值
 *
 * 「没传时间窗时默认最近 90 天」看起来很友好，实际是把一类错误换成了更难查的一类：
 *
 *   · 现在没传 = 按 `limit` 取最近 N 条 —— 用户看得到「有更多但没显示」，
 *     因为列表是满的、有滚动条；
 *   · 默认一个窗口 = 超出窗口的数据**从结果里消失**，而列表**看起来是完整的**
 *     （它就是不满，页面下方是「暂无更多」）。用户不会去查参数，他会认为
 *     「那段时间没记录」。
 *
 * 后者正是本项目最恨的那类 bug（见 `doc/需求规格说明书.md` 的「静默失败清单」）。
 * 所以这里的原则是：**要么调用方明确说要哪一段，要么就维持旧行为**。
 * 这条规矩有个守门人：`test/calendar.test.js` 里那条「不带时间窗仍只回 50 条」——
 * 有人加了默认窗口，那条断言会立刻红。
 *
 * ## 为什么 `from > to` 要报错而不是回空
 *
 * 回空的后果和上面一样：家长翻日历翻错了会以为「那天没数据」。
 * 一次 400 至少让调用方知道是自己的参数问题。这也符合 `coerce.js` 的一贯原则：
 * **只接受能无损解释的输入，其余一律 400 并说清是哪个字段**。
 *
 * ## 边界语义：左闭右开
 *
 * `from <= t < to`。选左开右闭会让「同一天的 23:59:59.999」和次日 00:00 撞上，
 * 而按天查的时候客户端算的是 `[本地日 00:00, 次日 00:00)` 的 UTC 瞬时
 * （见 §2.3 的约定：**客户端负责时区换算，服务端不做时区推断**）。
 * 两边必须一致，所以这里写死左闭右开。
 *
 * 两个端点各自可选：只给 `from` 是「从那以后的全部」，只给 `to` 是「在那之前的
 * 最近 N 条」。**单个端点是合法用法**，不要顺手要求两个都给。
 *
 * @returns `{ from: Date|null, to: Date|null }`，两个都是 `null` 表示「没给时间窗」
 */
export function toTimeWindow(query) {
  // 走 `toTs` 而不是 Date.parse：它会**拒绝不带时区的时间串**。
  // 这一条对本端点特别重要 —— 客户端算的是「本地日 → UTC 瞬时」，
  // 如果它错传了 `2026-09-22T00:00:00`（无 Z），按照 R3 那次的教训，
  // 服务端会拿服务端时区去解释它，于是整个窗口**静默偏一整天**。
  // 让它 400，比让它偏一天好。
  const from = toTs(query?.from, 'from');
  const to = toTs(query?.to, 'to');

  if (from !== null && to !== null && from.getTime() > to.getTime()) {
    throw badRequest(
      `from 不能晚于 to（收到 from=${from.toISOString()}、to=${to.toISOString()}）。`
        + '注意这里是**左闭右开**：查某一天应传 [那天 00:00, 次日 00:00)。',
    );
  }
  return { from, to };
}

/** 数值（NUMERIC 列，如 estimated_minutes / pass_rate）。`null` 穿过。 */
export function toNum(v, field) {
  if (isEmpty(v)) return null;
  const n = typeof v === 'number' ? v : Number(String(v).trim());
  if (!Number.isFinite(n)) throw badRequest(`${field} 必须是数字`);
  return n;
}

/** 字符串数组（如批量写入的 id 列表）。 */
export function toStringArray(v, field) {
  if (v === null || v === undefined) return null;
  if (!Array.isArray(v)) throw badRequest(`${field} 必须是数组`);
  return v.map((x) => String(x));
}

/**
 * 从候选值里挑一个枚举，不在集合里就 400。
 *
 * ⚠️ 明确**不在这里给默认值**。默认值属于业务判断（「没传 status 时算 pending」），
 * 写在类型层会让「客户端漏传字段」变成一次静默成功。
 */
export function toEnum(v, field, allowed) {
  if (isEmpty(v)) return null;
  const s = String(v).trim();
  if (!allowed.includes(s)) {
    throw badRequest(`${field} 只能是 ${allowed.join(' / ')} 之一（收到「${s}」）`);
  }
  return s;
}
