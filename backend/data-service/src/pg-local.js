import { spawnSync } from 'node:child_process';
import { rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import EmbeddedPostgres from 'embedded-postgres';

const here = path.dirname(fileURLToPath(import.meta.url));
export const sqlDir = path.resolve(here, '..', 'sql');

/**
 * 本机 PostgreSQL（真实 PG 17 二进制，由 npm 包提供）。
 *
 * 为什么不用 Docker：这台机器上没有 Docker，而装 PostgreSQL 服务需要管理员权限。
 * 这个包把 PG 的 initdb/postgres 二进制直接带下来，进程由 Node 管理，
 * **不需要管理员、不需要装服务、不污染系统**。
 *
 * 生产用云 PG，这个模块只服务本机开发与测试。
 *
 * ⚠️ 本机踩过的四个坑（2026-09-18），都在这里一次性挡住：
 *
 *   ① **中文系统的默认 locale 不被 initdb 接受**
 *      （`could not find suitable text search configuration for locale "Chinese (Simplified)_China.936"`）
 *      → 必须显式 `--locale=C -E UTF8`。
 *
 *   ② **`pg.stop()` 在 Windows 上会永久挂住**。它内部只是
 *      `spawn('taskkill', …)`，既不等待也不处理失败；一旦那次 taskkill 没生效，
 *      它等待的 `child.on('exit')` 就永不触发，脚本挂到被外部超时杀掉。
 *      → 改用绝对路径的 taskkill 自己杀（见 forceStopPostgres）。本机探针实测确认。
 *
 *   ③ **被中断后残留的数据目录会让 initdb 直接拒绝**
 *      （`directory exists but is not empty`）→ 每次开跑前先删干净。
 *
 *   ④ `/d/...` 这种 MSYS 风格路径 Windows 程序不认（pg_ctl 会说目录不存在），
 *      Node 侧用相对路径或 `d:/...` 即可。
 *
 * 另外：起 PG 的命令**不要接管道**（`| tail`）—— postgres 是常驻子进程会继承 stdout，
 * 管道永远等不到 EOF，命令会被超时杀掉，且现象看起来像「无任何输出地 SIGTERM」。
 */

/**
 * 本机开发的默认连接信息。应用角色与 sql/002_rls.sql 里创建的一致。
 *
 * `auth` 是 S2 新增的鉴权角色（sql/003_session.sql 创建）：
 * 注册与登录发生在还没有身份的时刻，用不了 RLS，只能用这个
 * **只被授权碰三张账号表**的角色。它带 BYPASSRLS，所以更不能拿它当应用角色。
 */
export const LOCAL_PG = {
  port: 55433,
  /**
   * 跑测试用的端口，**刻意与演示栈错开**。
   *
   * 两者共用一个端口时的现象很误导人：`withLocalPostgres` 启动失败，
   * 报的是「起库或迁移失败」，看起来像测试环境坏了 ——
   * 而真相只是「演示栈还开着」。数据目录本来就是分开的
   * （`.pgdata-dev` / `.pgdata-test`），端口没理由不分开。
   */
  testPort: 55434,
  /**
   * 跑对账用的端口。**第三个，与前两个都不共用。**
   *
   * 对账（`npm run reconcile:server`）自己就要起一次真实 PG。它原先**没显式指定
   * 端口**，于是落回 `port`（55433）—— 那正是演示栈的端口。演示栈开着时的现象是
   * 「对账跑到一半、退出码 1、什么原因都没说」：postgres 的
   * `could not bind ... address already in use` 被 `EmbeddedPostgres` 的默认
   * 空 `onLog` 一起吃掉了（2026-09-21 实测）。
   *
   * 三个端口对应三份数据目录（`.pgdata-dev` / `.pgdata-test` / `.pgdata-rec`），
   * **分开是它们各自能独立跑的前提**。
   */
  reconcilePort: 55435,
  database: 'easy_learn',
  admin: { user: 'postgres', password: 'postgres' },
  app: { user: 'app_rls', password: 'app_rls_local_dev' },
  auth: { user: 'app_auth', password: 'app_auth_local_dev' },
};

/**
 * 强杀本机 PG 进程树。
 *
 * 用**绝对路径**而不是命令名：PATH 在不同 shell / 沙箱模式下格式不一
 * （MSYS 的 `/c/Windows/System32` 对原生程序是无效项），而 `SystemRoot` 总是对的。
 */
export function forceStopPostgres(pg) {
  const pid = pg.process?.pid;
  if (!pid) return;
  if (process.platform === 'win32') {
    const taskkill = path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'taskkill.exe');
    spawnSync(taskkill, ['/pid', String(pid), '/f', '/t'], { stdio: 'ignore' });
  } else {
    try {
      process.kill(pid, 'SIGQUIT');
    } catch {
      // 已经退出了，没事
    }
  }
}

/**
 * 数据目录偶尔会被尚未完全退出的 postgres 占着，删不掉就等一会儿再删。
 *
 * **总预算硬上限**：Windows 上删掉一个 PG 数据目录偶尔会拖很久，
 * 若让收尾无限等下去，整个脚本会被外部超时杀掉 —— 现象是「断言全过，但退出码非 0」，
 * 一次通过的验收看起来像失败。宁可留下目录（下次开跑前本来就会清），也不能拖死收尾。
 */
export async function removeDirWithRetry(dir, options = {}) {
  const { attempts = 5, delayMs = 600, budgetMs = 4000 } = options;
  const deadline = Date.now() + budgetMs;
  for (let i = 0; i < attempts; i += 1) {
    try {
      await rm(dir, { recursive: true, force: true });
      return true;
    } catch {
      if (Date.now() >= deadline) return false;
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
  return false;
}

/**
 * 起一个本机 PG，把控制权交给回调，结束后强杀并清掉数据目录。
 *
 * ⚠️ 一个必须知道的时序问题：**不要让它和 `node:test` 共用同一个进程**。
 * `node:test` 会再 spawn 一层子进程跑测试文件；如果由测试进程持有 postgres，
 * 运行器会等不到句柄释放，最后被超时杀掉 —— 现象是「一条用例都没执行到」。
 * 所以起库要发生在测试进程**外面**（见 `scripts/run-tests.mjs`）。
 */
export async function withLocalPostgres(fn, options = {}) {
  const {
    port = LOCAL_PG.port,
    databaseDir = './.pgdata',
    persistent = false,
    onLog = () => {},
    onError = () => {},
  } = options;

  // ⚠️ 这个返回值**必须看**。不看的话，「删不掉」会一路走到 `initialise()`，
  // 那里报出来的是：
  //
  //     initdb: error: directory "….pgdata-test" exists but is not empty
  //
  // 这句话看起来像「测试环境坏了」或「测试库被别的测试留下的脏数据污染了」，
  // 而真实原因在**文件操作权限**这一层（沙箱拦删除、或上一个进程没放开句柄）。
  // 本项目最怕的正是这种**把人指错方向**的报错 —— 所以在这里就拦下，
  // 并把该查的两件事直接说出来。
  const cleaned = await removeDirWithRetry(databaseDir);
  if (!cleaned) {
    throw new Error(
      `测试库目录删不掉：${databaseDir}，initdb 因此无法重建它。两个常见原因：`
        + '① 运行沙箱拦了删除操作 —— 本机跑数据服务测试时，让这条命令在沙箱外执行；'
        + '② 上一次的 postgres 进程还没退干净，占着目录里的文件 —— '
        + `查一下 tasklist 里有没有 postgres.exe，确认没有之后手工删掉 ${databaseDir} 再跑。`,
    );
  }

  const pg = new EmbeddedPostgres({
    databaseDir,
    port,
    user: LOCAL_PG.admin.user,
    password: LOCAL_PG.admin.password,
    persistent,
    initdbFlags: ['--locale=C', '-E', 'UTF8'],
    onLog,
    onError,
  });

  await pg.initialise();
  await pg.start();
  try {
    return await fn(pg);
  } finally {
    forceStopPostgres(pg);
    // taskkill 返回时进程已收到信号，但 Windows 释放文件句柄要稍慢一拍；
    // 立刻删目录会失败，然后白等五轮重试。
    await new Promise((resolve) => setTimeout(resolve, 800));
    // 删不掉**不算失败**（理由见上面 removeDirWithRetry 的说明：宁可留下目录，
    // 也不能拖死收尾）。但要说一声 —— 否则下一次开跑会死在一个看起来
    // 毫无关系的 initdb 报错上，而那时已经没人记得是这一次没收尾。
    const cleanedAfter = await removeDirWithRetry(databaseDir);
    if (!cleanedAfter) {
      onLog(`⚠️ 测试库目录没删掉（${databaseDir}）。下次开跑前会先清一次；`
        + '若它一直留着，多数是运行沙箱拦了删除，而不是测试本身有问题。');
    }
  }
}

/**
 * 一条连接的工具：建库（可选）→ 跑迁移 → 把连接交给回调。
 * 测试与本地起服务都用它，保证「schema 怎么建起来的」只有一条路径。
 */
export async function withMigratedDatabase(fn, options = {}) {
  const { runMigrations } = await import('./migrate.js');
  const database = options.database ?? LOCAL_PG.database;

  return withLocalPostgres(async (pg) => {
    const admin = pg.getPgClient();
    await admin.connect();
    const exists = await admin.query('select 1 from pg_database where datname = $1', [database]);
    if (exists.rowCount === 0) {
      await admin.query(`create database ${quoteIdent(database)}`);
    }
    await admin.end();

    const client = pg.getPgClient(database);
    await client.connect();
    try {
      const applied = await runMigrations(client, sqlDir);
      return await fn(client, { applied, port: options.port ?? LOCAL_PG.port, database });
    } finally {
      await client.end();
    }
  }, options);
}

/** 只允许标识符字符，避免库名被拼进 SQL 时产生注入面。 */
function quoteIdent(name) {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) {
    throw new Error(`不合法的数据库名：${name}`);
  }
  return `"${name}"`;
}
