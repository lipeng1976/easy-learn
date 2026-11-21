import fs from 'node:fs';
import path from 'node:path';

/**
 * 记录已执行的迁移。用它而不是「表存在就跳过」：
 * 后者在「表结构被改过一半」时会静默放过，症状是本地跑得好好的、
 * 换一台机器就少列 —— 这类问题排查成本极高。
 */
const MIGRATION_TABLE = `
  create table if not exists schema_migrations (
    name       text primary key,
    applied_at timestamptz not null default now()
  )`;

/**
 * 按文件名顺序执行 sqlDir 下尚未应用的 .sql。
 *
 * 每个文件一个事务：失败则整个文件回滚，不会留下半截 schema。
 * 这也是为什么 sql/*.sql 里不写 BEGIN/COMMIT —— 嵌套事务只会得到一句
 * 「there is already a transaction in progress」的警告，然后事务边界变得不可预期。
 */
export async function runMigrations(client, sqlDir) {
  await client.query(MIGRATION_TABLE);

  const files = fs
    .readdirSync(sqlDir)
    .filter((f) => f.endsWith('.sql'))
    .sort();

  const applied = [];
  for (const name of files) {
    const done = await client.query('select 1 from schema_migrations where name = $1', [name]);
    if (done.rowCount > 0) continue;

    const sql = fs.readFileSync(path.join(sqlDir, name), 'utf8');
    await client.query('begin');
    try {
      await client.query(sql);
      await client.query('insert into schema_migrations(name) values ($1)', [name]);
      await client.query('commit');
      applied.push(name);
    } catch (e) {
      await client.query('rollback');
      throw new Error(`迁移 ${name} 失败：${e.message}`);
    }
  }
  return applied;
}

/**
 * 解析**运维连接**（迁移用）的连接参数。
 *
 * ## 为什么不能直接用 `PGUSER`
 *
 * 迁移要管理员身份：`002_rls.sql` / `003_session.sql` 会建 `app_auth`（`BYPASSRLS`），
 * 而 `BYPASSRLS` 只有超级用户授得出来。但**函数上跑的**那份 `PGUSER` 必须是
 * `app_rls` —— 拿超级用户当应用账号，整套 RLS 会失效（`assertRlsEnforced` 会拦住，
 * 但那是「起不来」而不是「配错了」）。
 *
 * 于是同一个变量名 `PGUSER` 上挂着**两个互相冲突的值**：
 * 迁移要 `PGPASSWORD` 配管理员，部署要它配 `app_rls`。而 `loadEnv()` 是**文件优先**
 * （见 `scripts/lib/env-file.mjs`），shell 里临时覆盖无效 —— 所以「一份 `.env.prod`
 * 同时喂给 migrate 和函数」这件事，靠变量名本身是做不到的。
 *
 * 解法是把**运维连接**单独命名：`PG_OPS_USER` / `PG_OPS_PASSWORD`。
 * 好处不只是「不打架」—— 还顺带保证了**管理员凭证不上云**：
 * `s.yaml` 只引用函数真正需要的变量，`PG_OPS_*` 不在其中。
 *
 * ## 回落到 `PGUSER` 是刻意的
 *
 * 本机与既有用法（`PGUSER=postgres node scripts/migrate.mjs`）保持零行为变化。
 * 但 `identity` 会把「你其实用的是应用身份」这件事报出来 ——
 * 生产上那几乎总是错的，而症状是迁移中途失败（建不出 BYPASSRLS 角色），
 * 报错信息看着像权限不足，容易被当成「库没连对」。
 *
 * @param {Record<string, string | undefined>} env
 * @returns {{host: string, port: number, database: string, user: string,
 *   password: string, identity: 'ops' | 'app' | 'default'}}
 */
export function resolveMigrationTarget(env = {}) {
  const opsUser = env.PG_OPS_USER ?? '';
  const identity = opsUser !== '' ? 'ops' : (env.PGUSER ? 'app' : 'default');
  return {
    host: env.PGHOST ?? '127.0.0.1',
    port: Number(env.PGPORT ?? 5432),
    database: env.PGDATABASE ?? 'easy_learn',
    // 用运维身份时**只认 PG_OPS_PASSWORD**：宁可因为缺口令连不上（看得见），
    // 也不要悄悄退回去用应用角色的口令 —— 那会得到一个权限不足的报错，
    // 而它和「口令写错了」长得一模一样。
    user: opsUser !== '' ? opsUser : (env.PGUSER ?? 'postgres'),
    password: opsUser !== '' ? (env.PG_OPS_PASSWORD ?? '') : (env.PGPASSWORD ?? ''),
    identity,
  };
}

/** 已应用的迁移清单（对账与排障用）。 */
export async function appliedMigrations(client) {
  const r = await client.query('select name, applied_at from schema_migrations order by name');
  return r.rows;
}
