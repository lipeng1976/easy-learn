/**
 * 全项目**唯一**读取环境变量的地方。
 *
 * 规矩：
 *   1) 其它文件一律用 getConfig() 取值，不得直接 process.env.XXX；
 *      scripts/verify.mjs 会静态检查这一条。
 *   2) 缺必需变量 → 启动即抛错，不静默用默认值兜底。
 *   3) 生产环境禁止占位符 CHANGE_ME，且 AI_REQUIRE_AUTH 必须为 true。
 *   4) 密钥只从这里进内存，不写日志、不落库、不进代码。
 *
 * .env 由 loadDotEnv() 手工解析（Node 20 内置 http，不引第三方 dotenv 依赖）：
 * 只填补 process.env 里**尚不存在**的键，平台注入的真实环境变量优先。
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
/** 工程根目录（<root>/backend/shared → <root>）。 */
export const PROJECT_ROOT = path.resolve(HERE, '..', '..');

const COMMON_REQUIRED = ['AI_SESSION_SECRET', 'AI_REQUIRE_AUTH'];
const DATA_REQUIRED = ['DATABASE_URL', 'STORAGE_ROOT', 'IMAGE_DRIVER'];
const MIN_SECRET_LENGTH = 32;

/** 解析根目录下的 .env；不存在时返回 null（不报错，允许纯平台注入）。 */
export function loadDotEnv() {
  const file = path.join(PROJECT_ROOT, '.env');
  if (!fs.existsSync(file)) return null;
  const text = fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '');
  const loaded = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 1) continue;
    let key = line.slice(0, eq).trim();
    if (key.startsWith('export ')) key = key.slice(7).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) continue;
    let value = line.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (process.env[key] === undefined) {
      process.env[key] = value;
      loaded.push(key);
    }
  }
  return { file, loaded };
}

function str(env, key, fallback = '') {
  const value = env[key];
  return value === undefined || value === null ? fallback : String(value).trim();
}

function int(env, key, fallback, min, max) {
  const raw = str(env, key, String(fallback));
  if (!/^\d+$/.test(raw)) throw new Error(`${key} 必须是整数，当前值：${raw}`);
  const n = Number(raw);
  if (n < min || n > max) throw new Error(`${key} 必须在 ${min}~${max} 之间，当前值：${n}`);
  return n;
}

function bool(env, key) {
  const raw = str(env, key).toLowerCase();
  if (raw !== 'true' && raw !== 'false') {
    throw new Error(`${key} 只能是 true / false，当前值：${raw || '(空)'}`);
  }
  return raw === 'true';
}

function assertRequired(env, keys) {
  const missing = keys.filter((k) => str(env, k) === '');
  if (missing.length) {
    throw new Error(
      `缺少必需环境变量：${missing.join(', ')}。\n` +
      `请复制 .env.example 为 .env 并填写（模板见 .env.example，说明见 docs/environment.md）。`
    );
  }
}

/** 构造配置对象。service: 'data' | 'ai'，决定哪些变量是必需的。 */
export function loadConfig(env = process.env, service = 'data') {
  loadDotEnv();

  const nodeEnv = str(env, 'NODE_ENV', 'development');
  const isProduction = nodeEnv.toLowerCase() === 'production';

  assertRequired(env, service === 'data' ? [...COMMON_REQUIRED, ...DATA_REQUIRED] : COMMON_REQUIRED);

  const secret = str(env, 'AI_SESSION_SECRET');
  if (secret.length < MIN_SECRET_LENGTH) {
    throw new Error(`AI_SESSION_SECRET 至少 ${MIN_SECRET_LENGTH} 字符，当前 ${secret.length} 字符。`);
  }

  const requireAuth = bool(env, 'AI_REQUIRE_AUTH');
  if (isProduction && !requireAuth) {
    throw new Error('生产环境必须设置 AI_REQUIRE_AUTH=true，否则 /data/* 与 /ai/* 可匿名调用。');
  }

  // 生产环境禁止任何占位符残留。逐项检查，别只查密钥。
  if (isProduction) {
    const placeholders = Object.entries(env)
      .filter(([k, v]) => k.startsWith('PG_') || k.startsWith('AI_') ||
                          k.startsWith('OSS_') || k.startsWith('BAILIAN_') ||
                          k.startsWith('ARK_') || k.startsWith('IMA_') ||
                          k === 'DATABASE_URL' || k === 'APP_RLS_PASSWORD')
      .filter(([, v]) => typeof v === 'string' && v.includes('CHANGE_ME'))
      .map(([k]) => k);
    if (placeholders.length) {
      throw new Error(`生产环境存在未替换的占位符：${placeholders.join(', ')}`);
    }
  }

  const imageDriver = str(env, 'IMAGE_DRIVER', 'local').toLowerCase();
  if (imageDriver !== 'local' && imageDriver !== 'oss') {
    throw new Error(`IMAGE_DRIVER 只能是 local / oss，当前值：${imageDriver || '(空)'}。不静默回退。`);
  }
  if (imageDriver === 'oss') {
    assertRequired(env, [
      'OSS_ENDPOINT', 'OSS_REGION', 'OSS_BUCKET',
      'OSS_ACCESS_KEY_ID', 'OSS_ACCESS_KEY_SECRET',
    ]);
  }

  const storageRoot = path.resolve(PROJECT_ROOT, str(env, 'STORAGE_ROOT', './var/storage'));

  return Object.freeze({
    projectRoot: PROJECT_ROOT,
    nodeEnv,
    isProduction,
    logLevel: str(env, 'LOG_LEVEL', 'info'),

    dataServicePort: int(env, 'DATA_SERVICE_PORT', 8788, 1, 65535),
    aiGatewayPort: int(env, 'AI_GATEWAY_PORT', 8787, 1, 65535),

    databaseUrl: str(env, 'DATABASE_URL'),
    pgOpsUrl: str(env, 'PG_OPS_URL'),
    pgSslMode: str(env, 'PGSSLMODE', 'disable'),
    pgPoolMax: int(env, 'PG_POOL_MAX', 10, 1, 200),
    pgAppRole: str(env, 'PG_APP_ROLE', 'app_rls'),
    appRlsPassword: str(env, 'APP_RLS_PASSWORD'),

    sessionSecret: secret,
    requireAuth,
    sessionTtlHours: int(env, 'SESSION_TTL_HOURS', 168, 1, 8760),

    // ★ 附件根目录：唯一配置处。数据库里只存相对它的路径。
    storageRoot,
    imageDriver,
    oss: Object.freeze({
      endpoint: str(env, 'OSS_ENDPOINT'),
      region: str(env, 'OSS_REGION'),
      bucket: str(env, 'OSS_BUCKET'),
      accessKeyId: str(env, 'OSS_ACCESS_KEY_ID'),
      accessKeySecret: str(env, 'OSS_ACCESS_KEY_SECRET'),
    }),

    aiModelProvider: str(env, 'AI_MODEL_PROVIDER', 'bailian').toLowerCase(),
    bailianApiKey: str(env, 'BAILIAN_API_KEY'),
    bailianModel: str(env, 'BAILIAN_MODEL', 'qwen-plus'),
    arkApiKey: str(env, 'ARK_API_KEY'),
    arkModel: str(env, 'ARK_MODEL'),
    aiGatewayTimeoutMs: int(env, 'AI_GATEWAY_TIMEOUT_MS', 12000, 100, 600000),

    imaClientId: str(env, 'IMA_CLIENT_ID'),
    imaApiKey: str(env, 'IMA_API_KEY'),
    imaCredentialSecret: str(env, 'IMA_CREDENTIAL_SECRET'),

    // 前端构建期变量：只在生成 --dart-define 命令时用，不注入服务运行时行为。
    frontend: Object.freeze({
      dataApiBaseUrl: str(env, 'DATA_API_BASE_URL'),
      aiBaseUrl: str(env, 'AI_BASE_URL'),
      dataTimeoutMs: str(env, 'DATA_TIMEOUT_MS'),
      aiTimeoutMs: str(env, 'AI_TIMEOUT_MS'),
      aiUploadTimeoutMs: str(env, 'AI_UPLOAD_TIMEOUT_MS'),
      aiJudgeTimeoutMs: str(env, 'AI_JUDGE_TIMEOUT_MS'),
    }),
  });
}

const cache = new Map();

/** 懒加载单例：模块被 import 时不会因为缺 env 直接抛错。 */
export function getConfig(service = 'data') {
  if (!cache.has(service)) cache.set(service, loadConfig(process.env, service));
  return cache.get(service);
}

/** 测试用：清空缓存。 */
export function resetConfigCache() {
  cache.clear();
}
