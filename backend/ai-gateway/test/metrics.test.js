import assert from 'node:assert/strict';
import test from 'node:test';

import { loadConfig } from '../src/config.js';
import { createGateway } from '../src/handler.js';

/**
 * 成本看板（`/ai/metrics`）。
 *
 * 这些用例的重点**不是「算得对不对」**，而是「不知道的时候会不会装知道」——
 * 成本看板最容易犯的错不是算错，而是在缺单价、缺 usage 的情况下
 * 报出一个看起来很精确的数字，然后被拿去当经营依据。
 *
 * 用注入的假模型而不是 mock 客户端：需要**指定的 usage** 才能验算成本，
 * 而 mock 的 usage 恒为 0（它不该为了测试好看而编一个 token 数出来）。
 */
class FixedUsageModelClient {
  constructor(usage) {
    this.usage = usage;
    this.calls = [];
  }

  capabilities() {
    return { vision: true, reasoning: true, light: true };
  }

  async complete({ capability, schema }) {
    this.calls.push(capability);
    return {
      value: fixtureFor(schema.name),
      model: `fixed-${capability}`,
      usage: this.usage,
      finishReason: 'stop',
    };
  }
}

/** 一份能通过 schema 校验的最小输出。 */
function fixtureFor(name) {
  switch (name) {
    case 'homework_check':
      return { score: 90, summary: '整体不错', items: [] };
    case 'review_judge':
      return { verdict: 'correct', score: 100, comment: '正确' };
    case 'review_explain':
      return {
        knowledgePoint: '分数加减',
        position: '第 2 步',
        whyWrong: '通分错误',
        steps: ['先通分'],
        pitfalls: [],
        mnemonic: '',
      };
    case 'review_practice':
      return { questions: [], referenceAnswer: '先通分再加减' };
    case 'report_reference_answers':
      return { answers: [{ index: 0, referenceAnswer: '先通分再加减' }] };
    default:
      return { ok: true };
  }
}

function build(envOverrides = {}, model = new FixedUsageModelClient({
  prompt_tokens: 1000,
  completion_tokens: 500,
})) {
  const config = loadConfig({
    AI_MODEL_CLIENT: 'mock',
    AI_UPLOAD_URL_BASE: 'https://gw.test',
    AI_UPLOAD_SIGNING_SECRET: 'test-secret',
    ...envOverrides,
  });
  const gateway = createGateway({
    config,
    model,
    now: () => Date.parse('2026-09-15T10:00:00Z'),
  });
  return { gateway, model };
}

async function call(gateway, { method = 'POST', path, body, headers = {} }) {
  const response = await gateway.handle({
    method,
    path,
    headers: { 'x-student-id': 'stu_test', ...headers },
    body,
  });
  const isJson = String(response.headers['Content-Type']).includes('json');
  return {
    status: response.status,
    json: isJson && response.body !== '' ? JSON.parse(response.body) : null,
  };
}

/** 一份最小可用的内联图片（只要能让 media 校验通过）。 */
const IMAGE = { base64: 'aGVsbG8=', mimeType: 'image/jpeg' };

/** 三次判定（强推理档）+ 一次批改（视觉档）。 */
async function exercise(gateway) {
  for (const answer of ['1', '2', '3']) {
    await call(gateway, {
      path: '/ai/review/judge',
      body: { studentAnswer: answer, referenceAnswer: answer },
    });
  }
  // 用批改（视觉档）而不是 `review/practice`：后者虽然也是「一次调用」，
  // 但它和判定**同属推理档**，跨不了能力档位 ——
  // 于是一旦真去算成本，「按能力分别计价」「总额是逐级相加」这两条
  // 就都没有验到（只有一个档位时，总额恰好等于它自己，写错也看不出来）。
  await call(gateway, {
    path: '/ai/homework/check',
    body: { subject: '数学', title: '口算', images: [IMAGE] },
  });
}

// ===== 口径 =====

test('看板如实标明是单实例口径，不假装是全局数字', async () => {
  const { gateway } = build();
  await exercise(gateway);

  const data = (await call(gateway, { method: 'GET', path: '/ai/metrics' })).json.data;
  assert.equal(data.scope, 'instance');
  assert.match(data.scopeNote, /多实例/);
  // 开一个时间点，让「统计的是哪个窗口」可追溯。
  assert.ok(Date.parse(data.since) > 0);
});

// ===== 成本：不知道就说不知道 =====

test('没配单价时报「成本未知」，而不是拿估算值冒充实际成本', async () => {
  const { gateway } = build();
  await exercise(gateway);

  const data = (await call(gateway, { method: 'GET', path: '/ai/metrics' })).json.data;
  assert.equal(data.pricing.state, 'none');
  assert.equal(data.totals.cost, null, '未配单价时必须为空，不能是 0');
  assert.match(data.costNote, /未配置模型单价/);
  // 用量照旧要有：成本空不代表用量空。
  assert.equal(data.totals.modelCalls, 4);
  assert.equal(data.totals.tokensIn, 4000);
  assert.equal(data.totals.tokensOut, 2000);
});

test('配齐单价后按能力分别计价，总额是逐级相加', async () => {
  const { gateway } = build({
    // 元 / 千 token
    AI_PRICE_VISION_IN: '0.008',
    AI_PRICE_VISION_OUT: '0.020',
    AI_PRICE_REASONING_IN: '0.001',
    AI_PRICE_REASONING_OUT: '0.002',
    AI_PRICE_LIGHT_IN: '0.0005',
    AI_PRICE_LIGHT_OUT: '0.001',
  });
  await exercise(gateway);

  const data = (await call(gateway, { method: 'GET', path: '/ai/metrics' })).json.data;
  assert.equal(data.pricing.state, 'full');

  const byCap = Object.fromEntries(
    data.byCapability.map((item) => [item.capability, item]),
  );
  // 3 次判定：1000 in / 500 out 各一次 → 3 × (1×0.001 + 0.5×0.002) = 0.006
  assert.equal(byCap.reasoning.cost, 0.006);
  // 1 次视觉：1×0.008 + 0.5×0.020 = 0.018
  assert.equal(byCap.vision.cost, 0.018);
  // 总计逐级相加，而不是把三级的 token 汇总乘一个价
  assert.equal(data.totals.cost, 0.024);
  assert.equal(data.costIsLowerBound, false);
});

test('有调用没返回 usage 时成本是下限，并单独计数', async () => {
  // 这条防的是「安静地少报」：厂商在某些响应里省略 usage 时，
  // 那几次调用的 token 数无从得知。不单独计数的话，
  // 看板会报出一个偏小的数字，而看不出偏了多少。
  const { gateway } = build(
    {
      AI_PRICE_VISION_IN: '0.008',
      AI_PRICE_VISION_OUT: '0.020',
      AI_PRICE_REASONING_IN: '0.001',
      AI_PRICE_REASONING_OUT: '0.002',
      AI_PRICE_LIGHT_IN: '0.0005',
      AI_PRICE_LIGHT_OUT: '0.001',
    },
    new FixedUsageModelClient(null),
  );

  await exercise(gateway);
  const data = (await call(gateway, { method: 'GET', path: '/ai/metrics' })).json.data;

  assert.equal(data.totals.modelCalls, 4);
  assert.equal(data.totals.usageMissing, 4);
  assert.equal(data.costIsLowerBound, true);
  assert.match(data.costNote, /成本是\*\*下限\*\*/);
  // token 数不可知时留空，而不是写 0 —— 0 会被读成「不花钱」。
  assert.equal(data.totals.tokensIn, 0);
});

// ===== 计数：缓存与规则要分开 =====

test('缓存命中计入调用次数但不计模型用量与成本', async () => {
  // 「省了多少」是看板要回答的问题之一，而它只能由
  // 「总调用数 - 模型调用数」得到。两者混在一起就答不了。
  const { gateway, model } = build({
    AI_PRICE_VISION_IN: '0.008',
    AI_PRICE_VISION_OUT: '0.020',
    AI_PRICE_REASONING_IN: '0.001',
    AI_PRICE_REASONING_OUT: '0.002',
    AI_PRICE_LIGHT_IN: '0.0005',
    AI_PRICE_LIGHT_OUT: '0.001',
  });
  const body = { studentAnswer: 'a', referenceAnswer: 'a' };

  await call(gateway, { path: '/ai/review/judge', body });
  await call(gateway, { path: '/ai/review/judge', body }); // 命中缓存

  const data = (await call(gateway, { method: 'GET', path: '/ai/metrics' })).json.data;
  assert.equal(model.calls.length, 1, '第二次不该调模型');
  assert.equal(data.totals.calls, 2);
  assert.equal(data.totals.cached, 1);
  assert.equal(data.totals.modelCalls, 1);
  assert.equal(data.totals.cost, 0.002);
});

test('规则直接判定的调用单独计数（它没花钱，但也是业务量）', async () => {
  const { gateway, model } = build();
  await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: '', referenceAnswer: 'a' },
  });

  const data = (await call(gateway, { method: 'GET', path: '/ai/metrics' })).json.data;
  assert.equal(model.calls.length, 0);
  assert.equal(data.totals.ruleCalls, 1);
  assert.equal(data.totals.modelCalls, 0);
});

test('失败按错误码分类，达到额度的拒绝可被单独看见', async () => {
  const { gateway } = build({
    AI_WEIGHT_REASONING: '1',
    AI_WEIGHT_VISION: '1',
    AI_QUOTA_UNITS_PER_DAY: '1',
  });
  await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: 'a', referenceAnswer: 'a' },
  });
  await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: 'b', referenceAnswer: 'b' },
  });

  const data = (await call(gateway, { method: 'GET', path: '/ai/metrics' })).json.data;
  assert.equal(data.byCode.quota_exhausted, 1);
  assert.equal(data.totals.failed, 1);
});

test('延迟给出分位，样本为空时是 null 而不是 0', async () => {
  const { gateway } = build();
  const empty = (await call(gateway, { method: 'GET', path: '/ai/metrics' })).json.data;
  assert.deepEqual(empty.latencyMs, { samples: 0, p50: null, p95: null, max: null });

  await exercise(gateway);
  const data = (await call(gateway, { method: 'GET', path: '/ai/metrics' })).json.data;
  assert.ok(data.latencyMs.samples > 0);
  assert.equal(typeof data.latencyMs.p95, 'number');
});

test('按路径聚合：能看出哪个业务动作最贵', async () => {
  const { gateway } = build();
  await exercise(gateway);

  const data = (await call(gateway, { method: 'GET', path: '/ai/metrics' })).json.data;
  const byPath = Object.fromEntries(data.byPath.map((item) => [item.path, item]));
  assert.equal(byPath['/ai/review/judge'].modelCalls, 3);
  // 路径桶要带能力档位：只报单位数看不出「8 个单位算贵还是便宜」。
  assert.equal(byPath['/ai/homework/check'].capability, 'vision');
  assert.equal(byPath['/ai/review/judge'].capability, 'reasoning');
});

// ===== 访问控制 =====

test('配了看板口令就要求带上它（用量数据不该公开可读）', async () => {
  const { gateway } = build({ AI_METRICS_TOKEN: 's3cret' });

  const denied = await call(gateway, { method: 'GET', path: '/ai/metrics' });
  const wrong = await call(gateway, {
    method: 'GET',
    path: '/ai/metrics',
    headers: { 'x-metrics-token': 'nope' },
  });
  const allowed = await call(gateway, {
    method: 'GET',
    path: '/ai/metrics',
    headers: { 'x-metrics-token': 's3cret' },
  });

  assert.equal(denied.status, 401);
  assert.equal(wrong.status, 401);
  assert.equal(allowed.status, 200);
});

test('看板不占学生配额（运维看数据不该消耗学生的额度）', async () => {
  const { gateway } = build({
    AI_WEIGHT_REASONING: '1',
    AI_QUOTA_UNITS_PER_MINUTE: '1',
  });

  const quota = (await call(gateway, { method: 'GET', path: '/ai/health' })).json.data.quota;
  assert.ok(quota.unitsPerDay > 0);

  await call(gateway, { method: 'GET', path: '/ai/metrics' });
  await call(gateway, { method: 'GET', path: '/ai/metrics' });
  // 额度若被看板吃掉，这次判定就会 429。
  const judged = await call(gateway, {
    path: '/ai/review/judge',
    body: { studentAnswer: 'a', referenceAnswer: 'a' },
  });
  assert.equal(judged.status, 200);
});
