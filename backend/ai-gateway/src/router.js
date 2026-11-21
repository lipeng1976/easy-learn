import { randomUUID } from 'node:crypto';

import { CAPABILITY_BY_KIND } from './config.js';
import {
  ErrorCodes,
  GatewayError,
  badRequest,
  notImplemented,
  payloadTooLarge,
  toGatewayError,
} from './errors.js';

/**
 * 客户端「没有身份」时曾用过的占位符学号。
 *
 * 与客户端 `ai_config.dart` 的 `kAnonymousStudentId` **必须一致** ——
 * 两侧对这个字符串的判断是同一件事：它不是学号，是「我没身份」的自白。
 *
 * 网关拿到它只能拒绝：配额按学号分桶、审计按学号归因，
 * 一个占位符会让额度落在「谁也不是」的账上。客户端现在会在上行前就拦住
 * （见 `AiApiClient.postJson` 的 `usable` 判定），这里留着是为了
 * **旧版本客户端**与手写调用仍然给出可读的错，而不是静默地把它当初学者号。
 */
const ANONYMOUS_STUDENT_ID = 'anonymous';

/**
 * 路由：把规范化后的请求分派给业务端点。
 *
 * 这里同时负责三件跨端点的横切事务：
 * - **信封**：成功 `{ok:true,data,meta}`、失败 `{ok:false,error}`。
 *   客户端只需要认一种形状，不必按端点分别处理。
 * - **限流**：在调用业务端点**之前**检查配额。放在之后等于「先花钱再拦」——
 *   超限的那次调用已经产生了费用，只是被丢弃而已。
 * - **审计**：无论成功失败都留一条记录。
 *
 * 配额开关写在路由表上而不是由端点自己声明：端点在执行过程中才知道
 * 自己要不要计费，而配额必须提前判定，两者不能混在一个字段上。
 * （路由表声明「是否预扣」，端点通过 `ctx.quotaCharged` 表达「这次要不要退」。）
 */
export function createRouter({ config, handlers, guard, uploads }) {
  const routes = [
    route('POST', '/ai/homework/ocr', handlers.homeworkOcr, { kind: 'homeworkOcr' }),
    route('POST', '/ai/homework/check', handlers.homeworkCheck, { kind: 'homeworkCheck' }),
    route('POST', '/ai/review/judge', handlers.reviewJudge, { kind: 'reviewJudge' }),
    // 拍照作答：把照片转录成文字**填进作答框**，学生确认后再走上面那条 judge。
    // 它自己不判定对错，所以路径挂在 review 下而不是另开一族。
    route('POST', '/ai/review/answer-ocr', handlers.answerOcr, { kind: 'answerOcr' }),
    // 错题录入：把照片里的题目提取成文本，供学生确认后入库。
    // 与 answer-ocr 的区别是「要的是题目，不是学生的作答」。
    route('POST', '/ai/review/extract-mistakes', handlers.extractMistakes, {
      kind: 'extractMistakes',
    }),
    route('POST', '/ai/review/explain', handlers.reviewExplain, { kind: 'reviewExplain' }),
    // 讲解配图：判「这题该不该画」，该画就给坐标（客户端本地画）。
    // 和 practice 分开是因为**触发时机不同**：practice 是学生点「练一练」，
    // 这个是学生在讲解页点「画一张图」。合并成一条端点就得靠 want 字段区分，
    // 而 want 一旦写错，学生会得到三张练习题却看不到图。
    route('POST', '/ai/review/figure', handlers.reviewFigure, { kind: 'reviewFigure' }),
    route('POST', '/ai/review/practice', handlers.reviewPractice, { kind: 'reviewPractice' }),
    // 每日概念打卡：按知识点出几道短题。
    // 判分**不在网关**做 —— 客户端本地比对（选择/判断是有限答案集），
    // 所以这里只出题、连答案一起下发，见 handlers.checkinGenerate 的说明。
    route('POST', '/ai/checkin/generate', handlers.checkinGenerate, {
      kind: 'checkinGenerate',
    }),
    // 错题库 → 知识点提示。与 practice 的区别是**只读不改**：
    // 它不产生新题、也不判定，只把已错过的知识点各写一句话，
    // 供计时页在学生做作业时轮换显示。
    route('POST', '/ai/review/tips', handlers.reviewTips, { kind: 'reviewTips' }),
    // 语音合成（伴读）：鸿蒙 NEXT 的卓易通容器里没有安卓 TTS 服务，
    // 端上 `TextToSpeech` 会把主线程卡十几秒然后超时。声音只能由服务端生成。
    // 不占配额（它不调对话模型，见 handlers.tts），字数上限在 handler 里卡死。
    route('POST', '/ai/tts', handlers.tts, { quota: false }),
    route('POST', '/ai/review/reference-batch', handlers.reviewReferenceBatch, {
      kind: 'reviewReferenceBatch',
    }),

    // 签名只是发一个凭证，不触碰模型，不该占用学生的每日配额 ——
    // 否则「传了 4 张照片」这件事会挤掉真正的批改额度。
    route('POST', '/ai/uploads/sign', handlers.uploadsSign, { quota: false }),

    // ===== 短信验证码：接口路由已预留，实现尚未接入 =====
    //
    // 客户端 `SmsGateway` 的默认实现就是「没接」，所以正常流量不会到这里。
    // 把这三条路先摆出来，是为了**把契约钉死**：路径、方法、状态码、
    // 以及「不应重试」这个语义。等接入短信网关时，改动只发生在
    // 这三个 handler 的实现里，客户端与路由表都不动。
    //
    // 三个决定，各自都有理由：
    // - `auth: false` —— 验证码要发给**还没有登录的人**。挂鉴权会把
    //   唯一需要它的那批用户全挡在外面，而且报的还是 401，
    //   看起来像「凭证过期」。
    // - `quota: false` —— 不调模型，不该占学生的 AI 额度。
    //   短信自己的频控是另一套维度（按手机号 + 时间桶），
    //   上线时在 handler 里做，不要借 AI 的这套。
    // - 返回 **501 而不是 404** —— 见 `ErrorCodes.notImplemented`。
    route('POST', '/auth/sms/send', handleSmsNotImplemented, { auth: false, quota: false }),
    route('POST', '/auth/sms/verify', handleSmsNotImplemented, { auth: false, quota: false }),
    route('POST', '/auth/sms/reset', handleSmsNotImplemented, { auth: false, quota: false }),

    // 探活不鉴权、不计配额：监控系统不该为了取一个状态码而持有学生身份。
    // 它返回的也只有能力开关，没有任何学生数据。
    route('GET', '/ai/health', handlers.health, { auth: false, quota: false }),
    route('POST', '/ai/health', handlers.health, { auth: false, quota: false }),

    // 看板要身份（用量数据不该公开可读），但不算配额（运维动作、不调模型）。
    route('GET', '/ai/metrics', handlers.metricsSnapshot, { quota: false }),
    route('POST', '/ai/metrics', handlers.metricsSnapshot, { quota: false }),

    route('PUT', '/ai/uploads/put', handleUploadPut, { auth: false, quota: false }),
    route('GET', '/ai/files', handleFileGet, { auth: false, quota: false }),
  ];

  // 装配期自检：带配额的端点必须能查到能力档位。
  //
  // 漏配的后果不是报错，而是**按 1 个单位计费**（guard 对未知能力按 1 算）——
  // 视觉批改本该扣 8 个单位，却只扣 1，额度形同虚设且毫无痕迹。
  // 这种事必须在部署时就炸掉，不能等到线上。
  for (const item of routes) {
    if (item.quota && !CAPABILITY_BY_KIND[item.kind]) {
      throw new Error(
        `路由 ${item.method} ${item.path} 声明了配额，但 ${item.kind} 没有对应的能力档位`
          + '（见 config.js 的 CAPABILITY_BY_KIND）：配额会按 1 个单位错算',
      );
    }
  }

  function handleUploadPut(ctx) {
    const contentType = String(
      ctx.headers?.['content-type'] ?? 'application/octet-stream',
    );
    return { data: uploads.put(ctx.query, ctx.rawBody, contentType), meta: {} };
  }

  /**
   * `/auth/sms/*` 三条预留端点的统一回应。
   *
   * 刻意**不实现「假装发了一条短信」**：那会让整条链路看起来是通的，
   * 而实际上一条短信都没出去 —— 用户会一直等一条永远不来的验证码。
   * 如实回 501，客户端那边也如实显示「短信服务尚未接入」。
   */
  function handleSmsNotImplemented(ctx) {
    throw notImplemented(
      `${ctx.path} 已预留但尚未实现：短信网关还没有接入，客户端也不会走到这里`
        + '（见 doc/auth-extension-seams.md）',
    );
  }

  function handleFileGet(ctx) {
    const object = uploads.get(ctx.query);
    return { raw: object.bytes, contentType: object.contentType };
  }

  return async function handle(request) {
    const requestId =
      String(request.headers?.['x-request-id'] ?? '') ||
      `g${randomUUID().replaceAll('-', '').slice(0, 20)}`;

    // 预检：浏览器跨域时先发 OPTIONS，不带业务体，也不该校验签名。
    if (request.method === 'OPTIONS') {
      return json(204, '', requestId, { preflight: true });
    }

    const matched = routes.find(
      (item) => item.method === request.method && item.path === request.path,
    );

    if (!matched) {
      const pathExists = routes.some((item) => item.path === request.path);
      return failure(
        pathExists
          ? new GatewayError(
              ErrorCodes.methodNotAllowed,
              `${request.path} 不支持 ${request.method}`,
              { status: 405 },
            )
          : new GatewayError(ErrorCodes.notFound, `未知端点 ${request.path}`, {
              status: 404,
            }),
        requestId,
      );
    }

    const startedAt = Date.now();
    let ctx = null;
    let resolvedIdentity = null;

    /**
     * 本次请求的配额状态。
     *
     * ## 为什么扣费点从「进端点之前」挪到了「真要调模型之前」
     *
     * 原实现是在路由层预扣、发现没花钱再退。这条路有个走不通的死角：
     * **缓存命中的判断只有端点里才有**（缓存键依赖业务载荷）。
     * 于是学生反复提交同一份作业时，第一次扣额度、第二次命中缓存，
     * 但**第二次已经在路由层被 429 拦下了** —— 退款逻辑根本没机会执行。
     * 表现出来就是「他什么都没花，却被挡住」。
     *
     * 改成「扣费紧贴在模型调用之前」（端点通过 `ctx.chargeQuota()` 触发）后：
     * - 缓存命中：压根不扣，也就不存在被拦的问题；
     * - 规则短路（空答案判定）：同样不扣；
     * - 参数不合法：在扣费之前就失败了，不扣；
     * - 唯一扣费的路径就是**真的要花这笔钱**。
     *
     * 设计文档那条「不能先花钱再拦」依然成立 —— 扣费发生在模型调用**之前**，
     * 超限的那次请求一次模型调用都不会发出。区别只是判定点往后挪了几微秒，
     * 挪到「已经知道这次要不要花钱」的位置。
     */
    const quota = {
      /** 路由表声明这条路要不要计费。 */
      eligible: matched.quota,
      capability: matched.quota ? CAPABILITY_BY_KIND[matched.kind] : null,
      units: matched.quota ? guard.unitsFor(CAPABILITY_BY_KIND[matched.kind]) : 0,
      /** 当前是否处于「已扣、未退」状态。 */
      charged: false,
    };

    /** 扣费。端点要在**发出模型请求之前**调用它。 */
    async function chargeQuota() {
      if (!quota.eligible || quota.charged || !resolvedIdentity) return;
      await guard.checkQuota(resolvedIdentity.studentId, quota.capability);
      quota.charged = true;
    }

    /**
     * 退还。**退款只有这一个入口**（端点通过 `ctx.refundQuota` 调）。
     *
     * 散着写的话，任何一处漏掉「退过没」的判断都会造成重复退款 ——
     * 计数器是「学生 + 时间桶」维度的，多退一次就是学生白拿一份额度，
     * 而且毫无痕迹。
     */
    async function refundQuota() {
      if (!quota.charged || !resolvedIdentity) return;
      quota.charged = false;
      try {
        await guard.refundQuota(resolvedIdentity.studentId, quota.capability);
      } catch {
        // guard 内部已记审计。退款失败不该改变这次调用的结果。
      }
    }

    try {
      // 上传/取图这两条路不带身份（预签名 URL 自带授权），
      // 只有需要配额的端点才解析身份。
      const identity = matched.auth
        ? guard.authorize(request.headers, requestId)
        : {
            studentId: 'anonymous',
            deviceId: '',
            requestId,
            authenticated: false,
          };
      resolvedIdentity = identity;

      if (matched.quota) {
        if (identity.studentId === ANONYMOUS_STUDENT_ID) {
          // 文案必须与「请求头缺失」区分开。
          //
          // 原先两种情况共用一句「缺少 X-Student-Id」，而实际现场是
          // **请求头在、值是占位符** —— 运维照着这句话去查，会一路往
          // 「客户端是不是没带头」的方向找，永远找不到真相。
          // 顺带记住：这种拒绝是「客户端该在上行前拦住」的一类，
          // 想让它少发生，改的是客户端，不是网关。
          throw badRequest(
            `X-Student-Id 是占位符「${ANONYMOUS_STUDENT_ID}」：客户端在未登录状态下`
              + '发起了 AI 调用。配额与审计无法归到任何学生，已拒绝',
          );
        }
        if (identity.studentId === '') {
          throw badRequest('X-Student-Id 为空，网关无法做配额与审计');
        }
        // 这里只做**能力位自检**，不扣费：扣费在端点里、
        // 紧贴模型调用的地方发生（原因见上面 quota 的说明）。
        // 少了这一步，路由表里写错 kind 的问题要到第一次调用才会暴露。
        if (!quota.capability) {
          throw new GatewayError(
            ErrorCodes.internal,
            `路由 ${request.path} 声明了配额但没有能力档位`,
            { status: 500 },
          );
        }
      }

      if (request.rawBody && request.rawBody.length > config.maxBodyBytes) {
        throw payloadTooLarge(
          `请求体超过 ${Math.round(config.maxBodyBytes / 1024 / 1024)}MB`,
        );
      }

      ctx = {
        path: request.path,
        method: request.method,
        body: requireObjectBody(request, matched),
        identity,
        // 二进制端点（PUT 上传 / GET 取图）不走 body，靠这三项工作。
        // 放在 ctx 上而不是另开一条签名不同的调用路径：
        // 处理器签名统一，路由只多传几个字段，比让一半处理器收 request、
        // 一半收 ctx 要好 —— 后者正是这次 bug 的来源。
        query: request.query ?? {},
        headers: request.headers ?? {},
        rawBody: request.rawBody ?? null,
        /**
         * 配额：状态对象 + 扣费/退款两个动作。
         *
         * 端点必须**在发出模型请求之前** `await ctx.chargeQuota()`，
         * 并且在确认这次没花钱时（能力没配等）`await ctx.refundQuota()`。
         */
        quota,
        chargeQuota,
        refundQuota,
      };

      const result = await matched.handler(ctx);

      if (result.raw) {
        return binary(
          result.raw,
          result.contentType ?? 'application/octet-stream',
          requestId,
        );
      }

      return json(
        200,
        { ok: true, data: result.data, meta: { requestId, ...result.meta } },
        requestId,
      );
    } catch (cause) {
      const error = toGatewayError(cause);

      // 模型调用失败已在 handlers.invoke 里记过（那里有 model / usage / 图片统计）。
      // 这里只补记「还没走到模型就失败」的那一类：参数校验、限流、鉴权、图片超限。
      // 漏记它们的后果是：线上看到「今天没有失败」，实际是失败根本没进日志。
      //
      // 这类失败也**不涉及退额**：扣费点在端点内部、紧贴模型调用，
      // 没走到那里就不会扣 —— 不扣自然不用退。
      if (!ctx?.modelInvoked) {
        guard.audit({
          requestId,
          studentId: resolvedIdentity?.studentId ?? 'unknown',
          path: request.path,
          /**
           * 带上能力档位。
           *
           * 少了这一项，「额度用完」这类拒绝在看板上**归不到任何一级能力** ——
           * 运维只看得到「今天有 30 次失败」，看不出是拍照批改（一档 8 个单位）
           * 用光了，还是判定（一档 2 个单位）用光了。
           * 而这两个结论对应的处置完全相反：一个要加视觉额度，一个要加推理额度。
           */
          capability: quota.capability ?? CAPABILITY_BY_KIND[matched.kind] ?? null,
          ok: false,
          code: error.code,
          units: 0,
          latencyMs: Date.now() - startedAt,
        });
      }

      return failure(error, requestId);
    }
  };
}

function route(method, path, handler, options = {}) {
  return {
    method,
    path,
    handler,
    /** 业务动作名。配额权重由它查 `CAPABILITY_BY_KIND` 得到。 */
    kind: options.kind ?? null,
    auth: options.auth ?? true,
    quota: options.quota ?? true,
  };
}

/** JSON 端点强制要求对象请求体；二进制端点（PUT 上传）不解析 body。 */
function requireObjectBody(request, matched) {
  if (matched.method === 'PUT' || matched.method === 'GET') return {};
  if (request.bodyInvalid) {
    throw badRequest('请求体不是合法 JSON');
  }
  const body = request.body;
  if (body === null || body === undefined) return {};
  if (typeof body !== 'object' || Array.isArray(body)) {
    throw badRequest('请求体应为 JSON 对象');
  }
  return body;
}

function failure(error, requestId) {
  const status = error.status ?? 500;
  return json(status, error.toEnvelope(requestId), requestId);
}

function json(status, payload, requestId, options = {}) {
  const body = payload === '' ? '' : JSON.stringify(payload);
  return {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'X-Request-Id': requestId,
      ...corsHeaders(),
      ...(options.preflight ? { 'Access-Control-Max-Age': '600' } : {}),
    },
    body,
  };
}

function binary(bytes, contentType, requestId) {
  return {
    status: 200,
    headers: {
      'Content-Type': contentType,
      'Cache-Control': 'private, max-age=300',
      'X-Request-Id': requestId,
      ...corsHeaders(),
    },
    body: Buffer.from(bytes),
  };
}

function corsHeaders() {
  // 允许的请求头要显式列出：预检时浏览器只认这份清单，
  // 漏掉 X-Student-Id 会让 Web 端所有请求在预检就被浏览器拦下，
  // 而后端日志里一条都看不到 —— 这类问题排查起来非常费时间。
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS',
    'Access-Control-Allow-Headers':
      'Content-Type, Authorization, X-Student-Id, X-Device-Id, X-App-Version, X-Request-Id',
    'Access-Control-Expose-Headers': 'X-Request-Id',
  };
}
