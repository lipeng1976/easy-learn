import { createHash } from 'node:crypto';

import { verifySessionToken } from './auth.js';
import {
  ErrorCodes,
  GatewayError,
  badRequest,
  quotaExhausted,
  rateLimited,
  unauthorized,
} from './errors.js';
import { createMemoryStore } from './store.js';

/** 学生 ID 允许的字符集。 */
const STUDENT_ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

/** 三级能力在配额报错里的说法。用学生看得懂的动作名，不用技术术语。 */
const QUOTA_LABELS = {
  vision: '拍照批改',
  reasoning: '判定与讲解',
  light: '文本解析',
};

/**
 * 请求护栏：鉴权、配额、缓存、审计。
 *
 * 这四件事在设计文档里被写成「BFF 的职责」。它们放在一个模块里，
 * 是因为它们都作用于同一个请求上下文，拆开只会让调用方多写四行样板。
 *
 * ## 配额是**两层**的，不是一层
 *
 * - **共享层**（`store`，配了 `AI_KV_URL` 才生效）：真正的全局配额。
 * - **本地层**（进程内 Map，永远生效）：单实例安全网。
 *
 * 为什么两层都要：共享层是「正确」，本地层是「可用」。
 * KV 抖动时如果只剩共享层，判定的依据就没了；只剩本地层，多实例下
 * 配额会成倍放大。两层叠加的结果是——
 * - 正常情况下：本地不会先触发（它和全局同额），实际由共享层裁决
 * - KV 故障时：退化成单实例安全网，并且**留下 `quota_degraded` 审计**
 *
 * 这个降级是**刻意的**：KV 抖一下就把全体学生的 AI 能力停掉，
 * 代价比一次短暂的配额放大高得多。需要反过来（宁可停服也不超支）
 * 就把 `AI_KV_FAIL_MODE=closed`。
 */
export function createGuard({
  config,
  store,
  now = () => Date.now(),
  onAudit,
} = {}) {
  const kv = store ?? createMemoryStore({ now });

  /** 本地兜底计数：`{key}|{bucket}` -> 已消耗的成本单位 */
  const localMinuteCounters = new Map();
  const localDayCounters = new Map();
  const events = [];

  /** 共享存储故障计数，供运维观察（`/ai/health` 会带出去）。 */
  let storeFailures = 0;

  /**
   * 某级能力单次消耗的成本单位。
   *
   * 没识别的能力按 1 算而不是 0：0 等于白送额度，而「不认识」恰恰
   * 是最不该被优惠的情况（新加了一条路由但忘了给权重，就会变成免费入口）。
   */
  function weightOf(capability) {
    const weight = config.quota?.weights?.[capability];
    return Number.isFinite(weight) && weight > 0 ? weight : 1;
  }

  /**
   * 审计实现。
   *
   * **刻意不记录学生答案与作业照片。** 教育数据里这些属于最敏感的一类
   * （照片里有姓名、班级、住址），而审计要回答的问题只有三个：
   * 谁调的、花了多少、有没有异常。把答案拍进日志既不解决这三个问题，
   * 又多出一份需要合规看护的数据。
   *
   * 定义在这里而不是直接写在返回对象上：`bumpShared` 与 `readCache`
   * 内部也要记审计（配额降级、存储故障），写成对象字面量的方法就够不着。
   */
  function auditEvent(event) {
    const record = {
      at: new Date(now()).toISOString(),
      requestId: event.requestId ?? null,
      studentId: event.studentId ?? null,
      path: event.path,
      capability: event.capability ?? null,
      model: event.model ?? null,
      ok: event.ok,
      code: event.code ?? null,
      cached: event.cached ?? false,
      /**
       * 本次**实际扣掉**的额度。缓存命中与规则短路是 0。
       *
       * 和下面的 `tokens` 是两回事：前者是本系统的记账口径，
       * 后者是厂商的计费口径。看板要把两者分开看 ——
       * 它们长期对不上就说明权重配歪了。
       */
      units: event.units ?? 0,
      latencyMs: event.latencyMs ?? null,
      tokens: event.usage
        ? {
            in: event.usage.prompt_tokens ?? 0,
            out: event.usage.completion_tokens ?? 0,
          }
        : null,
      imageCount: event.imageCount ?? 0,
      imageBytes: event.imageBytes ?? 0,
      ...(event.note ? { note: event.note } : {}),
    };
    events.push(record);
    if (events.length > 500) events.shift();
    onAudit?.(record);
    return record;
  }

  function pruneCounters(map, bucketMs) {
    const current = Math.floor(now() / bucketMs);
    // 只留当前与前一个窗口：一个窗口前的计数已经不再参与判定。
    for (const key of map.keys()) {
      const bucket = Number.parseInt(key.slice(key.lastIndexOf('|') + 1), 10);
      if (current - bucket > 1) map.delete(key);
    }
  }

  function bumpLocal(map, key, units, limit) {
    const count = (map.get(key) ?? 0) + units;
    map.set(key, count);
    return count > limit;
  }

  /**
   * 共享层自增。
   *
   * **只负责计数，不负责判定** —— 超限的判断由调用方在
   * 「本地层与共享层都扣完之后」统一做。分两处判的话，
   * 本地层与共享层各抛一次错，报出来的原因可能是错的（例如本地超的是分钟、
   * 共享超的是天）。
   *
   * @returns {{count: number}|{failure: Error}} 二选一
   */
  async function bumpShared(key, ttlSeconds, units) {
    try {
      return { count: await kv.incr(key, ttlSeconds, units) };
    } catch (cause) {
      storeFailures++;
      if (config.kv?.failMode === 'closed') {
        throw new GatewayError(
          ErrorCodes.internal,
          '配额服务暂时不可用，请稍后重试',
          { status: 503, retryable: true, cause },
        );
      }
      return { failure: cause };
    }
  }

  /** 分钟窗口的 Key。桶号本身就表达了窗口语义，TTL 只负责回收。 */
  function minuteKey(studentId, bucket) {
    return `q:m:${studentId}:${bucket}`;
  }

  function dayKey(studentId, bucket) {
    return `q:d:${studentId}:${bucket}`;
  }

  /**
   * 把「成本单位」翻译成用户能懂的话术。
   *
   * 阈值本身是按成本算的，但对学生说「你还有 24 个单位」毫无意义 ——
   * 他不知道一次批改要几个单位，也就无法判断还能用几次。
   * 所以对外一律换算成**次数**：每天最多几次拍照批改，一眼就懂。
   */
  function allowText(capability) {
    const units = weightOf(capability);
    return {
      units,
      label: QUOTA_LABELS[capability] ?? 'AI 调用',
      perMinute: Math.max(1, Math.floor(config.quota.unitsPerMinute / units)),
      perDay: Math.floor(config.quota.unitsPerDay / units),
    };
  }

  return {
    /** 共享存储是否真的在生效。运维排查「配额为什么不准」时的第一手信息。 */
    get storeShared() {
      return kv.shared === true;
    },

    get storeDriver() {
      return kv.driver ?? 'unknown';
    },

    get storeFailures() {
      return storeFailures;
    },

    /**
     * 解析调用方身份。
     *
     * `requireAuth` 打开时，**学号只从 token 里解**，请求头里的 `X-Student-Id`
     * 会被忽略。这一点是强鉴权能不能成立的关键：
     * 如果两者都接受，伪造者只要继续带头就绕过了整套机制，
     * 而外部看起来「已经加了鉴权」。
     */
    authorize(headers, requestId) {
      const raw = headers?.authorization ?? headers?.Authorization ?? '';
      const token = raw.startsWith('Bearer ') ? raw.slice(7).trim() : '';

      const declared = String(
        headers?.['x-student-id'] ?? headers?.['X-Student-Id'] ?? '',
      ).trim();
      const deviceId = String(
        headers?.['x-device-id'] ?? headers?.['X-Device-Id'] ?? '',
      ).slice(0, 64);

      if (config.requireAuth) {
        if (token === '') {
          throw unauthorized('需要提供会话 token（Authorization: Bearer …）');
        }
        const session = verifySessionToken(token, {
          secret: config.auth?.sessionSecret ?? '',
          now: now(),
        });
        return {
          studentId: session.studentId,
          deviceId,
          requestId,
          authenticated: true,
          expiresAt: session.expiresAt,
          // 带上这个字段是为了让审计能回答「这条记录是不是有人伪造了学号」。
          // 没有它就只能靠猜。
          declaredStudentId: declared && declared !== session.studentId
            ? declared
            : null,
        };
      }

      if (declared === '') {
        throw badRequest('缺少 X-Student-Id，网关无法做配额与审计');
      }
      if (!STUDENT_ID_PATTERN.test(declared)) {
        // 严格校验而不是「随便存下」：这个值会被拼进缓存键、
        // 写进审计日志、当作指标维度。放通任意字符串等于把日志注入和
        // 缓存键碰撞一起接进来。
        throw badRequest('X-Student-Id 格式不合法');
      }

      return {
        studentId: declared,
        deviceId,
        requestId,
        authenticated: false,
        expiresAt: null,
        declaredStudentId: null,
      };
    },

    /** 某级能力单次消耗的成本单位。没识别的能力按 1 算（保守：不白送额度）。 */
    unitsFor(capability) {
      return weightOf(capability);
    },

    /** 能力的额度口径（换算成次数），供 health 与报错文案使用。 */
    quotaTerms(capability) {
      return allowText(capability);
    },

    /**
     * 配额检查。按**成本权重**扣减，超限抛错。
     *
     * - 分钟窗口超限 → `rate_limited`（可重试：等一会真能成）
     * - 天窗口超限 → `quota_exhausted`（**不可重试**：今天不会再好了）
     *
     * 两个窗口的报错码不同是刻意的，见 errors.js 里的说明。
     *
     * 注意本方法是**预扣**：它先扣掉，后续若发现这次调用其实没花钱
     * （缓存命中、规则短路），由调用方 [refundQuota] 退回来。
     * 反过来做（先放行、事后补扣）不成立 —— 那等于「先花钱再拦」。
     *
     * @param {string} studentId
     * @param {string} capability 三级能力之一，决定扣几个单位
     */
    async checkQuota(studentId, capability) {
      const terms = allowText(capability);
      const minuteBucket = Math.floor(now() / 60000);
      const dayBucket = Math.floor(now() / 86400000);
      const unitMinuteLimit = config.quota.unitsPerMinute;
      const unitDayLimit = config.quota.unitsPerDay;

      // 本地层先扣：它永远可用，且能保证「KV 挂了也不会无限放行」。
      //
      // 注意计数器里存的是**成本单位**，所以这里比的是单位上限，
      // 不是 `terms.perMinute/perDay`（那两个是换算给用户看的次数）。
      // 拿单位去比次数会让最贵的场景一次都跑不了 —— 视觉一次 8 单位、
      // 而「每分钟 1 次」的 1 是次数，比出来永远是超限。
      const minuteOverLocal = bumpLocal(
        localMinuteCounters,
        `${studentId}|${minuteBucket}`,
        terms.units,
        unitMinuteLimit,
      );
      const dayOverLocal = bumpLocal(
        localDayCounters,
        `${studentId}|${dayBucket}`,
        terms.units,
        unitDayLimit,
      );

      let minuteOverShared = false;
      let dayOverShared = false;

      if (kv.shared === true) {
        // TTL 取窗口的两倍：桶号本身已经保证了窗口语义，
        // TTL 只负责把旧键清掉，给宽一点避免边界上被提前回收。
        const minuteShared = await bumpShared(
          minuteKey(studentId, minuteBucket),
          120,
          terms.units,
        );
        const dayShared = await bumpShared(
          dayKey(studentId, dayBucket),
          86400 * 2,
          terms.units,
        );

        minuteOverShared = (minuteShared.count ?? 0) > unitMinuteLimit;
        dayOverShared = (dayShared.count ?? 0) > unitDayLimit;

        // 一次请求只记**一条**降级审计。分钟与天各记一条的话，
        // KV 抖一下每个请求就刷两条重复记录，反而把真正的异常淹掉。
        const failure = minuteShared.failure ?? dayShared.failure;
        if (failure) {
          auditEvent({
            path: '(quota)',
            studentId,
            ok: false,
            code: 'quota_degraded',
            note: `共享 KV 不可用，本次仅用单实例配额兜底：${
              failure?.message ?? failure
            }`,
          });
        }
      }

      if (localMinuteCounters.size > 2000) pruneCounters(localMinuteCounters, 60000);
      if (localDayCounters.size > 20000) pruneCounters(localDayCounters, 86400000);

      // 天窗口优先于分钟窗口：两个都超时，用户该被告知的是「今天没了」，
      // 而不是「等一分钟」—— 后者会让他反复重试。
      if (dayOverLocal || dayOverShared) {
        throw quotaExhausted(
          `今天的 AI 额度用完了（${terms.label}每天最多 ${terms.perDay} 次）。`
            + '明天会恢复，或者先用离线模式继续。',
          {
            capability,
            window: 'day',
            units: terms.units,
            unitLimit: config.quota.unitsPerDay,
            callsLimit: terms.perDay,
          },
        );
      }
      if (minuteOverLocal || minuteOverShared) {
        throw rateLimited(
          `操作太频繁，请稍等片刻再试（${terms.label}每分钟最多 ${terms.perMinute} 次）`,
          {
            capability,
            window: 'minute',
            units: terms.units,
            unitLimit: config.quota.unitsPerMinute,
            callsLimit: terms.perMinute,
          },
        );
      }
    },

    /**
     * 退还本次预扣的额度。
     *
     * ## 为什么必须退
     *
     * 预扣发生在**路由层**（那时还不知道这次调用要不要花钱），而
     * 「没花钱」的两种情况都在**业务层**才揭晓：
     * - **缓存命中**：结果直接取自缓存，没有模型调用；
     * - **规则短路**：例如没填答案的判定，规则一句话就定了。
     *
     * 不退的后果很具体：学生把同一份作业反复提交（改一次答案重交一次），
     * 每次都命中缓存，额度却照样扣 —— 他什么都没花，却被告知「今天额度用完了」。
     * 那不是一个成本问题，是一个说不通的体验。
     *
     * 退款**不抛错**：它是收尾动作，失败只记一条审计。
     * 让退款失败去打断一次已经成功的调用，是拿主流程给配账陪葬。
     */
    async refundQuota(studentId, capability) {
      const units = weightOf(capability);
      if (!(units > 0)) return;

      const minuteBucket = Math.floor(now() / 60000);
      const dayBucket = Math.floor(now() / 86400000);
      const minuteLocal = `${studentId}|${minuteBucket}`;
      const dayLocal = `${studentId}|${dayBucket}`;

      localMinuteCounters.set(
        minuteLocal,
        Math.max(0, (localMinuteCounters.get(minuteLocal) ?? 0) - units),
      );
      localDayCounters.set(
        dayLocal,
        Math.max(0, (localDayCounters.get(dayLocal) ?? 0) - units),
      );

      if (kv.shared !== true) return;
      try {
        await kv.incr(minuteKey(studentId, minuteBucket), 120, -units);
        await kv.incr(dayKey(studentId, dayBucket), 86400 * 2, -units);
      } catch (cause) {
        storeFailures++;
        auditEvent({
          path: '(quota)',
          studentId,
          ok: false,
          code: 'quota_refund_failed',
          note: `额度退还失败，本次额度未退回：${cause?.message ?? cause}`,
        });
      }
    },

    /** 读缓存。过期返回 null。 */
    async readCache(key) {
      try {
        return await kv.get(`c:${key}`);
      } catch {
        // 缓存读失败是**可忽略**的：退化成「没命中」，代价只是多一次模型调用。
        // 与配额不同 —— 配额没有依据会让花钱失控，缓存没有依据只是少省一点。
        storeFailures++;
        return null;
      }
    },

    async writeCache(key, value) {
      try {
        await kv.set(`c:${key}`, value, Math.ceil(config.cacheTtlMs / 1000));
      } catch {
        storeFailures++;
      }
    },

    /**
     * 缓存键：能力 + 请求内容的哈希。
     *
     * **刻意不把学生 ID 拼进去。** 两个学生拿同一份输入来问，结论对两人同样成立；
     * 而请求体里本来就不含任何学生身份或历史，所以共享缓存不会把 A 的作答泄漏给 B。
     * 反之，如果按学生分桶，「同一个知识点全校问一千遍」就是一千次模型调用，
     * 缓存基本白做。
     *
     * 代价要说清楚：命中的两个人会拿到**逐字相同**的变式题与讲解。
     * 这在闭环里可以接受（练的是方法，不是背题），但如果是竞赛类场景
     * 需要「每人一套新题」，就得把学生 ID 加进来。
     */
    cacheKey(capability, payload) {
      const digest = createHash('sha256')
        .update(JSON.stringify(payload))
        .digest('hex')
        .slice(0, 32);
      return `${capability}:${digest}`;
    },

    /**
     * 审计一条调用。实现见上面的 `auditEvent`。
     */
    audit: auditEvent,

    /** 测试用：最近的审计记录。 */
    recentEvents() {
      return [...events];
    },

    /** 测试用：清空所有状态。 */
    async reset() {
      localMinuteCounters.clear();
      localDayCounters.clear();
      events.length = 0;
      storeFailures = 0;
      await kv.clear?.();
    },
  };
}
