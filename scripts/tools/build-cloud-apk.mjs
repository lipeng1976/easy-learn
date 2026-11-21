// 构建**连云端**的 APK：把两个服务地址在**编译期**烧进产物。
//
// ## 为什么要有这个脚本
//
// `DATA_API_BASE_URL` / `AI_BASE_URL` 都是 `String.fromEnvironment` 读的
// **编译期常量** —— 运行时改不了。所以「这个 APK 连哪台服务」是构建那一刻定死的，
// 装在手机上再改一律无效。命令又长（两个长域名 + 两个必带 flag），抄错一个字符的
// 症状是「登录不上 / AI 不可用」，看起来完全像**服务端坏了**。
//
// 所以真值只放一处：`.env.prod` 的 `CLIENT_DATA_BASE_URL` / `CLIENT_AI_BASE_URL`
// （由 `s deploy` 的 HTTP 触发器输出得来），本脚本只读它，不重复定义。
//
// ## 用法
//
// ```bash
// node tools/build-cloud-apk.mjs                              # 从 .env.prod 读
// node tools/build-cloud-apk.mjs --data <url> --ai <url>      # 临时覆盖（调试用）
// node tools/build-cloud-apk.mjs --out apk                    # 同时把 APK 拷到项目根
// node tools/build-cloud-apk.mjs --out apk --log <path>       # 另指定日志路径
// ```
//
// ⚠️ **不要**用 `| Tee-Object -FilePath x.txt` 去存日志 —— 那会把日志写成
//    UTF-16LE 且先经历一次 CP936 误码，两层叠加后终端和文件同时乱码，
//    看起来像「构建报错」。本脚本自己往 `build/_logs/build-cloud-apk.log`
//    写 UTF-8 日志，不需要任何 shell 重定向。
//
// ## 三道闸门（都是为了拦住「已经烧错了，但没人知道」）
//
// 1. **地址必须像生产地址**：`127.0.0.1` / 私有网段 / 空值一律拒绝。
//    内网地址尤其危险 —— 手机上根本连不到，而现象是「一直转圈」。
// 2. **两个地址必须探活**：构建前先打 `/health` 与 `/ai/health`。
// 3. **子进程管道自检**：见下面 `checkPipeHealth()`，这是一次真实踩坑的固化。
import { spawn, spawnSync } from 'node:child_process';
import {
  appendFileSync, copyFileSync, existsSync, mkdirSync, statSync, writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { loadEnv, valueOf } from '../serverless/data-service/scripts/lib/env-file.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..');

const argv = process.argv.slice(2);
const outToRoot = argv.includes('--out');

// ── 日志自落盘 ──────────────────────────────────────────────────────
// ⚠️ 为什么不让调用方用 PowerShell 的 `| Tee-Object` 存日志：
//    2026-09-26 实测，那条命令上叠了**两个**独立的坑 ——
//    ① `Tee-Object` 默认写 **UTF-16LE**（文件头 `ff fe`）。记事本打开"看着还行"，
//       但 grep / 编辑器 / AI 读到的是 `\ufffd` 与方块；
//    ② 更早一层：`flutter` / `node` 写的是 UTF-8 字节，PowerShell 管道**按 CP936
//       解码**再转存 ⇒ 得到 `鈺愨晲`（UTF-8 被当 GBK 读的典型形状）。
//    两层叠起来，**终端和文件同时乱码**，看起来完全像「构建报错了一堆乱码」，
//    而实际上构建成功、产物正常。
//    所以让脚本自己写一份 UTF-8 日志，不依赖任何 shell 重定向。
const logPath = resolve(
  repoRoot,
  valueOf(argv, '--log') ?? join('build', '_logs', 'build-cloud-apk.log'),
);
mkdirSync(dirname(logPath), { recursive: true });
writeFileSync(logPath, ''); // 每次构建重写，不留上一次的残留

/**
 * ⚠️ 故意用**同步**写。
 *
 * 日志只有几十行，同步写的开销可以忽略；而换成流 + `end()` 会踩坑：
 * `die()` 里紧跟着 `process.exit(1)`，异步 flush 会被直接掐掉 ——
 * 丢掉的偏偏是**最后一条、也往往正是真正失败原因**那行。
 * 那就是本项目最烦的「静默失败」：日志看起来写成功了，关键那条不在。
 */
function logLine(s) {
  try {
    appendFileSync(logPath, s + '\n');
  } catch {
    /* 日志写不进去不该影响构建本身 */
  }
}

// hook 掉 console：同一行同时进终端（可能被 shell 改坏）与日志文件（保证 UTF-8）
const rawLog = console.log.bind(console);
const rawErr = console.error.bind(console);
console.log = (...a) => { const s = a.map(String).join(' '); rawLog(s); logLine(s); };
console.error = (...a) => { const s = a.map(String).join(' '); rawErr(s); logLine(s); };

function die(msg) {
  console.error('\n✗ ' + msg);
  process.exit(1);
}

// ── ① 取地址（参数优先，否则读 .env.prod）────────────────────────────
const envFile = resolve(repoRoot, '.env.prod');
if (!existsSync(envFile)) die('找不到 ' + envFile);

const { env } = loadEnv(envFile);
const dataUrl = valueOf(argv, '--data') ?? env.CLIENT_DATA_BASE_URL ?? '';
const aiUrl = valueOf(argv, '--ai') ?? env.CLIENT_AI_BASE_URL ?? '';

if (!dataUrl || !aiUrl) {
  die(
    '地址没取到。请在 .env.prod 里配 CLIENT_DATA_BASE_URL 与 CLIENT_AI_BASE_URL\n' +
      '   （值来自 `s deploy` 输出的两个 HTTP 触发器地址），或用 --data / --ai 传。',
  );
}

/**
 * 地址必须像**生产地址**。
 *
 * ⚠️ 这一条拦的是本项目记录过的头号静默失败形态：把 `127.0.0.1` 或内网地址
 * 烧进 APK → 手机装上一路转圈 / 报网络错误，而服务端一切正常、日志一条都不来。
 * 内网地址（10./192.168./172.16-31.）尤其隐蔽：本机 curl 它是通的，手机不通。
 */
function assertRoutable(label, url) {
  let u;
  try {
    u = new URL(url);
  } catch {
    die(label + ' 不是合法 URL：' + url);
  }
  if (u.protocol !== 'https:') {
    die(label + ' 必须是 https（Android release 包默认禁明文 http）：' + url);
  }
  const host = u.hostname;
  if (host === 'localhost' || host === '127.0.0.1' || host === '::1') {
    die(label + ' 指向本机（' + host + '）—— 那只有在这台电脑上跑得通，手机会连不上。');
  }
  const priv = /^10\./.test(host) || /^192\.168\./.test(host) || /^172\.(1[6-9]|2\d|3[01])\./.test(host);
  if (priv) {
    die(label + ' 是内网地址（' + host + '）—— 手机在公网上连不到它。');
  }
  console.log('  ✓ ' + label + '  ' + url);
}

console.log('════ ① 构建参数 ════');
assertRoutable('数据服务', dataUrl);
assertRoutable('AI 网关 ', aiUrl);

// ── ② 探活 ────────────────────────────────────────────────────────
console.log('');
console.log('════ ② 两个地址探活 ════');
/**
 * ⚠️ 必须重试，不能一次定生死（2026-09-24 实测踩到）。
 *
 * FC 的 HTTP 触发器会**偶发**掐断一次请求 —— 实测同一条 URL 连打三次：
 * `200 (0.43s)` · `200 (0.21s)` · `000 (19.6s 后中断)`。
 * 这**不是冷启动**：冷启动是「第一次慢、之后快」，而这是**连着成功两次后突然断**。
 * 单次探活当硬闸门 → 一次抖动就把正常服务判死、把构建拦下（本轮真的发生了）。
 * 📌 判据取自「**可重复**」而不是「一次成功」：任一成功即算过，
 *    只有**连续 N 次全失败**才判不通。
 */
const PROBE_TRIES = 3;
async function probe(label, url, path) {
  const target = label + path;
  let last = '';
  for (let i = 1; i <= PROBE_TRIES; i++) {
    const t0 = Date.now();
    try {
      const r = await fetch(url + path, { signal: AbortSignal.timeout(30000) });
      if (r.ok) {
        const note = i > 1 ? `（第 ${i} 次才通 —— 前 ${i - 1} 次是抖动）` : '';
        console.log(`  ✓ ${target}  HTTP ${r.status}  ${Date.now() - t0}ms${note}`);
        return;
      }
      last = 'HTTP ' + r.status + '（期望 200）';
    } catch (e) {
      last = (e?.message ?? String(e)) + `（耗时 ${Date.now() - t0}ms）`;
    }
    if (i < PROBE_TRIES) {
      console.log(`  … ${target} 第 ${i} 次失败：${last} —— 重试`);
      await new Promise((r) => setTimeout(r, 1500 * i));
    }
  }
  die(
    `${target} 连续 ${PROBE_TRIES} 次探不通：${last}\n` +
      '   · 每次都「卡十几秒后中断」→ 多半在函数实例 / VPC 侧，去看 FC 日志；\n' +
      '   · 每次都秒回非 200 → 地址对，但路由或鉴权不对；\n' +
      '   · 全都不通 → 再确认 `s deploy` 是否成功、地址是否已变（重新部署会换域名）。',
  );
}
await probe('数据服务', dataUrl, '/health');
await probe('AI 网关 ', aiUrl, '/ai/health');

// ── ③ 子进程管道自检 ───────────────────────────────────────────────
/**
 * ⚠️ 这条判据是**一次真实踩坑的固化**（2026-09-24）。
 *
 * 当时 `flutter` 一启动就报 `CreateFile failed 231 (所有的管道范例都在使用中)`，
 * 看着像 Flutter 坏了。分层实验之后真相是：
 *
 * · `CreateProcess` 本身**完全正常**（`stdio: 'inherit'` / `'ignore'` 都成功）；
 * · 只要**用命名管道重定向 stdio**（`stdio: 'pipe'`，或默认的 encoding 捕获）就 `EBUSY`；
 * · 而且**只开 1 对管道成功、开 2 对就失败** —— 系统的命名管道实例已被挤到枯竭；
 * · 同一时刻有个系统服务（`mtkbtsvc`，联发科蓝牙）持有 **17.8 万个句柄**且在
 *   以约 9 个/秒持续增长，占全系统句柄的 40%。
 *
 * `flutter` 要起 `cmd.exe /c ver`（还有 git / adb）并且都要读输出 → 必然用管道
 * → 必然失败。**所以这不是项目的问题，是机器当时的状态**；重启后即恢复。
 *
 * 先自检一遍，是为了把「一屏乱码 + 崩溃报告」换成一句能照做的结论。
 */
function checkPipeHealth() {
  // ⚠️⚠️ 必须开**三对**管道（stdin/stdout/stderr），不能用「只开一对」的省钱写法。
  //
  // 第一版就是这么写的（`['ignore','pipe','ignore']`），结果自检报「✓ 可用」而
  // flutter 紧接着照样 231 —— **判据与被判对象不同构**：枯竭的机器上恰好还能挤出
  // 一对管道，所以「一对能成」根本不代表「三对能成」。判据必须按 flutter 的真实
  // 需求来配（它要的正是三对，外加后续 git / adb 的各三对）。
  const r = spawnSync(process.execPath, ['-e', 'process.stdout.write("ok")'], {
    stdio: ['pipe', 'pipe', 'pipe'],
    encoding: 'utf8',
    timeout: 20000,
  });
  if (r.error) {
    // ⚠️ 2026-10-03 定案（旧文案「命名管道已经枯竭 ⇒ 重启机器」是**错的**，曾把我带进
    //    mtkbtsvc / 重启 / 卸载反作弊软件三条歧路）：
    //    真正的签名 = 钩子**只在「为读数据而打开管道」时**失败；`CreateNamedPipeW` 没被钩，
    //    所以「建得出、打不开」。对照实验：本机 `net.createServer()` 自建管道 **5/5 成功**
    //    ⇒「系统管道池枯竭」被证伪。`dangerouslyDisableSandbox` 只解除策略限制、**解不掉 DLL 注入**。
    //    取证全过程见 .workbuddy/memory/DETAIL.md §3–§8。
    console.error('');
    console.error('✗ 起不了子进程：CreateFile failed 231 (ERROR_PIPE_BUSY)。');
    console.error('  ⚠️ 这不是项目的问题，也**不是**「管道用尽」——是这个**沙箱环境**的问题。');
    console.error('  签名：钩子只在「为读数据而打开管道」时失败，建管道本身正常；');
    console.error('        本脚本的 bash 的父进程**实测就是** sandbox-cli.exe（进程树已确认）。');
    console.error('');
    console.error('  处置：在 **WorkBuddy 之外的普通终端**里跑本脚本（开始菜单 → PowerShell / cmd，cd 到项目目录）。');
    console.error('  已知无效（别再试了）：重启机器 · 卸载反作弊软件 · 重开 WorkBuddy 会话 · 加沙箱豁免参数。');
    console.error('  取证细节：.workbuddy/memory/DETAIL.md §3–§8。');
    process.exit(1);
  }
  console.log('  ✓ 命名管道可用');
}

console.log('');
console.log('════ ③ 子进程管道自检 ════');
checkPipeHealth();

// ── ④ 构建 ────────────────────────────────────────────────────────
/**
 * ⚠️ 代理变量必须清掉。带着 `HTTP_PROXY` 跑 flutter 会得到
 * `WebSocketException`（它连自己的 pub / 引擎下载都走代理）——
 * **看着像测试坏了，其实是代理**。
 *
 * ⚠️⚠️ 但 `PUB_HOSTED_URL` / `FLUTTER_STORAGE_BASE_URL` **不能清** ——
 * 它们是**国内镜像**，和代理是两回事。2026-09-24 实测：把这两条
 * 混在一起清掉之后，pub 落到 `pub.dev`，构建**卡在 `Downloading packages...`
 * 整整 20 分钟、零输出**——不是报错、也不是快速失败，是**死等**。
 * 而同一时刻前台 `curl https://pub.dev` 还是 HTTP 200，
 * 所以「源可达」**不等于**「下载能完成」。
 * 📌 通则：**超时类失败会把判据自己骗过去**（挂住看着像在干活）。
 * 再叠加一条本机已知约束：**后台任务里沙箱豁免不生效** —— 构建一旦被
 * auto-background，网络就被拦，只会挂得更死。
 * → 所以下面干脆走**离线**路径（依赖已在本机 pub cache，实测 320 个条目）。
 */
const childEnv = { ...process.env };
for (const k of [
  'HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy',
  'ALL_PROXY', 'all_proxy', 'NO_PROXY', 'no_proxy',
]) {
  delete childEnv[k];
}
// 镜像变量：环境里有就留着；没有也不强行设 —— 因为下一步走 `--offline`。

/** 起 flutter，输出直连终端。返回退出码。 */
function runFlutter(a, env) {
  return new Promise((res) => {
    // ⚠️ `stdio: 'inherit'`：输出直连终端，既不经过管道（本机管道紧张时更稳），
    //    也不会被捕获后一次性倒出来（长构建时看不到进度）。
    const p = spawn('flutter', a, { cwd: repoRoot, env, stdio: 'inherit', shell: true });
    p.on('error', (e) => die('起不了 flutter：' + (e?.message ?? e)));
    p.on('close', res);
  });
}

console.log('');
console.log('════ ④a 离线解析依赖（不联网）════');
// ⚠️ 先离线 pub get，是为了把「依赖够不够」**单独拿到前面来判**：
//    缺了立刻说清楚，而不是混在几分钟的构建日志里变成一句含糊的下载失败。
//    过了这一步，后面用 `--no-pub` 跳过 pub，整条构建路径就**完全不依赖网络**。
const pubCode = await runFlutter(['pub', 'get', '--offline'], childEnv);
if (pubCode !== 0) {
  die(
    '离线解析依赖失败（退出码 ' + pubCode + '）。\n' +
    '    本机 pub cache 不全 —— 这一步需要联网补齐，请在**前台**执行\n' +
    '    `flutter pub get`（⚠️ 别放后台：后台任务的沙箱豁免不生效，会挂死），\n' +
    '    成功后再重跑本脚本。'
  );
}
console.log('  ✓ 依赖齐全（走本地 pub cache）');

const args = [
  'build', 'apk', '--release',
  // ⚠️ 不能省：项目里有动态构造的 IconData，tree-shaking 会把它判成「没用到」
  //    删掉 → 症状是**部分图标变成方框**（代码全对、测试全绿）。
  '--no-tree-shake-icons',
  // ⚠️ 上一步已经离线解析过了。加上这一条，构建就不再碰网络。
  '--no-pub',
  '--dart-define=DATA_API_BASE_URL=' + dataUrl,
  '--dart-define=AI_BASE_URL=' + aiUrl,
];

console.log('');
console.log('════ ④b flutter build apk（全量构建，通常几分钟）════');
console.log('  ' + ['flutter', ...args].join(' '));
console.log('');

const code = await runFlutter(args, childEnv);
if (code !== 0) die('flutter build 失败，退出码 ' + code + '（详情见上面的输出）');

// ── ⑤ 产物 ────────────────────────────────────────────────────────
const apk = join(repoRoot, 'build', 'app', 'outputs', 'flutter-apk', 'app-release.apk');
if (!existsSync(apk)) die('构建报成功但没找到 ' + apk);

const mb = (statSync(apk).size / 1024 / 1024).toFixed(1);
console.log('');
console.log('════ ⑤ 产物 ════');
console.log('  ' + apk + '  （' + mb + ' MB）');
console.log('  连的服务：' + dataUrl);
console.log('           ' + aiUrl);
console.log('');
console.log('⚠️ 装到手机后**必须**确认这两条，否则等于没验：');
console.log('   1. 用**云端库里已存在**的账号登录（查账号：cd serverless/data-service && node scripts/cloud-accounts.mjs）');
console.log('   2. AI 功能能用（家长端「AI 观察」页能看到用量，说明网关真的被调到了）');

if (outToRoot) {
  const dest = join(repoRoot, 'easy-learn-cloud.apk');
  copyFileSync(apk, dest);
  console.log('');
  console.log('  已另存一份到：' + dest);
}

console.log('');
console.log('日志已写入：' + logPath);
console.log('（UTF-8。若上面终端里的中文显示成方块或 `鈺愨晲` —— 那是 PowerShell 管道的');
console.log('  解码问题，**不是**构建问题；这份文件里的内容是干净的，直接看它。）');
