import { createHash, createHmac } from 'node:crypto';

/**
 * 火山引擎 TOS 的 V4 预签名 URL。
 *
 * ## 为什么自己实现而不是引 SDK
 *
 * 网关是**零依赖**的：它跑在 Serverless 上，装依赖意味着冷启动变大、
 * 供应链多一个面、平台升级 Node 时要跟着调。而预签名只用到了
 * `createHash` / `createHmac` 两个标准库函数。
 *
 * ## 与官方示例的关系（重要，别照抄文档里的哈希做断言）
 *
 * 官方文档里两个示例**互相矛盾**：同一份「包含签名到 Authorization 头」的
 * 示例，参数表写区域是 `tos-ap-southeast-1`，Authorization 里却写 `20220322`
 * （而请求时间是 `20220101`）；「预签名 URL」示例的参数表写
 * `tos-ap-southeast-1`，规范化查询串里却是 `ap-southeast-1`。
 * 拿这些哈希做断言只会得到「实现明明对、测试却红」。
 *
 * 所以本模块的**唯一权威是文档里的构造公式**，不是示例数值。
 * 想验证真伪只有一条路：用真凭证跑 `scripts/verify-tos.mjs`
 * （真实 PUT 一次、再 GET 一次）。代码不需要凭证就能测，对错由线上判。
 *
 * ## 公式（照抄文档，不做「优化」）
 *
 * ```
 * CanonicalRequest =
 *   HTTPMethod + '\n' + CanonicalURI + '\n' + CanonicalQueryString + '\n' +
 *   CanonicalHeaders + '\n' + SignedHeaders + '\n' + HashedPayload
 * StringToSign = 'TOS4-HMAC-SHA256' + '\n' + RequestDate + '\n' +
 *   CredentialScope + '\n' + HexEncode(Hash(CanonicalRequest))
 * kSigning = HMAC(HMAC(HMAC(HMAC(sk, Date), Region), 'tos'), 'request')
 * Signature = HexEncode(HMAC(kSigning, StringToSign))
 * ```
 *
 * 注意 `CanonicalHeaders` 自身以 `\n` 结尾，公式又在它后面拼一个 `\n`，
 * 所以**头部块与 SignedHeaders 之间本来就有一个空行**。
 * 这不是笔误 —— 少一个 `\n` 服务端就会 403。
 */

const ALGORITHM = 'TOS4-HMAC-SHA256';
const SERVICE = 'tos';

/**
 * 两种文档对有效期上限的说法不一致（火山引擎写 30 天，BytePlus 写 7 天）。
 * 取**更严的**那个：无论部署在哪个区域都不会被拒。
 */
const MAX_EXPIRES_SECONDS = 604800;

/**
 * RFC3986 编码。
 *
 * 不能直接用 `encodeURIComponent`：它不编码 `!'()*` 五个字符，
 * 而 TOS 要求它们也编码。差一个字符就是签名不匹配，
 * 而这种错在本地完全看不出来（只有真凭证才会暴露）。
 */
export function uriEncode(value) {
  return encodeURIComponent(String(value)).replace(
    /[!'()*]/g,
    (char) => `%${char.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

/** 路径编码：保留 `/` 作为分隔符，逐段编码。 */
function encodePath(objectKey) {
  const trimmed = String(objectKey).replace(/^\/+/, '');
  if (trimmed === '') return '/';
  return `/${trimmed.split('/').map(uriEncode).join('/')}`;
}

/** 从 endpoint 推出纯主机名，并补上桶名前缀。 */
export function resolveHost(bucket, endpoint) {
  const raw = String(endpoint ?? '').trim();
  if (raw === '') throw new Error('resolveHost: endpoint 不能为空');
  const withoutScheme = raw.replace(/^https?:\/\//, '').replace(/\/+$/, '');
  const hostOnly = withoutScheme.split('/')[0];
  // 允许两种写法：`tos-cn-beijing.volces.com`（推荐，代码补桶名）
  // 或已经带桶名的 `mybucket.tos-cn-beijing.volces.com`（原样用）。
  if (hostOnly.startsWith(`${bucket}.`)) return hostOnly;
  return `${bucket}.${hostOnly}`;
}

/** 按 TOS 要求格式化时间：`yyyyMMddTHHmmssZ`（UTC）。 */
export function formatTimestamp(epochMs) {
  const iso = new Date(epochMs).toISOString();
  // 2022-01-01T00:00:00.000Z -> 20220101T000000Z
  return `${iso.slice(0, 10).replaceAll('-', '')}T${iso.slice(11, 19).replaceAll(':', '')}Z`;
}

function deriveSigningKey({ secret, date, region }) {
  const hmac = (key, data) =>
    createHmac('sha256', key).update(data, 'utf8').digest();
  const kDate = hmac(secret, date);
  const kRegion = hmac(kDate, region);
  const kService = hmac(kRegion, SERVICE);
  return hmac(kService, 'request');
}

/**
 * 生成一个预签名 URL。
 *
 * @param {object} options
 * @param {'GET'|'PUT'|'DELETE'|'HEAD'} [options.method]
 * @param {string} options.bucket
 * @param {string} options.region
 * @param {string} options.endpoint
 * @param {string} options.objectKey
 * @param {string} options.accessKeyId
 * @param {string} options.accessKeySecret
 * @param {string} [options.securityToken] 临时 AK/SK（STS）时必填
 * @param {number} options.expiresSeconds
 * @param {number} [options.now] 便于测试注入时间
 * @returns {{url: string, host: string, objectKey: string, expiresAt: number}}
 */
export function buildPresignedUrl({
  method = 'GET',
  bucket,
  region,
  endpoint,
  objectKey,
  accessKeyId,
  accessKeySecret,
  securityToken = '',
  expiresSeconds,
  now = Date.now(),
}) {
  for (const [name, value] of Object.entries({
    bucket,
    region,
    endpoint,
    objectKey,
    accessKeyId,
    accessKeySecret,
  })) {
    if (value === undefined || value === null || String(value) === '') {
      throw new Error(`buildPresignedUrl: ${name} 不能为空`);
    }
  }

  const expires = Math.min(
    Math.max(Math.trunc(expiresSeconds ?? 600), 1),
    MAX_EXPIRES_SECONDS,
  );

  const httpMethod = String(method).toUpperCase();
  const host = resolveHost(bucket, endpoint);
  const timestamp = formatTimestamp(now);
  const date = timestamp.slice(0, 8);
  const credentialScope = `${date}/${region}/${SERVICE}/request`;

  // 规范化查询串：参数按编码后的 ASCII 排序，**不含 X-Tos-Signature**。
  const queryParams = [
    ['X-Tos-Algorithm', ALGORITHM],
    ['X-Tos-Credential', `${accessKeyId}/${credentialScope}`],
    ['X-Tos-Date', timestamp],
    ['X-Tos-Expires', String(expires)],
    ...(securityToken === ''
      ? []
      : [['X-Tos-Security-Token', securityToken]]),
    ['X-Tos-SignedHeaders', 'host'],
  ];
  const canonicalQuery = queryParams
    .map(([key, value]) => [uriEncode(key), uriEncode(value)])
    .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
    .map(([key, value]) => `${key}=${value}`)
    .join('&');

  // 只签 host：预签名 URL 由浏览器/客户端直接使用，
  // 我们无法保证它在 PUT 时会带上哪些额外头。把 Content-Type 也签进去
  // 会让「客户端换了 MIME 推断结果」直接变成 403 —— 而这个差异
  // 在 iOS/Android/浏览器三端并不一致。
  const canonicalHeaders = `host:${host}\n`;
  const signedHeaders = 'host';
  // 预签名时请求内容未知，用 UNSIGNED-PAYLOAD 代替载荷哈希。
  const payloadHash = 'UNSIGNED-PAYLOAD';

  const canonicalRequest = [
    httpMethod,
    encodePath(objectKey),
    canonicalQuery,
    canonicalHeaders,
    signedHeaders,
    payloadHash,
  ].join('\n');

  const stringToSign = [
    ALGORITHM,
    timestamp,
    credentialScope,
    createHash('sha256').update(canonicalRequest, 'utf8').digest('hex'),
  ].join('\n');

  const signature = createHmac(
    'sha256',
    deriveSigningKey({ secret: accessKeySecret, date, region }),
  )
    .update(stringToSign, 'utf8')
    .digest('hex');

  const queryString = [...queryParams, ['X-Tos-Signature', signature]]
    .map(([key, value]) => [uriEncode(key), uriEncode(value)])
    .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
    .map(([key, value]) => `${key}=${value}`)
    .join('&');

  return {
    url: `https://${host}${encodePath(objectKey)}?${queryString}`,
    host,
    objectKey,
    expiresAt: now + expires * 1000,
    // 暴露中间量供测试与排查使用。签名不匹配时，第一个要问的就是
    // 「规范化请求到底长什么样」，而线上你只能拿到 URL。
    debug: { canonicalRequest, stringToSign, credentialScope, timestamp },
  };
}

/**
 * 从配置判断 TOS 是否可用。
 *
 * 只检查「配齐了没」，不做任何网络探测 —— 配置错会在第一次上传时
 * 以 403 的形式暴露，那比网关自检更接近真实。
 */
export function tosReady(config) {
  const tos = config?.upload?.tos ?? {};
  return (
    String(tos.bucket ?? '') !== ''
    && String(tos.accessKeyId ?? '') !== ''
    && String(tos.accessKeySecret ?? '') !== ''
  );
}
