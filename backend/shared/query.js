/**
 * 从平台 HTTP 事件里读出**查询参数** —— 两个云函数入口共用这一份。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 为什么必须单独抽一个模块（2026-09-24 云上实测，一次真实故障的结论）
 * ══════════════════════════════════════════════════════════════════════════
 *
 * 症状：客户端「拍照识别」和「上传作业图片」都报 **缺少 studentId**，
 * 而同一个 studentId 直接写进 JSON body 却完全正常。也就是说
 * **所有 query 参数都没到达应用**。
 *
 * 真因：阿里云 **FC3 把查询参数放在 `event.queryParameters`**，而两个入口
 * 读的是 `queryStringParameters` / `rawQueryString`（借用 API 网关 / Lambda 的
 * 字段名），两个都不存在 —— 于是 `query` 静默变成 `{}`。
 *
 * 实测的真实事件（`/__diag?a=1&b=2` 的原样回显，只列顶层键）：
 *
 *     {
 *       "version": "v1",
 *       "rawPath": "/__diag",
 *       "headers": {...},              ← 键名是**大写**（Authorization / Host …）
 *       "queryParameters": {...},      ← ⚠️ 就是它，不是 queryStringParameters
 *       "body": "",
 *       "isBase64Encoded": true,
 *       "requestContext": {..., "http": {"method","path","protocol","sourceIp","userAgent"}}
 *     }
 *
 * 为什么本地永远发现不了：
 *   · 本机 `dev-server.js` 用 node:http 的 `req`，query 由 Node 的 URL 解析器给，
 *     根本不经过这层归一化；
 *   · 单测喂的是**我们自己造的**事件对象（照着我们以为的字段名造），
 *     造不出「字段名不对但请求看起来完全正常」这种组合。
 *   于是 `deploy-entry.test.js` 全绿、`deploy-check` 全过、`s deploy` EXIT=0，
 *   而线上每条带 query 的请求都在丢参数。
 *
 * ⚠️ 教训与 `toEventObject`（Buffer 事件）那一处**完全同构**：
 *   「两个入口各写一份 → 只修一个 → 另一个继续错」。
 *   所以这里的规则是：**查询串的字段名只在这一个文件里出现一次**。
 *
 * ⚠️ 别再往 `??` 两边堆字段名去赌：`a ?? b` 是「左侧不是空才用左侧」，
 *   而错的是**字段名本身**，赌错一次的表现就是「参数全丢且不报错」。
 *   这里改成「把已知的几种来源**都读一遍、取并集**」：多读一个不存在的键
 *   成本是零，漏读一个的代价是一次线上故障。
 */

/** 平台把查询串**解析成映射**时用的键名（FC3 用第一个）。 */
const QUERY_MAP_KEYS = [
  'queryParameters',            // ← 阿里云 FC3 HTTP 触发器（实测）
  'queryStringParameters',      // API 网关 / Lambda 风格
  'multiValueQueryStringParameters',
];

/** 平台把查询串**原样**给过来时用的键名。 */
const QUERY_STRING_KEYS = ['rawQueryString', 'queryString'];

/**
 * @param {object} event 已经还原成对象的平台事件（Buffer/字符串要先过 `toEventObject`）
 * @returns {Record<string, string>} 扁平化的查询参数；没有就是空对象
 *
 * 值一律转成字符串：`URLSearchParams` 给的就是字符串，而映射形态里
 * 可能是数字或数组 —— 统一成字符串，业务层只需要处理一种类型。
 * 同名参数出现多次时取**第一个非空**值（顺序：原始串优先，其次各映射）。
 */
export function readQueryParameters(event) {
  const out = {};
  const put = (key, value) => {
    if (typeof key !== 'string' || key === '' || out[key] !== undefined) return;
    if (value === undefined || value === null) return;
    const text = String(Array.isArray(value) ? value[0] : value);
    if (text === '') return;
    out[key] = text;
  };

  // ① 原始查询串优先：它是平台手上的原文，不存在「被解析器丢键/改类型」的余地。
  for (const key of QUERY_STRING_KEYS) {
    const raw = event?.[key];
    if (typeof raw !== 'string' || raw === '') continue;
    try {
      for (const [k, v] of new URLSearchParams(raw)) put(k, v);
    } catch {
      // 坏查询串不该让整个请求挂掉：这条路只是「尽力多读一个来源」。
    }
  }

  // ② 再补齐映射形态的来源（FC3 走的是这里）。
  for (const key of QUERY_MAP_KEYS) {
    const map = event?.[key];
    if (map === null || typeof map !== 'object' || Array.isArray(map)) continue;
    for (const [k, v] of Object.entries(map)) put(k, v);
  }

  return out;
}
