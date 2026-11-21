/**
 * ima 开放 API 封装（数据服务侧）。
 *
 * ## 这个文件解决什么问题
 *
 * 把「学习资料（错题 / 打卡 / 教学资料）沉淀到 ima 知识库」这件事收口成一组
 * **可单测、可注入**的函数。所有网络调用都通过 `fetchImpl`（默认 `globalThis.fetch`）
 * 走，测试里换成一个假 fetch 就能不碰真网络跑完整链路 —— 这正是项目反复强调的
 * 「剥离出可测函数」。
 *
 * ## 两条铁律（来自 2026-10-26 实测，错一次就是 403）
 *
 * 1. **建库 / 建文件夹是程序化的**：`create_knowledge_base` / `create_folder` 真实存在，
 *    不是「只能手动」。多家庭、多学生独立知识库的设计就建立在这两条 API 上。
 * 2. **COS 上传必须用旧版 SHA1 签名**（见 [buildCosSha1Authorization]）：手写腾讯云
 *    TC3 签名会拿 `403 AccessDenied`，而且它**不是** `SignatureDoesNotMatch`，
 *    极易被误当成「权限没给对」而一头扎进 RAM 控制台 —— 其实只是签名算法选错。
 *    token 走 `x-cos-security-token`，**不参与签名**。
 *
 * ## 多租户隔离
 *
 * 每个学生一个独立 KB（库名带学号），KB 内三个固定文件夹（错题档案 / 打卡档案 /
 * 教学资料）。`search_knowledge` 是**库级**检索，所以隔离靠「分库」而非「分文件夹」。
 *
 * ## 同步是可选的（opt-in）
 *
 * `shouldSync()` 只看 `ima_status === 'active'`。非 active（包括 `unconnected`，
 * 即家庭根本没连 ima）时，所有写入**静默跳过**——核心功能（错题复习 / 打卡）
 * 完全不受 ima 是否连接的影响。详见 `doc/ima-integration-design.md`。
 */

import crypto from 'node:crypto';
import {
  ApiError,
  ErrorCodes,
  imaAuthFailed,
  imaRequestFailed,
  imaUnavailable,
} from '../../shared/errors.js';

/** ima 公网地址（任何手机 / 服务端直接可达，不需要家里局域网）。 */
export const IMA_BASE_URL = 'https://ima.qq.com';

/** KB 内三个固定文件夹的规范名（建库时一次性建好，之后只往里塞内容）。 */
export const IMA_FOLDER_NAMES = {
  mistake: '错题档案',
  checkin: '打卡档案',
  teaching: '教学资料',
};

/**
 * `check_repeated_names` / `add_knowledge` 的 `media_type`（媒体类型枚举）。
 *
 * ⚠️ **`create_media` 根本没有这个字段**。它要的是 `content_type` + `file_ext`；
 * 往它身上塞 `media_type`（不管 1 还是 7）都会稳定返回
 * `220001 invalid media_type` —— 打卡 / 错题**从未真正推得进 ima 库**（库一直是空的）。
 *
 * 2026-10-28 按官方契约改正：`create_media` 传 `content_type` / `file_ext`，
 * `media_type` 只保留在重名检查与 `add_knowledge` 两处。
 * 之前那版「把 1 改成 7」修的是**字段值**，而错的是**字段本身**，所以照样 220001。
 *
 * 官方 MediaType 枚举（按扩展名给）：1=PDF 3=Word 4=PPT 5=Excel
 * 7=MarkDown 9=图片 11=笔记 13=TXT。本工程只上传 markdown，故固定 7。
 */
export const IMA_MEDIA_TYPE_MARKDOWN = 7;

/**
 * 文件夹条目。
 *
 * 目录树是靠 `media_type` 区分「这是不是一个文件夹」的 —— 名字里带不带
 * 「/」都不可靠（用户的文件夹名可以随便起）。读成 URL 或者反过来，
 * 症状是「目录里明明有东西，扫出来永远是空的」。
 */
export const IMA_MEDIA_TYPE_FOLDER = 99;

/** 同步状态枚举。与 `doc/ima-integration-design.md` §2 一致。 */
export const IMA_STATUS = {
  UNCONNECTED: 'unconnected', // 默认：未连接 / 无账号
  ACTIVE: 'active', // 已连接可用
  EXPIRED: 'expired', // 密钥失效待重连
};

/**
 * 同步守卫：只有 `active` 才允许写入 ima。
 *
 * 这是「ima 同步可选」的总开关。返回 false 时，上层应当**直接跳过、不报错、
 * 不阻断主流程**——数据留在本地 PG 即可。
 */
export function shouldSync(imaStatus) {
  return imaStatus === IMA_STATUS.ACTIVE;
}

/**
 * 低层：调用一个 ima OpenAPI 端点。
 *
 * 统一带 `ima-openapi-clientid` / `ima-openapi-apikey` 两个头，POST + JSON。
 * 状态码映射成有语义的错误码（见 shared/errors.js）：
 *   · 401 / 403 → imaAuthFailed（凭证问题，不可重试，提示家长重连）；
 *   · ≥ 500     → imaUnavailable（可重试，客户端降级到本地）；
 *   · 其余 4xx  → imaRequestFailed（请求本身的问题）。
 */
/**
 * 识别 ima 的「HTTP 200 + 业务错误码」。
 *
 * ima 的失败有两种表达：
 *   ① HTTP 4xx/5xx —— [imaFetch] 已按状态码分类；
 *   ② **HTTP 200，body 里带非 0 的 `code` / `retcode`** —— 它的常规失败方式。
 *
 * 只认第一种的后果是：业务失败被当成成功，调用方接着去读 `data.xxx`，
 * 读到 undefined，然后报出「未返回 xxx」—— 真正的错误信息（errmsg）
 * 就丢在这一跳里。家长端看到的就成了一句无从下手的「未返回 id」。
 *
 * 字段名两份官方资料不一致（一份 `code`、一份 `retcode`），两个都认；
 * 非 0 一律视为失败，**不做「某些码算成功」的猜测** —— 猜错的代价是
 * 把一次失败悄悄当成成功，那比多报一次错贵得多。
 */
function detectBusinessError(json, path) {
  if (!json || typeof json !== 'object') return null;
  const code = json.code ?? json.retcode;
  if (code === undefined || code === null) return null;
  if (String(code) === '0') return null;
  const message = json.errmsg ?? json.message ?? json.msg ?? '';
  return imaRequestFailed(
    `ima 拒绝请求（${path}）：${code}${message ? ` ${message}` : ''}`,
    { imaCode: code, imaMessage: message },
  );
}

export async function imaFetch({
  clientId,
  apiKey,
  fetchImpl = globalThis.fetch,
  method = 'POST',
  path,
  body,
  timeoutMs = 15000,
}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchImpl(`${IMA_BASE_URL}${path}`, {
      method,
      headers: {
        'Content-Type': 'application/json',
        'ima-openapi-clientid': clientId,
        'ima-openapi-apikey': apiKey,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: controller.signal,
    });
    const text = await res.text();
    let json;
    try {
      json = text ? JSON.parse(text) : {};
    } catch {
      json = { raw: text };
    }
    if (!res.ok) {
      if (res.status === 401 || res.status === 403) {
        throw imaAuthFailed(`${res.status} ${text.slice(0, 200)}`);
      }
      if (res.status >= 500) {
        throw imaUnavailable(`ima 暂时不可用（${res.status}）`);
      }
      throw imaRequestFailed(`ima 请求失败（${res.status}）：${text.slice(0, 200)}`);
    }
    // HTTP 200 不等于成功：业务错误码在这里拦下来，否则会被上层
    // 读成「字段缺失」，把真正的 errmsg 吞掉。
    const business = detectBusinessError(json, path);
    if (business) throw business;
    return json;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * 构造 COS PUT Object 的 SHA1 签名（Authorization 头）。
 *
 * 这是 2026-10-26 用官方 `cos-upload.cjs` 复刻出来的算法，**只签 `content-length`
 * 和 `host` 两个头，token 走 `x-cos-security-token` 不参与签名**。TestCase：
 * 手写 TC3 签名 + 把 token 放进签名 → `403 AccessDenied`（且不是
 * `SignatureDoesNotMatch`，极易误判）。
 *
 * 抽成纯函数是为了能单测——签名错是「看着像权限问题、实则算法选错」那一类，
 * 必须有一个不碰网络就能验证的判据。
 */
export function buildCosSha1Authorization({
  secretId,
  secretKey,
  method,
  pathname,
  contentLength,
  host,
  startTime,
  expiredTime,
}) {
  const keyTime = `${startTime};${expiredTime}`;
  const signKey = crypto.createHmac('sha1', secretKey).update(keyTime).digest('hex');

  const headerKeys = ['content-length', 'host'];
  const httpHeaders = headerKeys
    .map((k) => `${k}=${encodeURIComponent(k === 'content-length' ? contentLength : host)}`)
    .join('&');
  const httpString = `${method.toLowerCase()}\n${pathname}\n\n${httpHeaders}\n`;

  const stringToSign = `sha1\n${keyTime}\n${crypto.createHash('sha1').update(httpString).digest('hex')}\n`;
  const signature = crypto.createHmac('sha1', signKey).update(stringToSign).digest('hex');

  return [
    'q-sign-algorithm=sha1',
    `q-ak=${secretId}`,
    `q-sign-time=${keyTime}`,
    `q-key-time=${keyTime}`,
    `q-header-list=${headerKeys.join(';')}`,
    'q-url-param-list=',
    `q-signature=${signature}`,
  ].join('&');
}

/**
 * 从 `create_media` 的返回里尽量宽容地取出 COS 凭证（字段名以 PoC 实测为准）。
 *
 * 官方 `Credential` 结构用的是 `bucket_name` / `cos_key`；早期自己猜测写的是
 * `bucket` / `object_key`。两种写法都认，否则会在「上传 COS」那一步因 `bucket`
 * 为空直接抛「凭证不完整」—— 表现跟 `media_type` 错一样，是「字段名猜错」类的
 * 静默失败。同理 `token` 也兼容 COS 标准的 `security_token`。
 */
function extractCosCredentials(data) {
  if (!data) return {};
  // ⚠️ 真返回的凭证**嵌在 `data.cos_credential` 下**，不是平铺在 `data` 上：
  //   data = { media_id, cos_credential: { secret_id, secret_key, token,
  //            start_time, expired_time, appid, bucket_name, region, cos_key } }
  // 直接读 `data.secret_id` 会拿到一串 undefined，然后在 uploadToCos 里
  // 抛「COS 凭证不完整」——又一个对着自己假设验证、真接口前才炸的例子。
  const c = data.cos_credential ?? data;
  return {
    secretId: c.secret_id ?? c.secretId,
    secretKey: c.secret_key ?? c.secretKey,
    token: c.token ?? c.security_token ?? c.x_cos_security_token,
    bucket: c.bucket_name ?? c.bucket,
    region: c.region,
  };
}

/**
 * 把一段内容 PUT 到 COS（已拿到 `create_media` 返回的凭证后调用）。
 *
 * 只认 SHA1 签名（见 [buildCosSha1Authorization]）。403 一律按「签名错」报，
 * 不再顺着 `AccessDenied` 去查 RAM——那是一条已知的死路。
 */
export async function uploadToCos({
  cosCredentials,
  cosKey,
  content,
  contentType = 'application/octet-stream',
  fetchImpl = globalThis.fetch,
  timeoutMs = 60000,
}) {
  const { secretId, secretKey, token, bucket, region } = cosCredentials ?? {};
  if (!secretId || !secretKey || !token || !bucket || !region || !cosKey) {
    throw imaRequestFailed('create_media 返回的 COS 凭证不完整，无法上传');
  }
  const host = `${bucket}.cos.${region}.myqcloud.com`;
  const pathname = `/${cosKey}`;
  const length = Buffer.isBuffer(content) ? content.length : Buffer.byteLength(content);

  const nowSec = Math.floor(Date.now() / 1000);
  const authorization = buildCosSha1Authorization({
    secretId,
    secretKey,
    method: 'PUT',
    pathname,
    contentLength: String(length),
    host,
    startTime: nowSec,
    expiredTime: nowSec + 3600,
  });

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchImpl(`https://${host}${pathname}`, {
      method: 'PUT',
      headers: {
        'Content-Type': contentType,
        'Content-Length': String(length),
        Authorization: authorization,
        'x-cos-security-token': token,
      },
      body: content,
      signal: controller.signal,
    });
    if (res.status < 200 || res.status >= 300) {
      const txt = await res.text().catch(() => '');
      if (res.status === 403) {
        throw imaRequestFailed(`COS 上传被拒（403，多半是签名错）：${txt.slice(0, 200)}`);
      }
      throw imaRequestFailed(`COS 上传失败（${res.status}）：${txt.slice(0, 200)}`);
    }
  } finally {
    clearTimeout(timer);
  }
}

/**
 * 依次取第一个非空的 id 候选值。
 *
 * ## 为什么要这么写
 *
 * ima 各端点返回的 id 字段名**并不统一**，而且同一条端点在两份官方文档里
 * 写法都不一样（`create_knowledge_base` 的返例是 `data.knowledge_base_id`，
 * 另一份速查写 `{id, name}`；`search_knowledge_base` 的条目一份写 `kb_id`、
 * 一份写 `id`）。按单一字段名读，读不到时只能报「未返回 id」——
 * 那句话把真正的原因（字段名猜错 / 业务错误）全吞了，线上表现为
 * 家长点一次连接失败一次，日志里却只有 502。
 *
 * 所以策略是：**优先按官方返例的字段，其余常见别名兜底**；
 * 全都取不到时才报错，并把**实际返回的键名**写进错误里。
 */
function pickId(...candidates) {
  for (const value of candidates) {
    if (typeof value === 'string' && value.trim() !== '') return value;
    if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  }
  return undefined;
}

/** 按名称搜知识库（幂等建库前先查是否已建过）。 */
export async function searchKnowledgeBase({ clientId, apiKey, fetchImpl, query, limit = 20 }) {
  return imaFetch({
    clientId,
    apiKey,
    fetchImpl,
    path: '/openapi/wiki/v1/search_knowledge_base',
    body: { query, query_user: true, cursor: '', limit },
  });
}

/** 建知识库（不可逆，一生一次）。type 1001=个人 / 1002=共享。 */
export async function createKnowledgeBase({
  clientId,
  apiKey,
  fetchImpl,
  name,
  description = '',
  type = 1001,
}) {
  const json = await imaFetch({
    clientId,
    apiKey,
    fetchImpl,
    path: '/openapi/wiki/v1/create_knowledge_base',
    body: { name, description, type },
  });
  const data = json.data ?? json;
  // 官方返例：`{"code":0,"data":{"knowledge_base_id":"yeVqEg7…"}}`
  // —— 是 `knowledge_base_id`，不是 `id`。读错字段的后果不是「报错」而是
  // 「每次连接都失败」，所以这里三种写法都认。
  const id = pickId(data?.knowledge_base_id, data?.kb_id, data?.id);
  if (!id) {
    const keys = data && typeof data === 'object' ? Object.keys(data) : [];
    throw imaRequestFailed(
      'create_knowledge_base 未返回 id'
        + `（实际返回字段：${keys.length > 0 ? keys.join(' / ') : '空'}）`,
      { returnedKeys: keys },
    );
  }
  return { id, name: data.name ?? name };
}

/** 浏览某 KB（或某文件夹）下的条目，用于判断文件夹是否已存在。 */
export async function getKnowledgeList({
  clientId, apiKey, fetchImpl, kbId, folderId = '', cursor = '', limit = 50,
}) {
  return imaFetch({
    clientId,
    apiKey,
    fetchImpl,
    path: '/openapi/wiki/v1/get_knowledge_list',
    // `cursor` 与 `limit` 是**必填**（首次传空串游标）。漏了它们不是「用默认值」，
    // 而是参数校验失败 —— 而失败若又被当成「列表为空」，就会每次连接都
    // 重复建一遍三个文件夹（建库不可逆，文件夹也会越堆越多）。
    body: {
      knowledge_base_id: kbId,
      folder_id: folderId || undefined,
      cursor,
      limit,
    },
  });
}

/**
 * 取某条目的**下载地址**。
 *
 * 返回的 `url` 带短期签名（`t=` 之类），**必须立刻用**：放几分钟再下
 * 要么 403 要么空 body。所以不要把 url 缓存起来、也不要先落库再下载。
 *
 * ## 为什么返回整个 `url_info` 而不是只返回 url
 *
 * 下载需要额外带 6 个 `X-IMA-*` 头（签名、trace、uid 哈希…）。只把 url
 * 传出去，调用方一定会「裸 fetch」，而 ima 的 COS 对缺头的请求不是回 403，
 * 是**直接断开连接**（`UND_ERR_SOCKET`）—— 看着像网络不稳定，其实是缺头。
 */
export async function getMediaInfo({ clientId, apiKey, fetchImpl, kbId, mediaId }) {
  const json = await imaFetch({
    clientId,
    apiKey,
    fetchImpl,
    path: '/openapi/wiki/v1/get_media_info',
    body: { knowledge_base_id: kbId, media_id: mediaId },
  });
  const data = json.data ?? json;
  const urlInfo = data?.url_info ?? data?.urlInfo ?? null;
  if (!urlInfo?.url) {
    const keys = data && typeof data === 'object' ? Object.keys(data) : [];
    throw imaRequestFailed(
      'get_media_info 未返回下载地址'
        + `（实际返回字段：${keys.length > 0 ? keys.join(' / ') : '空'}）`,
      { returnedKeys: keys },
    );
  }
  return {
    url: String(urlInfo.url),
    headers: urlInfo.headers && typeof urlInfo.headers === 'object' ? urlInfo.headers : {},
  };
}

/**
 * 下载一个条目的原始字节（当前用于把 md 书取回服务端切课）。
 *
 * [maxBytes] 是硬闸：切课只需要几百 KB，谁要是把一本 200MB 的 PDF 命名成
 * `.md` 传上来，没有这道闸就是一次 OOM —— 而函数进程一崩，整个服务的
 * 所有家庭都受影响。超限直接报错，不做截断（截断的 md 会切出一本残缺的书，
 * 那比失败更糟）。
 */
export async function downloadMedia({
  clientId,
  apiKey,
  fetchImpl = globalThis.fetch,
  kbId,
  mediaId,
  maxBytes = 20 * 1024 * 1024,
}) {
  const { url, headers } = await getMediaInfo({ clientId, apiKey, fetchImpl, kbId, mediaId });
  const res = await fetchImpl(url, { headers });
  if (!res.ok) {
    throw imaUnavailable(`下载知识库文件失败（${res.status}）`);
  }
  const declared = Number(res.headers?.get?.('content-length') ?? 0);
  if (declared > maxBytes) {
    throw imaRequestFailed(`文件过大（${declared} 字节），超过 ${maxBytes} 字节上限`);
  }
  const bytes = Buffer.from(await res.arrayBuffer());
  if (bytes.length > maxBytes) {
    throw imaRequestFailed(`文件过大（${bytes.length} 字节），超过 ${maxBytes} 字节上限`);
  }
  return {
    bytes,
    contentType: res.headers?.get?.('content-type') ?? '',
  };
}

/** 建文件夹。返回 `media_id`（文件夹本身也是条目，id 以 folder_ 开头）。 */
export async function createFolder({ clientId, apiKey, fetchImpl, kbId, name, folderId }) {
  const json = await imaFetch({
    clientId,
    apiKey,
    fetchImpl,
    path: '/openapi/wiki/v1/create_folder',
    body: { knowledge_base_id: kbId, name, folder_id: folderId ?? undefined },
  });
  const data = json.data ?? json;
  const mediaId = pickId(data?.media_id, data?.folder_id, data?.id);
  if (!mediaId) {
    const keys = data && typeof data === 'object' ? Object.keys(data) : [];
    throw imaRequestFailed(
      'create_folder 未返回 id'
        + `（实际返回字段：${keys.length > 0 ? keys.join(' / ') : '空'}）`,
      { returnedKeys: keys },
    );
  }
  return { mediaId, title: data.title ?? data.name ?? name };
}

/**
 * 确保某文件夹存在（幂等）：先在 KB 根目录查，命中则复用，否则创建。
 *
 * `getKnowledgeList` 的返回形状以 PoC 实测为准，这里对 `info_list` / `list`
 * 两种键都做了兼容。
 */
export async function ensureFolder({ clientId, apiKey, fetchImpl, kbId, name }) {
  const list = await getKnowledgeList({ clientId, apiKey, fetchImpl, kbId, folderId: '' });
  // 官方文档的返回键是 `knowledge_list`；`info_list` / `list` 是早期猜测留下的兜底。
  // 只读后面两个的后果：**永远判成「文件夹不存在」**，于是每次连接都重新建三个，
  // 而 ima 那边会积累一堆同名文件夹，界面上一切正常。
  const entries = list?.data?.knowledge_list
    ?? list?.data?.info_list
    ?? list?.data?.list
    ?? [];
  const hit = entries.find((e) => e?.title === name || e?.name === name);
  if (hit) return pickId(hit.media_id, hit.folder_id, hit.id);
  const created = await createFolder({ clientId, apiKey, fetchImpl, kbId, name });
  return created.mediaId;
}

/**
 * 生成知识库名 —— **按 UTF-8 字节控制在 25 以内**。
 *
 * ## 为什么这里要算字节而不是字数
 *
 * ima 文档写的是「库名 1-25 字」，但「字」到底按字符还是按字节并没写清。
 * 中文在 UTF-8 里是 3 字节：`伴学-李雨霏-…` 光品牌和姓名就 16 字节。
 * 按字符裁到 25 时，字节数可能已经三十几 —— 一旦它按字节校验，
 * 就会在**刚好合规的边界上**失败，而错误信息只会说 id 没拿到。
 *
 * 按字节裁，两种口径都满足（字节数 ≥ 字符数，所以 ≤25 字节必然 ≤25 字符）。
 *
 * ## 原来的写法为什么必然失败
 *
 * 原先把完整 UUID 拼进去：
 *   `伴学-李雨霏-2654d216-ffd9-4b2a-aca4-01cdc83858f8` = 43 个字符
 * 这已经不是边界问题，而是明显越界。它与「字段名读错」叠在一起，
 * 表现完全一样（都拿不到 id），所以 2026-10-27 那次连接失败得同时修两处。
 *
 * ## 取学号前 6 位够不够
 *
 * 一个家庭几个孩子，6 位十六进制碰撞概率可以忽略；库名只是给人看的标签，
 * 真正的身份仍是 `ima_student_kb` 里那条映射。
 */
const KB_NAME_MAX_BYTES = 25;

export function buildKbName(displayName, studentId) {
  const prefix = '伴学-';
  const shortId = String(studentId ?? '').replace(/-/g, '').slice(0, 6) || 'unknown';
  const suffix = `-${shortId}`;
  const budget = KB_NAME_MAX_BYTES
    - Buffer.byteLength(prefix, 'utf8')
    - Buffer.byteLength(suffix, 'utf8');
  let name = String(displayName ?? '').trim();
  // 逐字回退而不是 `slice(0, n)`：中文/emoji 按字节裁会切半个字符。
  while (name.length > 0 && Buffer.byteLength(name, 'utf8') > budget) {
    name = name.slice(0, -1);
  }
  if (name === '') name = '学生';
  return `${prefix}${name}${suffix}`;
}

/**
 * 确保一个学生的独立知识库 + 三个固定文件夹存在（幂等）。
 *
 * KB 名带学号，检索时按全名匹配；命中则复用，避免重复建库（建库不可逆）。
 * 返回 `{ kbId, folderIds, created }`，`folderIds` 用 [IMA_FOLDER_NAMES] 的键索引。
 */
export async function ensureStudentKb({
  clientId,
  apiKey,
  fetchImpl,
  studentId,
  displayName,
}) {
  const kbName = buildKbName(displayName, studentId);
  const found = await searchKnowledgeBase({ clientId, apiKey, fetchImpl, query: kbName });
  // 搜索结果的条目字段同样两套写法（`kb_id`/`kb_name` 与 `id`/`name`），两种都认。
  const foundList = found?.data?.info_list ?? found?.data?.knowledge_base_list ?? [];
  const existing = foundList.find((x) => (x?.kb_name ?? x?.name) === kbName);
  let kbId;
  let created;
  if (existing) {
    kbId = pickId(existing.kb_id, existing.id, existing.knowledge_base_id);
    if (!kbId) {
      // 命中了库名却没有 id：宁可在这一步说清楚，也不要拿着 undefined
      // 去建文件夹 —— 那时的报错会指向 folder_id，与真正的问题（搜索返回缺 id）无关。
      throw imaRequestFailed(
        'search_knowledge_base 命中了同名库但条目里没有 id',
        { keys: Object.keys(existing) },
      );
    }
    created = false;
  } else {
    const made = await createKnowledgeBase({
      clientId,
      apiKey,
      fetchImpl,
      name: kbName,
      description: `伴学学生 ${displayName ?? studentId} 的学习资料库`,
    });
    kbId = made.id;
    created = true;
  }

  const folderIds = {};
  for (const [key, name] of Object.entries(IMA_FOLDER_NAMES)) {
    folderIds[key] = await ensureFolder({ clientId, apiKey, fetchImpl, kbId, name });
  }
  // 把 kbName 一起返回：调用方要用它写 `ima_student_kb.kb_name`。
  // 让调用方自己再拼一遍，就会拼出第二份（而且很容易拼成旧写法）——
  // 库里记的名字和 ima 里真实的库名一旦不一致，排查时根本对不上。
  return { kbId, folderIds, created, kbName };
}

/**
 * 重名检查（上传前调用）。
 *
 * 参数形状按官方文档：待检查项放在 `params` **数组**里，每项
 * `{ name, media_type }`；不是把 `name` 平铺在 body 顶层。
 * 平铺的写法会走参数校验失败 —— 而这条路在 `uploadMarkdown` 里是第一步，
 * 它失败就意味着**一次资料都推不上去**，且报错指向 check_repeated_names，
 * 与真正想做的事（上传）看起来毫无关系。
 */
export async function checkRepeatedNames({
  clientId, apiKey, fetchImpl, kbId, name, folderId = '', mediaType = IMA_MEDIA_TYPE_MARKDOWN,
}) {
  return imaFetch({
    clientId,
    apiKey,
    fetchImpl,
    path: '/openapi/wiki/v1/check_repeated_names',
    body: {
      knowledge_base_id: kbId,
      folder_id: folderId || undefined,
      params: [{ name, media_type: mediaType }],
    },
  });
}

/** 创建媒体记录，拿 COS 上传凭证。返回 mediaId + 解析出的 COS 凭证 + cosKey。 */
export async function createMedia({
  clientId,
  apiKey,
  fetchImpl,
  kbId,
  fileName,
  fileSize,
  contentType = 'text/markdown',
  fileExt = 'md',
}) {
  const json = await imaFetch({
    clientId,
    apiKey,
    fetchImpl,
    path: '/openapi/wiki/v1/create_media',
    // ⚠️ 这里**不能**带 `media_type`。官方 create_media 只认
    // `content_type` + `file_ext`；多传一个 `media_type` 会稳定 220001。
    // 2026-10-27 那次「把 media_type 从 1 改成 7」修错了对象 ——
    // 错的是这个字段不该存在，不是它的值。
    body: {
      knowledge_base_id: kbId,
      file_name: fileName,
      file_size: fileSize,
      content_type: contentType,
      file_ext: fileExt,
    },
  });
  const data = json.data ?? json;
  if (!data || !data.media_id) {
    throw imaRequestFailed('create_media 未返回 media_id', json);
  }
  return {
    mediaId: data.media_id,
    cosCredentials: extractCosCredentials(data),
    // cos_key 也在 `cos_credential` 里；旧字段名保留兼容。
    cosKey: data.cos_credential?.cos_key ?? data.object_key ?? data.cos_key ?? data.path,
  };
}

/** 把媒体加入知识库（指定文件夹）。 */
export async function addKnowledge({
  clientId,
  apiKey,
  fetchImpl,
  kbId,
  mediaId,
  folderId,
  title,
  mediaType = IMA_MEDIA_TYPE_MARKDOWN,
  cosKey,
  fileSize,
  fileName,
}) {
  // `file_info` 只在真的传过 COS（拿到 cos_key）时才带：官方示例里它是必填，
  // 但直接调 addKnowledge 的单测没有 cos_key，硬塞一个空对象反而会掩盖问题。
  const fileInfo =
    cosKey === undefined
      ? undefined
      : { cos_key: cosKey, file_size: fileSize, file_name: fileName };

  return imaFetch({
    clientId,
    apiKey,
    fetchImpl,
    path: '/openapi/wiki/v1/add_knowledge',
    body: {
      knowledge_base_id: kbId,
      media_id: mediaId,
      folder_id: folderId ?? undefined,
      title: title ?? undefined,
      media_type: mediaType,
      file_info: fileInfo,
    },
  });
}

/**
 * 把一份 markdown 推到 ima：重名检查 → 建媒体 → 传 COS → 入知识库。
 *
 * 这是「写一条资料到 ima」的最小闭环。上层（错题档案 / 打卡档案）都复用它。
 */
export async function uploadMarkdown({
  clientId,
  apiKey,
  fetchImpl,
  kbId,
  folderId,
  title,
  markdown,
  mediaType = IMA_MEDIA_TYPE_MARKDOWN,
}) {
  // 重名检查是「锦上添花」：返回值目前没人消费，失败也不该让整次上传失败。
  // 但**不能静默** —— 记一条警告，否则「这一步一直在失败」永远没人知道。
  // 检查的名字要和 `createMedia` 实际用的文件名一致（`<title>.md`），
  // 否则查的是一个根本不存在的名字，查了等于没查。
  try {
    await checkRepeatedNames({
      clientId, apiKey, fetchImpl, kbId, folderId, name: `${title}.md`, mediaType,
    });
  } catch (err) {
    console.warn(`[ima] 重名检查失败（不阻断上传）：${err.message}`);
  }
  const buf = Buffer.from(markdown, 'utf8');
  const fileName = `${title}.md`;
  const { mediaId, cosCredentials, cosKey } = await createMedia({
    clientId,
    apiKey,
    fetchImpl,
    kbId,
    fileName,
    fileSize: buf.length,
    // 契约分家：创建媒体走 content_type/file_ext，media_type 只留给
    // 重名检查与 add_knowledge。混用会让 create_media 直接 220001。
    contentType: 'text/markdown',
    fileExt: 'md',
  });
  await uploadToCos({
    cosCredentials,
    cosKey,
    content: buf,
    contentType: 'text/markdown',
    fetchImpl,
  });
  await addKnowledge({
    clientId,
    apiKey,
    fetchImpl,
    kbId,
    mediaId,
    folderId,
    title,
    mediaType,
    cosKey,
    fileSize: buf.length,
    fileName,
  });
  return { mediaId };
}

/**
 * 同义知识点归一（与 `tools/export-mistakes-ima.mjs` 同源）。
 *
 * `knowledge_point` 是错题录入时模型生成的**自由文本**，同一概念会出现多个名字
 * （实测：解方程 / 方程求解 / 解一元一次方程 三词并存）。不归一，档案在 ima 里就是散的。
 * 口径：只合并「明显同一概念」的，归一到右侧**已有名字**，不造新名；拿不准不合并。
 */
const KP_ALIAS = {
  解一元一次方程: '解一元一次方程',
  方程求解: '解一元一次方程',
  解方程: '解一元一次方程',
  列方程解应用题: '列方程解应用题',
  一元一次方程应用: '列方程解应用题',
  和倍问题: '列方程解应用题',
  相遇问题: '列方程解应用题',
  有理数乘除: '有理数乘除与混合运算',
  有理数乘除混合运算: '有理数乘除与混合运算',
  有理数加减: '有理数加减与混合运算',
  有理数加减混合运算: '有理数加减与混合运算',
  有理数乘方运算: '幂的运算',
  积的乘方逆运算: '幂的运算',
};

const MISTAKE_STATE_LABEL = {
  pending: '待复习',
  reviewing: '复习中',
  mastered: '已掌握',
};

function normalizeKp(raw) {
  const kp = (raw ?? '').trim();
  if (kp === '') return '(未标注)';
  return KP_ALIAS[kp] ?? kp;
}

/** 日期只保留 YYYY-MM-DD（pg 返回的是 Date 对象，直接 slice 会切成 "Sun Oct 25"）。 */
function dateOnly(v) {
  if (!v) return '';
  const d = v instanceof Date ? v : new Date(v);
  if (Number.isNaN(d.getTime())) return String(v).slice(0, 10);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** 未分科（历史数据里 `subject` 为空的）也要有归属，不能悄悄并进数学。 */
export const IMA_SUBJECT_FALLBACK = '未分科';

/** 一行的学科，空值归到 `未分科`。 */
export function subjectOf(row) {
  const s = String(row?.subject ?? '').trim();
  return s === '' ? IMA_SUBJECT_FALLBACK : s;
}

/**
 * 把行按学科分组：`[{ subject, rows }]`。
 *
 * 排序按「条数降序、同数按名称」—— 错题多的那一科先推到 ima，家长打开文件夹
 * 第一份就是最该看的那科。不按语文/数学/英语的固定顺序，因为学生年级不同，
 * 主科也不同。
 */
export function groupRowsBySubject(rows) {
  const map = new Map();
  for (const row of rows ?? []) {
    const key = subjectOf(row);
    if (!map.has(key)) map.set(key, []);
    map.get(key).push(row);
  }
  return [...map.entries()]
    .map(([subject, items]) => ({ subject, rows: items }))
    .sort((a, b) => b.rows.length - a.rows.length
      || (a.subject < b.subject ? -1 : a.subject > b.subject ? 1 : 0));
}

/**
 * 文件名里的学科片段。
 *
 * 学科目前是客户端固定枚举（数学/语文/英语…），但仍然过一遍：ima 的
 * `create_media.file_name` 里出现 `/` 之类的字符会被服务端拒或截断，
 * 而学科名一旦来自自由输入（比如「数学/物理」），失败会以「上传失败」的形式
 * 出现在一次打卡提交的日志里，很难联想到是文件名。
 */
export function subjectForFileName(subject) {
  return String(subject ?? '').replace(/[\\/:*?"<>|\s]+/g, '-').replace(/^-+|-+$/g, '')
    || IMA_SUBJECT_FALLBACK;
}

/**
 * 把错题行聚合成 markdown（按知识点分组，降序）。纯函数，便于单测。
 *
 * `rows` 每行字段：knowledge_point / title / question_body / question_no /
 * wrong_reason / answer_key / wrong_count / last_wrong_at / created_at /
 * state / source_homework_title。
 *
 * `subject` 是**这一份文件所属的学科**（见 `groupRowsBySubject`）。原实现把所有学科
 * 混进一份 md 且不写学科，家长在 ima 里翻档案根本看不出这道题是语文还是数学
 * （2026-11-02 报障）。现在一科一份，标题带科目，每题也标一行学科。
 */
export function buildMistakesMarkdown(rows, exportedAt, subject = '') {
  const byKp = new Map();
  for (const r of rows) {
    const kp = normalizeKp(r.knowledge_point);
    if (!byKp.has(kp)) byKp.set(kp, []);
    byKp.get(kp).push(r);
  }
  const groups = [...byKp.entries()]
    .map(([kp, items]) => ({
      kp,
      items,
      totalWrong: items.reduce((s, r) => s + (Number(r.wrong_count) || 0), 0),
    }))
    .sort((a, b) => b.totalWrong - a.totalWrong || b.items.length - a.items.length);

  const lines = [];
  lines.push(`# 错题档案${subject !== '' ? ` · ${subject}` : ''}（按知识点聚合）`);
  lines.push('');
  lines.push(`- 导出于：${exportedAt}`);
  if (subject !== '') lines.push(`- 学科：${subject}`);
  lines.push(`- 错题总数：${rows.length} 条；知识点：${groups.length} 个`);
  lines.push('');
  lines.push('## 知识点总览');
  lines.push('');
  lines.push('| 知识点 | 条目数 | 累计错误次数 |');
  lines.push('| --- | --- | --- |');
  for (const g of groups) {
    lines.push(`| ${g.kp} | ${g.items.length} | ${g.totalWrong} |`);
  }
  lines.push('');
  for (const g of groups) {
    lines.push(`## ${g.kp}`);
    lines.push('');
    for (const r of g.items) {
      const title = (r.title ?? '').trim();
      const body = (r.question_body ?? '').trim();
      const stem = body !== '' ? body : title;
      const no = (r.question_no ?? '').trim();
      lines.push(`### ${no !== '' ? `第 ${no} 题` : title || '（无标题）'}`);
      lines.push('');
      // 每条都带学科：文件本身已按学科分开，但拷出去一段、或家长把两科的内容
      // 放在一起看时，没有这一行就还是分不清。
      lines.push(`- 学科：${subjectOf(r)}`);
      if (stem !== '') {
        lines.push(`- 题干：${stem.replace(/\s+/g, ' ').slice(0, 300)}`);
      } else {
        lines.push('- 题干：（无题干）');
      }
      const reason = (r.wrong_reason ?? '').trim();
      if (reason !== '') lines.push(`- 错因：${reason.replace(/\s+/g, ' ').slice(0, 300)}`);
      const answer = (r.answer_key ?? '').trim();
      if (answer !== '') lines.push(`- 正确答案：${answer.replace(/\s+/g, ' ').slice(0, 120)}`);
      const src = (r.source_homework_title ?? '').trim();
      if (src !== '') lines.push(`- 来源作业：${src}`);
      const state = MISTAKE_STATE_LABEL[r.state] ?? r.state ?? '';
      lines.push(
        `- 状态：${state}；错误次数：${r.wrong_count ?? 1}；`
          + `最近做错：${dateOnly(r.last_wrong_at) || dateOnly(r.created_at) || '未知'}`,
      );
      lines.push('');
    }
  }
  return lines.join('\n');
}

/**
 * 把打卡记录聚合成 markdown。行字段尽量宽容：取 subject/knowledge/question/
 * answer/correct/created_at 等；缺字段的用占位，不抛错。纯函数，便于单测。
 *
 * `subject` 同 `buildMistakesMarkdown`：一科一份，标题带科目。
 */
export function buildCheckinsMarkdown(rows, exportedAt, subject = '') {
  const lines = [];
  lines.push(`# 打卡档案${subject !== '' ? ` · ${subject}` : ''}`);
  lines.push('');
  lines.push(`- 汇总于：${exportedAt}`);
  if (subject !== '') lines.push(`- 学科：${subject}`);
  lines.push(`- 打卡条数：${rows.length} 条`);
  lines.push('');
  rows.forEach((r, i) => {
    const date = dateOnly(r.created_at || r.date);
    lines.push(`## ${date || `第 ${i + 1} 次`}`);
    lines.push('');
    if (r.knowledge) lines.push(`- 主攻方向：${r.knowledge}`);
    if (r.subject) lines.push(`- 学科：${r.subject}`);
    if (r.question) lines.push(`- 题目：${String(r.question).slice(0, 300)}`);
    if (r.answer != null) lines.push(`- 你的答案：${r.answer}`);
    const correct = r.correct;
    if (typeof correct === 'boolean') {
      lines.push(`- 结果：${correct ? '正确' : '错误'}`);
    } else if (r.correct != null) {
      lines.push(`- 结果：${r.correct}`);
    }
    lines.push('');
  });
  return lines.join('\n');
}

/**
 * 把一个学生的资料同步到 ima（错题档案 + 打卡档案）。
 *
 * ## 这是「可选同步」的落地处
 *
 * - `imaStatus` 非 `active` → **直接返回 `{ synced: false }`，不报错、不联网、
 *   不查数据**。这就是「学生没 ima 账号也能完整体验」的实现：ima 永远不是前置条件。
 * - `active` → 确保该生 KB + 文件夹（幂等），再把错题 / 打卡各推一份 md。
 *
 * `fetchMistakes` / `fetchCheckins` 是注入的数据抓取回调（生产里走 PG；测试里给假数据）。
 * `ensureKbImpl` / `uploadMdImpl` 也可注入，便于把这个「编排」与「真实 ima 调用」解耦测试。
 */
export async function syncStudentData({
  imaStatus,
  credential,
  studentId,
  displayName,
  fetchMistakes,
  fetchCheckins,
  fetchImpl,
  now = () => new Date(),
  ensureKbImpl = ensureStudentKb,
  uploadMdImpl = uploadMarkdown,
}) {
  // 守卫：非 active 静默跳过。这是「可选同步」的总闸。
  if (!shouldSync(imaStatus)) {
    return { synced: false, reason: `ima_status=${imaStatus}` };
  }
  if (!credential?.clientId || !credential?.apiKey) {
    throw imaAuthFailed('ima 凭证缺失（status 为 active 却没有 clientid / apikey）');
  }
  const { clientId, apiKey } = credential;

  const { kbId, folderIds } = await ensureKbImpl({
    clientId,
    apiKey,
    fetchImpl,
    studentId,
    displayName,
  });

  const exportedAt = now().toISOString().slice(0, 19).replace('T', ' ');
  const day = exportedAt.slice(0, 10);
  let pushed = 0;

  // 一科一份：文件名带学科，家长在 ima 里点开就是分好科的。
  // 空学科的进「未分科」，不并进任何一科（猜错科目比不猜更糟）。
  if (fetchMistakes) {
    const mistakes = await fetchMistakes(studentId);
    for (const group of groupRowsBySubject(mistakes ?? [])) {
      const md = buildMistakesMarkdown(group.rows, exportedAt, group.subject);
      await uploadMdImpl({
        clientId,
        apiKey,
        fetchImpl,
        kbId,
        folderId: folderIds.mistake,
        title: `错题档案-${subjectForFileName(group.subject)}-${day}`,
        markdown: md,
      });
      pushed += 1;
    }
  }

  if (fetchCheckins) {
    const checkins = await fetchCheckins(studentId);
    for (const group of groupRowsBySubject(checkins ?? [])) {
      const md = buildCheckinsMarkdown(group.rows, exportedAt, group.subject);
      await uploadMdImpl({
        clientId,
        apiKey,
        fetchImpl,
        kbId,
        folderId: folderIds.checkin,
        title: `打卡档案-${subjectForFileName(group.subject)}-${day}`,
        markdown: md,
      });
      pushed += 1;
    }
  }

  return { synced: true, kbId, folderIds, pushed };
}
