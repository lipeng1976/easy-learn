import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createServer } from 'node:http';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { ArkModelClient } from '../src/ark.js';
import { Schemas } from '../src/schema.js';

const BASE_CONFIG = {
  ark: {
    region: 'cn-beijing',
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    apiKey: 'test-key',
    models: {
      vision: 'doubao-vision-test',
      reasoning: 'doubao-reasoning-test',
      light: 'doubao-light-test',
    },
    timeoutMs: 1000,
    maxAttempts: 2,
  },
};

/** 造一个假的 fetch，按顺序返回预设响应，并记录每次请求。 */
function fakeFetch(responses) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    const next = responses[Math.min(calls.length - 1, responses.length - 1)];
    if (next instanceof Error) throw next;
    return {
      ok: next.status >= 200 && next.status < 300,
      status: next.status,
      text: async () => next.text,
    };
  };
  impl.calls = calls;
  return impl;
}

function toolCallResponse(value) {
  return {
    status: 200,
    text: JSON.stringify({
      choices: [
        {
          finish_reason: 'tool_calls',
          message: {
            tool_calls: [
              {
                function: {
                  name: 'report_answer_judgement',
                  arguments: JSON.stringify(value),
                },
              },
            ],
          },
        },
      ],
      usage: { prompt_tokens: 120, completion_tokens: 40, total_tokens: 160 },
    }),
  };
}

function client(config, responses) {
  const fetchImpl = fakeFetch(responses);
  const instance = new ArkModelClient({
    config,
    fetchImpl,
    sleep: async () => {},
  });
  return { instance, fetchImpl };
}

const judgeParams = {
  capability: 'reasoning',
  schema: Schemas.reviewJudge,
  system: '判定学生答案',
  content: '学生答案：11/12',
};

test('按能力路由到对应模型，并把 tool schema 一起发过去', async () => {
  const { instance, fetchImpl } = client(BASE_CONFIG, [
    toolCallResponse({ verdict: 'correct', score: 100, comment: '对了' }),
  ]);

  await instance.complete(judgeParams);

  assert.equal(fetchImpl.calls.length, 1);
  const { url, init, body } = fetchImpl.calls[0];
  assert.equal(url, 'https://ark.cn-beijing.volces.com/api/v3/chat/completions');
  assert.equal(init.headers.Authorization, 'Bearer test-key');
  assert.equal(body.model, 'doubao-reasoning-test');
  assert.equal(body.tools[0].function.name, 'report_answer_judgement');
  assert.equal(body.tool_choice.function.name, 'report_answer_judgement');
});

test('视觉能力走视觉档模型，而不是复用强推理档', async () => {
  const { instance, fetchImpl } = client(BASE_CONFIG, [
    toolCallResponse({
      text: '识别结果',
      subject: '数学',
      confidence: 0.9,
      tasks: [{ subject: '数学', text: '第1-20题' }],
    }),
  ]);

  await instance.complete({
    capability: 'vision',
    schema: Schemas.homeworkOcr,
    system: '识别',
    content: '看图',
  });

  assert.equal(fetchImpl.calls[0].body.model, 'doubao-vision-test');
});

test('能力未配置模型：不发请求，报 model_not_enabled 且不可重试', async () => {
  const { instance, fetchImpl } = client(
    {
      ark: {
        ...BASE_CONFIG.ark,
        models: { vision: '', reasoning: '', light: '' },
      },
    },
    [],
  );

  await assert.rejects(
    () => instance.complete(judgeParams),
    (error) => {
      assert.equal(error.code, 'model_not_enabled');
      // 重试一百次也不会让一个没配的模型出现，所以必须不可重试，
      // 否则只会把「配置漏了」表现成「偶发失败」。
      assert.equal(error.retryable, false);
      return true;
    },
  );
  assert.equal(fetchImpl.calls.length, 0);
});

test('响应走 content 且带 ```json 围栏时也能解析', async () => {
  // 不是所有模型都支持 tool calling，只认 tool_calls 会让那些模型 100% 失败。
  const { instance } = client(BASE_CONFIG, [
    {
      status: 200,
      text: JSON.stringify({
        choices: [
          {
            finish_reason: 'stop',
            message: {
              content:
                '好的，以下是结果：\n```json\n{"verdict":"wrong","score":0,"comment":"通分错了"}\n```',
            },
          },
        ],
      }),
    },
  ]);

  const result = await instance.complete(judgeParams);
  assert.equal(result.value.verdict, 'wrong');
});

test('content 是片段数组时也能解析', async () => {
  const { instance } = client(BASE_CONFIG, [
    {
      status: 200,
      text: JSON.stringify({
        choices: [
          {
            finish_reason: 'stop',
            message: {
              content: [
                { type: 'text', text: '{"verdict":"correct",' },
                { type: 'text', text: '"score":100,"comment":"对"}' },
              ],
            },
          },
        ],
      }),
    },
  ]);

  const result = await instance.complete(judgeParams);
  assert.equal(result.value.verdict, 'correct');
});

test('schema 违约不在这里重试（提示词没变，重试只会重犯）', async () => {
  const { instance, fetchImpl } = client(BASE_CONFIG, [
    toolCallResponse({ verdict: 'correct', score: 100 }), // 缺 comment
  ]);

  await assert.rejects(
    () => instance.complete(judgeParams),
    (error) => {
      assert.equal(error.code, 'schema_violation');
      assert.equal(error.retryable, true); // 交给客户端带 retryHint 再来
      return true;
    },
  );
  assert.equal(fetchImpl.calls.length, 1);
});

test('模型返回空结果时报 model_output_invalid', async () => {
  const { instance } = client(BASE_CONFIG, [
    {
      status: 200,
      text: JSON.stringify({
        choices: [{ finish_reason: 'length', message: { content: '' } }],
      }),
    },
  ]);

  await assert.rejects(
    () => instance.complete(judgeParams),
    (error) => error.code === 'model_output_invalid',
  );
});

test('401 映射成 model_auth_failed 且不重试', async () => {
  const { instance, fetchImpl } = client(BASE_CONFIG, [
    { status: 401, text: JSON.stringify({ error: { message: 'invalid api key' } }) },
  ]);

  await assert.rejects(
    () => instance.complete(judgeParams),
    (error) => {
      assert.equal(error.code, 'model_auth_failed');
      assert.equal(error.retryable, false);
      assert.match(error.message, /invalid api key/);
      return true;
    },
  );
  assert.equal(fetchImpl.calls.length, 1);
});

test('429 会重试，第二次成功就返回', async () => {
  const { instance, fetchImpl } = client(BASE_CONFIG, [
    { status: 429, text: JSON.stringify({ error: { message: 'rate limited' } }) },
    toolCallResponse({ verdict: 'correct', score: 100, comment: '对了' }),
  ]);

  const result = await instance.complete(judgeParams);
  assert.equal(result.value.verdict, 'correct');
  assert.equal(fetchImpl.calls.length, 2);
});

test('持续 500 会在耗尽重试后抛 model_unavailable', async () => {
  const { instance, fetchImpl } = client(BASE_CONFIG, [
    { status: 500, text: 'upstream boom' },
  ]);

  await assert.rejects(
    () => instance.complete(judgeParams),
    (error) => error.code === 'model_unavailable' && error.retryable === true,
  );
  assert.equal(fetchImpl.calls.length, BASE_CONFIG.ark.maxAttempts);
});

test('超时映射成 model_timeout', async () => {
  const abortError = new Error('aborted');
  abortError.name = 'AbortError';
  const { instance } = client(BASE_CONFIG, [abortError]);

  await assert.rejects(
    () => instance.complete(judgeParams),
    (error) => error.code === 'model_timeout',
  );
});

test('连不上方舟时报 model_unavailable 而不是内部错误', async () => {
  const { instance } = client(BASE_CONFIG, [new Error('ECONNREFUSED')]);

  await assert.rejects(
    () => instance.complete(judgeParams),
    (error) => error.code === 'model_unavailable' && /ECONNREFUSED/.test(error.message),
  );
});

test('400 带上方舟原文，方便运维定位是哪个 model 名写错了', async () => {
  const { instance } = client(BASE_CONFIG, [
    {
      status: 400,
      text: JSON.stringify({
        error: { message: 'model doubao-reasoning-test not found' },
      }),
    },
  ]);

  await assert.rejects(
    () => instance.complete(judgeParams),
    (error) => {
      assert.equal(error.code, 'bad_request');
      assert.match(error.message, /not found/);
      return true;
    },
  );
});

test('capabilities 只在「有 Key 且有模型 ID」时才算可用', () => {
  const ready = new ArkModelClient({ config: BASE_CONFIG, fetchImpl: fakeFetch([]) });
  assert.deepEqual(ready.capabilities(), {
    vision: true,
    reasoning: true,
    light: true,
  });

  const noKey = new ArkModelClient({
    config: { ark: { ...BASE_CONFIG.ark, apiKey: '' } },
    fetchImpl: fakeFetch([]),
  });
  assert.deepEqual(noKey.capabilities(), {
    vision: false,
    reasoning: false,
    light: false,
  });
});

// ---------------------------------------------------------------------------
// scripts/probe-ark.mjs —— 真凭证探活脚本
//
// 这个脚本验的是「本地怎么测都测不出来」的两件事（模型是否真的开通、
// usage 的字段名）。所以它自己必须先被验：否则哪天它悄悄失效了，
// 上线前那条唯一的检查命令就成了摆设，而没人会注意到。
//
// 这里用**一个只回固定响应的本地假方舟**来验它，不需要真凭证。
// ---------------------------------------------------------------------------

const execFileAsync = promisify(execFile);
const PROBE_SCRIPT = fileURLToPath(new URL('../scripts/probe-ark.mjs', import.meta.url));

/** 跑探活脚本并把退出码与输出都拿回来（非 0 退出不算异常，是要断言的对象）。 */
async function runProbe(env, args = ['reasoning']) {
  try {
    const { stdout, stderr } = await execFileAsync(process.execPath, [PROBE_SCRIPT, ...args], {
      env: { ...process.env, ...env },
      encoding: 'utf8',
    });
    return { code: 0, stdout, stderr };
  } catch (error) {
    return { code: error.code, stdout: error.stdout ?? '', stderr: error.stderr ?? '' };
  }
}

/** 造一个假方舟，只回一条固定形状的响应。`usage` 由调用方控制 —— 那正是要验的东西。 */
async function withFakeArk(usage, run) {
  const server = createServer((request, response) => {
    let body = '';
    request.on('data', (chunk) => {
      body += chunk;
    });
    request.on('end', () => {
      const sent = JSON.parse(body || '{}');
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(
        JSON.stringify({
          choices: [
            {
              finish_reason: 'tool_calls',
              message: {
                tool_calls: [
                  {
                    function: {
                      // 回显请求里要的那个函数名，和真实方舟的行为一致。
                      name: sent.tools?.[0]?.function?.name ?? 'report_probe_result',
                      arguments: JSON.stringify({ summary: '收到了，这是一次探查。' }),
                    },
                  },
                ],
              },
            },
          ],
          ...(usage === undefined ? {} : { usage }),
        }),
      );
    });
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  try {
    return await run(`http://127.0.0.1:${port}/api/v3`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

const PROBE_ENV = {
  ARK_API_KEY: 'probe-key',
  ARK_MODEL_VISION: '',
  ARK_MODEL_REASONING: 'doubao-reasoning-probe',
  ARK_MODEL_LIGHT: '',
};

test('探活脚本：没有 ARK_API_KEY 时如实拒绝，而不是拿起就调', async () => {
  const result = await runProbe({ ...PROBE_ENV, ARK_API_KEY: '' });

  assert.equal(result.code, 2);
  // 报错必须点名那个变量：一句「配置不全」会让人从 18 个环境变量里挨个猜。
  assert.match(result.stderr, /ARK_API_KEY/);
});

test('探活脚本：通道正常时报通过，并核对 usage 的字段名', async () => {
  const result = await withFakeArk(
    { prompt_tokens: 30, completion_tokens: 8, total_tokens: 38 },
    (baseUrl) => runProbe({ ...PROBE_ENV, ARK_BASE_URL: baseUrl }),
  );

  assert.equal(result.code, 0);
  assert.match(result.stdout, /\[通过\] reasoning/);
  assert.match(result.stdout, /in 30 \/ out 8/);
  assert.match(result.stdout, /全部通过/);
});

test('探活脚本：usage 用了别的字段名时判失败，并点出实际返回了哪些键', async () => {
  // 这正是这条命令存在的理由：字段名换了以后，看板不会报错，
  // 它只会安静地把 token 记成 0、让成本退化成「下限」。
  const result = await withFakeArk(
    { input_tokens: 30, output_tokens: 8 },
    (baseUrl) => runProbe({ ...PROBE_ENV, ARK_BASE_URL: baseUrl }),
  );

  assert.equal(result.code, 1);
  assert.match(result.stdout, /prompt_tokens/);
  assert.match(result.stdout, /input_tokens, output_tokens/);
});

test('探活脚本：响应里根本没有 usage 时也判失败（成本会变成下限）', async () => {
  const result = await withFakeArk(undefined, (baseUrl) =>
    runProbe({ ...PROBE_ENV, ARK_BASE_URL: baseUrl }),
  );

  assert.equal(result.code, 1);
  assert.match(result.stdout, /没有 usage/);
});

test('探活脚本：未配置的能力跳过而不是判失败，并说明网关会回 model_not_enabled', async () => {
  const result = await withFakeArk(
    { prompt_tokens: 30, completion_tokens: 8 },
    (baseUrl) => runProbe({ ...PROBE_ENV, ARK_BASE_URL: baseUrl }, []),
  );

  assert.equal(result.code, 0);
  assert.match(result.stdout, /跳过 vision \/ light/);
  assert.match(result.stdout, /model_not_enabled/);
});
