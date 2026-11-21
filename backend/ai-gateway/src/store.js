/**
 * 计数与缓存的后端存储。
 *
 * ## 为什么必须把这件事从 guard 里抽出来
 *
 * Serverless 函数按需拉起、随时回收，同一个学生的下一次请求很可能落在
 * 另一个实例上。把配额与缓存放在进程内存里，等于「每个实例各算一份」——
 * 5 个实例就是 5 倍配额，缓存命中率也随实例数线性下降。
 *
 * 所以内存实现只保留两个用途：
 * 1. **本地联调与自动化测试**（零依赖）
 * 2. **共享存储故障时的兜底**（见 guard.js 里的双层计数）
 *
 * 生产要配 `AI_KV_DRIVER=http` 指向 Redis / 表格存储之类的共享 KV。
 *
 * ## 接口约定
 *
 * 三个方法全部异步，语义对齐 Redis：
 * - `incr(key, ttlSeconds, delta = 1)` —— 不存在则置 `delta`（下限 0）并带上 TTL；
 *   存在则自增。`delta` 支持**负数**，用于「退还额度」（见 guard 的退款路径：
 *   缓存命中与纯规则短路没有产生模型费用，不该扣学生的额度）。
 *   **自增不续期**，因为 guard 用的键本身就带时间桶（`{学生}|{分钟桶}`），
 *   TTL 只负责回收，不参与窗口判定。
 *   计数结果**永不小于 0**：负计数会让下一次调用白拿一份额度。
 * - `get(key)` —— 缺失或过期返回 `null`
 * - `set(key, value, ttlSeconds)`
 *
 * 只存 JSON 可序列化的值（数字、字符串、对象）。不存二进制：
 * 作业照片走对象存储，缓存里只放模型结论。
 */

/** 内存实现。默认使用，也是共享存储不可用时的兜底。 */
export function createMemoryStore({ now = () => Date.now() } = {}) {
  /** key -> {value, expiresAt} */
  const entries = new Map();

  function liveEntry(key) {
    const entry = entries.get(key);
    if (!entry) return null;
    if (entry.expiresAt <= now()) {
      entries.delete(key);
      return null;
    }
    return entry;
  }

  return {
    driver: 'memory',
    shared: false,

    async incr(key, ttlSeconds, delta = 1) {
      const step = Number.isFinite(delta) ? Math.trunc(delta) : 1;
      const entry = liveEntry(key);
      if (!entry) {
        const value = Math.max(0, step);
        entries.set(key, {
          value,
          expiresAt: now() + ttlSeconds * 1000,
        });
        return value;
      }
      if (typeof entry.value !== 'number') {
        // 键被用混了（一半当计数、一半当缓存）。抛错而不是静默覆盖：
        // 静默覆盖会让配额悄悄失效，而且没有任何痕迹。
        throw new Error(`store: 键 ${key} 已被非计数值占用`);
      }
      entry.value = Math.max(0, entry.value + step);
      return entry.value;
    },

    async get(key) {
      const entry = liveEntry(key);
      return entry ? entry.value : null;
    },

    async set(key, value, ttlSeconds) {
      entries.set(key, { value, expiresAt: now() + ttlSeconds * 1000 });
    },

    /** 测试与运维用。 */
    size() {
      return entries.size;
    },

    clear() {
      entries.clear();
    },
  };
}

/**
 * HTTP 共享 KV 客户端。
 *
 * 协议刻意做到最小 —— 任何能实现「四个动作」的服务都能接：
 *
 * ```
 * POST {url}
 * Authorization: Bearer {token}
 * { "op": "incr", "key": "s1|29241931", "ttlSeconds": 120, "delta": 8 }
 * -> { "value": 7 }
 *
 * POST {url}  { "op": "get", "key": "k" }                 -> { "value": 7 | null }
 * POST {url}  { "op": "set", "key": "k", "value": {...}, "ttlSeconds": 600 }
 *                                                          -> { "value": true }
 * ```
 *
 * `delta` 缺省视为 1。**实现必须支持负数**（退还额度）并保证结果不小于 0 ——
 * 负计数会让下一次调用白拿一份额度。
 *
 * 用 POST + JSON 而不是「GET /incr/{key}」这类 REST 风格，是为了避免键里的
 * `|`、`:` 等字符在不同网关上的转义差异 —— 键的构造方（guard）不应该
 * 因为换了存储就要改键的形态。
 *
 * 参考实现见 `examples/kv-server.mjs`（仅用于本地联调，**不要用于生产**）。
 */
export function createHttpStore({
  url,
  token = '',
  timeoutMs = 1500,
  fetchImpl = globalThis.fetch,
  now = () => Date.now(),
}) {
  if (!url) throw new Error('createHttpStore 需要 url');

  async function call(payload) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetchImpl(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(token === '' ? {} : { Authorization: `Bearer ${token}` }),
        },
        body: JSON.stringify(payload),
        signal: controller.signal,
      });
      if (!response.ok) {
        throw new Error(`KV 返回 ${response.status}`);
      }
      const decoded = await response.json();
      if (decoded === null || typeof decoded !== 'object') {
        throw new Error('KV 响应不是 JSON 对象');
      }
      return decoded.value ?? null;
    } finally {
      clearTimeout(timer);
    }
  }

  return {
    driver: 'http',
    shared: true,
    endpoint: url,

    async incr(key, ttlSeconds, delta = 1) {
      const value = await call({ op: 'incr', key, ttlSeconds, delta });
      if (typeof value !== 'number' || !Number.isFinite(value)) {
        // 自增拿不到数字就等于配额判断没有依据。这里必须抛，
        // 不能默认成 1 —— 那会把「存储不可用」伪装成「这是第一次调用」。
        throw new Error(`KV incr 未返回数字：${JSON.stringify(value)}`);
      }
      return value;
    },

    async get(key) {
      return call({ op: 'get', key });
    },

    async set(key, value, ttlSeconds) {
      await call({ op: 'set', key, value, ttlSeconds });
    },
  };
}

/**
 * 按配置选一个存储。
 *
 * `AI_KV_URL` 为空时静默回落内存实现，而不是报错：
 * 环境变量漏配应当表现为「配额退化成单实例安全网」并留下一条告警，
 * 而不是让整个网关起不来 —— 那会连本地兜底都一起丢掉。
 */
export function createStore({ config, now, fetchImpl } = {}) {
  const kv = config?.kv ?? {};
  if (kv.driver === 'http' && kv.url !== '') {
    return createHttpStore({
      url: kv.url,
      token: kv.token ?? '',
      timeoutMs: kv.timeoutMs ?? 1500,
      now,
      ...(fetchImpl ? { fetchImpl } : {}),
    });
  }
  return createMemoryStore({ now });
}

/** 借用一个时钟，供需要「过期」语义的地方使用。 */
export const systemClock = () => Date.now();
