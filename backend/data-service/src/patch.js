import { toApiKey, toDbKey } from './mapper.js';

/**
 * 字段掩码：**「这个键出现在请求体里」就是「这次要写它」**。
 *
 * ## 为什么是这个规则（陷阱 ② 的正面解）
 *
 * `updateHomework` 老签名的约定是「`null` = 本次不改这个字段」。在 Dart 里它能工作，
 * 因为「没传」与「传了 null」由调用方语法在**编译期**就分开了。但那份区分要活过
 * 一次序列化才能上云，而当初的担心是：标准 JSON 库里 `{"summary": null}` 与
 * 「`summary` 键不存在」会变成同一个东西。
 *
 * 核过之后要修正这个说法：**JSON 本身分得清这两件事** —— `Object.keys` 看得到
 * 前者没有后者。真正会丢信息的是**构造 Map 的写法**（`if (v != null) 'k': v`
 * 那种「顺手过滤掉 null」的代码），而 `HomeworkPatch.toMap()` 恰恰没这么写：
 * 它由 setter 决定键在不在，`clearResult()` 显式塞进 `null`。
 *
 * 所以服务端可以安全地采用这个规则，代价是**必须写清楚**：
 *
 *   键出现 且 值为 null  →  把这个字段写成 NULL（清空）
 *   键出现 且 值非 null  →  写这个值
 *   键不出现             →  一个字都不动
 *
 * 反过来说，**服务端绝不能**把「值为 null 的键」当「没传」丢掉 ——
 * 那正是当初担心的那个 bug，只是从客户端的序列化搬到了服务端的解构里，
 * 症状一模一样：重新提交作业后家长仍看到上一次的旧分数，不报错、只是数字不对。
 *
 * ## 列名的安全性
 *
 * `spec` 的键是**代码里写死的白名单**，列名由它推导；值一律走占位符。
 * 所以这里直接拼 `列名 = $n` 是安全的 —— 前提是**永远不要**把请求体会话里的
 * 键转发进 `spec`。加一个字段要改一行代码，这个摩擦是刻意的。
 */

function hasOwn(obj, key) {
  return Object.prototype.hasOwnProperty.call(obj ?? {}, key);
}

/** 这次请求带了几改。空掩码时调用方应当直接返回，别发一条空的 UPDATE。 */
export function touchedFields(body, spec) {
  return Object.keys(spec).filter((key) => hasOwn(body, key));
}

/**
 * 拼一条「按掩码更新」的 UPDATE。
 *
 * 占位符编号约定：**where 的参数在前（$1…$n），掩码的值接在后面**。
 * 反过来（掩码在前）需要在每次拼 WHERE 时重算偏移，那是个只会在
 * 「某个字段没传」时才出错的写法。
 *
 * @param {object} o
 * @param {string} o.table 表名（**字面量**，来自调用方代码）
 * @param {Record<string, (v: any, field: string) => any>} o.spec API 字段名 → 类型强制函数
 * @param {object} o.body 请求体
 * @param {string} o.where WHERE 子句（用 $1…$n 引用 whereValues）
 * @param {any[]} [o.whereValues]
 * @param {{column: string, value: any}[]} [o.extra] 不由客户端提供的附加赋值（如 updated_at = now()）
 * @returns {{text: string, values: any[], touched: string[]} | null} 掩码为空时返回 null
 */
export function buildUpdate({ table, spec, body, where, whereValues = [], extra = [] }) {
  const touched = touchedFields(body, spec);
  if (touched.length === 0 && extra.length === 0) return null;

  const values = [...whereValues];
  const sets = [];
  for (const key of touched) {
    values.push(spec[key](body[key], key));
    sets.push(`${toDbKey(key)} = $${values.length}`);
  }
  for (const e of extra) {
    values.push(e.value);
    sets.push(`${e.column} = $${values.length}`);
  }

  return {
    text: `update ${table} set ${sets.join(', ')} where ${where} returning *`,
    values,
    touched: touched.map(toApiKey),
  };
}

/**
 * 掩码为空时的统一返回。
 *
 * **不是错误** —— 接口契约里写明「掩码为空时调用方应跳过本次调用，实现也要容忍它」。
 * 返回 `{ updated: false }` 而不是抛异常，是因为调用方（控制器）本来就会发空掩码，
 * 而一个「什么都没改」的 400 会让它以为写失败了。
 */
export function emptyPatchResult() {
  return { updated: false, touched: [] };
}

/**
 * 更新前后，某个值**是不是真的变了**。
 *
 * 用于「事件 → 通知」的判定：通知必须只在一次**真实变化**上生成。
 * 只看「掩码里出现了这个键」是不够的 —— 一次网络超时后的重试送的是同一份掩码，
 * 那会再通知一遍。而比较「新旧值」正好把重试挡掉：重放时两者相等。
 *
 * 语义上「空」也算一个值：`null → null` 不算变化，`null → 时刻` 算变化。
 * 日期比较必须用 `getTime()` —— `Date` 对象之间用 `===` 永远是 false，
 * 而那会让「每次重试都通知一遍」，且**看起来完全正常**。
 */
export function changedTs(prev, next) {
  if (!next) return false;
  if (!prev) return true;
  return (prev instanceof Date ? prev.getTime() : prev)
    !== (next instanceof Date ? next.getTime() : next);
}
