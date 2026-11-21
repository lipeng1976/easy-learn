/**
 * 启动前环境变量自检。
 * 用法：npm run check:env
 * 只打印「有没有配」，绝不打印值。
 */

import { loadConfig, loadDotEnv } from '../backend/shared/config.js';

function mask(value) {
  return value ? 'set' : 'MISSING';
}

const dotenv = loadDotEnv();
console.log(`[env] .env：${dotenv ? `已加载（${dotenv.loaded.length} 项）` : '未找到，使用平台注入的环境变量'}`);

try {
  const data = loadConfig(process.env, 'data');
  const ai = loadConfig(process.env, 'ai');

  const checks = [
    ['DATABASE_URL', mask(data.databaseUrl)],
    ['PG_OPS_URL（初始化用）', mask(data.pgOpsUrl)],
    ['APP_RLS_PASSWORD（初始化用）', mask(data.appRlsPassword)],
    ['AI_SESSION_SECRET（≥32 字符）', `set (${data.sessionSecret.length} chars)`],
    ['AI_REQUIRE_AUTH', String(data.requireAuth)],
    ['STORAGE_ROOT', 'set（值不打印）'],
    ['IMAGE_DRIVER', data.imageDriver],
    ['AI_MODEL_PROVIDER', ai.aiModelProvider],
    ['NODE_ENV', data.nodeEnv],
  ];
  for (const [name, value] of checks) console.log(`  ${name.padEnd(36)} ${value}`);

  const warnings = [];
  if (!data.pgOpsUrl) warnings.push('PG_OPS_URL 未配置 → npm run db:init 无法执行');
  if (!data.appRlsPassword || data.appRlsPassword.includes('CHANGE_ME')) {
    warnings.push('APP_RLS_PASSWORD 仍是占位符 → npm run db:init 会拒绝执行');
  }
  if (data.pgAppRole !== 'app_rls') {
    throw new Error('PG_APP_ROLE 与 db/001_schema.sql 的固定角色 app_rls 不一致');
  }
  if (!data.isProduction && data.requireAuth) {
    console.log('  [提示] 开发环境也开启了鉴权，本地联调需要 Bearer 票据');
  }

  if (warnings.length) {
    console.log('\n[env] 警告（不影响服务启动）：');
    for (const w of warnings) console.log(`  ⚠ ${w}`);
  }
  console.log('\n[env] ✅ 必需变量校验通过');
} catch (err) {
  console.error('[env] ❌', err.message);
  process.exitCode = 1;
}
