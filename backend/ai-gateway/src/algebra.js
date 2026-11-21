/**
 * 中学写法的表达式求值 —— 只为一件事件存在：**验算模型给的答案**。
 *
 * ## 为什么必须验
 *
 * 实测（2026-10-23）：让视觉模型对着 L 形面积题出一道变式题，图形和题干都对，
 * 答案写成 `S = nq - (m-q)(n-p)`，而正确写法是 `nm - (m-q)(n-p)`。
 * 按它自己给的标注值代入，前者算出 1，后者算出 11 —— 图形真实面积是 11。
 *
 * 这个答案会进 `AiPracticeQuestion.answer`，学生明明做对了，批改时被判错。
 * 一份错的参考答案比没有参考答案更糟，所以**答案必须能被程序验**。
 *
 * ## 为什么要处理隐式乘法
 *
 * 中学写法是 `mp`、`(b-a)c`、`2ab`，不是 `m*p`。直接交给 `new Function` 只会
 * 得到 `NaN` 或 `ReferenceError`，而这里要的正是「算不出来就说算不出来」——
 * 所以解析失败一律返回 null，绝不返回一个猜的值。
 *
 * ## 为什么不用 eval
 *
 * 这段文本来自模型输出，也就是外部输入。`eval` 会把一个能出题的模型
 * 变成能在这台机器上跑任意代码的入口。这里只认数字、字母、四则运算和括号。
 */

const NUMBER = /^\d+(?:\.\d+)?$/;
const IDENT = /^[A-Za-z][A-Za-z0-9_]*$/;
const OPERATORS = new Set(['+', '-', '*', '/', '(', ')']);

/**
 * 把表达式切成 token，并按 `vars` 的键把 `mp` 这类连写拆成 `m * p`。
 *
 * 拆法：优先整串匹配 vars 的键；匹配不上就按单字母拆，且每个字母都必须
 * 在 vars 里 —— 否则说明这一项里有不认识的符号，直接放弃。
 */
function tokenize(source, vars) {
  const raw = [];
  let i = 0;
  while (i < source.length) {
    const ch = source[i];
    if (ch === ' ' || ch === '\t') {
      i += 1;
      continue;
    }
    if (OPERATORS.has(ch)) {
      raw.push({ type: 'op', value: ch });
      i += 1;
      continue;
    }
    if (/[0-9.]/.test(ch)) {
      let j = i;
      while (j < source.length && /[0-9.]/.test(source[j])) j += 1;
      const text = source.slice(i, j);
      if (!NUMBER.test(text)) return null;
      raw.push({ type: 'num', value: Number(text) });
      i = j;
      continue;
    }
    if (/[A-Za-z]/.test(ch)) {
      let j = i;
      while (j < source.length && /[A-Za-z0-9_]/.test(source[j])) j += 1;
      const text = source.slice(i, j);
      if (!IDENT.test(text)) return null;
      const parts = splitIdent(text, vars);
      if (parts === null) return null;
      for (const name of parts) raw.push({ type: 'var', value: name });
      i = j;
      continue;
    }
    return null;
  }
  return insertImplicitMultiply(raw);
}

/** `mp` → ['m','p']；`x1` → ['x1']（整串就是键时优先整串）。 */
function splitIdent(text, vars) {
  if (Object.hasOwn(vars, text)) return [text];
  const parts = [];
  let i = 0;
  while (i < text.length) {
    // 贪心：先试最长匹配，`xy` 里有 `x` 和 `y` 两个键时会拆成两个。
    let matched = '';
    for (let len = Math.min(6, text.length - i); len >= 1; len -= 1) {
      const candidate = text.slice(i, i + len);
      if (Object.hasOwn(vars, candidate)) {
        matched = candidate;
        break;
      }
    }
    if (matched === '') return null;
    parts.push(matched);
    i += matched.length;
  }
  return parts;
}

/** 相邻的两个「值」之间补乘号：`2ab` `(b-a)c` `2(3+x)`。 */
function insertImplicitMultiply(tokens) {
  const out = [];
  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i];
    const prev = out[out.length - 1];
    const prevEndsValue = prev && (prev.type === 'num' || prev.type === 'var' || prev.value === ')');
    const startsValue = token.type === 'num' || token.type === 'var' || token.value === '(';
    if (prevEndsValue && startsValue) out.push({ type: 'op', value: '*' });
    out.push(token);
  }
  return out;
}

/**
 * 求值。任何不确定都返回 `null` —— 调用方据此判定「这道题验不了」，
 * 而不是拿到一个像模像样的数。
 */
export function evaluateExpression(source, vars) {
  if (typeof source !== 'string') return null;
  const text = source.trim();
  if (text === '') return null;
  if (text.length > 120) return null;

  const tokens = tokenize(text, vars);
  if (tokens === null || tokens.length === 0) return null;

  let pos = 0;
  const peek = () => tokens[pos];
  const take = () => tokens[pos++];

  function parseExpression() {
    let left = parseTerm();
    if (left === null) return null;
    while (peek() && (peek().value === '+' || peek().value === '-')) {
      const op = take().value;
      const right = parseTerm();
      if (right === null) return null;
      left = op === '+' ? left + right : left - right;
    }
    return left;
  }

  function parseTerm() {
    let left = parseFactor();
    if (left === null) return null;
    while (peek() && (peek().value === '*' || peek().value === '/')) {
      const op = take().value;
      const right = parseFactor();
      if (right === null) return null;
      if (op === '/' && Math.abs(right) < 1e-12) return null;
      left = op === '*' ? left * right : left / right;
    }
    return left;
  }

  function parseFactor() {
    const token = peek();
    if (!token) return null;
    if (token.value === '-') {
      take();
      const value = parseFactor();
      return value === null ? null : -value;
    }
    if (token.value === '+') {
      take();
      return parseFactor();
    }
    if (token.value === '(') {
      take();
      const value = parseExpression();
      if (value === null) return null;
      if (!peek() || peek().value !== ')') return null;
      take();
      return value;
    }
    if (token.type === 'num') {
      take();
      return token.value;
    }
    if (token.type === 'var') {
      take();
      return vars[token.value];
    }
    return null;
  }

  const value = parseExpression();
  if (value === null || pos !== tokens.length) return null;
  if (!Number.isFinite(value)) return null;
  return value;
}

/**
 * 从「参考答案」里抽出可以验算的表达式。
 *
 * 输入常见形态：
 * - `40`（纯数值）
 * - `S = 40`
 * - `方法一：S = mp + (n-p)q；方法二：S = nq - (m-q)(n-p)`
 * - `$S = ad + (b - a)c$；$S = bc - (b - a)(d - c)$` ← **LaTeX 包裹的**
 *
 * 规则：先按分号和换行切段，每段取**最后一个**等号之后的部分。
 * 取最后一个而不是第一个，是为了跳过 `S =` 这种前缀赋值，同时兼容
 * `面积 = 长 × 宽` 这种双等号的写法。
 *
 * ## 为什么要剥 LaTeX
 *
 * 提示词要求数学式子用 `$...$` 包起来，所以答案里几乎总是带着 `$`。
 * 而 `$` 不是合法字符 —— 不剥掉的话，每个表达式都会解析失败，
 * 于是「一个都验不了」= `verdict: null` = **验算静默失效，错的答案照样放行**。
 * 这不是理论风险：2026-10-23 实测就漏了两道（模型把 `ab` 写成 `bc`，
 * 两道题都被保留了下来）。
 */
export function extractExpressions(answer) {
  if (typeof answer !== 'string' || answer.trim() === '') return [];
  const out = [];
  const segments = answer.split(/[；;\n。]/);
  for (const segment of segments) {
    const text = segment.trim();
    if (text === '') continue;
    const tail = text.includes('=') ? text.slice(text.lastIndexOf('=') + 1) : text;
    const cleaned = tail
      // 分式要先转成带括号的除法再删命令：`\frac{3}{4}` 如果直接按
      // 「删掉反斜杠命令」处理，会剩下 `{3}{4}` → `34`，**64 倍的错**。
      .replace(/\\frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}/g, '($1)/($2)')
      // LaTeX 的数学定界符与命令。先处理命令再处理符号，顺序反了会把
      // `\times` 变成一个孤零零的 `times`（被当成变量，然后解析失败）。
      .replace(/\\times/g, '*')
      .replace(/\\div/g, '/')
      .replace(/\\cdot/g, '*')
      .replace(/\\left|\\right/g, '')
      .replace(/\\[a-zA-Z]+/g, '')
      .replace(/[×]/g, '*')
      .replace(/[÷]/g, '/')
      .replace(/\$/g, '')
      .replace(/[{}（）]/g, '')
      .replace(/[，,]/g, '')
      .replace(/\s+/g, '')
      .replace(/[^\x20-\x7E]/g, '');
    if (cleaned === '') continue;
    out.push(cleaned);
  }
  return out;
}
