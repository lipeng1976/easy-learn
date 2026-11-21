/**
 * 本机开发栈的运行期凭据。
 *
 * ## 为什么存在
 *
 * 仓库里不允许出现任何**可用的**口令或会话签名密钥字面量：拿到源码的人
 * 不该能直接连上别人的库，也不该能自己签一张有效的会话票
 * （票据校验会全过、且不留痕迹——这是本项目最怕的那类静默失败）。
 *
 * 生产 / 云 / CI 一律由环境变量注入；本机演示栈为了保持「一条命令起全套」，
 * 在缺失环境变量时生成随机值并持久化到 `.dev-credentials.json`（gitignore）。
 *
 * ## 为什么必须持久化
 *
 * 会话密钥一重启就换，等于把所有已登录设备踢下线；角色口令一换，
 * 复用数据目录的旧库就连不上了。所以生成一次、之后复用。
 * 环境变量齐全时**完全不碰**本地文件，保证生产路径零副作用。
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
export const DEV_CREDENTIALS_FILE = path.resolve(here, '..', '..', '.dev-credentials.json');

/** 随机串的熵要够：48 字节 base64url = 64 字符，远超 HMAC 的最小长度。 */
const MIN_LENGTH = 32;

function randomSecret() {
  return crypto.randomBytes(48).toString('base64url');
}

function localCredentials() {
  let saved = {};
  try {
    saved = JSON.parse(fs.readFileSync(DEV_CREDENTIALS_FILE, 'utf8'));
  } catch {
    // 首次运行，或文件损坏：重建一份。旧票据会失效，调用方会打印提示。
  }
  const keys = ['adminPassword', 'appRlsPassword', 'appAuthPassword', 'sessionSecret'];
  let created = false;
  for (const key of keys) {
    if (typeof saved[key] !== 'string' || saved[key].length < MIN_LENGTH) {
      saved[key] = randomSecret();
      created = true;
    }
  }
  if (created) {
    fs.writeFileSync(DEV_CREDENTIALS_FILE, `${JSON.stringify(saved, null, 2)}\n`, { mode: 0o600 });
  }
  return saved;
}

/**
 * 三个凭据的取值优先级：环境变量 > 本机持久化文件。
 *
 * 生产环境不要用这个函数去「兜底」——服务侧缺 `AI_SESSION_SECRET` /
 * `PGPASSWORD` 由 `config-check.js` 与网关 `config.js` 直接拦下，
 * 绝不能靠开发栈的随机值静默放行。
 *
 * @param {Record<string, string|undefined>} env
 * @returns {{adminPassword: string, appRlsPassword: string, appAuthPassword: string, sessionSecret: string, source: 'env'|'local'}}
 */
export function loadDevCredentials(env = process.env) {
  const fromEnv = {
    adminPassword: String(env.PG_ADMIN_PASSWORD ?? '').trim(),
    appRlsPassword: String(env.APP_RLS_PASSWORD ?? '').trim(),
    appAuthPassword: String(env.APP_AUTH_PASSWORD ?? '').trim(),
    sessionSecret: String(env.AI_SESSION_SECRET ?? '').trim(),
  };

  if (Object.values(fromEnv).every((value) => value !== '')) {
    return { ...fromEnv, source: 'env' };
  }

  const saved = localCredentials();
  return {
    adminPassword: fromEnv.adminPassword || saved.adminPassword,
    appRlsPassword: fromEnv.appRlsPassword || saved.appRlsPassword,
    appAuthPassword: fromEnv.appAuthPassword || saved.appAuthPassword,
    sessionSecret: fromEnv.sessionSecret || saved.sessionSecret,
    source: 'local',
  };
}
