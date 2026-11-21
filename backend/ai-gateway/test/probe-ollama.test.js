import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createServer } from 'node:http';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import test from 'node:test';

// ---------------------------------------------------------------------------
// scripts/probe-ollama.mjs —— 本机 Ollama 适配探测
//
// 这个脚本要回答的是「本机那个模型能不能顶上网关档位」，本地单元测试
// 测不出真模型的脾气。但它自己**必须**被测：它是接本机模型时唯一的
// 判断依据，一旦它悄悄失效（比如把「没调函数」也判成通过），
// 后果是按一份错的结论去配生产环境。
//
// 用**一个假 Ollama**（同时实现 /api/tags 与 /v1/chat/completions）驱动它。
// ---------------------------------------------------------------------------

const execFileAsync = promisify(execFile);
const PROBE_SCRIPT = fileURLToPath(new URL('../scripts/probe-ollama.mjs', import.meta.url));

const TOOL_NAME = 'report_answer_judgement';

/** 跑探测脚本，把退出码与输出都拿回来（非 0 退出是要断言的对象，不是异常）。 */
async function runProbe(baseUrl, models = ['m:ok']) {
  try {
    const { stdout, stderr } = await execFileAsync(process.execPath, [PROBE_SCRIPT, ...models], {
      env: { ...process.env, OLLAMA_BASE_URL: baseUrl },
      encoding: 'utf8',
    });
    return { code: 0, stdout, stderr };
  } catch (error) {
    return { code: error.code, stdout: error.stdout ?? '', stderr: error.stderr ?? '' };
  }
}

/**
 * 一个假 Ollama。`mode` 决定模型**怎么回**那一次判定调用 ——
 * 每个 mode 对应一种真实模型会犯的毛病。
 */
async function withFakeOllama(mode, run, options = {}) {
  const models = options.models ?? ['m:ok'];
  const server = createServer((request, response) => {
    let body = '';
    request.on('data', (chunk) => {
      body += chunk;
    });
    request.on('end', () => {
      const url = request.url || '';

      if (url.includes('/api/tags')) {
        response.writeHead(200, { 'Content-Type': 'application/json' });
        response.end(JSON.stringify({ models: models.map((name) => ({ name })) }));
        return;
      }

      let sent = {};
      try {
        sent = JSON.parse(body || '{}');
      } catch {
        // 忽略：格式不重要，这里只关心怎么回。
      }
      const isVision = JSON.stringify(sent.messages ?? []).includes('image_url');

      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify(envelope(mode, { isVision, sent })));
    });
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  try {
    return await run(`http://127.0.0.1:${port}`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

/** 照 mode 造一份响应体。 */
function envelope(mode, { isVision, sent }) {
  const usage = { prompt_tokens: 120, completion_tokens: 18 };
  const text = (content) => ({
    choices: [{ finish_reason: 'stop', message: { role: 'assistant', content } }],
    usage,
  });
  const call = (name, args) => ({
    choices: [
      {
        finish_reason: 'tool_calls',
        message: {
          role: 'assistant',
          content: '',
          tool_calls: [
            { type: 'function', function: { name, arguments: typeof args === 'string' ? args : JSON.stringify(args) } },
          ],
        },
      },
    ],
    usage,
  });

  // 视觉探测（带图那一次）单独回，免得和 tool calling 用例互相干扰。
  if (isVision) {
    const requested = sent.model ?? '';
    if (mode === 'vision_fail') {
      return text('');
    }
    return text(requested.startsWith('blind') ? '我无法看到图片' : '红色');
  }

  switch (mode) {
    case 'tool_ok':
      return call(TOOL_NAME, { correct: true, reason: '通分后 21/28 > 20/28。' });
    // 最要紧的一类失败：模型**不肯调函数**，回一段大白话。
    // 判它失败时必须把它说的话带上 —— 否则用户无法区分
    // 「模型不肯调」和「工具定义写错了」。
    case 'text_only':
      return text('这道题学生答对了，因为通分后 21/28 比 20/28 大。');
    case 'bad_json':
      return call(TOOL_NAME, '{"correct": true, "reason": 通分后比较');
    case 'missing_field':
      return call(TOOL_NAME, { correct: true });
    case 'wrong_name':
      return call('judge_it', { correct: true, reason: '对' });
    case 'wrong_type':
      return call(TOOL_NAME, { correct: 'true', reason: '对' });
    case 'empty':
      return { choices: [{ finish_reason: 'length', message: { role: 'assistant', content: '' } }], usage };
    default:
      return call(TOOL_NAME, { correct: true, reason: '默认' });
  }
}

test('探测脚本：连不上 Ollama 时退出码 2，并给出怎么处理', async () => {
  // 127.0.0.1:1 基本不可能是 Ollama —— 用它模拟服务没起。
  const result = await runProbe('http://127.0.0.1:1', ['m:ok']);

  assert.equal(result.code, 2);
  assert.match(result.stderr, /Ollama/);
  assert.match(result.stderr, /ollama serve|OLLAMA_BASE_URL/);
});

test('探测脚本：模型正常产出 tool_calls 时判通过，并回退出码 0', async () => {
  const result = await withFakeOllama('tool_ok', (baseUrl) => runProbe(baseUrl, ['m:ok']));

  assert.equal(result.code, 0);
  assert.match(result.stdout, /\[测试\] m:ok\s+结构化判定 … 通过/);
  assert.match(result.stdout, /可作结构化输出/);
  assert.match(result.stdout, /m:ok/);
});

test('探测脚本：模型只回文本不调函数时判失败，并把它回的内容带出来', async () => {
  // 判据必须是「实际行为」：Ollama 的 capabilities 会报 tools 支持，
  // 但模型完全可能选择不调。只说「失败」而不给原文，
  // 排查时无法区分是模型不肯调、还是工具定义有问题。
  const result = await withFakeOllama('text_only', (baseUrl) => runProbe(baseUrl, ['m:ok']));

  assert.equal(result.code, 1);
  assert.match(result.stdout, /没调函数/);
  assert.match(result.stdout, /通分后 21\/28 比 20\/28 大/);
});

test('探测脚本：arguments 不是合法 JSON 时判失败，并列出实际内容', async () => {
  const result = await withFakeOllama('bad_json', (baseUrl) => runProbe(baseUrl, ['m:ok']));

  assert.equal(result.code, 1);
  assert.match(result.stdout, /不是合法 JSON/);
});

test('探测脚本：缺必填字段时判失败，并点名缺了哪个', async () => {
  const result = await withFakeOllama('missing_field', (baseUrl) => runProbe(baseUrl, ['m:ok']));

  assert.equal(result.code, 1);
  assert.match(result.stdout, /缺必填字段.*reason/);
});

test('探测脚本：函数名被模型自己编掉时判失败', async () => {
  const result = await withFakeOllama('wrong_name', (baseUrl) => runProbe(baseUrl, ['m:ok']));

  assert.equal(result.code, 1);
  assert.match(result.stdout, /函数名不对/);
  assert.match(result.stdout, /judge_it/);
});

test('探测脚本：类型不符（correct 是字符串）时判失败', async () => {
  // 字符串 "true" 在 JS 里是 truthy，不查类型就会把「写错类型」当通过 ——
  // 而网关侧 schema 校验会拦下它并触发重试，等于白跑一次。
  const result = await withFakeOllama('wrong_type', (baseUrl) => runProbe(baseUrl, ['m:ok']));

  assert.equal(result.code, 1);
  assert.match(result.stdout, /correct 不是布尔/);
});

test('探测脚本：空的 completion 时判失败而不是崩溃', async () => {
  const result = await withFakeOllama('empty', (baseUrl) => runProbe(baseUrl, ['m:ok']));

  assert.equal(result.code, 1);
  assert.match(result.stdout, /没调函数/);
});

test('探测脚本：本机没有的 tag 跳过而不判失败，并在结论里如实分开', async () => {
  // 「这个 tag 没装」和「这个模型不可用」是两件事：
  // 前者要去看 tag 有没有拼错，后者要换模型。混成一句会误导排查方向。
  const result = await withFakeOllama('tool_ok', (baseUrl) => runProbe(baseUrl, ['m:ok', 'm:nope']));

  assert.equal(result.code, 0);
  assert.match(result.stdout, /\[跳过\] m:nope/);
  assert.match(result.stdout, /本机没有这个 tag/);
  // 通过的那个仍然要出现在结论里。
  assert.match(result.stdout, /可作结构化输出.*m:ok/);
});

test('探测脚本：读图那一步会单独复测，并在结论里区分结构化与视觉两个用途', async () => {
  const result = await withFakeOllama('tool_ok', (baseUrl) => runProbe(baseUrl, ['m:ok']));

  assert.match(result.stdout, /读图 … 通过/);
  assert.match(result.stdout, /可作视觉档（作业批改）：m:ok/);
});

test('探测脚本：一个模型都不行时退出码 1，并明确说保持离线兜底', async () => {
  const result = await withFakeOllama('text_only', (baseUrl) => runProbe(baseUrl, ['m:ok']));

  assert.equal(result.code, 1);
  assert.match(result.stdout, /没有任何模型能产出可用的 tool_calls/);
  assert.match(result.stdout, /不要接本机/);
});
