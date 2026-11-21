import { loadConfig, validateConfig } from './config.js';
import { createGuard } from './guard.js';
import { createHandlers } from './handlers.js';
import { createMetrics } from './metrics.js';
import { createModelClient } from './model-client.js';
import { createRouter } from './router.js';
import { createStore } from './store.js';
import { createUploadService } from './uploads.js';
import { readQueryParameters } from '../../shared/query.js';

/**
 * 装配一个网关实例。
 *
 * 各部件都可注入，测试里用它替换掉模型客户端与时钟，
 * 就能在没有 Key、没有网络、不等待真实超时的前提下跑完整的请求链路。
 */
export function createGateway(overrides = {}) {
  const config = overrides.config ?? loadConfig();

  // 配置自检只拦「错了会静默产生错误行为」的组合（例如开了鉴权却没有密钥）。
  // 这类问题如果只写进日志，表现会和「一切正常」完全一样。
  const problems = validateConfig(config);
  if (problems.length > 0) {
    throw new Error(`网关配置有问题：\n- ${problems.join('\n- ')}`);
  }

  const store = overrides.store ?? createStore({ config, now: overrides.now });
  const model = overrides.model ?? createModelClient(config, overrides);
  const metrics = overrides.metrics ?? createMetrics({ config, now: overrides.now });
  const logger = overrides.onAudit ?? auditLogger(config);
  const guard =
    overrides.guard ??
    createGuard({
      config,
      store,
      now: overrides.now,
      /**
       * 审计一条，喂两个下游。
       *
       * 聚合搭在审计的**出口**上而不是各端点里，是为了保证
       * 「日志里的数」与「看板上的数」同源 —— 两套埋点迟早会分叉，
       * 而分叉时你无法判断哪套是对的。
       */
      onAudit: (record) => {
        metrics.record(record);
        logger?.(record);
      },
    });
  const uploads = overrides.uploads ?? createUploadService({ config, now: overrides.now });
  const handlers = createHandlers({
    config,
    model,
    guard,
    uploads,
    metrics,
    now: overrides.now,
  });
  const handle = createRouter({ config, handlers, guard, uploads });

  return { config, model, guard, uploads, handlers, handle, store, metrics };
}

/**
 * 审计日志。
 *
 * Serverless 平台按日志量计费，所以这里刻意**不展开请求内容** ——
 * 学生答案与作业照片既不解决「谁花了多少」的问题，又会多出一份需要合规看护的数据。
 * （见 guard.js 里 audit 的注释。）
 */
function auditLogger(config) {
  if (process.env.AI_AUDIT_LOG === 'off') return undefined;
  return (record) => {
    const line = JSON.stringify({ level: record.ok ? 'info' : 'warn', msg: 'ai_call', ...record });
    if (record.ok) {
      console.log(line);
    } else {
      // 失败走 warn，便于在日志服务里单独配告警规则。
      console.warn(line);
    }
  };
}

/**
 * 热实例复用。
 *
 * Serverless 的实例会被反复复用，每次请求都重新装配一遍会让连接池、
 * 结果缓存、限流计数全部作废 —— 缓存就白做了。
 * 配置变了（改了 Key 或模型）就重建，避免改了环境变量却继续用旧配置。
 */
let cached = null;
let cachedSignature = '';

export function getGateway(env = process.env) {
  const config = loadConfig(env);
  const signature = JSON.stringify([
    // ⚠️ 厂商必须参与签名。少了它，改了 AI_MODEL_PROVIDER 之后**复用中的实例
    // 会继续用旧厂商**（地址、Key、思维链字段全是旧的），
    // 而配置看着已经改了 —— 又一个「改了配置没生效」的静默失败。
    config.modelProvider,
    config.ark.apiKey !== '',
    config.ark.baseUrl,
    config.ark.models,
    config.modelClient,
    config.requireAuth,
    // 会话密钥参与签名：轮换密钥后必须重建实例，
    // 否则旧实例还会用旧密钥校验，表现为「刚换的 token 立刻失效」。
    config.auth.sessionSecret,
    // 配额与单价变了也要重建：配额缓存的是计数（计数不该丢），
    // 但权重与单价是每次判定都要读的配置。
    config.quota.unitsPerMinute,
    config.quota.unitsPerDay,
    config.quota.weights,
    config.pricing,
    config.cacheTtlMs,
    config.maxReferenceBatch,
    config.upload.signer,
    config.upload.proxyUrlBase,
    config.upload.tos.bucket,
    config.upload.tos.accessKeyId,
    config.kv.driver,
    config.kv.url,
  ]);
  if (cached && cachedSignature === signature) return cached;

  cached = createGateway({ config });
  cachedSignature = signature;
  return cached;
}

/** 测试用：清掉热实例。 */
export function resetGateway() {
  cached = null;
  cachedSignature = '';
}

/**
 * 平台入口。
 *
 * 火山引擎函数服务（veFaaS）/ 腾讯云 SCF / 阿里云 FC 走 API 网关触发器时，
 * 事件形状基本一致（`path` / `httpMethod` / `headers` / `body` / `isBase64Encoded`），
 * 所以一套归一化就够；差异（字段名、多一层 requestContext）在 [toRequest] 里抹平。
 */
export async function handler(event, context) {
  const gateway = getGateway();
  const request = toRequest(event);
  const result = await gateway.handle(request);
  return toPlatformResponse(result);
}

export default handler;

/**
 * ⚠️⚠️ 平台可能把事件**序列化成 Buffer（或字符串）**再传进来 —— 必须先还原成对象。
 *
 * 这个坑有多隐蔽（2026-09-24 云上首跑实测，数据服务那边先撞上、网关这边**一模一样**）：
 *   · 本地单测喂的是**对象** → 全绿，永远发现不了；
 *   · 阿里云 FC3 的 HTTP 触发器喂的是 **Buffer**（内容就是同一份 JSON 的字节，
 *     实测 `isBuffer: true`、顶层键是 `0..593` 这种下标、`event.requestContext` 是 undefined）；
 *   · 于是 `toRequest` 里读的字段全部落空，一路 fallback 成默认值；
 *   · **而症状看起来像「路由表坏了」** —— 每个请求都回
 *     `{"ok":false,"error":{"code":"not_found","message":"未知端点 /"}}`，
 *     响应体是标准信封，看不出是事件没解开。
 *   · ⚠️ 数据服务与网关是**两个独立入口**，改了一个**不会**顺带修好另一个 ——
 *     这次的形态就是「数据服务已经好了，网关还全是 404」。
 *
 * 判据（测试里有）：**同一个事件，喂 Buffer / 字符串和喂对象，产出必须逐字段相同**。
 * 少了这条，这个 bug 一定会复发 —— 因为「本地全绿」会一直给人错觉。
 *
 * 📌 另一个必须「两条外壳一致」的地方是 `normalizePath` 的网关前缀规则；
 *    凡是「本地 dev-server 与线上 handler 各写一份」的逻辑，都要在这里对齐。
 */
function toEventObject(raw) {
  if (Buffer.isBuffer(raw)) {
    try {
      return JSON.parse(raw.toString('utf8'));
    } catch {
      return {};
    }
  }
  if (typeof raw === 'string') {
    try {
      return JSON.parse(raw);
    } catch {
      return {};
    }
  }
  return raw ?? {};
}

export function toRequest(rawEvent) {
  const event = toEventObject(rawEvent);
  const http = event?.requestContext?.http ?? {};
  const method = String(
    event?.httpMethod ?? event?.method ?? http.method ?? 'POST',
  ).toUpperCase();

  const headers = lowerKeys(event?.headers ?? {});
  /**
   * ⚠️ 与数据服务同一条教训（见 shared/query.js）：FC3 的字段名是
   * `queryParameters`，原先读的 `queryStringParameters ?? rawQueryString`
   * 两边都不存在 → `/ai/uploads/put?key=…&sig=…` 这类请求的参数**全丢**，
   * 报出来的是「缺少参数 key」，看起来像调用方没带参数。
   */
  const query = readQueryParameters(event);

  const rawBody = event?.isBase64Encoded
    ? Buffer.from(event?.body ?? '', 'base64')
    : Buffer.from(event?.body ?? '', 'utf8');

  let body = null;
  let bodyInvalid = false;
  if (method !== 'PUT' && method !== 'GET') {
    const text = rawBody.toString('utf8').trim();
    if (text !== '') {
      try {
        body = JSON.parse(text);
      } catch {
        bodyInvalid = true;
      }
    }
  }

  return {
    method,
    path: normalizePath(event?.path ?? event?.rawPath ?? http.path ?? '/'),
    query,
    headers,
    body,
    bodyInvalid,
    rawBody,
  };
}

/**
 * 抹平网关前缀。
 *
 * API 网关通常会在路径前面加一段（`/prod/ai/...`、`/release/ai/...`），
 * 而路由表是从 `/ai/` 开始的。不处理的话，线上会出现
 * 「本地跑得好好的，发上去全是 404」，而且 404 的 body 看起来完全正常。
 */
function normalizePath(path) {
  const trimmed = path.startsWith('/') ? path : `/${path}`;
  if (trimmed.startsWith('/ai/') || trimmed === '/ai') return trimmed;
  const index = trimmed.indexOf('/ai/');
  return index >= 0 ? trimmed.slice(index) : trimmed;
}

function toPlatformResponse(result) {
  const isBinary = Buffer.isBuffer(result.body);
  return {
    statusCode: result.status,
    headers: result.headers,
    body: isBinary ? result.body.toString('base64') : result.body,
    // 二进制响应必须显式声明，否则平台会按 UTF-8 处理图片字节，返回一堆乱码。
    isBase64Encoded: isBinary,
  };
}

function lowerKeys(headers) {
  const output = {};
  for (const [key, value] of Object.entries(headers ?? {})) {
    output[key.toLowerCase()] = value;
  }
  return output;
}
