/**
 * 共享 KV 的**参考实现**。
 *
 * ⚠️ 仅用于本地联调与自动化测试。它把数据放在进程内存里，重启即丢，
 * 而且没有任何鉴权强度 —— **不要用于生产**。
 * 生产请接 Redis（火山引擎 Redis / 自建）或表格存储，
 * 只要按下面的协议实现 `incr` / `get` / `set` 三个动作即可。
 *
 * 它的实际用途是两件事：
 * 1. 让 `AI_KV_DRIVER=http` 这条链路能被真正跑通（而不是只有一份文档）
 * 2. 给「想自己实现一个 KV 适配器」的人一份可执行的协议说明
 *
 * 协议（见 `src/store.js` 的注释）：
 *
 * ```
 * POST /  { "op": "incr", "key": "q:m:stu_1:29241931", "ttlSeconds": 120, "delta": 8 }  -> { "value": 3 }
 * POST /  { "op": "get",  "key": "c:judge:ab12…" }                          -> { "value": {...} | null }
 * POST /  { "op": "set",  "key": "c:judge:ab12…", "value": {...}, "ttlSeconds": 600 } -> { "value": true }
 * ```
 *
 * 用法：
 * ```bash
 * node examples/kv-server.mjs                 # 监听 8788
 * PORT=9000 node examples/kv-server.mjs
 * ```
 * 然后给网关配：
 * ```bash
 * AI_KV_DRIVER=http AI_KV_URL=http://127.0.0.1:8788
 * ```
 */

import { createServer } from 'node:http';

const PORT = Number.parseInt(process.env.PORT ?? '8788', 10);
/** 与网关的 AI_KV_TOKEN 对应；留空表示不校验（仅限本地）。 */
const TOKEN = process.env.KV_TOKEN ?? '';

/** key -> {value, expiresAt} */
const entries = new Map();

function liveEntry(key) {
  const entry = entries.get(key);
  if (!entry) return null;
  if (entry.expiresAt <= Date.now()) {
    entries.delete(key);
    return null;
  }
  return entry;
}

/**
 * 自增。
 *
 * 三个语义细节必须和真实 Redis 一致，否则网关的配额判断会跑偏：
 * - 键不存在时置 `delta`（下限 0）并**带上 TTL**
 * - 键已存在时只自增，**不续期**（续期会让固定窗口变成滑动窗口，
 *   学生只要持续调用就永远不会进入下一个窗口）
 * - **支持负数 `delta`**（退还额度：缓存命中与规则短路没有产生模型费用），
 *   并且结果**不小于 0** —— 负计数会让下一次调用白拿一份额度。
 *   真实 Redis 的 `INCRBY` 允许负数但不会夹在 0，所以用 Redis 时
 *   这一条要靠 Lua 脚本或改用「只加不减 + 单独记退款数」来兜。
 */
function incr(key, ttlSeconds, delta = 1) {
  const step = Number.isFinite(delta) ? Math.trunc(delta) : 1;
  const entry = liveEntry(key);
  if (!entry) {
    const value = Math.max(0, step);
    entries.set(key, { value, expiresAt: Date.now() + ttlSeconds * 1000 });
    return value;
  }
  entry.value = Math.max(0, Number(entry.value) + step);
  return entry.value;
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    request.on('error', reject);
  });
}

const server = createServer(async (request, response) => {
  const send = (status, payload) => {
    const body = JSON.stringify(payload);
    response.writeHead(status, {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': Buffer.byteLength(body),
    });
    response.end(body);
  };

  if (request.method !== 'POST') {
    send(405, { error: 'method_not_allowed' });
    return;
  }

  if (TOKEN !== '') {
    const auth = String(request.headers.authorization ?? '');
    if (auth !== `Bearer ${TOKEN}`) {
      send(401, { error: 'unauthorized' });
      return;
    }
  }

  let payload;
  try {
    payload = JSON.parse(await readBody(request));
  } catch {
    send(400, { error: 'invalid_json' });
    return;
  }

  const key = String(payload?.key ?? '');
  if (key === '') {
    send(400, { error: 'missing_key' });
    return;
  }
  const ttl = Number.isFinite(Number(payload.ttlSeconds))
    ? Math.max(1, Math.trunc(Number(payload.ttlSeconds)))
    : 60;

  switch (payload?.op) {
    case 'incr':
      send(200, { value: incr(key, ttl, payload.delta) });
      return;
    case 'get': {
      const entry = liveEntry(key);
      send(200, { value: entry ? entry.value : null });
      return;
    }
    case 'set':
      entries.set(key, { value: payload.value ?? null, expiresAt: Date.now() + ttl * 1000 });
      send(200, { value: true });
      return;
    default:
      send(400, { error: 'unknown_op' });
  }
});

server.listen(PORT, '127.0.0.1', () => {
  // 只绑 127.0.0.1：这个进程没有任何生产级的鉴权，不该被局域网访问。
  console.log(`[kv-server] 已监听 http://127.0.0.1:${PORT}（内存实现，仅限本地联调）`);
});
