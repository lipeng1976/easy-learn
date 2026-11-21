// 本地迁移对账：云端库 vs 本机库 vs 本机磁盘。
//
// ── 为什么要有这个脚本 ──────────────────────────────────────────────────
// 「pg_restore 退出码 0」不等于「数据搬全了」：
//  · pg_dump 若用了 RLS 生效的角色，会**静默少导**（不报错，只是行数变少）；
//  · 附件按行数对上了，字节也可能被截断；
//  · RLS 策略没跟过来的话，隔离从「查不到」退化成「全查得到」—— 界面照样能跑。
//
// 所以判据必须是**三方逐项对账**：表/行数、策略/FORCE、附件字节。
//
// 用法：
//   node scripts/verify-local-migration.mjs
//   node scripts/verify-local-migration.mjs --local-port=5433 --attachments=D:/easy_learn_home/attachments
import fs from 'node:fs';
import path from 'node:path';
import pg from 'pg';

const argOf = (name, fallback = '') => {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : fallback;
};

function loadEnv(file) {
  const out = {};
  if (!fs.existsSync(file)) return out;
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const i = t.indexOf('=');
    if (i > 0) out[t.slice(0, i).trim()] = t.slice(i + 1);
  }
  return out;
}

const env = loadEnv(path.resolve('../../.env.prod'));
const LOCAL_PORT = Number(argOf('local-port', '5433'));
const ATTACH = path.resolve(argOf('attachments', 'D:/easy_learn_home/attachments'));

const cloud = new pg.Client({
  host: env.PGHOST_EXTERNAL,
  port: Number(env.PGPORT ?? 5432),
  database: env.PGDATABASE,
  user: env.PG_OPS_USER,
  password: env.PG_OPS_PASSWORD,
  ssl: { rejectUnauthorized: false },
  connectionTimeoutMillis: 20000,
});

// 本地也走管理员角色：用 app_rls 查会被 RLS 过滤，两边根本不是同一口径。
const local = new pg.Client({
  host: '127.0.0.1',
  port: LOCAL_PORT,
  database: env.PGDATABASE,
  user: env.PG_OPS_USER,
  password: env.PG_OPS_PASSWORD,
});

const problems = [];

async function stats(c) {
  const tables = await c.query(
    `select table_name from information_schema.tables
     where table_schema='public' and table_type='BASE TABLE' order by table_name`,
  );
  const rows = {};
  for (const { table_name: t } of tables.rows) {
    const r = await c.query(`select count(*)::int n from "${t}"`);
    rows[t] = r.rows[0].n;
  }
  const policies = await c.query(`select count(*)::int n from pg_policies where schemaname='public'`);
  const forced = await c.query(
    `select count(*)::int n from pg_class c join pg_namespace n on n.oid=c.relnamespace
     where n.nspname='public' and c.relkind='r' and c.relrowsecurity and c.relforcerowsecurity`,
  );
  const withRls = await c.query(
    `select count(*)::int n from pg_class c join pg_namespace n on n.oid=c.relnamespace
     where n.nspname='public' and c.relkind='r' and c.relrowsecurity`,
  );
  const fns = await c.query(
    `select count(*)::int n from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public'`,
  );
  const mig = tables.rows.some((t) => t.table_name === 'schema_migrations')
    ? (await c.query('select count(*)::int n from schema_migrations')).rows[0].n
    : null;
  return { tables: tables.rows.map((t) => t.table_name), rows, policies: policies.rows[0].n,
    forced: forced.rows[0].n, withRls: withRls.rows[0].n, fns: fns.rows[0].n, mig };
}

try {
  await cloud.connect();
  await local.connect();
  const [a, b] = await Promise.all([stats(cloud), stats(local)]);

  console.log('════════ 数据库对账 ════════');
  console.log(`表数量      云端 ${a.tables.length} · 本地 ${b.tables.length}`);
  if (a.tables.length !== b.tables.length) problems.push(`表数量不一致`);

  const onlyCloud = a.tables.filter((t) => !b.tables.includes(t));
  const onlyLocal = b.tables.filter((t) => !a.tables.includes(t));
  if (onlyCloud.length) problems.push(`本地缺表: ${onlyCloud.join(', ')}`);
  if (onlyLocal.length) problems.push(`本地多表: ${onlyLocal.join(', ')}`);

  console.log('\n逐表行数：');
  let totalA = 0;
  let totalB = 0;
  for (const t of a.tables) {
    const ca = a.rows[t];
    const cb = b.rows[t];
    totalA += ca;
    totalB += cb ?? 0;
    const ok = ca === cb;
    if (!ok) problems.push(`表 ${t} 行数 ${ca} → ${cb}`);
    console.log(`  ${ok ? '✅' : '🔴'} ${t.padEnd(26)} ${String(ca).padStart(6)} → ${String(cb ?? '缺失').padStart(6)}`);
  }
  console.log(`  ${'合计'.padEnd(26)} ${String(totalA).padStart(6)} → ${String(totalB).padStart(6)}`);
  if (totalA !== totalB) problems.push(`总行数 ${totalA} → ${totalB}`);

  console.log('\nRLS：');
  console.log(`  策略数      ${a.policies} → ${b.policies}`);
  console.log(`  启用 RLS 表 ${a.withRls} → ${b.withRls}`);
  console.log(`  FORCE RLS   ${a.forced} → ${b.forced}`);
  if (a.policies !== b.policies) problems.push(`RLS 策略数 ${a.policies} → ${b.policies}`);
  if (a.forced !== b.forced) problems.push(`FORCE RLS 表数 ${a.forced} → ${b.forced}`);

  console.log(`\npublic 函数 ${a.fns} → ${b.fns}`);
  console.log(`迁移记录   ${a.mig} → ${b.mig}`);

  // ── 附件：库里的清单 vs 磁盘 ─────────────────────────────────────────
  console.log('\n════════ 附件对账 ════════');
  const { rows: imgs } = await cloud.query(
    'select storage_key, file_size from homework_image order by storage_key',
  );
  let missing = 0;
  let mismatch = 0;
  let diskBytes = 0;
  for (const r of imgs) {
    const p = path.join(ATTACH, r.storage_key);
    if (!fs.existsSync(p)) {
      missing += 1;
      if (missing <= 5) console.log(`  🔴 缺文件 ${r.storage_key}`);
      continue;
    }
    const sz = fs.statSync(p).size;
    diskBytes += sz;
    if (sz !== r.file_size) {
      mismatch += 1;
      if (mismatch <= 5) console.log(`  🔴 字节不符 ${r.storage_key} 期望 ${r.file_size} 实际 ${sz}`);
    }
  }
  const expectBytes = imgs.reduce((s, r) => s + r.file_size, 0);
  console.log(`  库里记录    ${imgs.length} 个 · ${expectBytes.toLocaleString()} B`);
  console.log(`  磁盘实际    ${imgs.length - missing} 个 · ${diskBytes.toLocaleString()} B`);
  console.log(`  缺失 ${missing} · 字节不符 ${mismatch}`);
  if (missing) problems.push(`附件缺 ${missing} 个`);
  if (mismatch) problems.push(`附件字节不符 ${mismatch} 个`);
  if (diskBytes !== expectBytes) problems.push(`附件总字节 ${expectBytes} → ${diskBytes}`);

  console.log('\n════════ 结论 ════════');
  if (problems.length === 0) {
    console.log('✅ 全部对上：表 / 行数 / RLS / 附件字节 与云端一致');
  } else {
    console.log(`🔴 ${problems.length} 项不一致：`);
    for (const p of problems) console.log(`  · ${p}`);
    process.exitCode = 1;
  }
} finally {
  await cloud.end().catch(() => {});
  await local.end().catch(() => {});
}
