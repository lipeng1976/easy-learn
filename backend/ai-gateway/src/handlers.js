import { CAPABILITY_BY_KIND } from './config.js';
import {
  ErrorCodes,
  GatewayError,
  NO_COST_ERROR_CODES,
  badRequest,
  schemaViolation,
  toGatewayError,
  unauthorized,
} from './errors.js';
import { normalizeImages } from './media.js';
import { normalizeFigure, polygonArea, verifyFigureAnswer } from './figure.js';
import {
  compareExpressions,
  describeAreaMismatch,
  describeMismatch,
  evaluateSource,
  positiveVars,
} from './figure-verify.js';
import { systemPromptFor } from './prompts.js';
import { Schemas } from './schema.js';
import { synthesizeTts } from './tts.js';

/**
 * 一次最多归纳多少个知识点。
 *
 * 12 个已经够覆盖一个科目的错题本：再多，提示条数会超过学生愿意翻的量
 * （计时页一次只显示一条），而输入 token 全都要付。
 */
const MAX_TIP_ITEMS = 12;

/**
 * 打卡一次最多覆盖几个知识点。
 *
 * 打卡是「每天几分钟」，不是组卷。知识点超过 6 个，题目就会摊薄成
 * 一人一题、每个都只碰一下就过 —— 那不叫复习，叫浏览。
 * 少而集中才有意义：宁可今天只考两个知识点各两道。
 */
const MAX_CHECKIN_ITEMS = 6;

/**
 * 出题难度。与 `reviewPractice`（举一反三）用的是**同一套词**。
 *
 * 不另造「简单 / 中等 / 困难」：这两个能力的结果会进同一份学习档案，
 * 两套词在统计里就是两个不同的值，而没有任何一处会报错。
 */
const CHECKIN_DIFFICULTIES = ['基础', '提高', '挑战'];

/**
 * 业务端点。
 *
 * 端点**按业务动作划分，不按模型划分** —— 客户端不需要知道背后是哪个模型，
 * 换模型（甚至换厂商）不该要求客户端发版。
 * 因此响应里也不会出现任何模型 ID。
 */
export function createHandlers({ config, model, guard, uploads, metrics, now = () => Date.now() }) {
  /**
   * 退还本次扣掉的额度。
   *
   * 真正的判断（扣过没、退过没）在路由的那个闭包里，见 router.js 的
   * `refundQuota` —— **退款只能有一个入口**，否则容易重复退。
   * 这里只是转发，让端点读起来像「这次没花钱，退掉」。
   */
  async function refund(ctx, reason) {
    await ctx.refundQuota?.();
    ctx.refundReason = reason;
  }

  /** 本次实际扣掉的额度（已退的话是 0）。审计与响应都按这个报。 */
  function chargedUnits(ctx) {
    return ctx.quota?.charged ? (ctx.quota.units ?? 0) : 0;
  }

  /** 一次带缓存与审计的模型调用。 */
  async function invoke(ctx, { kind, payload, content, temperature }) {
    const startedAt = now();
    const identity = ctx.identity;
    const capability = CAPABILITY_BY_KIND[kind] ?? null;
    const cacheKey = guard.cacheKey(kind, payload);

    // 缓存探测必须在扣费**之前**：命中的调用没有模型费用，
    // 不该被额度拦住，也不该消耗额度。
    // （反过来做「先扣后退」是行不通的 —— 学生会在扣费那一刻就被 429 挡下，
    //   退款分支永远走不到。见 router.js 里 quota 的说明。）
    const cached = await guard.readCache(cacheKey);
    if (cached !== null) {
      guard.audit({
        requestId: identity.requestId,
        studentId: identity.studentId,
        path: ctx.path,
        capability,
        model: 'cache',
        ok: true,
        cached: true,
        units: 0,
        latencyMs: now() - startedAt,
      });
      return { data: cached, meta: { cached: true, model: 'cache', units: 0 } };
    }

    // 到这里才确定要花这笔钱 —— 扣费点紧贴模型调用。
    //
    // **`modelInvoked` 必须置在扣费之后。** 路由靠这个标记判断
    // 「这次失败是端点已经记过审计、还是得我来补记」。扣费抛出的
    // `quota_exhausted` 是**在扣费这一刻**发生的，此时还没置标记，
    // 路由才会补记一条 —— 而「额度用完了」恰恰是运维最需要看见的失败。
    // 踩过的坑就是把标记置在扣费之前：看板上 `byCode.quota_exhausted`
    // 永远是空的，像是没人触发过额度上限。
    await ctx.chargeQuota?.();

    // 标记「已经走到模型这一层」。审计由这里和路由共同负责：
    // 走到这里的事件信息最全（模型、用量、图片统计），由这里记；
    // 没走到这里的失败（鉴权、参数校验、配额超限）由路由补记。
    // 不区分的话，要么漏掉「还没进模型就失败」的那一半，
    // 要么同一次失败被记两条。
    ctx.modelInvoked = true;

    try {
      const result = await model.complete({
        capability,
        // 传 kind 只为一件事：决定这条路由要不要关思维链（见 ark.js）。
        // 选模型仍然只认 capability —— 两者混在一起时，
        // 想调「讲解快点」会连「判定用哪个模型」一起改掉。
        kind,
        schema: Schemas[kind],
        system: systemPromptFor(kind, { retryHint: ctx.body.retryHint }),
        content,
        temperature,
      });
      // 调试开关：本地排查「模型到底给了什么」时开 `AI_DEBUG_RAW=1`。
      // 平时不打印 —— 这里的内容是题目与学生作答，不该进常规日志。
      if (process.env.AI_DEBUG_RAW === '1') {
        console.log('[ai-debug] kind=%s cap=%s\n%s', kind, capability, JSON.stringify(result.value).slice(0, 6000));
      }
      await guard.writeCache(cacheKey, result.value);
      guard.audit({
        requestId: identity.requestId,
        studentId: identity.studentId,
        path: ctx.path,
        capability,
        model: result.model,
        ok: true,
        cached: false,
        units: chargedUnits(ctx),
        latencyMs: now() - startedAt,
        usage: result.usage,
        imageCount: ctx.imageCount ?? 0,
        imageBytes: ctx.imageBytes ?? 0,
      });
      return {
        data: result.value,
        meta: {
          cached: false,
          model: result.model,
          units: chargedUnits(ctx),
          usage: result.usage,
          finishReason: result.finishReason,
        },
      };
    } catch (cause) {
      const error = toGatewayError(cause);
      // 确定没到模型（能力没配 / 参数不合法）→ 没花钱，额度退回。
      const shouldRefund = NO_COST_ERROR_CODES.has(error.code);
      if (shouldRefund) await refund(ctx, error.code);
      guard.audit({
        requestId: identity.requestId,
        studentId: identity.studentId,
        path: ctx.path,
        capability,
        ok: false,
        code: error.code,
        units: chargedUnits(ctx),
        latencyMs: now() - startedAt,
        imageCount: ctx.imageCount ?? 0,
        imageBytes: ctx.imageBytes ?? 0,
      });
      throw error;
    }
  }

  /**
   * 图形题复核：第一次批改说「对」的含图题，交给程序算一遍。
   *
   * ## 为什么不直接信复核模型
   *
   * 复核用的也是同一个视觉模型。2026-10-23 的漏判就是它做的 ——
   * 它看得见那两行式子（单独转录一字不差），只是**没去算**。
   * 所以这次让它把式子交出来，由 `compareExpressions` 代入数值判决。
   *
   * ## 只用来否决
   *
   * 程序说「不同」⇒ 升级为错题；程序算不了（式子语法超出能力）⇒ **维持原判**。
   * 反方向不许用：程序说相等但模型说错时不升级 —— 图形题里存在
   * 「写法等价但依赖几何约束」的情况（绝对值、分段、单位换算），
   * 采样不一定覆盖得到。宁可少抓一条，也不能把做对的题塞进错题库。
   */
  async function reviewFigureAnswers(ctx, result, images) {
    const graded = result.data ?? {};
    const all = Array.isArray(graded.figureQuestions) ? graded.figureQuestions : [];
    if (all.length === 0) return result;

    /**
     * 已经判进 items 的题不必再复核 —— 结论已经是「错」了。
     * 判重不能只看题号：不少作业没有题号（questionNo 是空串），
     * 那样所有题都会被判成同一道。所以连同题干一起比。
     */
    const alreadyWrong = new Set(
      (graded.items ?? []).map((item) => `${item.questionNo ?? ''}|${item.question ?? ''}`),
    );
    const pending = all.filter(
      (q) => !alreadyWrong.has(`${q.questionNo ?? ''}|${q.question ?? ''}`),
    );
    if (pending.length === 0) return result;

    const lines = pending.map((q, index) => [
      `${index + 1}. 题号：${q.questionNo || '（无）'}`,
      `题干：${q.question}`,
      `学生写的内容：${q.studentWork || '【识别不清】'}`,
    ].join('\n'));

    let verification;
    try {
      verification = await invoke(ctx, {
        kind: 'homeworkFigureVerify',
        // 题干与学生写法都要进指纹：同一张照片里换了一道题，
        // 复核结果不能复用。
        payload: {
          questions: pending.map((q) => ({
            no: q.questionNo ?? '',
            question: q.question,
            work: q.studentWork ?? '',
          })),
          images: fingerprint(images),
          // 复核的判据（采样点、多数票阈值）改了要升这个值，
          // 否则同一批照片会一直复用旧判定 —— 和上面 schemaVersion 同一个道理。
          schemaVersion: 'figure-verify-3',
        },
        content: [
          {
            type: 'text',
            text: `本次作业有 ${pending.length} 道图形题需要复核。\n\n`
              + `${lines.join('\n\n')}\n\n请逐题验算，results 的顺序与上面一致。`,
          },
          ...images.parts,
        ],
      });
    } catch (error) {
      // 复核失败不能把整次批改拖垮：第一次的结果已经可用，而且已经扣过费。
      // 审计由 invoke 内部记（ok:false），这里只把状态标出来便于排查。
      return {
        ...result,
        meta: { ...result.meta, figureVerify: { status: 'failed', code: error?.code ?? null } },
      };
    }

    const results = Array.isArray(verification.data?.results) ? verification.data.results : [];
    const taken = new Set();
    const added = [];

    results.forEach((row, index) => {
      // 优先按题干找回原题；模型改了措辞就退回顺序对应。
      let source = pending.find((q) => !taken.has(q) && q.question === row.question);
      if (source === undefined) {
        const byIndex = pending[index];
        source = byIndex !== undefined && !taken.has(byIndex)
          ? byIndex
          : pending.find((q) => !taken.has(q));
      }
      if (source === undefined) return;
      taken.add(source);

      const studentExprs = (row.studentExpressions ?? [])
        .filter((s) => typeof s === 'string' && s.trim() !== '');
      if (studentExprs.length === 0) return;

      const rawRefs = (row.referenceExpressions ?? [])
        .filter((s) => typeof s === 'string' && s.trim() !== '');
      const vars = positiveVars(row.preferredValues);
      /**
       * **几何面积** —— 复核里唯一不依赖模型代数能力的证据。
       *
       * 2026-10-23 实测两种错法都出现过：
       *   ① 参考式把 `ab` 写成 `bc`，算出 16，而图形真实面积是 32；
       *   ② 把学生写错的式子直接抄进了 references。
       * 拿这样的参考式当判据，会把做对的学生判错 —— 比漏判更糟。
       * 所以只要模型给了轮廓点，就用鞋带公式自己算面积。
       */
      const area = Array.isArray(row.outline) && row.outline.length >= 3
        ? polygonArea(row.outline)
        : null;

      let wrongReason = '';
      let standardAnswer = '';

      if (area !== null && vars !== null && area > 0) {
        const tolerance = Math.max(1e-6, area * 1e-6);
        let bad = null;
        for (const studentExpr of studentExprs) {
          const value = evaluateSource(studentExpr, vars);
          // 式子解析不了的跳过 —— 「算不了」不等于「算错了」。
          if (value === null) continue;
          if (Math.abs(value - area) > tolerance) {
            bad = { student: studentExpr, area, sample: vars, studentValue: value };
            break;
          }
        }
        if (bad === null) return;
        wrongReason = describeAreaMismatch(bad) || row.reason;
        // 参考答案只收「代入后等于几何面积」的式子：模型写错的那个（如 bc）
        // 会在这里被剔掉。宁可给空（错题本允许空参考答案），也不给一个错的。
        standardAnswer = rawRefs
          .filter((ref) => {
            const value = evaluateSource(ref, vars);
            return value !== null && Math.abs(value - area) <= tolerance;
          })
          .join(' 或 ');
      } else {
        /**
         * 没有轮廓点时才退回「参考式比对」。
         *
         * 参考式先剔掉「和学生某一式等价」的那些：模型可能直接把学生的错式
         * 抄进来（实测发生过）。不剔的话判定也许仍然对，但
         * `standardAnswer` 会把错的式子写成「参考答案」进错题库。
         */
        const refs = rawRefs.filter((ref) => !studentExprs.some((studentExpr) =>
          ref.trim() === studentExpr.trim()
          || compareExpressions({
            reference: [ref],
            student: studentExpr,
            variables: row.variables,
          }).verdict === 'equal'));
        if (refs.length === 0) return;

        let mismatch = null;
        for (const studentExpr of studentExprs) {
          const check = compareExpressions({
            reference: refs,
            student: studentExpr,
            variables: row.variables,
            preferred: row.preferredValues,
          });
          if (check.verdict === 'different') {
            mismatch = { student: studentExpr, ...check };
            break;
          }
        }
        // 只有程序明确算出「不等」才升级。`unknown` 一律放行。
        if (mismatch === null) return;
        wrongReason = describeMismatch(mismatch) || row.reason;
        standardAnswer = refs.join(' 或 ');
      }

      added.push({
        question: source.question,
        questionNo: source.questionNo ?? '',
        studentProcess: source.studentWork ?? '',
        standardAnswer,
        knowledgePoint: row.knowledgePoint,
        originalAnswer: studentExprs.join('；'),
        wrongReason,
      });
    });

    if (added.length === 0) {
      return {
        ...result,
        meta: {
          ...result.meta,
          figureVerify: { status: 'ok', checked: pending.length, added: 0 },
        },
      };
    }

    const items = [...(graded.items ?? []), ...added];
    /**
     * 分数必须跟着改。
     *
     * 留着 `score=100` 而 items 里有错题，家长先看到的和实际存的相互矛盾
     * （批改提示词 6.7 明确禁止这种自相矛盾）。每多一条扣 15 分：
     * 不追求精确，只求「有错就不再是满分」。
     */
    const score = Math.max(0, (graded.score ?? 100) - 15 * added.length);
    const summary = (graded.items ?? []).length === 0
      ? `有 ${added.length} 道图形题验算没有通过，已并入错题；其余题目做对了。`
      : `${graded.summary}（另有 ${added.length} 道图形题验算未通过，已一并计入。）`;

    return {
      data: { ...graded, score, summary, items, figureQuestions: all },
      meta: {
        ...result.meta,
        figureVerify: { status: 'ok', checked: pending.length, added: added.length },
      },
    };
  }

  return {
    /** 能力与配置状态。客户端据此决定「要不要把照片发上来」。 */
    health(ctx) {
      return {
        data: {
          capabilities: model.capabilities(),
          /**
           * 这台部署的身份。客户端用它排除「同网段上的别人家的服务」——
           * 只在配了 `SERVER_INSTANCE_ID` 时出现（旧部署没有这个字段）。
           */
          ...(config.instanceId ? { instanceId: config.instanceId } : {}),
          /**
           * 区域。**只有方舟靠它拼数据面地址**，百炼端点固定、没有区域概念。
           *
           * 所以对百炼回空串，而不是回一个恒为 `cn-beijing` 的假值 ——
           * 后者会让人以为「百炼也要选区域」，去控制台找一个不存在的设置项。
           */
          region: config.modelProviderSpec?.regionEnv ? config.ark.region : '',
          // 客户端不关心是真人还是 mock，但运维必须一眼看出这套环境在跑什么。
          modelClient: config.modelClient,
          /**
           * 当前用的是哪一家的大模型。
           *
           * 放在 health 里的理由**就一条**：上线后第一个要回答的问题往往是
           * 「这到底在调谁」。它会因为一次环境变量没生效、或实例缓存没重建
           * 而和你以为的不一样 —— 而那种情况下**没有任何一处会报错**。
           * 这里是唯一能一眼看出来的地方（`baseUrl` 不回显，避免带出内网地址）。
           */
          modelProvider: config.modelProvider,
          modelProviderLabel: config.modelProviderSpec?.label ?? '(未知厂商)',
          /**
           * 上面那家的配置是从哪一组环境变量读的（`ARK` / `BAILIAN`）。
           *
           * 与 `modelProvider` 成对出现，缺一不可：「厂商名换了」不等于
           * 「那家的配置被读到了」。两套凭据并存时，最常见的错是
           * **开关换了、另一家的那一组没填全** —— 于是读到一半旧值，
           * 而接口表现完全正常。这里回显的就是实际参与读值的前缀。
           */
          modelProviderEnv: config.providerEnvPrefix,
          /**
           * 因为"本家那组没填"而回退到旧通用名的字段（正常是空数组）。
           *
           * ⚠️ 已填全 = `[]`；非空 = 这一项**用的是另一家的值**。
           * 它不是错误（旧的单套写法是合法兼容），但它是"我打算两套并存、
           * 结果漏填了一项"的唯一可见信号 —— 那种情况下 Key 会串、
           * 报 401，而 401 看起来只是"Key 没开通"。
           */
          modelProviderEnvFallbacks: config.providerEnvFallbacks,
          maxImages: config.maxImages,
          maxImageBytes: config.maxImageBytes,
          imageTransportHint: config.upload.signer === 'tos' ? 'objectStorage' : 'inline',
          maxReferenceBatch: config.maxReferenceBatch,
          /**
           * 鉴权与配额的真实状态。
           *
           * 这三项**只给运维看**，客户端逻辑不依赖它们 ——
           * 但把它们放在 health 里是刻意的：上线后最常见的疑问是
           * 「配额为什么不准」「鉴权到底开没开」，而这两个问题的答案
           * 恰恰是「KV 没配」和「requireAuth 还是 false」。
           */
          auth: {
            enforced: config.requireAuth,
            sessionTtlSeconds: config.auth.sessionTtlSeconds,
          },
          quota: {
            store: guard.storeDriver,
            shared: guard.storeShared,
            storeFailures: guard.storeFailures,
            /**
             * 额度按成本权重算，因此这里**同时**报单位和换算后的次数。
             *
             * 只报单位，运维无法回答「视觉一天能用几次」；
             * 只报次数，运维无法回答「权重配成多少了」。
             * 这两个问题在调额度的时都会问到。
             */
            unitsPerMinute: config.quota.unitsPerMinute,
            unitsPerDay: config.quota.unitsPerDay,
            weights: config.quota.weights,
            dailyCalls: {
              vision: guard.quotaTerms('vision').perDay,
              reasoning: guard.quotaTerms('reasoning').perDay,
              light: guard.quotaTerms('light').perDay,
            },
          },
        },
        meta: {},
      };
    },

    /** 拍照识别。 */
    async homeworkOcr(ctx) {
      const images = normalizeImages(ctx.body.images, config);
      if (images.parts.length === 0) {
        throw badRequest('至少需要一张作业照片');
      }
      tagImages(ctx, images);

      return invoke(ctx, {
        kind: 'homeworkOcr',
        payload: { fileName: ctx.body.fileName ?? '', images: fingerprint(images) },
        content: [
          { type: 'text', text: '请识别这些作业照片，并按科目标出各自的作业要求。' },
          ...images.parts,
        ],
      });
    },

    /**
     * 举一反三的**拍照作答**：把学生手写的这一题解答转录成文字。
     *
     * ## 它是「输入方式」，不是「判定方式」
     *
     * 这段文字回去会**填进学生的作答框**，学生看得见、改得了，然后走原来那条
     * `reviewJudge`。所以这条端点**不产生任何判定结论**（没有 verdict、没有对错），
     * 只负责把照片变成可编辑的文字。这样做的意义是：
     * 「拍照」只是一种更省事的输入法，而不是一条绕过作答的新判定路径 ——
     * 后者会让同一份作答因为「怎么输入的」而得到不同结论。
     *
     * ## 为什么不像 `homeworkOcr` 那样传文件名
     *
     * 那条链路的 `fileName` 是给学生核对「这张是不是我选的那张」用的。
     * 这里拍的是当前正在做的那一道题，题型/题干客户端本来就有，
     * 不需要再拿文件名去反推。少一个字段就少一处可以漂的地方。
     */
    async answerOcr(ctx) {
      const images = normalizeImages(ctx.body.images, config);
      if (images.parts.length === 0) {
        // 没有照片就一定没得识别。宁可明确报错让客户端走原有路径，
        // 也不要让模型凭空编一段「学生写的答案」出来 ——
        // 那段文字会被当成学生自己写的填进作答框，然后拿去判定对错。
        throw badRequest('至少需要一张照片');
      }
      tagImages(ctx, images);

      /**
       * 题干与知识点**只是给模型的上下文**，用来把注意力收在这一道上：
       * 一张照片里常常还拍进了旁边几道题，不给范围的话模型可能把
       * 隔壁那题的解答一起转录进来 —— 而那会变成一个学生从没写过的答案。
       *
       * 两者都可选：拿不到就直说「未提供」，不要编一个。
       */
      const questionContent = optionalText(ctx.body, 'questionContent');
      const knowledgePoint = optionalText(ctx.body, 'knowledgePoint');

      const lines = [];
      if (knowledgePoint !== '') lines.push(`知识点：${knowledgePoint}`);
      if (questionContent !== '') lines.push(`这一题的题干：${questionContent}`);
      lines.push(
        '请只转录照片里**学生手写**的这一题解答。',
        '不要订正、不要补全、不要写解法；认不准就降低 confidence 并在 uncertain 里说明位置。',
      );

      return invoke(ctx, {
        kind: 'answerOcr',
        payload: {
          knowledgePoint,
          questionContent,
          images: fingerprint(images),
        },
        content: [
          { type: 'text', text: lines.join('\n') },
          ...images.parts,
        ],
      });
    },

    /**
     * 错题录入：把照片里的题目提取成结构化文本。
     *
     * 与 `homeworkCheck` 的区别不是「模型不同」，而是**问的问题不同**：
     * 那条问「哪几道做错了、错在哪」，这条只问「这上面写着什么」。
     * 学生主动提交错题时，对错已经由他自己定了，模型再判一遍会制造
     * 一个他无法反驳的拒绝 —— 手上明明有张打了叉的卷子，系统说「这题没错」。
     *
     * `hint` 是可选的范围限定（如「只取第 3 题」）：一张照片里常常
     * 拍进了相邻的几道题，不给范围时模型会把它们一起提出来。
     * 批量录入正好需要那个行为，单题录入则用它把范围收窄。
     */
    async extractMistakes(ctx) {
      const images = normalizeImages(ctx.body.images, config);
      if (images.parts.length === 0) {
        // 没有照片时「提取结果」只能是编的，而编出来的题会被录进错题库，
        // 之后被组卷重做、被生成变式题 —— 学生练的是一道不存在的题。
        throw badRequest('至少需要一张照片');
      }
      tagImages(ctx, images);

      const hint = optionalText(ctx.body, 'hint');
      const skipped = Math.max(0, Number(ctx.body.imagesSkipped ?? 0));
      const lines = [];
      if (hint !== '') lines.push(`这次只需要提取：${hint}`);
      if (skipped > 0) {
        // 丢图必须说出来。不说的话模型会对着半张卷子说「都在这里了」，
        // 而学生以为整页都录进去了 —— 少的那几道题永远补不回来。
        lines.push(
          `注意：另有 ${skipped} 张照片未能送达，你看到的可能不是全部题目；`
            + '不要因为没看到就推断「这一页只有这些题」。',
        );
      }
      lines.push('请提取这些照片里的题目。');

      return invoke(ctx, {
        kind: 'extractMistakes',
        payload: { hint, images: fingerprint(images) },
        content: [
          { type: 'text', text: lines.join('\n') },
          ...images.parts,
        ],
      });
    },

    /** 作业批改。 */
    async homeworkCheck(ctx) {
      const subject = requireText(ctx.body, 'subject');
      const title = requireText(ctx.body, 'title');
      const images = normalizeImages(ctx.body.images, config);
      tagImages(ctx, images);

      if (images.parts.length === 0) {
        // 没有照片的批改一定是编出来的。宁可明确报错让客户端走本地兜底，
        // 也不要让模型凭科目名猜一份错题明细出来 —— 那些错题会进错题库，
        // 然后被组卷、被打印、被当成真的错题练。
        throw badRequest('批改作业必须提供至少一张照片');
      }

      const skipped = Math.max(0, Number(ctx.body.imagesSkipped ?? 0));
      const lines = [
        `科目：${subject}`,
        `作业标题：${title}`,
        `本次共 ${images.parts.length} 张照片。`,
      ];
      if (skipped > 0) {
        lines.push(
          `注意：另有 ${skipped} 张照片未能送达，你看到的内容可能不完整；`
            + '看不清的题目请跳过，不要猜测后判错。',
        );
      }

      /**
       * 第一次：判分。含图的题会额外列进 figureQuestions（无论对错），
       * 下面交给复核再算一遍 —— 漏判恰恰发生在「模型认为对了」的时候。
       *
       * ⚠️ `schemaVersion` 是**缓存失效开关**，不是元数据。
       * 缓存键只认 payload，所以昨天「score=100、items 空」那些结论会一直命中，
       * 加了复核也永远跑不到（`figureQuestions` 在旧结果里根本不存在）。
       * 改一次批改口径就要动这个值一次，否则新逻辑对老照片无效。
       */
      const graded = await invoke(ctx, {
        kind: 'homeworkCheck',
        payload: {
          subject,
          title,
          images: fingerprint(images),
          schemaVersion: 'figure-verify-3',
        },
        content: [
          { type: 'text', text: `${lines.join('\n')}\n\n请批改。` },
          ...images.parts,
        ],
      });
      return reviewFigureAnswers(ctx, graded, images);
    },

    /** 单题判定。 */
    async reviewJudge(ctx) {
      const studentAnswer = optionalText(ctx.body, 'studentAnswer');
      const referenceAnswer = requireText(ctx.body, 'referenceAnswer');

      if (studentAnswer === '') {
        // 「没写答案」是规则一眼能定的，不需要花一次模型调用。
        // 这也和本地实现的行为一致：两条路径对同一份输入的结论必须一样，
        // 否则同一个学生用离线版和在线版会得到不同的判定。
        //
        // 不扣额度也不需要退款：扣费点在 invoke 里、紧贴模型调用，
        // 这条路径压根走不到那里。学生连点十次「提交」也不会掉一次额度。
        guard.audit({
          requestId: ctx.identity.requestId,
          studentId: ctx.identity.studentId,
          path: ctx.path,
          capability: 'reasoning',
          model: 'rule',
          ok: true,
          units: 0,
          note: '答案为空，规则直接判定，未调用模型',
        });
        ctx.modelInvoked = true; // 已在这里记过审计，路由不必补记
        return {
          data: {
            verdict: 'wrong',
            score: 0,
            comment: '没有填写答案，按未通过处理。先看一遍讲解，再做一轮。',
          },
          meta: { cached: false, model: 'rule', units: 0 },
        };
      }

      const lines = [
        `科目：${optionalText(ctx.body, 'subject') || '未指定'}`,
        `知识点：${optionalText(ctx.body, 'knowledgePoint') || '未指定'}`,
        `学生答案：${studentAnswer}`,
        `参考答案：${referenceAnswer}`,
      ];
      const questionContent = optionalText(ctx.body, 'questionContent');
      if (questionContent !== '') lines.push(`题干：${questionContent}`);

      return invoke(ctx, {
        kind: 'reviewJudge',
        payload: { studentAnswer, referenceAnswer, questionContent },
        content: `${lines.join('\n')}\n\n请判定这个答案是否正确。`,
      });
    },

    /** 错题讲解。 */
    async reviewExplain(ctx) {
      const subject = optionalText(ctx.body, 'subject') || '未指定';
      const knowledgePoint = requireText(ctx.body, 'knowledgePoint');
      const title = requireText(ctx.body, 'title');
      const wrongReason = optionalText(ctx.body, 'wrongReason');
      /**
       * 题目原文（可空：2026-10 之前入库的错题没有这一列）。
       *
       * `title` 是「作业标题 · 知识点」这样的**标签**，不是题目。
       * 拿它当题目发给模型的后果已经实测过：讲解读起来很顺，
       * 只是讲的是另一个东西 —— 而学生看不出来哪里不对。
       */
      const questionBody = optionalText(ctx.body, 'questionBody');
      /**
       * 参考答案与孩子当时写的过程。
       *
       * 讲解要能说出「你这一步错了」，前提是它知道正确答案是什么、
       * 孩子写了什么。只给一句题干时，模型只能回「方法没掌握」这类空话 ——
       * 2026-10-23 实测，学生两式都错，讲解却说「或者两个式子化简后其实
       * 相同」，因为它根本不知道孩子写了什么。
       */
      const referenceAnswer = optionalText(ctx.body, 'referenceAnswer');
      const studentProcess = optionalText(ctx.body, 'studentProcess');

      /**
       * 原题照片（可空）。有图必须走视觉档：
       * 「用不同的方法表示**下图**的面积」这句话里没有图，纯文本档只能
       * 凭想象讲。没有照片的错题仍然走纯文本档，不为一张不存在的图付 8 倍配额。
       */
      const images = normalizeImages(ctx.body.images, config);
      tagImages(ctx, images);
      const withFigure = images.parts.length > 0;

      const lines = [`科目：${subject}`, `知识点：${knowledgePoint}`];
      if (questionBody !== '') {
        lines.push(`题目原文：\n${questionBody}`);
        // 标题降级成来源标签。放在题干后面，免得模型把它当成题目的一部分。
        if (title !== '' && title !== questionBody) lines.push(`来源：${title}`);
      } else {
        lines.push(`题目：${title}`);
      }
      if (wrongReason !== '') lines.push(`学生这次的错误：${wrongReason}`);
      if (referenceAnswer !== '') lines.push(`参考答案：${referenceAnswer}`);
      if (studentProcess !== '') lines.push(`学生当时写的内容：\n${studentProcess}`);
      if (withFigure) lines.push('（附一张原题照片，题目里说的「下图」就是它。）');

      const prompt = `${lines.join('\n')}\n\n请讲解这道题。`;

      return invoke(ctx, {
        kind: withFigure ? 'reviewExplainFigure' : 'reviewExplain',
        /**
         * `questionBody` 必须进指纹：不同题干的讲解不能被缓存命中同一条，
         * 否则学生看到的是另一道题的解法，而且看起来完全正常。
         *
         * `schemaVersion` 是**缓存失效开关**：缓存键只认 payload，
         * 所以「只有题干」时代存下来的那些通用讲解会一直命中，
         * 加了图和答案也永远走不到。改一次讲解口径就要动这个值一次。
         */
        payload: {
          subject,
          knowledgePoint,
          title,
          wrongReason,
          questionBody,
          referenceAnswer,
          studentProcess,
          schemaVersion: 'explain-figure-1',
          ...(withFigure ? { images: fingerprint(images) } : {}),
        },
        content: withFigure
          ? [{ type: 'text', text: prompt }, ...images.parts]
          : prompt,
      });
    },

    /**
     * 讲解配图：先判「这题该不该画」，该画才给坐标。
     *
     * ## 为什么「不画」也要走一次模型
     *
     * 判「该不该画」是教学判断，不是客户端能靠规则做的事：
     * 「数轴上的距离」和「幂的运算」在结构上都是「一道填空」，
     * 但一个画出来才有用、另一个画出来纯属添乱。把这条判断放在客户端
     * 只能靠知识点名硬编码，而知识点名是模型自己写的、随时会变。
     *
     * ## 为什么校验在服务端
     *
     * 与举一反三共用 `normalizeFigure`：长度对不上的尺寸标注、悬空的点名、
     * 超范围坐标，任一处不成立就**整张丢掉**（半张图比没有图更误导，
     * 学生会以为「没标的那条边就是没有长度」）。
     * 丢掉之后仍然返回 200，只是 `draw=false` 并带上原因 ——
     * 这是**正当结论**，不该让学生看到一个报错框。
     */
    async reviewFigure(ctx) {
      const subject = optionalText(ctx.body, 'subject') || '未指定';
      const knowledgePoint = requireText(ctx.body, 'knowledgePoint');
      const title = optionalText(ctx.body, 'title');
      const questionBody = optionalText(ctx.body, 'questionBody');
      const wrongReason = optionalText(ctx.body, 'wrongReason');
      const referenceAnswer = optionalText(ctx.body, 'referenceAnswer');
      const studentProcess = optionalText(ctx.body, 'studentProcess');

      const images = normalizeImages(ctx.body.images, config);
      const withPhoto = images.parts.length > 0;
      if (withPhoto) tagImages(ctx, images);

      const lines = [`科目：${subject}`, `知识点：${knowledgePoint}`];
      if (questionBody !== '') {
        lines.push(`题目原文：\n${questionBody}`);
        if (title !== '' && title !== questionBody) lines.push(`来源：${title}`);
      } else if (title !== '') {
        lines.push(`题目：${title}`);
      }
      if (wrongReason !== '') lines.push(`学生这次的错误：${wrongReason}`);
      if (referenceAnswer !== '') lines.push(`参考答案：${referenceAnswer}`);
      if (studentProcess !== '') lines.push(`学生当时写的内容：\n${studentProcess}`);
      // 明确告诉模型「照片是原题」，否则它会把照片当成学生作答的照片，
      // 去批改一道已经批过的题。
      if (withPhoto) lines.push('（附一张原题照片，题目说的「下图」就是它。）');

      const prompt = `${lines.join('\n')}\n\n这题要不要配一张图？请按要求输出。`;

      const result = await invoke(ctx, {
        kind: withPhoto ? 'reviewFigurePhoto' : 'reviewFigure',
        payload: {
          subject,
          knowledgePoint,
          title,
          questionBody,
          referenceAnswer,
          studentProcess,
          /**
           * `schemaVersion` 是缓存失效开关。缓存键只认 payload，
           * 改一次配图口径就要动这个值一次 —— 否则老结果永远命中，
           * 新口径在用户那儿一次都不生效。
           *
           * ⚠️ `wrongReason` 刻意**不进**指纹：它随每次作答变，
           * 会让同一道题的图反复重算。而图取决于题目本身，与孩子这次
           * 错在哪无关 —— 错因只影响 reason 那句话，不影响坐标。
           */
          schemaVersion: 'figure-3',
          ...(withPhoto ? { images: fingerprint(images) } : {}),
        },
        content: withPhoto
          ? [{ type: 'text', text: prompt }, ...images.parts]
          : prompt,
      });

      return { ...result, data: normalizeFigureResult(result.data) };
    },

    /**
     * 举一反三出题 / 取参考答案。
     *
     * 两条用途共用一个端点：它们要的是同一份「知识点画像」，
     * 为一个知识点分别发两次请求，等于把输入 token 付两遍。
     *
     * ## 为什么带不带照片是两条路径
     *
     * 只传知识点名时，模型根本不知道原题长什么样。实测（2026-10-23）：
     * 用「几何图形面积」调这条端点，回来的是「长方形长 8 宽 5」「三角形底 6
     * 高 4」—— 模型在**主动避开需要配图的题**，因为它画不出来，也知道自己
     * 画不出来。学生看到的就是「举一反三只会出纯文字题」。
     *
     * 带照片时走视觉档，模型能看清图形结构，才可能出同类型的图形题。
     * 两条都不丢：历史错题和手工录入的错题没有照片，不该为一张不存在的图
     * 付视觉档的价钱（配额权重差 8 倍）。
     */
    async reviewPractice(ctx) {
      const subject = optionalText(ctx.body, 'subject') || '未指定';
      const knowledgePoint = requireText(ctx.body, 'knowledgePoint');
      const difficulty = optionalText(ctx.body, 'difficulty') || '基础';
      const onlyReference = ctx.body.want === 'referenceAnswer';
      const requested = Number.parseInt(ctx.body.count ?? 3, 10);
      const count = onlyReference
        ? 0
        : Math.min(Math.max(Number.isFinite(requested) ? requested : 3, 1), 5);

      // 取参考答案时不需要图：那条路只要一句通用要点，看图只会让模型
      // 把注意力从「这一类题怎么做」挪到「这一道题的数值是多少」。
      const images = onlyReference
        ? { parts: [], imageCount: 0, totalBytes: 0 }
        : normalizeImages(ctx.body.images, config);
      const hasImages = images.parts.length > 0;
      if (hasImages) tagImages(ctx, images);

      const lines = [
        `科目：${subject}`,
        `知识点：${knowledgePoint}`,
      ];
      if (onlyReference) {
        lines.push(
          '只需要 referenceAnswer（该知识点的参考答案或通用解题要点）。'
            + 'questions 请返回空数组。拿不准具体数值时给通用解题步骤，不要编造具体答案。',
        );
      } else {
        lines.push(
          `难度：${difficulty}`,
          `题量：${count}`,
        );
        lines.push(
          hasImages
            ? '这是原题照片。请出同类型的变式题：考点与**图形结构**相同，数值或字母不同。'
            : '请出同类型的变式题，考点相同、数字与情境不同（没有原题照片，按知识点出）。',
        );
      }

      const question = `${lines.join('\n')}\n\n请按上面的要求输出。`;
      const result = await invoke(ctx, {
        kind: hasImages ? 'reviewPracticeFigure' : 'reviewPractice',
        payload: {
          subject,
          knowledgePoint,
          difficulty,
          count,
          onlyReference,
          ...(hasImages ? { images: fingerprint(images) } : {}),
        },
        content: hasImages
          ? [{ type: 'text', text: question }, ...images.parts]
          : question,
      });

      if (onlyReference) return result;

      const pruned = prunePractice(result.data);
      return {
        ...result,
        data: pruned.data,
        meta: {
          ...result.meta,
          keptQuestions: pruned.data.questions.length,
          rejected: pruned.rejected,
        },
      };
    },

    /**
     * 每日概念打卡：按知识点出几道**可本地判分**的短题。
     *
     * ## 为什么判分不在这里
     *
     * 判分由 App 本地做确定性比对。模型只负责**出题**，一旦让模型顺带判分，
     * 等价写法（`0.5` / `1/2`）就会被判错 —— 做对的学生看到「错了」，
     * 而且没有任何报错可查（B29 就是这么踩的）。
     *
     * ## 为什么答案要下发给客户端
     *
     * 这是**刻意的**取舍：本轮打卡是「家长发起、学生自己练」，不是考试，
     * 作弊不是要防的主要风险；而把答案留在服务端就得为判分再走一次网络，
     * 弱网下学生会卡在「已提交，等待判分」—— 这套闭环里最不值的一次等待。
     * 真正的考试形态要另做一套（答案不下发、服务端判分），不在这里省这一步。
     *
     * ## 输入契约
     *
     * `items[]` 每项 `{ knowledge, wrongCount?, wrongReason? }` —— 由客户端从
     * 本地错题库聚合后上传。服务端不复用错题表，是因为「错题在本地还是云端」
     * 因用户而异（有人根本没连云端），而**知识点列表是客户端当下最清楚的东西**。
     */
    async checkinGenerate(ctx) {
      const subject = optionalText(ctx.body, 'subject') || '未指定';
      const raw = ctx.body.items;
      if (!Array.isArray(raw) || raw.length === 0) {
        throw badRequest('items 应为非空数组（每项至少要有 knowledge）');
      }
      if (raw.length > MAX_CHECKIN_ITEMS) {
        throw badRequest(`单次最多覆盖 ${MAX_CHECKIN_ITEMS} 个知识点`);
      }

      const text = (v) => (v === undefined || v === null ? '' : String(v).trim());
      const points = [];
      for (const item of raw) {
        if (!item || typeof item !== 'object') continue;
        const knowledge = text(item.knowledge);
        if (knowledge === '') continue;
        const wrongCount = Number.parseInt(item.wrongCount ?? 0, 10);
        points.push({
          knowledge,
          wrongCount: Number.isFinite(wrongCount) && wrongCount > 0 ? wrongCount : 0,
          // 错因是自由文本，历史数据里可能是整段作文。它只是让题更贴的佐料。
          reason: text(item.wrongReason).slice(0, 60),
        });
      }
      if (points.length === 0) throw badRequest('items 里没有一条带 knowledge 的项');

      const requested = Number.parseInt(ctx.body.count ?? 5, 10);
      const count = Math.min(Math.max(Number.isFinite(requested) ? requested : 5, 1), 10);

      // 空串 = 没要求（学生自己发起时走这条）。非空就必须是白名单里的词：
      // 放行一个模型看不懂的「中等」，它会按自己的理解出题，而家长
      // 以为自己的设定生效了 —— 没有任何地方会报错。
      const difficulty = optionalText(ctx.body, 'difficulty');
      if (difficulty !== '' && !CHECKIN_DIFFICULTIES.includes(difficulty)) {
        throw badRequest(
          `difficulty 只能是 ${CHECKIN_DIFFICULTIES.join(' / ')} 之一（收到「${difficulty}」）`,
        );
      }

      const lines = [`科目：${subject}`, `题量：${count}`];
      if (difficulty !== '') lines.push(`难度：${difficulty}`);
      lines.push('', '知识点（越靠前越需要考）：');
      points.forEach((point, index) => {
        const parts = [`${index + 1}. ${point.knowledge}`];
        if (point.wrongCount > 0) parts.push(`（累计错 ${point.wrongCount} 次）`);
        if (point.reason !== '') parts.push(`错因：${point.reason}`);
        lines.push(parts.join(''));
      });
      lines.push('', '请只从上面这些知识点里出题，knowledge 一字不差地照抄。');

      const result = await invoke(ctx, {
        kind: 'checkinGenerate',
        payload: { subject, count, difficulty, points },
        content: `${lines.join('\n')}\n\n请按上面的要求输出。`,
      });

      const pruned = pruneCheckinQuestions(result.data, {
        fallbackKnowledge: points[0].knowledge,
      });
      if (pruned.data.questions.length === 0) {
        // 一条能用的都没有 ⇒ 这是模型违约，不是「今天没题」。
        // 必须报出来：客户端会退回本地题库，而服务端要能看见模型在乱给。
        throw schemaViolation(
          pruned.rejected.length > 0 ? pruned.rejected : ['模型没有返回任何可用题目'],
        );
      }

      return {
        ...result,
        data: pruned.data,
        meta: {
          ...result.meta,
          keptQuestions: pruned.data.questions.length,
          rejected: pruned.rejected,
        },
      };
    },

    /**
     * 错题库 → 知识点提示（一句话）。
     *
     * ## 为什么要服务端先做一次去重与截断
     *
     * 客户端已经按知识点聚合过一遍，但这份契约**不能依赖客户端守规矩**：
     * 一个知识点重复出现三条，模型就会把同一条提示写三遍，学生在计时页
     * 连点三次「换一条」看到的还是同一句话 —— 看起来像轮换坏了。
     *
     * 截断的是 `wrongReason`：它是自由文本，历史数据里可能有整段作文。
     * 它只是让提示更贴题的佐料，不是主体，超过 60 字的部分对判断没有帮助。
     */
    async reviewTips(ctx) {
      const subject = optionalText(ctx.body, 'subject') || '未指定';
      const raw = ctx.body.items;
      if (!Array.isArray(raw) || raw.length === 0) {
        throw badRequest('items 应为非空数组');
      }
      if (raw.length > MAX_TIP_ITEMS) {
        throw badRequest(`单次最多归纳 ${MAX_TIP_ITEMS} 个知识点`);
      }

      // 按知识点合并：同一知识点出现多次时保留「错得最多」的那条。
      const merged = new Map();
      raw.forEach((item, index) => {
        if (typeof item !== 'object' || item === null || Array.isArray(item)) {
          throw badRequest(`items[${index}] 应为对象`);
        }
        const knowledgePoint = String(item.knowledgePoint ?? '').trim();
        if (knowledgePoint === '') {
          throw badRequest(`items[${index}].knowledgePoint 不能为空`);
        }
        const wrongCount = Math.max(0, Math.trunc(Number(item.wrongCount ?? 0)) || 0);
        const wrongReason = String(item.wrongReason ?? '').trim().slice(0, 60);
        const existing = merged.get(knowledgePoint);
        if (!existing || wrongCount > existing.wrongCount) {
          merged.set(knowledgePoint, { knowledgePoint, wrongCount, wrongReason });
        }
      });

      const items = [...merged.values()];
      const lines = items.map((item) => {
        const parts = [`知识点：${item.knowledgePoint}`];
        if (item.wrongCount > 0) parts.push(`累计错 ${item.wrongCount} 次`);
        if (item.wrongReason !== '') parts.push(`最近一次错因：${item.wrongReason}`);
        return parts.join('｜');
      });

      return invoke(ctx, {
        kind: 'reviewTips',
        payload: { subject, items },
        content: [
          `科目：${subject}`,
          `这个学生的错题库里有 ${items.length} 个知识点：`,
          ...lines,
          '',
          '请按上面的要求，给其中 3-6 个知识点各写一句话提示。',
        ].join('\n'),
      });
    },

    /**
     * 语音合成（伴读）：一段文字 → 一组 mp3 地址。
     *
     * ## 为什么它必须存在
     *
     * 学生那台机器是鸿蒙 NEXT + 卓易通。鸿蒙自家的朗读能力（CoreSpeechKit）
     * 只给 ArkTS 原生应用，而卓易通没有实现安卓的 `TextToSpeechService` ——
     * 端上 `TextToSpeech` 这条路在那台机器上**根本不存在**，`speak()` 会
     * 卡十几秒然后超时。所以只能把「出声」这件事搬到服务端。
     *
     * ## 为什么不占 AI 配额
     *
     * 配额是按模型调用的成本权重记的（`CAPABILITY_BY_KIND`），这里没有档位。
     * 硬造一个档位就要同时改客户端的额度提示，而伴读的频率远低于批改
     * （一天几次），按字符计费的成本可以忽略。
     * **但字数上限必须有** —— 没有上限，一条请求就能把整本书合成一遍。
     *
     * ## 为什么返回多段
     *
     * 厂商单次上限 600 字符，切段是硬约束而不是优化。客户端按顺序播，
     * 段间自然有极短的间隙，听感上更像换气。
     */
    async tts(ctx) {
      const text = String(ctx.body?.text ?? '').trim();
      if (text === '') throw badRequest('text 不能为空');
      // 只认 en / zh：厂商的 language_type 是个闭集，猜错的后果是
      // 英文课文被当作中文、按拼音念出来（有声音，但完全听不懂）。
      const language = ctx.body?.language === 'en' ? 'en' : 'zh';
      const settings = config.tts ?? {};
      if (settings.enabled === false) {
        throw new GatewayError(
          ErrorCodes.modelNotEnabled,
          '语音合成已关闭（BAILIAN_TTS_ENABLED=0）',
          { status: 503, retryable: false },
        );
      }

      const data = await synthesizeTts({
        text,
        language,
        // 11-08 起客户端会显式带 `voice: 'Cherry'`（女声）：伴读约定是
        // 「男声 = 本机直连 / 女声 = 云端 Qwen 兜底」，不能让网关的
        // BAILIAN_TTS_VOICE 覆盖项把这条兜底改成男声。
        // 仍保留 settings.voice 作为老客户端 / 其它调用方的默认。
        voice: optionalText(ctx.body, 'voice') || settings.voice,
        apiKey: settings.apiKey,
        baseUrl: settings.baseUrl,
        model: settings.model,
      });

      // 不计额度也要留一条：不然「谁把整本书念了一遍」在审计里查不到。
      guard.audit({
        requestId: ctx.identity.requestId,
        studentId: ctx.identity.studentId,
        path: ctx.path,
        capability: null,
        model: data.model,
        ok: true,
        units: 0,
        note: `tts ${data.characters} 字 / ${data.segments.length} 段`,
      });

      return {
        data,
        meta: {
          provider: 'bailian',
          characters: data.characters,
          segmentCount: data.segments.length,
        },
      };
    },

    /**
     * 批量取参考答案。
     *
     * 与 `reviewPractice`（`want: 'referenceAnswer'`）的区别是**一次多条**：
     * 组卷要冻结一页题目的答案，逐题请求会让输入 token 与延迟都线性放大。
     */
    async reviewReferenceBatch(ctx) {
      const items = ctx.body.items;
      if (!Array.isArray(items) || items.length === 0) {
        throw badRequest('items 应为非空数组');
      }
      if (items.length > config.maxReferenceBatch) {
        throw badRequest(`单次最多批量取 ${config.maxReferenceBatch} 条参考答案`);
      }

      const normalized = items.map((item, index) => {
        if (typeof item !== 'object' || item === null || Array.isArray(item)) {
          throw badRequest(`items[${index}] 应为对象`);
        }
        const knowledgePoint = String(item.knowledgePoint ?? '').trim();
        if (knowledgePoint === '') {
          throw badRequest(`items[${index}].knowledgePoint 不能为空`);
        }
        return {
          index,
          subject: String(item.subject ?? '').trim() || '未指定',
          knowledgePoint,
          questionTitle: String(item.questionTitle ?? '').trim(),
        };
      });

      const lines = normalized.map((item) => {
        const parts = [`${item.index}. 科目：${item.subject}`, `知识点：${item.knowledgePoint}`];
        if (item.questionTitle !== '') parts.push(`题目：${item.questionTitle}`);
        return parts.join('｜');
      });

      return invoke(ctx, {
        kind: 'reviewReferenceBatch',
        payload: { items: normalized },
        content: [
          `共有 ${normalized.length} 条，请逐条给出参考答案：`,
          ...lines,
          '',
          '请按 index 逐条输出，不要重排、不要漏项。',
        ].join('\n'),
      });
    },

    /** 签发图片上传位置。 */
    uploadsSign(ctx) {
      const body = uploads.sign(ctx.body.files, ctx.identity);
      return {
        data: {
          ...body,
          // 回传客户端的 `uploads[].storageKey` 原样保留，
          // 客户端靠它把「云端的图」和「本地那张」对上。
          uploads: body.uploads.map((item) => ({
            storageKey: item.storageKey,
            uploadUrl: item.uploadUrl,
            objectUrl: item.objectUrl,
            contentType: item.contentType,
            headers: item.headers,
            expiresIn: item.expiresIn,
          })),
        },
        meta: {},
      };
    },

    /**
     * 用量与成本看板的数据。
     *
     * 不算配额：看板是运维动作，不该消耗学生额度 —— 而且它本身不调模型。
     *
     * 口令是可选的（`AI_METRICS_TOKEN`）。没配时依赖常规身份校验：
     * 本地与内网够用，**公网部署必须配**（否则任何能调接口的人都能看到
     * 这套系统一天跑多少量）。这与 `/ai/health` 不同：health 只报能力开关，
     * 是给监控探活用的，里面没有任何用量数据。
     */
    metricsSnapshot(ctx) {
      if (config.metrics.token !== '') {
        const supplied = String(
          ctx.headers?.['x-metrics-token'] ?? ctx.headers?.['X-Metrics-Token'] ?? '',
        );
        if (supplied !== config.metrics.token) {
          throw unauthorized('看板口令不正确（需要 X-Metrics-Token）');
        }
      }
      return { data: metrics.snapshot(), meta: {} };
    },
  };
}

/** 把图片统计挂到上下文上，供审计使用。 */
function tagImages(ctx, images) {
  ctx.imageCount = images.imageCount;
  ctx.imageBytes = images.totalBytes;
}

/** 题干里出现这些词，说明这道题**离开图就没法做**。 */
const MENTIONS_FIGURE = /如图|下图|上图|图中|图示/;

/**
 * 出好的练习题过一遍「能不能信」。
 *
 * ## 三档处置，不是两档
 *
 * | 情况 | 处置 | 为什么 |
 * |---|---|---|
 * | 图能画、答案也验过 | 保留带图 | — |
 * | 图坏了，题干不依赖图 | **只丢图，保留题** | 纯文字题丢了图也能做 |
 * | 图坏了，题干写着「如图」 | **整题丢** | 一句「如图，在△ABC 中…」配一张不存在的图，学生连题都读不懂 |
 * | 答案验算不过 | **整题丢** | 错的参考答案会把做对的学生判成错的 |
 *
 * 第四档是这套东西存在的理由。实测（2026-10-23）模型把 `nm` 写成 `nq`，
 * 算出 1 而图形面积是 11 —— 那道题如果发下去，学生做对了会被判错。
 *
 * ## 为什么「验不了」不丢
 *
 * 验不了 ≠ 错。没有尺寸标注、题干不问面积周长的题（证明题、角度题）本来
 * 就无从验算，把它们全丢掉会让举一反三只剩面积题。这里的态度是：
 * **有证据说它错，才丢。**
 */
/**
 * 打卡题目的守卫：**模型给了不算数，能被本地判分才算数**。
 *
 * 与 `prunePractice` 的分工不同：那边只管配图，题的内容照单全收（因为
 * 那边有模型/人工参与判分，题干写歪了顶多是道怪题）。
 * 这边判分完全靠本地比对，所以每一条都要能被机械验证：
 *
 *   · 题型必须是 choice / judge —— 别的题型本地判不了；
 *   · choice 的答案必须是**存在的选项字母**（`E` 落在四选一里就是死题：
 *     学生永远选不对，而且他会以为是自己错了）；
 *   · judge 的答案必须能归一成 T/F，options 一律被**覆盖**成
 *     ["正确","错误"]，防止模型写成 ["对","错","不一定"] 漏到界面；
 *   · 单条坏题只丢它自己，不拖垮整批 —— 今天少一道题也比没打卡好。
 */
function pruneCheckinQuestions(raw, { fallbackKnowledge = '通用' } = {}) {
  const list = Array.isArray(raw?.questions) ? raw.questions : [];
  const letters = ['A', 'B', 'C', 'D', 'E', 'F'];
  const trueWords = new Set(['T', 'TRUE', '对', '正确', '√', 'V', 'YES', 'Y']);
  const falseWords = new Set(['F', 'FALSE', '错', '错误', '×', 'X', 'NO', 'N']);
  const kept = [];
  const rejected = [];
  const textOf = (v) => (v === undefined || v === null ? '' : String(v).trim());
  const brief = (stem) => (stem.length > 14 ? `${stem.slice(0, 14)}…` : stem || '(无题干)');

  for (const item of list) {
    if (!item || typeof item !== 'object') continue;

    const stem = textOf(item.stem);
    if (stem === '') {
      rejected.push('有一条缺题干，已丢弃');
      continue;
    }

    const knowledge = textOf(item.knowledge) || fallbackKnowledge;
    const analysis = textOf(item.analysis).slice(0, 80);
    const type = item.type === 'judge' ? 'judge' : item.type === 'choice' ? 'choice' : '';

    if (type === '') {
      rejected.push(`${brief(stem)}：题型不是 choice/judge，已丢弃`);
      continue;
    }

    const withExtras = (base) =>
      analysis === '' ? base : { ...base, analysis };

    if (type === 'judge') {
      const rawAnswer = textOf(item.answer);
      const upper = rawAnswer.toUpperCase();
      const isTrue = trueWords.has(upper) || trueWords.has(rawAnswer);
      const isFalse = falseWords.has(upper) || falseWords.has(rawAnswer);
      if (!isTrue && !isFalse) {
        rejected.push(`${brief(stem)}：判断题答案「${rawAnswer}」无法识别，已丢弃`);
        continue;
      }
      kept.push(
        withExtras({
          type: 'judge',
          stem,
          // 覆盖而不是沿用：模型给的选项措辞不该决定界面长什么样。
          options: ['正确', '错误'],
          answer: isTrue ? 'T' : 'F',
          knowledge,
        }),
      );
      continue;
    }

    const options = Array.isArray(item.options)
      ? item.options.map(textOf).filter((o) => o !== '')
      : [];
    if (options.length < 2) {
      rejected.push(`${brief(stem)}：选择题选项不足 2 个，已丢弃`);
      continue;
    }

    const rawAnswer = textOf(item.answer);
    const matched = rawAnswer.toUpperCase().match(/[A-F]/);
    const letter = matched ? matched[0] : '';
    if (letter === '') {
      rejected.push(`${brief(stem)}：答案「${rawAnswer}」不是选项字母，已丢弃`);
      continue;
    }
    if (letters.indexOf(letter) >= options.length) {
      rejected.push(
        `${brief(stem)}：答案 ${letter} 超出选项数（${options.length}），已丢弃`,
      );
      continue;
    }

    kept.push(
      withExtras({ type: 'choice', stem, options, answer: letter, knowledge }),
    );
  }

  return {
    data: { questions: kept },
    // 只留前 5 条：再多就是噪音，而它会跟着响应回到客户端。
    rejected: rejected.slice(0, 5),
  };
}

function prunePractice(raw) {
  const questions = Array.isArray(raw?.questions) ? raw.questions : [];
  const kept = [];
  const rejected = [];

  for (const item of questions) {
    if (!item || typeof item !== 'object') continue;
    const next = { ...item };

    if (next.figure === undefined || next.figure === null) {
      kept.push(next);
      continue;
    }

    const normalized = normalizeFigure(next.figure);
    if (normalized.figure === null) {
      const why = normalized.rejected.join('；');
      if (MENTIONS_FIGURE.test(String(next.content ?? ''))) {
        rejected.push(`${next.title ?? '(未命名)'}：图作废（${why}），题干依赖图形，整题丢弃`);
        continue;
      }
      rejected.push(`${next.title ?? '(未命名)'}：图作废（${why}），已退回纯文字`);
      delete next.figure;
      kept.push(next);
      continue;
    }

    const verdict = verifyFigureAnswer({
      figure: normalized.figure,
      answer: String(next.answer ?? ''),
      stem: String(next.content ?? ''),
    });
    if (verdict.verdict === false) {
      rejected.push(`${next.title ?? '(未命名)'}：${verdict.reason}，整题丢弃`);
      continue;
    }

    next.figure = normalized.figure;
    kept.push(next);
  }

  return {
    data: { questions: kept, referenceAnswer: raw?.referenceAnswer ?? '' },
    // 只留前 5 条：再多就是噪音，而它会跟着响应回到客户端。
    rejected: rejected.slice(0, 5),
  };
}

/**
 * 讲解配图的归一化：把「模型说了什么」变成「客户端能画什么」。
 *
 * 三种结果都返回 200，因为**「不画」不是失败**：
 * · `draw=false, rejected='model_declined'` —— 模型自己判断不该画（最常见）
 * · `draw=false, rejected='figure_invalid'` —— 模型画了，但图对不上（标注长度
 *   与边长不符、点名悬空…）。这种情况下 reason 里要**说人话**，不能把
 *   `normalizeFigure` 的内部术语直接甩给学生。
 * · `draw=true` —— 带 figure 走。
 *
 * ⚠️ 绝不能把 `figure_invalid` 悄悄当成 `model_declined`：前者是「模型
 * 出了错」，后者是「这道题本来就没图」。两者都表现为「没图」，
 * 但前者会重试、后者不会 —— 混在一起就再也发现不了配图质量在下滑。
 */
export function normalizeFigureResult(raw) {
  const value = raw && typeof raw === 'object' ? raw : {};
  const reason = optionalText(value, 'reason');

  if (value.draw !== true) {
    return {
      draw: false,
      reason: reason || '这道题用式子讲更清楚，不需要配图。',
      rejected: 'model_declined',
    };
  }

  const normalized = normalizeFigure(value.figure);
  if (normalized.figure === null) {
    return {
      draw: false,
      reason: '这张图没画对（标注与图形对不上），改用文字讲。',
      rejected: 'figure_invalid',
      // 内部原因留在细节里，方便排查配图质量；界面只显示上面那句话。
      detail: normalized.rejected.slice(0, 3).join('；'),
    };
  }

  return {
    draw: true,
    reason: reason || '对照这张图看上面的步骤。',
    caption: optionalText(value, 'caption'),
    figure: normalized.figure,
  };
}

/**
 * 缓存指纹。
 *
 * 用「张数 + 总字节 + 每张的 base64 摘要前缀」而不是完整 base64：
 * 完整内容进缓存键等于把 3MB 的照片又存了一份，
 * 而 SHA-256 算在 3MB 上本身也要花掉几毫秒 —— 这两笔开销都会落在
 * 「学生点提交后等着看结果」这段最敏感的等待里。
 */
function fingerprint(images) {
  return images.parts.map((part) => {
    const url = part.image_url?.url ?? '';
    const isData = url.startsWith('data:');
    return {
      kind: isData ? 'inline' : 'url',
      size: isData ? url.length : 0,
      // 取头部与尾部各 24 个字符，够区分不同照片，又便宜。
      head: url.slice(0, 24),
      tail: url.slice(-24),
    };
  });
}

function requireText(body, key) {
  const value = optionalText(body, key);
  if (value === '') throw badRequest(`${key} 不能为空`);
  return value;
}

function optionalText(body, key) {
  const value = body?.[key];
  if (value === undefined || value === null) return '';
  if (typeof value !== 'string') throw badRequest(`${key} 应为字符串`);
  return value.trim();
}
