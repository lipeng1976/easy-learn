import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { ArkModelClient, thinkingDisabled } from '../src/ark.js';
import { loadConfig, validateConfig } from '../src/config.js';
import { Schemas } from '../src/schema.js';

/**
 * 思维链开关（`AI_THINKING_DISABLED_KINDS`）。
 *
 * ## 为什么值得单独一个测试文件
 *
 * 这个开关的**失败方式是安静的**：名单里拼错一个路由名、或者开关根本没生效，
 * 结果既不是报错也不是异常响应 —— 只是「参数没发出去、老师讲得慢」，
 * 而慢到什么程度要等到真模型上才发现。本文件盯的是三件容易被改坏的事：
 *
 * 1. **默认不发**。`thinking` 是方舟特有字段；网关可以指向本机 Ollama / vLLM
 *    （README「接本机模型」），那些服务收到不认识的字段可能直接 400。
 *    所以「没配就不发」是一条**兼容性**判据，不是省略。
 * 2. **只对名单里的路由发**。同一个 `reasoning` 档下判定不该关、讲解该关 ——
 *    开关粒度错了会把两件相反的事捆在一起。
 * 3. **拼错的名字要在启动自检里报出来**，而不是静默不生效。
 */

const BASE_CONFIG = {
  ark: {
    region: 'cn-beijing',
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    apiKey: 'test-key',
    models: { vision: 'doubao-vision-test', reasoning: 'doubao-reasoning-test', light: 'doubao-light-test' },
    timeoutMs: 1000,
    maxAttempts: 1,
  },
};

function configWith(disabledKinds) {
  const config = structuredClone(BASE_CONFIG);
  if (disabledKinds !== undefined) config.ark.thinkingDisabledKinds = disabledKinds;
  return config;
}

/** 只关心「请求体里有没有 thinking」，所以响应固定给一个合法的判定结果。 */
function fakeFetch() {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body) });
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
                      name: 'report_answer_judgement',
                      arguments: JSON.stringify({ verdict: 'correct', score: 100, comment: '对了' }),
                    },
                  },
                ],
              },
              usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
            },
          ],
        }),
    };
  };
  impl.calls = calls;
  return impl;
}

async function callWith(disabledKinds, kind, capability = 'reasoning') {
  const fetchImpl = fakeFetch();
  const instance = new ArkModelClient({
    config: configWith(disabledKinds),
    fetchImpl,
    sleep: async () => {},
  });
  await instance.complete({
    capability,
    kind,
    schema: Schemas.reviewJudge,
    system: '判定学生答案',
    content: '学生答案：11/12',
  });
  return fetchImpl.calls[0].body;
}

test('thinkingDisabled：空名单一律不关（默认行为不能被悄悄改掉）', () => {
  for (const empty of [undefined, null, [], 'reviewExplain']) {
    assert.equal(thinkingDisabled(empty, 'reviewExplain'), false, `名单 ${JSON.stringify(empty)} 不该关`);
  }
});

test('thinkingDisabled：只关名单里的路由，其余不动', () => {
  assert.equal(thinkingDisabled(['reviewExplain'], 'reviewExplain'), true);
  assert.equal(thinkingDisabled(['reviewExplain'], 'reviewPractice'), false);
  // 名单为空的路由名（没传 kind）不能被误判成命中
  assert.equal(thinkingDisabled(['reviewExplain'], ''), false);
  assert.equal(thinkingDisabled(['reviewExplain'], undefined), false);
});

test('thinkingDisabled：* 表示全部', () => {
  assert.equal(thinkingDisabled(['*'], 'reviewExplain'), true);
  assert.equal(thinkingDisabled(['*'], ''), true);
});

test('没配开关：请求体里没有 thinking 这个键（兼容本机 Ollama / vLLM）', async () => {
  const body = await callWith(undefined, 'reviewExplain');
  assert.equal('thinking' in body, false, '默认不该发方舟特有的字段');
});

test('配了开关：只对名单里的路由发 thinking:{type:"disabled"}', async () => {
  const explained = await callWith(['reviewExplain'], 'reviewExplain');
  assert.deepEqual(explained.thinking, { type: 'disabled' });

  const judged = await callWith(['reviewExplain'], 'reviewJudge');
  assert.equal('thinking' in judged, false, '判定不在名单里，不该被关掉');
});

test('生产名单里不许出现 reviewJudge，也不许出现通配符', () => {
  // 2026-09-26 定性：判定**不关**思维链。上面那条用例盯的是「传进来的名单」，
  // 而生产用的名单是**部署期环境变量**（代码默认值是空数组，见 config.js），
  // 所以真正的约定落在 `.env.prod.example` 里 —— 这里读的就是它。
  //
  // 为什么值得专门加一条闸：上一轮我**几乎就把它加进去了**。
  // 当时拿云上首批 47~50s 的样本（其实是冷启动）得出「网关比直连慢 10 倍」，
  // 而当时的补救方案正是「把 reviewJudge 也关掉」；补样本后那个结论被推翻。
  // 关掉只省约 3.5s（实测中位 5349ms → 1762ms），换来的却是判定准确率下降，
  // 而判定结果直接决定这道题能不能从错题库毕业 —— **漏判是静默的**。
  //
  // ⚠️ 2026-09-30 晚改：名单**按厂商分了两组**（`ARK_*` / `BAILIAN_*`），
  // 于是这条闸也不能再只读那一个旧通用槽 —— 它读到的会是**空值**，
  // 然后报「讲解不在名单里」，而那是假红：讲解在各自那一组里好好的。
  // 现在按 `loadConfig` 的**同一条优先级**解析出「实际生效的名单」，
  // 并且**两家都盯** —— 这比原来更强：原来只要有一个名单对就行。
  const examplePath = fileURLToPath(
    new URL('../../../.env.prod.example', import.meta.url),
  );
  assert.ok(
    existsSync(examplePath),
    `.env.prod.example 不在，无法核对生产名单：${examplePath}`,
  );

  const env = {};
  for (const raw of readFileSync(examplePath, 'utf8').split(/\r?\n/)) {
    const m = raw.match(/^([A-Za-z_0-9]+)=(.*)$/);
    if (m) env[m[1]] = m[2].trim();
  }

  // 与 config.js 的 providerEnvResolved 同一条规则：本家前缀 → 旧通用槽。
  const effectiveKinds = (prefix) => {
    const own = env[`${prefix}_THINKING_DISABLED_KINDS`];
    const value = own !== undefined && own !== '' ? own : (env.AI_THINKING_DISABLED_KINDS ?? '');
    return { raw: value, kinds: value.split(',').map((s) => s.trim()).filter((s) => s !== '') };
  };

  for (const [provider, prefix] of [['ark', 'ARK'], ['bailian', 'BAILIAN']]) {
    const { raw, kinds } = effectiveKinds(prefix);
    const where = `${provider}（${prefix}_THINKING_DISABLED_KINDS）`;
    assert.ok(
      kinds.length > 0,
      `${where} 的名单不该是空的 —— 讲解那几条正靠它把耗时压进客户端窗口`,
    );
    assert.ok(!kinds.includes('reviewJudge'), `${where} 把判定关掉思维链了：${raw}`);
    assert.ok(!kinds.includes('*'), `${where} 的正则会把判定也一起关掉：${raw}`);
  }

  // 百炼**必须**含讲解 —— 这条不是调优，是**协议必需**：
  // 百炼在思维链开启时不接受对象 `tool_choice`（实测 400），
  // 讲解不进名单 ⇒ 思考开着 ⇒ 退成 'auto' ⇒ **结构化输出的硬约束丢掉**。
  const bailian = effectiveKinds('BAILIAN');
  assert.ok(
    bailian.kinds.includes('reviewExplain'),
    `百炼这份少了讲解就会丢掉硬约束（tool_choice 退成 auto）：${bailian.raw}`,
  );

  // ⚠️ 方舟那一份**刻意不**断言「必须含讲解」，理由是它和百炼那份的**依据不同**：
  //   百炼是协议必需（上面那条），方舟只剩「速度」一个理由。
  //   而「讲解超窗口」那条结论（关掉前 23.5~41.6s，2/4 越界）是 2026-09-20 在
  //   **慢推理档**上测的 —— 2026-09-30 换成 `doubao-seed-2-1-lite` 之后**没复测**。
  //   ⇒ 这是一个**未定案的问题**（见 doc/open-items.md B31），不该由一条测试
  //   替人拍板「必须关」或「必须不关」。
  //
  //   这里换成一条**能站住的**不变量：两份名单**必须不同**。
  //   只要百炼那条 `tool_choice` 限制还在，两份相同就说明**有一份是错的** ——
  //   要么百炼少写了（丢硬约束），要么方舟多写了（白丢推理质量）。
  const ark = effectiveKinds('ARK');
  assert.notDeepEqual(
    ark.kinds,
    bailian.kinds,
    '两份关思维链名单相同了 —— 其中必有一份是错的（差异本身就是协议补偿）',
  );
});

test('生产名单：真实 .env.prod 里**当前生效的那一家**也要合规（文件不在就跳过）', () => {
  // 模板管的是"下一个人照着填"，而 `.env.prod` 管的是"这次部署真的发什么"。
  // 两者会漂（本次就漂了一次：模板改了、`.env.prod` 还没改）。
  // ⚠️ `.env.prod` 被 .gitignore 拦住，别人机器上可能没有 —— 所以缺席时跳过，
  // 而不是判失败（否则这条闸会在没配密钥的机器上变成路障）。
  const prodPath = fileURLToPath(new URL('../../../.env.prod', import.meta.url));
  if (!existsSync(prodPath)) {
    console.log('（跳过：本机没有 .env.prod）');
    return;
  }

  const env = {};
  for (const raw of readFileSync(prodPath, 'utf8').split(/\r?\n/)) {
    const m = raw.match(/^([A-Za-z_0-9]+)=(.*)$/);
    if (m) env[m[1]] = m[2].trim();
  }

  const provider = env.AI_MODEL_PROVIDER || 'ark';
  const prefix = provider === 'bailian' ? 'BAILIAN' : 'ARK';
  const own = env[`${prefix}_THINKING_DISABLED_KINDS`];
  const value = own !== undefined && own !== '' ? own : (env.AI_THINKING_DISABLED_KINDS ?? '');
  const kinds = value.split(',').map((s) => s.trim()).filter((s) => s !== '');

  assert.ok(kinds.length > 0, `.env.prod 里当前生效的名单是空的（provider=${provider}）`);
  assert.ok(!kinds.includes('reviewJudge'), `.env.prod 把判定关掉思维链了：${value}`);
  assert.ok(!kinds.includes('*'), `.env.prod 的通配符会把判定也一起关掉：${value}`);
  if (provider === 'bailian') {
    assert.ok(kinds.includes('reviewExplain'), `.env.prod 当前生效的名单少了讲解：${value}`);
  }
});

test('关思维链不影响「用哪个模型」——选模型只认 capability', async () => {
  const body = await callWith(['reviewExplain'], 'reviewExplain');
  assert.equal(body.model, 'doubao-reasoning-test');
  assert.equal(body.tool_choice.function.name, 'report_answer_judgement');
});

test('环境变量解析：逗号分隔、去空白、空串等于没配', () => {
  const parsed = loadConfig({ AI_THINKING_DISABLED_KINDS: ' reviewExplain , reviewPractice ' });
  assert.deepEqual(parsed.ark.thinkingDisabledKinds, ['reviewExplain', 'reviewPractice']);

  assert.deepEqual(loadConfig({}).ark.thinkingDisabledKinds, []);
  assert.deepEqual(loadConfig({ AI_THINKING_DISABLED_KINDS: '' }).ark.thinkingDisabledKinds, []);
  assert.deepEqual(loadConfig({ AI_THINKING_DISABLED_KINDS: '   ' }).ark.thinkingDisabledKinds, []);
});

test('启动自检：写了不存在的路由名要报出来（否则静默不生效）', () => {
  const config = loadConfig({ AI_THINKING_DISABLED_KINDS: 'reviewExplain,reviewExplian' });
  const problems = validateConfig(config);
  const hit = problems.find((text) => text.includes('AI_THINKING_DISABLED_KINDS'));
  assert.ok(hit, `自检没报出拼错的路由名，实际只报了：${JSON.stringify(problems)}`);
  assert.ok(hit.includes('reviewExplian'), '报错信息里要说清是哪个名字不对');
  assert.ok(hit.includes('reviewExplain'), '报错信息里要列出可选值');
});

test('启动自检：合法名单与 * 都不该报问题', () => {
  for (const raw of ['reviewExplain', 'reviewExplain,reviewPractice', '*']) {
    const config = loadConfig({ AI_THINKING_DISABLED_KINDS: raw });
    const problems = validateConfig(config);
    assert.equal(
      problems.some((text) => text.includes('AI_THINKING_DISABLED_KINDS')),
      false,
      `${raw} 不该被报成配置问题`,
    );
  }
});

test('请求级参数不被开关影响：temperature 与 messages 照旧', async () => {
  const body = await callWith(['reviewExplain'], 'reviewExplain');
  assert.equal(body.temperature, 0.2);
  assert.equal(body.messages[0].role, 'system');
  assert.equal(body.messages[1].content, '学生答案：11/12');
});
