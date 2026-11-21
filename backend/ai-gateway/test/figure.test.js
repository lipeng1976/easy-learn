import assert from 'node:assert/strict';
import test from 'node:test';

import { evaluateExpression, extractExpressions } from '../src/algebra.js';
import { normalizeFigure, verifyFigureAnswer } from '../src/figure.js';

/**
 * 图形 DSL 与答案验算。
 *
 * 用例里的图**不是编的**：`L_SHAPE` 是 2026-10-23 用 qwen3.5-omni-plus 读一张
 * 真实的 L 形面积题照片、再让它出变式题时它自己输出的结果，原样抄下来。
 * 用真数据当夹具才有意义 —— 手写的漂亮 JSON 永远能通过任何校验。
 */

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
    { from: { x: -3, y: 3.5 }, to: { x: 0, y: 3.5 }, text: 'p' },
    { from: { x: 2.5, y: 0 }, to: { x: 2.5, y: 1 }, text: 'q' },
  ],
  labels: [],
  marks: [],
  vars: { m: 3, p: 3, n: 5, q: 1 },
};

const STEM = '请用至少两种不同的代数式表示该图形的面积。';

test('真的模型输出能通过校验，点、边、标注一个不少', () => {
  const { figure, rejected } = normalizeFigure(L_SHAPE);
  assert.equal(rejected.length, 0, `不应有丢弃原因：${rejected.join('；')}`);
  assert.ok(figure);
  assert.equal(figure.points.length, 6);
  assert.equal(figure.polygons.length, 1);
  assert.equal(figure.dims.length, 4);
  assert.deepEqual(figure.vars, { m: 3, p: 3, n: 5, q: 1 });
});

test('「polygon」这类别名认得出来，未知类型整张丢', () => {
  assert.equal(normalizeFigure(L_SHAPE).figure.type, 'plane');
  const bad = normalizeFigure({ ...L_SHAPE, type: 'svg' });
  assert.equal(bad.figure, null);
  assert.match(bad.rejected.join('；'), /未知的图形类型/);
});

test('引用了不存在的点 —— 整张图作废，不是跳过那一条', () => {
  const { figure, rejected } = normalizeFigure({
    ...L_SHAPE,
    polygons: [['A', 'B', 'C', 'D', 'E', 'F'], ['A', 'B', 'Z']],
  });
  assert.equal(figure, null);
  assert.match(rejected.join('；'), /不存在的点：Z/);
});

test('尺寸线长度与任何一条边都对不上 ⇒ 作废', () => {
  const { figure, rejected } = normalizeFigure({
    ...L_SHAPE,
    dims: [{ from: { x: -6, y: -6 }, to: { x: -6, y: 1 }, text: 'x' }],
  });
  assert.equal(figure, null);
  assert.match(rejected.join('；'), /长度 .* 与任何一条边都对不上/);
});

test('同一个值既进 dims 又进 labels ⇒ 只留 dims，不画两遍', () => {
  const { figure } = normalizeFigure({
    ...L_SHAPE,
    labels: [
      { text: 'm', x: -4, y: 1.5 },
      { text: '50°', x: 0, y: 3.2 },
    ],
  });
  assert.ok(figure);
  assert.deepEqual(
    figure.labels.map((label) => label.text),
    ['50°'],
    'm 已经由尺寸线标出，不该再出现一个文字',
  );
});

test('像素坐标（越界）⇒ 作废，不夹紧', () => {
  const { figure, rejected } = normalizeFigure({
    ...L_SHAPE,
    points: L_SHAPE.points.map((point) => ({ ...point, x: point.x * 100 })),
  });
  assert.equal(figure, null);
  assert.match(rejected.join('；'), /坐标缺失或越界/);
});

test('只有点没有边 ⇒ 不画', () => {
  const { figure, rejected } = normalizeFigure({
    type: 'plane',
    points: L_SHAPE.points,
    polygons: [],
    segments: [],
  });
  assert.equal(figure, null);
  assert.match(rejected.join('；'), /没有任何边/);
});

/**
 * 这条是整个功能的底线：**模型算错的答案必须被拦下**。
 *
 * 左边那个 `nq` 是真事 —— 模型把 `nm` 写成了 `nq`，代入它自己给的标注值
 * 算出 1，而图形真实面积是 11。如果这道题原样发给学生，学生做对了会被判错。
 */
test('答案里有一处算错 ⇒ 判 false（探针里的真实错误）', () => {
  const { figure } = normalizeFigure(L_SHAPE);
  const result = verifyFigureAnswer({
    figure,
    stem: STEM,
    answer: '方法一：S = mp + (n-p)q；方法二：S = nq - (m-q)(n-p)',
  });
  assert.equal(result.verdict, false, result.reason);
  assert.match(result.reason, /算出 1/);
});

test('两种写法都正确 ⇒ 判 true', () => {
  const { figure } = normalizeFigure(L_SHAPE);
  const result = verifyFigureAnswer({
    figure,
    stem: STEM,
    answer: 'S = mp + (n-p)q；S = nm - (n-p)(m-q)',
  });
  assert.equal(result.verdict, true, result.reason);
});

test('比例坐标（6×4 表示 60×40）按比例还原，不误判', () => {
  const { figure } = normalizeFigure({
    type: 'plane',
    points: [
      { name: 'A', x: 0, y: 0 },
      { name: 'B', x: 6, y: 0 },
      { name: 'C', x: 6, y: 4 },
      { name: 'D', x: 0, y: 4 },
    ],
    polygons: [['A', 'B', 'C', 'D']],
    dims: [
      { from: { x: 0, y: -0.5 }, to: { x: 6, y: -0.5 }, text: '60m' },
      { from: { x: 6.5, y: 0 }, to: { x: 6.5, y: 4 }, text: '40m' },
    ],
  });
  assert.ok(figure);

  assert.equal(
    verifyFigureAnswer({ figure, stem: '这块场地的面积是多少', answer: '2400' }).verdict,
    true,
    '按比例还原后应是 2400，不能拿坐标面积 24 去判',
  );
  assert.equal(
    verifyFigureAnswer({ figure, stem: '这块场地的面积是多少', answer: '24' }).verdict,
    false,
  );
});

test('标注比例自相矛盾 ⇒ 验不了，判 null 而不是 true', () => {
  const { figure } = normalizeFigure({
    ...L_SHAPE,
    dims: [
      { from: { x: -3.5, y: 0 }, to: { x: -3.5, y: 3 }, text: '3' },
      { from: { x: -3, y: -0.5 }, to: { x: 2, y: -0.5 }, text: '99' },
    ],
  });
  assert.ok(figure);
  const result = verifyFigureAnswer({ figure, stem: STEM, answer: 'S = mp + (n-p)q' });
  assert.equal(result.verdict, null, '没有可信比例时不能声称验过');
});

test('题干不问面积周长 ⇒ 不验（null 不等于通过）', () => {
  const { figure } = normalizeFigure(L_SHAPE);
  const result = verifyFigureAnswer({ figure, stem: '求证 AD 平分 BC', answer: 'S = 11' });
  assert.equal(result.verdict, null);
});

test('隐式乘法：mp、(b-a)c、2ab 都要算得出', () => {
  const vars = { m: 3, p: 3, n: 5, q: 1, a: 2, b: 5, c: 4, d: 3 };
  assert.equal(evaluateExpression('mp', vars), 9);
  assert.equal(evaluateExpression('(b-a)c', vars), 12);
  assert.equal(evaluateExpression('2ab', vars), 20);
  assert.equal(evaluateExpression('bc - (b-a)(d-c)', vars), 23);
});

test('认不出的符号一律 null，不猜', () => {
  assert.equal(evaluateExpression('m*z', { m: 3 }), null);
  assert.equal(evaluateExpression('$$$', {}), null);
  assert.equal(evaluateExpression('m/(n-n)', { m: 3, n: 5 }), null);
  assert.equal(evaluateExpression('', {}), null);
});

test('参考答案里抽出多个表达式，最后一个等号才算赋值', () => {
  assert.deepEqual(
    extractExpressions('方法一：S = mp + (n-p)q；方法二：S = nq - (m-q)(n-p)'),
    ['mp+(n-p)q', 'nq-(m-q)(n-p)'],
  );
  assert.deepEqual(extractExpressions('40'), ['40']);
  assert.deepEqual(extractExpressions('S = 3/4'), ['3/4']);
});

/**
 * 提示词要求式子用 `$...$` 包起来，所以答案几乎总是带 LaTeX。
 * 不剥掉 `$` 的话每个表达式都解析失败 ⇒ `verdict: null` ⇒ **静默放行**。
 */
test('带 $...$ 的答案能抽出表达式（否则验算形同虚设）', () => {
  assert.deepEqual(
    extractExpressions('$S = ad + (b - a)c$；$S = bc - (b - a)(d - c)$'),
    ['ad+(b-a)c', 'bc-(b-a)(d-c)'],
  );
  assert.deepEqual(extractExpressions('$\\frac{3}{4}$'), ['(3)/(4)']);
  assert.deepEqual(extractExpressions('$2 \\times 3$'), ['2*3']);
});

/**
 * 这条是端到端漏检的复现：真实模型给的 LaTeX 答案明明算不平，
 * 却因为 `$` 解析失败被当成「验不了」而保留下来。
 */
test('LaTeX 包裹的错答案必须被判 false，不能被当成验不了', () => {
  const { figure } = normalizeFigure({
    ...L_SHAPE,
    // 模型实际给的坐标与标注值
    points: [
      { name: 'A', x: 0, y: 0 },
      { name: 'B', x: 5, y: 0 },
      { name: 'C', x: 5, y: 2 },
      { name: 'D', x: 3, y: 2 },
      { name: 'E', x: 3, y: 4 },
      { name: 'F', x: 0, y: 4 },
    ],
    polygons: [['A', 'B', 'C', 'D', 'E', 'F']],
    dims: [
      { from: { x: 0, y: 4.3 }, to: { x: 3, y: 4.3 }, text: 'd' },
      { from: { x: -0.3, y: 0 }, to: { x: -0.3, y: 4 }, text: 'a' },
      { from: { x: 0, y: -0.3 }, to: { x: 5, y: -0.3 }, text: 'b' },
      { from: { x: 5.3, y: 0 }, to: { x: 5.3, y: 2 }, text: 'c' },
    ],
    vars: [
      { name: 'a', value: 4 },
      { name: 'b', value: 5 },
      { name: 'c', value: 2 },
      { name: 'd', value: 3 },
    ],
  });
  assert.ok(figure, '这张图本身是自洽的，应该保留');

  const result = verifyFigureAnswer({
    figure,
    stem: '用不同的方法表示下图的面积（至少写出两种）。',
    answer: '$S = ad + (b - a)c$；$S = bc - (b - a)(d - c)$',
  });
  assert.equal(result.verdict, false, result.reason);
  assert.match(result.reason, /算出 14/);
});
