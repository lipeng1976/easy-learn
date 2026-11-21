#!/usr/bin/env node

/**
 * 首次接入**阿里云百炼（OpenAI 兼容端点）**时的模型目录探查。
 *
 * ## 为什么不能复用 `probe-ark-catalog.mjs`
 *
 * 那个脚本吃的是**方舟的** `GET /api/v3/models`：它读 `task_type` / 输出模态 /
 * `Shutdown`·`Retiring` 这些**方舟私有字段**，用来筛「哪些模型能走 chat」。
 * 百炼的兼容端点是标准 OpenAI 形状 —— `GET /models` 只回 `{id, object, created, owned_by}`，
 * 上面那些字段**一个都没有**。拿旧脚本去跑，筛出来的东西没有依据，
 * 所以这里是**分开的第二个脚本**，不是重复造轮子。
 *
 * ## 它回答的问题
 *
 * 「我该把什么填进 `ARK_MODEL_VISION` / `ARK_MODEL_REASONING` / `ARK_MODEL_LIGHT`？」
 *
 * 目录里 200+ 个模型名，而**目录 ≠ 这个账号能用**（方舟那次就栽在这：
 * 26 个候选里只开通了 1 个，剩下的回 404 而文案看着像「模型 ID 打错了」）。
 * 所以这里不猜、不查文档，只做一件事：**照网关真实形态各发一次请求，把原始响应摊开看**。
 *
 * ## 为什么必须「照网关真实形态」而不是发个简化请求
 *
 * 本网关**靠 function calling 硬约束结构化输出**（见 `ark.js` 的 buildRequestBody），
 * 所以「这个模型能聊天」**远远不够** —— 它还必须接受 `tools` 与我们要的 `tool_choice`。
 * 一个能聊天但不吃 `tool_choice: {type:'function',...}` 的模型，
 * 装上去的表现是**每次都拿不到结构化结果**，而不是启动报错。
 *
 * 因此每个候选按**网关实际会发的三种形态**各探一遍（见 `SHAPES`）：
 *
 * 1. `thinkingOff` —— 路由在 `AI_THINKING_DISABLED_KINDS` 里时发的形态：
 *    `enable_thinking: false` + **对象形式**的 `tool_choice`（硬约束）。
 * 2. `judgeLike` —— 路由**不在**名单里时发的形态：**不发** `enable_thinking`
 *    （百炼的默认 = 思考模式开着）+ `tool_choice: 'auto'`（软约束）。
 *    ⚠️ **`reviewJudge` 现在就是这个形态**，所以这一格直接决定「判定能不能跑」。
 * 3. `thinkingOnObject` —— 只为把「思考模式 + 对象 tool_choice」这个组合**钉死**：
 *    文档说不允许，实测到底是什么错误码。探它是因为**它决定了 2 能不能修**：
 *    若实测允许传对象，那 2 的软约束就可以就地改成硬约束。
 *
 * ## 用法
 *
 * ```bash
 * cd serverless/ai-gateway
 * set -a; . ./.env.local; set +a
 * node scripts/probe-bailian-catalog.mjs              # 目录 + 默认候选筛查
 * node scripts/probe-bailian-catalog.mjs --dry        # 只看目录，一个请求都不发
 * node scripts/probe-bailian-catalog.mjs --only=vl    # 只探名字含 vl 的
 * node scripts/probe-bailian-catalog.mjs --models=qwen3-vl-plus,qwen3-max
 * ```
 *
 * 环境变量：`ARK_API_KEY`（必填）、`ARK_BASE_URL`（默认取 `config.js` 里百炼的预设）。
 *
 * 退出码：`0` 至少有一个候选在「关思考」形态下通过；`1` 全部候选都不可用
 * （**这通常是账号侧没开通/没实名，不是代码问题**）；`2` 配置不全或目录拉不下来。
 */

import { MODEL_PROVIDERS } from '../src/config.js';
import { probeImageDataUri } from './lib/probe-image.mjs';

const BASE_URL = process.env.ARK_BASE_URL
  || MODEL_PROVIDERS.bailian.defaultBaseUrl();

const API_KEY = (() => {
  const k = process.env.ARK_API_KEY ?? '';
  if (k.trim() === '') {
    console.error('✗ 缺 ARK_API_KEY。用法：set -a; . ./.env.local; set +a');
    process.exit(2);
  }
  return k.trim();
})();

// ── 命令行 ────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const DRY = argv.includes('--dry');
const ONLY = (argv.find((a) => a.startsWith('--only=')) ?? '').slice('--only='.length);
const MODELS_ARG = (argv.find((a) => a.startsWith('--models=')) ?? '')
  .slice('--models='.length)
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

/**
 * 默认候选。**刻意每个系列只取一个「不带日期后缀」的别名**（如 `qwen3-vl-plus`）——
 * 带日期的那种（`qwen3-vl-plus-2025-09-23`）是快照，适合长期锁版本，
 * 而第一步先把「哪个系列可用」确定下来；锁快照是之后的事。
 */
const DEFAULT_CANDIDATES = {
  vision: ['qwen3-vl-plus', 'qwen-vl-max', 'qwen3-vl-flash', 'qwen3.5-ocr'],
  reasoning: ['qwen3.8-max', 'qwen3-max', 'qwen3.7-max'],
  light: ['qwen3.8-flash', 'qwen-flash', 'qwen-turbo'],
};

// ── 探针图：**与 `probe-ark.mjs` 共用同一份** ──────────────────────────
//
// 不在这里各造一张 —— 两张图意味着两条判据。上面那个模块的文件头记着
// 「为什么不能用 1×1 的图」（百炼要求长宽 > 10px，而报错看起来像模型不可用）。
const PROBE_IMAGE_URI = probeImageDataUri();

// ── 请求形态 ──────────────────────────────────────────────────────────────

const TOOL = {
  type: 'function',
  function: {
    name: 'report_result',
    description: '回填结构化结果',
    parameters: {
      type: 'object',
      properties: {
        summary: { type: 'string', description: '一句话结论' },
        confidence: { type: 'number', description: '0-1 的置信度' },
      },
      required: ['summary', 'confidence'],
      additionalProperties: false,
    },
  },
};

const OBJECT_CHOICE = { type: 'function', function: { name: TOOL.function.name } };

/**
 * 三种形态。`expect` 只是给输出加一句人看的注解，**不做断言** ——
 * 探测脚本的职责是把事实摊开，不是判定对错（判定由人来定口径）。
 */
const SHAPES = {
  // ① 路由在 AI_THINKING_DISABLED_KINDS 里 → 网关发这个。
  thinkingOff: () => ({
    extra: { enable_thinking: false },
    toolChoice: OBJECT_CHOICE,
    note: '关思考 + 对象 tool_choice（硬约束）← 名单内的路由',
  }),
  // ② 路由不在名单里 → 网关发这个。⚠️ reviewJudge 现在就是这一格。
  judgeLike: () => ({
    extra: {},
    toolChoice: 'auto',
    note: '不发 enable_thinking（=思考开着）+ auto ← reviewJudge 现在这一格',
  }),
  // ③ 只为钉死「思考开着能不能传对象」。
  thinkingOnObject: () => ({
    extra: {},
    toolChoice: OBJECT_CHOICE,
    note: '思考开着 + 对象 tool_choice ← 文档说不允许，实测看错误码',
  }),
};

function buildBody(model, shape, withImage) {
  const s = shape();
  const text = withImage
    ? '这张图里有什么？用 report_result 回填。'
    : '给出一句话结论：1+1 等于几？用 report_result 回填。';
  const content = withImage
    ? [
      { type: 'text', text },
      { type: 'image_url', image_url: { url: PROBE_IMAGE_URI, detail: 'high' } },
    ]
    : text;

  return {
    model,
    messages: [
      { role: 'system', content: '你是助手，必须通过 report_result 工具回填结果。' },
      { role: 'user', content },
    ],
    tools: [TOOL],
    tool_choice: s.toolChoice,
    max_tokens: 512,
    ...s.extra,
  };
}

async function post(path, body) {
  const started = Date.now();
  let res;
  try {
    res = await fetch(`${BASE_URL}${path}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
  } catch (e) {
    return { status: 0, ms: Date.now() - started, transportError: e.message, raw: '' };
  }
  const raw = await res.text();
  return { status: res.status, ms: Date.now() - started, raw, transportError: '' };
}

function summarize(r) {
  const out = { status: r.status, ms: r.ms, transportError: r.transportError };
  try {
    const j = JSON.parse(r.raw);
    if (j.error) {
      out.code = j.error.code ?? '';
      out.message = String(j.error.message ?? '').slice(0, 200);
      out.requestId = j.request_id ?? j.error.request_id ?? '';
      return out;
    }
    const choice = (j.choices ?? [])[0] ?? {};
    const tc = (choice.message?.tool_calls ?? [])[0];
    out.finish = choice.finish_reason ?? '';
    out.toolCall = tc ? tc.function?.name ?? '(无名)' : null;
    // 结构化输出最终要能被 JSON.parse —— 网关就是这么解 tool_calls 的实参。
    if (tc?.function?.arguments) {
      try {
        out.args = Object.keys(JSON.parse(tc.function.arguments)).join(',');
      } catch {
        out.args = '⚠️ 实参不是合法 JSON';
      }
    }
    // ⚠️ 成本链路只认这两个字段名（guard.js 里 `?? 0` —— 名字不对会**静默记成 0**）。
    out.usageKeys = Object.keys(j.usage ?? {}).join(',');
    out.tokens = j.usage
      ? `${j.usage.prompt_tokens ?? '—'}/${j.usage.completion_tokens ?? '—'}`
      : '(无 usage)';
    out.reasoning = j.usage?.completion_tokens_details?.reasoning_tokens ?? '—';
  } catch {
    out.parseError = (r.raw ?? '').slice(0, 200);
  }
  return out;
}

// ── ① 目录 ────────────────────────────────────────────────────────────────

async function listCatalog() {
  const res = await fetch(`${BASE_URL}/models`, {
    headers: { Authorization: `Bearer ${API_KEY}` },
  });
  if (!res.ok) {
    console.error(`✗ 拉目录失败：HTTP ${res.status}`);
    console.error((await res.text()).slice(0, 400));
    process.exit(2);
  }
  const j = await res.json();
  const ids = (j.data ?? []).map((m) => m.id);
  console.log(`✓ 目录拉到了：${ids.length} 个模型（${BASE_URL}/models）\n`);

  const buckets = [
    ['视觉/多模态（含 vl / omni / ocr / vision）', /(^|[/-])vl|omni|vision|ocr/i],
    ['强推理候选（*-max）', /(^|[/-])[a-z0-9.]*-max(-|$)/i],
    ['轻量候选（flash / turbo）', /flash|turbo/i],
  ];
  for (const [label, re] of buckets) {
    const hit = ids.filter((x) => re.test(x));
    console.log(`【${label}】${hit.length} 个`);
    for (const x of hit.slice(0, 40)) console.log(`   ${x}`);
    if (hit.length > 40) console.log(`   … 另有 ${hit.length - 40} 个`);
    console.log('');
  }
  return ids;
}

// ── ② 候选逐个实调 ────────────────────────────────────────────────────────

async function screen(name, model, withImage) {
  const shape = SHAPES.thinkingOff;
  const r = await post('/chat/completions', buildBody(model, shape, withImage));
  const s = summarize(r);
  const ok = s.status === 200 && s.toolCall !== null;
  const mark = ok ? '✓' : '✗';
  console.log(
    `${mark} [${name}] ${model.padEnd(26)} HTTP ${String(s.status).padEnd(4)}`
    + `${String(s.ms).padStart(5)}ms  ${s.code ?? ''}${s.code ? ' ' : ''}${s.message ?? ''}`,
  );
  if (ok) {
    console.log(
      `      工具=${s.toolCall} 字段=${s.args}  tokens(in/out)=${s.tokens}`
      + `  usage键=${s.usageKeys}  思考token=${s.reasoning}`,
    );
  }
  if (s.transportError) console.log(`      传输层错误：${s.transportError}`);
  if (s.parseError) console.log(`      响应不是 JSON：${s.parseError}`);
  return { model, ok, ...s };
}

// ── ③ 形态差异（决定 reviewJudge 能不能跑）────────────────────────────────

async function shapeMatrix(model, withImage) {
  console.log(`\n【形态差异】模型 = ${model}${withImage ? '（带图）' : '（纯文本）'}\n`);
  const rows = [];
  for (const [key, shape] of Object.entries(SHAPES)) {
    const r = await post('/chat/completions', buildBody(model, shape, withImage));
    const s = summarize(r);
    rows.push({ key, ok: s.status === 200, ...s });
    const mark = s.status === 200 ? '✓' : '✗';
    console.log(`${mark} ${key.padEnd(18)} HTTP ${String(s.status).padEnd(4)} ${s.code ?? ''} ${s.message ?? ''}`);
    console.log(`     ↳ ${shape().note}`);
    if (s.status === 200) {
      console.log(`     ↳ 工具=${s.toolCall} finish=${s.finish} 思考token=${s.reasoning} tokens=${s.tokens}`);
    }
  }
  return rows;
}

// ── main ──────────────────────────────────────────────────────────────────

console.log(`端点：${BASE_URL}\n`);

await listCatalog();
if (DRY) process.exit(0);

const plan = [];
if (MODELS_ARG.length > 0) {
  for (const m of MODELS_ARG) plan.push(['指定', m, false]);
} else {
  for (const [tier, models] of Object.entries(DEFAULT_CANDIDATES)) {
    for (const m of models) {
      if (ONLY !== '' && !m.includes(ONLY)) continue;
      plan.push([tier, m, tier === 'vision']);
    }
  }
}

console.log(`【候选实调】形态 = 关思考 + 对象 tool_choice（网关对名单内路由发的那一种）\n`);
const results = [];
for (const [tier, model, withImage] of plan) {
  results.push({ tier, ...(await screen(tier, model, withImage)) });
}

const usable = {
  vision: results.filter((r) => r.tier === 'vision' && r.ok).map((r) => r.model),
  reasoning: results.filter((r) => r.tier === 'reasoning' && r.ok).map((r) => r.model),
  light: results.filter((r) => r.tier === 'light' && r.ok).map((r) => r.model),
};

console.log('\n─── 可用清单（可直接填进 .env）────────────────────────────');
console.log(`ARK_MODEL_VISION=${usable.vision[0] ?? ''}`);
console.log(`ARK_MODEL_REASONING=${usable.reasoning[0] ?? ''}`);
console.log(`ARK_MODEL_LIGHT=${usable.light[0] ?? ''}`);
if (usable.light.length === 0) {
  console.log('（LIGHT 可以为空 —— 留空只代表该档未开通，网关会如实回 model_not_enabled）');
}

// 形态矩阵：**两级各探一遍** —— 因为「要不要把某条路由加进关闭名单」
// 在两级的答案可能不同（视觉档本来就不产生思维链 token 的话，
// 关掉它零代价、却能换回结构硬约束；强推理档则要权衡准确率与延迟）。
const matrixTargets = [
  ['reasoning', usable.reasoning[0] ?? '', false],
  ['vision', usable.vision[0] ?? '', true],
];
const matrices = {};
for (const [tier, model, withImage] of matrixTargets) {
  if (model === '') continue;
  matrices[tier] = await shapeMatrix(model, withImage);
}

console.log('\n─── 结论 ────────────────────────────────────────────────');
for (const [tier, rows] of Object.entries(matrices)) {
  const off = rows.find((r) => r.key === 'thinkingOff');
  const judge = rows.find((r) => r.key === 'judgeLike');
  const onObj = rows.find((r) => r.key === 'thinkingOnObject');
  console.log(`· [${tier}] 关思考 + 对象 tool_choice（名单内路由）：${off?.ok ? '可跑 ✓ 硬约束' : '失败 ✗'}`);
  console.log(`· [${tier}] 不关思考 + auto（名单外路由）：${judge?.ok ? `可跑 ✓ 但**软约束**（思考token=${judge.reasoning}）` : `失败 ✗ ${judge?.code ?? ''} ${judge?.message ?? ''}`}`);
  if (onObj && !onObj.ok) {
    console.log(`  ⚠️ 思考开着时传对象必失败：${onObj.code ?? ''} —— 所以「软约束」不是能省的，是没得选`);
  }
}

const anyOk = results.some((r) => r.ok);
console.log(`\n${anyOk ? '✓ 至少有一个可用模型' : '✗ 没有可用模型 —— 通常是账号侧没开通（不是代码问题）'}`);
process.exit(anyOk ? 0 : 1);
