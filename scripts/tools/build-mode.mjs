// 判定一个**已构建**的 Flutter Web 产物是哪种数据模式，以及演示种子有没有编进去。
//
// ## 为什么需要这条命令
//
// 客户端连哪一份库是**构建期**定的（`--dart-define=DATA_API_BASE_URL`），
// 运行时改不了；而两种模式用的是**两份互不相通的库**。用错模式的现象是
// 「我之前注册的账号说没有注册」—— 看起来像数据丢了，实际是这次打开的客户端
// 在翻另一份库。真去查数据（服务端 PG / 浏览器存储）之前，先确定这一点，
// 能省掉一大圈排查。
//
// ## ⚠️ 判据一律用 ASCII 标识，不要用界面文案
//
// dart2js 会把中文串转义成 `\uXXXX` 写进产物，拿中文 `grep main.dart.js`
// 得到的是**假阴性**。这个坑踩过一次：我当时用「林小宇」判定「演示种子没编进去」，
// 结论是错的；换成 ASCII 的 `hw_001` 才判对。所以这里全部用 ASCII 判据。
//
// ## 用法
//
// ```bash
// node tools/build-mode.mjs                    # 看 build/web
// node tools/build-mode.mjs build/web-local    # 看别的目录
// node tools/build-mode.mjs --expect cloud     # 不是云模式就以退出码 1 结束
// ```
//
// 加 `--expect` 是为了在跑云端走查**之前**自检：走查脚本自己看不到
// `DATA_API_BASE_URL`（它是编译期常量，被折进产物了），用错模式的产物去跑，
// 走查失败在客户端看来和「服务端没起」一模一样。
import { existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..');

const argv = process.argv.slice(2);

/**
 * 参数：`--expect cloud|local` · `--host <地址串>` · 位置参数（产物目录，默认 `build/web`）。
 *
 * ⚠️ 别写成「从 argv 里挑一个不以 `--` 开头的」那种一行版：`--expect` 的**值**
 * 也不以 `--` 开头，会被当成目录。第一版就是那么写的，而且这个 bug 很安静 ——
 * 传了目录却仍去读默认目录，输出看着完全正常（靠反面实验才发现）。
 */
let expect = null;
let hostHint = null;
const rest = [];
for (let i = 0; i < argv.length; i += 1) {
  if (argv[i] === '--expect') {
    expect = argv[(i += 1)];
  } else if (argv[i] === '--host') {
    hostHint = argv[(i += 1)];
  } else {
    rest.push(argv[i]);
  }
}
const webRoot = resolve(repoRoot, rest[0] ?? join('build', 'web'));

const jsPath = join(webRoot, 'main.dart.js');
if (!existsSync(jsPath)) {
  console.error(`✗ 没找到 ${jsPath}`);
  console.error('  先构建：flutter build web --release --no-tree-shake-icons \\');
  console.error('            --dart-define=DATA_API_BASE_URL=http://127.0.0.1:8788 \\');
  console.error('            --dart-define=AI_BASE_URL=http://127.0.0.1:8787');
  process.exit(1);
}

const bundle = readFileSync(jsPath, 'utf8');
const sizeMB = (statSync(jsPath).size / 1024 / 1024).toFixed(1);
const builtAt = statSync(jsPath).mtime.toLocaleString('zh-CN');

/**
 * 产物里的服务地址字面量。
 *
 * `DATA_API_BASE_URL` / `AI_BASE_URL` 都是编译期常量，dart2js 会把取到的值
 * 直接折进产物 —— 所以「产物里有没有地址」就是「构建时带没带参数」。
 * 反过来，**不带参数时那两个常量是空串**，产物里一个地址都不会有。
 *
 * 同时认 IP:端口与域名两种写法：本机开发是 `127.0.0.1:8788`，
 * 以后指到真域名时这条判据不用改。
 */
/**
 * 产物里的**业务地址**字面量：`http(s)://主机:端口`。
 *
 * 三个条件缺一不可 —— 每一个都是被反面实验逼出来的：
 *
 * 1. **必须带 `http://` / `https://` 前缀**。只看「主机:端口」这个形状，
 *    会把 `iso_646.irv:1991`（IANA 字符集名，混在编码表里）和版本号之类的
 *    `1.2:20` 一起收进来，于是**连本地模式的产物都判成云端**。
 * 2. **必须带端口**。dart2js 产物里本来就混着一批框架自带的地址
 *    （`https://flutter.dev`、`https://pub.dev`、`https://www.gstatic.com`…），
 *    不排掉它们，判据同样恒真。
 * 3. `DATA_API_BASE_URL` / `AI_BASE_URL` 的取值正好满足前两条
 *    （本机是 `http://127.0.0.1:8788`）。
 *
 * 副作用：真部署成 `https://api.example.com`（默认 443、不写端口）时这里会判成
 * 本地 —— 那种情况用 `--host api.example.com` 显式给地址兜底。
 */
const endpoints = [...new Set(bundle.match(/https?:\/\/[\w-]+(?:\.[\w-]+)*:\d{2,5}/g) ?? [])];

/**
 * 无端口的 `https://` 域名 —— 上面那条判据**看不见**它们，这是**假阴性**的来源。
 *
 * ⚠️ 不是假想：**阿里云函数计算给的域名就没有端口**
 * （`https://xxx.cn-hangzhou.fcapp.run`）。真部署到这种地址时 `endpoints` 是空的
 * → 产物被判成「本地模式」→ 人会跑去查浏览器存储 / `easy_learn_v2.db`，**方向全错**。
 *
 * 但**不能**直接拿它当判据：dart2js 产物里本来就混着一批框架自带的域名，
 * 那样会**恒真**（连本地模式都判成云端）。所以只当**警告**用 ——
 * 排除掉已知框架域名之后还有剩的，才提示「可能是这种情况」。
 */
const FRAMEWORK_HOSTS = [
  'flutter.dev', 'pub.dev', 'dart.dev', 'gstatic.com', 'googleapis.com',
  'google.com', 'w3.org', 'github.com', 'githubusercontent.com',
  'apple.com', 'mozilla.org', 'whatwg.org', 'ietf.org', 'unicode.org',
  'apache.org', 'json-schema.org', 'android.com', 'opensource.org',
];
const bareHosts = [...new Set(bundle.match(/https:\/\/[\w-]+(?:\.[\w-]+)+(?![:\w])/g) ?? [])]
  .filter((u) => !endpoints.some((e) => e.startsWith(u)))
  .filter((u) => {
    const h = u.replace(/^https:\/\//, '').toLowerCase();
    return !FRAMEWORK_HOSTS.some((f) => h === f || h.endsWith('.' + f));
  });

const byHint = hostHint ? bundle.includes(hostHint) : false;
const isCloud = endpoints.length > 0 || byHint;

/**
 * 演示种子有没有编进去 —— 用 ASCII 的作业 id 判。
 *
 * 只在**本地模式**下才有意义：那种模式首屏的数据就来自它，
 * 漏了 `SEED_DEMO_DATA=true` 的表现是「列表是空的」，而不是数据坏了。
 * 云端模式的数据由服务端 `seed-demo.mjs` 灌，这里编不编入都无所谓。
 */
const seeded = bundle.includes('hw_001');
const LOCAL_DB = bundle.includes('easy_learn_v2.db');

console.log(`产物：${jsPath}`);
console.log(`      ${sizeMB} MB · 构建于 ${builtAt}`);
console.log('');
console.log(`模式：${isCloud ? '云端' : '本地'}`);
if (isCloud) {
  const shown = endpoints.length > 0 ? endpoints.join('、') : `（由 --host ${hostHint} 命中）`;
  console.log(`      产物里带了服务地址：${shown}`);
  console.log('      账号与业务数据在**服务端**（PostgreSQL）。');
  console.log(`演示种子：${seeded ? '编进去了（云端模式下用不到，数据由服务端 seed-demo.mjs 灌）' : '未编入（云端模式正常）'}`);
  console.log('');
  console.log('找不到账号时先查服务端那份库：');
  console.log('      服务端必须起着：cd serverless/data-service && npm run dev:stack');
  console.log('      再看有哪些账号：cd serverless/data-service && npm run accounts');
} else {
  console.log('      产物里一个服务地址都没有 → 构建时没带 DATA_API_BASE_URL。');
  console.log(`      账号与业务数据在**这台设备上**${LOCAL_DB ? '（原生端写 easy_learn_v2.db）' : '（Web 端写浏览器存储）'}。`);
  console.log(`演示种子：${seeded ? '编进去了 —— 首屏会有演示数据（林小宇等）' : '没编入 —— 首屏会是空的，这是漏了 --dart-define=SEED_DEMO_DATA=true'}`);
  console.log('');
  console.log('⚠️ 这份产物看不到服务端注册的账号，反之亦然 —— 两份库从不同步。');
  console.log('   要连本机服务请重新构建：flutter build web --release --no-tree-shake-icons \\');
  console.log('     --dart-define=DATA_API_BASE_URL=http://127.0.0.1:8788 \\');
  console.log('     --dart-define=AI_BASE_URL=http://127.0.0.1:8787');

  // ⚠️ 「判成本地」这个结论有可能是假的 —— 见 bareHosts 的注释。
  if (bareHosts.length > 0) {
    console.log('');
    console.log('⚠️ 但产物里还有**不带端口**的 https 域名，上面那条判据看不见它们：');
    for (const u of bareHosts.slice(0, 8)) console.log(`      ${u}`);
    console.log('   若其中一条就是你的服务地址（函数计算给的域名就长这样），');
    console.log('   那这次其实是**云端模式**，用 --host 显式确认：');
    console.log('      node tools/build-mode.mjs --expect cloud --host <你的域名>');
  }
}

if (expect) {
  const actual = isCloud ? 'cloud' : 'local';
  if (actual !== expect) {
    console.error('');
    console.error(`✗ 期望 ${expect} 模式，实际是 ${actual} 模式`);
    process.exit(1);
  }
  console.log('');
  console.log(`✓ 模式与期望一致（${expect}）`);
}
