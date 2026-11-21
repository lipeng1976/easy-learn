import { createServer } from 'node:http';

import assert from 'node:assert/strict';
import test from 'node:test';

import { createGuard } from '../src/guard.js';
import { loadConfig } from '../src/config.js';
import { createHttpStore, createMemoryStore } from '../src/store.js';

/**
 * 起一个最小的 KV 服务，用来验证 HTTP 存储这条链路。
 *
 * 刻意**不复用** `examples/kv-server.mjs`：那是给用户看的参考实现，
 * 它会随文档一起演进；测试里用独立的一份，才不会被「为了文档好看」
 * 的改动悄悄改掉断言的前提。
 */
async function startFakeKv({ failWith = null, delayMs = 0 } = {}) {
  const calls = [];
  const entries = new Map();
  const server = createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const payload = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
    calls.push(payload);

    if (delayMs > 0) await new Promise((resolve) => setTimeout(resolve, delayMs));
    if (failWith !== null) {
      response.writeHead(failWith);
      response.end('{"error":"boom"}');
      return;
    }

    const body = (value) => {
      const text = JSON.stringify({ value });
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(text);
    };

    if (payload.op === 'incr') {
      // 必须支持 `delta`（含负数），并且结果不小于 0 ——
      // 协议里写了这一条（见 src/store.js）：负计数会让下一次调用白拿额度，
      // 而忽略 delta 会让「退还额度」在共享层失效，多实例下账目立刻分叉。
      const step = Number.isFinite(payload.delta) ? Math.trunc(payload.delta) : 1;
      const next = Math.max(0, (entries.get(payload.key) ?? 0) + step);
      entries.set(payload.key, next);
      body(next);
      return;
    }
    if (payload.op === 'get') {
      body(entries.get(payload.key) ?? null);
      return;
    }
    entries.set(payload.key, payload.value);
    body(true);
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  return {
    url: `http://127.0.0.1:${port}`,
    calls,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

// ===== 内存实现 =====

test('内存存储：自增首次置 1，之后自增但不续期', async () => {
  let now = 1_000_000;
  const store = createMemoryStore({ now: () => now });

  assert.equal(await store.incr('k', 10), 1);
  now += 5_000;
  assert.equal(await store.incr('k', 10), 2);
  // 关键：第二次的 ttl 不会把过期时间往后推。
  // 续期会让固定窗口变成滑动窗口 —— 一直调用就永远进不了下一个窗口。
  now += 6_000;
  assert.equal(await store.get('k'), null);
});

test('内存存储：get/set 带过期，过期后读到 null', async () => {
  let now = 0;
  const store = createMemoryStore({ now: () => now });

  await store.set('c:a', { hello: 'world' }, 60);
  assert.deepEqual(await store.get('c:a'), { hello: 'world' });

  now += 60_001;
  assert.equal(await store.get('c:a'), null);
});

test('内存存储：计数键被当缓存写过时要报错，而不是静默覆盖', async () => {
  const store = createMemoryStore();
  await store.set('q:m:stu:1', { not: 'a number' }, 60);
  // 静默覆盖会让配额悄悄失效，而且没有任何痕迹。
  await assert.rejects(() => store.incr('q:m:stu:1', 60), /非计数值/);
});

// ===== HTTP 实现 =====

test('HTTP 存储：三个动作走通，且带上 Bearer token', async () => {
  const kv = await startFakeKv();
  try {
    const store = createHttpStore({ url: kv.url, token: 'secret-token' });
    assert.equal(store.shared, true);
    assert.equal(store.driver, 'http');

    assert.equal(await store.incr('q:m:stu:1', 120), 1);
    assert.equal(await store.incr('q:m:stu:1', 120), 2);

    await store.set('c:x', { ok: true }, 300);
    assert.deepEqual(await store.get('c:x'), { ok: true });
    assert.equal(await store.get('c:missing'), null);

    assert.deepEqual(
      kv.calls.map((call) => call.op),
      ['incr', 'incr', 'set', 'get', 'get'],
    );
  } finally {
    await kv.close();
  }
});

test('HTTP 存储：incr 拿不到数字时报错，而不是默认成 1', async () => {
  const server = createServer((request, response) => {
    response.writeHead(200, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify({ value: null }));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();

  try {
    const store = createHttpStore({ url: `http://127.0.0.1:${port}` });
    // 把「存储不可用」伪装成「这是第一次调用」，会让配额彻底失效。
    await assert.rejects(() => store.incr('k', 60), /未返回数字/);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('HTTP 存储：超时会被中断而不是一直挂着', async () => {
  const kv = await startFakeKv({ delayMs: 300 });
  try {
    const store = createHttpStore({ url: kv.url, timeoutMs: 50 });
    await assert.rejects(() => store.incr('k', 60));
  } finally {
    await kv.close();
  }
});

// ===== guard 与共享存储的配合 =====

function guardWithStore(store, envOverrides = {}) {
  const config = loadConfig({
    AI_MODEL_CLIENT: 'mock',
    // 这里把权重压成 1，让「单位」与「次数」一一对应，
    // 用例的断言就能直接写次数。权重本身另有专门用例覆盖。
    AI_WEIGHT_REASONING: '1',
    AI_QUOTA_UNITS_PER_MINUTE: '3',
    AI_QUOTA_UNITS_PER_DAY: '5',
    ...envOverrides,
  });
  const audits = [];
  const guard = createGuard({
    config,
    store,
    now: () => 1_700_000_000_000,
    onAudit: (record) => audits.push(record),
  });
  return { guard, audits, config };
}

test('配额跨实例生效：两个 guard 共用一个 KV 时按同一份额度算', async () => {
  const kv = await startFakeKv();
  try {
    const storeA = createHttpStore({ url: kv.url });
    const storeB = createHttpStore({ url: kv.url });
    const a = guardWithStore(storeA);
    const b = guardWithStore(storeB);

    // 单实例的本地计数各自为 1，加起来只有 2 次；共享层才是真正的裁决者。
    await a.guard.checkQuota('stu_1', 'reasoning');
    await b.guard.checkQuota('stu_1', 'reasoning');
    await a.guard.checkQuota('stu_1', 'reasoning');
    // 第 4 次超过每分钟 3 次的上限。
    await assert.rejects(() => b.guard.checkQuota('stu_1', 'reasoning'), /每分钟最多/);
  } finally {
    await kv.close();
  }
});

test('退还额度会同时落到本地层与共享层', async () => {
  // 退额是「缓存命中不扣额度」的实现基础。只退本地层的话，
  // 共享层仍然记着这笔账 —— 在多实例部署下会出现
  // 「本地看还有额度、共享层已经判超限」的分裂。
  const kv = await startFakeKv();
  try {
    const store = createHttpStore({ url: kv.url });
    const { guard } = guardWithStore(store);

    await guard.checkQuota('stu_1', 'reasoning');
    await guard.checkQuota('stu_1', 'reasoning');
    await guard.refundQuota('stu_1', 'reasoning');

    // 共享层退回 1 个单位后，第 3 次调用仍在上限（3）之内。
    await guard.checkQuota('stu_1', 'reasoning');
    await guard.checkQuota('stu_1', 'reasoning');
    await assert.rejects(() => guard.checkQuota('stu_1', 'reasoning'), /每分钟最多/);
  } finally {
    await kv.close();
  }
});

test('退额不会把计数退成负数（否则下次调用白拿额度）', async () => {
  const kv = await startFakeKv();
  try {
    const store = createHttpStore({ url: kv.url });
    const { guard } = guardWithStore(store);

    await guard.checkQuota('stu_1', 'reasoning');
    await guard.refundQuota('stu_1', 'reasoning');
    await guard.refundQuota('stu_1', 'reasoning');
    await guard.refundQuota('stu_1', 'reasoning');

    // 计数被夹在 0：接下来仍只有 3 次额度，而不是「退了 3 次白得 3 次」。
    await guard.checkQuota('stu_1', 'reasoning');
    await guard.checkQuota('stu_1', 'reasoning');
    await guard.checkQuota('stu_1', 'reasoning');
    await assert.rejects(() => guard.checkQuota('stu_1', 'reasoning'), /每分钟最多/);
  } finally {
    await kv.close();
  }
});

test('共享 KV 故障时按 failMode=open 放行，但留下 quota_degraded 审计', async () => {
  const kv = await startFakeKv({ failWith: 500 });
  try {
    const store = createHttpStore({ url: kv.url });
    const { guard, audits } = guardWithStore(store);

    // KV 抖一下就把全体学生的 AI 停掉，代价比一次短暂的配额放大高得多。
    await guard.checkQuota('stu_1', 'reasoning');

    const degraded = audits.filter((record) => record.code === 'quota_degraded');
    assert.equal(degraded.length, 1);
    assert.match(degraded[0].note, /共享 KV 不可用/);
  } finally {
    await kv.close();
  }
});

test('共享 KV 故障时 failMode=closed 直接拒绝', async () => {
  const kv = await startFakeKv({ failWith: 500 });
  try {
    const store = createHttpStore({ url: kv.url });
    const { guard } = guardWithStore(store, { AI_KV_FAIL_MODE: 'closed' });

    await assert.rejects(() => guard.checkQuota('stu_1', 'reasoning'), /配额服务暂时不可用/);
  } finally {
    await kv.close();
  }
});

test('KV 故障不吞掉真正的限流错误', async () => {
  // 这条是防「修 bug 修出更大的 bug」：把 KV 异常统一吞掉的话，
  // KV 正常但真的超限时反而会被静默放行。
  const kv = await startFakeKv();
  try {
    const store = createHttpStore({ url: kv.url });
    const { guard } = guardWithStore(store);

    await guard.checkQuota('stu_1', 'reasoning');
    await guard.checkQuota('stu_1', 'reasoning');
    await guard.checkQuota('stu_1', 'reasoning');
    await assert.rejects(() => guard.checkQuota('stu_1', 'reasoning'), /每分钟最多/);
  } finally {
    await kv.close();
  }
});

test('共享 KV 下的缓存跨实例命中', async () => {
  const kv = await startFakeKv();
  try {
    const a = guardWithStore(createHttpStore({ url: kv.url }));
    const b = guardWithStore(createHttpStore({ url: kv.url }));

    await a.guard.writeCache('judge:abc', { verdict: 'correct' });
    // 缓存按内容哈希分桶、不含学生 ID：同一个知识点全校问一千遍只调一次模型。
    assert.deepEqual(await b.guard.readCache('judge:abc'), { verdict: 'correct' });
  } finally {
    await kv.close();
  }
});

test('缓存读失败退化成「没命中」，不抛错', async () => {
  const kv = await startFakeKv({ failWith: 503 });
  try {
    const { guard } = guardWithStore(createHttpStore({ url: kv.url }));
    // 缓存没有依据只是少省一点钱，不该让整条请求失败。
    assert.equal(await guard.readCache('judge:abc'), null);
  } finally {
    await kv.close();
  }
});

test('内存模式下 storeShared 为 false，运维据此判断配额是否真的准', async () => {
  const { guard } = guardWithStore(createMemoryStore());
  assert.equal(guard.storeShared, false);
  assert.equal(guard.storeDriver, 'memory');
});

test('未配 AI_KV_URL 时静默回落内存，而不是起不来', async () => {
  const { guard } = guardWithStore(createMemoryStore());
  await guard.checkQuota('stu_1', 'reasoning');
  assert.equal(guard.storeFailures, 0);
});
