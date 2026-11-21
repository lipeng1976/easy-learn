/**
 * 教材「骨架」Markdown 的解析器。
 *
 * ## 骨架长什么样
 *
 * ```markdown
 * # 人教版七年级上册 数学
 *
 * ## 第1章 有理数 | p1
 * 考点：正数、负数、数轴、相反数、绝对值
 *
 * ## 第2章 整式的加减 | p23
 * 考点：单项式、多项式、同类项、合并同类项
 * ```
 *
 * 三行就能表达一节：**标题（可带页码）+ 考点清单**。为什么只到这一层粒度：
 *
 *   · 出题要的是「考什么」，不是「课本原文」—— 喂正文会让模型抄原题；
 *   · 理科教材的公式、几何图、电路图转 MD 必丢（见 `doc/textbook-ima-format.md`），
 *     硬转出来的是「看起来完整、其实缺条件」的半成品，比没有更危险；
 *   · 一节十几个考点词，几十行就能覆盖一本书，ima 一次输出得完。
 *
 * ## 为什么不从标题里解析章号
 *
 * 教材写法各不相同：「第 1 章」「Unit 1」「一、」「1.」「Chapter One」。
 * 正则覆盖不全时**不报错**，只是章号乱掉或者全变成 1 —— 而症状要到
 * 「家长选了第 3 章、出的是第 1 章」才看得出来。
 * 所以章号 = **文档里出现的顺序**（1 起）。家长看到的下拉里也是这个顺序。
 *
 * ## 容错
 *
 * 人手敲、模型生成，实际文件里一定会有：代码围栏包一层、CRLF、全角竖线 `｜`、
 * 考点写成 `考点:`。这些都认。认不出的行**直接忽略**（不是报错）——
 * 一张多出来的分隔线不该让整本书导不进来。
 */

/** 最多容纳的节数。真到 300 节说明文件拿错了，不是教材。 */
const MAX_UNITS = 300;

/** 给用户看的格式说明（导入失败时原样回显，比一句「格式不对」有用）。 */
export const TEXTBOOK_FORMAT_HINT =
  '教材文件需要这样的结构：一行「# 书名」，每节一个「## 第N章 标题 | p页码」，'
  + '下一行「考点：知识点1、知识点2」。';

/** 去掉模型习惯性包在外面的 ```markdown 围栏与 BOM。 */
function stripFence(text) {
  let one = String(text ?? '').replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n');
  one = one.trim();
  if (!one.startsWith('```')) return one;
  const lines = one.split('\n');
  if (lines.length < 2) return one;
  lines.shift();
  if (lines[lines.length - 1].trim().startsWith('```')) lines.pop();
  return lines.join('\n').trim();
}

/** `第1章 有理数 | p1` → `{ title: '第1章 有理数', pageHint: '1' }`。 */
function splitTitle(raw) {
  const parts = String(raw).split(/[|｜]/);
  const title = (parts[0] ?? '').trim();
  // 页码只作提示：`p1` / `P1` / `第1页` / `1` 都收，统一成去掉前导 p 的形式。
  const pageHint = (parts[1] ?? '')
    .trim()
    .replace(/^[pP]\s*/, '')
    .replace(/^第\s*/, '')
    .replace(/\s*页$/, '');
  return { title, pageHint };
}

/**
 * 解析骨架文本。
 *
 * @param {string} text  Markdown 原文
 * @param {{title?: string}} [options] 书名兜底（一般取文件名）
 * @returns {{title: string, units: Array<{unitNo: number, title: string, summary: string, pageHint: string}>}}
 */
export function parseTextbookSkeleton(text, { title = '' } = {}) {
  const body = stripFence(text);
  const units = [];
  let bookTitle = '';

  for (const rawLine of body.split('\n')) {
    const line = rawLine.trim();
    if (line === '') continue;

    // `###` 及更深不当节：模型偶尔会多打一个 #，那不是新的一节。
    if (/^##\s+/.test(line) && !/^###/.test(line)) {
      if (units.length >= MAX_UNITS) break;
      const { title: unitTitle, pageHint } = splitTitle(line.replace(/^##\s+/, ''));
      if (unitTitle === '') continue;
      units.push({
        unitNo: units.length + 1,
        title: unitTitle,
        summary: '',
        pageHint,
      });
      continue;
    }

    if (/^#\s+/.test(line)) {
      if (bookTitle === '') bookTitle = line.replace(/^#\s+/, '').trim();
      continue;
    }

    // 考点行：只认「考点：」开头，且必须已经有一节（否则是书级说明，忽略）。
    const hit = line.match(/^考点\s*[:：]\s*(.*)$/);
    if (hit && units.length > 0) {
      const current = units[units.length - 1];
      const point = hit[1].trim().replace(/[。.;；]+$/, '');
      if (point === '') continue;
      // 允许写多行考点：拼起来，保留原有分隔符。
      current.summary = current.summary === '' ? point : `${current.summary}、${point}`;
    }
  }

  return {
    title: bookTitle || String(title ?? '').trim(),
    units,
  };
}

/**
 * 一节的考点串 → 知识点数组。
 *
 * 分隔符收 `、 ， , ; ； /`：模型生成时这几种都会出现，而**只认一种**的结果是
 * 「整节 12 个考点被当成 1 个知识点」，出题范围宽到等于没设。
 */
export function splitPoints(summary, limit = 6) {
  const out = [];
  for (const piece of String(summary ?? '').split(/[、,，;；/]/)) {
    const one = piece.trim();
    if (one === '' || out.includes(one)) continue;
    out.push(one);
    if (out.length >= limit) break;
  }
  return out;
}
