// 构建**连本机后台**的 APK：把本机地址在编译期烧进产物。
//
// ## 为什么不能复用 build-cloud-apk.mjs
//
// 那个脚本有三道闸门，方向与本脚本**正好相反**：
//   1. 地址必须像生产地址 —— `127.0.0.1` / 私有网段 / 空值一律拒绝；
//   2. 两个地址必须 https；
//   3. 只认 `.env.prod` 的 `CLIENT_*`。
// 本地包要的恰恰是 `http://192.168.x.x` 或组网地址 `http://100.x.x.x`，
// 所以只能单独一条构建路径，而不是给云包脚本加 `--force`。
//
// ## 为什么还要改 network_security_config.xml
//
// `targetSdk = 36` 下安卓默认**禁止明文 HTTP**，而本项目那份配置
// **只放行 127.0.0.1 / localhost**（为 just_audio 的回环代理加的）。
// 于是 `http://192.168.3.80:8788` 的请求**根本发不出去** ——
// 后端日志一条都没有，界面表现是「一直转圈」。这个坑已经踩过一次（B24 同族）。
//
// 本脚本的做法是：**构建前**把目标地址插进白名单，构建完**无论成败都原样还原**。
// 这样仓库里不会留下某个人的家庭 IP，而产物里该有的放行已经编译进去了。
//
// ## 为什么还要换图标、换应用名、换包名
//
// 云服务版和本机版会**同时装在一台手机上**对比。三样东西必须分开，缺一样就会误判：
//   · **图标**（绿 = 本机 / 蓝 = 云端）：桌面上点错包，然后去查网络，是最贵的绕路；
//   · **应用名**（伴学·本机）：桌面文字是第二道区分；
//   · **包名**（`cn.easylearn.app.local`）：包名相同 = 覆盖安装，云版会被顶掉，
//     而且登录态会串过去（token 还是云端的），排查时根本分不清哪个包在跑。
// 三者都在构建前打补丁、构建后还原，仓库里保持云端版原样。
// 真的想覆盖安装云端包：加 `--same-app`（不推荐，只在你确定要顶掉时用）。
//
// ## 用法
//
// ```bash
// node scripts/tools/build-local-apk.mjs --host 192.168.3.80            # 局域网（在仓库根执行）
// node scripts/tools/build-local-apk.mjs --host 100.88.1.23            # 组网（Tailscale 等）
// node scripts/tools/build-local-apk.mjs --host 192.168.3.80 --dry-run # 只校验，不构建
// node scripts/tools/build-local-apk.mjs --host 192.168.3.80 --out     # 另拷一份到 D:\easy_learn_home\dist
// ```
//
// 可选开关：`--icon none`（不换图标/应用名）· `--same-app`（沿用云版包名）·
//           `--label 伴学·本机`（自定义应用名）· `--no-probe`（跳过探活）
//
// ⚠️ 手机连不连得到，与「包有没有烧对」是两件事：
//    本脚本只能保证**地址烧对了、明文放行了**；网络可达性由 `--probe` 那一步先探。

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  appendFileSync, copyFileSync, existsSync, mkdirSync, readFileSync, statSync, unlinkSync, writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import net from 'node:net';
import { inflateRawSync, inflateSync } from 'node:zlib';

const here = dirname(fileURLToPath(import.meta.url));
// 移交后的布局：本脚本在 `scripts/tools/`，Flutter 项目在 `frontend/`。
// 旧仓是「脚本 tools/ 与 android/ 同级」，所以这里不能再用 `resolve(here, '..')`
// —— 那会指向 scripts/，图标/清单/ Gradle 补丁全部打不到文件，报错还会像「构建失败」。
// 保留 repoRoot 这个名字，是因为脚本下面所有路径（res / manifest / gradle /
// flutter cwd / apk 产物）指的都是**同一个 Flutter 项目根**。
const repoRoot = resolve(here, '..', '..', 'frontend');

const argv = process.argv.slice(2);
const hasFlag = (f) => argv.includes(f);
const opt = (f) => {
  const i = argv.indexOf(f);
  return i >= 0 ? argv[i + 1] : undefined;
};

// `--host` 支持逗号分隔的多个地址：**第一个是首选，其余是备选**。
//
// 典型用法（同一台机器的两条网络路径）：
//   --host 192.168.3.80,100.96.105.11
// 手机在家时走局域网、在外走 Tailscale，由客户端的 EndpointResolver 运行期择优。
//
// ⚠️ 多个地址必须是**同一个后端**（同一份数据库）。给两个不同的服务端，
// 客户端会在它们之间来回切，数据也会分叉。
const hostArg = opt('--host');
const hosts = (hostArg ?? '')
  .split(',')
  .map((h) => h.trim())
  .filter(Boolean);
const host = hosts[0];
const dataPort = opt('--data-port') ?? '8788';
const aiPort = opt('--ai-port') ?? '8787';
const dryRun = hasFlag('--dry-run');
const noProbe = hasFlag('--no-probe');
const copyOut = hasFlag('--out');
const outDir = opt('--out-dir') ?? 'D:/easy_learn_home/dist';

// ── 更新包发布（前台提醒升级用）────────────────────────────────
// `versionCode` 用 epoch 秒：旧包是 1，任何新构建都严格大于它；2038 年前不会溢出 int32。
// 版本名从 pubspec 的 base version 取，附加构建时间戳，用户能看出是哪次编译的。
const updateDir = opt('--update-dir') ?? 'D:/easy_learn_home/app-updates';
const changelog = opt('--changelog') ?? '修复已知问题，优化使用体验';
const publishUpdate = !hasFlag('--no-publish');
const buildNumber = Math.floor(Date.now() / 1000);
const pubspecText = readFileSync(join(repoRoot, 'pubspec.yaml'), 'utf8');
const baseVersion = pubspecText.match(/^version:\s*([0-9]+\.[0-9]+\.[0-9]+)/m)?.[1] ?? '1.0.0';
const stamp = new Date().toISOString().slice(0, 16).replace(/[-:T]/g, '');
const buildName = `${baseVersion}+${stamp}`;

// 图标/标识：默认换成「本机版」那一套（绿图标 + 伴学·本机 + 独立包名）
const iconMode = opt('--icon') ?? 'local'; // local | none
const sameApp = hasFlag('--same-app');
const appLabel = opt('--label') ?? '伴学·本机';
const APP_ID_SUFFIX = '.local';

const RES = join(repoRoot, 'android', 'app', 'src', 'main', 'res');
const XML = join(RES, 'xml', 'network_security_config.xml');
const MANIFEST = join(repoRoot, 'android', 'app', 'src', 'main', 'AndroidManifest.xml');
const GRADLE = join(repoRoot, 'android', 'app', 'build.gradle.kts');
const ICON_FILES = [
  'mipmap-mdpi/ic_launcher.png',
  'mipmap-hdpi/ic_launcher.png',
  'mipmap-xhdpi/ic_launcher.png',
  'mipmap-xxhdpi/ic_launcher.png',
  'mipmap-xxxhdpi/ic_launcher.png',
  'mipmap-mdpi/ic_launcher_foreground.png',
  'mipmap-hdpi/ic_launcher_foreground.png',
  'mipmap-xhdpi/ic_launcher_foreground.png',
  'mipmap-xxhdpi/ic_launcher_foreground.png',
  'mipmap-xxxhdpi/ic_launcher_foreground.png',
  'mipmap-anydpi-v26/ic_launcher.xml',
  'values/colors.xml',
];

const logPath = join(repoRoot, 'build', '_logs', 'build-local-apk.log');
mkdirSync(dirname(logPath), { recursive: true });
writeFileSync(logPath, '');

function say(s) {
  console.log(s);
  try {
    appendFileSync(logPath, s + '\n');
  } catch {
    /* 日志写不进去不该影响构建 */
  }
}
function die(s) {
  say('\n✗ ' + s);
  process.exit(1);
}

// ── ① 参数校验 ────────────────────────────────────────────────────
if (!host) {
  die(
    '缺少 --host。\n' +
      '    局域网：--host 192.168.3.80\n' +
      '    组网：  --host <Tailscale/ZeroTier 分配的地址>\n' +
      '    （地址必须能被手机 ping 到；用 127.0.0.1 构建的包，手机上一定连不上）',
  );
}
for (const h of hosts) {
  const isIp = net.isIP(h) === 4;
  const isHostname = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/i.test(h);
  if (!isIp && !isHostname) die(`--host 里的 "${h}" 既不是合法 IPv4 也不是合法主机名`);
  if (h === '127.0.0.1' || h === 'localhost' || h === '0.0.0.0') {
    die(
      `拒绝 ${h}：手机上的 127.0.0.1 是**手机自己**，连不到这台电脑。\n` +
        '    要手机能连，必须用这台电脑在手机可达网络里的地址。',
    );
  }
}
if (new Set(hosts).size !== hosts.length) {
  die('--host 里有重复地址：' + hosts.join(', '));
}

const dataUrl = `http://${host}:${dataPort}`;
const aiUrl = `http://${host}:${aiPort}`;

// 备选（第一个之后的全部）。
const fallbackDataUrls = hosts.slice(1).map((h) => `http://${h}:${dataPort}`);
const fallbackAiUrls = hosts.slice(1).map((h) => `http://${h}:${aiPort}`);

// 实例标识：客户端拿它判断「这个地址上那台是不是我的机器」。
// 与 `config/local.env`、`config/ai.env` 里的 `SERVER_INSTANCE_ID` 必须一致。
const instanceId = (opt('--instance-id') ?? process.env.SERVER_INSTANCE_ID ?? '').trim();

say('════ 本地包构建 ════');
say('  数据服务：' + dataUrl + (fallbackDataUrls.length ? '（备选 ' + fallbackDataUrls.join(' / ') + '）' : ''));
say('  AI 网关： ' + aiUrl + (fallbackAiUrls.length ? '（备选 ' + fallbackAiUrls.join(' / ') + '）' : ''));
say('  实例标识：' + (instanceId || '（未配置）'));
if (hosts.length > 1 && !instanceId) {
  say('');
  say('  ⚠️ 配了多个地址却没有实例标识 —— 撞车保护是关的。');
  say('     别人家同一网段上的另一台服务同样会回 200，客户端分不出来。');
  say('     建议加 --instance-id <与服务器 SERVER_INSTANCE_ID 相同的值>。');
}
say('  产物日志：' + logPath);

// ── ② 临时补丁：先备份，退出时无条件还原 ──────────────────────────
//
// 备份存的是**原始字节**而不是「改过的文本」：图标是 PNG（二进制）、manifest 是
// UTF-8、gradle 是 kts —— 统一按 Buffer 存取，才不会在还原时悄悄改掉换行或编码。
const backups = new Map();
function backup(abs) {
  if (!backups.has(abs)) backups.set(abs, readFileSync(abs));
}

let restored = false;
function restoreAll() {
  if (restored) return;
  restored = true;
  let bad = 0;
  for (const [abs, buf] of backups) {
    try {
      writeFileSync(abs, buf);
      if (!readFileSync(abs).equals(buf)) {
        bad += 1;
        say('  ⚠️ 还原后与原文不一致：' + abs);
      }
    } catch (e) {
      bad += 1;
      say('  ⚠️ 还原失败：' + abs + ' ' + e.message);
    }
  }
  if (backups.size === 0) return;
  say(
    bad === 0
      ? `  ✓ 已还原 ${backups.size} 个文件（仓库不留构建机痕迹）`
      : `  ⚠️ ${bad} 个文件还原异常，请用 git status / git checkout 检查`,
  );
}
process.on('exit', restoreAll);
process.on('SIGINT', () => {
  restoreAll();
  process.exit(130);
});

const originalXml = readFileSync(XML, 'utf8');

const hasDomain = (xml, h) =>
  new RegExp(`<domain[^>]*>\\s*${h.replace(/\./g, '\\.')}\\s*</domain>`).test(xml);

// 每个 host 都要放行 —— 少放行一个，那个候选地址在手机上**根本发不出请求**，
// 表现是「备用地址永远探测失败」，而日志里只有一条超时。
const missingHosts = hosts.filter((h) => !hasDomain(originalXml, h));
const alreadyAllowed = missingHosts.length === 0;

function patchXml() {
  if (alreadyAllowed) return originalXml;
  const marker = '</domain-config>';
  const at = originalXml.lastIndexOf(marker);
  if (at < 0) die('network_security_config.xml 里找不到 </domain-config>，补丁位置不明，停止');
  const entry =
    `        <!-- 本机后台（构建工具自动插入，构建后还原） -->\n` +
    missingHosts
      .map((h) => `        <domain includeSubdomains="false">${h}</domain>`)
      .join('\n') +
    `\n    `;
  return originalXml.slice(0, at) + entry + originalXml.slice(at);
}

say('');
say('════ ① 明文 HTTP 放行 ════');
if (alreadyAllowed) {
  say(`  ✓ 白名单里已有 ${hosts.join(' / ')}，无需修改`);
} else {
  backup(XML);
  const patched = patchXml();
  writeFileSync(XML, patched, 'utf8');
  for (const h of missingHosts) {
    if (!patched.includes(`>${h}</domain>`)) {
      die('补丁写入后校验失败：XML 里没有出现 ' + h);
    }
  }
  say(`  ✓ 已临时加入 ${missingHosts.join(' / ')}（构建结束会还原）`);
}

// ── ③ 可达性预检 ──────────────────────────────────────────────────
async function probe(label, url) {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(6000) });
    const body = await r.text();
    if (!r.ok) return { ok: false, why: `HTTP ${r.status} ${body.slice(0, 100)}` };
    return { ok: true, why: body.replace(/\s+/g, ' ').slice(0, 90) };
  } catch (e) {
    return { ok: false, why: `${e.name} ${e.message}` };
  }
}

if (!noProbe) {
  say('');
  say('════ ② 从这台机器探活（不代表手机能连）════');
  for (const [label, url] of [['数据服务', `${dataUrl}/health`], ['AI 网关', `${aiUrl}/ai/health`]]) {
    const r = await probe(label, url);
    say(`  ${r.ok ? '✓' : '✗'} ${label}  ${url}  ${r.why}`);
    if (!r.ok) {
      die(
        `${label} 从本机都探不通，先别构建。\n` +
          '    常见原因：服务没起 / 只绑了 127.0.0.1（要 BIND_HOST=0.0.0.0）/ 端口不对。\n' +
          '    真要跳过预检：加 --no-probe',
      );
    }
  }
}

// ── ③ 图标 / 应用名 / 包名（本机版专属，构建后还原）────────────────
say('');
say('════ ③ 应用标识 ════');

const identity = { palette: null, appId: null, label: null };

if (iconMode === 'none') {
  say('  · 跳过（--icon none）：沿用云版图标与应用名');
} else {
  // 图标：调用既有的图标生成器，只是换成 `local` 配色。
  // ⚠️ 它写的就是仓库里的文件，所以必须先把原始字节收进备份池。
  for (const rel of ICON_FILES) backup(join(RES, rel));
  const gen = await new Promise((res) => {
    const p = spawn(
      process.execPath,
      [join(here, 'make-app-icon.mjs'), '--palette', iconMode, '--android-only'],
      { cwd: repoRoot, stdio: 'inherit' },
    );
    p.on('error', (e) => die('图标生成失败：' + (e?.message ?? e)));
    p.on('close', res);
  });
  if (gen !== 0) die('图标生成脚本退出码 ' + gen);

  // 判据：生成后**主色确实是绿的**。
  //
  // ⚠️ 原来这里还有一条「生成前后字节必须不同」。它看着更严格，其实是个弱判据：
  //    2026-10-21 一次构建被中途杀掉，仓库里留下了本机版（绿色）图标，
  //    于是下一次构建「生成前=绿、生成后=绿」→ 字节没变 → 误报「配色没生效」。
  //    真正要证明的是**结论**（绿），不是**过程**（有没有写过文件）。
  const mdpi = readFileSync(join(RES, 'mipmap-mdpi/ic_launcher.png'));
  const px = pngSample(mdpi);
  if (!px || !(px.g > px.r + 24 && px.g > px.b + 16)) {
    die(
      `图标主色不是绿色系（${px ? `采样 rgb=${px.r},${px.g},${px.b}` : '采样失败'}），配色没生效`,
    );
  }
  identity.palette = iconMode;
  say(`  ✓ 图标：${iconMode} 配色（采样 rgb=${px.r},${px.g},${px.b}）`);

  // 应用名：桌面文字是第二道区分。
  if (appLabel) {
    backup(MANIFEST);
    const src = readFileSync(MANIFEST, 'utf8');
    if (!/android:label="[^"]*"/.test(src)) die('AndroidManifest.xml 里找不到 android:label');
    writeFileSync(MANIFEST, src.replace(/android:label="[^"]*"/, `android:label="${appLabel}"`), 'utf8');
    const check = readFileSync(MANIFEST, 'utf8').includes(`android:label="${appLabel}"`);
    if (!check) die('应用名补丁写入后校验失败');
    identity.label = appLabel;
    say(`  ✓ 应用名：${appLabel}`);
  }
}

// 包名：独立 applicationId 才能与云版并存。同名 = 覆盖安装，云版会被顶掉。
if (!sameApp) {
  backup(GRADLE);
  const src = readFileSync(GRADLE, 'utf8');
  const m = /applicationId\s*=\s*"([^"]+)"/.exec(src);
  if (!m) die('build.gradle.kts 里找不到 applicationId，包名补丁位置不明');
  const appId = m[1].endsWith(APP_ID_SUFFIX) ? m[1] : m[1] + APP_ID_SUFFIX;
  writeFileSync(GRADLE, src.replace(m[0], `applicationId = "${appId}"`), 'utf8');
  if (!readFileSync(GRADLE, 'utf8').includes(`applicationId = "${appId}"`)) {
    die('包名补丁写入后校验失败');
  }
  identity.appId = appId;
  say(`  ✓ 包名：${appId}（可与云版并存）`);
} else {
  say('  ⚠️ --same-app：沿用云版包名，安装会**顶掉**云版并继承它的登录态');
}

// ── ④ flutter 构建 ────────────────────────────────────────────────
if (dryRun) {
  say('');
  say('════ --dry-run：跳过 flutter ════');
  say('  将要执行的参数：');
  say(
    '    flutter build apk --release --no-tree-shake-icons --no-pub ' +
      `--dart-define=DATA_API_BASE_URL=${dataUrl} ` +
      `--dart-define=DATA_API_FALLBACK_URLS=${fallbackDataUrls.join(',')} ` +
      `--dart-define=AI_BASE_URL=${aiUrl} ` +
      `--dart-define=AI_FALLBACK_URLS=${fallbackAiUrls.join(',')} ` +
      `--dart-define=SERVER_INSTANCE_ID=${instanceId} ` +
      `--build-number=${buildNumber} --build-name=${buildName} ` +
      `--dart-define=APP_VERSION_CODE=${buildNumber} --dart-define=APP_VERSION_NAME=${buildName}`,
  );
  say(`  应用标识：${JSON.stringify(identity)}`);
  restoreAll();
  say('\n✓ 校验通过（未构建）');
  process.exit(0);
}

const childEnv = { ...process.env };
for (const k of ['HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy', 'ALL_PROXY', 'all_proxy']) {
  delete childEnv[k];
}

function runFlutter(args) {
  return new Promise((res) => {
    const p = spawn('flutter', args, { cwd: repoRoot, env: childEnv, stdio: 'inherit', shell: true });
    p.on('error', (e) => die('起不了 flutter：' + (e?.message ?? e)));
    p.on('close', res);
  });
}

say('');
say('════ ④ 离线解析依赖 ════');
const pubCode = await runFlutter(['pub', 'get', '--offline']);
if (pubCode !== 0) {
  die(
    '离线解析依赖失败。本机 pub cache 不全 —— 请在前台执行 flutter pub get（别放后台）。',
  );
}
say('  ✓ 依赖齐全');

const args = [
  'build', 'apk', '--release',
  '--no-tree-shake-icons',
  '--no-pub',
  '--dart-define=DATA_API_BASE_URL=' + dataUrl,
  // 备选地址：同一后端的另一条网络路径。为空时客户端解析成空列表 = 不探测。
  '--dart-define=DATA_API_FALLBACK_URLS=' + fallbackDataUrls.join(','),
  '--dart-define=AI_BASE_URL=' + aiUrl,
  '--dart-define=AI_FALLBACK_URLS=' + fallbackAiUrls.join(','),
  // 探测时用它排除「同网段的另一台机器」。
  '--dart-define=SERVER_INSTANCE_ID=' + instanceId,
  // 版本号：pubspec 里写死 1.0.0+1 会让所有历史包 versionCode 都是 1，
  // 前台无从判断「已装的是不是旧版」。构建号与 dart-define 双写：
  // 前者进 AndroidManifest，后者给 Dart 侧读来比对清单。
  '--build-number=' + buildNumber,
  '--build-name=' + buildName,
  '--dart-define=APP_VERSION_CODE=' + buildNumber,
  '--dart-define=APP_VERSION_NAME=' + buildName,
];

say('');
say('════ ⑤ flutter build apk ════');
say('  flutter ' + args.join(' '));
const code = await runFlutter(args);
if (code !== 0) {
  restoreAll();
  die('flutter build 失败，退出码 ' + code);
}

// ── ⑥ 产物 ────────────────────────────────────────────────────────
const apk = join(repoRoot, 'build', 'app', 'outputs', 'flutter-apk', 'app-release.apk');
if (!existsSync(apk)) die('构建报成功但没找到 ' + apk);

const bytes = statSync(apk).size;
const apkBuf = readFileSync(apk);
const sha = createHash('sha256').update(apkBuf).digest('hex');

// 判据：**包里**那张图标得是绿的。
// 只验仓库里的 PNG 不够 —— 资源合并/缓存都可能让 APK 沿用上一版的图标，
// 而那种失败是安静的：装上去才发现「两个 App 长得一样」。
let pkgIcon = null;
if (iconMode !== 'none') {
  // ⚠️ **不能按文件名找图标**：AGP 开启资源路径缩短后，`res/mipmap-xxxhdpi-v4/ic_launcher.png`
  //    在包里叫 `res/o-.png`。第一版判据按名字找，构建明明成功了却报「找不到图标」——
  //    这不是图标没进包，是**判据写错了**（本项目栽过多次的那类）。
  //    改成按 PNG 自身尺寸识别：48/72/96/144/192 就是五个密度的传统启动图标。
  const LAUNCH_SIZES = new Set([48, 72, 96, 144, 192]);
  const sampled = zipPngs(apkBuf)
    .map((e) => ({ name: e.name, s: pngSample(e.data) }))
    .filter((x) => x.s && x.s.alpha > 0 && LAUNCH_SIZES.has(x.s.w) && x.s.w === x.s.h);
  const greens = sampled.filter((x) => x.s.g > x.s.r + 24 && x.s.g > x.s.b + 16);
  // 前景层是白书 + 透明底，采样必为透明 —— 所以只统计「不透明」的那几张（legacy 图标）。
  // 正常情况是 5 张（48/72/96/144/192）；要求 ≥2 已足以证明这一批图进了包。
  if (greens.length < 2) {
    die(
      `APK 里的启动图标不是本机配色（绿色 ${greens.length}/${sampled.length} 张）—— 图标没进包。\n` +
        sampled.map((x) => `    ${x.name} ${x.s.w}×${x.s.h} rgb=${x.s.r},${x.s.g},${x.s.b}`).join('\n'),
    );
  }
  const best = greens.find((x) => x.s.w === 192) ?? greens[greens.length - 1];
  pkgIcon = {
    entry: best.name,
    rgb: `${best.s.r},${best.s.g},${best.s.b}`,
    count: greens.length,
    total: sampled.length,
  };
}

restoreAll();
say('');
say('════ ⑥ 产物 ════');
say('  ' + apk);
say('  大小：' + (bytes / 1024 / 1024).toFixed(1) + ' MB');
say('  sha256：' + sha);
say('  连的服务：' + dataUrl + '  /  ' + aiUrl);
if (pkgIcon) say(`  图标：${pkgIcon.count}/${pkgIcon.total} 张启动图标为绿色系（${pkgIcon.entry} 采样 rgb=${pkgIcon.rgb}）✓`);
if (identity.appId) say('  包名：' + identity.appId + '（与云版共存，不会顶掉它）');
if (identity.label) say('  应用名：' + identity.label);

if (copyOut) {
  mkdirSync(outDir, { recursive: true });
  const dest = join(outDir, `easy-learn-local-${host}-${stamp}.apk`);
  copyFileSync(apk, dest);
  say('  已另存：' + dest);
}

// ── ⑦ 发布更新包 ────────────────────────────────────────────────
// 清单先写临时文件，再一次性 copyFileSync 覆盖：服务端 readFileSync 是整读，
// 直接 writeFileSync 同一个文件会先截断再写，恰在那一瞬检查的客户端会拿到半截 JSON。
if (publishUpdate) {
  mkdirSync(updateDir, { recursive: true });
  const fileName = `easy-learn-local-${host}-${stamp}.apk`;
  copyFileSync(apk, join(updateDir, fileName));
  const manifest = {
    versionCode: buildNumber,
    versionName: buildName,
    changelog,
    fileName,
    size: bytes,
    sha256: sha,
    publishedAt: new Date().toISOString(),
  };
  const manifestPath = join(updateDir, 'manifest.json');
  const tmpManifest = join(updateDir, `manifest.json.tmp-${process.pid}`);
  writeFileSync(tmpManifest, JSON.stringify(manifest, null, 2));
  // Windows 上 copyFileSync 覆盖已存在的目标是支持的（不加 COPYFILE_EXCL）。
  try { copyFileSync(tmpManifest, manifestPath); } finally { unlinkSync(tmpManifest); }
  say(`  更新包已发布：${join(updateDir, fileName)}`);
  say(`  更新清单：${manifestPath}（versionCode=${buildNumber}）`);
}

say('\n⚠️ 装到手机后：手机必须和这台电脑在同一个可达网络里（同一 WiFi，或组网工具已连接）。');

// ── 辅助：从 APK 里取出所有 PNG 并采样一个像素 ────────────────────
//
// 为什么不用 `unzip` / `aapt`：这个脚本要在 PowerShell 与 Git Bash 下都能跑，
// 而 APK 就是个 zip —— 自己读中央目录反而更可靠（项目里 apk-contains.mjs 同思路）。
function zipPngs(zip) {
  let eocd = -1;
  const floor = Math.max(0, zip.length - 22 - 0xffff);
  for (let i = zip.length - 22; i >= floor; i -= 1) {
    if (zip.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('这不是一个 zip（找不到 EOCD）');
  const count = zip.readUInt16LE(eocd + 10);
  let p = zip.readUInt32LE(eocd + 16);
  const out = [];
  for (let n = 0; n < count; n += 1) {
    if (zip.readUInt32LE(p) !== 0x02014b50) throw new Error('中央目录损坏');
    const method = zip.readUInt16LE(p + 10);
    const compSize = zip.readUInt32LE(p + 20);
    const nameLen = zip.readUInt16LE(p + 28);
    const extraLen = zip.readUInt16LE(p + 30);
    const commentLen = zip.readUInt16LE(p + 32);
    const localOff = zip.readUInt32LE(p + 42);
    const name = zip.toString('utf8', p + 46, p + 46 + nameLen);
    if (name.endsWith('.png')) {
      const start =
        localOff + 30 + zip.readUInt16LE(localOff + 26) + zip.readUInt16LE(localOff + 28);
      const raw = zip.subarray(start, start + compSize);
      out.push({ name, data: method === 0 ? raw : inflateRawSync(raw) });
    }
    p += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

/**
 * 取 PNG **第一行最右侧**那个像素，返回 `{w, h, r, g, b, alpha}`。
 *
 * 为什么不取左上角：圆角图标的左上角是抗锯齿边缘，颜色会被背景稀释。
 * 为什么是第一行：只需解 filter，不必处理整张图的逐行预测。
 *
 * 为什么要支持调色板（colorType=3）：AGP 会把大尺寸图标重新量化成 indexed PNG
 * （192×192 从 RGBA 变成 256 色调色板）。只认 RGBA 的话，最大的那张会被误判成
 * 「读不出来」，进而让人以为图标没进包。
 */
function pngSample(buf) {
  if (buf.length < 24 || buf.readUInt32BE(0) !== 0x89504e47) return null;
  let w = 0;
  let h = 0;
  let bitDepth = 0;
  let colorType = 0;
  let plte = null;
  let trns = null;
  const idat = [];
  let p = 8;
  while (p + 12 <= buf.length) {
    const len = buf.readUInt32BE(p);
    const type = buf.toString('ascii', p + 4, p + 8);
    const data = buf.subarray(p + 8, p + 8 + len);
    if (type === 'IHDR') {
      w = data.readUInt32BE(0);
      h = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
    } else if (type === 'PLTE') {
      plte = data;
    } else if (type === 'tRNS') {
      trns = data;
    } else if (type === 'IDAT') {
      idat.push(data);
    } else if (type === 'IEND') {
      break;
    }
    p += 12 + len;
  }
  const bpp = colorType === 6 ? 4 : colorType === 2 ? 3 : colorType === 3 ? 1 : 0;
  if (bitDepth !== 8 || bpp === 0) return null;

  const stride = w * bpp;
  const raw = inflateSync(Buffer.concat(idat));
  const line = Buffer.alloc(stride);
  const filter = raw[0];
  for (let i = 0; i < stride; i += 1) {
    const x = raw[1 + i];
    const a = i >= bpp ? line[i - bpp] : 0; // 第一行：上/左上都是 0
    const v =
      filter === 0 ? x
      : filter === 1 ? x + a
      : filter === 2 ? x
      : filter === 3 ? x + (a >> 1)
      : filter === 4 ? x + a
      : null;
    if (v === null) return null;
    line[i] = v & 0xff;
  }
  const i = (w - 2) * bpp;
  if (colorType === 3) {
    if (!plte) return null;
    const k = line[i];
    return {
      w, h,
      r: plte[k * 3],
      g: plte[k * 3 + 1],
      b: plte[k * 3 + 2],
      alpha: trns && trns[k] !== undefined ? trns[k] : 255,
    };
  }
  return {
    w, h,
    r: line[i],
    g: line[i + 1],
    b: line[i + 2],
    alpha: bpp === 4 ? line[i + 3] : 255,
  };
}
