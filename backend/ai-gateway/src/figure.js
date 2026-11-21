/**
 * 图形 DSL：模型只描述「点和线」，画由客户端做。
 * ## 为什么不是让模型出图片
 *
 * 图像生成模型画出来的几何图，**线长与标注数字对不上**：图上标着「a」的那条边
 * 可能是任意长度，写着 50° 的角可能是 80°。学生照着这张图推理，会得出一个
 * 建立在错误前提上的结论 —— 而且它看起来完全正常，没有任何报错。
 * 这是本项目最怕的那种错：**静默地错**。
 *
 * 所以图必须由**坐标**生成。坐标是数，长度是算出来的，标注写什么与线画多长
 * 由同一组数决定，画出来就不可能自相矛盾。
 *
 * ## 为什么不直接收 SVG
 *
 * SVG 能表达的东西没有边界（`<script>`、外部引用、任意路径），校验等于没校验；
 * Flutter 端还要引一整个 svg 运行时。这里的封闭集合刻意小：
 * 点、折线、线段、虚线、尺寸标注、自由文字、直角/角弧标记。
 * **画不出来的题就不画**，退回纯文字 —— 半张图比没有图更误导。
 *
 * ## 容差为什么是「长度匹配」而不是「位置匹配」
 *
 * 尺寸标注天然画在边的外侧（平移 0.5~1 格），要求端点落在边上是不合理的；
 * 而长度必须相等 —— 一条标着 `b` 的尺寸线如果长度与任何边都对不上，
 * 那它就不是「标在了哪条边旁边」，而是模型随手画的一条线。这种情况整张图丢掉。
 */

import { evaluateExpression, extractExpressions } from './algebra.js';

/** 坐标绝对值上限。超出说明模型把页面像素坐标当成了图形坐标。 */
const MAX_SPAN = 20;

/** 标注/标签文字长度上限。超过这个长度的不是标注，是一句话。 */
const LABEL_MAX = 16;

/** 尺寸线长度与边长的容差（格）。 */
const DIM_LENGTH_TOLERANCE = 0.8;

const FIGURE_TYPES = new Set(['plane', 'coord']);
const TYPE_ALIASES = new Map([
  ['polygon', 'plane'],
  ['planeGeometry', 'plane'],
  ['geometry', 'plane'],
  ['coordinate', 'coord'],
  ['cartesian', 'coord'],
  ['axes', 'coord'],
]);

/** 只支持这两种标记。等长/平行标记刻意不做：画错的等长标记会直接误导推理。 */
const MARK_KINDS = new Set(['rightAngle', 'arc']);

const MAX_POINTS = 40;
const MAX_EDGES = 60;
const MAX_MARKS = 20;

function finite(value) {
  return typeof value === 'number' && Number.isFinite(value);
}

function readXY(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  if (!finite(raw.x) || !finite(raw.y)) return null;
  if (Math.abs(raw.x) > MAX_SPAN || Math.abs(raw.y) > MAX_SPAN) return null;
  return { x: round3(raw.x), y: round3(raw.y) };
}

function round3(value) {
  return Math.round(value * 1000) / 1000;
}

function distance(a, b) {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

function readText(raw, max = LABEL_MAX) {
  if (typeof raw !== 'string') return '';
  const text = raw.trim();
  if (text === '' || text.length > max) return '';
  return text;
}

/** 多边形面积（鞋带公式）。图形自洽校验与答案验算都靠它。 */
export function polygonArea(points) {
  if (!Array.isArray(points) || points.length < 3) return 0;
  let sum = 0;
  for (let i = 0; i < points.length; i += 1) {
    const a = points[i];
    const b = points[(i + 1) % points.length];
    sum += a.x * b.y - b.x * a.y;
  }
  return Math.abs(sum) / 2;
}

export function polygonPerimeter(points) {
  if (!Array.isArray(points) || points.length < 3) return 0;
  let sum = 0;
  for (let i = 0; i < points.length; i += 1) {
    sum += distance(points[i], points[(i + 1) % points.length]);
  }
  return sum;
}

/**
 * 把模型给的 figure 归一成可信的图。
 *
 * 返回 `{ figure, rejected }`：
 * - `figure` 为 null 表示这张图**不能用**（调用方保留文字题、丢掉图）
 * - `rejected` 是丢弃原因，进审计日志。不能静默 —— 图被丢掉时，
 *   运维只能靠这条记录解释「为什么这道题没图」。
 *
 * 原则是**宁可丢图，不可画错**：任何一处对不上就整张图作废，
 * 不做「过滤掉坏的那条、留下好的那几条」—— 少画一条尺寸线的图，
 * 学生读到的是「这条边没有标注」，那是另一个意思。
 */
export function normalizeFigure(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return { figure: null, rejected: ['figure 不是对象'] };
  }

  const rawType = typeof raw.type === 'string' ? raw.type.trim() : '';
  const type = TYPE_ALIASES.get(rawType) ?? rawType;
  if (!FIGURE_TYPES.has(type)) {
    return { figure: null, rejected: [`未知的图形类型：${rawType || '(空)'}`] };
  }

  const rejected = [];
  const points = readPoints(raw.points, rejected);
  if (points.size < 2) {
    return { figure: null, rejected: [...rejected, '有效点少于 2 个'] };
  }

  const polygons = readShapes(raw.polygons, points, 3, MAX_EDGES, rejected, 'polygons');
  const segments = readShapes(raw.segments, points, 2, MAX_EDGES, rejected, 'segments');
  const dashed = readShapes(raw.dashed, points, 2, MAX_EDGES, rejected, 'dashed');

  if (polygons.length === 0 && segments.length === 0 && type === 'plane') {
    // 只有散点没有线，画出来是一堆孤立的点，不如不画。
    return { figure: null, rejected: [...rejected, '没有任何边'] };
  }

  const edges = [
    ...polygons.flatMap((names) => toEdges(names, true)),
    ...segments.flatMap((names) => toEdges(names, false)),
  ];
  // 尺寸线要与「边长」比对，所以这里先落成坐标。早一步转，
  // 后面就不用到处记「这一串到底是点名还是点」。
  const edgeCoords = edges.map(([a, b]) => [points.get(a), points.get(b)]);
  const dims = readDims(raw.dims, edgeCoords, rejected);
  const marks = readMarks(raw.marks, points, rejected);
  const labels = readLabels(raw.labels, dims, rejected);
  const vars = readVars(raw.vars, rejected);

  if (rejected.length > 0) {
    // 一处坏，整张丢。原因留在 rejected 里，别静默。
    return { figure: null, rejected };
  }

  return {
    figure: {
      type,
      points: [...points.values()],
      polygons,
      segments,
      dashed,
      dims,
      labels,
      marks,
      vars,
    },
    rejected: [],
  };
}

function readPoints(rawPoints, rejected) {
  const map = new Map();
  if (!Array.isArray(rawPoints)) {
    if (rawPoints !== undefined && rawPoints !== null) rejected.push('points 不是数组');
    return map;
  }
  if (rawPoints.length > MAX_POINTS) {
    rejected.push(`点太多：${rawPoints.length}`);
    return map;
  }
  for (const raw of rawPoints) {
    const name = typeof raw?.name === 'string' ? raw.name.trim() : '';
    if (name === '' || name.length > 6) {
      rejected.push(`点名为空或过长：${name || '(空)'}`);
      continue;
    }
    const at = readXY(raw);
    if (at === null) {
      rejected.push(`点 ${name} 的坐标缺失或越界`);
      continue;
    }
    if (map.has(name)) {
      rejected.push(`点重名：${name}`);
      continue;
    }
    map.set(name, { name, x: at.x, y: at.y });
  }
  return map;
}

function readShapes(rawShapes, points, minLen, maxCount, rejected, field) {
  if (rawShapes === undefined || rawShapes === null) return [];
  if (!Array.isArray(rawShapes)) {
    rejected.push(`${field} 不是数组`);
    return [];
  }
  if (rawShapes.length > maxCount) {
    rejected.push(`${field} 太多：${rawShapes.length}`);
    return [];
  }
  const out = [];
  for (const shape of rawShapes) {
    if (!Array.isArray(shape) || shape.length < minLen) {
      rejected.push(`${field} 里有一条少于 ${minLen} 个点`);
      continue;
    }
    const names = [];
    let broken = false;
    for (const name of shape) {
      if (typeof name !== 'string' || !points.has(name)) {
        rejected.push(`${field} 引用了不存在的点：${String(name)}`);
        broken = true;
        break;
      }
      names.push(name);
    }
    if (!broken) out.push(names);
  }
  return out;
}

function toEdges(names, closed) {
  const edges = [];
  const end = closed ? names.length : names.length - 1;
  for (let i = 0; i < end; i += 1) {
    edges.push([names[i], names[(i + 1) % names.length]]);
  }
  return edges;
}

function readDims(rawDims, edges, rejected) {
  if (rawDims === undefined || rawDims === null) return [];
  if (!Array.isArray(rawDims)) {
    rejected.push('dims 不是数组');
    return [];
  }
  const out = [];
  for (const raw of rawDims) {
    const from = readXY(raw?.from);
    const to = readXY(raw?.to);
    const text = readText(raw?.text);
    if (from === null || to === null) {
      rejected.push('尺寸标注的端点坐标缺失或越界');
      continue;
    }
    if (text === '') {
      rejected.push('尺寸标注没有文字');
      continue;
    }
    const length = distance(from, to);
    if (length < 0.2) {
      rejected.push(`尺寸标注长度为 0（${text}）`);
      continue;
    }
    // 一条尺寸线必须「贴着某条边」：长度与该边相等。对不上说明它是随手画的。
    const hasMatch = edges.some(
      ([a, b]) => Math.abs(distance(a, b) - length) <= DIM_LENGTH_TOLERANCE,
    );
    if (!hasMatch) {
      rejected.push(`尺寸标注 ${text} 的长度 ${round3(length)} 与任何一条边都对不上`);
      continue;
    }
    out.push({ from, to, text });
  }
  return out;
}

function readMarks(rawMarks, points, rejected) {
  if (rawMarks === undefined || rawMarks === null) return [];
  if (!Array.isArray(rawMarks)) {
    rejected.push('marks 不是数组');
    return [];
  }
  const out = [];
  for (const raw of rawMarks.slice(0, MAX_MARKS)) {
    const kind = typeof raw?.kind === 'string' ? raw.kind.trim() : '';
    if (!MARK_KINDS.has(kind)) {
      rejected.push(`不支持的标记：${kind || '(空)'}`);
      continue;
    }
    const at = readXY(raw?.at);
    if (at === null) {
      rejected.push('标记位置缺失或越界');
      continue;
    }
    const text = readText(raw?.text, 8);
    out.push({ kind, at, text });
  }
  return out;
}

/**
 * 自由文字。
 *
 * 模型常把同一个值**既放进 dims 又放进 labels**（探针里 `m` 就出现了两次），
 * 那样会画两遍、叠在一起。这里按「同文字 + 距离近」去重：
 * 已经由尺寸线标出来的量，不需要再放一个文字。
 */
function readLabels(rawLabels, dims, rejected) {
  if (rawLabels === undefined || rawLabels === null) return [];
  if (!Array.isArray(rawLabels)) {
    rejected.push('labels 不是数组');
    return [];
  }
  const out = [];
  for (const raw of rawLabels) {
    const text = readText(raw?.text);
    const at = readXY(raw);
    if (text === '' || at === null) {
      rejected.push('标签文字为空或位置越界');
      continue;
    }
    const duplicate = dims.some((dim) => {
      if (dim.text !== text) return false;
      const midX = (dim.from.x + dim.to.x) / 2;
      const midY = (dim.from.y + dim.to.y) / 2;
      return Math.hypot(at.x - midX, at.y - midY) <= 2;
    });
    if (duplicate) continue;
    out.push({ text, x: at.x, y: at.y });
  }
  return out;
}

/**
 * 标注字母 → 数值。
 *
 * 只有答案验算用得到，画图不需要。缺了不丢图，只是这道题做不了验算。
 */
/**
 * 标注字母 → 数值。
 *
 * 只有答案验算用得到，画图不需要。缺了不丢图，只是这道题做不了验算。
 *
 * 收两种形态：契约里给的是 `[{name, value}]`（严格模式的模型对
 * `additionalProperties` 是 schema 的支持不一致，数组最安全），
 * 但模型也常直接给对象 —— 两种都认，别为了格式丢掉能用的信息。
 */
function readVars(rawVars, rejected) {
  if (rawVars === undefined || rawVars === null) return {};

  const out = {};
  const put = (name, value) => {
    const key = String(name ?? '').trim();
    if (key === '' || key.length > 6) return;
    if (!finite(value)) return;
    out[key] = value;
  };

  if (Array.isArray(rawVars)) {
    for (const item of rawVars) {
      if (!item || typeof item !== 'object') continue;
      put(item.name, item.value);
    }
    return out;
  }
  if (typeof rawVars === 'object') {
    for (const [key, value] of Object.entries(rawVars)) put(key, value);
    return out;
  }
  rejected.push('vars 既不是数组也不是对象');
  return {};
}

// ===== 答案验算 =====

/** 从「5cm」「12 厘米」这类标注里取数值。 */
function dimValue(text, vars) {
  if (Object.hasOwn(vars, text)) return vars[text];
  const matched = /^(-?\d+(?:\.\d+)?)/.exec(text);
  return matched ? Number(matched[1]) : null;
}

/**
 * 用图形反算出一个「真实尺寸」，再拿去验算模型给的答案。
 *
 * ## 为什么不能直接用坐标算面积
 *
 * 图上的坐标是**比例坐标**：模型完全可以把一块 60m×40m 的场地画成 6×4。
 * 直接算坐标面积得到 24，而正确答案是 2400，会把自己判成错的。
 *
 * 所以先求**比例系数**：每条尺寸标注的数值 ÷ 它那条边的坐标长度。
 * 所有标注推出来的比例必须一致（差 2% 以内），才认为这张图是等比例的，
 * 面积用 `坐标面积 × 比例²` 还原。有一条对不上就放弃验算 —— 那说明
 * 模型给的数值标注和图形大小自相矛盾，这时候什么都不能信。
 *
 * ## 返回值
 *
 * - `true` —— 验过，答案对
 * - `false` —— 验过，答案错（调用方必须丢掉这道题）
 * - `null` —— 验不了（没有标注、没问面积周长、表达式解析不出）。
 *   注意 `null` **不等于通过**，只是没有证据。不能把「验不了」当成「对」，
 *   那样验算就成了摆设。
 */
export function verifyFigureAnswer({ figure, answer, stem }) {
  if (!figure || !Array.isArray(figure.polygons) || figure.polygons.length === 0) {
    return { verdict: null, reason: '没有多边形，无从验算' };
  }
  const stemText = String(stem ?? '');
  const metric = /面积|占地/.test(stemText) ? 'area' : /周长/.test(stemText) ? 'perimeter' : '';
  if (metric === '') return { verdict: null, reason: '题干没问面积或周长' };

  const scale = figureScale(figure);
  if (scale === null) {
    return { verdict: null, reason: '缺少可用的尺寸标注，无法定比例' };
  }

  const byName = new Map(figure.points.map((point) => [point.name, point]));
  let coordinateTotal = 0;
  for (const polygon of figure.polygons) {
    const pts = polygon.map((name) => byName.get(name)).filter(Boolean);
    coordinateTotal += metric === 'area' ? polygonArea(pts) : polygonPerimeter(pts);
  }
  const real = metric === 'area' ? coordinateTotal * scale * scale : coordinateTotal * scale;
  if (!(real > 0)) return { verdict: null, reason: '图形算出的量不是正数' };

  const expressions = extractExpressions(answer);
  if (expressions.length === 0) return { verdict: null, reason: '答案里没有可解析的表达式' };

  let checked = 0;
  for (const expression of expressions) {
    const value = evaluateExpression(expression, figure.vars);
    if (value === null) continue;
    checked += 1;
    const diff = Math.abs(value - real);
    if (diff > Math.max(0.02, Math.abs(real) * 0.005)) {
      return {
        verdict: false,
        reason: `「${expression}」算出 ${round3(value)}，图形真实${metric === 'area' ? '面积' : '周长'}是 ${round3(real)}`,
      };
    }
  }
  if (checked === 0) return { verdict: null, reason: '表达式都解析不出数值' };
  return { verdict: true, reason: `已验算 ${checked} 个表达式` };
}

/**
 * 尺寸标注给出的比例系数（图上 1 格等于多少真实单位）。
 *
 * 所有标注必须指向同一个比例，否则返回 null。
 */
function figureScale(figure) {
  if (!Array.isArray(figure.dims) || figure.dims.length === 0) return null;
  const samples = [];
  for (const dim of figure.dims) {
    const value = dimValue(dim.text, figure.vars ?? {});
    if (value === null) continue;
    const length = Math.hypot(dim.to.x - dim.from.x, dim.to.y - dim.from.y);
    if (length < 0.2) continue;
    samples.push(value / length);
  }
  if (samples.length === 0) return null;
  const first = samples[0];
  for (const sample of samples) {
    if (Math.abs(sample - first) > Math.abs(first) * 0.02) return null;
  }
  return first;
}
