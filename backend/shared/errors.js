/**
 * 服务端错误：把「为什么失败」变成机器可读的错误码。
 *
 * ai-gateway 与 data-service **共用这一份**。理由：错误码是客户端协议的一部分，
 * 两个服务各定义一份的话，同一个失败会在两边叫不同名字，而客户端只认一套 ——
 * 症状是「AI 请求能正确重试，数据请求却莫名重试写操作」。这类分叉最难查。
 *
 * 客户端据此决定要不要重试、要不要降级到本地实现。
 * 因此错误码不是日志细节，而是**协议的一部分**，改动需要同步客户端。
 */
export const ErrorCodes = {
  /** 请求体本身不合法。重试没有意义。 */
  badRequest: 'bad_request',
  /** 鉴权失败（没有凭证 / 凭证无效）。 */
  unauthorized: 'unauthorized',
  /**
   * 会话 token 已过期。
   *
   * 与 [unauthorized] 分开是因为**客户端的处置完全不同**：
   * 过期应当静默换取新 token 后重试，而凭证无效只能提示重新登录。
   * 合成一个码会让客户端在「token 被篡改」时也去反复续签。
   */
  tokenExpired: 'token_expired',
  /** 会话 token 签名不合法 / 结构不对。不可重试，必须重新登录。 */
  tokenInvalid: 'token_invalid',
  /** 打开了强制鉴权但没有配签名密钥。这是运维问题，不是调用方的问题。 */
  authNotConfigured: 'auth_not_configured',
  /**
   * 身份有效，但**没有权限访问这条数据**。
   *
   * 与 [unauthorized] 分开的理由和上面同族：处置方向相反。
   * 401 是「你是谁我不知道」→ 去登录；403 是「我知道你是谁，但这不是你的」
   * → 重新登录没有用（登了还是没有），也不该重试。
   * 典型来源：关系鉴权中间件发现请求的 studentId 不在 visible_students 里。
   */
  forbidden: 'forbidden',
  /** 触发限流。可重试（客户端退避后再来）。 */
  rateLimited: 'rate_limited',
  /**
   * 当日额度用完。
   *
   * 与 [rateLimited] 拆成两个码，是因为**客户端的正确处置完全相反**：
   * 限流等几十秒真能成；额度用完要等到明天（或换个学生账号），
   * 退避重试十几次全是白等、白烧请求。
   * 合成一个码的后果是客户端会对一个当天不可能成功的请求反复重试，
   * 学生看到的就是「转圈很久，最后还是失败」。
   */
  quotaExhausted: 'quota_exhausted',
  /** 请求体超出体积上限（照片太多太大）。客户端能自己修，不该当模型故障处理。 */
  payloadTooLarge: 'payload_too_large',
  /** 该能力对应的模型没配置/没开通。**不可重试** —— 重试一百次也不会开通。 */
  modelNotEnabled: 'model_not_enabled',
  /** 方舟拒绝了网关的凭证（Key 无效、被禁用、欠费）。不可重试，且只能靠运维修。 */
  modelAuthFailed: 'model_auth_failed',
  /** 模型侧临时故障 / 5xx。可重试。 */
  modelUnavailable: 'model_unavailable',
  /** 模型调用超时。可重试。 */
  modelTimeout: 'model_timeout',
  /** 模型返回了内容，但不符合约定 schema。可重试（带 retryHint 更能救回来）。 */
  schemaViolation: 'schema_violation',
  /** 模型返回了无法解析的东西。 */
  modelOutputInvalid: 'model_output_invalid',
  /**
   * 对象存储链路没配齐。
   *
   * 独立成一个码而不是复用 internal：它是**配置问题**，
   * 运维看到就知道该去补哪些环境变量，而不用去翻代码。
   */
  uploadNotConfigured: 'upload_not_configured',
  /**
   * 某个学生的照片张数到了上限。
   *
   * ⚠️ **不复用 [quotaExhausted]**，虽然两者都叫「配额用完」。
   * 客户端看到它们该做的事**恰巧相反**：
   *   · `quota_exhausted` 是 AI 当日额度 → 立刻**回落本地实现**、别再重试
   *     （明天才恢复，退避重试全是白等）；
   *   · 这个码是**存储配额** → 不能回落本地（照片本来就该存在服务端，
   *     回落到设备本地正是「家长看不到孩子照片」那个老 bug），
   *     该做的是**提示用户删掉旧照片**或让运维调大配额。
   *
   * 复用同一个码的后果很具体：客户端会照着 AI 那条路走，弹出
   * 「今日 AI 额度已用完」——把一个存储问题说成了一个模型问题，
   * 于是用户去等明天。这是本项目里「同一个码两种语义」的典型代价。
   *
   * **不可重试**：重试一百次，那个学生的照片数还是满的。
   */
  storageQuotaExceeded: 'storage_quota_exceeded',
  notFound: 'not_found',
  methodNotAllowed: 'method_not_allowed',
  /**
   * 端点已预留、还没有实现。
   *
   * 与 [notFound] 和 [internal] 都不同，**必须单独一个码**：
   * - 看到 `not_found`，人会去查「是不是部署漏了这段代码」；
   * - 看到 `internal`，人会去查日志、当成一次线上故障；
   * - 看到这个码，正确的反应是「这是计划内的空缺」——不用查，也不用重试。
   *
   * 目前 `/auth/sms/*` 三条路会返回它（短信网关尚未接入），
   * 见 `doc/auth-extension-seams.md`。
   */
  notImplemented: 'not_implemented',
  /**
   * 数据库暂时不可用（连不上 / 连接池耗尽 / 正处于故障切换）。
   *
   * 单独一个码而不是并进 internal：它是**基础设施问题且可重试**，
   * 而 internal 是「代码有 bug、重试大概率还是错」。混在一起会让客户端
   * 对真正的 bug 做无意义的退避重试。
   */
  /**
   * ima 凭证被拒（key 失效 / 无权限 / 走错了账号）。
   *
   * 与 [modelAuthFailed] 同一族但**不复用**：客户端看到它该做的事相反 ——
   * 这里是「家长的 ima 连接过期了，去「连接 ima」里重连」，不是「去查模型 Key」。
   * 合成一个码的话，家长端会弹出一条和 ima 无关的提示，于是没人去重连，
   * 而打卡/错题数据就一直静静躺在本地、从不被推上去。
   */
  imaAuthFailed: 'ima_auth_failed',
  /**
   * ima 服务端临时故障 / 5xx。可重试 —— 与 [modelUnavailable] 同族，
   * 但客户端应当**降级到本地**（数据先存本地、等下次再推），而不是无限重试烧请求。
   */
  imaUnavailable: 'ima_unavailable',
  /**
   * ima 请求本身失败（非 401/403/5xx 的 4xx，或返回结构不符合约定）。
   *
   * 单独一个码而不是并进 internal：它是**外部依赖的配置/契约问题**，
   * 运维看到就知道该去核对 ima 端点的返回结构或请求参数，而不是翻本服务代码。
   */
  imaRequestFailed: 'ima_request_failed',
  dbUnavailable: 'db_unavailable',
  /**
   * 提交的作答与当前题目对不上 —— 典型场景：客户端拿着旧卷交卷，
   * 而这份打卡已经被重新出题换掉了。
   *
   * 单独一个码而不是并进 badRequest / notFound，理由与上面同族：
   * 客户端看到它的正确处置是**丢弃手里的卷、重新拉题重做**，
   * 而不是把「提交失败」重试一百次（内容不变，重试必然还是这个错）。
   * 2026-10-27 真机事故：重新出题只换内容不换主键，孩子手里的 8 题作答
   * 被静默裁成 5 题、拿新题判出 2/5 —— 本地「全对」、云端「2/5」。
   */
  quizVersionConflict: 'quiz_version_conflict',
  /** 服务端自身的 bug。可重试一次碰运气，但要靠日志定位。 */
  internal: 'internal',
};

/**
 * 「确定没到模型」的错误码。
 *
 * 这些失败发生在发出模型请求**之前**（能力没配、参数不合法、体太大），
 * 因此不产生任何模型费用 —— 预扣的额度必须退回去，否则学生为一个
 * 根本没发生的调用付了额度。
 *
 * 反面同样重要：`model_timeout` / `model_unavailable` / `schema_violation`
 * **不退**。前两者可能已经在模型侧跑完并计了费，后者一定跑完并计了费。
 * 规则是「不确定有没有花钱时按花过算」—— 否则配额会被超时重试磨穿。
 *
 * 注：这条规则只属于 ai-gateway（data-service 不碰模型额度），
 * 但码表本身是共用的，所以集合也放在这里，避免它引用一个不存在于本文件的码。
 */
export const NO_COST_ERROR_CODES = new Set([
  'model_not_enabled',
  'bad_request',
  'payload_too_large',
]);

/**
 * 服务端错误的统一载体。
 *
 * 原先叫 `GatewayError`，抽到共享层时改成中性名 —— 数据服务不是网关，
 * 一个叫 gateway 的异常类会让人以为它只该在网关里用。
 * ai-gateway 侧保留 `GatewayError` 这个别名，调用点不用动。
 */
export class ApiError extends Error {
  /**
   * @param {string} code 见 ErrorCodes
   * @param {string} message 给人看的中文说明
   * @param {{status?: number, retryable?: boolean, details?: object, cause?: Error}} [options]
   */
  constructor(code, message, options = {}) {
    super(message, options.cause ? { cause: options.cause } : undefined);
    this.name = 'ApiError';
    this.code = code;
    this.status = options.status ?? 400;
    this.retryable = options.retryable ?? false;
    this.details = options.details ?? undefined;
  }

  toEnvelope(requestId) {
    const error = {
      code: this.code,
      message: this.message,
      retryable: this.retryable,
    };
    if (this.details !== undefined) error.details = this.details;
    if (requestId) error.requestId = requestId;
    return { ok: false, error };
  }
}

/** 兜住任何非 ApiError 的异常，避免把内部堆栈漏给客户端。 */
export function toApiError(cause) {
  if (cause instanceof ApiError) return cause;
  return new ApiError(
    ErrorCodes.internal,
    '服务端内部错误，请稍后重试',
    { status: 500, retryable: true, cause },
  );
}

/**
 * 服务端自身的 bug / 数据不一致。
 *
 * ⚠️ 用它的地方应当是**理论上不可达**的分支。一旦出现，说明代码假设被打破了，
 * 这时候宁可把话说直白（带着能定位的信息），也不要伪装成一次普通的业务失败 ——
 * 后者会让排查从一个假的方向开始。
 */
export function internal(message = '服务端内部错误，请稍后重试', options = {}) {
  return new ApiError(ErrorCodes.internal, message, {
    status: 500,
    retryable: true,
    ...options,
  });
}

export function badRequest(message, details) {
  return new ApiError(ErrorCodes.badRequest, message, { details });
}

/**
 * 端点已预留但尚未实现。
 *
 * **`retryable: false` 是刻意的**：这个端点不是「暂时坏了」，
 * 而是「还没做」。让它可重试只会让客户端对一个永远不会成功的请求退避重试，
 * 把「功能没上线」表现成「偶发失败」。
 */
export function notImplemented(message) {
  return new ApiError(ErrorCodes.notImplemented, message, {
    status: 501,
    retryable: false,
  });
}

export function unauthorized(message = '缺少有效的调用凭证') {
  return new ApiError(ErrorCodes.unauthorized, message, { status: 401 });
}

/**
 * 身份有效但没有权限。
 *
 * 刻意 `retryable: false` —— 权限不会因为重试而出现，
 * 且重新登录也解决不了（换个 token 还是这个身份）。
 */
export function forbidden(message = '无权访问该数据') {
  return new ApiError(ErrorCodes.forbidden, message, {
    status: 403,
    retryable: false,
  });
}

/** 会话过期：客户端应换取新 token 后重试。 */
export function tokenExpired(message = '会话已过期，请重新登录') {
  return new ApiError(ErrorCodes.tokenExpired, message, {
    status: 401,
    // 不可重试是刻意的：同一个 token 再发一次必然还是过期。
    // 「换 token 再试」是**客户端**的动作，不是 HTTP 层重试能解决的。
    retryable: false,
  });
}

export function tokenInvalid(message = '会话凭证无效') {
  return new ApiError(ErrorCodes.tokenInvalid, message, { status: 401 });
}

export function authNotConfigured(message) {
  return new ApiError(ErrorCodes.authNotConfigured, message, {
    status: 503,
    retryable: false,
  });
}

export function rateLimited(message, details) {
  return new ApiError(ErrorCodes.rateLimited, message, {
    status: 429,
    retryable: true,
    details,
  });
}

/**
 * 当日额度用完。
 *
 * 同样回 429（语义上确实是「太多请求了」），但 **`retryable: false`** ——
 * 客户端必须立刻回落本地实现并把「今天额度用完了」如实告诉用户，
 * 而不是退避重试。见 [ErrorCodes.quotaExhausted]。
 *
 * `details` 里带上额度口径：看板与客户端都能据此说出「是视觉场景太贵
 * 还是总量不够」，而这决定了下一步是调权重还是提额度。
 */
export function quotaExhausted(message, details) {
  return new ApiError(ErrorCodes.quotaExhausted, message, {
    status: 429,
    retryable: false,
    details,
  });
}

export function payloadTooLarge(message, details) {
  return new ApiError(ErrorCodes.payloadTooLarge, message, {
    status: 413,
    details,
  });
}

/**
 * 该学生的照片张数已达上限。
 *
 * ## 为什么是 409 而不是 429 / 413 / 403
 *
 * - **429** 的语义是「你发得太快，等会儿再来」——客户端会退避重试，
 *   而这里**重试一万次也一样**：那个学生的照片数不会自己变少。
 * - **413** 说的是「这一次的请求体太大」，但超限与这一批的大小无关 ——
 *   只发一张、在满额的学生名下照样超。用 413 会让人去压图片尺寸。
 * - **403** 会与「这不是你的数据」混在一起，于是排查方向变成检查鉴权。
 * - **409** 说的正是实情：请求本身没问题，是**目标资源当前的状态**装不下了。
 *
 * ## `details` 必须带数字
 *
 * 只回一句「已达上限」，用户唯一能做的动作就是「再试一次」。
 * 带上 `used` / `quota` / `incoming` 之后，界面能说出「已用 N / 上限 N 张」，
 * 用户就知道该去删旧照片，运维也知道该不该调大 `IMAGE_QUOTA_PER_STUDENT`。
 */
export function storageQuotaExceeded(message, details) {
  return new ApiError(ErrorCodes.storageQuotaExceeded, message, {
    status: 409,
    // 刻意不可重试：配额不会因为重试而变化。
    retryable: false,
    details,
  });
}

export function notFound(message = '资源不存在') {
  return new ApiError(ErrorCodes.notFound, message, { status: 404 });
}

/**
 * 作答与当前题目对不上（打卡被重新出题覆盖）。409 + 不可重试：
 * 处置动作在客户端 —— 丢卷、重新拉题。
 */
export function quizVersionConflict(message = '题目已更新，请重新打开打卡') {
  return new ApiError(ErrorCodes.quizVersionConflict, message, {
    status: 409,
    retryable: false,
  });
}

export function methodNotAllowed(message = '不支持的请求方法') {
  return new ApiError(ErrorCodes.methodNotAllowed, message, { status: 405 });
}

/**
 * 数据库暂时不可用。可重试 —— 基础设施抖动是暂时的。
 *
 * 注意与 `internal` 的区别：后者是「代码有问题」，重试没有意义。
 */
export function dbUnavailable(message, options = {}) {
  return new ApiError(ErrorCodes.dbUnavailable, message, {
    status: 503,
    retryable: true,
    ...options,
  });
}

export function modelNotEnabled(capability) {
  return new ApiError(
    ErrorCodes.modelNotEnabled,
    `服务端未配置 ${capability} 能力对应的模型（请检查 ARK_MODEL_* 环境变量与方舟侧的开通状态）`,
    // 刻意 retryable: false。这条错误一旦出现就是配置问题，
    // 让它可重试只会把「配置漏了」表现成「偶发失败」，把排查方向带偏。
    { status: 503, retryable: false, details: { capability } },
  );
}

export function schemaViolation(problems) {
  return new ApiError(
    ErrorCodes.schemaViolation,
    `模型输出不符合约定结构：${problems.slice(0, 3).join('；')}`,
    { status: 502, retryable: true, details: { problems } },
  );
}

export function modelAuthFailed(message) {
  return new ApiError(
    ErrorCodes.modelAuthFailed,
    `方舟拒绝了网关凭证：${message}（请检查 ARK_API_KEY 是否有效、是否欠费）`,
    // retryable: false —— 凭证问题重试不会自愈，只会让限流更快触发。
    { status: 502, retryable: false },
  );
}

/**
 * ima 凭证被拒（key 失效 / 无权限）。
 *
 * **`retryable: false` 是刻意的**：这与「数据库连接抖动」相反 —— 重连 ima
 * 不会因为重试而出现，它只能靠家长去「连接 ima」里重新粘贴有效的 key。
 * 让它可重试只会把「家庭没连 ima」表现成「偶发失败」，把排查方向带偏，
 * 而真正该发生的事（提示家长重连）一直不发生。
 */
export function imaAuthFailed(message) {
  return new ApiError(
    ErrorCodes.imaAuthFailed,
    `ima 拒绝了凭证：${message}（请到「连接 ima」重新粘贴有效的 clientid / apikey）`,
    { status: 502, retryable: false },
  );
}

/** ima 侧临时故障（5xx）。可重试，但客户端应降级到本地、而非无限重试。 */
export function imaUnavailable(message) {
  return new ApiError(ErrorCodes.imaUnavailable, message, {
    status: 502,
    retryable: true,
  });
}

/** ima 请求失败（非 401/403/5xx 的 4xx，或返回结构不符约定）。不可重试。 */
export function imaRequestFailed(message, details) {
  return new ApiError(ErrorCodes.imaRequestFailed, message, {
    status: 502,
    retryable: false,
    details,
  });
}

export function modelUnavailable(message, options = {}) {
  return new ApiError(ErrorCodes.modelUnavailable, message, {
    status: 502,
    retryable: true,
    ...options,
  });
}

export function modelTimeout(message) {
  return new ApiError(ErrorCodes.modelTimeout, message, {
    status: 504,
    retryable: true,
  });
}
