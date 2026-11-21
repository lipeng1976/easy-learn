import { ApiError, ErrorCodes } from '../../shared/errors.js';

/**
 * 数据服务 → AI 网关的出站调用。
 *
 * ## 为什么数据服务要调网关
 *
 * 打卡出题要在数据服务里完成：客户端只发一次请求，不用先有本地错题本，
 * 「聚合哪几个知识点」也只有一个口径。
 *
 * 曾经的做法是「客户端调网关出题 → 再 POST 给数据服务存题」，两跳两次解析。
 * 现在一次调用就能完成：聚合错题、出题、校验、落库。
 *
 * 题目**带答案**返回给孩子设备 —— 交卷那一刻要在本机判对错，不等网络。
 * 「答题时看不到答案」由客户端渲染层保证，不是这个接口的责任。
 *
 * ## 只转发调用者原来那张票
 *
 * **不新签一张服务票**。项目里「取票只走 `AiIdentity.resolve`」是硬约束：
 * 另建一份票，迟早出现「票写 A、身份取 B」——本地全绿，只有网关 401。
 * 这里把客户端带来的 `Authorization` 原样转发，身份因此是**同一个**；
 * 网关侧看到的 studentId 与数据服务鉴权时解出来的也是同一个人。
 *
 * `X-Student-Id` 同时带上，只为 `AI_REQUIRE_AUTH=false` 的本机开发栈：
 * 那种部署下网关不验票、只认这个头。生产强鉴权时网关会忽略它，
 * 并在与票不一致时记进审计（见 ai-gateway/src/guard.js 的 `declaredStudentId`）。
 *
 * ## 未配置基址就是不可用，不做「静默退回客户端出题」
 *
 * 退回客户端等于把这个漏洞原样装回去，而且部署方看不到任何提示。
 */

/** 网关信封里允许透传的状态码范围。其它一律按 502 处理。 */
function relayStatus(status) {
  return Number.isInteger(status) && status >= 400 && status <= 599 ? status : 502;
}

/**
 * @param {object} options
 * @param {string} [options.baseUrl] 网关基址（`AI_GATEWAY_BASE_URL`），如 `http://127.0.0.1:8787`
 * @param {number} [options.timeoutMs] 单次调用超时
 * @param {typeof fetch} [options.fetchImpl] 注入点（测试用假实现，不真发网络请求）
 */
export function createAiGatewayClient({
  baseUrl = '',
  timeoutMs = 30_000,
  fetchImpl = globalThis.fetch,
} = {}) {
  const base = String(baseUrl ?? '').trim().replace(/\/+$/, '');

  /**
   * 调一个网关端点，返回信封里的 `data`。
   *
   * 失败一律抛 `ApiError`，**错误码按「客户端该做什么」重新归类**，
   * 不是把网关的码原样搬过来：
   *
   *   · 网关 401/403 → `modelAuthFailed`。这里的 401 几乎不可能是「用户票过期」
   *     （数据服务刚验过同一张票），真实原因是两个函数配了**不同的**
   *     `AI_SESSION_SECRET`。客户端去重新登录一百次也没用，只能运维修。
   *   · 网络/5xx → `modelUnavailable`（可重试）。
   *   · 超时 → `modelTimeout`（可重试）。
   *   · 其余业务码（`schema_violation` / `rate_limited` / `quota_exhausted` …）
   *     原样透传：客户端对它们的处理与直连网关时完全一致，不该多一层翻译。
   */
  async function postJson(path, { authHeader = '', studentId = '', body = {}, timeout = timeoutMs } = {}) {
    if (base === '') {
      throw new ApiError(
        ErrorCodes.modelNotEnabled,
        '服务端没有配置 AI 网关地址（AI_GATEWAY_BASE_URL），每日打卡暂时出不了题',
        {
          retryable: false,
          details: { configMissing: 'AI_GATEWAY_BASE_URL' },
        },
      );
    }
    if (typeof fetchImpl !== 'function') {
      throw new ApiError(ErrorCodes.internal, '当前运行时没有 fetch，无法调用 AI 网关', {
        status: 500,
        retryable: false,
      });
    }

    const headers = { 'content-type': 'application/json', accept: 'application/json' };
    if (authHeader !== '') headers.authorization = authHeader;
    if (studentId !== '') headers['x-student-id'] = studentId;

    let response;
    try {
      response = await fetchImpl(`${base}${path}`, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(timeout),
      });
    } catch (cause) {
      // `AbortSignal.timeout` 抛的是 TimeoutError（DOMException）；
      // 手工 abort 也可能是 AbortError。两者都是「等太久」，可重试。
      const name = String(cause?.name ?? '');
      if (name === 'TimeoutError' || name === 'AbortError') {
        throw new ApiError(
          ErrorCodes.modelTimeout,
          `AI 网关在 ${Math.round(timeout / 1000)} 秒内没有返回`,
          { status: 504, retryable: true, cause },
        );
      }
      throw new ApiError(
        ErrorCodes.modelUnavailable,
        `连不上 AI 网关（${base}）：${cause?.message ?? cause}`,
        { status: 502, retryable: true, cause },
      );
    }

    let payload = null;
    try {
      payload = await response.json();
    } catch {
      payload = null;
    }

    if (response.ok && payload && payload.ok === true) {
      return { data: payload.data, meta: payload.meta ?? null };
    }

    const error = payload?.error ?? {};
    const code = String(error.code ?? '');

    if (response.status === 401 || response.status === 403) {
      throw new ApiError(
        ErrorCodes.modelAuthFailed,
        'AI 网关不接受本服务的调用凭证 —— 两个函数配的 AI_SESSION_SECRET 可能不一致',
        {
          status: 502,
          retryable: false,
          details: { upstreamStatus: response.status, upstreamCode: code || undefined },
        },
      );
    }

    if (code !== '' && code !== ErrorCodes.internal) {
      throw new ApiError(code, String(error.message ?? 'AI 网关调用失败'), {
        status: relayStatus(response.status),
        retryable: error.retryable === true,
        details: error.details,
      });
    }

    throw new ApiError(
      ErrorCodes.modelUnavailable,
      `AI 网关返回了无法识别的响应（HTTP ${response.status}）`,
      { status: 502, retryable: true },
    );
  }

  return { postJson, baseUrl: base };
}
