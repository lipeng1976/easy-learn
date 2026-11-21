#!/usr/bin/env node

/**
 * 首次接入方舟时用的**模型目录探查**：告诉我该把什么填进 `ARK_MODEL_*`。
 *
 * ## 为什么 `probe-ark.mjs` 不够
 *
 * `probe-ark.mjs` 验的是「已知模型 ID 时，这条通道通不通」（鉴权、tool calling、
 * schema 解析、usage 字段）。它**假设你已经知道要填哪个模型 ID** ——
 * 而这恰恰是第一次接入时唯一不知道的事。控制台里模型名一长串，
 * 文档里写的是 `doubao-...`，到底该填哪一个、哪一个在**这个账号**上开通了，
 * 没有任何本地办法能回答。
 *
 * ## 两个容易混为一谈的「不存在」
 *
 * `GET /models` 返回的是**平台模型目录**（实测 133 条，其中 69 条 `Shutdown`、
 * 22 条 `Retiring`）—— 它说明「平台上有这个模型」，**不说明这个账号开通了它**。
 *
 * 而 `POST /chat/completions` 用未开通的模型会回 `404 ModelNotOpen`，
 * 文案是「Your account <id> has not activated the model ...」。
 * 这两件事的**处置动作完全不同**：
 *
 * - 模型 ID 打错 → 改配置；
 * - 模型没开通 → 去方舟控制台「开通管理」开通，改配置没用。
 *
 * 两者都是 404，日志里长得一模一样。所以这个脚本把两件事分开回答：
 * 先照着目录**列出候选**（打错字看不出来），再对每个候选**实际调一次**（没开通看不出来）。
 *
 * ## 它花多少钱
 *
 * 每个候选一次 `max_tokens: 8` 的调用。实测 19 个候选合计约 30 秒、
 * 输入 token 数是两位数 —— 这是「几厘钱换一个确定答案」的交易。
 * 想先看目录不花钱：加 `--dry`。
 *
 * ## 用法
 *
 * ```bash
 * ARK_API_KEY=xxx node scripts/probe-ark-catalog.mjs          # 列候选 + 逐个探开通
 * ARK_API_KEY=xxx node scripts/probe-ark-catalog.mjs --dry    # 只看目录，一次调用都不发
 * ARK_API_KEY=xxx node scripts/probe-ark-catalog.mjs --only=seed-2-1   # 只探名字含该串的
 * ```
 *
 * 退出码：`0` 至少开通了一个可用模型；`1` 一个都没有（**这通常是账号侧没开通，
 * 不是代码问题**）；`2` 配置不全或目录拉不下来。
 */

import { loadConfig } from '../src/config.js';

/**
 * 一个模型能不能走 `/chat/completions`，看**输出**模态而不是任务名。
 *
 * 判据取输出侧是有原因的：`task_type` 字段在老模型上经常是空的
 * （目录里 `qwen3-32b`、`glm-4-5-air` 这些就是空的），拿它筛会把
 * 可能可用的模型漏掉；而「输出里有没有文本」才是 chat 端点的真实前提。
 * 反过来，输出是 image / video / three_d 或任务是 Embedding 的，
 * 拿 chat 探它们**永远不可能是 200** —— 那种「未开通」是假的，会误导人。
 */
/**
 * 按系列名排除**确定不是 chat** 的模型。
 *
 * 上面那条「看输出模态」的规则对老条目是失效的：`task_type` 与 `modalities`
 * 都为空时只能放它去探。实测这种漏网的是 `doubao-seedream-4-0-20260415`
 * （文生图系列）—— 拿 chat 端点探它必然失败，会输出一行「未开通」。
 *
 * 那行是**假的**：不是没开通，是这个端点和它无关。假阳性比漏探更坏 ——
 * 它让人以为「账号里有一部分模型开通了，另一部分没开通」，
 * 而事实是「一个都没开通」。所以宁可按名字再拦一道。
 */
const NOT_CHAT_SERIES = /seedream|seedance|seed3d|hitem3d|hyper3d|embedding/i;

function canUseChatEndpoint(model) {
  if (NOT_CHAT_SERIES.test(model.id)) return false;

  const tasks = model.task_type ?? [];
  if (tasks.some((t) => /Embedding|ImageTo3D|ToVideo|ToImage/i.test(t))) return false;

  const out = model.modalities?.output_modalities;
  if (Array.isArray(out) && out.length > 0) return out.includes('text');
  // 没有模态信息的老条目：不排除，让它去探 —— 一次调用而已。
  return true;
}

/** 目录里 `status` 缺省表示在售；`Shutdown` / `Retiring` 直接不看。 */
function isListed(model) {
  return model.status !== 'Shutdown' && model.status !== 'Retiring';
}

async function listCatalog(config) {
  const r = await fetch(`${config.ark.baseUrl}/models`, {
    headers: { authorization: `Bearer ${config.ark.apiKey}` },
    signal: AbortSignal.timeout(30000),
  });
  if (!r.ok) {
    throw new Error(
      `拉取模型目录失败：HTTP ${r.status} ${(await r.text()).slice(0, 200)}\n`
        + '鉴权不通时先确认 ARK_API_KEY 与 ARK_REGION 是同一个账号/区域的。',
    );
  }
  return (await r.json()).data ?? [];
}

/**
 * 实际调一次，判「这个账号能不能用这个模型」。
 *
 * 返回 `{ ok, note }` —— `note` 是给「不能」的情况准备的**可操作**说明，
 * 而不是把原始 JSON 丢给读者让他自己认。
 */
async function probeModel(config, modelId) {
  const startedAt = Date.now();
  try {
    const r = await fetch(`${config.ark.baseUrl}/chat/completions`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${config.ark.apiKey}`,
      },
      body: JSON.stringify({
        model: modelId,
        messages: [{ role: 'user', content: '回一个字：好' }],
        max_tokens: 8,
      }),
      signal: AbortSignal.timeout(30000),
    });
    const text = await r.text();
    const ms = Date.now() - startedAt;

    if (r.ok) {
      const body = JSON.parse(text);
      return {
        ok: true,
        ms,
        usage: body.usage ?? null,
        reply: String(body.choices?.[0]?.message?.content ?? '').trim(),
      };
    }

    let code = '';
    try {
      code = JSON.parse(text).error?.code ?? '';
    } catch { /* 非 JSON 响应，保持空 */ }

    const notes = {
      ModelNotOpen: '账号未开通 —— 去方舟控制台「开通管理」开通这个模型，改配置没用',
      /**
       * 与 `ModelNotOpen` 的区别值得单列，因为**处置动作完全相反**。
       *
       * 实测目录里挂在「在售」的 `qwen3-*` / `glm-4-5-air` / `doubao-smart-router`
       * 回的是这个码 —— 它们在目录里活着，但已经调不动了（老型号退役、
       * 或本来就不是 chat 模型）。对着这些去控制台找「开通」按钮是白费功夫。
       *
       * 换句话说：**目录的「在售」不等于「可开通」**。这也是为什么
       * 「只拉目录」这一步不足以回答「我该填什么」。
       */
      'InvalidEndpointOrModel.NotFound':
        '目录里有但已不可用（老型号/非 chat 端点）—— 别去开通它，换个新一点的型号',
      AuthenticationError: 'Key 或区域不对',
      InvalidParameter: '参数被拒（可能这个模型不支持 chat 端点）',
    };
    return { ok: false, ms, code, note: notes[code] ?? text.slice(0, 160) };
  } catch (e) {
    return { ok: false, ms: Date.now() - startedAt, code: '', note: `网络层失败：${e.message}` };
  }
}

/** 标签列按**显示宽度**对齐（CJK 占 2 列），与 probe-ark.mjs 同一套理由。 */
function displayWidth(text) {
  let width = 0;
  for (const char of text) {
    const code = char.codePointAt(0);
    const wide = code >= 0x1100
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

function line(label, value) {
  console.log(`  ${label}${' '.repeat(Math.max(1, 10 - displayWidth(label)))}${value}`);
}

async function main() {
  const args = process.argv.slice(2);
  const dry = args.includes('--dry');
  const onlyArg = args.find((a) => a.startsWith('--only='));
  const only = onlyArg ? onlyArg.slice('--only='.length) : null;

  const config = loadConfig(process.env);
  if (config.ark.apiKey === '') {
    console.error(
      '缺少 ARK_API_KEY。\n'
        + '用法：ARK_API_KEY=xxx node scripts/probe-ark-catalog.mjs [--dry] [--only=<名字片段>]',
    );
    process.exit(2);
  }

  console.log(`区域：${config.ark.region}`);
  console.log(`数据面：${config.ark.baseUrl}`);

  let catalog;
  try {
    catalog = await listCatalog(config);
  } catch (e) {
    console.error(`\n${e.message}`);
    process.exit(2);
  }

  const listed = catalog.filter(isListed);
  const shutDown = catalog.length - listed.length;

  let candidates = listed.filter(canUseChatEndpoint);
  if (only !== null) candidates = candidates.filter((m) => m.id.includes(only));
  candidates.sort((a, b) => a.id.localeCompare(b.id));

  console.log(
    `\n目录 ${catalog.length} 条：在售 ${listed.length}、已下架 ${shutDown}（Shutdown/Retiring）。`,
  );
  console.log(`其中可走 chat 端点的候选 ${candidates.length} 个。`);

  if (candidates.length === 0) {
    console.error(only === null
      ? '\n一个候选都没有 —— 目录为空通常意味着区域填错了（见 ARK_REGION）。'
      : `\n没有名字含「${only}」的候选，去掉 --only 看全部。`);
    process.exit(2);
  }

  if (dry) {
    console.log('\n（--dry：只列目录，未发送任何调用）\n');
    for (const m of candidates) {
      const tasks = (m.task_type ?? []).join('+') || '(无任务信息)';
      const vision = (m.modalities?.input_modalities ?? []).includes('image') ? '  可读图' : '';
      line(m.id, `${tasks}${vision}`);
    }
    console.log('\n去掉 --dry 会对上面每个候选实际调一次，判定它在**本账号**是否开通。');
    return;
  }

  console.log('\n逐个实调（每个一次 max_tokens=8 的最小请求）：\n');

  const opened = [];
  for (const m of candidates) {
    const r = await probeModel(config, m.id);
    if (r.ok) {
      const vision = (m.modalities?.input_modalities ?? []).includes('image');
      opened.push({ id: m.id, vision, usage: r.usage });
      const usageText = r.usage
        ? `in ${r.usage.prompt_tokens} / out ${r.usage.completion_tokens}`
        : '(无 usage —— 成本会退化成下限)';
      line(`✅ ${m.id}`, `${r.ms}ms  ${vision ? '可读图  ' : ''}${usageText}`);
      // 探活回话本身不重要，但「回了个空串」是一种真实的异常（结构化输出没出来），
      // 值得看一眼；不静默。
      if (r.reply === '') line('', '[!] 回了空内容，值得留意但不是未开通');
    } else {
      line(`·  ${m.id}`, `${r.ms}ms  ${r.code || '-'}  ${r.note}`);
    }
    // 串行 + 小间隔：并发跑 19 条容易被方舟的 RPM 限制打到，
    // 那样得到的是 429，会被误读成「这个模型有问题」。
    await new Promise((resolve) => setTimeout(resolve, 120));
  }

  console.log('\n================ 结论 ================');
  if (opened.length === 0) {
    console.log('本账号**一个 chat 模型都没开通**。');
    console.log('');
    console.log('这不是 Key 的问题：Key 有效才会返回 ModelNotOpen');
    console.log('（错误文案里带着你的 account id），无效 Key 会直接 401。');
    console.log('要开通：方舟控制台 → 在线推理 → 开通管理 → 搜模型名 → 开通。');
    console.log('开通后把模型 ID 填进 ARK_MODEL_*，再跑 scripts/probe-ark.mjs 验通道。');
    process.exit(1);
  }

  /**
   * ⚠️ **`--only` 会把视野收窄，但下面那几句结论文案长得像「全账号结论」。**
   *
   * 2026-09-30 现场踩到：`--only=pro` 跑完之后脚本打印
   * 「已开通的模型都读不了图」并建议 `ARK_MODEL_VISION=` 留空 ——
   * 而能读图的那两只（`doubao-seed-2-1-lite` / `-2-0-mini`）**根本没被探到**，
   * 因为它们名字里没有 `pro`。这是一个**由过滤造成的假结论**，
   * 而且它错得很有说服力：格式规整、还贴心地给出了留空的理由。
   *
   * ⇒ 过滤生效时，先把「这不是全账号」说出来。
   */
  if (only !== null) {
    console.log(`⚠️ 本次带了 --only=${only} —— 下面只说「名字含「${only}」的候选」，`);
    console.log('   **不是全账号的结论**。要看全量就去掉 --only 重跑。');
    console.log('');
  }
  console.log(`本次探到的候选里，${opened.length} 个可走 chat。`);
  const visionModels = opened.filter((m) => m.vision).map((m) => m.id);
  console.log('\n可直接填进环境变量（按网关的三级档位）：');
  console.log('');
  if (visionModels.length > 0) {
    console.log(`  ARK_MODEL_VISION=${visionModels[0]}`);
  } else {
    console.log('  ARK_MODEL_VISION=      # ← 本次探到的候选里没有能读图的，留空');
  }
  /**
   * ⚠️ **不要拿 `opened[0]` 当 reasoning 档。**
   *
   * 这里原先印的是 `ARK_MODEL_REASONING=${opened[0].id}` —— 而 `opened` 是按
   * **目录返回顺序**排的，跟能力毫无关系。2026-09-30 它印出了
   * `deepseek-v4-pro-ga-260813`，看起来很合理，但那个「合理」是巧合：
   * 列表第一项刚好是它。换一天目录顺序变了，同一句话就会推荐另一个模型。
   *
   * ⇒ 档位只能**按能力实测**选（跑 `../probe-*` 那套判据），不能按列表顺序发。
   */
  console.log('  ARK_MODEL_REASONING=   # ← 档位要按能力实测选，**不要**照抄列表顺序');
  console.log(`                         #    本次第一个是 ${opened[0].id}，顺序不代表能力`);
  console.log('  ARK_MODEL_LIGHT=      # ← 没有业务端点用到它；不需要就留空，别拿别的模型名填满');
  console.log('');
  console.log('⚠️ 没开通的档位**留空**，不要用同一个模型名填满两处：');
  console.log('   网关把「填了模型名」当作「这个能力可用」，填错不会报错 ——');
  console.log('   它会**编一份批改结果**，而那份结果会进错题库、被组卷、被打印出来。');
  console.log('');
  console.log('下一步：填好后跑 scripts/probe-ark.mjs 验通道（schema / usage / tool calling）。');
}

await main();
