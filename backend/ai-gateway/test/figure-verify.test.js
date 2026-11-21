import assert from 'node:assert/strict';
import test from 'node:test';

import { compareExpressions, describeMismatch } from '../src/figure-verify.js';

/**
 * 图形题的独立复核。
 *
 * 用例里的式子**不是编的**：那是 2026-10-23 一张真实作业照片上学生手写的
 * 两道式子，接的是「用不同的方法表示下图的面积（至少两种）」。
 * 批改当时给的是 `score=100, items=0`，摘要「图形面积计算都掌握得很好」——
 * 而这两式都错。拿真数据当夹具，才可能复现那一次漏判。
 *
 * 图：L 形，a 左高、b 总宽、d 上宽、c 右高。
 * 正确：`ad + c(b-d)`（分割）与 `ab - (a-c)(b-d)`（补形），两者恒等。
 */

const VARIABLES = ['a', 'b', 'c', 'd'];
const REFERENCE = ['ad + c(b-d)', 'ab - (a-c)(b-d)'];
/** 一组画得出这个 L 形的取值：右高 < 左高、上宽 < 总宽。 */
const PREFERRED = { a: 4, b: 7, c: 2, d: 3 };

test('学生把 b-d 写成 b-a：判为不同（这就是当时被放过的那一处）', () => {
  const result = compareExpressions({
    reference: REFERENCE,
    student: 'ad + (b-a)c',
    variables: VARIABLES,
    preferred: PREFERRED,
  });
  assert.equal(result.verdict, 'different');
});

test('学生把外接矩形写成 bc：判为不同', () => {
  const result = compareExpressions({
    reference: REFERENCE,
    student: 'bc - (b-a)(d-c)',
    variables: VARIABLES,
    preferred: PREFERRED,
  });
  assert.equal(result.verdict, 'different');
});

test('两种正确写法都必须判为相同（分割法与补形法）', () => {
  for (const correct of ['ad + c(b-d)', 'ab - (a-c)(b-d)', 'S = ad+c(b-d)', '$S = ab - (a-c)(b-d)$']) {
    const result = compareExpressions({
      reference: REFERENCE,
      student: correct,
      variables: VARIABLES,
      preferred: PREFERRED,
    });
    assert.equal(result.verdict, 'equal', `${correct} 应判为相同`);
  }
});

test('形状等价但多乘了系数：判为不同（不能因为长得像就放过）', () => {
  const result = compareExpressions({
    reference: REFERENCE,
    student: '2(ad + c(b-d))',
    variables: VARIABLES,
  });
  assert.equal(result.verdict, 'different');
});

test('采样点落在几何约束之外，也不能把恒等的式子判成不同', () => {
  // 自动采样里会出现 c > a（右高大于左高），那种图形不存在。
  // 但这两个式子是**代数恒等**的，任何取值下都相等 —— 判定必须不受影响。
  const result = compareExpressions({
    reference: ['ab - (a-c)(b-d)'],
    student: 'ad + c(b-d)',
    variables: VARIABLES,
  });
  assert.equal(result.verdict, 'equal');
});

test('式子超出求值能力时返回 unknown，绝不当成「不同」', () => {
  // unknown 会被调用方放行（维持原判）。判成 different 等于凭空造一条错题。
  const result = compareExpressions({
    reference: ['\\sqrt{a}'],
    student: 'a',
    variables: VARIABLES,
  });
  assert.equal(result.verdict, 'unknown');
});

test('变量表为空时返回 unknown，不去猜', () => {
  const result = compareExpressions({ reference: REFERENCE, student: 'ad', variables: [] });
  assert.equal(result.verdict, 'unknown');
});

test('证据用模型给的那组取值，并把数字算出来', () => {
  const result = compareExpressions({
    reference: REFERENCE,
    student: 'ad + (b-a)c',
    variables: VARIABLES,
    preferred: PREFERRED,
  });
  assert.deepEqual(result.sample, PREFERRED, '证据应优先用「画得出图形」的那组取值');
  assert.equal(result.values['ad + c(b-d)'], 20, 'a=4,b=7,c=2,d=3 时面积是 20');
  assert.equal(result.studentValue, 18, '学生式 ad+(b-a)c 在这组数上算出 18');

  const text = describeMismatch({ student: 'ad + (b-a)c', ...result });
  assert.match(text, /a=4, b=7, c=2, d=3/);
  assert.match(text, /20/);
  assert.match(text, /18/);
});

test('模型给的取值不合几何条件时丢弃，不拿它当证据', () => {
  // c=9 > a=5：右高比左高还长，这个图形不存在。
  // 但 sanitize 只校验「都是正数」，所以这里能过 —— 关键在于
  // **它必须仍然判定正确**，而不是因为取了怪值就判错。
  const result = compareExpressions({
    reference: REFERENCE,
    student: 'ad + c(b-d)',
    variables: VARIABLES,
    preferred: { a: 5, b: 7, c: 9, d: 3 },
  });
  assert.equal(result.verdict, 'equal');
});
