#!/usr/bin/env node
/**
 * 对账比对器：读两侧 dump，逐表逐行逐字段比较，输出人看得懂的差异清单。
 *
 * ## 三条设计决定
 *
 * **① 比对逻辑只在这里。** 两个执行器只管「执行 + dump」，不做任何判断。
 * 两侧各写一份 diff 会漂，而漂了的对账脚本比没有更坏 —— 它会给出「一致」的假结论。
 *
 * **② 用「归一化后的 id」配对，不按索引配对。** 一侧多一行就会让按索引的比法
 * 全表错位，报出一堆「看起来全都不对」的差异，而真实原因只有一个。
 * 归一化之后两侧的 id 都是 `$hw1` 这种别名，于是配对是精确的，差异能落到具体字段。
 *
 * **③ 忽略项是白名单，不是「默认忽略」。** 每一条忽略都必须写明理由（见 IGNORE），
 * 否则它会慢慢长大成「什么都不比」。
 *
 * 跑法：`npm run reconcile:compare`（或 node 本文件）
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const serviceRoot = path.resolve(here, '..', '..');

const LOCAL = process.env.RECONCILE_LOCAL_OUT ?? path.join(serviceRoot, 'out', 'local-dump.json');
const SERVER = process.env.RECONCILE_SERVER_OUT ?? path.join(serviceRoot, 'out', 'server-dump.json');

/**
 * 比对器**也读场景文件**（这是它唯一读的非 dump 输入）。
 *
 * 理由：它需要知道「哪些差异是声明过的」。把台账写在比对器里、把序列写在
 * scenario 里，两者会漂；写在同一处时，「序列里加了新动作」与「它的预期差异」
 * 是同一份 diff 里的两行，忘不掉。
 */
const SCENARIO = process.env.RECONCILE_SCENARIO
  ?? path.join(here, 'scenario.json');

/**
 * 列名归一化：本地是 camelCase（Dart 侧 `toMap()` 的产物），服务端是 snake_case。
 *
 * ⚠️ 这一步是**必需**的，而且理由不是「好看」：不归一化的话，每一列都会被报成
 * 「仅本地有 studentId / 仅服务端有 student_id」—— 于是真正的行为差异被淹没在
 * 一片命名风格差异里，对账脚本也就没法用了。
 */
const snake = (s) => s.replace(/[A-Z]/g, (m) => `_${m.toLowerCase()}`);

/** 把一侧的 dump 统一成 snake_case 的列名与行键。
 *
 * `aliases` 要一起带过来 —— 它由 `main` 注入到每张表上（顶层的那一份是两侧共用的）。
 * 少了它，`reverseAliases` 拿到空表，所有 id 都会被当成「原始 id」，
 * 于是每一行都报「两侧各多出一行」—— 差异看起来很多，实际是归一化没生效。
 */
function canonicalize(table) {
  return {
    columns: table.columns.map(snake),
    rows: table.rows.map((r) => Object.fromEntries(
      Object.entries(r).map(([k, v]) => [snake(k), v]),
    )),
    aliases: table.aliases ?? {},
  };
}

/**
 * 值不参与比对的列。**每一条都要能说清「为什么它必然不同」**。
 *
 * 列名一律用归一化后的 snake_case。注意 `created_at` 这类**两侧都有**的列：
 * 本地由客户端 `DateTime.now()` 给、服务端由 `now()` 给（R3），它们必然不同，
 * 而且不同是对的 —— 这正是不比对它的理由。反过来 `due_at` 是**业务时间**，
 * 两侧都该原样保存客户端给的值，所以它**不在**清单里（不同就是 bug）。
 */
const IGNORE_VALUES = {
  '*': [
    // 记录时间：本地由客户端给，服务端由 now() 给（R3）。必然不同，且不同是对的。
    'created_at',
    'issued_at',
    'expires_at',
    // `review_summary.generated_at` —— 与上面同一类（R3），但值得单独说一句：
    // 服务端**根本不读**客户端给的 `generatedAt`（`SUMMARY_SPEC` 里没有这个字段，
    // 由 `generated_at = now()` 直接落库）。实测：本地 `13:20:00.000Z`（序列给的）/
    // 服务端 `16:17:20.614Z`（PG 的 now()）。
    //
    // ⚠️ 这条白名单**掩盖着一个已知的小不一致**，写在这里以免它被忘掉：
    // 报告的 `scopeKey`（`2026-W38`）是**客户端**按设备本地日期算出来的，
    // 而 `generated_at` 是**服务端**时钟 —— 设备时钟偏一天时，一份报告可能落在
    // 「scopeKey 说这周、generated_at 说下周」的状态里，而列表是按
    // `generated_at DESC` 排序的。
    //
    // 同一类风险 `created_at` 也有，属于 R3 已经接受的取舍。真要收紧，正确做法是
    // **把 scopeKey 一起交给服务端算**（那才是它唯一的真相来源），
    // 而不是把 generated_at 改成信任客户端 —— 后者会让「今天错了几道」跟着设备时钟走。
    'generated_at',
    // 存储键：S5 之前本地是文件路径、服务端是对象 key，语义已经变了。
    'storage_key',
  ],
  homework: [
    // `user_role` —— 服务端 DDL 保留了这一列（从本地 schema 翻译过来时的产物），
    // 但服务端**既不写也不读**它：可见范围由 token 推出（R5/R7），不存在
    // 「行自己说这行给谁看」。本地写 `'student'`，服务端留 NULL。
    //
    // 之所以判为可接受：客户端读路径有兜底
    // （`database_service.dart` 的 `_homeworkFromMap`: `?? 'student'`），
    // 而服务端 `listHomework` 的 select 里根本没有这一列 —— 也就是说两侧
    // **对任何读者呈现的值都是一样的**。
    //
    // ⚠️ 如果哪天服务端要自己读这一列（聚合、报表、导出），这条白名单必须删掉：
    // 那时 NULL 与 'student' 就不再等价了。
    'user_role',
  ],
};

/**
 * 列集差异的已知项：`表 → 仅某一侧有的列`（归一化后的名字）。
 *
 * ⚠️ 这是**报告的出口**，不是「悄悄放过」：条目会照常打印，只是不算失败。
 * 不写理由的条目应该被视为待查项。
 */
const KNOWN_COLUMN_SET_DIFF = {
  // 本地 `homework` 有一列 `userRole`（老实现的产物，存「这行是给谁看的」）。
  // 服务端不需要它：可见范围由 token 推出（R5/R7），不存在「行自己说给谁看」。
  homework: { localOnly: ['user_role'] },
};

const read = (p, label) => {
  if (!fs.existsSync(p)) {
    throw new Error(
      `${label} 的 dump 不存在：${p}\n`
      + '先跑两侧执行器：\n'
      + '  RECONCILE_OUT=out/local-dump.json flutter test test/reconcile_dump_test.dart\n'
      + '  npm run reconcile:server',
    );
  }
  return JSON.parse(fs.readFileSync(p, 'utf8'));
};

/** 把 aliases（`别名 → 真实 id`）反转成 `真实 id → $别名`，用于归一化列值。 */
function reverseAliases(aliases) {
  return Object.fromEntries(
    Object.entries(aliases).map(([alias, id]) => [id, `$${alias}`]),
  );
}

/**
 * 把值里出现的**真实 id** 换成 `$别名`。
 *
 * ⚠️ 必须是**字符串内替换**，不能只认整串相等：真实 id 会嵌在别的字符串中间，
 * 而这不是边角情况 —— 幂等键的形态就是 `plan:<planId>:<date>`
 * （`PointController.planKey`）。只认整串的后果是每一轮都报两条
 * 「idempotency_key 不同」，而人一旦习惯忽略它，真差异也就没人看了。
 *
 * 按 id 长度**降序**替换：`L_pt1` 是 `L_pt1_reversal` 的前缀，
 * 短的那个先替换会把长的换坏。
 */
const normValue = (v, rev) => {
  if (typeof v !== 'string') return v;
  const ids = Object.keys(rev);
  if (ids.length === 0) return v;
  let out = v;
  for (const id of ids.sort((a, b) => b.length - a.length)) {
    if (id !== '' && out.includes(id)) out = out.split(id).join(rev[id]);
  }
  return out;
};

/**
 * 布尔值的表示归一化：SQLite 没有布尔类型（本地一律存 `1/0`），PG 有（存 `true/false`）。
 * 同一个逻辑值在两侧形状不同，而**形状不同不等于值不同**。
 *
 * ⚠️ 关键区别：这**不能**用「把这几个列加进忽略清单」来代替。
 * 忽略掉的话，`needs_grading` 真的从 `true` 变成 `false`（学生关掉了批改开关）
 * 也会被放过 —— 而那正是最该被看见的一类差异。归一化只抹平「同一逻辑值的两种写法」：
 * `1` vs `0` 依旧会被报出来。
 */
const boolish = (v) => (v === true ? 1 : v === false ? 0 : v);

/**
 * 数值的表示归一化：同一个数在不同驱动里可能形状不同。
 *
 * ⚠️ **本机实测：这一条没有被触发过。** 加它的理由是预判「PG 的 `numeric` 列经
 * node-pg 会变成字符串（默认不转 double，以免丢精度）」—— 而实测 `pass_rate`
 * （`NUMERIC(5,4)`）在两侧都是 **number** `0.5`（`out/*-dump.json` 里可见，
 * 迁移计划 §6.2 有记录）。所以它是一条**未被验证的保险**。
 *
 * 保留它的理由：它只在两侧数值真正相等时生效（`"1.0000"` vs `1` → 相等；
 * `1` vs `2` 照旧报差异），代价小；而它要防的那件事一旦发生，症状是
 * **每次跑都报一条假差异**，会把人耗在「为什么通过率不一样」上。
 *
 * ⚠️ 已知的粗糙处：它对 **TEXT 列**同样生效，所以一个值恰好长得像数字的文本列
 * （例如 `note: "2026"`）会被当数字比 —— 那意味着 `"2026"` 与 `"2026.0"`
 * 会被判为相同。反过来「不做归一化」的代价是把真差异淹掉。
 */
const numericish = (v) => {
  if (typeof v !== 'string') return v;
  return /^-?\d+(\.\d+)?$/.test(v) ? Number(v) : v;
};

/**
 * DATE 列（只有 `study_plan_checkin.date`）的表示归一化。
 *
 * PG 的 `date` 经 node-pg 出来是 `Date`（UTC 午夜），本地 SQLite 存的是
 * `toMap()` 写进去的 `YYYY-MM-DD` 字符串 —— **同一个日子、两种形状**。
 * 不归一化就会每次都报一条「date: 本地='2026-09-18' 服务端='2026-09-18T00:00:00.000Z'」，
 * 而它掩着的真差异是「打卡记到了哪一天」（晚 8 点后打卡记到明天）——
 * 那正是这条日期的全部意义，不能被一条格式噪音淹没。
 *
 * ⚠️ 只在**列名**为 `date` 时才做（不按值猜）：`due_at` / `submitted_at`
 * 这类是时刻不是日子，它们带上 `T00:00:00.000Z` 是正常的、不该被削成日期。
 */
const DATE_COLUMNS = new Set(['date']);

/**
 * DATE 列的兜底归一化：`YYYY-MM-DD` 与「同一天的 ISO 时刻」视为同一个值。
 *
 * ⚠️ **正常情况下这一条不会生效** —— 服务端 dump 侧已经按列类型把 DATE
 * 输出成 `YYYY-MM-DD`（`server-run.mjs` 的 `localDateString`，理由是
 * 「`2026-09-18` 会被 UTC 说成前一天」）。留在这里是因为：那一侧漏掉一张表
 * 时，症状会是「每次跑都报一条日期差异」，而人一旦习惯忽略它，
 * 真差异也就没人看了。它只在两侧真的是同一天时才判等，`2026-09-19` vs
 * `2026-09-18` 照旧报差异。
 */
const dateOnly = (v) => {
  if (typeof v !== 'string') return v;
  const m = /^(\d{4}-\d{2}-\d{2})(?:T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)?$/.exec(v);
  return m ? m[1] : v;
};

/**
 * 只比「有没有值」的列：`point_ledger.reversed_at`。
 *
 * 这一列记的是**撤销发生在哪一刻**，而「哪一刻」在两侧必然不同 ——
 * 本地由设备时钟给（`PointController.revoke` 的 `clock()`），服务端由 `now()`
 * 给（R3）。实测：本地 `2026-09-19T10:05:43.203741`（不带 Z，设备本地时间）
 * / 服务端 `2026-09-19T01:56:28.677Z`。
 *
 * ⚠️ 这里**不能把整列加进白名单**：`空 ↔ 非空` 正是「这笔到底有没有被撤销」，
 * 抹掉它就等于放过「撤销没生效」这个 bug。所以只把值归一成一个相同的哨兵，
 * 空值仍然是空值。
 */
const PRESENCE_ONLY = new Set(['reversed_at']);

/** 归一化的唯一入口 —— 顺序有意义：别名 → 存在性 → 布尔/日期 → 数值。 */
const normalize = (v, rev, column) => {
  const aliased = normValue(v, rev);
  if (PRESENCE_ONLY.has(column)) {
    return aliased === null || aliased === undefined ? null : '<ts>';
  }
  if (DATE_COLUMNS.has(column)) return dateOnly(aliased);
  return numericish(boolish(aliased));
};

const ignoredFor = (table, column) =>
  (IGNORE_VALUES['*'] ?? []).includes(column)
  || (IGNORE_VALUES[table] ?? []).includes(column);

function compareTable(table, rawL, rawS) {
  const diffs = [];
  const L = canonicalize(rawL);
  const S = canonicalize(rawS);
  const localCols = L.columns;
  const serverCols = S.columns;

  const localOnlyCols = localCols.filter((c) => !serverCols.includes(c));
  const serverOnlyCols = serverCols.filter((c) => !localCols.includes(c));
  const known = KNOWN_COLUMN_SET_DIFF[table] ?? {};
  const unexpectedCols = [
    ...localOnlyCols.filter((c) => !(known.localOnly ?? []).includes(c)).map((c) => `仅本地有 ${c}`),
    ...serverOnlyCols.filter((c) => !(known.serverOnly ?? []).includes(c)).map((c) => `仅服务端有 ${c}`),
  ];
  if (unexpectedCols.length > 0) {
    diffs.push({ kind: 'column-set', detail: unexpectedCols.join('、') });
  }
  const knownCols = [
    ...localOnlyCols.filter((c) => (known.localOnly ?? []).includes(c)).map((c) => `仅本地有 ${c}（已知）`),
    ...serverOnlyCols.filter((c) => (known.serverOnly ?? []).includes(c)).map((c) => `仅服务端有 ${c}（已知）`),
  ];

  const revL = reverseAliases(L.aliases ?? {});
  const revS = reverseAliases(S.aliases ?? {});

  const index = (rows, rev) => {
    const m = new Map();
    for (const row of rows) {
      const key = typeof row.id === 'string' && row.id in rev ? rev[row.id] : `(原始 id) ${row.id}`;
      if (m.has(key)) m.get(key).push(row);
      else m.set(key, [row]);
    }
    return m;
  };
  const li = index(L.rows, revL);
  const si = index(S.rows, revS);

  for (const key of new Set([...li.keys(), ...si.keys()])) {
    const l = li.get(key) ?? [];
    const s = si.get(key) ?? [];
    if (l.length === 0) { diffs.push({ kind: 'row-missing', detail: `服务端多出一行 ${key}` }); continue; }
    if (s.length === 0) { diffs.push({ kind: 'row-missing', detail: `本地多出一行 ${key}` }); continue; }

    // 同一 id 出现多行：本身就是要报的事（唯一约束在某一侧没生效）。
    if (l.length > 1 || s.length > 1) {
      diffs.push({ kind: 'row-duplicate', detail: `${key} 本地 ${l.length} 行 / 服务端 ${s.length} 行` });
    }

    for (let i = 0; i < Math.min(l.length, s.length); i++) {
      const lr = l[i];
      const sr = s[i];
      const cols = [...new Set([...localCols, ...serverCols])].filter(
        (c) => localCols.includes(c) && serverCols.includes(c) && !ignoredFor(table, c),
      );
      const fields = [];
      for (const c of cols) {
        const a = normalize(lr[c], revL, c);
        const b = normalize(sr[c], revS, c);
        if (JSON.stringify(a) !== JSON.stringify(b)) {
          fields.push({ column: c, local: a, server: b });
        }
      }
      if (fields.length > 0) diffs.push({ kind: 'field', key, fields });
    }
  }

  return { diffs, knownCols };
}

function fmt(v) {
  const s = JSON.stringify(v);
  return s === undefined ? 'undefined' : (s.length > 60 ? `${s.slice(0, 57)}…` : s);
}

/**
 * 「声明过的行为差异」的核对 —— 不是放行，是**按声明核对**。
 *
 * 它与 `IGNORE_VALUES` 的区别值得说清：白名单是**抹掉一个列的值**（此后不再看它，
 * 唯一能发现的就是那一列本身的变化），而这里是**对着清单核**——多一条、少一条、
 * 换了个标题，都会报。所以：值级的表示差异走白名单，结构级/行为级的差异走这条路。
 * 走这条路的每一条都必须能说清「为什么它必然不同」。
 */
function compareBehavior(table, rawL, rawS, entry) {
  const lines = [];
  let bad = 0;

  if (entry.mode === 'title-multiset') {
    const countOf = (arr) => {
      const m = new Map();
      for (const x of arr) m.set(x, (m.get(x) ?? 0) + 1);
      return m;
    };
    const titlesOf = (raw) => {
      if (!raw) return [];
      return raw.rows.map((r) => {
        const k = Object.keys(r).find((c) => snake(c) === 'title');
        return k === undefined ? '' : String(r[k] ?? '');
      });
    };
    const show = (m) => (m.size === 0
      ? '（无）'
      : [...m.entries()].map(([k, v]) => (v > 1 ? `${k}×${v}` : k)).join(' / '));
    const sum = (m) => [...m.values()].reduce((a, b) => a + b, 0);

    const actualS = countOf(titlesOf(rawS));
    const actualL = countOf(titlesOf(rawL));

    lines.push(`· ${table}（已声明的行为差异）：服务端 ${sum(actualS)} 条 / 本地 ${sum(actualL)} 条`);
    lines.push(`    服务端：${show(actualS)}`);
    lines.push(`    本地：${show(actualL)}`);

    // 与声明的清单逐条核。**只比标题多重集、不比 id** —— 两侧的 id 都是
    // 各自生成的，本来就没有对应关系；而「产生了哪几条通知」才是要验的事。
    const mismatches = [];
    const check = (want, actual, side) => {
      for (const [k, v] of want) {
        if ((actual.get(k) ?? 0) !== v) {
          mismatches.push(`${side}期望「${k}」×${v}，实际 ×${actual.get(k) ?? 0}`);
        }
      }
      for (const [k, v] of actual) {
        if (!want.has(k)) mismatches.push(`${side}多出「${k}」×${v}`);
      }
    };
    check(countOf(entry.server ?? []), actualS, '服务端');
    check(countOf(entry.local ?? []), actualL, '本地');
    for (const m of mismatches) lines.push(`    ✗ ${m}`);
    bad += mismatches.length;

    return { lines, bad };
  }

  if (entry.mode === 'server-only-table') {
    const rows = rawS?.rows?.length ?? 0;
    lines.push(`· ${table}（只有服务端有这张表）：服务端 ${rows} 行 / 本地 schema 里没有它`);
    if (rawL !== undefined) {
      lines.push('    ✗ 本地 dump 里出现了这张表 —— 声明已过时，请重看 scenario.behaviorDiff');
      bad += 1;
    }
    if (entry.expectRows !== undefined && rows !== entry.expectRows) {
      lines.push(`    ✗ 期望 ${entry.expectRows} 行，实际 ${rows} 行`);
      bad += 1;
    }
    return { lines, bad };
  }

  lines.push(`· ${table}：behaviorDiff 里的 mode「${entry.mode}」比对器不认识`);
  return { lines, bad: bad + 1 };
}

function main() {
  const L = read(LOCAL, '本地');
  const S = read(SERVER, '服务端');
  const scenario = JSON.parse(fs.readFileSync(SCENARIO, 'utf8'));

  // `aliases` 在 payload 顶层（两侧各一份），而比对是按表进行的 ——
  // 把它挂到每张表上，`canonicalize` 才拿得到。
  // 两侧的表取并集：本地 dump 里不会有 `app_notification_read`（它的 schema
  // 里没有这张表），而比对器必须**看见**它、并按 behaviorDiff 核对，而不是
  // 因为「本地没这张表」就悄悄跳过。
  const allTables = [...new Set([...Object.keys(L.tables), ...Object.keys(S.tables)])];
  for (const t of allTables) {
    if (L.tables[t]) L.tables[t].aliases = L.aliases ?? {};
    if (S.tables[t]) S.tables[t].aliases = S.aliases ?? {};
  }

  if (L.scenario !== S.scenario) {
    throw new Error(`两侧跑的不是同一个场景：本地 ${L.scenario} / 服务端 ${S.scenario}`);
  }

  const behaviorEntries = new Map(
    (scenario.behaviorDiff?.entries ?? []).map((e) => [e.table, e]),
  );
  let total = 0;
  const lines = [];
  lines.push(`对账场景：${L.scenario}`);
  lines.push(`  本地 dump：${LOCAL}`);
  lines.push(`  服务端 dump：${SERVER}`);
  lines.push('');

  // 词表差异：两侧的枚举值域故意不同（不是命名风格）。照常打印、不算失败 ——
  // 但必须打印，否则「场景里为什么只用 completed」会被下一个人重新推一遍。
  for (const v of scenario.vocabDiff ?? []) {
    lines.push(`⚠ 词表差异（两侧故意不同）：${v.column}`);
    lines.push(`    本地：${(v.local ?? []).join(' / ')}`);
    lines.push(`    服务端：${(v.server ?? []).join(' / ')}`);
    lines.push(`    ${v.note ?? ''}`);
    lines.push('');
  }

  for (const t of allTables) {
    const entry = behaviorEntries.get(t);
    if (entry) {
      const r = compareBehavior(t, L.tables[t], S.tables[t], entry);
      lines.push(...r.lines);
      total += r.bad;
      continue;
    }
    if (!L.tables[t] || !S.tables[t]) {
      lines.push(
        `✗ ${t}：只有一侧 dump 了这张表 —— 若这是刻意的结构差异，`
        + '请写进 scenario 的 behaviorDiff（并给出理由），否则它是一处待查的缺失',
      );
      total += 1;
      continue;
    }
    const { diffs, knownCols } = compareTable(t, L.tables[t], S.tables[t]);
    const rows = L.tables[t].rows.length;
    const mark = diffs.length === 0 ? '✓' : '✗';
    lines.push(`${mark} ${t}（本地 ${rows} 行 / 服务端 ${S.tables[t].rows.length} 行）`);
    for (const c of knownCols) lines.push(`    · 列集：${c}`);
    for (const d of diffs) {
      if (d.kind === 'column-set') lines.push(`    ✗ 列集差异：${d.detail}`);
      else if (d.kind === 'field') {
        lines.push(`    ✗ ${d.key} 有 ${d.fields.length} 个字段不同：`);
        for (const f of d.fields) {
          lines.push(`        ${f.column}: 本地=${fmt(f.local)}  服务端=${fmt(f.server)}`);
        }
      } else lines.push(`    ✗ ${d.detail}`);
    }
    total += diffs.length;
  }

  lines.push('');
  lines.push(total === 0
    ? '差异：0 —— 两侧落库结果一致'
    : `差异：${total} 处（上面每一条都要么修掉、要么写进白名单并说明理由）`);

  process.stdout.write(`${lines.join('\n')}\n`);
  process.exit(total === 0 ? 0 : 1);
}

main();
