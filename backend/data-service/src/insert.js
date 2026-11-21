import { toDbKey } from './mapper.js';

/**
 * 写入的公共层：**按字段清单把请求体映射成一行，再拼成 INSERT / UPDATE**。
 *
 * 为什么要有它：复习那个领域有 8 张表、动辄十几个列，逐个手写 INSERT 的话
 * 会出现两类错误，而两类都不会在写的时候被发现：
 *
 *   ① **列与占位符错位**（改了列顺序忘了改参数顺序）→ 数据被写进相邻的列，
 *      类型恰好兼容时**一条都不报错**。症状是「复习轮次莫名变成 20」。
 *   ② **漏了一个 NOT NULL DEFAULT '' 的列** → 它落成空串，与「客户端没传」
 *      看起来一样，但那两件事的语义不同（DDL 约定③）。
 *
 * 这里把两件事分开：**字段清单（spec）决定列名与类型强制**，映射与拼 SQL
 * 从同一个清单出发 —— 错位的可能性被结构消掉了。
 *
 * ⚠️ `spec` 的键必须是**代码里写死的字面量**（它决定列名）。永远不要把
 * 请求体里的键转发进 spec：那是一个注入口子，而且它长得跟正常代码一样。
 */

/**
 * SQL 侧的 `now()`。
 *
 * 作为列的「值」传进来时表示**这一列由数据库填当前时刻**，而不是一个参数。
 * 需要它是因为「记录时间服务端说了算」（R3）—— 但「服务端说了算」不等于
 * 「JS 里 `new Date()` 一下」：那用的是应用进程的时钟，而多实例部署时
 * 各台机器的时钟会有毫秒级差异（更别说容器时钟漂移）。
 * 让数据库给时间，同一个事务里的所有行拿到的是**同一个** `now()`。
 */
export const SQL_NOW = Symbol('sql-now');

function hasOwn(obj, key) {
  return Object.prototype.hasOwnProperty.call(obj ?? {}, key);
}

/**
 * `RETURNING` 子句。`returning: null` 表示**明确不要它**。
 *
 * ## 为什么必须能关掉它：RLS 下 `RETURNING` 会要求新行**可读**
 *
 * `INSERT ... RETURNING` 返回的每一行都要过一遍**读**策略。于是
 * 「写进去」与「读回来」原本是两件独立的事，被 `RETURNING` 绑成了一件：
 * 只要读策略不允许这一行（例如通知是写给**别人**的），整条 INSERT 就被拒，
 * 而报错说的是
 *
 *     new row violates row-level security policy for table "..."
 *
 * —— 指向**写**策略，而写策略其实完全放行。排查方向因此是错的。
 *
 * 本机实测（`sql/005_notification.sql` 的通知表，四格矩阵）：
 * 字面量 / 参数化 × 带 / 不带 `RETURNING` —— 唯一决定成败的是 `RETURNING`；
 * 而同样带 `RETURNING`、只把收件人换成调用者自己，就通过。
 *
 * 所以调用方在「写入的对象与调用者不同」时应当显式传 `returning: null`，
 * 并在 JS 侧自己组装返回值。见 `routes/notify.js`。
 */
function returningClause(returning) {
  if (returning === null || returning === '') return '';
  // 传进来的应当是**列清单**（`*` / `id` / `id, title`），关键字由这里拼。
  // 传错成 `'returning *'` 会拼出 `returning returning *`，而数据库只回一句
  // `42601 syntax error` —— 不指向任何参数。这个守卫是**踩过之后加的**：
  // 一次完整测试跑（约 3 分钟）就为了这一句报错。
  if (/^\s*returning\b/i.test(returning)) {
    throw new Error(
      `returning 只写列清单，不要带 returning 关键字（收到 ${JSON.stringify(returning)}）`,
    );
  }
  return ` returning ${returning}`;
}

/** 单行的映射：按 spec 把请求体转成 `{apiKey: 已强制的值}`。 */
export function mapRow(body, spec) {
  const out = {};
  for (const [key, coerce] of Object.entries(spec)) {
    out[key] = coerce(body?.[key], key);
  }
  return out;
}

function present(row) {
  return Object.entries(row).filter(([, v]) => v !== undefined);
}

/**
 * 拼一条 INSERT。
 *
 * @param {object} o
 * @param {string} o.table 表名字面量
 * @param {Record<string, (v: any, field: string) => any>} [o.spec] API 字段名 → 类型强制
 * @param {object} [o.body] 请求体（给了 spec 就要给 body）
 * @param {object} [o.row] 已映射好的一行（与 body 二选一）
 * @param {{column: string, value: any}[]} [o.extras] 服务端定的列（id / student_id / created_at）
 * @param {string} [o.onConflict]
 * @param {string|null} [o.returning] 列清单；**`null` = 不要 `RETURNING` 子句**（见 `returningClause`）
 */
export function buildInsert({ table, spec, body, row, extras = [], onConflict = '', returning = '*' }) {
  const mapped = row ?? mapRow(body, spec);
  const cols = [];
  const holders = [];
  const values = [];

  const push = (column, value) => {
    cols.push(column);
    if (value === SQL_NOW) {
      holders.push('now()');
      return;
    }
    values.push(value);
    holders.push(`$${values.length}`);
  };

  for (const e of extras) push(e.column, e.value);
  for (const [key, value] of present(mapped)) push(toDbKey(key), value);

  return {
    text: `insert into ${table} (${cols.join(', ')}) values (${holders.join(', ')})${onConflict}${returningClause(returning)}`,
    values,
  };
}

/**
 * 拼一条多行 INSERT。
 *
 * @param {object} o
 * @param {string} o.table 表名字面量
 * @param {Record<string, (v: any, field: string) => any>} o.spec
 * @param {object[]} o.rows 请求体里的一批对象
 * @param {{column: string, value: any}[]} [o.extras] 广播到每一行的列
 * @param {Record<string, (row: object, index: number) => any>} [o.perRow] 逐行计算的列（如 id）
 *        —— 值的形态与 extras 一致，`SQL_NOW` 同样有效
 * @param {string} [o.onConflict]
 * @param {string|null} [o.returning] 与 `buildInsert` 同义
 */
export function buildInsertMany({ table, spec, rows, extras = [], perRow = {}, onConflict = '', returning = '*' }) {
  const keys = Object.keys(spec);
  const perRowKeys = Object.keys(perRow);
  const cols = [
    ...extras.map((e) => e.column),
    ...perRowKeys,
    ...keys.map(toDbKey),
  ];

  const values = [];
  const tuples = rows.map((row, index) => {
    const holders = [];
    const push = (value) => {
      if (value === SQL_NOW) {
        holders.push('now()');
        return;
      }
      values.push(value);
      holders.push(`$${values.length}`);
    };
    for (const e of extras) push(e.value);
    for (const key of perRowKeys) push(perRow[key](row, index));
    for (const key of keys) push(spec[key](row?.[key], key));
    return `(${holders.join(', ')})`;
  });

  return {
    text: `insert into ${table} (${cols.join(', ')}) values ${tuples.join(', ')}${onConflict}${returningClause(returning)}`,
    values,
  };
}

/**
 * 「逐行 id + 广播归属 + 数据库 now()」三件套 —— 每次批量写都要的三种列。
 *
 * 存在的理由：`id` 必须**逐行不同**（`extras` 只会广播同一个值），而这三样
 * 逐个调用点自己拼，就会出现「某一处忘了逐行 id」→ 整批只有第一行写进去、
 * 其余全撞唯一键，**而这个错误只在批量超过 1 行时才出现**。
 *
 * @param {object} [o]
 * @param {string} [o.studentId] 给了就广播 `student_id`
 * @param {boolean} [o.createdAt] 是否带 `created_at = now()`（默认带；有的表没有这一列）
 * @param {{column: string, value: any}[]} [o.extras] 额外的广播列（如 `paper_id`）
 */
export function idAndServerColumns({ studentId, createdAt = true, extras = [] } = {}) {
  return {
    perRow: { id: () => globalThis.crypto.randomUUID() },
    extras: [
      ...(studentId === undefined ? [] : [{ column: 'student_id', value: studentId }]),
      ...(createdAt ? [{ column: 'created_at', value: SQL_NOW }] : []),
      ...extras,
    ],
  };
}

/** 请求体里是否出现了这个键（掩码判定的唯一判据）。 */
export function touches(body, key) {
  return hasOwn(body, key);
}
