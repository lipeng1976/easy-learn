// 配额位置清单 + 「注释里的默认值写错了吗」检查。
//
// ⚠️ **只读**，一个文件都不写。
// 用法：
//   npm run quota:where            # 打印完整清单（改配额前看这个）
//   npm run quota:where -- --quiet # 只报结论，供 npm test 用（一致时静默）
//
// ── 这个脚本存在的理由 ────────────────────────────────────────────────
// 「配额」在**运行时**其实是单点配置：环境变量 `IMAGE_QUOTA_PER_STUDENT`，
// 改一处、不用改代码、不用重新构建。但仓库里还有几类**必须跟着改**的副本：
//   · 测试断言 —— **故意的重复**。断言若 import 常量，常量改错它也绿
//   · 部署清单里的那份默认值
//   · 文档与注释里写的具体数字
//
// 这几类副本**没有任何东西在盯**。实证：配额从 10000 下调到 3000 时，
// `scripts/run-tests.mjs` 的注释漏了，写着旧值而代码早已是 3000 ——
// 全部测试仍然绿，因为**没有一条判据读注释**。
//
// 所以它做两件事：
//   ① 把位置摆出来（改之前跑一次，就知道该动哪几处）
//   ② 检查「写了『默认 N』的地方，N 是否等于真值」—— 不一致就 exit 1
//
// ⚠️ 它自己**不写死任何数字** —— 真值从 `image-store-factory.js` import 进来，
// 否则这个脚本自己就成了又一份会漂的副本。
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  DEFAULT_QUOTA_PER_STUDENT,
  DEFAULT_QUOTA_WARN_REMAINING,
} from '../src/image-store-factory.js';

/** `--quiet` 时只报结论 —— 否则 100+ 行清单会把测试日志刷满。 */
const QUIET = process.argv.includes('--quiet');
const out = QUIET ? () => {} : (...a) => console.log(...a);

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, '../../..');
const SELF = path.relative(REPO_ROOT, fileURLToPath(import.meta.url)).replace(/\\/g, '/');

/** 只扫这些扩展名 —— 配额不会写在图片或数据库页里。 */
const EXT = new Set(['.js', '.mjs', '.cjs', '.dart', '.md', '.json', '.yaml', '.yml', '.sh', '.ps1']);

/** 不进这些目录：依赖、产物、平台脚手架、本机数据库目录。 */
const SKIP_DIRS = new Set([
  'node_modules', '.git', '.dart_tool', '.idea', '.vscode', 'coverage',
  'build', 'dist', '.pgdata-dev', '.pgdata-test', '.workbuddy', '.serena',
]);

/** 这些文件里必然有海量无关数字（依赖树、生成物），不扫。 */
const SKIP_FILES = new Set(['package-lock.json']);

/** 「配置名」—— 改配额时，任何提到它的地方都值得看一眼。 */
const KEYWORDS = [
  'IMAGE_QUOTA_PER_STUDENT',
  'IMAGE_QUOTA_WARN_REMAINING',
  'DEFAULT_QUOTA_PER_STUDENT',
  'DEFAULT_QUOTA_WARN_REMAINING',
];

/** 配置名 → 当前真值（从定义处 import，不手抄）。 */
const QUOTA = String(DEFAULT_QUOTA_PER_STUDENT);
const WARN = String(DEFAULT_QUOTA_WARN_REMAINING);
const VALUES = new Map([[QUOTA, '配额'], [WARN, '提示阈值']]);

/** 配置名 → 它对应的真值。用来在本行内判断「说的是哪一个」。 */
const NAME_VALUE = [
  ['IMAGE_QUOTA_PER_STUDENT', QUOTA],
  ['DEFAULT_QUOTA_PER_STUDENT', QUOTA],
  ['IMAGE_QUOTA_WARN_REMAINING', WARN],
  ['DEFAULT_QUOTA_WARN_REMAINING', WARN],
];

/**
 * 光有数字不算「写了真值」—— 还得在同一行里有配额语境。
 * 否则 `Node 20+`、`bytes < 20 * 1024` 都会被算成「阈值 20」。
 */
const CONTEXT = /张|配额|上限|剩余|quota|Quota|QUOTA|remaining|Remaining|REMAINING|warn|Warn|WARN|LIMIT|Limit/;

/**
 * 一致性检查只认**照片配额**的语境。
 *
 * ⚠️ 用上面那个宽泛的 CONTEXT 试过，结果把仓库里**别的**「默认 N」全抓了出来：
 *   · `AI_QUOTA_UNITS_PER_DAY`（默认 200 单位）—— 那是 AI 额度，不是照片
 *   · `listHomework` 的 `limit`（默认 50、上限 200）—— 那是分页，不是配额
 *   · 视觉档权重（默认 8）
 * 它们本身都是**对的**注释，却被判成漂移 —— 报错的检查等于没有检查，
 * 因为人第一件事就是把它关掉。判据必须窄到只覆盖自己那一件事。
 */
const PHOTO_CONTEXT = /照片|相片|图片|IMAGE_QUOTA|QUOTA_PER_STUDENT|QUOTA_WARN_REMAINING|photoQuota|photoUsage|张/;

/**
 * 反向排除：紧跟着**单位**的默认值属于别的东西。
 * 例：release-guide 的超时表写着「照片上传（最大 8MB）… 默认 3s 会大面积超时」——
 * 「照片」与「默认 3s」同现，但 3s 是超时，不是配额。
 */
const NOT_QUOTA = /默认\s*\**\s*\d+\s*(s|ms|秒|分钟|小时|次|条|个|行|KB|MB|GB|单位)/;

/**
 * 「写了默认值」的两种形态。
 *
 * ⚠️ 判据用**严格**形态：「默认」后面紧接数字（中间只允许 `**` 与空格）。
 * 先用宽松形态试过，误报两处：
 *   · `默认上限：库里 2999 张时，第 3000 张写得进去` —— 2999 是「库里已有多少」
 *   · `免得读的人以为默认值还是 10000` —— 说的是「可能被误读的旧值」
 * 一个会误报的检查，最后一定会被人 `|| true` 绕过去 —— 那还不如没有。
 * 宽松形态单独记，只提示、不据此失败。
 */
const DEFAULT_STRICT = /默认\s*\**\s*(\d+)/;
const DEFAULT_LOOSE = /默认[^。，,；;]{0,14}?(\d+)/;

function* walk(dir) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    if (e.isDirectory()) {
      if (SKIP_DIRS.has(e.name)) continue;
      yield* walk(path.join(dir, e.name));
    } else if (e.isFile()) {
      if (!EXT.has(path.extname(e.name))) continue;
      if (SKIP_FILES.has(e.name)) continue;
      yield path.join(dir, e.name);
    }
  }
}

/** 按路径判断这一处是什么角色 —— 它决定「改默认值要不要动它」。 */
function roleOf(rel) {
  if (rel.includes('/src/image-store-factory.js')) return '定义';
  if (rel.endsWith('serverless/deploy-prepare.mjs') || rel.endsWith('/s.yaml')) return '部署';
  if (rel.startsWith('doc/') || rel.endsWith('.md')) return '文档';
  if (rel.startsWith('test/') || rel.includes('/test/') || rel.endsWith('run-tests.mjs')) return '测试';
  if (rel.includes('/scripts/') || rel.startsWith('scripts/')) return '脚本';
  if (rel.startsWith('lib/')) return '客户端';
  if (rel.startsWith('serverless/')) return '服务端';
  return '其他';
}

/** 注释行还是代码行 —— 决定了「这处数字会不会被编译器/测试碰到」。 */
function isComment(rel, line) {
  const t = line.trim();
  if (rel.endsWith('.md')) return true;
  if (rel.endsWith('.yaml') || rel.endsWith('.yml') || rel.endsWith('.sh') || rel.endsWith('.ps1')) {
    return t.startsWith('#');
  }
  return t.startsWith('//') || t.startsWith('/*') || t.startsWith('*') || t.startsWith('*/');
}

const spots = [];
const kwFiles = new Map();
const mismatches = [];
const nonstandard = [];

for (const abs of walk(REPO_ROOT)) {
  const rel = path.relative(REPO_ROOT, abs).replace(/\\/g, '/');
  if (rel === SELF) continue;
  let text;
  try {
    text = fs.readFileSync(abs, 'utf8');
  } catch {
    continue;
  }
  if (text.includes('\u0000')) continue; // 二进制
  const lines = text.split(/\r?\n/);

  const kwLines = new Set();
  lines.forEach((line, i) => {
    if (KEYWORDS.some((k) => line.includes(k))) kwLines.add(i);
  });
  if (kwLines.size > 0) kwFiles.set(rel, kwLines);

  lines.forEach((line, i) => {
    const flat = line.trim().replace(/\s+/g, ' ').slice(0, 104);
    const hasKw = kwLines.has(i);
    const hits = [];
    for (const [num, label] of VALUES) {
      // 前后不能是数字或小数点 —— 免得 3000 命中 30000。
      if (new RegExp(`(?<![\\d.])${num}(?![\\d.])`).test(line) && CONTEXT.test(line)) {
        hits.push(label);
      }
    }

    // ── 一致性检查 ──
    // ⚠️ 这里**刻意不要求本行提到配置名**。踩过的坑：原先只扫「含配置名的文件」，
    // 于是「照片配额：默认 <旧值>」这种「只写数字、不写配置名」的注释**整个被跳过** ——
    // 而它恰恰是最会漂的一类（改代码的人不会去 grep 一个纯数字）。
    // 证伪时才暴露：把注释改回旧值，脚本仍然报「检查通过」。
    if (PHOTO_CONTEXT.test(line) && !NOT_QUOTA.test(line)) {
      const strict = DEFAULT_STRICT.exec(line);
      const m = strict ?? DEFAULT_LOOSE.exec(line);
      if (m) {
        const written = m[1];
        const touched = NAME_VALUE.filter(([name]) => line.includes(name)).map(([, v]) => v);
        const expect = touched.length > 0 ? touched : [QUOTA, WARN];
        if (!expect.includes(written)) {
          const entry = { rel, line: i + 1, text: flat, written, expect };
          if (strict) mismatches.push(entry);
          else nonstandard.push(entry);
        }
      }
    }

    if (!hasKw && hits.length === 0) return;
    spots.push({
      rel,
      line: i + 1,
      text: flat,
      hasKw,
      hits,
      role: roleOf(rel),
      comment: isComment(rel, line),
    });
  });
}

// ── 输出 ────────────────────────────────────────────────────────────
const bar = (s) => `\n── ${s} ${'─'.repeat(Math.max(0, 66 - s.length))}`;
const show = (s) => {
  out(`   ${s.rel}:${s.line}`);
  out(`      ${s.text}`);
};

out(`\n配额位置清单 —— 真值：每学生 ${QUOTA} 张 · 剩余 ${WARN} 张时提前提示`);
out('定义：serverless/data-service/src/image-store-factory.js');

out(bar('① 改「生产配额」= 1 处，而且不是代码'));
out('   环境变量 IMAGE_QUOTA_PER_STUDENT（阈值：IMAGE_QUOTA_WARN_REMAINING）');
out('   · 阿里云：函数计算 → data-service 函数 → 环境变量 → 改完重启');
out('   · 或改 serverless/deploy-prepare.mjs 里那份清单后重新部署');
out('   改完不用改代码、不用重新构建。下面几段是「连代码默认值也一起改」时才要顾的。');

const codeValued = spots.filter((s) => !s.comment && s.hits.length > 0);
/** 赋值 / 断言形态 —— 这些才是「改默认值真正要动手」的行。 */
const isAssign = (t) =>
  /(DEFAULT_QUOTA_\w+|IMAGE_QUOTA_\w+|EXPECTED_DEFAULT_\w+)\s*[=:]\s*'?\d+/.test(t)
  || /\b(quota|warnRemaining)\s*:\s*\d+/.test(t);
const codeOrder = ['定义', '部署', '测试', '服务端', '客户端', '脚本', '其他'];
const assignments = codeOrder.flatMap((r) =>
  codeValued.filter((s) => s.role === r && isAssign(s.text)));
const restCode = codeValued.filter((s) => !isAssign(s.text));

out(bar(`② 改「代码默认值」真正要动手的 —— ${assignments.length} 处`));
if (assignments.length === 0) out('   （无）');
for (const s of assignments) {
  out(`   [${s.role === '测试' ? '断言·手抄' : s.role}] ${s.rel}:${s.line}`);
  out(`      ${s.text}`);
}
if (assignments.some((s) => s.role === '测试')) {
  out('   ⚠️ 标「手抄」的**必须手抄**，不许 import 常量 —— 断言若从被测代码取值，');
  out('      常量改错了它也绿，那条测试就从「判据」变成「回音」。');
}
if (restCode.length > 0) {
  const byRole = new Map();
  for (const s of restCode) byRole.set(s.role, (byRole.get(s.role) ?? 0) + 1);
  out(`   另有 ${restCode.length} 处真值写在非赋值处（测试名 / 断言参数 / 提示文案）：`);
  out(`   ${[...byRole].map(([r, n]) => `${r}×${n}`).join(' · ')} —— 跟随改即可。`);
}

const docSpots = spots.filter((s) => s.comment && s.hits.length > 0);
out(bar(`③ 注释与文档里的数字副本 —— ${docSpots.length} 处，改默认值别漏`));
for (const s of docSpots.slice(0, 10)) show(s);
if (docSpots.length > 10) out(`   … 另有 ${docSpots.length - 10} 处`);

const refs = spots.filter((s) => !s.comment && s.hits.length === 0);
const byFile = new Map();
for (const s of refs) byFile.set(s.rel, (byFile.get(s.rel) ?? 0) + 1);
out(bar(`④ 不用动的 —— ${refs.length} 处 / ${byFile.size} 个文件（引用配置名，不写数字）`));
for (const [rel, n] of [...byFile].sort()) out(`   ${rel}  ×${n}`);

out(bar('小结'));
out(`   提到配置名：${spots.length} 处 / ${kwFiles.size} 个文件`);
out(`   其中代码里写了真值：${codeValued.length} 处 · 注释与文档：${docSpots.length} 处`);

if (nonstandard.length > 0) {
  out(`\n   ⚠️ ${nonstandard.length} 处「默认…数字」形态不标准、且与真值不同 —— 未纳入判据，人工确认：`);
  for (const s of nonstandard.slice(0, 5)) show(s);
}

if (mismatches.length > 0) {
  console.log(bar(`⚠️ 配额默认值检查失败 —— ${mismatches.length} 处写的「默认值」与代码不符`));
  for (const m of mismatches) {
    console.log(`   ${m.rel}:${m.line}`);
    console.log(`      写的：默认 ${m.written}   ←→  真值：${m.expect.join(' / ')}`);
    console.log(`      ${m.text}`);
  }
  console.log('\n   这是**静默漂移**：没有任何测试会因此变红，只有读到这行注释的人会被骗。');
  console.log('   改代码或改注释都行 —— 但要让这两处说同一件事。');
  process.exitCode = 1;
} else {
  console.log(`✅ 配额默认值一致性：OK（真值 ${QUOTA} 张 / 提示阈值 ${WARN} 张）`);
  if (nonstandard.length > 0) {
    console.log(`   （另 ${nonstandard.length} 处形态不标准，未纳入判据 —— 详见 npm run quota:where）`);
  }
}
