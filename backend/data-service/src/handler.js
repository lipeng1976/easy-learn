import { createApp } from './app.js';
import { createAiGatewayClient } from './ai_client.js';
import { readQueryParameters } from '../../shared/query.js';
import { isProduction, validateConfig } from './config-check.js';
import { assertAuthRoleScoped, assertRlsEnforced, createPool } from './db.js';
import {
  DEFAULT_QUOTA_PER_STUDENT,
  DEFAULT_QUOTA_WARN_REMAINING,
  createImageStoreFor,
  imageStoreConfigFingerprint,
  parsePhotoQuota,
  parseQuotaWarnRemaining,
} from './image-store-factory.js';

/**
 * 数据服务的**云函数入口**。
 *
 * ## 它和 dev-server.js 的关系
 *
 * `app.js` 是框架无关的请求处理核心；本文件与 `dev-server.js` 是它的两个外壳，
 * 差别只在「请求怎么进来的」：
 *
 *   dev-server.js  → node:http 的 `req`/`res`（本机开发）
 *   本文件          → 平台的 HTTP 触发事件（线上）
 *
 * 在这之前**只有 dev-server** —— 也就是说这份服务其实没有线上入口，
 * 代码里那句「云函数入口用的是同一个 createApp」当时还只是意图。
 *
 * ## 为什么零依赖也要自己写这一层
 *
 * 平台给的 `event` 形状各家略有不同（字段名、是否多一层 `requestContext`、
 * body 是否 base64），而路由表认的是**精确整串匹配**的 `/data/*` 与 `/auth/*`。
 * 少了归一化，线上第一个症状是「本地全绿、发上去全是 404」，而且
 * 404 的响应体看起来完全正常（它就是本服务的标准错误信封）。
 */

/**
 * 装配一个数据服务实例。
 *
 * 与网关的 `createGateway` 同一个形状：部件可注入，测试里换掉连接池与时钟
 * 就能不碰真库跑完整链路。
 */
export function createDataService(overrides = {}) {
  const env = overrides.env ?? process.env;

  // 配置自检：拦「错了会静默产生错误行为」的组合（见 config-check.js）。
  // 装配点负责炸 —— 在函数里这就是冷启动失败，所有请求 500，**看得见**。
  const { problems, warnings } = validateConfig(env);
  for (const w of warnings) {
    console.warn(`[data-service] 警告：${w}`);
  }
  if (problems.length > 0) {
    throw new Error(
      `数据服务配置有问题（${isProduction(env) ? '生产' : '非生产'}环境）：\n- ${problems.join('\n- ')}`,
    );
  }

  const pool = overrides.pool ?? createPool({
    user: env.PGUSER,
    password: env.PGPASSWORD,
    host: env.PGHOST,
    port: env.PGPORT ? Number(env.PGPORT) : undefined,
    database: env.PGDATABASE,
    max: env.PG_POOL_MAX ? Number(env.PG_POOL_MAX) : undefined,
  });
  /**
   * 鉴权连接池。**必须显式给 user** —— `createPool` 的默认值取自 `PGUSER`，
   * 而那是应用角色 app_rls；用它连就等于「没有鉴权连接」，注册登录一行也读不到。
   */
  const authPool = overrides.authPool ?? createPool({
    user: env.PG_AUTH_USER ?? 'app_auth',
    password: env.PG_AUTH_PASSWORD ?? undefined,
    host: env.PGHOST,
    port: env.PGPORT ? Number(env.PGPORT) : undefined,
    database: env.PGDATABASE,
    max: env.PG_AUTH_POOL_MAX ? Number(env.PG_AUTH_POOL_MAX) : 3,
  });

  /**
   * 照片字节的存储。**后端由 `IMAGE_DRIVER` 决定**（`fs` 默认 / `oss`），
   * 选择逻辑只有一处，见 image-store-factory.js。
   *
   * 云上必须用 `oss`：函数计算没有持久磁盘，`fs` 的写入会随实例回收消失，
   * 而且多实例之间不共享 —— 症状是「上传成功，过一会儿图没了」。
   */
  const imageStore = overrides.imageStore ?? createImageStoreFor(env);

  /**
   * 每个学生的照片张数上限。
   *
   * **它是独立的装配项，不挂在 `imageStore` 上** —— 这一点是刻意的：
   * 测试里注入一个假存储（`overrides.imageStore`）时不该连带把配额也换掉，
   * 否则「权限/配额」这类逻辑会在测试里悄悄用上另一套数字，
   * 而失败信息会指向「功能没接通」这个假线索。
   *
   * `parsePhotoQuota` 的错误分支这里**不再处理**：`validateConfig` 已经把非法值
   * 归进 problems，上面那一行早就抛了。真走到这里说明它合法。
   */
  const photoQuota = overrides.photoQuota
    ?? parsePhotoQuota(env.IMAGE_QUOTA_PER_STUDENT).quota
    ?? DEFAULT_QUOTA_PER_STUDENT;

  /**
   * 剩余不足多少张时给学生一句提示。默认 20，写 `0` = 不提前提示。
   *
   * 与 `photoQuota` 一样是**独立装配项**，理由同上：测试里换掉存储或配额时，
   * 不该连带把另一个数也换掉。
   */
  const photoWarnRemaining = overrides.photoWarnRemaining
    ?? parseQuotaWarnRemaining(env.IMAGE_QUOTA_WARN_REMAINING).warnRemaining
    ?? DEFAULT_QUOTA_WARN_REMAINING;

  /**
   * AI 网关客户端。没配 `AI_GATEWAY_BASE_URL` 就是 `null`。
   *
   * 云上这两个服务是两个函数，**必须配公网 URL**。不给本机地址兜底：
   * 那会让云上静默指向 `127.0.0.1`，症状是「打卡永远出不了题」而日志看起来正常。
   */
  const aiGateway = overrides.aiGateway ?? (env.AI_GATEWAY_BASE_URL
    ? createAiGatewayClient({
      baseUrl: env.AI_GATEWAY_BASE_URL,
      timeoutMs: Number(env.AI_GATEWAY_TIMEOUT_MS) || 30_000,
    })
    : null);

  const app = createApp({
    pool,
    authPool,
    sessionSecret: env.AI_SESSION_SECRET ?? '',
    imageStore,
    photoQuota,
    photoWarnRemaining,
    aiGateway,
    instanceId: env.SERVER_INSTANCE_ID ?? '',
  });

  return {
    app, pool, authPool, imageStore, photoQuota, photoWarnRemaining, aiGateway, env,
  };
}

/**
 * 冷启动自检 —— **与配置自检是两件事**。
 *
 * `validateConfig` 只看环境变量（不用连库）；这里查的是「连上库之后」的三道闸：
 * RLS 到底有没有生效、鉴权角色有没有被多授权、照片存储能不能写。
 * 前两道**不通过就不该服务**：它们失效时不会有任何症状，只会在某天变成一次数据泄露。
 * 第三道只是功能，起不来也不该拖死其余路由，所以只进日志。
 *
 * 每次冷启动只跑一次（`ready` 缓存 Promise）。**热实例复用时不能重跑** ——
 * 那是每个请求一次全表扫描。
 */
let ready = null;

export function ensureReady(service) {
  if (ready) return ready;
  ready = (async () => {
    const role = await assertRlsEnforced(service.pool);
    const authRole = await assertAuthRoleScoped(service.authPool);
    const store = await service.imageStore.assertReady();
    const storeLine = store.ok
      ? `照片存储：${store.root}`
      : `⚠️  照片存储不可用 —— ${store.reason}（其余功能不受影响）`;
    console.log(
      `[data-service] 冷启动自检通过（应用角色=${role}，鉴权角色=${authRole}）；${storeLine}`,
    );
    return true;
  })().catch((e) => {
    // 失败的 Promise 不能留在缓存里，否则这一个实例会永远 500 到被回收 ——
    // 而失败原因只有第一条请求看得见。
    ready = null;
    throw e;
  });
  return ready;
}

/** 测试用：清掉就绪标记。 */
export function resetReady() {
  ready = null;
}

/**
 * 热实例复用。
 *
 * Serverless 的实例会被反复复用。每次请求都重新装配会让**连接池作废** ——
 * PG 连接是这份服务最贵的资源，冷启动一次就要重新握手（见 cloud-migration-plan
 * §Serverless 连接数坑：实例数 × 池大小不得超过数据库连接上限）。
 */
let cached = null;
let cachedSignature = '';

export function getDataService(env = process.env) {
  const signature = JSON.stringify([
    env.PGHOST, env.PGPORT, env.PGDATABASE, env.PGUSER,
    env.PG_AUTH_USER, env.PG_POOL_MAX, env.PG_AUTH_POOL_MAX,
    // 密钥参与签名：轮换后必须重建，否则旧实例还在用旧密钥验签。
    env.AI_SESSION_SECRET,
    // AI 网关地址同理：换了地址还留着旧实例，表现是「打卡仍打旧网关」，
    // 而环境变量看起来已经是新的。
    env.AI_GATEWAY_BASE_URL,
    // 照片存储的配置（含后端选择与桶）：换后端/换桶/换密钥同样必须重建 ——
    // 否则会出现「改了 IMAGE_DRIVER 但照片仍写进旧存储」，
    // 而健康检查显示的是新配置，属于查不出来那一类。
    imageStoreConfigFingerprint(env),
  ]);
  if (cached && cachedSignature === signature) return cached;
  cached = createDataService({ env });
  cachedSignature = signature;
  // 配置变了就重新过一遍自检（新实例还没查过 RLS）。
  ready = null;
  return cached;
}

/** 测试用：清掉热实例。 */
export function resetDataService() {
  cached = null;
  cachedSignature = '';
  ready = null;
}

/**
 * 平台入口。
 *
 * 火山引擎函数服务（veFaaS）/ 腾讯云 SCF / 阿里云 FC 走 API 网关触发器时，
 * 事件形状基本一致（`path` / `httpMethod` / `headers` / `body` / `isBase64Encoded`），
 * 所以一套归一化就够；差异在 [toRequest] 里抹平。
 */
/**
 * 超过这个耗时就打一条日志（毫秒）。
 *
 * 取 1500 而不是 10000：正常请求是**几十毫秒**量级，1.5 秒已经在一个数量级之外；
 * 而客户端那边的预算是 10 秒 —— 卡到 10 秒才记账的日志，永远追不上用户看到的失败。
 */
export const SLOW_REQUEST_MS = 1500;

/**
 * ⚠️ 慢请求日志（2026-09-24 加）—— 它存在的**唯一**目的是让「10 秒没有响应」可判。
 *
 * ## 为什么原来查不下去
 *
 * 真机反馈：「伴学消息」发消息时，客户端报「数据服务 10 秒没有响应」。
 * 而这一层当时**一条日志都没有** —— `errorResponse` 只记 500（4xx 刻意不记，
 * 怕淹没真信号），冷启动那行每个实例只打一次。于是这两种情况在日志里
 * **长得一模一样：都是空的**：
 *
 *   ① 平台收到了、服务端自己慢（借连接 / 等库）；
 *   ② 平台**压根没把请求交给函数**（实例没起来 / 网关侧 / 连接是半开的）。
 *
 * 而它们的处置完全相反：① 要查池与 SQL，② 要查平台与客户端的那条连接。
 * 一句「10 秒没响应」不带这个区分，排查就只能靠猜 —— 那是本仓反复吃过亏的形状。
 *
 * ## 判据（看日志就够，不用再猜）
 *
 *   · **有这条日志**、`elapsed` 很大 → 服务端确实在处理 → 方向是库与连接池；
 *     日志里的 `query 键` 顺带证明「query 参数到底有没有到达应用」
 *     （那场 `studentId` 事故就是它，见 `shared/query.js`）。
 *   · **没有这条日志**（连一行都没有）→ 请求没进来 → 直接去查平台侧，
 *     别在业务代码里找。
 */
export function logIfSlow(request, elapsedMs, status) {
  if (elapsedMs < SLOW_REQUEST_MS) return;
  const queryKeys = Object.keys(request?.query ?? {}).join(',') || '(无)';
  console.warn(
    `[data-service] ⚠️ 慢请求 ${elapsedMs}ms：${request?.method} ${request?.pathname}`
    + ` → ${status || '(未出结果)'}；query 键 = ${queryKeys}`,
  );
}

export async function handler(event, context) {
  const startedAt = Date.now();
  // 归一化与装配都提到 try 外面：`ensureReady` 失败（冷启动自检不过）时，
  // 也要能打出「是哪个请求、带了什么」—— 否则那一次失败只剩一句配置错误。
  const request = toRequest(event);
  const service = getDataService();
  let status = 0;
  try {
    await ensureReady(service);
    const result = await service.app(request);
    status = result.status;
    return toPlatformResponse(result);
  } finally {
    logIfSlow(request, Date.now() - startedAt, status);
  }
}

export default handler;

/**
 * 把平台事件归一化成 `app.js` 认的那个请求对象。
 *
 * ⚠️ **照片上传这条路必须走通**：`POST /data/homework/images/upload` 的 body
 * 就是图片字节。平台把二进制请求体标成 `isBase64Encoded: true`，所以这里
 * 必须先解 base64 再交给路由 —— 少这一步，收下来的是 base64 文本，
 * 存成的图**打得开才怪**，而且不会报任何错。
 */
/**
 * ⚠️⚠️ 平台可能把事件**序列化成 Buffer（或字符串）**再传进来 —— 必须先还原成对象。
 *
 * 这个坑有多隐蔽（2026-09-24 云上首跑实测，排查了一整轮）：
 *   · 本地 `deploy-entry.test.js` 喂的是**对象** → 单测全绿，永远发现不了；
 *   · 阿里云 FC3 的 HTTP 触发器喂的是 **Buffer**（内容就是同一份 JSON 的字节，
 *     实测 `isBuffer: true`、顶层键是 `0..593` 这种下标、`event.requestContext` 是 undefined）；
 *   · 于是 `toRequest` 里读的四个字段全部落空，一路 fallback 成 `GET /`；
 *   · **而症状看起来像「路由表坏了」** —— 每个请求都回
 *     `{"ok":false,"error":{"code":"not_found","message":"未知端点：GET /"}}`，
 *     响应体是标准信封，看不出是事件没解开。
 *   · ⚠️ 连带教训：`/health` 这种「在 normalizePath 里有特例」的路径是最灵敏的探针 ——
 *     它也跟着回「未知端点：GET /」，才能断定不是某条路由写错了。
 *
 * 判据（测试里有）：**同一个事件，喂 Buffer 和喂对象，产出必须逐字段相同**。
 * 少了这条，这个 bug 一定会复发 —— 因为「本地全绿」会一直给人错觉。
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
    event?.httpMethod ?? event?.method ?? http.method ?? 'GET',
  ).toUpperCase();

  const headers = lowerKeys(event?.headers ?? {});
  /**
   * ⚠️ 查询参数**不能**写成 `event.queryStringParameters ?? URLSearchParams(...)`。
   *
   * FC3 的字段名是 `queryParameters`（2026-09-24 云上实测，见 shared/query.js），
   * 而 `??` 只在左侧为 null/undefined 时回落 —— 字段名猜错一次，
   * 全部 query 参数静默变成空，症状是「上传照片说缺少 studentId，
   * 而同样的值放进 body 就正常」。字段名与来源的**唯一真值**在 shared/query.js。
   */
  const query = readQueryParameters(event);

  const raw = event?.isBase64Encoded
    ? Buffer.from(event?.body ?? '', 'base64')
    : Buffer.from(event?.body ?? '', 'utf8');

  /**
   * 这是 JSON 还是二进制？判据与 dev-server **逐字相同**（含「空 content-type
   * 当作 JSON」那条宽松规则）：两条外壳对同一个请求必须做出同样的判断，
   * 否则会出现「本机跑得好好的、发上去参数全丢」—— 而那种现象会被归因到别处。
   */
  const contentType = String(headers['content-type'] ?? '').toLowerCase();
  const isBinary = contentType !== '' && !contentType.includes('json');

  let body = {};
  if (raw.length > 0 && !isBinary) {
    try {
      body = JSON.parse(raw.toString('utf8'));
    } catch {
      // 交给路由去报「字段缺失」不合适 —— 那会把「JSON 坏了」说成「参数没填」。
      body = null;
    }
  }

  return {
    method,
    pathname: normalizePath(event?.path ?? event?.rawPath ?? http.path ?? '/'),
    query,
    headers,
    body,
    bytes: isBinary && raw.length > 0 ? raw : null,
    // 云函数网关在 requestContext 里给来源 IP（转发头缺失时的兜底）。
    remoteAddress: http.sourceIp ?? event?.requestContext?.sourceIp ?? '',
  };
}

/**
 * 抹平网关前缀。
 *
 * API 网关通常会在路径前面加一段（`/prod/...`、`/release/api/...`），
 * 而路由表是从 `/data/` 与 `/auth/` 开始的。不处理的话，线上会出现
 * 「本地跑得好好的，发上去全是 404」，且 404 的响应体看起来完全正常。
 *
 * 注意**不能**按前缀猜公开与受保护（那是 `app.js` 里刻意避免的做法）——
 * 这里只做「把前缀切掉」，判断哪条路公开仍然由路由表决定。
 */
function normalizePath(path) {
  const p = path.startsWith('/') ? path : `/${path}`;
  if (p === '/health' || p.endsWith('/health')) return '/health';
  if (p.startsWith('/data/') || p.startsWith('/auth/')) return p;
  const indexes = ['/data/', '/auth/']
    .map((s) => p.indexOf(s))
    .filter((i) => i >= 0);
  return indexes.length > 0 ? p.slice(Math.min(...indexes)) : p;
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
