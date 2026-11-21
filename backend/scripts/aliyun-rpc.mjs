#!/usr/bin/env node
/**
 * 阿里云 **RPC 风格** API 的最小客户端（HMAC-SHA1 签名，**零依赖**）。
 *
 * ── 为什么需要它 ────────────────────────────────────────────────────────────
 *
 * 部署链路上有一件事 `s` 做不了：给函数建那把「FC 访问 VPC 用的服务角色」。
 * 那是 **RAM** 的接口，而 `s` 只管 FC。为了它去装 `@alicloud/ram20150501`
 * 等于给一个一次性动作拖进一串依赖 —— 所以这里手写签名，只用 node crypto。
 *
 * ⚠️ RPC 风格 ≠ OSS 那套 REST 风格签名（本项目里 OSS 的 V4 签名在
 *    `serverless/data-service/lib/storage-oss.js`）。两者**不通用**：
 *    · RPC 把参数摊在 query/body 里，按 key 排序后连同 `&` 整串参与签名
 *    · StringToSign 固定三行：`POST` + `&%2F&` + percentEncode(参数串)
 *    · percentEncode 与 encodeURIComponent 不同：`+`→`%20`、`*`→`%2A`、`%7E`→`~`
 *    · 签名密钥是 `Secret + "&"`（注意那个 **&**，漏了就是恒定的 SignatureDoesNotMatch）
 *
 * ── 用法 ────────────────────────────────────────────────────────────────────
 *
 *     node serverless/scripts/aliyun-rpc.mjs ListRoles
 *     node serverless/scripts/aliyun-rpc.mjs GetRole RoleName=xxx
 *     node serverless/scripts/aliyun-rpc.mjs AttachPolicyToRole \
 *          PolicyType=System PolicyName=AliyunECSNetworkInterfaceManagementAccess RoleName=xxx
 *
 *     参数一律 `k=v`；值里可以有空格、JSON，交给 shell 加引号即可。
 *
 *     --alias=xxx      用 ~/.s/access.yaml 里的另一个别名（默认 default，
 *                      也就是 `s config add` 时用的那个）
 *     --endpoint=...   覆盖端点（默认 ram.aliyuncs.com）
 *     --version=...    覆盖 API 版本（默认按端点推导）
 *     --post           强制用 POST（参数很长时用，如 AssumeRolePolicyDocument）
 *
 * 凭证来源优先级：ALIYUN_AK/ALIYUN_SK 环境变量 > ~/.s/access.yaml。
 * **脚本从不打印 AK/SK**，只打印账号 ID 的后四位，够对上号就行。
 *
 * ⚠️ 本机带本地代理，但 node 的 fetch(undici) **默认不读** http_proxy ——
 *    所以这里不会踩 run-s.mjs 那个 400 的坑。真要显式走代理才需要别的处理。
 */
import { createHmac, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

// ── ① 读凭证 ────────────────────────────────────────────────────────────────

/** 从 `s` 的 access.yaml 里取某个别名的键值（只解析这一层，够用）。 */
function readSProfile(alias) {
  const file = process.env.S_ACCESS_FILE || join(homedir(), '.s', 'access.yaml');
  let raw;
  try {
    raw = readFileSync(file, 'utf8');
  } catch {
    return {};
  }
  const out = {};
  let inBlock = false;
  for (const line of raw.split(/\r?\n/)) {
    const top = line.match(/^([A-Za-z0-9_-]+):\s*$/);
    if (top) {
      inBlock = top[1] === alias;
      continue;
    }
    if (!inBlock) continue;
    const kv = line.match(/^\s+([A-Za-z_]+):\s*(.*)$/);
    if (kv) out[kv[1]] = kv[2].trim().replace(/^['"]|['"]$/g, '');
  }
  return out;
}

/**
 * ⚠️ 为什么**不能**自动把凭证从 `~/.s/access.yaml` 里读出来 —— 两条路都堵死（2026-09-24 实测）：
 *
 *   ① **文件里是密文。** `s config add` 默认把 AccessKeySecret 加密后落盘，
 *      特征是 `U2FsdGVkX1` 开头（CryptoJS 的 `Salted__`）。
 *      拿它去签名 → 阿里云回 `InvalidAccessKeyId: Specified access key is not
 *      found or invalid.` —— **看着像「AK 不存在」，其实是「SK 是密文」**，
 *      很容易往错的方向查。这是本项目最容易误判的那一类失败。
 *
 *   ② **`s config get` 借不到。** 它确实能解密，但**只在真实终端里输出明文**；
 *      一旦 stdout 被重定向或捕获（脚本里必然如此），它会把密钥**自动打码**成
 *      `Nh8****LdO`。所以「调 s 拿明文」这条路是死的 —— 别改回去。
 *
 * 结论：本脚本**只认环境变量**。用之前这样喂：
 *     ALIYUN_AK=xxx ALIYUN_SK=xxx node serverless/scripts/aliyun-rpc.mjs ListRoles
 *
 * （下面的 `readSProfile` 留着，是为了兼容「未加密存储的 access.yaml」和
 *   `S_ACCESS_FILE` 指向别处的情况；它读到密文时会在下面给出明确提示。）
 */
// （这段本来有个「调 s config get 取明文」的兜底，已删 —— 见上一段说明：它拿不到明文。）

// ── ② 签名（RPC 风格）───────────────────────────────────────────────────────

/**
 * ⚠️ 别用 encodeURIComponent 直接了事：它不转 `*`，且把 `~` 留着 —— 阿里云要的
 *    恰好相反（`~` 必须还原成字面量，其余按 RFC3986）。这三个替换就是全部区别。
 */
function percentEncode(s) {
  return encodeURIComponent(String(s))
    .replace(/\+/g, '%20')
    .replace(/\*/g, '%2A')
    .replace(/%7E/g, '~');
}

/** 已知端点的默认 API 版本。 */
const VERSIONS = {
  'ram.aliyuncs.com': '2015-05-01',
  'sts.aliyuncs.com': '2015-04-01',
  'fc.aliyuncs.com': '2023-03-30',
  'ecs.aliyuncs.com': '2014-05-26',
  'vpc.aliyuncs.com': '2016-04-28',
};

/**
 * 发一个 RPC 调用。
 * @returns {Promise<{status:number, body:any, raw:string}>}
 */
export async function rpcCall({
  action,
  params = {},
  ak,
  sk,
  endpoint = 'ram.aliyuncs.com',
  version,
  method = 'POST',
}) {
  const ver = version || VERSIONS[endpoint] || '2015-05-01';
  const all = {
    Format: 'JSON',
    Version: ver,
    AccessKeyId: ak,
    SignatureMethod: 'HMAC-SHA1',
    SignatureVersion: '1.0',
    SignatureNonce: randomUUID(),
    // ⚠️ 必须是 **UTC** 的 ISO，带 Z。用本地时间会得到 SignatureExpired，
    //    而报错文本看着像「密钥不对」。
    Timestamp: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
    Action: action,
    ...params,
  };
  // 空值不参与签名，也不发出去。
  for (const k of Object.keys(all)) {
    if (all[k] === undefined || all[k] === null || all[k] === '') delete all[k];
  }

  const canonical = Object.keys(all)
    .sort()
    .map((k) => `${percentEncode(k)}=${percentEncode(all[k])}`)
    .join('&');

  const stringToSign = `${method}&${percentEncode('/')}&${percentEncode(canonical)}`;
  // ⚠️ 密钥后面那个 `&` 是签名机制的一部分，不是笔误。
  const signature = createHmac('sha1', `${sk}&`).update(stringToSign, 'utf8').digest('base64');

  const url = `https://${endpoint}/`;
  const body = `${canonical}&Signature=${percentEncode(signature)}`;

  const res = await fetch(method === 'POST' ? url : `${url}?${body}`, {
    method,
    ...(method === 'POST'
      ? { headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body }
      : {}),
  });
  const raw = await res.text();
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    parsed = null;
  }
  return { status: res.status, body: parsed, raw };
}

// ── ③ CLI ───────────────────────────────────────────────────────────────────

function main() {
  const argv = process.argv.slice(2);
  if (argv.length === 0) {
    console.error('用法：node serverless/scripts/aliyun-rpc.mjs <Action> [k=v ...] [选项]');
    console.error('例：  node serverless/scripts/aliyun-rpc.mjs ListRoles');
    process.exit(1);
  }

  let alias = 'default';
  let endpoint = 'ram.aliyuncs.com';
  let version;
  let method = 'GET';
  const action = argv[0];
  const params = {};

  for (const a of argv.slice(1)) {
    const opt = a.match(/^--([a-zA-Z]+)=(.*)$/);
    if (opt) {
      if (opt[1] === 'alias') alias = opt[2];
      else if (opt[1] === 'endpoint') endpoint = opt[2];
      else if (opt[1] === 'version') version = opt[2];
      continue;
    }
    if (a === '--post') {
      method = 'POST';
      continue;
    }
    const kv = a.match(/^([A-Za-z0-9_.]+)=(.*)$/s);
    if (kv) params[kv[1]] = kv[2];
  }

  const profile = readSProfile(alias);
  const ak = process.env.ALIYUN_AK || profile.AccessKeyID;
  const sk = process.env.ALIYUN_SK || profile.AccessKeySecret;

  if (!ak || !sk) {
    console.error(`✗ 没拿到凭证（别名 ${alias}）。本脚本只认环境变量：`);
    console.error('    ALIYUN_AK=xxx ALIYUN_SK=xxx node serverless/scripts/aliyun-rpc.mjs ListRoles');
    process.exit(1);
  }
  // ⚠️ 这条拦得越早越好：密文会让阿里云回 `InvalidAccessKeyId`，
  //    读起来像「AK 不存在」，实际是「SK 是密文」—— 本项目最容易误判的一类。
  if (sk.startsWith('U2FsdGVkX1')) {
    console.error('✗ SK 拿到的是**密文**（access.yaml 里存的是加密后的值），不是明文。');
    console.error('  它的表现是阿里云回 `InvalidAccessKeyId: Specified access key is not');
    console.error('  found or invalid.` —— 看着像「AK 不存在」，别往那个方向查。');
    console.error('  改喂环境变量：ALIYUN_AK=xxx ALIYUN_SK=xxx node serverless/scripts/aliyun-rpc.mjs ...');
    process.exit(1);
  }

  // 只露后四位，够确认「用的是哪把」而不泄漏。
  // ⚠️ AccountID 也要判一下：access.yaml 里连它都是加密的，直接打印会得到
  //    一长串 `U2FsdGVkX1…` 密文 —— 那看起来像「账号 ID 很怪」，其实是没解出。
  const tail = ak.slice(-4);
  const acct = profile.AccountID && !profile.AccountID.startsWith('U2FsdGVkX1')
    ? profile.AccountID
    : '未解出（文件里是加密存储）';
  console.log(`▸ 凭证：…${tail}（别名 ${alias}，账号 ${acct}）`);
  console.log(`▸ 调用：${endpoint} ${action} ${method}\n`);

  rpcCall({ action, params, ak, sk, endpoint, version, method })
    .then((r) => {
      console.log(`HTTP ${r.status}`);
      if (r.body) console.log(JSON.stringify(r.body, null, 2));
      else console.log(r.raw);
      process.exit(r.status >= 200 && r.status < 300 ? 0 : 1);
    })
    .catch((e) => {
      console.error(`✗ 请求失败：${e.message}`);
      process.exit(1);
    });
}

// ⚠️ 别手工拼 `file://` + argv[1] 来比：Windows 上 import.meta.url 是
//    `file:///D:/...`（三个斜杠），手工拼出来的是两个 → 恒不相等 → CLI **静默不执行**。
if (import.meta.url === pathToFileURL(process.argv[1]).href) main();
