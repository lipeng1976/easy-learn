// 存储月报 —— 「永久保留」这个决定的对账工具。
//
// ⚠️ **只读**，一行都不写。
// ⚠️ 需要 `npm run dev:stack` 正开着（它是持有本机 PG 的那个进程）。
//
// 用法：
//   npm run report:storage                  # 演示栈的库（55433），当月
//   npm run report:storage -- --port=55434  # 测试库
//   npm run report:storage -- --month=2026-08
//
// ── 这个脚本存在的唯一理由 ────────────────────────────────────────────
// 「永久保留、不清理」是对的决定（方案 §3.1），但它**没有反向判据**：
// 如果哪天有人加了个 TTL / 归档任务 / 手滑删了一批，**没有任何东西会报警** ——
// 界面照常、测试照常（测试库每次都是全新的，删不到它）。
//
// 所以月报里最要紧的一行**不是**「一共多少行」，而是：
//
//   ⭐ 最老一条数据的日期 —— 它**必须不随月份推进而变新**。
//
// 它查的是「最老那条还在不在」。任何「统计总数」的报表都做不到这件事：
// 总数下降可以解释成「这个月没人用」，而最老日期**只可能因为删除而变新**。
//
// 第一次跑的时候把这一天记下来（见输出末尾的提示），之后每个月比一次。
import pg from 'pg';
import { LOCAL_PG } from '../src/pg-local.js';

const portArg = process.argv.find((a) => a.startsWith('--port='));
const port = portArg ? Number(portArg.slice('--port='.length)) : LOCAL_PG.port;
const monthArg = process.argv.find((a) => a.startsWith('--month='));

const now = new Date();
const month = monthArg
  ? monthArg.slice('--month='.length)
  : `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;

if (!/^\d{4}-\d{2}$/.test(month)) {
  console.error(`--month 要写成 YYYY-MM，收到的是「${month}」`);
  process.exit(1);
}

const c = new pg.Client({
  host: '127.0.0.1',
  port,
  user: LOCAL_PG.admin.user,
  password: LOCAL_PG.admin.password,
  database: LOCAL_PG.database,
});

try {
  await c.connect();
} catch (e) {
  console.error(`连不上 127.0.0.1:${port} 上的 PostgreSQL：${e?.message ?? e}`);
  console.error('');
  console.error('这个库由 dev-stack 持有，先把它开着：');
  console.error('  cd serverless/data-service && npm run dev:stack');
  process.exit(1);
}

/** 表名 → 用作「这个月新增」的时间列。没有时间列的表示不按月切。 */
// ⚠️ **`pg` 把 `count(*)`（bigint）当字符串返回**，不是数字：
//     `select count(*) from homework` → `"14"`（string）
//     `select count(*)::int from homework` → `14`（number）
//     后果很像「静默失败」：`total += n` 会**拼字符串**（"0" + "6" = "06"），
//     打印出来是个看着像数字的怪值；`n > 5` 因为隐式转换反而**碰巧**是对的。
//     所以本文件里每一处 count/sum 都要么 `::int`、要么 `Number(...)` 包一层。
//     下面那段是实测（2026-09-23）：
//       raw count(*)::int = 14 number
//       raw count(*)      = "14" string
const TIMED_TABLES = {
  homework: 'due_at',
  workout_record: 'start_at',
  homework_image: 'created_at',
  review_mistake: 'last_wrong_at',
  study_plan_checkin: 'created_at',
  point_ledger: 'created_at',
  chat_message: 'created_at',
  daily_comment: 'created_at',
};

/** 表名 → 「最老一条」的时间列。只在有意义的表上查。 */
const OLDEST_TABLES = {
  homework: 'due_at',
  workout_record: 'start_at',
  homework_image: 'created_at',
  review_mistake: 'last_wrong_at',
  study_plan_checkin: 'created_at',
};

/** 本地月份的 [起, 止) 瞬时 —— 与 `calendar/summary` 同一套口径。 */
function monthRange(ym) {
  const [y, m] = ym.split('-').map(Number);
  const from = new Date(y, m - 1, 1, 0, 0, 0, 0);
  const to = new Date(y, m, 1, 0, 0, 0, 0);
  return { from, to };
}

const exists = async (table) => {
  const r = await c.query(`select to_regclass($1) as t`, [`public.${table}`]);
  return r.rows[0]?.t != null;
};

const { from, to } = monthRange(month);

try {
  console.log('═══════════════════════════════════════════════════════');
  console.log(`  存储月报  ${LOCAL_PG.database} @ 127.0.0.1:${port}`);
  console.log(`  统计月份：${month}（本地时区，左闭右开）`);
  console.log('═══════════════════════════════════════════════════════');

  // ── 一、这个月新增 ────────────────────────────────────────
  console.log('');
  console.log('【一、这个月新增】');
  for (const [table, col] of Object.entries(TIMED_TABLES)) {
    if (!(await exists(table))) continue;
    const r = await c.query(
      `select count(*)::int as n from ${table} where ${col} >= $1 and ${col} < $2`,
      [from, to],
    );
    console.log(`  ${table.padEnd(20)} ${r.rows[0].n}`);
  }

  // ── 二、⭐ 最老一条还在不在 ───────────────────────────────
  //
  // 这一节是整份报表的目的。**不要**把它挪到后面、**不要**只打总数。
  console.log('');
  console.log('【二、⭐ 最老一条数据的日期（反向判据）】');
  console.log('  它必须不随月份推进而变新。变新 = 有人删了历史。');
  console.log('');
  let anyOldest = false;
  for (const [table, col] of Object.entries(OLDEST_TABLES)) {
    if (!(await exists(table))) continue;
    const r = await c.query(
      `select ${col} as oldest from ${table} where ${col} is not null order by ${col} asc limit 1`,
    );
    if (r.rowCount === 0) {
      console.log(`  ${table.padEnd(20)} (无数据)`);
      continue;
    }
    anyOldest = true;
    const d = r.rows[0].oldest;
    const date = d instanceof Date ? d.toISOString().slice(0, 10) : String(d).slice(0, 10);
    console.log(`  ${table.padEnd(20)} ${date}`);
  }
  if (!anyOldest) {
    console.log('');
    console.log('  ⚠️ 一张表都没有数据 —— 这不是「判据通过」，而是**判据还没开始生效**。');
    console.log('     先灌种子（npm run seed:demo）或走查一轮再跑。');
  }

  // ── 三、总量与照片字节 ────────────────────────────────────
  console.log('');
  console.log('【三、总量】');
  const allTables = [
    ...new Set([...Object.keys(TIMED_TABLES), ...Object.keys(OLDEST_TABLES)]),
  ];
  let totalRows = 0;
  for (const table of allTables) {
    if (!(await exists(table))) continue;
    const r = await c.query(`select count(*)::int as n from ${table}`);
    totalRows += r.rows[0].n;
    console.log(`  ${table.padEnd(20)} ${r.rows[0].n}`);
  }
  console.log(`  ${'合计'.padEnd(20)} ${totalRows}`);

  // 照片单独算账：**字节量与行数是两件事**，而字节量决定上云后的账单。
  if (await exists('homework_image')) {
    const r = await c.query(
      `select count(*)::int as n, coalesce(sum(file_size), 0)::bigint as bytes
         from homework_image`,
    );
    const bytes = Number(r.rows[0].bytes);
    const gb = bytes / 1024 / 1024 / 1024;
    console.log('');
    console.log('【四、照片字节（与行数分开算）】');
    console.log(`  张数            ${r.rows[0].n}`);
    console.log(`  合计字节        ${bytes}`);
    console.log(`  折合            ${gb.toFixed(3)} GB`);

    // 按学生算，因为配额是**按学生**的（方案 Q2）。
    const per = await c.query(
      `select student_id,
              count(*)::int as n,
              coalesce(sum(file_size), 0)::bigint as bytes
         from homework_image
        group by student_id
        order by bytes desc`,
    );
    if (per.rowCount > 0) {
      console.log('');
      console.log('  按学生：');
      for (const row of per.rows) {
        const b = Number(row.bytes);
        console.log(
          `    ${String(row.student_id).padEnd(24)} ${String(row.n).padStart(5)} 张` +
            `  ${(b / 1024 / 1024).toFixed(2)} MB`,
        );
      }
      const max = Math.max(...per.rows.map((r) => Number(r.bytes)));
      console.log('');
      console.log(`  单学生最大 ${(max / 1024 / 1024).toFixed(2)} MB`);
      console.log('  配额口径（方案 Q2，上云前定）：暂估 2GB / 学生；');
      console.log('  接近配额**提示不硬拦**（宁可多存，不可让孩子交不了作业）。');
    }
  }

  // ── 五、基线提示 ─────────────────────────────────────────
  console.log('');
  console.log('───────────────────────────────────────────────────────');
  console.log('把上面【二】的日期抄下来当基线。下次跑时逐个对照：');
  console.log('  · 一模一样        → 历史完好（这是期望结果）');
  console.log('  · 任何一行变新    → **有人删了历史**，立刻查（全仓本该没有按时间删）');
  console.log('  · 变旧            → 正常：用户补录了更早的记录');
  console.log('');
  console.log('⚠️ 测试库（55434）每次跑测试都会被重建，它的最老日期**不构成基线**。');
} finally {
  await c.end();
}
