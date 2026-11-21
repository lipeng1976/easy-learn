#!/usr/bin/env node

/**
 * 按**真实路由**调一次，把**模型原文**摊开看。
 *
 * ## 它填的是哪一层空
 *
 * 已有的两个探针各差一层：
 *
 * | 脚本 | 走真网关 | 真提示词/真 schema | 能看到模型原文 |
 * |---|---|---|---|
 * | `probe-ark.mjs` | ✗ 直接调模型 | ✗ 极简探活 schema | ✗ |
 * | `e2e-local-homework.mjs` | ✓ 真 HTTP | ✓ | ✗ **只给结论** |
 * | **本脚本** | ✓ 真网关（进程内） | ✓ | ✓ |
 *
 * 差的那一层在出错时才显出来：端到端会告诉你「`schema_violation`：tasks 应为数组」，
 * 但**模型到底回了什么**它不显示 —— 而那句话恰恰是唯一能定位问题的信息
 * （是 `tasks` 给成了对象？还是一个字符串？还是压根没调工具、回了散文？）。
 *
 * ## 怎么做到既忠实又能看到原文
 *
 * 不自己拼请求（那就会和网关的真实行为漂），而是**在进程内把真网关跑起来**，
 * 只在最外层的 `fetch` 上套一个「记下来再转发」的壳。
 * 于是提示词、schema、`tool_choice` 的形态、思维链开关、配额与缓存
 * **全部是生产的那一套**，而模型的原始响应被完整留存。
 *
 * ## ⚠️ 缓存必须压掉
 *
 * 网关按 payload 缓存 10 分钟。不压掉的话第二次跑量到的**是缓存不是模型**，
 * 而输出看起来一模一样 —— 一次什么都没测的「成功」。
 * 所以本脚本把 `AI_CACHE_TTL_MS` 压到 1 秒（`intOf` 不收 0，会回落默认值，
 * 所以用 1 而不是 0）。
 *
 * ## 用法
 *
 * ```bash
 * cd serverless/ai-gateway
 * set -a; . ./.env.local; set +a
 *
 * # 视觉路由：直接给一张图
 * node scripts/probe-route.mjs --route=ocr --image=/path/to/homework.png
 *
 * # 推理路由：直接给 JSON 体
 * node scripts/probe-route.mjs --route=judge \
 *   --body='{"studentAnswer":"26","referenceAnswer":"27"}'
 *
 * # 想看同一输入多次的差异（判断是「偶发」还是「稳定跑飞」）
 * node scripts/probe-route.mjs --route=ocr --image=... --repeat=3
 * ```
 *
 * ⚠️ **用短名（`--route=ocr`），不要直接传 `/ai/homework/ocr`。**
 * Git Bash 会把以 `/` 开头的参数改写成 Windows 路径 —— 实测
 * `--path=/ai/homework/ocr` 到了 Node 里变成
 * `--path=C:/Users/.../PortableGit/versions/1.2.0/ai/homework/ocr`
 * （连 `=` 后面那段也一起改），于是报「路由不存在」，看起来像路径写错了。
 * 短名绕开整个问题；`--path=` 只留给非 Git Bash 的场合。
 * 短名可选：`ocr` `check` `judge` `answerOcr` `explain` `practice` `reference`。
 *
 * 退出码：`0` 网关回了 2xx；`1` 网关拒绝了（此时**重点看模型原文那一段**）；
 * `2` 用法或配置有问题。
 */

import { readFile } from 'node:fs/promises';
import { basename } from 'node:path';

import { ArkModelClient } from '../src/ark.js';
import { loadConfig, validateConfig } from '../src/config.js';
import { createGateway } from '../src/handler.js';

// ── 参数 ──────────────────────────────────────────────────────────────────

const argv = process.argv.slice(2);
const optOf = (name) => {
  const hit = argv.find((a) => a.startsWith(`--${name}=`));
  return hit === undefined ? '' : hit.slice(name.length + 3);
};

/**
 * 路由短名 → 真实路径。
 *
 * ⚠️ 为什么要短名而不是让人直接传 `/ai/homework/ocr`：**Git Bash 会把以 `/`
 * 开头的参数改写成 Windows 路径**（实测 `--path=/ai/homework/ocr` 到了 Node 里
 * 变成 `--path=C:/Users/.../PortableGit/versions/1.2.0/ai/homework/ocr`，
 * 连 `=` 后面那段也一起改）。于是「照文档敲一遍」得到的报错是「路由不存在」，
 * 而排查方向会跑到路由名或代码上 —— 真正的原因在 shell 这一层。
 */
const ROUTE_ALIASES = {
  ocr: '/ai/homework/ocr',
  check: '/ai/homework/check',
  judge: '/ai/review/judge',
  answerOcr: '/ai/review/answer-ocr',
  explain: '/ai/review/explain',
  practice: '/ai/review/practice',
  reference: '/ai/review/reference-batch',
};

const routeArg = optOf('route');
const routePath = ROUTE_ALIASES[routeArg] ?? optOf('path');

if (routeArg !== '' && ROUTE_ALIASES[routeArg] === undefined) {
  console.error(`✗ 没有这个短名：${routeArg}`);
  console.error(`  可选：${Object.keys(ROUTE_ALIASES).join(' / ')}`);
  process.exit(2);
}

const repeats = Math.max(1, Number.parseInt(optOf('repeat') || '1', 10) || 1);
const studentId = optOf('student') || 'stu_probe';

if (routePath === '') {
  console.error('用法：node scripts/probe-route.mjs --route=<短名> [--image=<文件>] [--body=<JSON>] [--repeat=N]');
  console.error(`  短名：${Object.keys(ROUTE_ALIASES).join(' / ')}`);
  console.error('例：  node scripts/probe-route.mjs --route=ocr --image=./hw.png');
  process.exit(2);
}

// ⚠️ 见文件头：不压掉缓存，复跑测到的是缓存而不是模型。
process.env.AI_CACHE_TTL_MS = '1';

const config = loadConfig(process.env);
const problems = validateConfig(config);
if (problems.length > 0) {
  console.error('✗ 配置有问题（网关自己也会拒绝启动）：');
  for (const p of problems) console.error(`   · ${p}`);
  process.exit(2);
}

// ── 组装请求体 ────────────────────────────────────────────────────────────

const body = optOf('body') === '' ? {} : JSON.parse(optOf('body'));

const imagePath = optOf('image');
if (imagePath !== '') {
  const bytes = await readFile(imagePath);
  const ext = imagePath.toLowerCase().endsWith('.jpg') || imagePath.toLowerCase().endsWith('.jpeg')
    ? 'image/jpeg'
    : 'image/png';
  body.images = [{ base64: bytes.toString('base64'), mimeType: ext }];
  body.fileName = basename(imagePath);
}

// ── 真网关 + 记录原文的壳 ─────────────────────────────────────────────────

const captured = [];
const model = new ArkModelClient({
  config,
  fetchImpl: async (url, init) => {
    const res = await fetch(url, init);
    // 只读一次：拿完文本再把它包成一个同形的假响应交回给客户端。
    // （真响应体的 body 只能消费一次，直接传下去就没法打印了。）
    const text = await res.text();
    captured.push({
      url,
      request: JSON.parse(init.body),
      status: res.status,
      text,
    });
    return { ok: res.ok, status: res.status, text: async () => text };
  },
});

const gateway = createGateway({ config, model, onAudit: () => {} });

console.log('端到端路由探针');
console.log(`  路径      ${routePath}`);
console.log(`  厂商      ${config.modelProvider}（${config.modelProviderSpec?.label ?? '未知'}）`);
console.log(`  数据面    ${config.ark.baseUrl}`);
console.log(`  模型档    vision=${config.ark.models.vision || '(空)'} · reasoning=${config.ark.models.reasoning || '(空)'}`);
console.log(`  关思维链  ${config.ark.thinkingDisabledKinds.length === 0 ? '(不关)' : config.ark.thinkingDisabledKinds.join(',')}`);
if (imagePath !== '') {
  const kb = (Buffer.byteLength(body.images[0].base64, 'base64') / 1024).toFixed(0);
  console.log(`  图片      ${basename(imagePath)}（${kb} KB）`);
}
console.log('');

let lastStatus = 0;

for (let attempt = 1; attempt <= repeats; attempt += 1) {
  captured.length = 0;
  if (repeats > 1) console.log(`──────── 第 ${attempt}/${repeats} 次 ────────`);

  const started = Date.now();
  const response = await gateway.handle({
    method: 'POST',
    path: routePath,
    query: {},
    headers: { 'x-student-id': studentId, 'x-device-id': 'probe' },
    body,
  });
  const elapsed = Date.now() - started;
  lastStatus = response.status;

  // ── ① 模型原文（本脚本存在的理由）────────────────────────────────────
  for (const call of captured) {
    console.log('【模型原文】← 网关只报「不符合结构」时，原文在这里');
    console.log(`  HTTP ${call.status}  ${call.url}`);
    const shape = call.request;
    console.log(`  请求侧：model=${shape.model} tool_choice=${JSON.stringify(shape.tool_choice)}`
      + ` ${Object.keys(shape).filter((k) => k.startsWith('enable_thinking') || k === 'thinking').map((k) => `${k}=${JSON.stringify(shape[k])}`).join(' ')}`);

    let payload = null;
    try {
      payload = JSON.parse(call.text);
    } catch {
      console.log(`  ⚠️ 响应不是 JSON：${call.text.slice(0, 300)}`);
      continue;
    }
    if (payload.error) {
      console.log(`  ✗ 对方报错：${payload.error.code ?? ''} ${String(payload.error.message ?? '').slice(0, 300)}`);
      continue;
    }
    const choice = (payload.choices ?? [])[0] ?? {};
    const toolCall = (choice.message?.tool_calls ?? [])[0];
    console.log(`  finish_reason = ${choice.finish_reason ?? '(无)'}`);

    if (toolCall !== undefined) {
      const raw = toolCall.function?.arguments ?? '';
      console.log('  tool_calls[0].function.arguments：');
      // 原样打印，**不做美化排序** —— 顺序本身有时就是线索。
      console.log(`    ${String(raw).slice(0, 4000)}`);
    } else {
      console.log('  ⚠️ **模型没有调用工具**，回的是普通内容：');
      console.log(`    ${String(choice.message?.content ?? '').slice(0, 1500)}`);
    }
    if (payload.usage) console.log(`  usage = ${JSON.stringify(payload.usage)}`);
    console.log('');
  }

  // ── ② 网关判定 ─────────────────────────────────────────────────────────
  const isJson = String(response.headers['Content-Type']).includes('json');
  let parsed = null;
  if (isJson && response.body !== '') {
    try {
      parsed = JSON.parse(response.body);
    } catch {
      parsed = null;
    }
  }
  console.log(`【网关判定】HTTP ${response.status}  ${elapsed}ms`);
  console.log(`  ${JSON.stringify(parsed ?? response.body).slice(0, 1200)}`);
  console.log('');
}

process.exit(lastStatus >= 200 && lastStatus < 300 ? 0 : 1);
