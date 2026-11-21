/**
 * 静态自检：语法 / 密钥 / 绝对路径 / 文件完整性。
 * 用法：npm run verify
 *
 * 它**不**连数据库、不替代端到端探针。目的是把「静默失败」类问题
 * 挡在提交前：漏文件、密钥硬编码、绝对路径混进 SQL、db/ 里混进业务数据。
 */

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const failures = [];
const passes = [];

const REQUIRED_FILES = [
  '.env.example', '.gitignore', 'package.json', 'README.md',
  'frontend/.gitignore', 'frontend/pubspec.yaml', 'frontend/analysis_options.yaml',
  'frontend/lib/main.dart', 'frontend/lib/app.dart',
  'frontend/lib/config/app_config.dart', 'frontend/lib/config/api_endpoints.dart',
  'frontend/lib/core/network/api_client.dart',
  'frontend/lib/core/network/api_exception.dart',
  'frontend/lib/core/storage/relative_path.dart',
  'frontend/lib/data/models/attachment.dart',
  'frontend/lib/data/repositories/attachment_repository.dart',
  'frontend/lib/pages/home_page.dart',
  'frontend/test/relative_path_test.dart',
  'backend/.gitignore',
  'backend/shared/package.json', 'backend/shared/config.js', 'backend/shared/paths.js',
  'backend/shared/errors.js', 'backend/shared/http.js', 'backend/shared/db.js',
  'backend/shared/session.js',
  'backend/data-service/package.json', 'backend/data-service/index.cjs',
  'backend/data-service/scripts/migrate.mjs',
  'backend/data-service/src/server.js', 'backend/data-service/src/app.js',
  'backend/data-service/src/router.js', 'backend/data-service/src/auth.js',
  'backend/data-service/src/password.js',
  'backend/data-service/src/routes/health.js',
  'backend/data-service/src/routes/auth.js',
  'backend/data-service/src/routes/attachments.js',
  'backend/data-service/src/storage/local_driver.js',
  'backend/ai-gateway/package.json', 'backend/ai-gateway/index.cjs',
  'backend/ai-gateway/src/server.js', 'backend/ai-gateway/src/app.js',
  'backend/ai-gateway/src/router.js', 'backend/ai-gateway/src/model_client.js',
  'backend/ai-gateway/src/routes/health.js',
  'backend/ai-gateway/src/routes/review.js',
  'db/001_schema.sql', 'db/002_seed.sql', 'db/README.md',
  'docs/README.md', 'docs/architecture.md', 'docs/environment.md',
  'docs/database.md', 'docs/source-index.md', 'docs/handover.md',
  'scripts/init-db.mjs', 'scripts/check-env.mjs', 'scripts/verify.mjs',
  'scripts/create-user.mjs',
];

const SKIP_DIRS = new Set([
  'node_modules', '.git', 'build', 'dist', 'var', '.dart_tool', 'coverage', '.idea', '.vscode',
]);

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.') && entry.name !== '.env.example' && entry.name !== '.gitignore') continue;
    if (SKIP_DIRS.has(entry.name)) continue;
    const absolute = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(absolute, out);
    else if (entry.isFile()) out.push(absolute);
  }
  return out;
}

const files = walk(ROOT);
const rel = (f) => path.relative(ROOT, f).split(path.sep).join('/');
const read = (f) => fs.readFileSync(f, 'utf8');

// ── 1. 关键文件完整性 ────────────────────────────────────────────────────
const missing = REQUIRED_FILES.filter((f) => !fs.existsSync(path.join(ROOT, f)));
if (missing.length) failures.push(`缺少关键文件：${missing.join(', ')}`);
else passes.push(`关键文件齐全（${REQUIRED_FILES.length} 个）`);

// 每个交付文件都必须是完整内容，不允许「...省略」占位。
const placeholders = files
  .filter((f) => /\.(js|mjs|cjs|dart|sql|md|yaml|json)$/.test(f))
  .filter((f) => /(\/\/|#|--)\s*\.\.\.\s*(省略|其余|下同|snip)/i.test(read(f)));
if (placeholders.length) failures.push(`存在省略占位：${placeholders.map(rel).join(', ')}`);
else passes.push('无「...省略」占位片段');

// ── 2. JS / CJS 语法 ─────────────────────────────────────────────────────
const jsFiles = files.filter((f) => /\.(js|mjs|cjs)$/.test(f));
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

// ── 3. 环境变量读取只在 config.js 与 scripts/ ─────────────────────────────
const envReaders = jsFiles.filter((f) => /process\.env/.test(read(f)));
const illegals = envReaders.filter((f) => {
  const r = rel(f);
  return r !== 'backend/shared/config.js' && !r.startsWith('scripts/');
});
if (illegals.length) failures.push(`越权读取环境变量：${illegals.map(rel).join(', ')}`);
else passes.push('环境变量只在 config.js / scripts/ 读取');

// ── 4. 密钥字面量 ───────────────────────────────────────────────────────
const secretPattern = /(sk-[A-Za-z0-9]{16,}|AKID[A-Za-z0-9]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)/;
const codeFiles = files.filter((f) => /\.(js|mjs|cjs|dart|sql|json|yaml)$/.test(f));
const secretHits = codeFiles.filter((f) => secretPattern.test(read(f)));
if (secretHits.length) failures.push(`疑似硬编码密钥：${secretHits.map(rel).join(', ')}`);
else passes.push('代码与 SQL 中无密钥字面量');

// SQL/DDL 里不允许出现带口令的 CREATE/ALTER ROLE。
const sqlFiles = files.filter((f) => f.endsWith('.sql'));
const passwordInSql = sqlFiles.filter((f) => /PASSWORD\s+'/i.test(read(f)));
if (passwordInSql.length) failures.push(`SQL 中硬编码了角色口令：${passwordInSql.map(rel).join(', ')}`);
else passes.push('SQL 中无角色口令');

// ── 5. 绝对路径字面量（★ 数据库/代码里不许出现）──────────────────────────
const absPathPattern = /(['"`])(?:[A-Za-z]:[\\/]|\/var\/|\/home\/|\/Users\/)/;
// 测试用例里**必须**保留这些反例字面量，否则判据无法证伪 —— 排除测试目录。
const absHits = codeFiles
  .filter((f) => !rel(f).startsWith('frontend/test/'))
  .filter((f) => absPathPattern.test(read(f)));
if (absHits.length) failures.push(`代码/SQL 中出现绝对路径字面量：${absHits.map(rel).join(', ')}`);
else passes.push('生产代码与 SQL 中无绝对路径字面量（测试反例除外）');

// ── 6. .env.example 只放占位符 ───────────────────────────────────────────
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

// ── 7. db/ 只有 DDL + 非敏感种子 ─────────────────────────────────────────
const dbSql = fs.readdirSync(path.join(ROOT, 'db')).filter((f) => f.endsWith('.sql')).sort();
if (dbSql.join(',') !== '001_schema.sql,002_seed.sql') {
  failures.push(`db/ 应只有 001_schema.sql 与 002_seed.sql，实际：${dbSql.join(',')}`);
} else {
  passes.push('db/ 只含 DDL 与种子两个 SQL');
}
const seed = read(path.join(ROOT, 'db/002_seed.sql'));
const insertTargets = [...seed.matchAll(/INSERT\s+INTO\s+([A-Za-z_][A-Za-z0-9_]*)/gi)].map((m) => m[1]);
if (insertTargets.some((t) => t !== 'app_dict')) {
  failures.push(`种子 SQL 写入了非字典表：${[...new Set(insertTargets)].join(', ')}`);
} else {
  passes.push('种子 SQL 只写字典表 app_dict（无账号 / 无业务数据）');
}

// ── 8. 入库完整性：关键文件不得被 .gitignore 误忽略 ───────────────────────
// 「文件在磁盘上」不等于「会进版本库」。典型静默失败：.gitignore 写了
// 不带根锚定的 storage/，把 src/storage/ 源码目录一起吃掉。
// 只有本目录已 git init 时才检查；交付包被解压成普通文件夹时跳过。
if (fs.existsSync(path.join(ROOT, '.git'))) {
  let stdout = '';
  try {
    stdout = execFileSync(
      'git',
      ['check-ignore', '--no-index', '-z', '--stdin'],
      {
        cwd: ROOT,
        input: Buffer.from(`${REQUIRED_FILES.join('\0')}\0`),
        encoding: 'utf8',
      },
    );
  } catch (err) {
    // 退出码 1 = 没有任何文件被忽略（正常结果）；其它情况才是真异常。
    stdout = String(err.stdout ?? '');
    if (err.status !== 1) {
      failures.push(`git check-ignore 执行失败：${String(err.stderr ?? err.message).split('\n')[0]}`);
    }
  }
  const ignored = stdout.split('\0').filter(Boolean);
  if (ignored.length) failures.push(`关键文件被 .gitignore 忽略，将漏入库：${ignored.join(', ')}`);
  else passes.push('关键文件均可被 git 跟踪（无 .gitignore 误伤）');
} else {
  passes.push('关键文件均可被 git 跟踪（尚未 git init，跳过）');
}

// ── 输出 ────────────────────────────────────────────────────────────────
for (const p of passes) console.log(`  ✅ ${p}`);
if (failures.length) {
  for (const f of failures) console.error(`  ❌ ${f}`);
  console.error(`\n[verify] 失败：${failures.length} 项`);
  process.exitCode = 1;
} else {
  console.log(`\n[verify] ✅ 全部通过（${passes.length} 项静态检查）`);
  console.log('[verify] 注意：这是静态自检，不替代真库执行与端到端探针。');
}
