import { createHash, createHmac } from 'node:crypto';

import { ApiError, ErrorCodes } from '../../shared/errors.js';
import { buildStorageKey, isServerImageKey } from './imagestore.js';
import { extensionFor, validateUpload } from './attachments.js';

/**
 * 作业照片的字节存储（**阿里云 OSS 实现**）。
 *
 * 与 `imagestore.js`（文件系统版）**接口逐字相同**，所以调用方（`routes/homework.js`、
 * 冷启动自检）一行都不用改 —— 换后端只是换一个 `IMAGE_DRIVER` 的值。
 *
 * ## 为什么需要它
 *
 * 文件系统版只在「有一块持久磁盘」的部署上成立。函数计算（FC）**没有持久磁盘**：
 * 实例回收后文件就没了，而且多实例之间不共享 —— 症状是「上传成功、过一会儿图没了」，
 * 或者「家长在另一台设备上永远看不到图」，两者都不报错。
 *
 * ## ⚠️ 必须用 V4 签名，V1 已经被禁用
 *
 * OSS 的 V1 签名（`Authorization: OSS <AK>:<sig>`，HMAC-SHA1）**不可用**了：
 * - 2025-03-01 起，**新注册用户**无法使用 V1 签名
 * - 2025-09-01 起，**新创建的 Bucket** 无法使用 V1 签名
 *
 * 所以任何按老文档写的 V1 实现，在**新账号 + 新桶**上会 100% 失败，
 * 而且失败信息是 `SignatureDoesNotMatch` —— 看起来像 AccessKey 填错了，
 * 排查方向会先走到「去控制台重新生成一下 Key」。本模块只用 V4。
 *
 * ## 为什么手写签名而不是装 SDK
 *
 * 本服务目前只依赖 `pg` 一个包。官方 `ali-oss` SDK 会拖进一整棵依赖树，
 * 冷启动和包体都要付代价 —— 而我们只需要 PUT 和 GET 两个操作。
 *
 * 代价是**签名的正确性得自己保证**。做法是：把签名拆成纯函数，
 * 并用官方文档给出的那份完整算例（固定 AK/SK/时间/对象，连期望的 SigningKey 和
 * Signature 都印在文档上）做**逐段对照**。见 `test/oss-imagestore.test.js` ——
 * 三条断言里任意一条跑红，说明实现与官方算法已经不一致了。
 *
 * ⚠️ 但要说清楚：**算对了不等于线上能过**。签名最终对不对只有 OSS 说了算，
 * 所以还留了 `scripts/probe-oss.mjs`，用真凭证打一次真实请求。
 *
 * ## 桶必须是私有的
 *
 * 图片字节里是学生的作业本，而键里含 `studentId`。公共读等于把
 * 「猜别人家孩子的照片」变成一件只需知道 uuid 的事，与多家庭隔离的模型冲突。
 * 所以本模块**总是带签名读**，绝不依赖公开访问。
 */

// ===== V4 签名（纯函数，独立可测） =====

/**
 * URI 编码：不编码 `A-Za-z0-9` 与 `-_.~`，其余按字节大写十六进制转义。
 *
 * `encodeURIComponent` 恰好放行 `!'()*` 这五个字符，而规范里它们是**要编码**的。
 * 我们的键只含 `[0-9a-zA-Z/._-]`，实际碰到它们的概率为零 —— 但
 * 「实际不会发生」不能当作正确性前提，否则将来换键格式就会静默踩到。
 */
export function uriEncode(value) {
  return encodeURIComponent(String(value))
    .replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
}

/** 路径编码：**斜杠不编码**（它是路径分隔符，编码了就变成另一个对象名）。 */
function encodePath(path) {
  return String(path).split('/').map(uriEncode).join('/');
}

/** `YYYYMMDDTHHMMSSZ`（ISO 8601，UTC）。签名有效期 15 分钟，所以时钟别偏。 */
export function iso8601Utc(epochMs) {
  return new Date(epochMs).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
}

/**
 * 一个头是否参与签名。
 *
 * 规则照抄官方 SDK（`_is_sign_header`）：所有 `x-oss-*`、`content-type`、
 * `content-md5`，以及显式点名要签的。
 *
 * ⚠️ **`host` 不在其中** —— 这与 AWS SigV4 不同（AWS 必签 host）。
 * 把 host 也签进来会得到 `SignatureDoesNotMatch`，且看不出哪里错了。
 */
function isSignedHeader(lowerName, additionalHeaders) {
  if (lowerName.startsWith('x-oss-')) return true;
  if (lowerName === 'content-type' || lowerName === 'content-md5') return true;
  return additionalHeaders.includes(lowerName);
}

/**
 * 规范请求（CanonicalRequest）。
 *
 * ```
 * HTTPVerb \n CanonicalURI \n CanonicalQueryString \n
 * CanonicalHeaders \n AdditionalHeaders \n HashedPayload
 * ```
 *
 * `CanonicalHeaders` 自己**每一行都以 `\n` 结尾**，所以拼进去之后
 * 它和 `AdditionalHeaders` 之间会自然出现一个空行 —— 这正是规范要的，
 * 不是多写了一个换行。
 *
 * ⚠️ `CanonicalURI` **必须带 bucket**（`/bucket/key`），不管请求 URL 用的是
 * 虚拟主机风格还是路径风格。这是 OSS 与 AWS 的又一处差异。
 */
export function buildCanonicalRequest({ method, bucket, key, headers, additionalHeaders = [] }) {
  const signed = Object.entries(headers)
    .map(([k, v]) => [k.toLowerCase(), String(v).trim()])
    .filter(([k]) => isSignedHeader(k, additionalHeaders))
    .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));

  const canonicalHeaders = signed.map(([k, v]) => `${k}:${v}\n`).join('');

  return {
    canonicalRequest: [
      method,
      encodePath(`/${bucket}/${key}`),
      '', // 查询串：本模块只用无参数的读写接口
      canonicalHeaders,
      additionalHeaders.join(';'),
      'UNSIGNED-PAYLOAD', // 目前只支持这一个值
    ].join('\n'),
    signedHeaderNames: signed.map(([k]) => k),
  };
}

/** 签名密钥：四层 HMAC 链，起点是 `"aliyun_v4" + AccessKeySecret`。 */
export function deriveSigningKey({ accessKeySecret, date, region, product = 'oss' }) {
  const hmac = (key, data) => createHmac('sha256', key).update(data, 'utf8').digest();
  return hmac(
    hmac(hmac(hmac(`aliyun_v4${accessKeySecret}`, date), region), product),
    'aliyun_v4_request',
  );
}

/**
 * 给一次请求签名，返回**可以直接发出去的全部头**。
 *
 * 设计要点：调用方交进来的是「打算发送的头」，本函数补上必须的
 * `x-oss-date` / `x-oss-content-sha256`，并按**实际发送的内容**挑选签名头。
 * 这样就消除了「签名的头」与「发送的头」不一致这一整类 bug ——
 * 那种不一致的表现是 `SignatureDoesNotMatch`，而人只会去怀疑 AccessKey。
 */
export function signRequest({
  method,
  bucket,
  key,
  headers = {},
  additionalHeaders = [],
  accessKeyId,
  accessKeySecret,
  region,
  timestamp,
  product = 'oss',
}) {
  if (!accessKeyId || !accessKeySecret) throw new Error('OSS 凭证未配置');
  if (!region) throw new Error('OSS_REGION 未配置');

  const stamp = timestamp ?? iso8601Utc(Date.now());
  const date = stamp.slice(0, 8);
  const scope = `${date}/${region}/${product}/aliyun_v4_request`;

  const allHeaders = {
    ...headers,
    'x-oss-date': stamp,
    'x-oss-content-sha256': 'UNSIGNED-PAYLOAD',
  };

  // 可选头里，剔除「本来就要签的」和「值不存在的」——与官方 SDK 的
  // _common_additional_headers 一致。否则 AdditionalHeaders 会列出一些
  // 不参与签名的名字，签名立刻不匹配。
  const effectiveAdditional = [...new Set(additionalHeaders.map((h) => String(h).toLowerCase()))]
    .filter((h) => !isSignedHeader(h, []))
    .filter((h) => String(headers[h] ?? '') !== '')
    .sort();

  const { canonicalRequest } = buildCanonicalRequest({
    method,
    bucket,
    key,
    headers: allHeaders,
    additionalHeaders: effectiveAdditional,
  });

  const stringToSign = [
    'OSS4-HMAC-SHA256',
    stamp,
    scope,
    createHash('sha256').update(canonicalRequest, 'utf8').digest('hex'),
  ].join('\n');

  const signingKey = deriveSigningKey({ accessKeySecret, date, region, product });
  const signature = createHmac('sha256', signingKey).update(stringToSign, 'utf8').digest('hex');

  let authorization = `OSS4-HMAC-SHA256 Credential=${accessKeyId}/${scope}`;
  // 没有可选头时**整段省略**（官方 SDK 就是 if len > 0 才拼）。
  // 写成 `AdditionalHeaders=` 空值也能过，但那是另一种形状，没必要。
  if (effectiveAdditional.length > 0) {
    authorization += `,AdditionalHeaders=${effectiveAdditional.join(';')}`;
  }
  authorization += `,Signature=${signature}`;

  return {
    headers: { ...allHeaders, authorization },
    authorization,
    // 下面三样是**给排查用的**：OSS 在签名失败时也会回显它的版本，
    // 逐段对比就能定位分歧在哪一步。测试也直接断言它们。
    canonicalRequest,
    stringToSign,
    signingKeyHex: signingKey.toString('hex'),
    scope,
    timestamp: stamp,
  };
}

// ===== 存储后端 =====

const PROBE_TIMEOUT_MS = 3000;

/**
 * OSS V4 **头部签名**允许的时钟偏移窗口（秒）。
 *
 * ⚠️ 这个值**不是我们设的**，是 OSS 服务端的行为：`x-oss-date` 与它的当前时间
 * 相差超过这个窗口就判 `RequestTimeTooSkewed`。所以它只用来**回显给客户端**
 * 「这份直传凭证大概还能用多久」，改它不会让凭证真的变长或变短。
 *
 * 它对本功能是够的：100MB 在 200KB/s 的弱网上传约 8.5 分钟（客户端直传
 * 超时给到 12 分钟，仍在窗口内）。
 * 但**它意味着慢到 15 分钟以上的上传会中途失败** —— 那种失败无法靠重试
 * 补救（凭证本身就过期了），只能重新签一次。所以客户端拿到
 * `RequestTimeTooSkewed`/403 时要**重新申请凭证**，而不是原地重试。
 */
const OSS_V4_CLOCK_WINDOW_SECONDS = 900;

/**
 * 把 OSS 的错误码翻译成**该去做什么**。
 *
 * 这一段是刻意的：`SignatureDoesNotMatch` / `NoSuchBucket` / `AccessDenied`
 * 在运维眼里长得很像（都是「照片传不上去」），但处置完全不同。
 * 让人只看错误信息就知道该动哪个开关，是这里唯一的目的。
 */
export function explainOssFailure({ code, status }) {
  switch (code) {
    case 'NoSuchBucket':
      return '桶不存在 —— 检查 OSS_BUCKET 拼写，以及 OSS_REGION 与桶所在区域是否一致；桶建在别的区域时这里同样是 404';
    case 'SignatureDoesNotMatch':
      return '签名不匹配 —— OSS_ACCESS_KEY_ID / OSS_ACCESS_KEY_SECRET 不对，或服务端时钟偏差超过 15 分钟';
    case 'InvalidAccessKeyId':
      return 'AccessKeyId 不存在或已被删除';
    case 'AccessDenied':
      return '权限不足 —— 该 AccessKey 没有被授权访问这个桶。生产请用只授予该桶 PutObject/GetObject 的 RAM 子账号，不要用主账号';
    case 'RequestTimeTooSkewed':
      return '请求时间与 OSS 相差过大 —— 检查服务器时钟';
    default:
      return `对象存储回了 ${status}${code ? `（${code}）` : ''}`;
  }
}

/**
 * 把「访问域名」归一化成裸 host，并做两项**结构事实**检查。
 *
 * ## 为什么需要它
 *
 * OSS 控制台给的 Endpoint 是**带协议的完整 URL**
 * （`https://oss-cn-hangzhou.aliyuncs.com`），而本模块要的是**裸 host**：
 * 协议由本模块自己拼，且 **host 不参与签名**（★ 与 AWS 相反，见文件头）。
 *
 * 使用者的现实就是「照控制台复制粘贴」。不处理的话，host 会被拼成
 * `mybucket.https://oss-...` ，而 `fetch` 抛的是 `Failed to parse URL`
 * —— **那句话完全指不出是哪个配置错了**，排查方向会先跑到桶名上。
 *
 * 所以这里把「带协议」和「带尾斜杠」当**正常输入**收下，并返回一条
 * `note` 说明做了什么（**不静默**）。
 *
 * ## 宽容到此为止
 *
 * 以下三种是**真填错了**，返回 `error` 点名（不抛 —— 缺配置都不拖死服务，
 * 填错更不该；由 `assertReady` / 冷启动自检如实报出）：
 *
 * - 带路径：`https://oss-...-internal.aliyuncs.com/abc`
 * - bucket 域名：`https://mybucket.oss-cn-hangzhou.aliyuncs.com`
 *   —— 会拼成 `mybucket.mybucket.oss-...`，症状是 `NoSuchBucket`，
 *   **看着像桶名拼错**。
 * - **域名里的区域 ≠ `OSS_REGION`**：签名按 `OSS_REGION` 算、请求却打到域名
 *   里那个区域，服务端回 403 —— 而它和「RAM 权限没给对」长得一模一样。
 *   （2026-09-24 差点真踩：控制台给的域名在杭州，而配置里 region 写的是北京。）
 *
 * @param {string} region `OSS_REGION`，用来判定它与域名里的区域是否一致
 * @returns {{ host: string, note: string, error: string }}
 */
function normalizeHost(endpoint, bucket, region) {
  const raw = String(endpoint ?? '').trim();
  const rg = String(region ?? '').trim();
  const none = { host: '', note: '', error: '' };
  if (raw === '') return none;

  const strippedScheme = /^https?:\/\//i.test(raw);
  const strippedSlash = /\/+$/.test(raw);
  const h = raw.replace(/^https?:\/\//i, '').replace(/\/+$/, '');

  if (h.includes('/')) {
    return {
      ...none,
      error:
        `OSS_ENDPOINT 填的是带路径的 URL（${raw}）。这里要的是**纯域名**，` +
        '例如 oss-cn-hangzhou.aliyuncs.com',
    };
  }
  if (bucket !== '' && h.startsWith(`${bucket}.`)) {
    return {
      ...none,
      error:
        `OSS_ENDPOINT 填的是 bucket 域名（${raw}）。只填域名部分即可 —— ` +
        `桶名由 OSS_BUCKET 单独提供，否则会拼成 ${bucket}.${h}`,
    };
  }

  // 只判 `oss-<region>[-internal].aliyuncs.com` 这个形态；自定义域名（CNAME）
  // 里的区域推不出来，跳过 —— 不能因为判不了就报错。
  const m = /^oss-(cn-[a-z-]+?)(?:-internal)?\.aliyuncs\.com$/.exec(h);
  if (m && rg !== '' && m[1] !== rg) {
    return {
      ...none,
      error:
        `OSS_ENDPOINT 的域名在 ${m[1]}，而 OSS_REGION 写的是 ${rg} —— 两者必须同区。` +
        `签名按 OSS_REGION 算、请求却打到 ${m[1]}，服务端会回 403` +
        '（看着像 RAM 权限没给对，于是排查会先跑到控制台去重发密钥）',
    };
  }

  const note =
    strippedScheme || strippedSlash
      ? `${raw} 里的协议/尾斜杠已自动去掉（这里要的是纯域名）`
      : '';
  return { host: h, note, error: '' };
}

/**
 * @param {object} options
 * @param {string} options.bucket 桶名
 * @param {string} options.region 区域 ID，如 `cn-hangzhou`。**参与签名**，填错必失败
 * @param {string} [options.endpoint] 访问域名。默认 `oss-<region>.aliyuncs.com`；
 *   函数计算/ECS 与桶同区域时用 `oss-<region>-internal.aliyuncs.com`（走内网，省流量费）
 * @param {string} options.accessKeyId
 * @param {string} options.accessKeySecret
 * @param {string} [options.prefix] 键前缀，便于同一个桶里区分多套环境
 * @param {Map<string, number>|Record<string, number>} [options.maxBytesByKind]
 *        **按附件类型分别**的字节上限（`{ image, audio, video }`）。缺省取
 *        `attachments.js` 的 `DEFAULT_MAX_BYTES`。取一个数字管所有类型是不行的：
 *        照片 8MB 与视频 100MB 不是同一个量级。可以传一个 `Map`，
 *        也可以是普通对象。
 * @param {() => number} [options.now] 便于测试注入时间
 * @param {typeof fetch} [options.fetchImpl] 便于测试注入
 */
export function createOssImageStore({
  bucket,
  region,
  endpoint,
  accessKeyId,
  accessKeySecret,
  prefix = '',
  maxBytesByKind,
  now = () => Date.now(),
  fetchImpl = globalThis.fetch,
}) {
  const b = String(bucket ?? '').trim();
  const r = String(region ?? '').trim();
  const ak = String(accessKeyId ?? '').trim();
  const sk = String(accessKeySecret ?? '').trim();
  // 归一化 + 区域一致性见 normalizeHost 的说明：控制台给的是带协议的完整 URL，
  // 这里要裸 host；且域名里的区域必须与 OSS_REGION 一致，否则签名对不上。
  const ep = normalizeHost(endpoint, b, r);
  const host = ep.host || (r === '' ? '' : `oss-${r}.aliyuncs.com`);
  const prefixSeg = String(prefix ?? '').replace(/^\/+|\/+$/g, '');

  const missing = [
    b === '' && 'OSS_BUCKET',
    r === '' && 'OSS_REGION',
    ak === '' && 'OSS_ACCESS_KEY_ID',
    sk === '' && 'OSS_ACCESS_KEY_SECRET',
  ].filter(Boolean);
  // endpoint 填错也算「没就绪」—— 它的后果与缺值一样（照片功能全废），
  // 但**修法不同**，所以两者在 assertReady 里分开报。
  const ready = missing.length === 0 && ep.error === '';
  const root = `oss://${b}${prefixSeg === '' ? '' : `/${prefixSeg}`}`;

  /** 加前缀。**前缀在键之外**：数据库里存的仍是不带前缀的相对键。 */
  const keyOf = (storageKey) => (prefixSeg === '' ? storageKey : `${prefixSeg}/${storageKey}`);

  function assertConfigured() {
    // 正常情况下调用方（路由层）已经用 `ready` 挡住了，走到这里说明接线漏了。
    if (ep.error) throw new Error(ep.error);
    if (!ready) throw new Error(`对象存储未配置（缺 ${missing.join('、')}）`);
  }

  /**
   * 一次真实请求。返回 `{ ok, status, code, requestId, bytes? }`。
   *
   * 失败时**不抛异常** —— 由调用方按 `code` 决定这是「照片没了」还是
   * 「配置错了」。这两种必须分开（见 get 的说明）。
   */
  async function request(method, storageKey, body, { mimeType, timeoutMs } = {}) {
    const headers = {};
    // content-type 会被签名，所以必须在发送前就定下来 —— 由本函数统一加，
    // 保证「签的」和「发的」是同一个值。
    // content-length 刻意**不显式设置**：交给运行时算，避免与之冲突；
    // 它不在签名头里，所以不影响签名。
    if (mimeType) headers['content-type'] = mimeType;

    const signed = signRequest({
      method,
      bucket: b,
      key: keyOf(storageKey),
      headers,
      accessKeyId: ak,
      accessKeySecret: sk,
      region: r,
      timestamp: iso8601Utc(now()),
    });

    const controller = typeof AbortController === 'function' ? new AbortController() : null;
    const timer = timeoutMs && controller ? setTimeout(() => controller.abort(), timeoutMs) : null;
    let res;
    try {
      res = await fetchImpl(`https://${b}.${host}/${encodePath(keyOf(storageKey))}`, {
        method,
        headers: signed.headers,
        body,
        signal: controller?.signal,
      });
    } finally {
      if (timer) clearTimeout(timer);
    }

    const requestId = res.headers?.get?.('x-oss-request-id') ?? '';

    if (!res.ok) {
      // 错误时是 XML。`Code` 才是判据（HTTP 状态码会撞：两种不同的 404）。
      const text = await res.text().catch(() => '');
      return {
        ok: false,
        status: res.status,
        code: /<Code>([^<]+)<\/Code>/.exec(text)?.[1] ?? '',
        requestId,
      };
    }

    return {
      ok: true,
      status: res.status,
      requestId,
      bytes: res.arrayBuffer ? Buffer.from(await res.arrayBuffer()) : undefined,
    };
  }

  /** 配置类故障（不是「照片丢了」）—— 让它长得就像服务端故障，别伪装成 404。 */
  function backendFault(result, storageKey) {
    return new ApiError(
      ErrorCodes.internal,
      `照片存储后端访问失败：${explainOssFailure(result)}`
        + (result.requestId ? `（RequestId ${result.requestId}，凭它可在 OSS 侧查这条请求）` : ''),
      {
        status: 500,
        details: {
          // ⚠️ 与 not_on_server / file_missing **不同的 reason**：
          // 那两个是「照片的问题」，这个是「配置的问题」。
          reason: 'storage_backend_error',
          ossCode: result.code,
          storageKey,
        },
      },
    );
  }

  return {
    ready,
    root,
    maxBytesByKind,
    assertReady,

    /**
     * 上传一批字节，返回相对键。
     *
     * 与文件系统版不同：这里**天然是原子的** —— 对象存储没有「写到一半的可见文件」，
     * 一个键要么完全是旧内容，要么完全是新内容。所以不需要 `.tmp` + rename 那一套。
     */
    async put({ studentId, bytes, mimeType }) {
      assertConfigured();
      const { kind, mime, ext } = validateUpload({ bytes, mimeType, maxBytesByKind });
      const storageKey = buildStorageKey({ studentId, ext, epochMs: now() });

      const res = await request('PUT', storageKey, bytes, { mimeType: mime });
      if (!res.ok) throw backendFault(res, storageKey);

      return { storageKey, byteSize: bytes.length, mimeType: mime, kind };
    },

    /**
     * 签一个**客户端直传**的位置（大文件专用）。
     *
     * ## 为什么必须存在这条路
     *
     * 视频最大 100MB，而 `POST /data/homework/images/upload` 的字节是**穿过函数
     * 请求体**的 —— 那条路的上限是平台给的（本地 `dev-server` 实测 12MB，
     * 且平台还会把二进制标成 base64 再解一遍），100MB 根本过不去。
     * 而且让函数替客户端转一手 100MB 字节，是在为一个与业务无关的动作
     * 付执行时长与内存的钱。
     *
     * 所以大文件不走函数：**服务端只签名，客户端直接 PUT 到对象存储**。
     *
     * ## ⚠️ 这里返回的是「签好的头」，不是一条预签名 URL
     *
     * OSS 的 V4 预签名 URL 要把签名放进取值串（`x-oss-signature=` 等五个
     * query 参数），它的 CanonicalQueryString 规则与头部签名**不是同一套** ——
     * 而本项目的头部签名（`signRequest`）是**已经在生产上跑通的**
     * （照片上传走的就是它）。
     *
     * 所以这里刻意**复用那一条已验证的路径**：把 `x-oss-date`、
     * `x-oss-content-sha256`、`authorization` 三个头交给客户端原样发送。
     * 两者的授权强度是**相同**的 —— `authorization` 里只有 AccessKeyId 和
     * 签名，没有 Secret；而签名覆盖了 method + bucket + key，
     * 所以它只对**这一个对象**有效，且受 OSS 的 15 分钟时钟窗约束。
     *
     * 相比新写一套 query 签名：新代码写错的表现是 `SignatureDoesNotMatch`，
     * 而那个错误看起来像「AccessKey 填错了」，会把排查带偏到控制台去。
     * 复用已验证的路径不会引入这一类风险。
     *
     * ## ⚠️ 浏览器直传需要桶侧 CORS
     *
     * 原生 App 直传不发 `Origin`，不受影响；**Web 端**需要桶上配一条
     * 允许来源 PUT 的 CORS 规则 —— 这一步在控制台做，代码里没有开关。
     * 没配的表现是浏览器里 `Failed to fetch` 且**服务端日志一条都没有**
     * （与 `doc/DETAIL.md` 里 B24 那条跨域预检的形状一样）。
     *
     * ## 与「先传字节再写行」的关系
     *
     * 直传只解决**字节怎么过去**。行的写入仍然是之后的
     * `POST /data/homework/images`（客户端把这里给的 `storageKey` 交回来）。
     *
     * @returns {{storageKey: string, uploadUrl: string, headers: object, expiresIn: number, maxBytes: number}|null}
     *          文件系统后端返回 `null`（它没有可直传的 HTTP 端点）
     */
    signDirectPut({ studentId, mimeType, maxBytes }) {
      if (!ready) return null;
      const mime = String(mimeType ?? '').toLowerCase();
      const ext = extensionFor(mime);
      if (ext === '') return null;

      const storageKey = buildStorageKey({ studentId, ext, epochMs: now() });
      const objectKey = keyOf(storageKey);

      const signed = signRequest({
        method: 'PUT',
        bucket: b,
        key: objectKey,
        headers: { 'content-type': mime },
        region: r,
        accessKeyId: ak,
        accessKeySecret: sk,
        timestamp: iso8601Utc(now()),
      });

      // 只回**客户端必须原样发送**的那几个头。多给无害，但少一个就是签名不匹配，
      // 所以这里直接把 signRequest 产出的整份头发回去 —— 由它决定发什么，
      // 不在这里挑挑选选（挑错一个的表现仍是 SignatureDoesNotMatch）。
      // ⚠️ 桶名必须在**子域**上（虚拟主机风格：`https://<bucket>.<host>/<key>`），
      //    与 `request()` 里发出的形状逐字相同。
      //    漏掉桶名会拼成 `https://<host>/<key>` —— 那在 OSS 眼里是**路径风格**，
      //    于是它把 key 的第一段（`20261003`）当成桶名，回
      //    `NoSuchBucket: The specified bucket does not exist`，
      //    而 `<BucketName>` 里赫然写着那个日期目录。这个错误看起来像
      //    「桶名配错了」，与签名毫无关系 —— 定位它靠的是**真发一次请求**
      //    （2026-10-03 实测抓到，本地怎么看都是对的）。
      return {
        storageKey,
        uploadUrl: `https://${b}.${host}/${encodePath(objectKey)}`,
        headers: signed.headers,
        expiresIn: OSS_V4_CLOCK_WINDOW_SECONDS,
        maxBytes,
      };
    },

    /**
     * 签一个**客户端直读**的位置（大附件专用）。
     *
     * ## 为什么必须存在这条路（与上传侧的原因不同）
     *
     * 上传侧撞的是**请求体**上限，这里撞的是**响应体**上限：函数计算的
     * 响应体上限是 32 MiB，超了回 `{"Code":"ResponseTooLarge"}` 400 ——
     * 而视频上限是 100 MB。于是「传得上去」与「取得回来」两个口径对不上：
     * 超过 32 MiB 的视频会**传成功、之后永远播不了**，且全程不报错。
     *
     * 2026-10-03 用 `scripts/probe-readback-ceiling.mjs` 实测（走的就是
     * App 真正用的那条 `GET /data/homework/images/file?id=`）：
     * 11,475,812 B 通（sha256 一致）、52,428,800 B 400 `ResponseTooLarge`。
     * 修法就是这一条：让字节**不再穿过函数**。
     *
     * ## 与 signDirectPut 同一条路：还是「签好的头」，不是预签名 URL
     *
     * 理由与 signDirectPut 的长注释逐字相同 —— V4 的**查询串签名**与头部签名
     * 不是同一套规则，而头部签名是**已经在生产上跑通的**那条。多写一套的
     * 代价不是多几行，而是多一种 `SignatureDoesNotMatch`（看起来像密钥配错）。
     *
     * 读这边还多一个不选查询串签名的理由：**Range 不在签名头里**
     * （见 `isSignedHeader`），所以播放器每一次分段请求都带着同一份
     * `authorization` 也能过 —— 视频拖动进度正是靠它。换成 URL 里的签名，
     * 每个不同的查询串都要重签一次。
     *
     * ## ⚠️ 有效期只有 15 分钟
     *
     * `x-oss-date` 是**签发时刻**，OSS 只认它 ±15 分钟（见
     * `OSS_V4_CLOCK_WINDOW_SECONDS`）。100MB 在 200KB/s 上约 8.5 分钟，够用；
     * 但**慢到 15 分钟以上的播放会中途 403**，而那种失败靠重试救不回来
     * （凭证本身过期了），只能重新签一次。所以 `expiresIn` 要如实回给客户端。
     *
     * @param {string} storageKey 数据库里那一列的**相对键**（不带前缀）
     * @returns {{readUrl: string, headers: object, expiresIn: number}|null}
     *          未就绪、或键不是服务端键（旧版设备本地标识）时返回 `null`
     */
    signDirectGet(storageKey) {
      if (!ready) return null;
      // 旧版设备本地标识（绝对路径 / localStorage 键）在对象存储里**没有对应对象**。
      // 签一个必然 404 的地址等于把「回退本地读」这条正路堵死，所以如实回 null。
      if (!isServerImageKey(storageKey)) return null;

      const objectKey = keyOf(storageKey);
      // ⚠️ 不传任何 content-* 头：GET 没有请求体，而 `content-type` / `content-md5`
      //    是**参与签名**的（见 isSignedHeader）—— 凭空塞一个进去，客户端就得
      //    原样再发一遍，多一个「签的」与「发的」不一致的机会。
      const signed = signRequest({
        method: 'GET',
        bucket: b,
        key: objectKey,
        headers: {},
        region: r,
        accessKeyId: ak,
        accessKeySecret: sk,
        timestamp: iso8601Utc(now()),
      });

      // 桶名必须在**子域**上（虚拟主机风格），与 request() / signDirectPut 逐字相同。
      // ⚠️ 漏掉桶名会变成路径风格，OSS 会把键的第一段当桶名回 `NoSuchBucket`
      //    （见 signDirectPut 里那段实测记录）。
      return {
        readUrl: `https://${b}.${host}/${encodePath(objectKey)}`,
        headers: signed.headers,
        expiresIn: OSS_V4_CLOCK_WINDOW_SECONDS,
      };
    },

    /**
     * 按相对键读回字节。
     *
     * 三种失败**必须分清**（症状可能一样，处置完全不同）：
     * - `not_on_server`：旧版设备本地标识，字节只在那台设备上 → 客户端回退本地读
     * - `file_missing`：键是服务端的、东西真没了 → 如实报不可用
     * - `storage_backend_error`：桶名/区域/凭证/权限配错了 → 修配置，**不要**提示用户重传
     *
     * ⚠️ 最后一种最容易写错：`NoSuchBucket` 和 `NoSuchKey` **都是 404**。
     * 只看状态码的话，「桶名拼错了」会表现成「照片被清理了」，
     * 于是所有人去查清理策略，而真实原因是环境变量。所以这里必须读 `Code`。
     */
    async get(storageKey) {
      assertConfigured();
      if (!isServerImageKey(storageKey)) {
        throw new ApiError(
          ErrorCodes.notFound,
          '该照片的字节不在服务端（这是旧版设备本地标识，字节只在当初那台设备上）',
          { status: 404, details: { reason: 'not_on_server', storageKey } },
        );
      }

      const res = await request('GET', storageKey, null);
      if (res.ok) return res.bytes;
      if (res.status === 404 && res.code === 'NoSuchKey') {
        throw new ApiError(
          ErrorCodes.notFound,
          '照片文件不存在（对象存储里没有这个键，可能已被清理）',
          { status: 404, details: { reason: 'file_missing', storageKey } },
        );
      }
      throw backendFault(res, storageKey);
    },
  };

  /**
   * 启动自检：**连一次真请求**。
   *
   * 与文件系统版「建个文件试试」的目标不同，这里能顺带验证三件事：
   * 桶在不在、凭证对不对、**签名算法有没有写对**。
   * 签名错了必须在这里暴露 —— 否则它会以「学生拍完照点提交失败」的形式
   * 出现在线上，而那时人不会怀疑签名。
   *
   * 探测方式：GET 一个必然不存在的键，**期望 404 + NoSuchKey**。
   * 这个「期望失败」的判据比 HEAD 强：HEAD 没有响应体，读不到错误码，
   * 于是两种 404 又分不开了。
   */
  async function assertReady() {
    // endpoint 填错先报：它的诊断信息更具体，被「缺 X」盖住就没用了。
    if (ep.error) return { ok: false, reason: ep.error };
    if (!ready) return { ok: false, reason: `对象存储未配置（缺 ${missing.join('、')}）` };
    if (typeof fetchImpl !== 'function') {
      return { ok: false, reason: '当前运行时没有 fetch，无法访问对象存储' };
    }

    try {
      const probeKey = `${prefixSeg === '' ? '' : `${prefixSeg}/`}__cold-start-probe__`;
      const res = await request('GET', probeKey, null, { timeoutMs: PROBE_TIMEOUT_MS });

      if (res.ok) {
        // 不影响使用，只是说明桶里有这么个对象 —— 值得知道，但不是故障。
        return {
          ok: true,
          root,
          note: [ep.note, '冷启动探测对象竟已存在（非故障，仅提示）'].filter(Boolean).join('；'),
        };
      }
      if (res.status === 404 && res.code === 'NoSuchKey') {
        // ← 这正是我们要的：签名对、桶在、只是对象不存在。
        return ep.note === '' ? { ok: true, root } : { ok: true, root, note: ep.note };
      }
      return { ok: false, reason: explainOssFailure(res) };
    } catch (e) {
      const why = e?.name === 'AbortError' ? `超时（${PROBE_TIMEOUT_MS}ms 内没响应）` : e.message;
      return { ok: false, reason: `连不上对象存储：${why}` };
    }
  }
}
