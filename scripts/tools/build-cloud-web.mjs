// 构建**连云端**的 Flutter Web 产物，并整理成一个「可以直接发布」的目录。
//
// ## 为什么要有这个脚本
//
// 和 `build-cloud-apk.mjs` 同源：`DATA_API_BASE_URL` / `AI_BASE_URL` 都是
// `String.fromEnvironment` 读的**编译期常量**（`lib/services/data_config.dart:75`、
// `lib/services/ai_config.dart:134`），运行时改不了 —— 网页装在谁的浏览器里都一样。
// 而这两个参数一旦漏掉或写错，产物会**安安静静地**变成本地模式（或连到 127.0.0.1），
// 表现是「登录不上 / 一直转圈」，看起来完全像**服务端坏了**。
// 所以真值只放一处：`.env.prod` 的 `CLIENT_DATA_BASE_URL` / `CLIENT_AI_BASE_URL`。
//
// ## 用法
//
// ```bash
// node tools/build-cloud-web.mjs              # 从 .env.prod 读地址，产物整理到 site/
// node tools/build-cloud-web.mjs --out site   # 指定发布目录
// ```
//
// ⚠️ **必须在「你自己的终端」里跑**（不是在协作窗口/自动化里）：
//    Flutter 起子进程时要用**命名管道**，而被注入的沙箱会拦「以只读权限打开命名管道」
//    ⇒ 一启动就 `CreateFile failed 231`。脚本第 ③ 步会先探这一条，探到就当场停下
//    并说清楚原因，而不是给你一屏崩溃报告。
//
// ## 六道闸门（都是为了拦住「已经烧错了，但没人知道」）
//
// 1. **地址必须像生产地址**：非 https / 本机 / 私有网段一律拒。
// 2. **两个地址必须探活**：构建前打 `/health` 与 `/ai/health`（带重试，偶发抖动不算不通）。
// 3. **flutter 真的能跑**：见 `assertFlutterRunnable()`。
// 4. **产物必须指向生产**：复用 `tools/build-mode.mjs` 的判据（不在这里重抄一份）。
// 5. **产物里不许残留本机地址**：`127.0.0.1:8788` 这类一个都不许有。
// 6. **发布目录不叫 `build`**：发布工具有「排除构建产物」的规则，万一它按目录名匹配，
//    整个 `build/` 会被跳过 —— 上传成功、页面空白，而且没有任何报错。
import { spawn, spawnSync } from 'node:child_process';
import {
  appendFileSync, cpSync, existsSync, mkdirSync, readFileSync, rmSync,
  statSync, writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { loadEnv, valueOf } from '../serverless/data-service/scripts/lib/env-file.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..');

const argv = process.argv.slice(2);

// ── 日志自落盘（UTF-8，不依赖任何 shell 重定向）────────────────────────
// ⚠️ 同 `build-cloud-apk.mjs`：PowerShell 的 `| Tee-Object` 会写出 UTF-16LE 且先经历
//    一次 CP936 误码，两层叠加后看起来像「构建报错了一堆乱码」。
const logPath = resolve(
  repoRoot,
  valueOf(argv, '--log') ?? join('build', '_logs', 'build-cloud-web.log'),
);
mkdirSync(dirname(logPath), { recursive: true });
writeFileSync(logPath, '');

// ⚠️ 同步写：`die()` 后面紧跟 `process.exit(1)`，异步 flush 会被掐掉，
//    丢的偏偏是最后那条、也往往正是真正原因那行。
function logLine(s) {
  try {
    appendFileSync(logPath, s + '\n');
  } catch {
    /* 日志写不进去不该影响构建本身 */
  }
}
const rawLog = console.log.bind(console);
const rawErr = console.error.bind(console);
console.log = (...a) => { const s = a.map(String).join(' '); rawLog(s); logLine(s); };
console.error = (...a) => { const s = a.map(String).join(' '); rawErr(s); logLine(s); };

function die(msg) {
  console.error('\n✗ ' + msg);
  console.error('\n日志：' + logPath);
  process.exit(1);
}

// ── ① 取地址 ────────────────────────────────────────────────────────
const envFile = resolve(repoRoot, '.env.prod');
if (!existsSync(envFile)) die('找不到 ' + envFile);

const { env } = loadEnv(envFile);
const dataUrl = valueOf(argv, '--data') ?? env.CLIENT_DATA_BASE_URL ?? '';
const aiUrl = valueOf(argv, '--ai') ?? env.CLIENT_AI_BASE_URL ?? '';

if (!dataUrl || !aiUrl) {
  die(
    '地址没取到。请在 .env.prod 里配 CLIENT_DATA_BASE_URL 与 CLIENT_AI_BASE_URL\n' +
      '   （值来自 `s deploy` 输出的两个 HTTP 触发器地址）。',
  );
}

/** 地址必须像**生产地址** —— 拦的是本项目记录过的头号静默失败形态。 */
function assertRoutable(label, url) {
  let u;
  try {
    u = new URL(url);
  } catch {
    die(label + ' 不是合法 URL：' + url);
  }
  // Web 版也要 https：页面本身会挂在 https 上，去调 http 接口会被浏览器拦掉。
  if (u.protocol !== 'https:') die(label + ' 必须是 https：' + url);
  const host = u.hostname;
  if (host === 'localhost' || host === '127.0.0.1' || host === '::1') {
    die(label + ' 指向本机（' + host + '）—— 网页放到浏览器里就连不上了。');
  }
  if (/^10\./.test(host) || /^192\.168\./.test(host) || /^172\.(1[6-9]|2\d|3[01])\./.test(host)) {
    die(label + ' 是内网地址（' + host + '）—— 公网上的浏览器连不到它。');
  }
  console.log('  ✓ ' + label + '  ' + url);
  return host;
}

console.log('════ ① 构建参数 ════');
assertRoutable('数据服务', dataUrl);
const dataHost = assertRoutable('AI 网关 ', aiUrl);

// ── ② 探活 ──────────────────────────────────────────────────────────
console.log('');
console.log('════ ② 两个地址探活 ════');
/**
 * ⚠️ 不能一次定生死：FC 的 HTTP 触发器会**偶发**掐断一次请求
 * （实测同一条 URL 连着成功两次后突然断，19.6s 无响应）。
 * 判据取「**可重复**」：任一成功即算过，只有连续 N 次全失败才判不通。
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
  die(`${target} 连续 ${PROBE_TRIES} 次探不通：${last}`);
}
await probe('数据服务', dataUrl, '/health');
await probe('AI 网关 ', aiUrl, '/ai/health');

// ── ③ flutter 真的能跑吗 ─────────────────────────────────────────────
/**
 * ⚠️ 这一条**不能**用 `node -e` 起个子进程来代表（`build-cloud-apk.mjs` 那版是这么写的）——
 *    在本机的协作窗口里，Node 走**匿名管道不受影响**，被拦的是 Dart/Flutter 起的
 *    **命名管道**。那时「✓ 管道可用」会紧跟着一屏 `CreateFile failed 231`，
 *    自检把判据自己骗过去了。
 *    ⇒ 判据必须用**被判对象本身**：跑一次 `flutter --version`。
 *      （⚠️ 别用 `dart --version` 代替 —— 它进程内自答、**不 spawn**，永远是通的。）
 */
function assertFlutterRunnable() {
  const r = spawnSync('flutter', ['--version'], {
    cwd: repoRoot,
    stdio: ['ignore', 'pipe', 'pipe'],
    encoding: 'utf8',
    timeout: 180000,
    shell: true,
  });
  const out = `${r.stdout ?? ''}${r.stderr ?? ''}`;
  if (r.status === 0 && !/CreateFile failed 231/.test(out)) {
    const v = (out.match(/Flutter\s+[\d.]+/) ?? ['Flutter'])[0];
    console.log(`  ✓ flutter 可执行（${v}）`);
    return;
  }
  console.error('');
  console.error('✗ 这台机器上 flutter 跑不起来 —— **不是项目的问题**。');
  console.error('');
  if (/CreateFile failed 231/.test(out)) {
    console.error('  现象：`CreateFile failed 231 (所有的管道范例都在使用中)`');
    console.error('  原因两种，处置一样 —— 换到**你自己的终端**里跑：');
    console.error('    · 命名管道被挤到枯竭（有进程持有大量句柄）：');
    console.error('        Get-Process | Sort-Object HandleCount -Descending | Select-Object -First 8 Name,Id,HandleCount');
    console.error('    · 或本进程树被注入了沙箱，它拦「以只读权限打开命名管道」——');
    console.error('        此时 `dart --version` **照样正常**（它不 spawn），别被它骗了。');
  } else {
    console.error('  输出如下（拿它判断是没装、还是 PATH 不对）：');
    console.error(out.split('\n').slice(0, 12).map((l) => '    ' + l).join('\n'));
  }
  process.exit(1);
}

console.log('');
console.log('════ ③ flutter 可执行性 ════');
/**
 * `--from <目录>`：**不构建**，直接拿一份已有的产物走 ⑤⑥ 两道校验（再整理到发布目录）。
 * 用途：产物已经构建过（例如在别的终端里刚跑完），只想重新校验 + 重新整理。
 * ⚠️ 它**不**证明「这份产物是这次那两个地址构建出来的」—— 那由 ⑥ 的地址断言兜。
 */
const fromDir = valueOf(argv, '--from');
if (fromDir) {
  console.log('  （--from：跳过构建，直接校验已有的产物）');
} else {
  assertFlutterRunnable();
}

// ── ④ 构建 ──────────────────────────────────────────────────────────
/**
 * ⚠️ 代理变量必须清掉（带着 `HTTP_PROXY` 跑 flutter 会 WebSocketException）；
 *    但 `PUB_HOSTED_URL` / `FLUTTER_STORAGE_BASE_URL` **不能清** —— 它们是国内镜像。
 */
const childEnv = { ...process.env };
for (const k of ['HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy', 'ALL_PROXY', 'all_proxy', 'NO_PROXY', 'no_proxy']) {
  delete childEnv[k];
}

function runFlutter(a, env) {
  return new Promise((res) => {
    // `stdio: 'inherit'`：输出直连终端，不走管道。
    const p = spawn('flutter', a, { cwd: repoRoot, env, stdio: 'inherit', shell: true });
    p.on('error', (e) => die('起不了 flutter：' + (e?.message ?? e)));
    p.on('close', res);
  });
}

/** 产物来源：默认是本次构建出的 `build/web`，`--from` 时是调用方给的那份。 */
const builtDir = fromDir ? resolve(repoRoot, fromDir) : join(repoRoot, 'build', 'web');

if (!fromDir) {
console.log('');
console.log('════ ④a 离线解析依赖（不联网）════');
const pubCode = await runFlutter(['pub', 'get', '--offline'], childEnv);
if (pubCode !== 0) {
  die(
    '离线解析依赖失败（退出码 ' + pubCode + '）。\n' +
      '    本机 pub cache 不全 —— 请先在**前台**执行 `flutter pub get`（别放后台，后台沙箱豁免不生效会挂死），\n' +
      '    成功后再重跑本脚本。',
  );
}
console.log('  ✓ 依赖齐全（走本地 pub cache）');

const args = [
  'build', 'web', '--release',
  // ⚠️ 不能省：项目里有动态构造的 IconData，tree-shaking 会判成「没用到」删掉
  //    ⇒ 症状是**部分图标变成方框**（代码全对、测试全绿）。
  '--no-tree-shake-icons',
  '--no-pub', // 上一步已离线解析过，这一步不再碰网络
  '--dart-define=DATA_API_BASE_URL=' + dataUrl,
  '--dart-define=AI_BASE_URL=' + aiUrl,
  // 📌 刻意**不传** `SEED_DEMO_DATA`：演示种子默认不灌，云端模式的数据由服务端
  //    `seed-demo.mjs` 负责。灌进去等于把演示数据烧进产物。
];

console.log('');
console.log('════ ④b flutter build web（通常一两分钟）════');
console.log('  ' + ['flutter', ...args].join(' '));
console.log('');

const code = await runFlutter(args, childEnv);
if (code !== 0) die('flutter build 失败，退出码 ' + code + '（详情见上面的输出）');
}

/** 产物必须存在 —— 构建成功却找不到产物是「报成功但没东西」的经典形态。 */
if (!existsSync(join(builtDir, 'main.dart.js'))) {
  die(
    '没找到 ' + join(builtDir, 'main.dart.js') +
      (fromDir ? '（--from 指向的目录里没有 main.dart.js）' : '（构建报成功但产物不在）'),
  );
}
console.log('  产物来源：' + builtDir);

// ── ⑤ 整理出发布目录（**不叫 build**）────────────────────────────────
const outDir = resolve(repoRoot, valueOf(argv, '--out') ?? 'site');
if (existsSync(outDir)) rmSync(outDir, { recursive: true, force: true });
cpSync(builtDir, outDir, { recursive: true });

const bundle = readFileSync(join(outDir, 'main.dart.js'), 'utf8');
const mb = (statSync(join(outDir, 'main.dart.js')).size / 1024 / 1024).toFixed(1);

console.log('');
console.log('════ ⑤ 发布目录 ════');
console.log('  ' + outDir + '  （main.dart.js ' + mb + ' MB）');

// ── ⑥ 产物必须指向生产（复用 build-mode 的判据，不重抄一份）────────────
console.log('');
console.log('════ ⑥ 产物模式自检 ════');
const mode = spawnSync(
  process.execPath,
  [join(repoRoot, 'tools', 'build-mode.mjs'), outDir, '--expect', 'cloud', '--host', dataHost],
  { cwd: repoRoot, stdio: 'inherit' },
);
if (mode.status !== 0) {
  die(
    '产物不是云端模式（或模式判不出来）—— **别发布**。\n' +
      '    先看上面 build-mode 的输出：它会把产物里带的地址逐条列出来。',
  );
}

/**
 * ⚠️ 第六条闸门，也是**决定性**的那条：产物里必须字面包含**生产域名**。
 *
 * 为什么不能只靠 `build-mode.mjs` 的 `--expect cloud`：
 *   它的 `isCloud` 判据是「产物里有**任何** `http(s)://主机:端口` 的服务地址」
 *   —— 指向 `127.0.0.1:8788` 的构建**同样满足**（那种产物在本仓语义里叫「服务端模式」，
 *   只是服务端在本机）。所以 `--expect cloud` 会**放行一份连本机的产物**。
 *   `--host` 那一支才是真正的正向判据（`bundle.includes(hostHint)`）。
 *   ⇒ 这里再显式断一次：两个生产域名都得在产物里。
 *     （它和下面的「不许残留本机地址」是**两条**判据：产物可以两条都有。）
 */
const missing = [dataUrl, aiUrl].filter((u) => !bundle.includes(u));
if (missing.length > 0) {
  die(
    '产物里**找不到**这次构建用的地址：' + missing.join('、') + '\n' +
      '    说明 --dart-define 没生效（产物不是这份地址构建出来的）—— **别发布**。',
  );
}
console.log('  ✓ 产物里两个生产地址都在');

/**
 * ⚠️ 第五条闸门：本机地址一个都不许残留。
 * `build-mode.mjs` 判的是「**有没有**服务端地址」，这里判的是「**有没有**调试地址」——
 * 两件事，一个成立不代表另一个不成立（产物里可以两条都有）。
 */
const leaked = ['127.0.0.1:8788', 'localhost:8788', '127.0.0.1:8787', 'localhost:8787']
  .filter((s) => bundle.includes(s));
if (leaked.length > 0) {
  die('产物里仍残留本机地址：' + leaked.join('、') + '\n    这份发出去就是「点了没反应」。');
}
console.log('  ✓ 产物里没有本机地址残留');

console.log('');
console.log('════ 完成 ════');
console.log('  发布目录：' + outDir);
console.log('  连的服务：' + dataUrl);
console.log('           ' + aiUrl);
console.log('');
console.log('下一步：把 `' + outDir + '` 交给发布流程（或让助手发布）。');
console.log('⚠️ 发布后**必须**真浏览器验一遍：登录 / 注册 / 拍照各一次 ——');
console.log('   「能打开首页」只证明静态文件在，不证明它连得上后端。');
console.log('');
console.log('日志已写入：' + logPath + '（UTF-8）');
