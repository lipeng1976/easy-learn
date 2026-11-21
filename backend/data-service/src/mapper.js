/**
 * 列名映射：**库内 snake_case，传输 camelCase**。
 *
 * 只在服务端这一个地方做（迁移计划 §3.1①）：
 * PG 里驼峰列名必须每次加双引号（`"studentId"`），这是永久摩擦；
 * 改成下划线是一次性成本，而客户端完全无感 —— 它收到的 JSON 仍是 camelCase。
 */

/** `student_id` → `studentId`。 */
export function toApiKey(snake) {
  return snake.replace(/_([a-z0-9])/g, (_, c) => c.toUpperCase());
}

/** `studentId` → `student_id`。 */
export function toDbKey(camel) {
  return camel.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`);
}

/**
 * 数据库行 → API 对象。
 *
 * ⚠️ 时间戳一律转成**带 Z 的 UTC ISO8601**。客户端现在库里存的是
 * 「不带时区后缀的本地时间」，`DateTime.parse` 会当成本地时间；
 * 换成 UTC 后如果客户端不 `.toLocal()`，**所有时间显示会差一个时区**（东八区差 8 小时）。
 * 这是上云后必然出现、且很容易漏的一处，客户端切换时要注意（S4）。
 */
export function rowToApi(row) {
  if (!row) return null;
  const out = {};
  for (const [k, v] of Object.entries(row)) {
    out[toApiKey(k)] = v instanceof Date ? v.toISOString() : v;
  }
  return out;
}

/** 批量版本。 */
export function rowsToApi(rows) {
  return (rows ?? []).map(rowToApi);
}

/**
 * 从请求体里挑出允许写入的字段。
 *
 * 为什么是白名单而不是「遍历 body 直接拼 SQL」：后者会让客户端能往
 * 任意列写值 —— 包括 `reversed_at`、`grading_source` 这种有业务含义的列。
 * 白名单的代价是每加一个字段要改一行，这正是我们想要的摩擦。
 */
export function pick(body, allowed) {
  const out = {};
  for (const key of allowed) {
    if (body[key] !== undefined) out[key] = body[key];
  }
  return out;
}

/** 生成服务端 id（R2：id 由服务端生成，客户端送什么来都不采用）。 */
export function newId() {
  return globalThis.crypto.randomUUID();
}
