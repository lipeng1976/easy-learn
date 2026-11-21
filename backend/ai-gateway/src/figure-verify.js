/**
 * 图形题的**独立复核** —— 当模型说「这道图形题做对了」时，再算一遍。
 *
 * ## 为什么需要它
 *
 * 实测（2026-10-23）：学法 P51 第 10 题「用不同的方法表示下图的面积」，
 * 学生写 `S = ad + (b-a)c` 与 `S = bc - (b-a)(d-c)`，两式都错
 * （正确是 `ad + c(b-d)` 与 `ab - (a-c)(b-d)`；代 a=4,b=7,c=2,d=3
 * 真实面积 20，学生两式得 18 和 11）。
 *
 * 批改给的是 `score=100, items=0`，摘要「图形面积计算都掌握得很好」，
 * 改标题破缓存**重跑两次仍然 100/0**。
 *
 * 而同一个模型单独转录这两行式子是一字不差的 —— 它**看得见，只是没去算**。
 *
 * 所以复核不能只靠「再问一次模型」：那只是把同一个不确定性抛一次硬币。
 * 这里的做法是让模型给出式子，**由程序代入数值算**。
 *
 * ## 为什么只用来「否决」，不用来「定罪」
 *
 * 本模块的 `different` 只作为**加强证据**：模型说对、但程序在全部采样点上都
 * 算出不等，才改判为错。反过来（模型说错、程序说相等）不改判 ——
 * 图形题里存在「写法等价但依赖几何约束」的情况（绝对值、分段、单位换算），
 * 采样不一定覆盖到。宁可少抓一条，也不能把做对的题判错。
 */

import { evaluateExpression } from './algebra.js';

/**
 * 采样几组。
 *
 * 5 组够不够？对「代数式是否恒等」这类题，两个不同的多项式在随机点上
 * 同时相等的概率极低（Schwartz–Zippel），5 组已经足够；
 * 而每组要算 2-4 个表达式，再多就只是白花 CPU。
 */
const SAMPLE_COUNT = 9;

/**
 * 生成采样值。
 *
 * 刻意取 **2..9 的整数**：
 * - 避开 0 —— `a` 与 `2a` 在 0 处相等，会把错的式子算成对的；
 * - 避开 1 —— `a` 与 `a^2` 在 1 处相等，同样会放过；
 * - 用整数是为了让 `reason` 里的数字能被人一眼看懂
 *   （「取 a=4,b=7,c=2,d=3 时得 18，实际 20」比小数好读）。
 *
 * 用固定序列而不是 `Math.random()`：判据要可复现。
 * 调试时同样的输入必须得到同样的结论，否则「上一次是红的」毫无意义。
 */
function buildSamples(variables) {
  const sets = [];
  for (let k = 0; k < SAMPLE_COUNT; k += 1) {
    const vars = {};
    variables.forEach((name, index) => {
      // 每个变量错开一位，避免所有变量取到同一个数
      // （那会让 `a+b` 与 `2a` 恰好相等，掩盖错误）。
      vars[name] = 2 + ((k * 3 + index * 2) % 8);
    });
    sets.push(vars);
  }
  return sets;
}

/** 去掉 LaTeX 外壳，只留下能求值的部分。`S = ad + c(b-d)` → `ad + c(b-d)`。 */
function toExpression(source) {
  let text = String(source ?? '').trim();
  if (text === '') return '';
  // `S=...` / `面积=...`：等号左边是标签，不是表达式的一部分。
  const eq = text.indexOf('=');
  if (eq >= 0) text = text.slice(eq + 1);
  return text
    // `\frac{1}{2}` 必须先换成除法：直接删命令会得到 `{1}{2}`，
    // 再删括号就变成 `12` —— 数值差 4 倍且不报错（algebra.js 里栽过同一个坑）。
    .replace(/\\frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}/g, '($1)/($2)')
    .replace(/\$/g, '')
    .replace(/\\left|\\right/g, '')
    .replace(/\\times|\\cdot/g, '*')
    .replace(/\\div/g, '/')
    // 手写体/中文输入法里的符号：全角与数学减号在词法分析器里都不是运算符，
    // 不归一就会解析失败 → 复核放弃 → 该抓的错误继续被放过。
    .replace(/[−–—]/g, '-')
    .replace(/[×·]/g, '*')
    .replace(/÷/g, '/')
    .replace(/（/g, '(')
    .replace(/）/g, ')')
    .replace(/[，。；、]/g, '')
    .trim();
}

/**
 * 判两个式子是否在采样点上等价。
 *
 * @param {object} input
 * @param {string[]} input.reference 参考式（可以有多个，任一成立即算对）
 * @param {string} input.student 学生的式子
 * @param {string[]} input.variables 变量名
 * @param {object} [input.preferred] 模型给的一组「满足图形条件」的取值。
 *   它会被放进采样集，并优先用作展示证据 —— 自动采样的点可能落在
 *   几何约束之外（如右高 c 大于左高 a），算出来的数是正数但图形不存在，
 *   写进错因会让人怀疑「老师算错了」。
 * @returns {{verdict:'equal'|'different'|'unknown', sample:object|null, values:object|null}}
 *   `unknown` = 式子解析不了（语法超出本模块能力），此时**不许**当成不同。
 */
export function compareExpressions({ reference, student, variables, preferred }) {
  const names = (variables ?? []).filter((v) => typeof v === 'string' && v !== '');
  if (names.length === 0) return { verdict: 'unknown', sample: null, values: null };

  const studentExpr = toExpression(student);
  if (studentExpr === '') return { verdict: 'unknown', sample: null, values: null };

  const refs = (reference ?? []).map(toExpression).filter((v) => v !== '');
  if (refs.length === 0) return { verdict: 'unknown', sample: null, values: null };

  const preferredVars = sanitizePreferred(preferred, names);
  const samples = buildSamples(names).slice();
  if (preferredVars !== null) samples.unshift(preferredVars);
  let parsed = false;
  /**
   * 参考式有没有至少算出来过一次。
   *
   * 没有它的时候踩过一个坑：参考式是 `\sqrt{a}` 这类超出求值器能力的东西时，
   * 循环里每个 ref 都被 `continue` 跳过 → `equalCount` 恒为 0 →
   * 得出 `different`。那不是「学生错了」，是**我们算不出来**，
   * 结论会把一个做对的学生塞进错题库 —— 比漏判更糟。
   */
  let refParsed = false;
  let equalCount = 0;
  /** 展示证据用：第一个「参考式算出来是正数」的采样点（见下）。 */
  let positiveEvidence = null;

  for (const vars of samples) {
    const studentValue = evaluateExpression(studentExpr, vars);
    if (studentValue === null) return { verdict: 'unknown', sample: null, values: null };
    parsed = true;

    let matched = false;
    const refValues = {};
    for (const ref of refs) {
      const refValue = evaluateExpression(ref, vars);
      if (refValue === null) continue;
      parsed = true;
      refParsed = true;
      refValues[ref] = refValue;
      if (Math.abs(refValue - studentValue) < 1e-9) matched = true;
    }
    if (matched) equalCount += 1;

    // 证据优先选「结果为正」的点：几何题里 a<c 这类取值会算出负面积，
    // 虽然判得对，但把 -8 写进错因会让学生以为老师算错了。
    if (positiveEvidence === null && Object.values(refValues).every((v) => v > 0)) {
      positiveEvidence = { sample: vars, values: refValues, studentValue };
    }
  }

  if (!parsed || !refParsed) return { verdict: 'unknown', sample: null, values: null };

  /**
   * **多数票**，不是「有一个点相等就算对」。
   *
   * 式子是否恒等，能在任意点验证；但采样点可能落在几何约束之外
   * （如 a<c，图形根本不存在），那里正确式也可能算不出应有结果。
   * 取「一半以上的点相等」既不会因为一个偶然相等的点放过错式子，
   * 也不会因为一个约束外的点把对的式子判错。
   */
  const equal = equalCount * 2 > samples.length;
  if (equal) return { verdict: 'equal', sample: null, values: null };

  if (positiveEvidence !== null) {
    return {
      verdict: 'different',
      sample: positiveEvidence.sample,
      values: positiveEvidence.values,
      studentValue: positiveEvidence.studentValue,
    };
  }
  return { verdict: 'different', sample: samples[0], values: null, studentValue: null };
}

/**
 * 把一条「人类写的式子」求值（先剥掉 `S=` 这类前缀与 LaTeX 外壳）。
 *
 * 暴露出来是为了让调用方能拿**几何面积**去比 —— 那条路不依赖模型给的
 * 参考式，是复核里唯一完全独立的证据。
 */
export function evaluateSource(source, vars) {
  const expr = toExpression(source);
  if (expr === '') return null;
  return evaluateExpression(expr, vars);
}

/**
 * 把比较结果说成人话，塞进 `wrongReason`。
 *
 * 不写「经复核」「等等」这类边想边改的句子：这条文案会原样存进错题库，
 * 家长和学生都会看到（详见批改提示词 6.6 的同一条规矩）。
 */
export function describeMismatch({ student, sample, values, studentValue }) {
  if (!sample) return '';
  const pairs = Object.entries(values ?? {})
    .filter(([, v]) => typeof v === 'number')
    .map(([expr, v]) => `${expr} = ${round(v)}`);
  if (pairs.length === 0) return '';
  const varsText = Object.entries(sample)
    .map(([k, v]) => `${k}=${v}`)
    .join(', ');
  const studentPart = typeof studentValue === 'number'
    ? `学生这个式子算得 ${round(studentValue)}`
    : `学生写的是 ${student}`;
  return `按 ${varsText} 验算：正确结果 ${pairs[0]}，${studentPart}`;
}

/**
 * 用**几何面积**（多边形顶点算出来的）当证据写错因。
 *
 * 比 `describeMismatch` 可靠：那条路的「正确结果」是模型给的代数式，
 * 而模型会把 `ab` 写成 `bc`（2026-10-23 实测：参考式算 16，真实面积 32）。
 * 这里的面积由顶点坐标算，是程序自己算的数。
 */
export function describeAreaMismatch({ student, area, sample, studentValue }) {
  if (typeof area !== 'number' || !Number.isFinite(area) || sample === null) return '';
  const varsText = Object.entries(sample)
    .map(([k, v]) => `${k}=${v}`)
    .join(', ');
  const studentPart = typeof studentValue === 'number'
    ? `学生的式子算出 ${round(studentValue)}`
    : `学生写的是 ${student}`;
  return `按 ${varsText} 算，图形面积是 ${round(area)}；${studentPart}，与图形不符`;
}

function round(value) {
  return Number.isInteger(value) ? String(value) : String(Math.round(value * 1000) / 1000);
}

/**
 * 校验模型给的取值能用。
 *
 * 只接受「每个变量都在、都是有限正数」的完整对象 —— 缺一个变量、
 * 或给了个负数，都不该被当成证据（那组数画不出这个图形）。
 *
 * 导出是为了让调用方能拿它去算**几何面积**：那条路的输入必须干净，
 * 否则算出来的面积比用错的参考式还离谱。
 */
export function positiveVars(raw) {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return null;
  const vars = {};
  for (const [name, value] of Object.entries(raw)) {
    const numeric = Number(value);
    if (!Number.isFinite(numeric) || numeric <= 0) return null;
    vars[name] = numeric;
  }
  return Object.keys(vars).length === 0 ? null : vars;
}

/**
 * 校验模型给的取值能用。
 *
 * 只接受「每个变量都在、都是有限正数」的完整对象 —— 缺一个变量、
 * 或给了个负数，都不该被当成证据（那组数画不出这个图形）。
 */
function sanitizePreferred(raw, names) {
  const vars = positiveVars(raw);
  if (vars === null) return null;
  for (const name of names) {
    if (!Object.hasOwn(vars, name)) return null;
  }
  return vars;
}
