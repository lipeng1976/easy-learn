import test from 'node:test';
import assert from 'node:assert/strict';

import { ArkModelClient, buildRequestBody, shouldSendToolChoiceObject } from '../src/ark.js';
import { MODEL_PROVIDERS, loadConfig, validateConfig } from '../src/config.js';
import { createGateway } from '../src/handler.js';
import { Schemas } from '../src/schema.js';

/**
 * 模型厂商开关（`AI_MODEL_PROVIDER`）。
 *
 * ## 这组测试盯的是什么
 *
 * 「换厂商」这类改动的失败形态**全都不会报错**：
 *   · 思维链字段名不被认识 → 服务端静默忽略 → 讲解悄悄超时（看着像没用上 AI）
 *   · 模型名是另一家的 → 调用时才报 invalid_parameter_error，且未必带模型名
 *   · 厂商名拼错 → 回落到默认厂商，用甲家字段打乙家地址
 * 所以这里不测「函数返回了什么」，而是直接断言**发出去的请求体长什么样**，
 * 以及**配置错的组合能不能在启动时被拦下来**。
 *
 * 判据全部打在「被替换的那一侧」：断言 `body.thinking` / `body.enable_thinking`
 * 是否存在，而不是断言某个常量等于某个值。
 */

// ─────────────────────────────────────────────────────────────────
// 一、loadConfig：开关本身

test('loadConfig：不配 AI_MODEL_PROVIDER 就是方舟（既有部署零行为变化）', () => {
  const config = loadConfig({ ARK_API_KEY: 'k' });
  assert.equal(config.modelProvider, 'ark');
  assert.equal(config.ark.baseUrl, 'https://ark.cn-beijing.volces.com/api/v3');
});

test('loadConfig：选百炼后 baseUrl 换成百炼的端点', () => {
  const config = loadConfig({ AI_MODEL_PROVIDER: 'bailian', ARK_API_KEY: 'k' });
  assert.equal(config.modelProvider, 'bailian');
  assert.equal(config.ark.baseUrl, 'https://dashscope.aliyuncs.com/compatible-mode/v1');
});

test('loadConfig：ARK_BASE_URL 仍然可以盖掉预设（自建网关/本机模型的退路）', () => {
  const config = loadConfig({
    AI_MODEL_PROVIDER: 'bailian',
    ARK_BASE_URL: 'http://127.0.0.1:11434/v1',
  });
  assert.equal(config.ark.baseUrl, 'http://127.0.0.1:11434/v1');
});

test('loadConfig：方舟仍按区域拼地址，百炼不吃 ARK_REGION', () => {
  const ark = loadConfig({ AI_MODEL_PROVIDER: 'ark', ARK_REGION: 'cn-shanghai' });
  assert.equal(ark.ark.baseUrl, 'https://ark.cn-shanghai.volces.com/api/v3');

  // 百炼的端点固定，不该被 ARK_REGION 影响（否则会拼出一个不存在的域名）。
  const bailian = loadConfig({ AI_MODEL_PROVIDER: 'bailian', ARK_REGION: 'cn-shanghai' });
  assert.equal(bailian.ark.baseUrl, 'https://dashscope.aliyuncs.com/compatible-mode/v1');
});

test('loadConfig：认不出的厂商名不在这里拦（交给 validateConfig），且不崩', () => {
  const config = loadConfig({ AI_MODEL_PROVIDER: 'openai' });
  assert.equal(config.modelProvider, 'openai');
  assert.equal(config.modelProviderSpec, null);
  // 回落一个方舟地址，好让 validateConfig 的报错是「厂商名错」而不是别的。
  assert.match(config.ark.baseUrl, /volces\.com/);
});

// ─────────────────────────────────────────────────────────────────
// 二、validateConfig：配错了要在**启动时**拦

test('validateConfig：厂商名拼错 → 启动失败并列出可选项', () => {
  const problems = validateConfig(loadConfig({ AI_MODEL_PROVIDER: 'blian' }));
  const hit = problems.find((p) => p.includes('AI_MODEL_PROVIDER=blian'));
  assert.ok(hit, `应当报出厂商名不可用，实际：${JSON.stringify(problems)}`);
  // 报错必须给出可选项，否则运维只能去翻代码。
  assert.match(hit, /ark/);
  assert.match(hit, /bailian/);
});

test('validateConfig：选了百炼却填方舟的模型名 → 启动失败', () => {
  const config = loadConfig({
    AI_MODEL_PROVIDER: 'bailian',
    ARK_API_KEY: 'k',
    ARK_MODEL_REASONING: 'deepseek-v4-pro-ga-260813', // 方舟式：带 -YYMMDD
  });
  const problems = validateConfig(config);
  const hit = problems.find((p) => p.includes('deepseek-v4-pro-ga-260813'));
  assert.ok(hit, `应当报出模型名与厂商不匹配，实际：${JSON.stringify(problems)}`);
  assert.match(hit, /reasoning/);
});

test('validateConfig：方舟的接入点前缀（ep-）也认得出不是百炼的', () => {
  const config = loadConfig({
    AI_MODEL_PROVIDER: 'bailian',
    ARK_MODEL_VISION: 'ep-20260923120000-abcde',
  });
  const problems = validateConfig(config);
  assert.ok(problems.some((p) => p.includes('ep-20260923120000-abcde')));
});

test('validateConfig：百炼配百炼的模型名 → 不报（守卫不能变成路障）', () => {
  const config = loadConfig({
    AI_MODEL_PROVIDER: 'bailian',
    ARK_API_KEY: 'k',
    ARK_MODEL_VISION: 'qwen3-vl-plus',
    ARK_MODEL_REASONING: 'qwen3-max',
  });
  const problems = validateConfig(config);
  assert.equal(
    problems.filter((p) => p.includes('不像百炼')).length,
    0,
    `不该误报，实际：${JSON.stringify(problems)}`,
  );
});

test('validateConfig：模型名留空不算错（= 该能力未开通，是合法状态）', () => {
  const config = loadConfig({ AI_MODEL_PROVIDER: 'bailian', ARK_MODEL_LIGHT: '' });
  const problems = validateConfig(config);
  assert.equal(problems.filter((p) => p.includes('不像百炼')).length, 0);
});

test('validateConfig：百炼下**新上线的**模型名不该被拦（判据刻意宽松）', () => {
  // 百炼在持续上新。写死白名单的后果是「新模型一上线，老配置就拦下来了」。
  // 这里拿几个当下不存在但形态合法的名字验证宽松度。
  const config = loadConfig({
    AI_MODEL_PROVIDER: 'bailian',
    ARK_MODEL_REASONING: 'qwen9.9-ultra-turbo',
  });
  const problems = validateConfig(config);
  assert.equal(problems.filter((p) => p.includes('不像百炼')).length, 0);
});

// ─────────────────────────────────────────────────────────────────
// 三、buildRequestBody：协议差异的**唯一**分叉点

const SCHEMA = {
  name: 'report_answer_judgement',
  description: '报一个判定结果',
  parameters: { type: 'object', properties: {} },
};
const COMMON = {
  model: 'm',
  schema: SCHEMA,
  system: 'sys',
  content: 'hi',
  temperature: 0.2,
};

test('请求体·方舟：关思维链发 thinking 对象，tool_choice 仍是对象（硬约束不丢）', () => {
  const body = buildRequestBody({
    ...COMMON,
    thinkingOff: true,
    provider: MODEL_PROVIDERS.ark,
  });
  assert.deepEqual(body.thinking, { type: 'disabled' });
  assert.equal(body.enable_thinking, undefined, '方舟不该出现百炼的字段');
  assert.deepEqual(body.tool_choice, { type: 'function', function: { name: SCHEMA.name } });
});

test('请求体·百炼：关思维链发 enable_thinking=false，tool_choice 仍是对象', () => {
  const body = buildRequestBody({
    ...COMMON,
    thinkingOff: true,
    provider: MODEL_PROVIDERS.bailian,
  });
  assert.equal(body.enable_thinking, false);
  assert.equal(body.thinking, undefined, '百炼不该出现方舟的字段');
  // ⚠️ 这条是**关键区分**：百炼的限制只在思维链「开着」时生效。
  // 关了思维链仍然可以传对象 → 结构化输出的硬约束不该被无谓牺牲。
  assert.deepEqual(body.tool_choice, { type: 'function', function: { name: SCHEMA.name } });
});

test('请求体·百炼 + 思维链开着：tool_choice 必须退成 auto（否则 400）', () => {
  const body = buildRequestBody({
    ...COMMON,
    thinkingOff: false,
    provider: MODEL_PROVIDERS.bailian,
  });
  assert.equal(body.tool_choice, 'auto');
  // 没关思维链 = 不该发 enable_thinking（默认就是开）。
  assert.equal(body.enable_thinking, undefined);
});

test('请求体·方舟 + 思维链开着：tool_choice 照样是对象（方舟没这条限制）', () => {
  const body = buildRequestBody({
    ...COMMON,
    thinkingOff: false,
    provider: MODEL_PROVIDERS.ark,
  });
  assert.deepEqual(body.tool_choice, { type: 'function', function: { name: SCHEMA.name } });
  assert.equal(body.thinking, undefined);
});

test('请求体：provider 缺失时回落方舟字段，且不静默丢掉思维链开关', () => {
  // config 不总是 loadConfig() 造的（测试、嵌入式用法会手搓）。
  // 静默不发这个字段的后果是「思维链没关掉」——不报错，只是讲解偶尔超时。
  const body = buildRequestBody({ ...COMMON, thinkingOff: true, provider: undefined });
  assert.deepEqual(body.thinking, { type: 'disabled' });
});

test('请求体：厂商之间的差异只有那两个字段，其余逐字节相同', () => {
  const base = { ...COMMON, thinkingOff: false };
  const ark = buildRequestBody({ ...base, provider: MODEL_PROVIDERS.ark });
  const bailian = buildRequestBody({ ...base, provider: MODEL_PROVIDERS.bailian });
  // 思维链没关时，两家发出去的东西应当**完全一样**——除了百炼的 tool_choice。
  assert.deepEqual(ark.tools, bailian.tools);
  assert.deepEqual(ark.messages, bailian.messages);
  assert.equal(ark.temperature, bailian.temperature);
  assert.equal(ark.model, bailian.model);
});

test('shouldSendToolChoiceObject：规则只有一条，但是两个条件的交点', () => {
  // 方舟：永远可以传对象
  assert.equal(shouldSendToolChoiceObject({ thinkingOff: false, provider: MODEL_PROVIDERS.ark }), true);
  assert.equal(shouldSendToolChoiceObject({ thinkingOff: true, provider: MODEL_PROVIDERS.ark }), true);
  // 百炼：只有思维链开着时才不能传
  assert.equal(shouldSendToolChoiceObject({ thinkingOff: false, provider: MODEL_PROVIDERS.bailian }), false);
  assert.equal(shouldSendToolChoiceObject({ thinkingOff: true, provider: MODEL_PROVIDERS.bailian }), true);
  // provider 缺失 → 按最宽松处理，与改动前一致
  assert.equal(shouldSendToolChoiceObject({ thinkingOff: false, provider: undefined }), true);
});

// ─────────────────────────────────────────────────────────────────
// 四、端到端：真驱动一次 complete()，断言**实际发出的 body**
//    （上面那些测的是纯函数；这一组证明它们真的被调用了）
//
//  这也正是 `AI_THINKING_DISABLED_KINDS` 那套的教训：
//  纯函数全绿不等于调用点接对了 —— 名单里拼错一个词，参数就发不出去，
//  而请求仍然成功，只有耗时不对。

function fakeFetch() {
  // 返回体要**按 schema 真的能过校验**，否则会先在 schema 校验那里炸，
  // 断言就够不到请求体了（第一版就是这样失败的）。
  const byName = {
    report_answer_judgement: { verdict: 'correct', score: 100, comment: '对了' },
    report_mistake_explanation: {
      knowledgePoint: '被动语态',
      position: '八年级下 Unit 8',
      whyWrong: '没有识别出动作的承受者',
      steps: ['第一步：找主语'],
      pitfalls: ['别把 by 短语当主语'],
      mnemonic: '谁被做，谁在前',
    },
  };
  const calls = [];
  const impl = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push({ url, body });
    const name = body.tool_choice?.function?.name ?? body.tools[0].function.name;
    return {
      ok: true,
      status: 200,
      text: async () =>
        JSON.stringify({
          choices: [
            {
              finish_reason: 'tool_calls',
              message: {
                tool_calls: [
                  {
                    function: {
                      name,
                      arguments: JSON.stringify(byName[name] ?? {}),
                    },
                  },
                ],
              },
              usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
            },
          ],
        }),
    };
  };
  return { impl, calls };
}

async function driveComplete(provider) {
  const config = loadConfig({
    AI_MODEL_PROVIDER: provider,
    ARK_API_KEY: 'test-key',
    ARK_MODEL_REASONING: provider === 'bailian' ? 'qwen3-max' : 'doubao-reasoning-test',
    // 判定（reviewJudge）**刻意不在**关闭名单里 —— 它是唯一开思维链的路由。
    AI_THINKING_DISABLED_KINDS: 'reviewExplain,reviewPractice,reviewReferenceBatch',
  });
  const { impl, calls } = fakeFetch();
  const client = new ArkModelClient({ config, fetchImpl: impl, sleep: async () => {} });

  /** 打一次完整的 complete()，回传**实际发出去的 body**。 */
  async function call(kind) {
    const schema = Schemas[kind];
    assert.ok(schema, `测试自身的问题：没有名为 ${kind} 的 schema`);
    await client.complete({
      capability: 'reasoning',
      kind,
      schema,
      system: 'sys',
      content: 'hi',
    });
    return calls[calls.length - 1];
  }

  return { config, call };
}

test('端到端·百炼：reviewJudge（唯一开思维链的路由）发出的 tool_choice 是 auto', async () => {
  const { call } = await driveComplete('bailian');
  const { url, body } = await call('reviewJudge');
  assert.match(url, /dashscope\.aliyuncs\.com/, '地址该是百炼的');
  assert.equal(body.tool_choice, 'auto', '百炼 + 开思维链 → 不能传对象');
  assert.equal(body.enable_thinking, undefined, '默认就是开，不该发这个字段');
  assert.equal(body.thinking, undefined, '不该混进方舟的字段');
});

test('端到端·百炼：reviewExplain（在关闭名单里）发 enable_thinking=false 且保留对象 tool_choice', async () => {
  const { call } = await driveComplete('bailian');
  const { body } = await call('reviewExplain');
  assert.equal(body.enable_thinking, false);
  assert.deepEqual(body.tool_choice, {
    type: 'function',
    function: { name: body.tool_choice.function.name },
  });
});

test('端到端·方舟：同一份关闭名单下行为与改动前一致', async () => {
  const { call } = await driveComplete('ark');

  const judge = await call('reviewJudge');
  assert.match(judge.url, /volces\.com/);
  assert.deepEqual(judge.body.tool_choice, {
    type: 'function',
    function: { name: judge.body.tool_choice.function.name },
  });
  assert.equal(judge.body.thinking, undefined, '方舟下 reviewJudge 不在名单里，不该发');

  const explain = await call('reviewExplain');
  assert.deepEqual(explain.body.thinking, { type: 'disabled' });
  assert.equal(explain.body.enable_thinking, undefined);
});

// ─────────────────────────────────────────────────────────────────
// 四·补：**报错文案里的厂商名**也必须跟着开关走

/**
 * 打一次必然失败的真实 complete()，把**运维在日志里看到的那句话**取回来。
 *
 * 为什么值得单独测：这句话写死厂商名时，排查方向会被指到另一家的控制台去，
 * 而那边根本没有这条记录。它与「用甲家的地址、乙家的 Key」是同一类失败 ——
 * 单看每一处都对，合起来把人带偏。
 */
async function messageOnHttpError(provider, { status, errorText }) {
  const config = loadConfig({
    AI_MODEL_PROVIDER: provider,
    ARK_API_KEY: 'test-key',
    ARK_MODEL_REASONING: provider === 'bailian' ? 'qwen3-max' : 'doubao-reasoning-test',
  });
  const client = new ArkModelClient({
    config,
    fetchImpl: async () => ({ ok: false, status, text: async () => errorText }),
    sleep: async () => {},
  });
  try {
    await client.complete({
      capability: 'reasoning',
      kind: 'reviewJudge',
      schema: Schemas.reviewJudge,
      system: 'sys',
      content: 'hi',
    });
  } catch (error) {
    return error.message;
  }
  throw new Error('测试自身的问题：本该抛错却没有');
}

test('报错文案·百炼：400 点名百炼，且一个字都不提方舟', async () => {
  const message = await messageOnHttpError('bailian', {
    status: 400,
    errorText: JSON.stringify({ error: { message: 'model not found' } }),
  });
  assert.match(message, /百炼/, '文案该点名当前厂商');
  assert.match(message, /model not found/, '对方原文必须带出来，否则运维没有线索');
  assert.doesNotMatch(message, /方舟/, '切到百炼还说方舟 → 排查方向被指到另一家控制台');
});

test('报错文案·方舟（反面）：同一段代码在方舟下仍点名方舟', async () => {
  // 反面用例不是凑数：不做的话，把文案统一改成笼统的「模型服务」
  // 也能让上一条变绿 —— 那上一条就没有区分力了。
  const message = await messageOnHttpError('ark', {
    status: 400,
    errorText: JSON.stringify({ error: { message: 'model not found' } }),
  });
  assert.match(message, /方舟/);
  assert.doesNotMatch(message, /百炼/);
});

test('报错文案：网络层错误（连不上）同样不能用错厂商名', async () => {
  // 这条走的是另一段代码（`#call` 的 catch），不是 mapHttpError ——
  // 只改一处的话，断网时的日志仍然是「无法连接方舟」。
  const config = loadConfig({
    AI_MODEL_PROVIDER: 'bailian',
    ARK_API_KEY: 'k',
    ARK_MODEL_REASONING: 'qwen3-max',
  });
  const client = new ArkModelClient({
    config,
    fetchImpl: async () => { throw new Error('ECONNREFUSED'); },
    sleep: async () => {},
  });
  await assert.rejects(
    () => client.complete({
      capability: 'reasoning',
      kind: 'reviewJudge',
      schema: Schemas.reviewJudge,
      system: 'sys',
      content: 'hi',
    }),
    (error) => {
      assert.match(error.message, /ECONNREFUSED/);
      assert.match(error.message, /百炼/);
      assert.doesNotMatch(error.message, /方舟/);
      return true;
    },
  );
});

// ─────────────────────────────────────────────────────────────────
// 四·补二：厂商会把**嵌套结构序列化成字符串** —— 只有声明过的厂商才修

/** 一个回固定 payload 的假后端。 */
function payloadFetch(payload) {
  return async () => ({ ok: true, status: 200, text: async () => JSON.stringify(payload) });
}

/**
 * **实测原文**（2026-09-24，百炼 `qwen3-vl-plus` / `qwen3-vl-flash` 各两次，4/4 一致）：
 * `tasks` 是一个**字符串**，数组被多包了一层引号。
 */
const STRINGIFIED_TASKS = {
  choices: [
    {
      finish_reason: 'tool_calls',
      message: {
        tool_calls: [
          {
            function: {
              name: 'report_homework_ocr',
              arguments: JSON.stringify({
                text: '今日作业',
                subject: '语文',
                confidence: 0.95,
                tasks: '\n[{"subject": "语文", "text": "抄写生字"}]\n',
              }),
            },
          },
        ],
      },
    },
  ],
  usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
};

async function completeOcr(provider, payload) {
  const config = loadConfig({
    AI_MODEL_PROVIDER: provider,
    ARK_API_KEY: 'test-key',
    ARK_MODEL_VISION: provider === 'bailian' ? 'qwen3-vl-plus' : 'doubao-vision-test',
  });
  const client = new ArkModelClient({
    config,
    fetchImpl: payloadFetch(payload),
    sleep: async () => {},
  });
  return client.complete({
    capability: 'vision',
    kind: 'homeworkOcr',
    schema: Schemas.homeworkOcr,
    system: 'sys',
    content: 'img',
  });
}

test('百炼：嵌套数组被序列化成字符串 → 网关侧修回来（实测的形态）', async () => {
  const result = await completeOcr('bailian', STRINGIFIED_TASKS);

  assert.ok(Array.isArray(result.value.tasks), 'tasks 该被解成真数组');
  assert.equal(result.value.tasks[0].subject, '语文');
});

test('方舟（反面）：同一份响应仍然判违规 —— 放宽只对声明过的厂商生效', async () => {
  // 这条是 `stringifiesStructuredArgs` 那个旗标的**唯一判据**。
  // 不做它的话，把修复无条件打开也能让上一条变绿 —— 而那等于
  // 偷偷改了方舟的行为，而「既有部署零行为变化」是代码里的明文承诺。
  await assert.rejects(
    () => completeOcr('ark', STRINGIFIED_TASKS),
    (error) => {
      assert.equal(error.code, 'schema_violation');
      assert.match(String(error.message), /应为数组/);
      return true;
    },
  );
});

// ─────────────────────────────────────────────────────────────────
// 五、实例缓存与 health：**改了开关到底有没有生效**

test('实例缓存：换厂商必须让缓存失效，否则复用中的实例还在打旧厂商', async () => {
  // 这是「改了配置没生效」那一类静默失败：缓存签名漏了厂商的话，
  // 你改了 AI_MODEL_PROVIDER，但**复用中的实例仍在打旧厂商**——
  // 地址、Key、思维链字段全是旧的，而配置看着已经改了。
  const { getGateway, resetGateway } = await import('../src/handler.js');
  resetGateway();

  const envArk = {
    ARK_API_KEY: 'k',
    ARK_MODEL_REASONING: 'doubao-test',
  };
  const envBailian = {
    AI_MODEL_PROVIDER: 'bailian',
    ARK_API_KEY: 'k',
    ARK_MODEL_REASONING: 'qwen3-max',
  };

  const first = getGateway(envArk);
  const again = getGateway(envArk);
  assert.equal(first, again, '同一份配置应当复用实例（否则连接池/缓存全白做）');

  const switched = getGateway(envBailian);
  assert.notEqual(switched, first, '换了厂商必须重建实例');
  assert.match(switched.config.ark.baseUrl, /dashscope/, '新实例该用百炼的地址');

  resetGateway();
});

/** 造一个能直接打的网关（配置**必须**经 loadConfig，不能手搓 —— 手搓会绕开开关）。 */
function buildGateway(envOverrides = {}) {
  const config = loadConfig({
    AI_MODEL_CLIENT: 'mock',
    AI_UPLOAD_URL_BASE: 'https://gw.test',
    AI_UPLOAD_SIGNING_SECRET: 'test-secret',
    ARK_API_KEY: 'k',
    ...envOverrides,
  });
  return createGateway({ config });
}

test('health：回显当前厂商，且百炼不报一个假的区域', async () => {
  // `handle()` 返回 `{ status, headers, body }`，且 **body 已经是序列化好的 JSON 字符串**
  // （云函数的返回约定）。要断言内容得自己 parse —— 这一层契约不在本测试的范围内，
  // 但它决定了这里怎么写。
  const healthOf = async (envOverrides) => {
    const gateway = buildGateway(envOverrides);
    const res = await gateway.handle({ method: 'GET', path: '/ai/health', headers: {} });
    assert.equal(res.status, 200);
    return JSON.parse(res.body).data;
  };

  const bailian = await healthOf({
    AI_MODEL_PROVIDER: 'bailian',
    ARK_MODEL_REASONING: 'qwen3-max',
  });
  assert.equal(bailian.modelProvider, 'bailian');
  assert.equal(bailian.modelProviderLabel, '阿里云百炼');
  // 百炼端点固定，回一个 cn-beijing 会让人去控制台找一个不存在的设置项。
  assert.equal(bailian.region, '');

  const ark = await healthOf({ ARK_REGION: 'cn-shanghai', ARK_MODEL_REASONING: 'doubao-test' });
  assert.equal(ark.modelProvider, 'ark');
  assert.equal(ark.region, 'cn-shanghai', '方舟的区域要如实回显');
});

test('createGateway：厂商名拼错时在**构造期**就抛，不是等第一个请求', () => {
  // 构造期抛 = 部署时就能看到；等到第一个请求才炸 = 上线后才发现。
  assert.throws(
    () => buildGateway({ AI_MODEL_PROVIDER: 'blian' }),
    /AI_MODEL_PROVIDER=blian/,
  );
});

// ─────────────────────────────────────────────────────────────────
// 五、两套配置并存：让 `AI_MODEL_PROVIDER` 成为**真正的**一个开关
//
// ## 这一节的由来（别把它读成"多加了一组变量名"）
//
// 开关本来就存在 —— 但两家**共用同一组槽位**（`ARK_API_KEY` /
// `ARK_MODEL_*` / `AI_PRICE_*`）。于是"换一家厂商"实际要改 5–10 个值，
// **覆盖掉上一家的**，切回来还得再改一遍。开关是有的，但它不是
// "只改一个配置"：它要求你手里留着上一家的值。
//
// 分开存之后，两套凭据同时在 `.env.prod` 里躺着，切换只动一个变量。
//
// ⚠️ 这一节的断言全部打在"**切过去之后拿到的是不是那一家的东西**"上 ——
// 而不是"函数返回了某个常量"。失败形态都是安静的：
// 用甲家的 Key 打乙家的地址（401，看着像 Key 没开通）、
// 拿上一家的单价喂成本看板（数字格式完整、数值错误）。

/**
 * 两套配置并存的那份 `.env.prod`。
 *
 * 方舟与百炼的 Key、模型名、单价**同时存在**，且**互不覆盖**。
 */
const BOTH_SETS = {
  // ── 方舟那一套（前缀 ARK_，与旧名同字）──
  ARK_API_KEY: 'ark-key',
  ARK_MODEL_VISION: 'doubao-seed-2-1-vision-260628',
  ARK_MODEL_REASONING: 'doubao-seed-2-1-pro-260628',
  // 单价**六项全填**：只填一半会被自检拦下来（缺的算成 0，
  // 看板给出一个偏小但看起来完整的数字）。夹具必须自己先合规。
  ARK_PRICE_VISION_IN: '0.001',
  ARK_PRICE_VISION_OUT: '0.004',
  ARK_PRICE_REASONING_IN: '0.002',
  ARK_PRICE_REASONING_OUT: '0.008',
  ARK_PRICE_LIGHT_IN: '0.0005',
  ARK_PRICE_LIGHT_OUT: '0.001',
  // ── 百炼那一套（前缀 BAILIAN_）──
  BAILIAN_API_KEY: 'bailian-key',
  BAILIAN_MODEL_VISION: 'qwen3-vl-plus',
  BAILIAN_MODEL_REASONING: 'qwen3-max',
  BAILIAN_PRICE_VISION_IN: '0.008',
  BAILIAN_PRICE_VISION_OUT: '0.032',
  BAILIAN_PRICE_REASONING_IN: '0.006',
  BAILIAN_PRICE_REASONING_OUT: '0.024',
  BAILIAN_PRICE_LIGHT_IN: '0.002',
  BAILIAN_PRICE_LIGHT_OUT: '0.006',
};

test('两套配置并存：只改 AI_MODEL_PROVIDER，Key/地址/模型/单价整套跟着换', () => {
  const asArk = loadConfig({ ...BOTH_SETS, AI_MODEL_PROVIDER: 'ark' });
  const asBailian = loadConfig({ ...BOTH_SETS, AI_MODEL_PROVIDER: 'bailian' });

  // ① 先证明"两边的输入只差那一个变量"—— 这是"一个开关"这句话的字面意思。
  //    ⚠️ 这里**不写自证的循环**（那种断言恒真，等于没测）。改成把两份 env
  //    摊平比较：除了 AI_MODEL_PROVIDER，其余每一项都必须一模一样。
  const envOf = (providerName) => ({ ...BOTH_SETS, AI_MODEL_PROVIDER: providerName });
  const envArk = envOf('ark');
  const envBailian = envOf('bailian');
  const differing = Object.keys({ ...envArk, ...envBailian })
    .filter((key) => envArk[key] !== envBailian[key]);
  assert.deepEqual(differing, ['AI_MODEL_PROVIDER'], '除开关外不该有第二个变量参与切换');

  // ② Key 不能串：这是最坏的失败形态（401 会被读成"Key 没开通"）。
  assert.equal(asArk.ark.apiKey, 'ark-key');
  assert.equal(asBailian.ark.apiKey, 'bailian-key');

  // ③ 地址不能串。
  assert.match(asArk.ark.baseUrl, /volces\.com/);
  assert.match(asBailian.ark.baseUrl, /dashscope/);

  // ④ 模型不能串。
  assert.equal(asArk.ark.models.vision, 'doubao-seed-2-1-vision-260628');
  assert.equal(asBailian.ark.models.vision, 'qwen3-vl-plus');
  assert.equal(asArk.ark.models.reasoning, 'doubao-seed-2-1-pro-260628');
  assert.equal(asBailian.ark.models.reasoning, 'qwen3-max');

  // ⑤ 单价不能串 —— 它不参与功能，只喂成本看板，所以错了**完全没有症状**。
  assert.equal(asArk.pricing.inputPerKToken.vision, 0.001);
  assert.equal(asBailian.pricing.inputPerKToken.vision, 0.008);

  // ⑥ 两份配置必须都是合法的（否则"能切"只是纸面上的）。
  assert.deepEqual(validateConfig(asArk), []);
  assert.deepEqual(validateConfig(asBailian), []);
});

test('两套并存时前缀优先：BAILIAN_* 盖过旧的 ARK_* 通用槽', () => {
  const config = loadConfig({
    AI_MODEL_PROVIDER: 'bailian',
    ARK_API_KEY: '旧通用槽里的值',
    BAILIAN_API_KEY: '百炼自己那组的值',
    ARK_MODEL_VISION: 'qwen3-vl-flash',
    BAILIAN_MODEL_VISION: 'qwen3-vl-plus',
  });
  assert.equal(config.ark.apiKey, '百炼自己那组的值');
  assert.equal(config.ark.models.vision, 'qwen3-vl-plus');
});

test('思维链名单也跟着厂商走：两家的名单**本来就该不一样**', () => {
  // 这是本次改造里最容易漏掉的一处 —— 它看起来只是个"调优参数"，
  // 实际是**协议差异的补偿**：百炼在思维链开启时不接受对象 `tool_choice`，
  // 所以它的名单必须更长（多关掉几条路由才能拿回硬约束）；方舟没这条限制。
  // 不分厂商的后果两种都不报错：百炼用短名单 → 硬约束悄悄降级；
  // 方舟用长名单 → 白关思维链，推理质量下降。
  const both = {
    ARK_API_KEY: 'k',
    ARK_MODEL_REASONING: 'doubao-test',
    ARK_THINKING_DISABLED_KINDS: 'homeworkOcr,homeworkCheck,answerOcr',
    BAILIAN_API_KEY: 'b',
    BAILIAN_MODEL_REASONING: 'qwen3-max',
    BAILIAN_THINKING_DISABLED_KINDS: 'homeworkOcr,homeworkCheck,reviewExplain,reviewPractice',
  };
  const asArk = loadConfig({ ...both, AI_MODEL_PROVIDER: 'ark' });
  const asBailian = loadConfig({ ...both, AI_MODEL_PROVIDER: 'bailian' });

  assert.deepEqual(asArk.ark.thinkingDisabledKinds, ['homeworkOcr', 'homeworkCheck', 'answerOcr']);
  assert.deepEqual(
    asBailian.ark.thinkingDisabledKinds,
    ['homeworkOcr', 'homeworkCheck', 'reviewExplain', 'reviewPractice'],
  );
  // 两份都填全了 → 都该是零回退（否则说明前缀又漏了一处）。
  assert.deepEqual(asArk.providerEnvFallbacks, []);
  assert.deepEqual(asBailian.providerEnvFallbacks, []);
});

test('旧的单套写法照常能用：只有 ARK_* 一组时，选百炼仍然生效', () => {
  // 这是本次改动前唯一的写法，也是**当前线上**的写法。
  // 不能因为"分了两组"就把只用一组的部署拦下来。
  const config = loadConfig({
    AI_MODEL_PROVIDER: 'bailian',
    ARK_API_KEY: 'k',
    ARK_MODEL_VISION: 'qwen3-vl-plus',
    AI_PRICE_VISION_IN: '0.008',
  });
  assert.equal(config.ark.apiKey, 'k');
  assert.equal(config.ark.models.vision, 'qwen3-vl-plus');
  assert.equal(config.pricing.inputPerKToken.vision, 0.008);
});

test('回退如实报出来：providerEnvFallbacks 列的是"没填前缀、用了旧名"的字段', () => {
  // "打算两套并存，却漏填了其中一项" → 那一项**悄悄用了另一家的值**。
  // Key 与单价没有形态可以判，所以不猜（猜错 = 路障），改成报出来。
  const clean = loadConfig({
    AI_MODEL_PROVIDER: 'bailian',
    BAILIAN_API_KEY: 'b',
    BAILIAN_MODEL_VISION: 'qwen3-vl-plus',
    BAILIAN_PRICE_VISION_IN: '0.008',
  });
  assert.deepEqual(clean.providerEnvFallbacks, [], '填全了就不该有任何回退');
  assert.equal(clean.providerEnvPrefix, 'BAILIAN');

  const mixed = loadConfig({
    AI_MODEL_PROVIDER: 'bailian',
    BAILIAN_API_KEY: 'b',
    ARK_MODEL_VISION: 'qwen3-vl-plus', // 漏了 BAILIAN_ 前缀，悄悄用了通用槽
    AI_PRICE_VISION_IN: '0.008', // 单价同理
  });
  assert.deepEqual(mixed.providerEnvFallbacks, ['ARK_MODEL_VISION', 'AI_PRICE_VISION_IN']);

  // 方舟那一侧**永远**是空的（前缀与旧名同字，不可能一个空一个非空）——
  // 所以这条不会给既有部署增加任何噪音。
  const ark = loadConfig({ AI_MODEL_PROVIDER: 'ark', ARK_API_KEY: 'k', ARK_MODEL_VISION: 'doubao-test' });
  assert.deepEqual(ark.providerEnvFallbacks, []);
  assert.equal(ark.providerEnvPrefix, 'ARK');
});

test('切换厂商后单价不会"悄悄"沿用上一家的：要么读本家的，要么被报成回退', () => {
  // 单价的失败形态是这一组配置里最安静的：它**不参与任何功能**，
  // 只喂成本看板 —— 错了就是"接口全通、看板给出一个格式完整、数值错误的数字"。
  // 所以这里把两种情形都钉住，尤其是第二种（回退允许，**但必须可见**）。

  // ① 本家那一组填了 → 读本家的，且没有任何回退。
  const ownSet = loadConfig({
    AI_MODEL_PROVIDER: 'bailian',
    BAILIAN_API_KEY: 'b',
    BAILIAN_PRICE_VISION_IN: '0.008',
  });
  assert.equal(ownSet.pricing.inputPerKToken.vision, 0.008);
  assert.deepEqual(ownSet.providerEnvFallbacks, []);

  // ② 本家那一组没填 → 回退到旧通用槽（这是刻意的兼容，旧的单套写法靠它活着），
  //    **但必须被显式报出来**。不报的话，"我打算两套并存、结果漏填了一项"
  //    就只剩下一个安静的错数字。
  const fellBack = loadConfig({
    AI_MODEL_PROVIDER: 'bailian',
    BAILIAN_API_KEY: 'b',
    AI_PRICE_VISION_IN: '0.001', // 旧通用槽里还留着方舟的价
  });
  assert.equal(fellBack.pricing.inputPerKToken.vision, 0.001);
  assert.deepEqual(
    fellBack.providerEnvFallbacks,
    ['AI_PRICE_VISION_IN'],
    '回退必须可见 —— 否则就是"用着甲家的单价、算着乙家的账"',
  );
});

test('反方向守卫：选了方舟却填百炼的模型名 → 启动失败', () => {
  // 两套配置并列写在同一份 .env.prod 里之后，
  // "复制粘贴时改错块"从"手抖"变成了最常见的失手方式。
  const problems = validateConfig(loadConfig({
    AI_MODEL_PROVIDER: 'ark',
    ARK_API_KEY: 'k',
    ARK_MODEL_REASONING: 'qwen3-max',
  }));
  const hit = problems.find((p) => p.includes('qwen3-max'));
  assert.ok(hit, `应当报出模型名与厂商不匹配，实际：${JSON.stringify(problems)}`);
  assert.match(hit, /reasoning/);
  // 报错要指出怎么退出这条守卫，否则自建网关的人会被堵死。
  assert.match(hit, /ARK_BASE_URL/);
});

test('反方向守卫的反面：**同一个模型名**，默认端点拦、自建端点放行', () => {
  // ⚠️ 写成**对照实验**而不是单边断言：单边的"自建端点不报错"在有守卫
  //    和没守卫两种情况下**都是绿的**，那样的断言等于没测
  //    （本项目踩过：判据一直是绿的，其实什么都没测）。
  //
  // 差异只能来自一处 —— baseUrl 是不是厂商默认值：
  // 「两家的模型名互不认」这个前提，在你指向自建网关/本机 Ollama 时就不成立了。
  const shared = { AI_MODEL_PROVIDER: 'ark', ARK_API_KEY: 'k', ARK_MODEL_REASONING: 'qwen3-max' };

  const onDefault = validateConfig(loadConfig(shared));
  assert.ok(
    onDefault.some((p) => p.includes('qwen3-max')),
    `厂商默认端点下应当拦下（否则守卫形同虚设），实际：${JSON.stringify(onDefault)}`,
  );

  const selfHosted = validateConfig(loadConfig({ ...shared, ARK_BASE_URL: 'http://127.0.0.1:11434/v1' }));
  assert.equal(
    selfHosted.filter((p) => p.includes('qwen3-max')).length,
    0,
    `自建端点下不该拦（守卫不能变成路障，README「接本机模型」那条退路靠它），实际：${JSON.stringify(selfHosted)}`,
  );
});

test('health：回显**实际参与读值的那一组环境变量前缀**', async () => {
  // `modelProvider` 可能"改了却没生效"（实例缓存 / 变量没传上去），
  // 而 `/ai/health` 是唯一能一眼看出这件事的地方 ——
  // 厂商名与配置来源**一起看**才能回答"我改了开关，到底生效了没有"。
  const healthOf = async (envOverrides) => {
    const gateway = buildGateway(envOverrides);
    const res = await gateway.handle({ method: 'GET', path: '/ai/health', headers: {} });
    assert.equal(res.status, 200);
    return JSON.parse(res.body).data;
  };

  const asArk = await healthOf({ ARK_MODEL_REASONING: 'doubao-test' });
  assert.equal(asArk.modelProvider, 'ark');
  assert.equal(asArk.modelProviderEnv, 'ARK');
  assert.deepEqual(asArk.modelProviderEnvFallbacks, []);

  const asBailian = await healthOf({
    AI_MODEL_PROVIDER: 'bailian',
    BAILIAN_API_KEY: 'b',
    BAILIAN_MODEL_REASONING: 'qwen3-max',
  });
  assert.equal(asBailian.modelProvider, 'bailian');
  assert.equal(asBailian.modelProviderEnv, 'BAILIAN');
  assert.deepEqual(asBailian.modelProviderEnvFallbacks, []);
});
