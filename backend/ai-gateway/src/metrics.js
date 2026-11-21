import { pricingState } from './config.js';

/**
 * 用量与成本聚合。
 *
 * ## 数据来源是审计事件，不是另开一条埋点
 *
 * 每次调用都会经 `guard.audit()` 记一条结构化事件；本模块只做聚合。
 * 好处是**只有一处真相**：审计里看到的和看板上看到的一定一致。
 * 如果看板单独埋点，两套数字迟早会分叉，而分叉时你无法判断哪套是对的。
 *
 * ## 关于「成本」的三条诚实规则
 *
 * 1. **没配单价就报 `cost: null`**，不拿设计文档里的估算值冒充实际成本。
 *    估算写在文档里说明「数量级」，看板上报出来就会被当成账。
 * 2. **有调用没返回 `usage` 时，成本是下限**（`costIsLowerBound: true`）。
 *    模型厂商可能在某些响应里省略 usage，此时 token 数无从得知 ——
 *    如果不说，看板会安静地少报，而且少报多少完全不可见。
 * 3. **缓存命中不计成本**（没有 token 消耗），但**计入调用次数**。
 *    这两件事分开报，才能回答「省了多少」。
 *
 * ## 口径是单实例
 *
 * 见 config.js 里 `metrics` 的说明：响应里带 `scope: 'instance'`，
 * 调用方（看板）必须如实展示，不能拿它当全局数字。
 */
export function createMetrics({ config, now = () => Date.now() } = {}) {
  const startedAt = now();

  /** 一个空的计数桶。 */
  function emptyBucket() {
    return {
      calls: 0,
      /** 真正调了模型的次数（不含缓存命中与规则短路）。 */
      modelCalls: 0,
      cached: 0,
      /** 规则直接给出结论、没调模型的次数。 */
      ruleCalls: 0,
      failed: 0,
      /** 实际扣掉的额度单位。 */
      units: 0,
      tokensIn: 0,
      tokensOut: 0,
      /** 调了模型但响应里没有 usage 的次数。成本会因此变成下限。 */
      usageMissing: 0,
      images: 0,
      imageBytes: 0,
    };
  }

  const totals = emptyBucket();
  const byCapability = new Map();
  const byPath = new Map();
  const byCode = new Map();
  /** 最近若干次延迟样本（毫秒）。 */
  let latencies = [];

  function bucketOf(map, key) {
    const name = key ?? 'unknown';
    let bucket = map.get(name);
    if (!bucket) {
      bucket = emptyBucket();
      // 高基数防护：路径与错误码理论上可控，但能力维度一旦被写成
      // 「把学生 ID 拼进去」就会无限增长，所以在入口处设上限。
      if (map.size < (config.metrics?.maxDimensions ?? 40)) {
        map.set(name, bucket);
      } else {
        return null;
      }
    }
    return bucket;
  }

  function accumulate(bucket, record) {
    if (!bucket) return;
    bucket.calls++;
    bucket.units += record.units ?? 0;
    bucket.images += record.imageCount ?? 0;
    bucket.imageBytes += record.imageBytes ?? 0;

    const isCache = record.model === 'cache' || record.cached === true;
    const isRule = record.model === 'rule';

    if (!record.ok) {
      bucket.failed++;
      return;
    }
    if (isCache) {
      bucket.cached++;
      return;
    }
    if (isRule) {
      bucket.ruleCalls++;
      return;
    }
    // 走到这里说明确实调了模型。`model` 为空说明这条记录不是模型调用
    // （例如配额降级、参数校验失败），不算模型用量。
    if (!record.model) return;
    bucket.modelCalls++;
    if (record.tokens) {
      bucket.tokensIn += record.tokens.in ?? 0;
      bucket.tokensOut += record.tokens.out ?? 0;
    } else {
      // 有模型调用却没有 usage —— 必须单独计数，否则成本会被静默低估。
      bucket.usageMissing++;
    }
  }

  return {
    /** 记一条审计事件。绝不抛错：聚合失败不该影响正在进行的业务调用。 */
    record(event) {
      try {
        accumulate(totals, event);

        /**
         * 能力维度只装「真的属于某一级能力」的事件。
         *
         * 鉴权失败、参数不合法这类审计没有能力档位。把它们塞进一个
         * `unknown` 桶会有两个后果：看板多出一行没有意义的 unknown，
         * 而它的单价永远配不出来 —— 于是 `totals.cost` 被判成
         * 「算不全」而整体置空。明明一次模型都没调，成本却变成未知。
         * 这类事件在 `totals` 与 `byCode` 里照样看得到，不会丢。
         */
        if (event.capability) accumulate(bucketOf(byCapability, event.capability), event);

        // 路径桶带上能力档位：路径到能力是多对一（一个路径只归属一档），
        // 但看板上「哪条路最贵」必须配合档位才解释得通 ——
        // 只报单位数，读者不知道 8 个单位算贵还是便宜。
        const pathBucket = bucketOf(byPath, event.path);
        if (pathBucket && event.capability) pathBucket.capability = event.capability;
        accumulate(pathBucket, event);

        if (event.code) {
          byCode.set(event.code, (byCode.get(event.code) ?? 0) + 1);
        }
        if (typeof event.latencyMs === 'number') {
          latencies.push(event.latencyMs);
          const cap = config.metrics?.latencySamples ?? 500;
          if (latencies.length > cap) latencies = latencies.slice(-cap);
        }
      } catch {
        // 聚合是旁路。它出错时正确的行为是「少一份统计」，
        // 而不是让学生的批改请求失败。
      }
    },

    /** 当前快照。看板直接渲染它。 */
    snapshot() {
      const priceState = pricingState(config);
      const capabilities = [...byCapability.entries()].map(([name, bucket]) => ({
        capability: name,
        ...bucket,
        cost: costOf(config, name, bucket),
      }));

      // 总成本 = 逐级求和。**不能**把三级的 token 加起来乘一个价：
      // 三级单价不同，那样算出来的数没有意义。
      // 有一级算不出来（单价没配）时，总计也置空 —— 报一个「少了一部分」的
      // 总额比报空更危险，因为它看起来是完整的。
      const costs = capabilities
        .filter((item) => item.capability)
        .map((item) => item.cost);
      const totalCost = priceState === 'full' && costs.every((value) => value !== null)
        ? round(costs.reduce((sum, value) => sum + value, 0))
        : null;

      return {
        scope: 'instance',
        /**
         * 口径说明。刻意放进响应体而不是只写在文档里 ——
         * 看板是给人看的，让人必须去翻文档才知道「这个数字不是全局的」，
         * 结果就是被当成全局数字用。
         */
        scopeNote:
          '本实例自启动以来的口径。Serverless 多实例下每个实例各算一份，'
          + '全局口径需要把审计事件接到日志/指标服务。',
        since: new Date(startedAt).toISOString(),
        now: new Date(now()).toISOString(),
        totals: {
          ...totals,
          cost: totalCost,
        },
        byCapability: capabilities,
        byPath: [...byPath.entries()].map(([path, bucket]) => ({ path, ...bucket })),
        byCode: Object.fromEntries([...byCode.entries()].sort((a, b) => b[1] - a[1])),
        latencyMs: percentile(latencies),
        pricing: {
          state: priceState,
          currency: config.pricing?.currency ?? 'CNY',
          /** 单价本身回给看板：让「为什么没有成本数字」可以自查。 */
          inputPerKToken: config.pricing?.inputPerKToken ?? {},
          outputPerKToken: config.pricing?.outputPerKToken ?? {},
        },
        /**
         * 成本是否为**下限**。
         *
         * 单独给一个布尔量而不是只写进 `costNote`：客户端要据此在界面上
         * 加一个「≥」号。只给文字说明的话，界面很容易把这个数字当成准确的。
         */
        costIsLowerBound: priceState !== 'none' && totals.usageMissing > 0,
        costNote: costNoteOf(priceState, totals),
        quota: {
          unitsPerMinute: config.quota?.unitsPerMinute ?? 0,
          unitsPerDay: config.quota?.unitsPerDay ?? 0,
          weights: config.quota?.weights ?? {},
        },
      };
    },

    /** 测试用。 */
    reset() {
      Object.assign(totals, emptyBucket());
      byCapability.clear();
      byPath.clear();
      byCode.clear();
      latencies = [];
    },
  };
}

/**
 * 某级能力的成本。
 *
 * 单价按**能力**配而不是按模型配：当前是「一级能力一个模型」的一对一关系，
 * 按能力配足够且更稳定 —— 换模型 ID 时单价通常不变，而模型 ID 会带日期后缀、
 * 每次换都要改配置的话，漏改一次成本就是错的。
 * 真出现「同一能力多模型分流」时再按模型分档。
 *
 * 导出是为了让 `scripts/probe-ark.mjs` 复用同一个公式。那个脚本要回答
 * 「照控制台把这些单价填进去，算出来是多少」，如果它自己写一份算法，
 * 就会出现「探查看起来没问题、看板算出来是另一个数」——
 * 那时你无法判断该信哪一个。
 */
export function costOf(config, capability, bucket) {
  const input = config.pricing?.inputPerKToken?.[capability];
  const output = config.pricing?.outputPerKToken?.[capability];
  if (typeof input !== 'number' || typeof output !== 'number') return null;
  return round((bucket.tokensIn / 1000) * input + (bucket.tokensOut / 1000) * output);
}

/** 保留 4 位：成本单位是元，再多的小数位没有信息量。 */
function round(value) {
  return Math.round(value * 10000) / 10000;
}

function costNoteOf(priceState, totals) {
  if (priceState === 'none') {
    return '未配置模型单价（AI_PRICE_*），因此只提供用量、不估算成本。'
      + '价格随官方调价与模型换代变化，写死一份会过期 —— 请在火山方舟控制台确认后填入。';
  }
  if (priceState === 'partial') {
    return '单价只配置了一部分，未配的那部分会被算作 0，总额偏小。请配齐或全部留空。';
  }
  if (totals.usageMissing > 0) {
    return `有 ${totals.usageMissing} 次模型调用未返回 usage，这些调用的 token 数无从得知，`
      + '成本是**下限**。';
  }
  return null;
}

/** 分位。样本为空时全部返回 null，而不是 0 —— 「没有样本」和「延迟为 0」不同。 */
function percentile(samples) {
  if (samples.length === 0) {
    return { samples: 0, p50: null, p95: null, max: null };
  }
  const sorted = [...samples].sort((a, b) => a - b);
  const at = (ratio) => {
    const index = Math.min(sorted.length - 1, Math.floor(sorted.length * ratio));
    return sorted[index];
  };
  return {
    samples: sorted.length,
    p50: at(0.5),
    p95: at(0.95),
    max: sorted[sorted.length - 1],
  };
}
