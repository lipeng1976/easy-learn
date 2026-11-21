#!/usr/bin/env node
/**
 * 跑 `s`（Serverless Devs）的包装器 —— 把两个「不告诉你真正原因」的坑堵在一处。
 *
 * ── 为什么需要它 ────────────────────────────────────────────────────────────
 *
 * ① **代理**（本轮实测踩到，最难查的一个）
 *    本机 / WorkBuddy 这类带本地服务代理的环境会设
 *    `http_proxy=https_proxy=http://127.0.0.1:<port>`。
 *    `s` 拉取 component 时会把**完整的 https URL 当成路径**发给那个代理，
 *    代理回 `400 Client sent an HTTP request to an HTTPS server.`
 *    —— 而 `s` 只显示 `Request failed with status code 400`，`--debug` 也不打响应体。
 *    表现：任何子命令都 400（连只读的 `s info` 也一样），2 秒内失败，
 *    `~/.s/components/` 里什么都没有。**看起来像配置写错了，其实是代理。**
 *    ⚠️ 这与 Flutter 在本机踩的是**同一个坑**（`flutter` 也必须先清代理变量）。
 *
 * ② **环境变量**
 *    `s.yaml` 里全是 `${env('X')}`，必须先灌进 shell。漏了会报
 *    `env('X') not found`（这个反倒能看出原因，不用猜）。
 *
 * ── 用法 ────────────────────────────────────────────────────────────────────
 *
 *     node serverless/scripts/run-s.mjs deploy
 *     node serverless/scripts/run-s.mjs deploy --debug
 *     node serverless/scripts/run-s.mjs info
 *     node serverless/scripts/run-s.mjs deploy --sniff     # 出问题时看真实响应体
 *
 *     ENV_FILE=.env.local  node serverless/scripts/run-s.mjs deploy
 *     S_BIN=/path/to/s     node serverless/scripts/run-s.mjs deploy
 *
 * `--sniff` 会注入 `net-sniff.cjs`，把状态码 ≥400 的**响应体**打到 stderr。
 * 只在 `s` 的报错信息不够用时才需要它。
 */
import { spawnSync } from 'node:child_process';
import { closeSync, existsSync, openSync, readFileSync, unlinkSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { loadEnv } from '../data-service/scripts/lib/env-file.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../..');
const WIN = process.platform === 'win32';

/** 这些一律不带进子进程 —— 留下任何一个都可能让 s 得到那个看不懂的 400。 */
const PROXY_KEYS = [
  'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY',
  'http_proxy', 'https_proxy', 'all_proxy',
  'NO_PROXY', 'no_proxy',
];

const argv = process.argv.slice(2);
if (argv.length === 0) {
  console.error('用法：node serverless/scripts/run-s.mjs <deploy|info|remove|...> [--sniff] [s 的参数...]');
  process.exit(1);
}
const sniff = argv.includes('--sniff');
const pass = argv.filter((a) => a !== '--sniff');

// ── ① 载入环境变量（.env.prod 是唯一真值处）─────────────────────────────────
const envFile = process.env.ENV_FILE || '.env.prod';
const envPath = resolve(ROOT, envFile);
if (!existsSync(envPath)) {
  console.error(`✗ 找不到环境文件：${envPath}`);
  console.error('  它是 s.yaml 里所有 ${env(...)} 的取值来源，必须先有。');
  process.exit(1);
}
const { env, count } = loadEnv(envPath);

// ── ② 组装子进程环境：文件的值覆盖 shell，然后**清掉代理** ──────────────────
const childEnv = { ...process.env, ...env };
const stripped = PROXY_KEYS.filter((k) => childEnv[k]);
for (const k of PROXY_KEYS) delete childEnv[k];

if (sniff) {
  const requirePath = join(HERE, 'net-sniff.cjs');
  childEnv.NODE_OPTIONS = `${childEnv.NODE_OPTIONS || ''} --require ${requirePath}`.trim();
}

// ── ③ 找 s：显式指定 > PATH > 本环境的隔离安装 ─────────────────────────────
const managed = join(homedir(), '.workbuddy/binaries/node/workspace/node_modules/.bin/s.cmd');
function onPath(name) {
  // ⚠️ stdio:'ignore'：本机**建管道**会失败（CreateFile failed 231 / EBUSY），
  //    而探测用的形态必须与真调用一致才不作假 —— 这里用不到管道就别建。
  const r = spawnSync(WIN ? 'where' : 'which', [name], { stdio: 'ignore' });
  return r.status === 0;
}
let bin;
if (process.env.S_BIN) bin = process.env.S_BIN;
else if (onPath('s')) bin = 's';
else if (WIN && existsSync(managed)) bin = managed;
else {
  console.error('✗ 找不到 s（Serverless Devs）。');
  console.error('  PATH 里没有；也没有本环境的隔离安装。装法二选一：');
  console.error('    npm i -g @serverless-devs/s          # 全局（推荐）');
  console.error('    或用 S_BIN=/绝对/路径/s 指定');
  process.exit(1);
}

// ── ④ deploy 前确认暂存树在（缺了会传一个**旧包**上去，而平台照样报成功）────
if (pass[0] === 'deploy' && !pass.includes('-t')) {
  const missing = ['build/deploy/data-service-code', 'build/deploy/ai-gateway-code']
    .filter((d) => !existsSync(resolve(ROOT, d)));
  if (missing.length > 0) {
    console.error(`✗ 部署暂存目录不存在：${missing.join('、')}`);
    console.error('  先跑：node serverless/deploy-prepare.mjs');
    process.exit(1);
  }
}

// ── ⑤ 把做的事说出来（静默的包装器会变成新的排查障碍）─────────────────────
console.log(`▸ 环境：${envFile}（${count} 个键）`);
console.log(stripped.length > 0
  ? `▸ 已清掉 ${stripped.length} 个代理变量：${stripped.join(', ')}`
  : '▸ 没有代理变量要清');
console.log(`▸ s：${bin}`);
if (sniff) console.log('▸ 已开启响应体嗅探（--sniff）');
console.log(`▸ 执行：s ${pass.join(' ')}\n`);

// ── ⑥ 回显脱敏（2026-09-26 新增，起因是一次真实的泄露）─────────────────────
// `s deploy` 成功后会**把整个 environmentVariables 明文回显**（PG 口令、OSS AK/SK、
// ARK_API_KEY、AI_SESSION_SECRET …）。原来 `stdio:'inherit'` 直接透传，于是
// 「顺手 `> build/_logs/xxx.log` 留个证据」就等于把生产密钥写进磁盘；贴进聊天更是一贴一个准。
// 改成：子进程写临时文件 → 打码 → 再写回 stdout（stderr 一并保住）。
// ⚠️ 不能用 `stdio:'pipe'` 抓输出：本机建管道会失败（CreateFile failed 231 / EBUSY）
//    —— 上面 onPath() 用 `'ignore'` 是同一个原因。fd 中转绕开它。
// ⚠️ 保留前 4 位：既不泄露，又能核对「这个键到底有没有配」。别改成整值抹掉 ——
//    那样「配了个空串」和「配对了」在回显里长得一样。
const SECRET_KEYS = [
  'PGPASSWORD', 'PG_AUTH_PASSWORD', 'PG_OPS_PASSWORD', 'PGHOST',
  'OSS_ACCESS_KEY_ID', 'OSS_ACCESS_KEY_SECRET',
  'ARK_API_KEY', 'BAILIAN_API_KEY', 'AI_SESSION_SECRET', 'AI_METRICS_TOKEN', 'AI_KV_TOKEN', 'AI_KV_URL',
];

/**
 * ⚠️ 名单是**按厂商名写死**的，所以「名单漏一个 = 密钥泄一次」——2026-10-01 真栽过：
 *    厂商从 `ARK_*` 切到 `BAILIAN_*` 之后，`BAILIAN_API_KEY` 在回显里是**明文**
 *    （同一份输出里 `ARK_API_KEY` 却是 `ark-***MASKED***`，看着像已经脱敏好了）。
 *    这不是「忘了加一行」，而是**判据形态错了**：它跟着厂商走，而厂商是会换的。
 *
 *    所以再加一条**与厂商无关**的判据：键名里出现 `KEY` / `SECRET` / `TOKEN` /
 *    `PASSWORD` 词段就脱敏。以后新接一家厂商，靠这一条兜住，不靠有人记得来加名单。
 *    （名单仍保留：`PGHOST` / `AI_KV_URL` 这类不含敏感词段、但约定要打码的靠它。）
 */
const SECRET_NAME_RE = /(?:^|_)(?:KEY|SECRET|TOKEN|PASSWORD|PWD)(?:_|$)/;

/** 给 `NAME: value` 的值打码；顺手剥掉 ANSI 颜色码（重定向进文件时它们只是噪声）。 */
function maskSecrets(text) {
  let s = text.replace(/\x1b\[[0-9;]*m/g, '');
  // 逐行看「缩进 + 键名 + 冒号 + 值」的形状：命中任一条判据就打码。
  // ⚠️ 保留前 4 位：既不泄露，又能核对「这个键到底有没有配」——
  //    整值抹掉的话，「配了个空串」和「配对了」在回显里长得一样。
  s = s.replace(
    /^([ \t]*)([A-Za-z0-9_]+)(:[ \t]*)(\S+)/gm,
    (m, indent, name, sep, value) => {
      if (!SECRET_KEYS.includes(name) && !SECRET_NAME_RE.test(name)) return m;
      return `${indent}${name}${sep}${value.slice(0, 4)}***MASKED***`;
    },
  );
  return s;
}

const tmpLog = join(tmpdir(), `run-s-${process.pid}.log`);
let outFd = null;
try {
  outFd = openSync(tmpLog, 'w');
} catch {
  outFd = null; // 开不了就退回直通：**不因为「脱敏」这件事本身把部署弄挂**
}

let r;
try {
  r = outFd === null
    ? spawnSync(bin, pass, { stdio: 'inherit', cwd: ROOT, env: childEnv, shell: WIN })
    : spawnSync(bin, pass, { stdio: ['inherit', outFd, outFd], cwd: ROOT, env: childEnv, shell: WIN });
} finally {
  if (outFd !== null) closeSync(outFd);
}

if (outFd === null) {
  console.error('⚠️ 未能建立脱敏中转，本次是**原样透传** —— 回显里可能含生产密钥，别落盘别外发。');
} else {
  try {
    process.stdout.write(maskSecrets(readFileSync(tmpLog, 'utf8')));
    try { unlinkSync(tmpLog); } catch { /* 删不掉不影响本次结果 */ }
  } catch {
    console.error(`⚠️ 回显脱敏失败 —— 原始输出留在 ${tmpLog}，**里面是明文密钥**，看完请删。`);
  }
}

process.exit(r.status ?? 1);
