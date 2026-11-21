#!/usr/bin/env node
/**
 * 应用身份一致性判据（发布门槛之一，见 `doc/release-guide.md` §1）。
 *
 * ## 为什么需要它
 *
 * 「应用身份」这一个语义，在真实工程里**必然**散落在六七个文件里：
 * Android 的 `applicationId` 与 `namespace`、Kotlin 的包路径与 `package` 声明、
 * `AndroidManifest` 的应用名、iOS 的 `PRODUCT_BUNDLE_IDENTIFIER` 与 `CFBundleDisplayName`、
 * web 的 `manifest.json` 与 `index.html`。
 *
 * 这些地方**没有任何编译器或构建**会把它们串起来 —— 改了五处漏掉第六处，
 * 构建照样成功，症状是「某个平台上的名字/身份还是旧的」，而且往往要等到
 * 上架被拒、或者用户装不上覆盖包时才发现（因为**换 applicationId = 换一个应用**，
 * 装过旧包的手机必须卸载重装、数据一起没）。
 *
 * 所以这里把 `app-identity.json` 当作**声明**，逐处核对实际值；
 * 顺带拒收 Flutter 模板的占位值（`com.example.*` 上不了任何应用商店）。
 *
 * 用法：
 *   node tools/app-identity.mjs              核对身份一致性
 *   node tools/app-identity.mjs --release    额外要求发布签名已配置（上架前的自检）
 *
 * 只在**不一致**时退出码非 0 —— 这是给人看的判据，不是给 CI 猜的。
 */
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => readFileSync(join(repoRoot, p), 'utf8');

const want = JSON.parse(read('app-identity.json'));
const ID = want.applicationId;
const NAME = want.displayName;

/** Flutter 模板原样留下的值。出现任何一个都说明「某处没改到」。 */
const TEMPLATE = [
  'com.example',
  'easy_learn_app',
  'easyLearnApp',
  'Easy Learn App',
  'A new Flutter project.',
];

const problems = [];
const notes = [];
const ok = [];

/** 记一条核对结果。`actual` 与期望不符时进 problems。 */
function expect(where, actual, expected, hint) {
  const value = (actual ?? '').trim();
  if (value === expected) {
    ok.push(`${where} = ${value}`);
    return;
  }
  problems.push(
    `${where}\n     期望: ${expected}\n     实际: ${value || '(没读到)'}`
      + (hint ? `\n     ${hint}` : ''),
  );
}

/** 检查一段文本里有没有模板占位值（不拦的话，名字改了但某处忘了）。 */
function templateGuard(where, text) {
  const hit = TEMPLATE.filter((t) => text.includes(t));
  if (hit.length > 0) {
    problems.push(`${where} 里仍有模板占位值：${hit.join(' / ')}`);
  }
}

// ===== 1. Android：Gradle 里的 namespace / applicationId =====
const gradlePath = 'android/app/build.gradle.kts';
const gradle = read(gradlePath);
{
  const ns = gradle.match(/namespace\s*=\s*"([^"]+)"/)?.[1];
  const appId = gradle.match(/applicationId\s*=\s*"([^"]+)"/)?.[1];
  expect(`${gradlePath} 的 namespace`, ns, ID);
  expect(`${gradlePath} 的 applicationId`, appId, ID,
    'applicationId 是应用身份，上架后不能改（改了商店不认、旧版装不上升级包）');
  templateGuard(gradlePath, gradle.replace(/^import .*$/gm, ''));
}

// ===== 2. Android：Kotlin 的包路径与 package 声明 =====
// 光看 namespace 不够：`namespace` 声明在 Gradle 里，而 MainActivity 的真实包路径
// 是**目录结构**（com/example/xxx → 现在应当是 cn/easylearn/app）。
// 两者不一致时，Android 侧会在运行期找不到 Activity —— 这是最常见的「改了一半」。
{
  const kotlinRoot = 'android/app/src/main/kotlin';
  // 一律用「正斜杠的仓内相对路径」比较 —— Windows 上 path.join() 给的是反斜杠，
  // 而遍历给出的是另一种写法，两边不归一就会**把正常情况报成「有两个 MainActivity」**
  // （这个判据第一版就是这么自己骗自己的）。repoRoot 也用正斜杠的副本参与比较。
  const root = repoRoot.replace(/\\/g, '/');
  const wantDir = `${kotlinRoot}/${ID.split('.').join('/')}`;
  const wantFile = `${wantDir}/MainActivity.kt`;

  if (!existsSync(join(repoRoot, wantFile))) {
    problems.push(`找不到 ${wantFile} —— Kotlin 包路径必须与 applicationId 对应（目录结构就是包名）`);
  } else {
    const src = read(wantFile);
    const pkg = src.match(/^\s*package\s+([A-Za-z0-9_.]+)/m)?.[1];
    expect(`${wantFile} 的 package`, pkg, ID);
    ok.push(`${wantDir}/ 目录与包名一致`);
  }

  // 反面：别的地方还留着第二个 MainActivity（移动只做了一半）。
  if (existsSync(join(repoRoot, kotlinRoot))) {
    const strays = [];
    const walk = (dir) => {
      for (const e of readdirSync(dir, { withFileTypes: true })) {
        const p = join(dir, e.name);
        if (e.isDirectory()) walk(p);
        else if (
          e.name === 'MainActivity.kt'
          && p.replace(/\\/g, '/').replace(`${root}/`, '') !== wantFile
        ) strays.push(p);
      }
    };
    walk(join(repoRoot, kotlinRoot));
    if (strays.length > 0) {
      problems.push(
        `除 ${wantFile} 之外还有别的 MainActivity.kt：${strays.join('、')}\n`
          + '     （多半是改包名时只复制没删除）',
      );
    }
  }
}

// ===== 3. Android：清单里的应用名 =====
const manifestPath = 'android/app/src/main/AndroidManifest.xml';
{
  const label = read(manifestPath).match(/android:label="([^"]*)"/)?.[1];
  expect(`${manifestPath} 的 android:label`, label, NAME,
    '这是桌面图标下面显示的名字');
}

// ===== 4. iOS：Bundle ID（含 RunnerTests 的后缀）=====
const pbxPath = 'ios/Runner.xcodeproj/project.pbxproj';
{
  const all = [...read(pbxPath).matchAll(/PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);/g)]
    .map((m) => m[1].trim());
  if (all.length === 0) {
    problems.push(`${pbxPath} 里没找到 PRODUCT_BUNDLE_IDENTIFIER —— 解析规则可能过期了，去看一眼`);
  }
  const bad = all.filter((v) => v !== ID && !v.startsWith(`${ID}.`));
  if (bad.length > 0) {
    problems.push(`${pbxPath} 里这些 Bundle ID 不是 ${ID}（或它的子标识）:\n     ${[...new Set(bad)].join('\n     ')}`);
  } else {
    ok.push(`${pbxPath} 的 ${all.length} 处 Bundle ID 都挂在 ${ID} 下`);
  }
}

// ===== 5. iOS：显示名 =====
const plistPath = 'ios/Runner/Info.plist';
{
  const plist = read(plistPath);
  const disp = plist.match(/<key>CFBundleDisplayName<\/key>\s*<string>([^<]*)<\/string>/)?.[1];
  expect(`${plistPath} 的 CFBundleDisplayName`, disp, NAME);
  const short = plist.match(/<key>CFBundleName<\/key>\s*<string>([^<]*)<\/string>/)?.[1];
  expect(`${plistPath} 的 CFBundleName`, short, NAME);
}

// ===== 6. Web：manifest.json =====
const webManifestPath = 'web/manifest.json';
{
  const m = JSON.parse(read(webManifestPath));
  expect(`${webManifestPath} 的 name`, m.name, NAME);
  expect(`${webManifestPath} 的 short_name`, m.short_name, NAME);
}

// ===== 7. Web：index.html 的标题与 iOS 独立模式标题 =====
const indexPath = 'web/index.html';
{
  const html = read(indexPath);
  const title = html.match(/<title>([^<]*)<\/title>/)?.[1];
  expect(`${indexPath} 的 <title>`, title, NAME);
  const appleTitle = html
    .match(/<meta\s+name="apple-mobile-web-app-title"\s+content="([^"]*)"/)?.[1];
  expect(`${indexPath} 的 apple-mobile-web-app-title`, appleTitle, NAME);
}

// ===== 8. pubspec 的描述（模板文案）=====
{
  const desc = read('pubspec.yaml').match(/^description:\s*"?([^"\n]*)"?/m)?.[1];
  templateGuard('pubspec.yaml 的 description', desc ?? '');
}

// ===== 9. 版本号（只报告，不判定）=====
{
  const v = read('pubspec.yaml').match(/^version:\s*(\S+)/m)?.[1];
  notes.push(`版本：${v}（Android versionName/versionCode、iOS CFBundleShortVersionString 都取自这里）`);
}

// ===== 10. 桌面端：**显式不在判据内** =====
// 声明出来，是为了让「这里为什么没查」变成一个决定，而不是一个遗漏。
{
  const desktops = ['linux', 'macos', 'windows'].filter((d) => existsSync(join(repoRoot, d)));
  if (desktops.length > 0) {
    notes.push(
      `未纳入判据：${desktops.join(' / ')}（Flutter 模板残留，不是发布目标；`
        + '里面仍是 easy_learn_app / com.example。真要出桌面版时，先把这几处一起改掉再加进来）',
    );
  }
}

// ===== --release：发布签名的前置条件 =====
const releaseMode = process.argv.includes('--release');
if (releaseMode) {
  const propsPath = 'android/key.properties';
  if (!existsSync(join(repoRoot, propsPath))) {
    problems.push(
      `${propsPath} 不存在 —— release 包会用 **debug key** 签名，不能上架。\n`
        + '     生成：node build/_make-keystore.mjs（或照 doc/release-guide.md §1 用 keytool）',
    );
  } else {
    const props = read(propsPath);
    const storeFile = props.match(/^storeFile=(.+)$/m)?.[1]?.trim();
    const alias = props.match(/^keyAlias=(.+)$/m)?.[1]?.trim();
    const hasPw = /^storePassword=.+$/m.test(props) && /^keyPassword=.+$/m.test(props);
    if (!hasPw) problems.push(`${propsPath} 里 storePassword / keyPassword 是空的`);
    if (!alias) problems.push(`${propsPath} 里没有 keyAlias`);
    if (storeFile) {
      // storeFile 相对 android/app 解析（Gradle 的 file() 在那个模块里求值）。
      const ks = join(repoRoot, 'android', 'app', storeFile);
      if (existsSync(ks)) ok.push(`发布签名已配置（keystore: android/app/${storeFile}, alias: ${alias}）`);
      else {
        problems.push(
          `${propsPath} 指向的 keystore 不存在：android/app/${storeFile}\n`
            + '     注意 storeFile 是**相对 android/app/** 的路径',
        );
      }
    }
  }
}

// ===== 输出 =====
console.log(`应用身份（来源 app-identity.json）`);
console.log(`  applicationId : ${ID}`);
console.log(`  displayName   : ${NAME}`);
if (releaseMode) console.log('  模式          : --release（额外核对发布签名）');
console.log();

if (ok.length > 0) {
  console.log(`✓ 核对通过 ${ok.length} 处`);
  for (const line of ok) console.log(`    ${line}`);
}
for (const n of notes) console.log(`\nℹ️  ${n}`);

if (problems.length > 0) {
  console.log(`\n✗ ${problems.length} 处不一致：\n`);
  problems.forEach((p, i) => console.log(`  ${i + 1}. ${p}\n`));
  console.log('这些地方**没有任何构建**会把它们串起来，所以只能靠这道判据。');
  process.exit(1);
}

console.log('\n✓ 身份一致。');
