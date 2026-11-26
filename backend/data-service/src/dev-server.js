#!/usr/bin/env node
/**
 * 本机开发的 HTTP 外壳。
 *
 * 云函数入口用的是同一个 `createApp` —— 两者只差「请求怎么进来的」。
 * 刻意不引任何 HTTP 框架：ai-gateway 就是零依赖的 Node ESM，数据服务保持一致，
 * 部署时不用打包 node_modules，冷启动也少一截。
 *
 * 连接信息全部走环境变量（见 db.js 的 createPool）：
 *   PGHOST / PGPORT / PGUSER / PGPASSWORD / PGDATABASE / PG_POOL_MAX
 *   PG_AUTH_USER / PG_AUTH_PASSWORD / PG_AUTH_POOL_MAX   鉴权连接（app_auth）
 *   AI_SESSION_SECRET  会话签名密钥（与网关同一把；不设则所有 /data/* 请求都判未配置）
 *   PORT               监听端口，默认 8788
 *   BIND_HOST          监听地址，默认 127.0.0.1（只允许本机连）。见下方长注释
 *   CORS_ALLOW_ORIGIN  额外放行的来源（逗号分隔；`*` 表示全部。默认只放本机来源）
 */
import { createServer } from 'node:http';

import { createApp } from './app.js';
import { createAiGatewayClient } from './ai_client.js';
import { validateConfig } from './config-check.js';
import { assertAuthRoleScoped, assertRlsEnforced, createPool } from './db.js';
import {
  createImageStoreFor,
  parsePhotoQuota,
  parseQuotaWarnRemaining,
} from './image-store-factory.js';

const PORT = Number(process.env.PORT ?? 8788);
/**
 * 监听地址。**默认只绑回环**，要手机连才显式打开（`BIND_HOST=0.0.0.0`）。
 *
 * 这条默认值是刻意收紧的，因为原先跑的是 `server.listen(PORT)` —— 不写 host
 * 时 Node 绑 `0.0.0.0`，也就是**同局域网内任何人都能连**。而这个服务里是
 * 真实账号与作业数据，`/auth/login` 又是公开端点：等于同一家咖啡店里
 * 任何人都能对着你的库爆破口令，而且**全程没有任何症状**。
 *
 * 更值得记一笔的是下面那段 CORS 注释的措辞：它写着「所以默认只认本机来源
 * （localhost / 127.0.0.1 / [::1]）」。那个承诺**只对浏览器成立** ——
 * CORS 是浏览器强加给自己页面的规矩，curl、脚本、以及本项目自己的手机 App
 * 一个都不发 `Origin` 头，`corsHeaders()` 直接走 `if (!origin) return {}` 放行。
 *
 * 也就是说：把「谁能连上」寄托在 CORS 上，保护范围只有浏览器那一小块。
 * 真正管用的是**绑哪个网卡**。这两件事是互补的，不是一件事。
 */
const BIND_HOST = process.env.BIND_HOST ?? '127.0.0.1';
/**
 * 请求体上限。
 *
 * 原来的注释是「图片不走这条路（它走对象存储）」—— 那时候图片字节确实
 * 不经手数据服务。现在作业照片上传走 `POST /data/homework/images/upload`，
 * 体就是图片本身，所以这个值必须按**一张手机照片**来给，而不是按 JSON 给。
 * 1MB 的老值会让每一张正常照片都撞 413，而 413 的表现是「照片传不上去」
 * 却看不出是限额问题。
 */
const MAX_BODY_BYTES = Number(process.env.DATA_MAX_BODY_BYTES ?? 12 * 1024 * 1024);

/**
 * 跨源放行（**只对本机开发服务生效**，云函数入口那一侧没这段）。
 *
 * ## 为什么必须有它
 *
 * Flutter Web 产物是由一个**静态服务器**端出来的（`flutter run -d chrome`
 * 自己起一个随机端口，`flutter build web` + 自建静态服务则是一个固定端口），
 * 而数据服务在 8788 —— 两者**来源不同**。于是浏览器会在每一个请求前先发一次
 * `OPTIONS` 预检，而预检失败的表现是客户端收到一个 `network` 错误。
 *
 * 这正是最坏的一种失败：客户端把它归类成「连不上数据服务」，而服务明明活着、
 * `curl` 也打得通。排查方向会一路走到「是不是端口填错了」上去。
 *
 * ## 为什么不写 `*`
 *
 * 放行全部来源的话，用户在浏览器里随手打开的**任意**网页都能向
 * `127.0.0.1:8788` 发请求并读到响应。这个服务里是真实的账号与作业数据，
 * 而 `/auth/login` 是公开端点 —— 等于给每个网页一个免费的口令爆破接口。
 * 所以默认只认本机来源（`localhost` / `127.0.0.1` / `[::1]`，任意端口），
 * 其他来源要显式用 `CORS_ALLOW_ORIGIN` 放行。
 *
 * 回显 `origin` 而不是回 `*`：`*` 会让将来某天给请求带上凭证（cookie）时
 * 静默失效，而那种失效只有在浏览器控制台里看得见。
 *
 * 生产环境这件事应该由网关/边缘统一处理 —— 那样只有一处配置，
 * 而不是每个函数各自实现一份、且各自实现得略有不同。
 */
const CORS_ALLOW_ORIGIN = process.env.CORS_ALLOW_ORIGIN ?? '';
const LOCAL_ORIGIN = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/;
const EXTRA_ORIGINS = CORS_ALLOW_ORIGIN
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

/// 本地时间的 `HH:MM:SS`，只用于访问日志。
///
/// 为什么不用 `toISOString()`：那是 UTC，本机在 +8，日志里会出现
/// 「凌晨 16:00」这种与用户描述对不上的时刻 —— 排查时白白多一层换算。
function localStamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

function corsHeaders(origin) {
  if (!origin) return {}; // 不是浏览器跨源请求（curl、探针、云函数），不需要这些头
  const allowed = CORS_ALLOW_ORIGIN === '*'
    || LOCAL_ORIGIN.test(origin)
    || EXTRA_ORIGINS.includes(origin);
  if (!allowed) return {};
  return {
    'access-control-allow-origin': origin,
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    // `authorization` 必须列出来：它不是「简单头」，浏览器不会自动放行，
    // 漏掉它的症状是**带 token 的请求全被拦、不带 token 的（登录）却正常**。
    'access-control-allow-headers': 'authorization, content-type, accept',
    'access-control-max-age': '600',
    // 响应随来源变化，缓存必须按来源分开 —— 否则一个来源的放行头会被复用给另一个。
    vary: 'Origin',
  };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error('请求体过大'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    // 给出去的是 **Buffer**，不是字符串。这里是图片上传能成立的关键：
    // `toString('utf8')` 会把任意二进制按 UTF-8 解码，非法字节被替换成 U+FFFD，
    // 于是「收下来的字节」与「发出去的字节」不再相同 —— 而且**不会报错**，
    // 只会得到一张打不开的图。JSON 那一侧在解析时自己 `.toString('utf8')`。
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

/**
 * 配置自检（**在连库之前**跑）。
 *
 * 下面那三道闸（RLS、鉴权角色、照片存储）查的是「连上库之后」的事，
 * 而「密钥为空 / 用的是开发栈那把公开密钥」这类问题连库都不用连，
 * 症状却同样安静 —— 见 `config-check.js` 开头。**宁可起不来，也不要裸奔**。
 */
const { problems: configProblems, warnings: configWarnings } = validateConfig(process.env);
for (const w of configWarnings) {
  process.stderr.write(`[data-service] 警告：${w}\n`);
}
if (configProblems.length > 0) {
  throw new Error(`数据服务配置有问题：\n- ${configProblems.join('\n- ')}`);
}

const pool = createPool();
/**
 * 鉴权连接池。**必须显式传 user** —— `createPool` 的默认值取自 `PGUSER`，
 * 而那是应用角色 app_rls，用它连就等于没有鉴权连接（注册登录会一行也读不到）。
 */
const authPool = createPool({
  user: process.env.PG_AUTH_USER ?? 'app_auth',
  password: process.env.PG_AUTH_PASSWORD ?? undefined,
  max: Number(process.env.PG_AUTH_POOL_MAX ?? 3),
});
/**
 * 照片字节的存储（见 imagestore.js / ossimagestore.js）。
 *
 * 后端由 `IMAGE_DRIVER` 选：`fs`（默认，用 `IMAGE_ROOT_DIR`）或 `oss`。
 * 选择逻辑只有一处，见 image-store-factory.js。
 *
 * 这里刻意**不做「没配就悄悄退回本地存储」**：那种「友好降级」会把
 * 「服务端配漏了」表现成「家长端看不到图」，而后者一定会被当成客户端 bug 去查。
 * 约定是：没配 = 该功能如实报 `upload_not_configured`，其余 40 多条路由照常工作。
 *
 * 本机开发想连真 OSS 就设 `IMAGE_DRIVER=oss` 加 `OSS_*` 那几个变量 ——
 * 这也是**唯一能在上云前验证签名是否写对**的办法（见 scripts/probe-oss.mjs）。
 */
const imageStore = createImageStoreFor(process.env);

/**
 * 单学生照片张数上限（`IMAGE_QUOTA_PER_STUDENT`，默认 3000）。
 *
 * 非法值这里不管：上面的 `validateConfig` 已经把它归进 problems 并抛了。
 * 本机开发想验证「配额拦得住吗」，把这个值调成 2 再传三张就够了 ——
 * 不必真造三千行数据。
 */
const photoQuota = parsePhotoQuota(process.env.IMAGE_QUOTA_PER_STUDENT).quota;

/** 剩余不足多少张开始提示（`IMAGE_QUOTA_WARN_REMAINING`，默认 20，写 0 = 不提示）。 */
const photoWarnRemaining =
  parseQuotaWarnRemaining(process.env.IMAGE_QUOTA_WARN_REMAINING).warnRemaining;

/**
 * AI 网关（`AI_GATEWAY_BASE_URL`，本机开发栈是 `http://127.0.0.1:8787`）。
 *
 * 没配就是 `null`，只有 `/data/checkin/generate` 会回 `model_not_enabled`，
 * 其余路由照常 —— 与照片存储同样的取舍：一个可选能力不该拖死整个服务。
 *
 * ⚠️ 云上必须显式配这个变量（函数的公网 URL）。给一个「默认本机地址」的兜底
 * 会让云上静默指向不存在的 `127.0.0.1`，症状是「打卡永远出不了题」，
 * 而日志里看起来一切正常。
 */
const aiGatewayBaseUrl = process.env.AI_GATEWAY_BASE_URL ?? '';
const aiGateway = aiGatewayBaseUrl
  ? createAiGatewayClient({
    baseUrl: aiGatewayBaseUrl,
    timeoutMs: Number(process.env.AI_GATEWAY_TIMEOUT_MS) || 30_000,
  })
  : null;

const app = createApp({
  pool,
  authPool,
  sessionSecret: process.env.AI_SESSION_SECRET ?? '',
  imageStore,
  photoQuota,
  photoWarnRemaining,
  aiGateway,
  instanceId: process.env.SERVER_INSTANCE_ID ?? '',
  updatePackageDir: process.env.UPDATE_PACKAGE_DIR ?? '',
});

/**
 * 启动自检：**宁可起不来，也不要裸奔**。
 *
 * 两道闸，防的是同一类问题 —— 安全机制静默失效：
 *   · 用超级用户连库 → RLS 不生效（该挡的挡不住）；
 *   · 鉴权角色被多授权 → 一片表不受隔离（该关的没关）。
 * 两者都不报错、不会有症状，只会在某天变成一次数据泄露。
 */
const role = await assertRlsEnforced(pool);
const authRole = await assertAuthRoleScoped(authPool);

/**
 * 照片存储自检 —— 与上面两道闸**刻意不同**。
 *
 * 那两道是**安全机制**：RLS 没生效、鉴权角色被多授权，都是「不报错但会
 * 在某天变成数据泄露」的事，所以必须起不来。
 *
 * 存储是**功能**：`IMAGE_ROOT_DIR` 没配、或目录建不出来、或盘不可写。
 * 让它把整个服务拖死是过度的 —— 其余 40 多条路由（登录、作业、积分…）
 * 本来好好的。但它**必须在启动日志里说出来**：不说的话，第一次发现
 * 「照片存不下来」的时机是「学生拍完照点提交」，而那时排查方向
 * 会先走到客户端上。
 */
const storeCheck = await imageStore.assertReady();
const storeLine = storeCheck.ok
  ? `照片存储：${storeCheck.root}`
  : `⚠️  照片存储不可用 —— ${storeCheck.reason}`;

const server = createServer(async (req, res) => {
  const cors = corsHeaders(req.headers.origin);

  /**
   * 访问日志：**谁、从哪个地址、打了哪个端点、结果如何**。
   *
   * 加它的理由很具体（2026-10-20）：手机在外网连不上后台时，
   * 日志里只有启动信息，无法回答最关键的那个问题 ——
   * 「请求到底有没有到这台机器」。没有它就只能靠猜（VPN？防火墙？明文？），
   * 而这三者的现象完全一样：App 报「连不上」。
   *
   * ⚠️ 只记路径不记 body：登录口令在 body 里。
   * ⚠️ `remoteAddress` 是关键证据：`100.70.x` = 走了 Tailscale，
   * `192.168.3.x` = 局域网，`::1` = 本机自测。
   */
  const accessStartedAt = Date.now();
  const accessAt = localStamp();
  const remoteAddress = req.socket?.remoteAddress ?? '?';
  // UA 只留前 60 字符：足够区分「App（Dart/…）」与「手机浏览器（Mozilla/…）」，
  // 又不至于把整条 Chrome UA 写进日志。
  const ua = String(req.headers['user-agent'] ?? '').slice(0, 60);
  res.on('finish', () => {
    process.stdout.write(
      `[access] ${accessAt} ${req.method} ${req.url} ${res.statusCode} ${remoteAddress} `
        + `${Date.now() - accessStartedAt}ms${ua ? ` ua="${ua}"` : ''}\n`,
    );
  });

  // 预检必须在**读请求体之前**结束：OPTIONS 没有体，而且它压根不该进业务路由
  // （`createApp` 的路由表里没有 OPTIONS，走进去会得到一次 405）。
  if (req.method === 'OPTIONS') {
    res.writeHead(204, cors);
    res.end();
    return;
  }

  let raw = Buffer.alloc(0);
  try {
    raw = await readBody(req);
  } catch {
    res.writeHead(413, { ...cors, 'content-type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({
      ok: false,
      error: {
        code: 'payload_too_large',
        message: `请求体超过上限 ${Math.round(MAX_BODY_BYTES / 1024 / 1024)}MB`,
        retryable: false,
      },
    }));
    return;
  }

  const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);

  /**
   * 这是 JSON 还是二进制？
   *
   * 判据用 `content-type`，且**刻意保留宽松**：
   * - 空 → 当作 JSON。现有调用方有没带这个头的（`curl`、老客户端），
   *   要求它才能解析 JSON 会把「少一个头」变成「参数全丢」，
   *   而症状是「明明发了数据却报必填字段缺失」。
   * - 含 `json` → JSON。
   * - 其余（`image/jpeg` 等）→ 二进制，原样交给路由。
   *
   * 之所以不按路径判断：那等于把路由表复制到 HTTP 外壳里，
   * 将来加第二条二进制端点时必然会漏改这一处。
   */
  const contentType = String(req.headers['content-type'] ?? '').toLowerCase();
  const isBinary = contentType !== '' && !contentType.includes('json');

  let body = {};
  if (raw.length > 0 && !isBinary) {
    try {
      body = JSON.parse(raw.toString('utf8'));
    } catch {
      res.writeHead(400, { ...cors, 'content-type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ ok: false, error: { code: 'bad_request', message: '请求体不是合法 JSON' } }));
      return;
    }
  }

  const out = await app({
    method: req.method ?? 'GET',
    pathname: url.pathname,
    query: Object.fromEntries(url.searchParams.entries()),
    headers: req.headers,
    body,
    bytes: isBinary && raw.length > 0 ? raw : null,
    remoteAddress: remoteAddress,
  });

  res.writeHead(out.status, {
    ...cors,
    ...(out.headers ?? { 'content-type': 'application/json; charset=utf-8' }),
  });
  res.end(out.body);
});

server.listen(PORT, BIND_HOST, () => {
  // 日志里回显**真实的绑定地址**，别写死 127.0.0.1：绑了 0.0.0.0 还打印
  // 「监听 127.0.0.1」会让「手机为什么连不上」查错方向 —— 反过来，
  // 只绑回环却打印成局域网，排查的人会一头扎进防火墙。
  const shown = BIND_HOST === '0.0.0.0' ? '0.0.0.0（本机所有网卡，局域网可达）' : BIND_HOST;
  process.stdout.write(
    `[data-service] 监听 http://${shown}:${PORT}（应用角色=${role}，鉴权角色=${authRole}）\n`,
  );
  process.stdout.write(`[data-service] ${storeLine}\n`);
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    server.close(() => Promise.all([pool.end(), authPool.end()])
      .then(() => process.exit(0))
      .catch(() => process.exit(0)));
  });
}
