#!/usr/bin/env node
/**
 * 本机 Ollama 适配探测（不需要网络、不需要凭证）。
 *
 * 回答一个问题：**本机这几个模型，能不能直接顶上网关的三级档位？**
 *
 * 为什么要单独写一个，而不是直接起网关接 Ollama 跑一遍：
 * 网关的链路里 tool calling、schema 校验、重试、降级是叠在一起的，
 * 端到端失败时你无法判断是本机模型不行、还是别的地方不行。
 * 这里**只测那一件不可替代的事** —— 模型到底会不会按 tools 调函数。
 *
 * 判据是「实际行为」而非「声明能力」：Ollama 的 /api/show 会把 tools 列进
 * capabilities，但那是模板级的（模型愿意调 vs 模板允许调是两回事）。
 * 小模型最常见的两种失败：把 JSON 写坏、或者干脆回一段大白话。
 *
 * 用法：
 *   node scripts/probe-ollama.mjs                # 测默认几个模型
 *   node scripts/probe-ollama.mjs gemma4:26b     # 只测指定的
 *   OLLAMA_BASE_URL=http://127.0.0.1:11434 node scripts/probe-ollama.mjs
 *
 * 退出码：0 = 至少有一个模型可用；1 = 一个都没有。
 */

const BASE = (process.env.OLLAMA_BASE_URL || 'http://127.0.0.1:11434').replace(/\/$/, '');

/** 默认按「能顶什么档位」来挑：视觉档要真多模态，推理档要中文与判定能力。 */
const DEFAULT_MODELS = [
  'gemma4:26b',
  'gemma4:e4b',
  'qwen2.5:7b',
  'qwen3-coder:30b',
  'deepseek-r1:14b',
];

/**
 * 一个极简但**形状真实**的工具：网关判定链路里最关键的那个。
 * 刻意不做成完整业务 schema —— 这里要分辨的是「会不会调函数」，
 * 不是「能不能答对题」。混在一起测，失败时归因不清。
 */
const JUDGE_TOOL = {
  type: 'function',
  function: {
    name: 'report_answer_judgement',
    description: '给出学生答案是否与参考答案一致的判定结论。',
    parameters: {
      type: 'object',
      properties: {
        correct: { type: 'boolean', description: '学生答案正确则为 true' },
        reason: { type: 'string', description: '一句话说明判定依据' },
      },
      required: ['correct', 'reason'],
    },
  },
};

const QUESTION = [
  '你是小学数学老师，请判定学生的答案是否正确。',
  '',
  '题目：比较 3/4 和 5/7 的大小',
  '参考答案：3/4 > 5/7（3/4=21/28，5/7=20/28）',
  '学生答案：3/4 大，因为通分后是 21/28 和 20/28',
].join('\n');

/** 宽字符按 2 列算宽度，否则中文标签会把整列顶歪。 */
function width(s) {
  let w = 0;
  for (const ch of s) {
    const code = ch.codePointAt(0);
    w += code >= 0x1100 && (code <= 0x115f || code === 0x2329 || code === 0x232a ||
      (code >= 0x2e80 && code <= 0xa4cf) || (code >= 0xac00 && code <= 0xd7a3) ||
      (code >= 0xf900 && code <= 0xfaff) || (code >= 0xfe30 && code <= 0xfe6f) ||
      (code >= 0xff00 && code <= 0xff60) || (code >= 0xffe0 && code <= 0xffe6) ||
      (code >= 0x1f300 && code <= 0x1f64f) || (code >= 0x20000 && code <= 0x3fffd))
      ? 2 : 1;
  }
  return w;
}

function pad(s, n) {
  const diff = n - width(s);
  return diff > 0 ? s + ' '.repeat(diff) : s;
}

/** 这个模型到底有没有被本机拉下来（拿不到就说明 tag 写错了）。 */
async function listModels() {
  const response = await fetch(`${BASE}/api/tags`);
  if (!response.ok) throw new Error(`Ollama 未响应（HTTP ${response.status}）`);
  const data = await response.json();
  return (data.models || []).map((m) => m.name);
}

/**
 * 问一次模型，把「它到底干了什么」原样记下来。
 *
 * 不抛异常 —— 探测失败是要断言的对象，不是要中断的意外。
 */
async function probeToolCall(model) {
  const startedAt = Date.now();
  let response;
  try {
    response = await fetch(`${BASE}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model,
        messages: [{ role: 'user', content: QUESTION }],
        tools: [JUDGE_TOOL],
        tool_choice: 'auto',
        temperature: 0,
        stream: false,
      }),
      signal: AbortSignal.timeout(240_000),
    });
  } catch (error) {
    return { ok: false, elapsed: Date.now() - startedAt, why: `请求失败：${error.message}` };
  }

  const elapsed = Date.now() - startedAt;
  if (!response.ok) {
    const body = await response.text();
    return {
      ok: false,
      elapsed,
      why: `HTTP ${response.status}：${body.slice(0, 120)}`,
    };
  }

  const payload = await response.json();
  const choice = payload.choices?.[0];
  const call = choice?.message?.tool_calls?.[0];
  const usage = payload.usage;

  if (!call) {
    const text = (choice?.message?.content || '').trim().replace(/\s+/g, ' ').slice(0, 60);
    return {
      ok: false,
      elapsed,
      usage,
      why: text
        ? `没调函数，回了一段文本：「${text}…」`
        : `没调函数（finish_reason=${choice?.finish_reason}）`,
    };
  }

  // 名字对不对：本地小模型偶尔会自己编一个函数名。
  if (call.function?.name !== JUDGE_TOOL.function.name) {
    return {
      ok: false,
      elapsed,
      usage,
      why: `函数名不对：要 ${JUDGE_TOOL.function.name}，给了 ${call.function?.name}`,
    };
  }

  // arguments 是字符串形式的 JSON —— 写坏是最常见的失败。
  let args;
  try {
    args = JSON.parse(call.function.arguments);
  } catch {
    return {
      ok: false,
      elapsed,
      usage,
      why: `arguments 不是合法 JSON：${String(call.function.arguments).slice(0, 70)}`,
    };
  }

  // 必填字段不能缺（缺了网关的 schema 校验会拦下来重试）。
  const missing = JUDGE_TOOL.function.parameters.required.filter((k) => args[k] === undefined);
  if (missing.length) {
    return { ok: false, elapsed, usage, why: `缺必填字段：${missing.join(', ')}` };
  }

  if (typeof args.correct !== 'boolean') {
    return { ok: false, elapsed, usage, why: `correct 不是布尔：${JSON.stringify(args.correct)}` };
  }

  return { ok: true, elapsed, usage, correct: args.correct, reason: String(args.reason) };
}

/** 视觉档要真的能读图 —— 能力位写着 vision 不等于会用它。 */
async function probeVision(model) {
  // 1×1 红点 PNG。够让模型「看到一张图」，也够暴露「图根本没传进去」。
  const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
  const startedAt = Date.now();
  try {
    const response = await fetch(`${BASE}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model,
        messages: [
          {
            role: 'user',
            content: [
              { type: 'text', text: '这张图里主要是什么颜色？只回一个词。' },
              {
                type: 'image_url',
                image_url: { url: `data:image/png;base64,${png}` },
              },
            ],
          },
        ],
        temperature: 0,
        stream: false,
      }),
      signal: AbortSignal.timeout(120_000),
    });
    const elapsed = Date.now() - startedAt;
    if (!response.ok) {
      const body = await response.text();
      return { ok: false, elapsed, why: `HTTP ${response.status}：${body.slice(0, 100)}` };
    }
    const payload = await response.json();
    const text = (payload.choices?.[0]?.message?.content || '').trim().replace(/\s+/g, ' ');
    if (!text) return { ok: false, elapsed, why: '回了空内容' };
    return { ok: true, elapsed, answer: text.slice(0, 30) };
  } catch (error) {
    return { ok: false, elapsed: Date.now() - startedAt, why: `请求失败：${error.message}` };
  }
}

async function main() {
  const wanted = process.argv.slice(2).filter((a) => !a.startsWith('-'));
  console.log(`Ollama: ${BASE}`);
  let installed;
  try {
    installed = await listModels();
  } catch (error) {
    console.error(`\n连不上 Ollama：${error.message}`);
    console.error('确认服务已启动（ollama serve），或改 OLLAMA_BASE_URL。');
    process.exit(2);
  }

  const models = wanted.length ? wanted : DEFAULT_MODELS;
  console.log(`本机已装 ${installed.length} 个模型\n`);

  let usable = 0;
  const rows = [];

  for (const model of models) {
    if (!installed.includes(model)) {
      console.log(`[跳过] ${model}  —— 本机没有这个 tag（已装的在下面列着）`);
      continue;
    }
    process.stdout.write(`[测试] ${pad(model, 18)} 结构化判定 … `);
    const result = await probeToolCall(model);
    if (result.ok) usable++;
    console.log(result.ok ? `通过（${(result.elapsed / 1000).toFixed(1)}s）` : `失败（${(result.elapsed / 1000).toFixed(1)}s）`);
    if (!result.ok) console.log(`         ↳ ${result.why}`);
    rows.push({ model, ...result });
  }

  // 汇总：一眼看出哪个能顶哪个档位。
  console.log('\n结构化输出（tool calling）实测结果');
  console.log('-'.repeat(78));
  console.log(`${pad('模型', 20)}${pad('结果', 8)}${pad('耗时', 9)}${pad('token(in/out)', 16)}判定`);
  console.log('-'.repeat(78));
  for (const row of rows) {
    const tokens = row.usage
      ? `${row.usage.prompt_tokens ?? '?'}/${row.usage.completion_tokens ?? '?'}`
      : '-';
    const verdict = row.ok ? `${row.correct ? '正确' : '错误'} · ${String(row.reason).slice(0, 22)}` : '—';
    console.log(
      pad(row.model, 20) +
        pad(row.ok ? '可用' : '不可用', 8) +
        pad(`${(row.elapsed / 1000).toFixed(1)}s`, 9) +
        pad(tokens, 16) +
        verdict,
    );
  }
  console.log('-'.repeat(78));

  // 有 vision 位的再测一次读图 —— 批改链路必须它真的能看图。
  const visionCandidates = rows.filter((r) => r.ok).map((r) => r.model);
  const visionProbes = [...new Set([...models, ...visionCandidates])];
  const images = [];
  for (const model of visionProbes) {
    if (!installed.includes(model)) continue;
    process.stdout.write(`[测试] ${pad(model, 18)} 读图 … `);
    const result = await probeVision(model);
    if (result.ok) images.push({ model, ...result });
    console.log(result.ok ? `通过（${(result.elapsed / 1000).toFixed(1)}s）→ ${result.answer}` : `失败（${(result.elapsed / 1000).toFixed(1)}s）`);
    if (!result.ok) console.log(`         ↳ ${result.why}`);
  }

  console.log('\n结论');
  console.log('-'.repeat(78));
  if (!usable) {
    console.log('没有任何模型能产出可用的 tool_calls。');
    console.log('网关的结构化输出依赖它 —— 这种情况请保持 gateway 的离线兜底，不要接本机。');
  } else {
    const okModels = rows.filter((r) => r.ok).map((r) => r.model);
    console.log(`可作结构化输出（强推理/文本档）：${okModels.join('、')}`);
    if (images.length) {
      console.log(`可作视觉档（作业批改）：${images.map((i) => i.model).join('、')}`);
    } else {
      console.log('没有模型能读图 —— 视觉档请留空，让作业批改走本地兜底。');
    }
  }
  console.log('-'.repeat(78));

  process.exit(usable ? 0 : 1);
}

main().catch((error) => {
  console.error(error);
  process.exit(2);
});
