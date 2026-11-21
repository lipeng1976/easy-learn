/**
 * 全量工程静态自检 —— 用法：npm run verify
 *
 * 不连数据库、不跑 Flutter、不替代端到端探针。
 * 挡的是「静默失败」：漏文件、禁入项混进仓库、密钥字面量、
 * 绝对路径混进生产代码/SQL、文件被 .gitignore 吃掉导致入库漏件。
 *
 * 口径：迁入的全量业务源码是**当前真值**，docs/baseline/ 是整理版基线快照。
 * 两者规范不同，检查范围按目录区分，见 docs/migration.md。
 */

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const failures = [];
const passes = [];
const warnings = [];
const rel = (f) => path.relative(ROOT, f).split(path.sep).join('/');
const read = (f) => fs.readFileSync(f, 'utf8');

const SKIP_DIRS = new Set(['.git', 'node_modules']);
function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP_DIRS.has(entry.name)) continue;
    const absolute = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(absolute, out);
    else if (entry.isFile()) out.push(absolute);
  }
  return out;
}

const allFiles = walk(ROOT);
const rels = allFiles.map(rel);
const countIn = (prefix) => rels.filter((r) => r.startsWith(`${prefix}/`)).length;

// ── 1. 全量源码规模（用下限，新增文件不会误报，漏文件会报）────────────────
const SCALE = [
  ['frontend/lib', 277, '前端业务源码'],
  ['frontend/test', 175, '前端测试'],
  ['backend/shared', 6, 'shared 层'],
  ['backend/data-service/src', 53, '数据服务源码'],
  ['backend/data-service/scripts', 51, '数据服务脚本'],
  ['backend/data-service/test', 31, '数据服务契约测试'],
  ['backend/ai-gateway/src', 23, 'AI 网关源码'],
  ['backend/ai-gateway/test', 16, 'AI 网关契约测试'],
  ['backend/ai-gateway/scripts', 23, 'AI 网关脚本'],
  ['backend/ai-gateway/examples', 2, 'AI 网关示例'],
  ['db/migrations', 29, '增量迁移 SQL'],
  ['docs/baseline', 59, '整理版基线快照'],
];
const short = [];
for (const [dir, min, label] of SCALE) {
  const n = countIn(dir);
  if (n < min) short.push(`${label} ${dir}: ${n} < ${min}`);
}
if (short.length) failures.push(`源码规模不足：\n    ${short.join('\n    ')}`);
else passes.push(`全量源码规模达标（lib ${countIn('frontend/lib')} / test ${countIn('frontend/test')} / migrations ${countIn('db/migrations')}）`);

// ── 2. 关键文件 ─────────────────────────────────────────────────────────
const REQUIRED = [
  'README.md', '.env.example', '.gitignore', 'package.json',
  'frontend/pubspec.yaml', 'frontend/pubspec.lock', 'frontend/analysis_options.yaml',
  'frontend/lib/main.dart', 'frontend/lib/app.dart',
  'frontend/lib/services/database_service.dart',
  'frontend/lib/services/cloud_runtime.dart',
  'frontend/android/settings.gradle.kts',
  'backend/shared/env.js', 'backend/shared/token.js',
  'backend/data-service/index.cjs', 'backend/data-service/src/app.js',
  'backend/data-service/src/dev-server.js', 'backend/data-service/src/db.js',
  'backend/data-service/scripts/dev-stack.mjs',
  'backend/data-service/test/contract.test.js',
  'backend/data-service/test/runner-list.test.js',
  'backend/ai-gateway/index.cjs', 'backend/ai-gateway/src/dev-server.js',
  'backend/ai-gateway/src/prompts.js', 'backend/ai-gateway/test/contract.test.js',
  'db/migrations/001_schema.sql', 'db/migrations/029_book_grade_term.sql',
  'docs/README.md', 'docs/migration.md', 'docs/DETAIL.md',
  'scripts/verify.mjs', 'docs/baseline/README.md',
  'docs/baseline/backend/shared/paths.js',
];
const missing = REQUIRED.filter((f) => !fs.existsSync(path.join(ROOT, f)));
if (missing.length) failures.push(`缺少关键文件：${missing.join(', ')}`);
else passes.push(`关键文件齐全（${REQUIRED.length} 个）`);

// 每个交付文件都必须是完整内容，不允许「...省略」占位。
const placeholders = allFiles
  .filter((f) => /\.(js|mjs|cjs|dart|sql|md|yaml|json)$/.test(f))
  .filter((f) => /(\/\/|#|--)\s*\.\.\.\s*(省略|其余|下同|snip)/i.test(read(f)));
if (placeholders.length) failures.push(`存在省略占位：${placeholders.map(rel).join(', ')}`);
else passes.push('无「...省略」占位片段');

// ── 3. 禁入项（★ 迁移时最容易 cp -r 带进来的东西）────────────────────────
const BANNED = [
  [/\.env\.prod/i, '真实生产 env'],
  [/\.env\.local$/i, '本机 env'],
  [/\.env\.volc/i, '厂商 env'],
  [/^s\.yaml$/i, 'FC3 部署配置（含密钥）'],
  [/key\.properties$/i, 'Android 签名配置'],
  [/local\.properties$/i, '本机 SDK 路径'],
  [/\.apk$/i, 'APK'],
  [/\.(db|sqlite|sqlite3)$/i, '数据库快照'],
  [/\.log$/i, '日志'],
  [/\.iml$/i, 'IDE 配置'],
  [/(^|\/)node_modules\//, '依赖目录'],
  [/(^|\/)build\//, '构建产物'],
  [/(^|\/)ephemeral\//, 'Flutter 临时产物'],
  [/\.pgdata/i, '本地 PG 数据目录'],
  [/(^|\/)site(-old-[^/]*)?\//, 'Web 发布产物'],
];
const bannedHits = [];
for (const r of rels) {
  for (const [pattern, label] of BANNED) {
    if (pattern.test(r)) bannedHits.push(`${r}（${label}）`);
  }
}
if (bannedHits.length) failures.push(`禁入项混进仓库：${bannedHits.slice(0, 12).join(', ')}${bannedHits.length > 12 ? ` …共 ${bannedHits.length} 项` : ''}`);
else passes.push('无禁入项（密钥 / APK / 数据库 / 日志 / 构建产物）');

// 单文件体积：源码仓库不该出现 >5MB 的二进制。
const bigFiles = allFiles
  .filter((f) => fs.statSync(f).size > 5 * 1024 * 1024)
  .map((f) => `${rel(f)} ${(fs.statSync(f).size / 1024 / 1024).toFixed(1)}MB`);
if (bigFiles.length) failures.push(`超大文件：${bigFiles.join(', ')}`);
else passes.push('无 >5MB 的大文件');

// ── 4. JS / CJS 语法（全量）─────────────────────────────────────────────
const jsFiles = allFiles.filter((f) => /\.(js|mjs|cjs)$/.test(f));
const syntaxErrors = [];
for (const f of jsFiles) {
  try {
    execFileSync(process.execPath, ['--check', f], { stdio: 'pipe' });
  } catch (err) {
    syntaxErrors.push(`${rel(f)}: ${String(err.stderr ?? err.message).split('\n')[0]}`);
  }
}
if (syntaxErrors.length) failures.push(`语法错误：\n    ${syntaxErrors.join('\n    ')}`);
else passes.push(`JS 语法检查通过（${jsFiles.length} 个文件）`);

// ── 5. 密钥字面量（生产密钥形式）─────────────────────────────────────────
const secretPattern = /(sk-[A-Za-z0-9]{16,}|AKID[A-Za-z0-9]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)/;
const codeFiles = allFiles.filter((f) => /\.(js|mjs|cjs|dart|sql|json|yaml)$/.test(f));
const secretHits = codeFiles.filter((f) => secretPattern.test(read(f)));
if (secretHits.length) failures.push(`疑似硬编码生产密钥：${secretHits.map(rel).join(', ')}`);
else passes.push('无生产密钥字面量');

// ── 6. 绝对路径：只查生产代码与 SQL ───────────────────────────────────────
// 探针/运维脚本里保留本机绝对路径作为默认值，属既有事实，见 docs/migration.md。
// 测试里的反例字面量必须保留，否则判据无法证伪。
const absPathPattern = /(['"`])(?:[A-Za-z]:[\\/]|\/var\/|\/home\/|\/Users\/)/;
const prodFiles = codeFiles.filter((f) => {
  const r = rel(f);
  return !r.startsWith('docs/baseline/')
    && !r.includes('/test/')
    && !r.startsWith('scripts/')
    && !r.startsWith('backend/scripts/')
    && !r.includes('/scripts/');
});
// 逐行判断：注释/文档字符串里的路径示例不是硬编码；
// `process.env.SystemRoot ?? 'C:\Windows'` 是 Windows 系统目录兜底，不是业务根目录。
function hasAbsPathInCode(file) {
  return read(file).split(/\r?\n/).some((line) => {
    const trimmed = line.trim();
    if (/^(\/\/|\*|#|--)/.test(trimmed)) return false;
    if (/process\.env\.SystemRoot\s*\?\?/.test(trimmed)) return false;
    return absPathPattern.test(line);
  });
}
const absHits = prodFiles.filter(hasAbsPathInCode);
if (absHits.length) failures.push(`生产代码/SQL 中出现绝对路径字面量：${absHits.map(rel).join(', ')}`);
else passes.push('生产代码与 SQL 中无硬编码绝对路径（注释示例 / 系统目录兜底 / 脚本默认值 / 测试反例除外）');

// ── 7. .env.example 只放占位符 ───────────────────────────────────────────
const envExample = read(path.join(ROOT, '.env.example'));
const badEnvLines = envExample.split(/\r?\n/)
  .filter((line) => /^[A-Z][A-Z0-9_]*=/.test(line))
  .filter((line) => /(KEY|SECRET|PASSWORD|TOKEN)/i.test(line.split('=')[0]))
  .filter((line) => {
    const value = line.slice(line.indexOf('=') + 1).trim();
    return value !== '' && !value.includes('CHANGE_ME');
  });
if (badEnvLines.length) failures.push(`.env.example 含非占位值：${badEnvLines.join(' | ')}`);
else passes.push('.env.example 全部为占位符');

// ── 8. 迁移文件序列 001~029 齐全 ─────────────────────────────────────────
const migrationNames = fs.readdirSync(path.join(ROOT, 'db/migrations'))
  .filter((f) => f.endsWith('.sql')).sort().map((f) => f.slice(0, 3));
const expected = Array.from({ length: 29 }, (_, i) => String(i + 1).padStart(3, '0'));
const missingSeq = expected.filter((n) => !migrationNames.includes(n));
if (missingSeq.length) failures.push(`增量迁移缺号：${missingSeq.join(', ')}`);
else passes.push('db/migrations 001~029 序列完整');

// ── 9. 已知差异：本机开发口令（不计失败，如实提示）────────────────────────
const sqlFiles = allFiles.filter((f) => f.endsWith('.sql'));
const rolePw = sqlFiles.filter((f) => /PASSWORD\s+'/i.test(read(f))).map(rel);
if (rolePw.length) {
  warnings.push(`本机开发角色口令写在 ${rolePw.join(', ')}（公开弱口令、原工程既有设计；生产口令从环境变量/云控制台注入，详见 docs/migration.md）`);
}

// ── 10. 入库完整性：交付文件不得被 .gitignore 误忽略 ─────────────────────
// 「文件在磁盘上」≠「会进版本库」。11-21 曾因 backend/.gitignore 的 storage/
// 连带忽略 src/storage/ 源码目录，exist 检查全绿但入库漏文件。
if (fs.existsSync(path.join(ROOT, '.git'))) {
  let stdout = '';
  try {
    stdout = execFileSync(
      'git',
      ['check-ignore', '--no-index', '-z', '--stdin'],
      { cwd: ROOT, input: Buffer.from(`${rels.join('\0')}\0`), encoding: 'utf8' },
    );
  } catch (err) {
    // 退出码 1 = 没有任何文件被忽略（正常结果）。
    stdout = String(err.stdout ?? '');
    if (err.status !== 1) {
      failures.push(`git check-ignore 执行失败：${String(err.stderr ?? err.message).split('\n')[0]}`);
    }
  }
  const ignored = stdout.split('\0').filter(Boolean);
  const badIgnored = ignored.filter((p) => /\.(js|mjs|cjs|dart|sql|md|yaml|json)$/.test(p));
  if (badIgnored.length) failures.push(`交付文件被 .gitignore 忽略，将漏入库：${badIgnored.slice(0, 10).join(', ')}`);
  else passes.push('全部交付文件可被 git 跟踪（无 .gitignore 误伤）');
} else {
  passes.push('git 可入库检查（尚未 git init，跳过）');
}

// ── 输出 ────────────────────────────────────────────────────────────────
for (const p of passes) console.log(`  ✅ ${p}`);
for (const w of warnings) console.log(`  ⚠️  ${w}`);
if (failures.length) {
  for (const f of failures) console.error(`  ❌ ${f}`);
  console.error(`\n[verify] 失败：${failures.length} 项`);
  process.exitCode = 1;
} else {
  console.log(`\n[verify] ✅ 全部通过（${passes.length} 项静态检查${warnings.length ? `，${warnings.length} 条已知差异提示` : ''}）`);
  console.log('[verify] 注意：静态自检不替代真库执行、Flutter analyze/test 与端到端探针。');
}
