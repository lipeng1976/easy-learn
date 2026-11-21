import assert from 'node:assert/strict';
import test from 'node:test';

import { normalizeFigureResult } from '../src/handlers.js';

/**
 * 讲解配图的归一化。
 *
 * 这里盯的是一件事：**「不画」有三种来源，响应里必须能分开**。
 *
 * · `model_declined` —— 模型判断这题不该画（六成初一代数题就是这种）
 * · `figure_invalid` —— 模型画了，但图对不上，整张丢掉
 * · `draw=true` —— 带图走
 *
 * 三种在界面上都是「没有图」，但只有第二种说明**配图质量在下降**。
 * 把第二种混进第一种，看板上一片安静，而学生那边已经很久没见到图了。
 */

/** 2026-10-23 实测的真实模型输出（L 形面积题），原样当夹具。 */
const L_SHAPE = {
  type: 'polygon',
  points: [
    { name: 'A', x: -3, y: 0 },
    { name: 'B', x: -3, y: 3 },
    { name: 'C', x: 0, y: 3 },
    { name: 'D', x: 0, y: 1 },
    { name: 'E', x: 2, y: 1 },
    { name: 'F', x: 2, y: 0 },
  ],
  polygons: [['A', 'B', 'C', 'D', 'E', 'F']],
  dims: [
    { from: { x: -3.5, y: 0 }, to: { x: -3.5, y: 3 }, text: 'm' },
    { from: { x: -3, y: -0.5 }, to: { x: 2, y: -0.5 }, text: 'n' },
  ],
};

test('模型说不用画：原样保留它的理由，不套兜底文案', () => {
  const out = normalizeFigureResult({
    draw: false,
    reason: '纯符号运算，画图看不出新东西。',
  });

  assert.equal(out.draw, false);
  assert.equal(out.reason, '纯符号运算，画图看不出新东西。');
  assert.equal(out.rejected, 'model_declined');
});

test('模型说不用画但没给理由：给一句能读的兜底', () => {
  const out = normalizeFigureResult({ draw: false });
  assert.equal(out.draw, false);
  assert.ok(out.reason.length > 0);
});

test('draw=true + 合法图：图经过 normalizeFigure，别名归一成 plane', () => {
  const out = normalizeFigureResult({
    draw: true,
    reason: '看这条分割线',
    caption: '两种切法',
    figure: L_SHAPE,
  });

  assert.equal(out.draw, true);
  assert.ok(out.figure);
  assert.equal(out.figure.type, 'plane');
  assert.equal(out.figure.points.length, 6);
  assert.equal(out.caption, '两种切法');
});

test('draw=true 但图作废 ⇒ 退回不画，且标记 figure_invalid', () => {
  // 引用了不存在的点 Z —— normalizeFigure 会整张丢掉。
  const out = normalizeFigureResult({
    draw: true,
    reason: '画好了',
    figure: { ...L_SHAPE, polygons: [['A', 'B', 'Z']] },
  });

  assert.equal(out.draw, false);
  assert.equal(out.rejected, 'figure_invalid');
  // 给学生看的那句话**不能带内部术语**：学生不知道「尺寸线」是什么。
  assert.ok(!out.reason.includes('尺寸线'), `人话文案里出现了内部术语：${out.reason}`);
  assert.ok(!out.reason.includes('polygons'), `人话文案里出现了字段名：${out.reason}`);
  // 但内部原因要留着，方便排查配图质量。
  assert.ok(typeof out.detail === 'string' && out.detail.length > 0);
});

test('draw=true 却没给 figure ⇒ 同样算 figure_invalid，不是「没画」', () => {
  const out = normalizeFigureResult({ draw: true, reason: '画好了' });
  assert.equal(out.draw, false);
  assert.equal(out.rejected, 'figure_invalid');
});

test('draw 缺失 / 不是布尔 ⇒ 按「不画」处理（schema 已挡住，这里是第二道闸）', () => {
  for (const raw of [{}, { draw: 'true' }, null, undefined, 'nope']) {
    const out = normalizeFigureResult(raw);
    assert.equal(out.draw, false, `输入 ${JSON.stringify(raw)} 不该产出图`);
    assert.equal(out.rejected, 'model_declined');
  }
});
