#!/usr/bin/env node

/**
 * 火山方舟三级模型的**真凭证探查**。
 *
 * ## 为什么需要它
 *
 * `AI_MODEL_CLIENT=mock` 时整条链路全绿，但那证明不了任何线上事实：
 * mock 是我们自己写的，它当然返回我们要的字段、当然认识我们写的 schema。
 * 有两件事**只有真凭证能验**：
 *
 * 1. **模型是不是真的开通了。** 视觉通了不代表强推理通了 —— 三级模型在方舟上
 *    是分别开通的。没开通的能力网关会如实回 `model_not_enabled`，
 *    但那要等到学生第一次点「讲解」才暴露。
 * 2. **`usage` 的字段名。** 网关的成本链路只认 `usage.prompt_tokens` 与
 *    `usage.completion_tokens`（见 `guard.js` 里的 `tokens`）。方舟某个模型或
 *    接入点若用了别的名字、或干脆不返回 usage，看板**不会报错** ——
 *    它会安静地把 token 记成 0、让成本退化成「下限」。这类错误没有任何本地测法。
 *
 * 所以这里不写「看起来对」的断言，只做一件事：**各调一次，把原始响应摊开看**。
 * 这与 `probe-tos.mjs` 是同一种做法、同一个理由。
 *
 * ## 它**不**验什么（别误读为已验）
 *
 * 不验业务契约的**正确性**：探活用的是一个极简 schema，只要求模型回一句话。
 * 判定准不准、批改得对不对，要靠真实使用来评，不是一条探活命令能证明的。
 * 它验的是**通道**：鉴权、模型 ID、tool calling、结构化输出解析、usage 字段。
 *
 * 用法：
 *
 * ```bash
 * ARK_API_KEY=xxx \
 * ARK_MODEL_VISION=doubao-... ARK_MODEL_REASONING=doubao-... \
 * node scripts/probe-ark.mjs
 *
 * node scripts/probe-ark.mjs reasoning   # 只探一级
 * ```
 *
 * 退出码：`0` 全部通过；`1` 有失败或 token 字段缺失；`2` 配置不全。
 */

import { ArkModelClient } from '../src/ark.js';
import {
  Capabilities,
  capabilityReport,
  loadConfig,
  pricingState,
  validateConfig,
} from '../src/config.js';
import { costOf } from '../src/metrics.js';
import { probeImageDataUri } from './lib/probe-image.mjs';

/** 三级能力：从贵到便宜。顺序固定，输出才便于前后对比。 */
const TIERS = [Capabilities.vision, Capabilities.reasoning, Capabilities.light];

/** 环境变量名，报错时直接告诉运维该填哪个。 */
const MODEL_ENV = {
  [Capabilities.vision]: 'ARK_MODEL_VISION',
  [Capabilities.reasoning]: 'ARK_MODEL_REASONING',
  [Capabilities.light]: 'ARK_MODEL_LIGHT',
};

/**
 * 探查用的极简 schema。
 *
 * 刻意**不用**业务 schema（`Schemas.homeworkCheck` 那些）：探活要回答的是
 * 「这条通道通不通」，不是「模型批改得好不好」。混在一起时，
 * 模型这次答得不合格会让你看不出到底是通道坏了还是它没答好。
 */
const PROBE_SCHEMA = {
  name: 'report_probe_result',
  description: '回报一次连通性探查的结果',
  type: 'object',
  additionalProperties: false,
  required: ['summary'],
  properties: {
    summary: {
      type: 'string',
      minLength: 1,
      description: '一句话说明本次探查的结论',
    },
  },
};

/**
 * 探针图来自 `scripts/lib/probe-image.mjs` —— **共享一份**，不在这里内联。
 *
 * ⚠️ 这里原先内联的是一张 **1×1** 的 PNG。它在方舟上从没暴露问题
 * （那时视觉档没开通，这条路**压根没被跑过**），2026-09-24 换成百炼后立刻回：
 *
 * ```
 * <400> The image length and width do not meet the model restrictions.
 *       [height:1 or width:1 must be larger than 10]
 * ```
 *
 * 报错读起来像「模型不可用 / 密钥不对」，实际是**探针自己的测试数据不合格**。
 * 详见那个模块的文件头 —— 那里的 96×96 是「明显大于各厂商下限」的取值。
 */
const PROBE_IMAGE_URI = probeImageDataUri();

/** 与 `handlers.js` 组装 content 的方式保持一致（文本片段在前，图片在后）。 */
function contentFor(tier) {
  const ask = '这是一次连通性探查。请用一句话回报你收到了请求。';
  if (tier !== Capabilities.vision) return ask;
  return [
    // 问「有什么形状」而不是「主色」：这张图是白底黑框＋一条横线，
    // 主色这个问题在它上面没有确定的答案，模型答什么都不能说明它会看图。
    { type: 'text', text: `${ask}另外说明这张图片里有什么形状。` },
    {
      type: 'image_url',
      image_url: { url: PROBE_IMAGE_URI, detail: 'high' },
    },
  ];
}

/**
 * 标签的**显示宽度**（CJK 与全角符号占 2 列）。
 *
 * 不能用 `padEnd`：它按 UTF-16 码元数补，而「模型」是 2 个码元却占 4 列。
 * 结果就是全角标签这一列全歪 —— 而这份输出是给人扫一眼的，
 * 歪掉的对齐会让人多花几秒才能定位到出错的那一行。
 */
function displayWidth(text) {
  let width = 0;
  for (const char of text) {
    const code = char.codePointAt(0);
    const wide =
      code >= 0x1100
      && (code <= 0x115f
        || (code >= 0x2e80 && code <= 0xa4cf)
        || (code >= 0xac00 && code <= 0xd7a3)
        || (code >= 0xf900 && code <= 0xfaff)
        || (code >= 0xfe30 && code <= 0xfe6f)
        || (code >= 0xff00 && code <= 0xff60)
        || (code >= 0xffe0 && code <= 0xffe6));
    width += wide ? 2 : 1;
  }
  return width;
}

/** 一行对齐的输出。标签列固定 10 列宽。 */
function line(label, value) {
  console.log(`  ${label}${' '.repeat(Math.max(1, 10 - displayWidth(label)))}${value}`);
}

/**
 * 核对 usage 里有没有网关依赖的两个字段。
 *
 * 这里**必须点名是哪个字段**：只报「usage 不对」时，运维拿到的信息
 * 无法定位到 `guard.js` 那一行。把方舟实际返回的键列出来，一眼就能对上。
 */
function checkUsageFields(usage) {
  if (usage === null || usage === undefined) {
    return {
      ok: false,
      reason:
        '响应里没有 usage —— 这次调用的 token 数无从得知，看板会把成本标成「下限」',
    };
  }

  const missing = ['prompt_tokens', 'completion_tokens'].filter(
    (field) => typeof usage[field] !== 'number',
  );
  if (missing.length > 0) {
    return {
      ok: false,
      reason:
        `usage 里缺 ${missing.join(' / ')}。网关按这两个字段记账（guard.js），`
        + `实际返回的键是：${Object.keys(usage).join(', ') || '(空对象)'}`,
    };
  }

  return { ok: true, reason: '' };
}

async function probeTier(client, config, tier) {
  const startedAt = Date.now();
  try {
    const result = await client.complete({
      capability: tier,
      schema: PROBE_SCHEMA,
      system: '你是一个结构化输出一致性检查器，只按 schema 返回结果。',
      content: contentFor(tier),
    });
    const latencyMs = Date.now() - startedAt;

    const usage = result.usage ?? null;
    const usageCheck = checkUsageFields(usage);
    const tokensIn = usage?.prompt_tokens ?? 0;
    const tokensOut = usage?.completion_tokens ?? 0;
    const cost = costOf(config, tier, { tokensIn, tokensOut });

    console.log(`\n[通过] ${tier}`);
    line('模型', result.model);
    line('耗时', `${latencyMs}ms`);
    line('结束原因', result.finishReason || '(未提供)');
    line('额度权重', `${config.quota?.weights?.[tier] ?? '?'} 单位/次`);
    line('token', usage === null ? '(无 usage)' : `in ${tokensIn} / out ${tokensOut}`);
    line(
      '成本',
      cost === null
        ? '未配单价（看板会显示「成本未知」）'
        : `¥${cost}（按 AI_PRICE_${tier.toUpperCase()}_* 估算）`,
    );
    if (usage !== null) {
      line('usage 原文', JSON.stringify(usage));
    }

    if (!usageCheck.ok) {
      console.log(`  [!] ${usageCheck.reason}`);
    }

    return usageCheck.ok;
  } catch (error) {
    console.log(`\n[失败] ${tier}`);
    line('模型', config.ark.models[tier] || '(未配置)');
    line('耗时', `${Date.now() - startedAt}ms`);
    line('错误码', error?.code ?? '(非网关错误)');
    line('信息', error?.message ?? String(error));
    if (error?.code === 'model_not_enabled') {
      console.log(
        `  该能力未开通。确认方舟控制台已开通对应模型，并把模型 ID 填进 ${MODEL_ENV[tier]}。`,
      );
    }
    if (error?.code === 'model_auth_failed') {
      console.log('  鉴权失败：确认 ARK_API_KEY 属于当前区域（ARK_REGION）的账号。');
    }
    return false;
  }
}

async function main() {
  const [only] = process.argv.slice(2);
  const config = loadConfig(process.env);

  if (only !== undefined && !TIERS.includes(only)) {
    console.error(`未知能力「${only}」。可选：${TIERS.join(' / ')}`);
    process.exit(2);
  }

  if (config.ark.apiKey === '') {
    console.error(
      '缺少 ARK_API_KEY。这是真凭证探查，没有密钥就无从验起。\n'
        + '用法：ARK_API_KEY=xxx ARK_MODEL_VISION=... ARK_MODEL_REASONING=... node scripts/probe-ark.mjs',
    );
    process.exit(2);
  }

  const report = capabilityReport(config);
  const targets = (only ? [only] : TIERS).filter((tier) => tier !== undefined);

  console.log(`区域：${config.ark.region}    数据面：${config.ark.baseUrl}`);
  console.log(
    `配置里已开通：${TIERS.filter((tier) => report[tier]).join(' / ') || '(一个都没有)'}`,
  );

  const priceState = pricingState(config);
  console.log(
    `单价配置：${
      { none: '未配（看板只报用量）', partial: '只配了一部分（会被启动自检拦下）', full: '已配齐' }[
        priceState
      ]
    }`,
  );

  // 启动自检本来在网关装配时跑。这里也跑一遍：探查的目的之一就是
  // 「部署前把配置问题一次看完」，此时给出的问题比线上 429 好查得多。
  const problems = validateConfig(config);
  if (problems.length > 0) {
    console.log('\n配置自检发现的问题：');
    for (const problem of problems) console.log(`  - ${problem}`);
  }

  const client = new ArkModelClient({ config });

  let failed = 0;
  const skipped = [];

  for (const tier of targets) {
    if (!report[tier]) {
      skipped.push(tier);
      continue;
    }
    // 串行而不是并发：并发会把三条请求的延迟混在一起，
    // 而延迟本身是这次探查要看的数（尤其是视觉档）。
    const ok = await probeTier(client, config, tier);
    if (!ok) failed += 1;
  }

  console.log('');
  if (skipped.length > 0) {
    console.log(
      `跳过 ${skipped.join(' / ')}：${MODEL_ENV[skipped[0]]} 等未配置，网关会如实回 model_not_enabled。`,
    );
  }

  /**
   * 轻量档目前**没有业务端点**：`router.js` 的六条路由只落到视觉与强推理两档
   * （见 `CAPABILITY_BY_KIND`）。它仍然值得探 —— 开通与否是运维侧的事实，
   * 而这条事实决定了「以后要加小任务时有没有现成的档位可用」。
   */
  if (targets.includes(Capabilities.light) && report[Capabilities.light]) {
    console.log(
      '提示：轻量档当前没有网关路由使用（CAPABILITY_BY_KIND 里只有视觉与强推理），'
        + '通过只说明这个模型 ID 可用。',
    );
  }

  if (failed > 0) {
    console.log(`\n有 ${failed} 级能力未通过，见上面的 [!] 与错误信息。`);
    process.exit(1);
  }

  console.log('\n全部通过：鉴权、模型 ID、结构化输出、usage 字段都正常。');
  console.log('此时可以按控制台定价填 AI_PRICE_* 了 —— 看板的成本才会从「未知」变成数字。');
}

await main();
