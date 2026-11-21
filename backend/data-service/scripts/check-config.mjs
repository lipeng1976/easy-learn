#!/usr/bin/env node
/**
 * 上线前的配置自检（**不连库、不起服务**）。
 *
 * 与 `src/config-check.js` 是同一套规则，区别是这里把它做成一条命令 ——
 * 因为「猜自己配全了没」是部署里最容易出错的一步，而配漏的症状往往
 * 要到线上才出现（见 config-check.js 开头那几条）。
 *
 * 用法：
 *   # 1) 把打算用的环境变量写成一个文件（别提交，见 .gitignore 的 .env.*）
 *   #    NODE_ENV=production
 *   #    AI_SESSION_SECRET=<64 位随机串>
 *   #    PGPASSWORD=<...>
 *   node scripts/check-config.mjs --env-file .env.prod
 *
 *   # 2) 或者直接查当前 shell 里的环境变量
 *   node scripts/check-config.mjs
 *
 *   # 3) 只想看「按生产标准」会报什么（自动补上 NODE_ENV=production）
 *   node scripts/check-config.mjs --env-file .env.prod --production
 *
 * 退出码：0 = 没有致命问题（警告会照常打印）；1 = 有致命问题。
 */
import { isProduction, validateConfig } from '../src/config-check.js';
import { loadEnv, valueOf } from './lib/env-file.mjs';

const args = process.argv.slice(2);

const envFile = valueOf(args, '--env-file');
const { env: rawEnv, count, fromFile } = loadEnv(envFile);
if (fromFile) {
  process.stdout.write(`环境变量文件：${envFile}（${count} 个键）\n`);
} else {
  process.stdout.write('环境变量来源：当前进程（没给 --env-file）\n');
}

let env = rawEnv;
if (args.includes('--production')) {
  env = { ...env, NODE_ENV: 'production' };
  process.stdout.write('已按 --production 强制 NODE_ENV=production\n');
}

const production = isProduction(env);
process.stdout.write(`环境：${production ? '生产（NODE_ENV=production）' : '非生产'}\n\n`);

const { problems, warnings } = validateConfig(env);

if (warnings.length > 0) {
  process.stdout.write(`⚠️  ${warnings.length} 条警告（不拦，但要自己确认能接受）：\n`);
  warnings.forEach((w, i) => process.stdout.write(`  ${i + 1}. ${w}\n`));
  process.stdout.write('\n');
}

if (problems.length > 0) {
  process.stdout.write(`✗ ${problems.length} 条致命问题（这个配置起不来）：\n`);
  problems.forEach((p, i) => process.stdout.write(`  ${i + 1}. ${p}\n`));
  process.exit(1);
}

process.stdout.write('✓ 没有致命问题。\n');
