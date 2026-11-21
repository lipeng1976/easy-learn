#!/usr/bin/env node
/**
 * 讲解配图端到端探针：真 HTTP + 真模型，看返回的图能不能信。
 *
 * 单测证明的是「解析与归一化的逻辑对」；这里证明的是**模型真的会画**，
 * 而且画出来的东西对得上题。两者缺一不可 —— 归一化测试可以全绿，
 * 而模型每次给的坐标都是乱的，那功能在用户那儿等于不存在。
 *
 * ## 判据
 *
 * 1. 纯符号运算（幂的运算）⇒ `draw=false` —— 不该硬画
 * 2. 题干里没有图形信息的面积题 ⇒ `draw=false` —— 画不出来就别画
 * 3. 数轴两点距离 ⇒ `draw=true`，且**两个解都要有点**（这是这道题的
 *    全部教学价值：距离为 2 的点有两个）
 * 4. 返回的 figure 必须带 type/points，且点都在 [-5,5]×[-4,4] 里
 *
 * ## 用法
 *
 *   node scripts/probe-review-figure.mjs --env-file "D:/easy_learn_home/config/ai.env"
 *
 * 需要网关已启动（默认 `http://127.0.0.1:8787`，可用 `PROBE_BASE` 改）。
 */
import { readFileSync, writeFileSync } from 'node:fs';

import { issueSessionToken } from '../src/auth.js';

const BASE = (process.env.PROBE_BASE ?? 'http://127.0.0.1:8787').replace(/\/+$/, '');

function parseArgs(argv) {
  const out = { envFile: '', out: '' };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--env-file') out.envFile = argv[++i] ?? '';
    else if (argv[i] === '--out') out.out = argv[++i] ?? '';
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
if (!args.envFile) {
  console.error('缺少 --env-file');
  process.exit(2);
}

const env = Object.fromEntries(
  readFileSync(args.envFile, 'utf8')
    .split(/\r?\n/)
    .map((line) => /^([A-Z0-9_]+)=(.*)$/.exec(line.trim()))
    .filter(Boolean)
    .map((m) => [m[1], m[2].trim()]),
);

const secret = env.AI_SESSION_SECRET ?? '';
if (secret.length < 32) {
  console.error('AI_SESSION_SECRET 缺失或太短');
  process.exit(2);
}

const token = issueSessionToken({ secret, studentId: 'stu_probe_figure', ttlSeconds: 3600 });

/** 夹具全部来自本机真实错题库（`review_mistake`），不是编的题。 */
const CASES = [
  {
    name: '数轴·两点距离（必须给出两个解）',
    expectDraw: true,
    expect: (fig) => {
      const xs = fig.points.map((p) => p.x);
      // 两个点在同一侧、或只有一个点，都是这道题上最典型的错图。
      const hasLeft = xs.some((x) => x < 0);
      const hasRight = xs.some((x) => x > 0);
      if (!hasLeft || !hasRight) return `左右两侧都要有点，实际 x=${xs.join(',')}`;
      return null;
    },
    body: {
      subject: '数学',
      knowledgePoint: '数轴上两点间的距离',
      questionBody: '(2) 数轴上的点 C 与点 B 的距离为 2 个单位长度，那么点 C 表示的数为______',
    },
  },
  {
    name: '组合图形面积（题干里没有图）',
    expectDraw: false,
    body: {
      subject: '数学',
      knowledgePoint: '组合图形面积计算',
      questionBody: '10. 用不同的方法表示下图的面积(至少写出两种).',
    },
  },
  {
    name: '幂的运算（纯符号，画图没有意义）',
    expectDraw: false,
    body: {
      subject: '数学',
      knowledgePoint: '幂的运算',
      questionBody: '计算 $(-0.25)^{2024} \\times (-4)^{2024} =$ ______',
    },
  },
];

let pass = 0;
const failures = [];
const captured = [];

function check(label, ok, detail = '') {
  if (ok) {
    pass += 1;
    console.log(`  ✓ ${label}`);
  } else {
    failures.push(`${label}${detail ? `：${detail}` : ''}`);
    console.log(`  ✗ ${label}${detail ? ` —— ${detail}` : ''}`);
  }
}

for (const item of CASES) {
  console.log(`\n=== ${item.name} ===`);
  const started = Date.now();
  let response;
  let data;
  try {
    response = await fetch(`${BASE}/ai/review/figure`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify(item.body),
    });
    data = await response.json();
  } catch (error) {
    check('请求成功', false, String(error));
    continue;
  }
  const ms = Date.now() - started;

  if (!response.ok) {
    check('HTTP 200', false, `${response.status} ${JSON.stringify(data).slice(0, 300)}`);
    continue;
  }

  check('HTTP 200', true);
  // 网关把结果包在 data 里（与其它端点同构）。
  const result = data.data ?? data;
  console.log(`  ${ms}ms  cached=${data.meta?.cached ?? '?'}  draw=${result.draw}`);
  console.log(`  reason: ${result.reason ?? '(空)'}`);
  if (result.caption) console.log(`  caption: ${result.caption}`);

  check(
    `draw === ${item.expectDraw}`,
    result.draw === item.expectDraw,
    `实际 ${result.draw}`,
  );

  if (result.draw === true) {
    const fig = result.figure;
    check('返回了 figure', Boolean(fig), 'draw=true 却没有 figure');
    if (fig) {
      check('type 是 plane / coord', fig.type === 'plane' || fig.type === 'coord', fig.type);
      check('至少两个点', Array.isArray(fig.points) && fig.points.length >= 2);
      const outOfRange = (fig.points ?? []).filter(
        (p) => Math.abs(p.x) > 5.5 || Math.abs(p.y) > 4.5,
      );
      check('坐标没越界', outOfRange.length === 0, `越界 ${outOfRange.length} 个`);
      if (item.expect) {
        const problem = item.expect(fig);
        check('图形内容符合这道题', problem === null, problem ?? '');
      }
      captured.push({ name: item.name, figure: fig, caption: result.caption ?? '' });
    }
  }

  // 延迟也要记：客户端给的是 30s 窗口，超过就必须调。
  if (ms > 25_000) {
    check('延迟在客户端窗口内（<25s）', false, `${ms}ms`);
  }
}

if (args.out && captured.length > 0) {
  writeFileSync(args.out, JSON.stringify(captured, null, 2), 'utf8');
  console.log(`\n图已存到 ${args.out}（${captured.length} 张）`);
}

console.log(`\n通过 ${pass} 项，失败 ${failures.length} 项`);
if (failures.length > 0) {
  for (const f of failures) console.log(`  · ${f}`);
  process.exit(1);
}
