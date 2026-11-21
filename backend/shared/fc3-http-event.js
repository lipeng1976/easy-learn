/**
 * **真实抓取**的阿里云 FC3 HTTP 触发器事件样本 —— 两个服务的测试共用这一份。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 它为什么必须存在，以及为什么必须是「原样」
 * ══════════════════════════════════════════════════════════════════════════
 *
 * 2026-09-24 云端实测发现**所有 query 参数都没到达应用**：
 * 拍照识别与上传作业图片都报「缺少 studentId」，而同一个 studentId
 * 放进 JSON body 却完全正常。
 *
 * 真因就在这份形状里：**FC3 把查询参数放在 `queryParameters`**，
 * 而两个入口读的是 `queryStringParameters` / `rawQueryString`。用 `??` 读两个
 * 都不存在的键 → `query` 静默变成 `{}`。
 *
 * ⚠️ 网关那边**早就把这份事件抄进测试了**（`gateway.test.js` 的 realEvent），
 * 而且抄对了 `queryParameters` 这个键名 —— 但值写的是 `{}`，于是那条测试
 * 只验证了「Buffer 与对象两种形态等价」，字段名错了它一句话都说不出来。
 * **这就是本文件存在的理由：形状要原样保留，且要被断言钉住。**
 *
 * ⚠️ 因此：**不要「顺手简化」这里的键**（把 `queryParameters` 改名成更眼熟的
 * `queryStringParameters`、删掉看着没用的 `version` / `isBase64Encoded` …）。
 * 这个样本的价值全部来自「它和平台真实发过来的一模一样」。
 * `assertCapturedShape()` 就是拦这种「善意的清理」的。
 *
 * 抓法（可复现）：把事件原样回显的临时端点挂到函数上，请求一次
 * `GET /__diag?a=1&b=2`，读响应。形状**未经任何加工**，只把
 * `Authorization` 之类的值换掉。
 */

/**
 * 实测抓到的**顶层键**，一个不多一个不少（`/__diag` 那次响应的
 * 「② 解析后的顶层键」原样抄录，顺序也是原样）。
 */
export const CAPTURED_TOP_LEVEL_KEYS = [
  'version',
  'rawPath',
  'headers',
  'queryParameters',
  'body',
  'isBase64Encoded',
  'requestContext',
];

/**
 * 造一份与平台真实事件**同形状**的事件。
 *
 * 只允许覆盖「随请求而变」的部分（路径、方法、查询参数、请求体、请求头）；
 * 其余字段照抄实测值 —— 尤其是 `isBase64Encoded: true`：
 * **实测连 GET 请求它都是 true**，所以业务代码不能拿它来判断「有没有 body」。
 *
 * @param {object} [init]
 * @param {string} [init.path] 路径（会同时写进 `rawPath` 与 `requestContext.http.path`）
 * @param {string} [init.method] HTTP 方法
 * @param {Record<string, string|string[]>} [init.query] 查询参数 —— 落进 `queryParameters`
 * @param {string} [init.body] 原始请求体（base64 与否由 `isBase64Encoded` 决定）
 * @param {boolean} [init.isBase64Encoded]
 * @param {Record<string, string>} [init.headers] 请求头（真实事件里键名是**大写**的）
 * @returns {object} 可以直接喂给 `toRequest()`，也可以 `JSON.stringify` 后再喂（模拟 Buffer）
 */
export function fc3HttpEvent({
  path = '/data/homework/images',
  method = 'GET',
  query = {},
  body = '',
  isBase64Encoded = true,
  headers = {},
} = {}) {
  return {
    version: 'v1',
    rawPath: path,
    headers: {
      Authorization: 'Bearer test-token-not-real',
      'Accept-Language': '*',
      Connection: 'keep-alive',
      'Accept-Encoding': 'br, gzip, deflate',
      Host: 'easy-learn-data-bunatimdzn.cn-hangzhou.fcapp.run',
      Accept: '*/*',
      'Sec-Fetch-Mode': 'cors',
      'User-Agent': 'node',
      ...headers,
    },
    queryParameters: query,
    body,
    isBase64Encoded,
    requestContext: {
      accountId: '1234567890',
      domainName: 'easy-learn-data-bunatimdzn.cn-hangzhou.fcapp.run',
      domainPrefix: 'easy-learn-data-bunatimdzn',
      requestId: 'req_captured_sample',
      time: '2026-09-24T15:30:00.000Z',
      timeEpoch: 1758727800000,
      http: {
        method,
        path,
        protocol: 'HTTP/1.1',
        sourceIp: '36.148.179.99',
        userAgent: 'node',
      },
    },
  };
}

/**
 * 守住「这份样本与平台实测形状一致」。
 *
 * 单独立一个函数、两个测试文件各自调用它：任一处「顺手改名」都会当场变红，
 * 而不是等到线上参数又丢一次。
 */
export function assertCapturedShape(assert, sample) {
  assert.deepEqual(
    Object.keys(sample),
    CAPTURED_TOP_LEVEL_KEYS,
    '这份事件样本必须与云端实测抓到的形状**逐键一致**（见文件头说明，别顺手改名或删字段）',
  );
  assert.equal(
    sample.queryParameters && typeof sample.queryParameters === 'object',
    true,
    '查询参数落在 queryParameters —— 这是 FC3 的字段名，不是 queryStringParameters',
  );
  // 反面：我们**曾经**读的那两个键在真实事件里根本不存在。
  // 把这条钉住，「为什么以前会丢参数」就不必靠回忆。
  assert.equal(sample.queryStringParameters, undefined);
  assert.equal(sample.rawQueryString, undefined);
}
