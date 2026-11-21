#!/usr/bin/env node
/**
 * 本机演示栈：**一条命令把整套后端立起来**。
 *
 *     node scripts/dev-stack.mjs            # 起 PG + 迁移 + 演示数据 + 两个服务
 *     node scripts/dev-stack.mjs --reset    # 先清库重来（数据全丢）
 *     node scripts/dev-stack.mjs --no-ai    # 只起数据服务
 *     node scripts/dev-stack.mjs --lan      # 绑到所有网卡，让手机 / 真机连进来
 *     node scripts/dev-stack.mjs --run "flutter test test/cloud_live_test.dart"
 *
 * ## `--lan` 解决的是什么
 *
 * 默认两个服务都只绑回环，手机够不着。`--lan` 把它们绑到所有网卡，
 * 并打印**手机版**的构建命令（两个地址都换成局域网 IP）。
 *
 * 它同时放行手机浏览器打开 Web 版时的来源 —— 见下面 `WEB_PORT` 的注释：
 * 手机浏览器那条路不用构建 APK，是验证链路最快的方式。
 *
 * ## `--run` 解决的是什么
 *
 * 「起服务 → 跑一条命令 → 收服务」这件事**必须在一个进程里做完**。
 * 分成两步做（一个终端起栈、另一个终端跑测试）在交互式终端里没问题，
 * 但在任何非交互环境里都会散架：栈是常驻进程，命令一返回它就被回收，
 * 于是「测试连不上」看起来像代码坏了，其实只是服务没了。
 *
 * 顺带它还**替调用方定了地址**（见 `CLOUD_LIVE_BASE` 的注入），
 * 免得端口抄错 —— 抄错的症状是「连到了 AI 网关的 8787 上，报一堆 404」。
 *
 * ## 与 `npm test` / `smoke:http` 的区别
 *
 * 那两者每次都在**全新的临时库**上跑，跑完就删 —— 因为验收要的是「干净可复现」。
 * 演示正相反：它要的是**数据留得住**。所以这里的数据目录是持久的（`.pgdata-dev`），
 * Ctrl+C 之后下次起来还在。
 *
 * ## 它顺手验证了什么
 *
 * 起库 → 迁移 → 建账号 → 登录 → 结伴 → 布置作业 → 提交 → 批改 → 记错题 →
 * 打卡 → 积分 → 心愿 → 点评。这条链路**全部走 HTTP**，没有一条 SQL 写入 ——
 * 所以「脚本跑完了」本身就等于「这条链路上的端点都是通的」。
 *
 * ⚠️ 必须在**无沙箱隔离**下运行：沙箱会把常驻的 postgres 当残留进程回收，
 * 现象是「起来几秒后自己没了」。
 */
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import { createConnection } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import EmbeddedPostgres from 'embedded-postgres';

import { loadDevCredentials } from '../../shared/dev-credentials.js';
import { runMigrations } from '../src/migrate.js';
import { LOCAL_PG, forceStopPostgres, removeDirWithRetry, sqlDir } from '../src/pg-local.js';
import { DEMO, seedDemo } from './seed-demo.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const serviceRoot = path.resolve(here, '..');
const repoRoot = path.resolve(serviceRoot, '..', '..');

const argv = process.argv.slice(2);
const args = new Set(argv);
const flag = (name) => args.has(`--${name}`);
/**
 * 取一个带值的选项，`--name=值` 与 `--name 值` **两种写法都要认**。
 *
 * 只认 `=` 的写法会在传命令时静默失效：`--run "flutter test …"` 被 shell 拆成
 * 两个 argv，于是 `--run` 看起来「没给值」，脚本照常起栈、然后**一直挂着**——
 * 现象是「命令跑不起来也不报错」，而根因只是少解析了一个参数。
 */
const opt = (name, fallback) => {
  const eq = argv.find((a) => a.startsWith(`--${name}=`));
  if (eq !== undefined) return eq.slice(name.length + 3);
  const i = argv.indexOf(`--${name}`);
  const next = i >= 0 ? argv[i + 1] : undefined;
  if (next !== undefined && !next.startsWith('--')) return next;
  return fallback;
};

const DATA_PORT = Number(opt('port', process.env.PORT ?? 8788));
const PG_PORT = Number(opt('pg-port', process.env.DATA_PG_PORT ?? LOCAL_PG.port));
const AI_PORT = Number(opt('ai-port', process.env.AI_GATEWAY_PORT ?? 8787));
/** 栈起来之后要跑的那条命令。空 = 只起栈，等 Ctrl+C。 */
const RUN = opt('run', '');
/**
 * `--lan`：把两个服务绑到**所有网卡**，让手机 / 真机能连进来。
 *
 * 默认只绑回环，这不是洁癖：数据服务里是真实账号数据，而网关攥着方舟的 Key ——
 * 放出去而没人察觉的症状是「同一个 Wi-Fi 下有人在花你的额度」。
 *
 * 注意 `--lan` 开的是**两个服务**。只开一个是这条路上最常见的坑：数据服务通了、
 * 登录也进得去，但 AI 相关功能全线不通 —— 因为网关还锁在回环上，
 * 而客户端的 `AI_BASE_URL` 指的是局域网地址，那边**根本没有服务在听**。
 */
const LAN = flag('lan');
const BIND_HOST = LAN ? '0.0.0.0' : (process.env.BIND_HOST ?? '127.0.0.1');

/**
 * 找一个**手机能用**的局域网地址。
 *
 * 优先无线网卡：手机连的通常是同一个 Wi-Fi，而有线网卡那个地址手机够不着 ——
 * 换来的症状是「怎么都连不上，但电脑上一切正常」，很难往网卡上想。
 * 多个候选时按「像 Wi-Fi」排序，取第一个。
 */
function lanAddress() {
  const candidates = [];
  for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
    for (const a of addrs ?? []) {
      if (a.family !== 'IPv4' || a.internal) continue;
      candidates.push({ name, address: a.address, wifi: /wi-?fi|wlan|wi-fi|无线/i.test(name) });
    }
  }
  candidates.sort((a, b) => Number(b.wifi) - Number(a.wifi));
  return candidates[0] ?? null;
}

/** `--lan` 时探到的局域网地址；没探到就是 null（下面会拦下来）。 */
const LAN_IP = LAN ? (lanAddress()?.address ?? null) : null;

/**
 * `--lan` 时顺带放行的**浏览器来源**。
 *
 * 手机用浏览器打开 Web 版是最快的验证路径（不用构建 APK、不用装包），
 * 但页面来源是 `http://<局域网IP>:<端口>`，不在这边白名单里就会被 CORS 拦掉 ——
 * 而 CORS 失败在客户端被归类成「连不上数据服务」，服务明明活着、curl 也通。
 *
 * 只放行这一个来源，不用 `*`：局域网里别人的网页同样能打到这个端口。
 */
const WEB_PORT = Number(opt('web-port', 8088));
const DATA_DIR = path.join(serviceRoot, '.pgdata-dev');
/**
 * 会话签名密钥与三个本机 PG 角色口令，统一由 shared/dev-credentials.js 提供：
 * 环境变量优先；本机没配时随机生成一次并持久化到 `.dev-credentials.json`。
 *
 * **不能每次随机就换** —— 一重启就换密钥，等于把所有已登录设备踢下线；
 * 角色口令换了，复用数据目录的旧库也连不上。所以生成一次、之后复用。
 * 仓库里不再有任何可用的密钥字面量。生产必须显式配 `AI_SESSION_SECRET`
 * 等四个变量，服务侧的 config-check 会拦住缺失的情况。
 */
const DEV_CREDENTIALS = loadDevCredentials();
const SESSION_SECRET = DEV_CREDENTIALS.sessionSecret;
/**
 * 作业照片字节的落盘根目录（见 `src/imagestore.js`）。
 *
 * 默认放在**仓库之外**（`D:/easylearn/image`）：照片是运行期数据，
 * 放进仓库目录一来会被 git status 看见、二来会在切分支 / `flutter clean`
 * 这类操作里被顺手删掉 —— 而「图片不见了」这种故障**没有任何报错**。
 *
 * 目录不存在时服务端自己建；建不出来就在启动日志里显式报警，
 * 但**不会**把整个服务拖死（其余路由本来好好的）。
 */
const IMAGE_ROOT_DIR = process.env.IMAGE_ROOT_DIR ?? 'D:/easylearn/image';

const children = [];
const log = (m) => process.stdout.write(`[stack] ${m}\n`);

function killChildren() {
  for (const { child } of children) {
    if (!child?.pid) continue;
    if (process.platform === 'win32') {
      const taskkill = path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'taskkill.exe');
      spawnSync(taskkill, ['/pid', String(child.pid), '/f', '/t'], { stdio: 'ignore' });
    } else {
      try {
        child.kill('SIGTERM');
      } catch {
        // 已经退出了
      }
    }
  }
}

async function waitForHealth(url, attempts = 200) {
  for (let i = 0; i < attempts; i += 1) {
    try {
      const res = await fetch(url);
      if (res.status === 200) return true;
    } catch {
      // 还没起来
    }
    await new Promise((r) => setTimeout(r, 300));
  }
  return false;
}

// ===== 参数自检 =====

// 探不到局域网地址时**当场退出**，别继续往下起栈。
// 否则会绑上 0.0.0.0 却给不出一个手机能用的地址，打印的命令是编的 ——
// 而「照着抄的命令连不上」是最难查的一类，因为每一处看起来都对。
if (LAN && LAN_IP === null) {
  log('✗ --lan 打开了，但这台机器上找不到局域网地址（只剩回环）。');
  log('  手机连的是**电脑的局域网地址**；没有它，绑出去也没人够得着。');
  log('  确认 Wi-Fi / 网线已连上，再重试。');
  process.exit(1);
}

// ===== ⓪ 端口预检 =====
//
// 这两个端口是**客户端编译期常量**（`--dart-define=DATA_API_BASE_URL=…:8788`、
// `AI_BASE_URL=…:8787`），所以这里**不能**学静态托管那样「被占就换一个口」——
// 换了口客户端就找不到服务，症状是一堆 404 / 连不上，看起来像端点没实现。
//
// 于是分两种处理：
//   · 数据口被占 → 直接退出。数据服务必须连**本次起的**那个库，复用别人的
//     服务等于在演示另一个库（而演示数据看起来「还在」，最难分辨）。
//   · AI 口被占但探活通过 → 复用。本机常常本来就挂着一个网关（比如接 Ollama
//     的那份），此时再起一个 mock 是多余的，而且新进程会 EADDRINUSE 崩掉，
//     只留下一段看不懂的异常栈 —— 实测撞过一次，栈还照样报「全部判据通过」。

/**
 * 端口有没有人在听 —— **进程内 socket 探测，不起子进程**。
 *
 * 为什么不直接 `netstat -ano`：实测这个环境里**每次 spawnSync 固定约 5.2 秒**
 * （连 `node --version` 也一样，预热后不变），于是「先 netstat 再 tasklist」
 * 会给每次起栈白加约 10 秒 —— 而这是个只需要回答「有没有人」的问题。
 * 换成 socket 探测：**1 毫秒**。查占用者身份的开销挪到真正被占的分支里付。
 *
 * 探不通（ECONNREFUSED）就是没人听；连上了就立刻断开。
 */
function portIsListening(port, timeoutMs = 400) {
  return new Promise((resolve) => {
    const sock = createConnection({ host: '127.0.0.1', port });
    const done = (v) => { sock.destroy(); resolve(v); };
    sock.setTimeout(timeoutMs);
    sock.once('connect', () => done(true));
    sock.once('error', () => done(false));
    sock.once('timeout', () => done(false));
  });
}

/** 谁在监听这个端口：只在**已经确定被占**时调用（这是要花子进程的）。 */
function listenersOn(port) {
  if (process.platform !== 'win32') return [];
  const sys32 = path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32');
  const r = spawnSync(path.join(sys32, 'netstat.exe'), ['-ano'], { encoding: 'utf8' });
  const pids = new Set();
  for (const line of (r.stdout ?? '').split('\n')) {
    if (!/LISTENING/i.test(line)) continue;
    // TCP  127.0.0.1:8787  0.0.0.0:0  LISTENING  23620
    const m = line.trim().split(/\s+/);
    if (m.length >= 5 && m[1]?.endsWith(`:${port}`)) pids.add(m[4]);
  }
  return [...pids];
}

/** PID 的进程名，只为了让报错能被人一眼认出来（同样只在失败分支里付）。 */
function imageNameOf(pid) {
  if (process.platform !== 'win32') return '';
  const sys32 = path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32');
  const r = spawnSync(path.join(sys32, 'tasklist.exe'),
    ['/FI', `PID eq ${pid}`, '/FO', 'CSV', '/NH'], { encoding: 'utf8' });
  return (r.stdout ?? '').match(/^"([^"]+)"/m)?.[1] ?? '';
}

/** 把 PID 列表渲染成人能读的一行（每个 PID 要一次 tasklist，所以一次算好复用）。 */
function describePids(pids) {
  return pids.length
    ? pids.map((p) => `PID ${p} ${imageNameOf(p)}`.trim()).join(' / ')
    : '(没查出 PID，用 netstat -ano | findstr :端口 自己看一眼)';
}

if (await portIsListening(DATA_PORT)) {
  const pids = listenersOn(DATA_PORT);
  log(`✗ 数据服务端口 ${DATA_PORT} 已被占用：${describePids(pids)}`);
  log('    客户端是把端口编译进产物的（--dart-define），所以这个端口不能换；');
  log('    复用别人的数据服务也不行 —— 那等于在演示另一个库。');
  log(`    先结束它再重跑：taskkill /PID ${pids[0] ?? '<pid>'} /T /F`);
  process.exit(1);
}

// AI 口被占不一定是坏事：本机常常本来就挂着一个网关（比如接 Ollama 的那份），
// 此时再起一个 mock 是多余的，而且新进程会 EADDRINUSE 崩掉、只留下一段看不懂
// 的异常栈 —— 实测撞过一次，栈还照样报「全部判据通过」。所以先探活再判。
const aiPortTaken = flag('no-ai') ? false : await portIsListening(AI_PORT);
let reuseAi = false;
if (aiPortTaken) reuseAi = await waitForHealth(`http://127.0.0.1:${AI_PORT}/ai/health`, 10);
const aiPortBlocked = aiPortTaken && !reuseAi;
if (aiPortTaken) {
  const who = describePids(listenersOn(AI_PORT));
  if (reuseAi) {
    log(`AI 端口 ${AI_PORT} 上已有一个探活通过的网关（${who}），直接复用`);
  } else {
    log(`⚠️ AI 端口 ${AI_PORT} 被占（${who}），但它没响应 /ai/health。`);
    log('    再起一个只会 EADDRINUSE 崩掉（那段异常栈和真正的问题无关），所以这次**不起** AI 网关。');
    log('    想让 AI 链路也通：先结束它再重跑。');
  }
}

// ===== ① 起库 =====

if (DEV_CREDENTIALS.source === 'local') {
  log('本机凭据：.dev-credentials.json（随机生成一次并复用，不入库；可用环境变量覆盖）');
}

if (flag('reset')) {
  log(`清库：${DATA_DIR}`);
  if (!(await removeDirWithRetry(DATA_DIR, { attempts: 3, budgetMs: 6000 }))) {
    log('⚠️ 目录没删干净（多半有 postgres 还占着）。先确认没有残留的 postgres 进程再重试。');
    process.exit(1);
  }
}
const fresh = !fs.existsSync(path.join(DATA_DIR, 'PG_VERSION'));

const pg = new EmbeddedPostgres({
  databaseDir: DATA_DIR,
  port: PG_PORT,
  user: LOCAL_PG.admin.user,
  password: LOCAL_PG.admin.password,
  persistent: true,
  initdbFlags: ['--locale=C', '-E', 'UTF8'],
  // PG 自己的日志默认整份吞掉。它在「一切正常」时是对的（很吵：checkpoint、
  // statement、autovacuum 每秒都有），但它把**最该看见的那几行**也吞了：
  // 后端崩溃、FATAL、崩溃恢复。
  //
  // 2026-09-20 走查中途 PG 崩过一次并进了 recovery，现场只剩客户端看到的一句
  // 「数据库暂时无法连接」，真因（`could not open file … Permission denied`）
  // 只能靠猜 —— 那次排查绕了很远。所以这里只放行会改变结论的那几类，
  // 其余照旧安静：日志的价值在于**出事时它在**，不是在于它全。
  onLog: (line) => {
    if (/FATAL|PANIC|ERROR|recovery|shutting down|terminating/i.test(line)) {
      process.stderr.write(`[pg] ${line}\n`);
    }
  },
  onError: (e) => process.stderr.write(`[pg] ${e?.message ?? e}\n`),
});

if (fresh) {
  log(`首次初始化数据目录：${DATA_DIR}`);
  await pg.initialise();
} else {
  log(`复用已有数据目录：${DATA_DIR}（要重来加 --reset）`);
}
await pg.start();
log(`PostgreSQL 已就绪（端口 ${PG_PORT}，库 ${LOCAL_PG.database}）`);

// ===== ② 建库 + 迁移 =====

{
  const admin = pg.getPgClient();
  await admin.connect();
  const exists = await admin.query('select 1 from pg_database where datname = $1', [LOCAL_PG.database]);
  if (exists.rowCount === 0) await admin.query(`create database "${LOCAL_PG.database}"`);
  await admin.end();

  const client = pg.getPgClient(LOCAL_PG.database);
  await client.connect();
  try {
    const applied = await runMigrations(client, sqlDir, {
      rolePasswords: {
        appRls: DEV_CREDENTIALS.appRlsPassword,
        appAuth: DEV_CREDENTIALS.appAuthPassword,
      },
    });
    log(applied.length === 0 ? '迁移：无新增' : `迁移：应用了 ${applied.join(' / ')}`);
  } finally {
    await client.end();
  }
}

// ===== ③ 起数据服务 =====

const dbEnv = {
  PGHOST: '127.0.0.1',
  PGPORT: String(PG_PORT),
  PGDATABASE: LOCAL_PG.database,
  PGUSER: LOCAL_PG.app.user,
  PGPASSWORD: LOCAL_PG.app.password,
  // 两个角色都要给。漏掉 PG_AUTH_* 时注册登录会以「手机号已占用」之类的
  // 假象失败 —— 因为鉴权连接退回了应用角色，一行账号也读不到。
  PG_AUTH_USER: LOCAL_PG.auth.user,
  PG_AUTH_PASSWORD: LOCAL_PG.auth.password,
  AI_SESSION_SECRET: SESSION_SECRET,
  PORT: String(DATA_PORT),
  BIND_HOST,
  // 手机浏览器打开 Web 版时，页面来源是局域网的 http://IP:8088；
  // 不放行它，页面里每个请求都会在预检就失败（见 CORS_ALLOW_ORIGIN 的注释）。
  CORS_ALLOW_ORIGIN: process.env.CORS_ALLOW_ORIGIN
    ?? (LAN ? `http://${LAN_IP}:${WEB_PORT}` : ''),
  IMAGE_ROOT_DIR,
};

const dataServer = spawn(process.execPath, ['src/dev-server.js'], {
  cwd: serviceRoot,
  stdio: ['ignore', 'pipe', 'pipe'],
  env: { ...process.env, ...dbEnv },
});
dataServer.stdout.on('data', (b) => process.stdout.write(`[data] ${b}`));
dataServer.stderr.on('data', (b) => process.stderr.write(`[data] ${b}`));
children.push({ label: 'data', child: dataServer });

if (!(await waitForHealth(`http://127.0.0.1:${DATA_PORT}/health`))) {
  log('✗ 数据服务没起来。看上面的 [data] 输出 —— 最常见是端口被占，或启动自检没过。');
  killChildren();
  forceStopPostgres(pg);
  process.exit(1);
}
log(`数据服务已监听 http://127.0.0.1:${DATA_PORT}`);

// ===== ④ 起 AI 网关（可选）=====

let aiUp = reuseAi;
if (!flag('no-ai') && !reuseAi && !aiPortBlocked) {
  const gatewayRoot = path.join(repoRoot, 'backend', 'ai-gateway');
  if (fs.existsSync(path.join(gatewayRoot, 'src', 'dev-server.js'))) {
    const ai = spawn(process.execPath, ['src/dev-server.js'], {
      cwd: gatewayRoot,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: {
        ...process.env,
        PORT: String(AI_PORT),
        // 本机没有方舟的 Key，默认走 mock 模型：它能返回**形状正确**的响应，
        // 所以客户端那条链（请求 → 解析 → 落库 → 降级）是真的被跑过一遍的。
        // 要接本机的 Ollama，见 ai-gateway/README.md（纯配置，不改代码）。
        AI_MODEL_CLIENT: process.env.AI_MODEL_CLIENT ?? 'mock',
        BIND_HOST,
        // 上传地址是**签给客户端**的：客户端拿它去 PUT 图片字节。所以它必须是
        // 「客户端视角能到达」的地址。绑了局域网却还签 `127.0.0.1` 的话，
        // 手机拿到的是「上传到手机自己」—— 症状是拍照上传失败、其余功能却都正常。
        AI_UPLOAD_URL_BASE: process.env.AI_UPLOAD_URL_BASE
          ?? `http://${LAN_IP ?? '127.0.0.1'}:${AI_PORT}`,
        AI_UPLOAD_SIGNING_SECRET: process.env.AI_UPLOAD_SIGNING_SECRET ?? SESSION_SECRET,
        // 会话密钥必须与数据服务**同一个值**：客户端登录时拿到的票是数据服务
        // 签的，网关要用同一把密钥才验得开。给网关不配的结果不是「鉴权失效」，
        // 而是**网关启动即报错**（config.js：requireAuth 打开却没有密钥）。
        AI_SESSION_SECRET: process.env.AI_SESSION_SECRET ?? SESSION_SECRET,
        // 默认**打开**：演示栈跑什么路径，决定它能不能暴露出问题。
        // 关着的时候客户端不带票也能跑通，「客户端漏传 Authorization」
        // 这类缺口在本机永远看不见（2026-09-20 打开时发现的就是这个）。
        // 本地想临时关掉：AI_REQUIRE_AUTH=false npm run dev:stack
        AI_REQUIRE_AUTH: process.env.AI_REQUIRE_AUTH ?? 'true',
      },
    });
    ai.stdout.on('data', (b) => process.stdout.write(`[ai] ${b}`));
    ai.stderr.on('data', (b) => process.stderr.write(`[ai] ${b}`));
    children.push({ label: 'ai', child: ai });
    aiUp = await waitForHealth(`http://127.0.0.1:${AI_PORT}/ai/health`);
    log(aiUp ? `AI 网关已监听 http://127.0.0.1:${AI_PORT}（模型：mock）` : '⚠️ AI 网关没起来，客户端会自动回落本地实现');
  }
}

// ===== ⑤ 演示数据 =====

if (!flag('no-seed')) {
  log('灌演示数据…');
  try {
    await seedDemo({ base: `http://127.0.0.1:${DATA_PORT}`, log: (m) => log(`  ${m}`) });
  } catch (e) {
    // 种子失败**不退出**：服务已经起来了，也许是某张表的数据已经存在导致的
    // 边缘情况。让演示能继续，把问题如实打出来。
    log(`⚠️ 演示数据没灌完：${e.message}`);
  }
}

// ===== ⑥ 收尾 =====

const stop = async (code = 0) => {
  log('收尾中…');
  killChildren();
  // 先让两个服务退干净**再**停库。反过来做的话，连接池里的空闲连接会先看到
  // PG 消失，打出「Connection terminated unexpectedly」—— 一次正常的 Ctrl+C
  // 看起来像崩溃，下次排查时会去查一个不存在的问题。
  await new Promise((r) => setTimeout(r, 800));
  forceStopPostgres(pg);
  await new Promise((r) => setTimeout(r, 800));
  process.exit(code);
};
process.on('SIGINT', () => stop(0));
process.on('SIGTERM', () => stop(0));

log('');
log('─'.repeat(72));
const shownHost = LAN ? LAN_IP : '127.0.0.1';
log(`数据服务   http://${shownHost}:${DATA_PORT}   （/health 可探活）`);
if (LAN) {
  log(`           ↑ 手机走的就是这个**局域网地址**；` + '手机上的 127.0.0.1 指的是手机自己。');
}
if (aiUp) {
  log(`AI 网关    http://${shownHost}:${AI_PORT}   （${reuseAi ? '复用本机已在跑的那份' : '模型 mock'}）`);
} else if (aiPortBlocked) {
  log(`AI 网关    未启动（端口被占，见上面的警告）—— AI 功能会回落本地实现`);
}
log(`数据库     postgres://127.0.0.1:${PG_PORT}/${LOCAL_PG.database}   （数据目录 ${path.relative(repoRoot, DATA_DIR)}）`);
log(`照片存储   ${IMAGE_ROOT_DIR}   （作业照片的字节落在这里，库里存的是相对路径）`);
log('');
log('演示账号（密码都是 ' + DEMO.password + '，用手机号登录）');
log(`  学生  ${DEMO.student.name}   ${DEMO.student.phone}`);
log(`  学生  ${DEMO.student2.name}   ${DEMO.student2.phone}`);
log(`  家长  ${DEMO.parent.name}   ${DEMO.parent.phone}   （已结伴上面两个孩子）`);
log('');
log('客户端指到本机：');
log(`  flutter run -d chrome --dart-define=DATA_API_BASE_URL=http://127.0.0.1:${DATA_PORT} \\`);
log(`    --dart-define=AI_BASE_URL=http://127.0.0.1:${AI_PORT} \\`);
log('    --dart-define=AI_TIMEOUT_MS=90000 --dart-define=AI_UPLOAD_TIMEOUT_MS=120000');
log('（这条走**云端模式**，数据由服务端 seed-demo.mjs 灌；不需要 SEED_DEMO_DATA。）');
if (LAN) {
  log('');
  log(`手机路线 A · 浏览器打开 Web 版（最快，不用构建 APK、不用装包）`);
  log(`  ① 构建：flutter build web --release --no-tree-shake-icons \\`);
  log(`       --dart-define=DATA_API_BASE_URL=http://${LAN_IP}:${DATA_PORT} \\`);
  log(`       --dart-define=AI_BASE_URL=http://${LAN_IP}:${AI_PORT} \\`);
  log('       --dart-define=AI_TIMEOUT_MS=90000 --dart-define=AI_UPLOAD_TIMEOUT_MS=120000');
  log(`  ② 静态服务要绑所有网卡（--bind 127.0.0.1 的话手机够不着）：`);
  log(`       cd build/web && python -m http.server ${WEB_PORT} --bind 0.0.0.0`);
  log(`  ③ 手机浏览器打开 http://${LAN_IP}:${WEB_PORT}`);
  log(`     数据服务已放行来源 http://${LAN_IP}:${WEB_PORT}；换端口就加 CORS_ALLOW_ORIGIN 重起。`);
  log('');
  log(`手机路线 B · 装 APK（局域网联调，地址是编译期常量）`);
  log('  flutter build apk --debug --target-platform android-arm64 \\');
  log(`    --dart-define=DATA_API_BASE_URL=http://${LAN_IP}:${DATA_PORT} \\`);
  log(`    --dart-define=AI_BASE_URL=http://${LAN_IP}:${AI_PORT} \\`);
  log('    --dart-define=AI_TIMEOUT_MS=90000 --dart-define=AI_UPLOAD_TIMEOUT_MS=120000');
  log('  产物 build/app/outputs/flutter-apk/app-debug.apk，装到手机上即可。');
  log('  ⚠️ 这条**必须是 `--debug`，不是 `--release`**：Android 9（API 28）起系统默认禁明文');
  log('     HTTP，而明文例外只开在 debug 变体（android/app/src/debug/AndroidManifest.xml）。');
  log('     拿 --release 构建出来的包装上去，连 http:// 是**所有请求静静失败** ——');
  log('     不报错、不提示，看着像服务端没起来。要发 --release，服务端得先有 HTTPS。');
  log('  ⚠️ 换一次 Wi-Fi（IP 变了）就要按新 IP 重新构建一次。');
  log('');
  log('两条路线共通：手机要和电脑连**同一个 Wi-Fi**；连不上先看电脑防火墙（README 有一节）。');
} else {
  log('');
  log('要给手机连：加 `--lan` 重起（两个服务都绑到所有网卡，并打印手机版的地址与命令）。');
}
log('⚠️ 客户端必须是用**上面这条命令**构建的。拿本地模式的产物（不带 DATA_API_BASE_URL）');
log('   打开，它查的是设备自己那份库 —— 在这个栈里注册的账号会显示「未注册」。');
log('   数据没丢：两份库从不同步，它还在服务端这里。');
log('');
log(RUN
  ? `准备执行：${RUN}`
  : 'Ctrl+C 停止（数据库保留，下次起来数据还在；要清空加 --reset）');
log('─'.repeat(72));

// ===== ⑦ 跑一条命令，然后自动收栈（`--run`）=====

if (RUN) {
  const code = await new Promise((resolve) => {
    const child = spawn(RUN, {
      shell: true,
      stdio: 'inherit',
      cwd: repoRoot,
      env: {
        ...process.env,
        // 把栈**自己的**地址交给子进程：调用方不用再抄一遍端口，
        // 而抄错（比如填成 AI 网关的 8787）的症状是「一堆 404」，
        // 看起来像端点没实现，实际上连错服务了。
        CLOUD_LIVE_BASE: process.env.CLOUD_LIVE_BASE ?? `http://127.0.0.1:${DATA_PORT}`,
        DATA_API_BASE_URL: process.env.DATA_API_BASE_URL ?? `http://127.0.0.1:${DATA_PORT}`,
        AI_BASE_URL: process.env.AI_BASE_URL ?? (aiUp ? `http://127.0.0.1:${AI_PORT}` : ''),
      },
    });
    child.on('error', (e) => {
      log(`✗ 命令没能起来：${e.message}`);
      resolve(1);
    });
    child.on('exit', (c, signal) => resolve(signal ? 1 : (c ?? 0)));
  });
  log(`命令退出码 ${code} —— 收栈`);
  await stop(code);
}
