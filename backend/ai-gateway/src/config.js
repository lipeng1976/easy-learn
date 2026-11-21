/**
 * 网关配置：全部来自环境变量。
 *
 * 三条约定：
 * 1. **API Key 只在这里读**，绝不写入任何返回体、日志或错误信息。
 * 2. **模型 ID 全部可配**。方舟的模型 ID 带日期后缀（形如 `doubao-seed-2-1-pro-260628`），
 *    官方会持续上新与下线；写死在代码里意味着每次换模型都要重新部署一遍。
 * 3. **缺模型 ID 就是「该能力未开通」**，而不是「用默认模型顶上」——
 *    用错档位的模型（拿轻量档做判定）会静默产生错判，比报错难查得多。
 */
import { DEV_STACK_SECRET, isProduction } from '../../shared/env.js';

/** 三级能力。对应设计文档的模型选型表。 */
export const Capabilities = {
  /** 视觉：作业拍照识别、手写批改。单价最高，只给真正需要看图的请求。 */
  vision: 'vision',
  /** 强推理：出题、讲解、规则判不了的难题。必须算得准，不能省。 */
  reasoning: 'reasoning',
  /** 轻量：文本解析、格式化、分类。便宜到可以忽略。 */
  light: 'light',
};

/**
 * 业务动作 → 能力档位。
 *
 * **只此一份**：`handlers.js` 用它选模型，`router.js` 用它算配额权重。
 * 分成两份的后果很隐蔽 —— 两边对不上时，路由会按 A 档收额度、
 * 实际却调了 B 档的模型，配额的权重全错，而且没有任何报错。
 */
export const CAPABILITY_BY_KIND = {
  homeworkOcr: Capabilities.vision,
  homeworkCheck: Capabilities.vision,
  /**
   * 图形题的**独立复核**（批改内部第二次调用）。
   *
   * 档位必须与 `homeworkCheck` 一致：它要看同一张照片、重新读图中的标注，
   * 用纯文本档等于让它凭印象猜。
   *
   * ⚠️ 它**不会**再扣一次配额：路由的 `chargeQuota` 有 `quota.charged` 守卫，
   * 同一请求只扣一次。也就是说第二次视觉调用的钱由服务方承担 ——
   * 这是刻意的取舍：宁可少收一次，也不能让「额度只剩 1 次」的学生
   * 在批改已经成功之后被 429 打断。成本可在 `/ai/metrics` 的 ai_call 条数上看到。
   */
  homeworkFigureVerify: Capabilities.vision,
  /**
   * 举一反三的**拍照作答**（把学生手写的这一题解答转录成文字）。
   *
   * ⚠️ **不要拿 `homeworkOcr` 顶上**：它的语义是「整卷识别 + 按科目归纳作业要求」，
   * 输出 `text/subject/confidence/tasks`。这里要的是「认出学生**这一题**的作答」，
   * 只要一段文字。共用会让模型把单题作答当成整卷，归纳出一堆不存在的作业要求。
   *
   * 档位选 vision 是有代价的：走视觉档 ⇒ 配额按视觉权重（默认 8）扣。
   * 这是对的 —— 它确实要发一张图给视觉模型。选 light 会让成本少算 8 倍。
   */
  answerOcr: Capabilities.vision,
  /**
   * 错题录入：把照片里的题目提取成文本。
   *
   * 与 `homeworkCheck` 的差别是**问的问题不同**：那条问「哪几道做错了」，
   * 这条问「这上面写着什么」。复用批改提示词的后果不是报错，而是模型
   * 努力凑出错题明细 —— 学生拍的是一道他自认为错的题，回来却是一份
   * 按科目归纳的批改报告。
   *
   * 档位是 vision：确实要发图。按 8 倍权重扣额度，这是对的。
   */
  extractMistakes: Capabilities.vision,
  reviewJudge: Capabilities.reasoning,
  reviewExplain: Capabilities.reasoning,
  /**
   * 错题讲解，**带原题照片**的那条路径。
   *
   * 为什么要单独一档：`reviewExplain` 是纯文本档，面对「下图的面积」这类题
   * 只能给通用套路（2026-10-23 实测：回来的是「横向切 / 竖向切 / 补形」，
   * 学生看完还是不会）。有照片时必须走视觉档，代价是 8 倍配额 ——
   * 所以**没有照片的错题仍然走纯文本档**，不为一张不存在的图付视觉的钱。
   */
  reviewExplainFigure: Capabilities.vision,
  reviewPractice: Capabilities.reasoning,
  /**
   * 举一反三，**带原题照片**的那条路径。
   *
   * 为什么必须有这一档、而不是把 `reviewPractice` 直接改成视觉：
   * 只有拍照录入的错题才有原图。历史错题、手工录入的错题都没有，
   * 那些请求不该为一张不存在的图付视觉档的价钱（配额权重 8 倍）。
   * 客户端按 `imageCount > 0` 选路径，网关按 kind 选模型。
   */
  reviewPracticeFigure: Capabilities.vision,
  /**
   * 每日概念打卡：一次出 3–5 道**可本地判分**的短题（选择 / 判断）。
   *
   * 走推理档而不是轻量档的理由：这些题要围着学生**错过的知识点**出，
   * 出错了比不出更糟 —— 轻量档常见的失败是「题干对、答案错」，
   * 而答案错会让做对的学生被判错，直接毁掉这条链路的意义。
   *
   * ⚠️ 只许出 choice / judge 两种题型。填空与解答**绝不在这里出**：
   * 本地判分只能做确定性比对（`0.5` 与 `1/2` 就是同一个答案），
   * 一旦放进自由作答，判错就是必然，而且是静默的。
   */
  checkinGenerate: Capabilities.reasoning,
  /**
   * 错题库 → 知识点提示。
   *
   * 走 reasoning 而不是 light，尽管它只输出几句短文本：这几句话会被学生
   * 当成「要点」记住并直接影响下一次做题。light 档在常识性知识点上
   * 编一个似是而非的公式是很常见的事，而代价（一个错公式）远大于
   * 省下的那点 token —— 何况它有缓存，一个科目几天才生成一次。
   */
  reviewTips: Capabilities.reasoning,
  /**
   * 错题的**讲解配图**（讲解页「看懂这张图」）。
   *
   * 走 reasoning 而不是 light：这一步要判断「这题该不该画、画出来能不能说明
   * 问题」，是**教学设计**而不是文本生成。light 档的典型失败是给
   * `(-0.25)^2024 × (-4)^2024` 硬画一张数轴 —— 它看起来像个正常的图，
   * 学生却读不出任何东西，还会以为图里有自己没看出来的东西。
   *
   * 成本可以不管：它由学生点击触发、结果进缓存，一道题只算一次。
   */
  reviewFigure: Capabilities.reasoning,
  /**
   * 同上，但手上有原题照片。
   *
   * 面积题、几何题的「如图」全在照片里，纯文本档看不见图就只能凭想象画 ——
   * 实测那正是它把「大矩形减缺口」画错的地方。有照片就必须走视觉档。
   */
  reviewFigurePhoto: Capabilities.vision,
  reviewReferenceBatch: Capabilities.reasoning,
};

function intOf(raw, fallback) {
  const parsed = Number.parseInt(raw ?? '', 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function boolOf(raw, fallback) {
  if (raw === undefined || raw === '') return fallback;
  return raw === 'true' || raw === '1';
}

/**
 * 逗号分隔的路由（kind）名单，支持 `*` 表示全部。
 *
 * 这里**只解析、不校验名字是否真实存在** —— 校验放在 `validateConfig` 里，
 * 因为那是启动时会打印出来的地方。一个拼错的 kind 不会报错、只会静默不生效，
 * 也就是「以为关掉了、其实没关」，必须让人在部署那一刻看见。
 */
function kindListOf(raw) {
  if (raw === undefined || raw === '') return [];
  return String(raw)
    .split(',')
    .map((item) => item.trim())
    .filter((item) => item !== '');
}

/**
 * 价格专用：**未配置返回 null，而不是 0**。
 *
 * 0 与「没配」在看板上是两个完全不同的结论（一个是「免费」，一个是
 * 「不知道」），而 `intOf` 那类「缺省即回落一个合理值」的写法会把它抹平。
 */
function floatOf(raw) {
  if (raw === undefined || raw === '') return null;
  const parsed = Number.parseFloat(raw);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

/**
 * 单价的解析：**「没配」与「配了但看不懂」必须分开**。
 *
 * `floatOf` 对这两种输入**都返回 null**，而下游 `pricingState` 只看得到 null。
 * 于是「六个单价全填了、但格式都不对」会被判成「一个都没配」→ **放行**：
 * 部署成功、看板显示「未配置模型单价」，可用户回去看 `.env.prod` 明明填了，
 * 重填一遍还是不行 —— 因为问题在**格式**不在值，而没有任何地方说过这句话。
 *
 * 最常见的触发方式是从控制台抄价格时带上了货币符号（`¥0.008`）——
 * `Number.parseFloat` 只容忍**尾随**垃圾（`0.008元` 能读出来），
 * 前导符号一律读成 NaN。
 *
 * 所以这里把解析失败的原始值记进 `invalid`，交给 `validateConfig` 响亮地报错。
 * ⚠️ 空串 / undefined 不算「看不懂」—— 那是**合法的未配置**（见 pricing 的注释）。
 */
function priceOf(raw, key, invalid) {
  const value = floatOf(raw);
  if (value === null && raw !== undefined && String(raw).trim() !== '') {
    invalid.push(`${key}=${String(raw).trim()}`);
  }
  return value;
}

/**
 * 组装单价配置。
 *
 * 单独抽成函数，是为了在**对象字面量之外**有一个能放中间变量的地方 ——
 * `pricing` 是 `return {...}` 里的一个属性，里面写不了 `const` 语句。
 *
 * ## 单价**必须**跟着厂商走
 *
 * 它是这组配置里最容易被忘掉、又最安静的一处：两家的模型单价完全不同
 * （百炼的 `qwen3-vl-plus` 与方舟的 `doubao-seed-2-1-vision` 不是一个价），
 * 而单价**不参与任何功能**，只喂给成本看板。
 * 于是「切了厂商但单价还是上一家的」不会有任何症状 ——
 * 接口全通、日志全绿、看板给出一个**格式完整、数值错误**的成本数字。
 * 这比「未配置单价」坏得多：后者至少如实显示「成本未知」。
 *
 * 所以单价也按前缀分：`BAILIAN_PRICE_VISION_IN` / `ARK_PRICE_VISION_IN`，
 * 读不到再回落到旧的 `AI_PRICE_*`（既有部署不受影响）。
 */
function pricingFrom(env, provider) {
  const invalid = [];
  /**
   * ⚠️ 报错里点名的是**他实际写下的那个变量名**，不是模板拼出来的名字。
   *
   * 写成 `ARK_PRICE_VISION_IN（或旧名 AI_PRICE_VISION_IN）` 看起来更"全"，
   * 实际更差：用户在文件里只写了一行 `AI_PRICE_VISION_IN=¥0.008`，
   * 报错却先给他一个他没写过的名字 —— 他会先去找那个变量。
   */
  const price = (suffix, legacyKey) => {
    const { value, key } = providerEnvResolved(env, provider, suffix, legacyKey);
    return priceOf(value, key, invalid);
  };
  return {
    currency: env.AI_PRICE_CURRENCY || 'CNY',
    /** 千 token 输入单价（元）。留空 = 未配置。 */
    inputPerKToken: {
      [Capabilities.vision]: price('PRICE_VISION_IN', 'AI_PRICE_VISION_IN'),
      [Capabilities.reasoning]: price('PRICE_REASONING_IN', 'AI_PRICE_REASONING_IN'),
      [Capabilities.light]: price('PRICE_LIGHT_IN', 'AI_PRICE_LIGHT_IN'),
    },
    /** 千 token 输出单价（元）。留空 = 未配置。 */
    outputPerKToken: {
      [Capabilities.vision]: price('PRICE_VISION_OUT', 'AI_PRICE_VISION_OUT'),
      [Capabilities.reasoning]: price('PRICE_REASONING_OUT', 'AI_PRICE_REASONING_OUT'),
      [Capabilities.light]: price('PRICE_LIGHT_OUT', 'AI_PRICE_LIGHT_OUT'),
    },
    /**
     * 「填了但读不出数字」的单价原始值，形如 `AI_PRICE_VISION_IN=¥0.008`。
     * ⚠️ 空串**不在**这里 —— 那是合法的「未配置」。`validateConfig` 据此报致命。
     */
    invalidRaw: invalid,
  };
}

/**
 * 已改名的旧环境变量。
 *
 * 配额从「次数」改成「成本单位」时改名是必须的：语义变了，
 * 沿用旧名字会让 `AI_RATE_PER_STUDENT_PER_DAY=200` 被当成
 * 「每天 200 个成本单位」（≈ 25 次视觉批改）—— 一个**静默的、宽松了 8 倍**的配额。
 * 所以这里既不映射也不忽略，而是让启动直接失败（见 validateConfig）：
 * 部署脚本报错一次，好过配额悄悄失效到月底才发现。
 */
const RENAMED_ENV = {
  AI_RATE_PER_STUDENT_PER_DAY: 'AI_QUOTA_UNITS_PER_DAY',
  AI_RATE_PER_STUDENT_PER_MINUTE: 'AI_QUOTA_UNITS_PER_MINUTE',
};

/**
 * 模型服务商预设。**用开关选厂商，而不是靠散落的 if**。
 *
 * ## 为什么需要这层
 *
 * 网关的请求形态是 **OpenAI 兼容**的（`POST {baseUrl}/chat/completions` + Bearer），
 * 所以「换一家厂商」在多数情况下确实只是换三样东西：baseUrl、Key、模型名。
 * 但**有两处不兼容是藏在协议之外的**，照抄过去不会报「你配错了」：
 *
 * 1. **思维链的开关字段名与语义都不同**
 *    - 方舟：`thinking: { type: 'disabled' }` —— 「关掉」是一个**对象**
 *    - 百炼：`enable_thinking: false` —— 「关掉」是一个**布尔**
 *    字段名不认识时，多数服务端**选择静默忽略**（而不是 400）。
 *    后果是「思维链根本没关掉」→ 讲解悄悄超时 → 客户端安静退回本地模板，
 *    从外部看就是那句「讲解功能好像没用上 AI」。
 *
 * 2. **`tool_choice` 能否传对象，取决于思维链是否开着**
 *    百炼在思维链开启时只接受 `"none"` / `"auto"`，传对象**直接 400**：
 *    *The tool_choice parameter does not support being set to required or object
 *    in thinking mode.*
 *    而本项目用 `tool_choice` 传对象来**硬约束结构化输出**（见 ark.js 的注释：
 *    「结构化输出靠 function calling 硬约束，而不是在提示词里求模型返回 JSON」）。
 *    这两件事叠在一起才是坑：单看每一处都对，合起来就报错。
 *
 * ## 因此这里显式列出「各家到底怎么发这两个字段」
 *
 * 目前这张表记着**三件**会因厂商而异的事，都是实测出来的、不是照文档抄的：
 * ① 思维链怎么关（字段名与语义都不同）；② `tool_choice` 能不能传对象；
 * ③ 会不会把嵌套结构序列化成字符串塞进实参（`stringifiesStructuredArgs`）。
 *
 * 新增一家厂商时，**只改这张表**，客户端代码不动。
 * 表里没有的厂商名 → 启动直接失败（而不是回落一个默认值：
 * 回落的失败形态是「用着甲家的字段、打着乙家的地址」，比报错难查得多）。
 */
export const MODEL_PROVIDERS = {
  /** 火山引擎方舟。**行为完全不变**，是这一次改动前的唯一路径。 */
  ark: {
    label: '火山引擎方舟',
    /**
     * 这一家的配置从哪一组环境变量里读：`ARK_API_KEY` / `ARK_MODEL_*` /
     * `ARK_PRICE_*`。**与旧名字逐字相同** —— 所以方舟这一侧的行为
     * 与本次改动前**完全一致**，不需要迁移任何既有部署。
     */
    envPrefix: 'ARK',
    defaultRegion: 'cn-beijing',
    defaultBaseUrl: (region) => `https://ark.${region}.volces.com/api/v3`,
    /**
     * 思维链：方舟用 `thinking` 对象，值 `{ type: 'disabled' }` 表示关掉。
     * 注意它**没有**「开着」的显式写法 —— 不发这个字段就是开着。
     */
    thinkingOff: { field: 'thinking', value: { type: 'disabled' } },
    /** 方舟允许 `tool_choice` 传对象（即使思维链开着）。 */
    toolChoiceObjectAllowed: true,
    /** 区域变量名。两家的区域概念不同，方舟靠它拼 URL 前缀。 */
    regionEnv: 'ARK_REGION',
    /**
     * 会不会把**嵌套结构**序列化成字符串塞进实参里（`tasks: "[{...}]"`）。
     * 方舟不会 —— 2026-09-20 的联调里嵌套数组一直是真数组。
     * 所以这条对它是 `false`，行为与改动前**逐字节一致**。
     */
    stringifiesStructuredArgs: false,
  },

  /** 阿里云百炼（DashScope 的 OpenAI 兼容模式）。 */
  bailian: {
    label: '阿里云百炼',
    /**
     * 百炼**自己的一组**环境变量：`BAILIAN_API_KEY` / `BAILIAN_MODEL_*` /
     * `BAILIAN_PRICE_*`。
     *
     * ## 为什么要另起一组，而不是共用 `ARK_*`
     *
     * 共用一个槽位的后果是：**两套配置没法同时存在**。切到百炼就得把
     * `ARK_API_KEY` 和三个模型名**改掉**（覆盖掉方舟的值），切回去还得再改一遍
     * —— 于是「换一家厂商」变成了一件需要翻记录、且**做错一次就会被
     * 另一家的 Key 打到正确地址上**（报 401，看起来像 Key 没开通）的事。
     *
     * 分开之后，两套凭据同时在 `.env.prod` 里存着，`AI_MODEL_PROVIDER`
     * 真的成了**一个**开关 —— 这也是这个字段存在的唯一理由。
     *
     * ⚠️ 回退是**保留**的：`BAILIAN_*` 没填时仍然读旧的 `ARK_*` 通用槽，
     * 所以「只有一套配置、把值换成百炼的」这种既有写法照常能用。
     * 代价是那套写法仍然有上面说的切换风险 —— 补上 `BAILIAN_*` 就没了。
     */
    envPrefix: 'BAILIAN',
    /**
     * 百炼的 OpenAI 兼容端点带 `/v1` 后缀，**与方舟不同形**：
     * 方舟是 `https://ark.<region>.volces.com/api/v3`，
     * 百炼是 `https://dashscope.aliyuncs.com/compatible-mode/v1`。
     * 两者都不用再拼 `/chat/completions`（那是 ark.js 负责的）。
     */
    defaultRegion: '',
    defaultBaseUrl: () => 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    /**
     * 思维链：百炼用 `enable_thinking` **布尔**，语义与方舟相反。
     *
     * ⚠️ 早先记的「百炼非流式调用不支持思考模式」**是错的**（2026-09-24 实测推翻）：
     * 不发 `enable_thinking` 时思考照常跑（`usage` 里 `reasoning_tokens` 有值）。
     * 所以这里 `false` 的语义是「**换回硬约束 + 省时间**」，**不是**「否则会 400」。
     */
    thinkingOff: { field: 'enable_thinking', value: false },
    /**
     * 百炼在思维链开启时**不接受** `tool_choice` 传对象（`qwen3.8-max` 实测回 400）。
     *
     * ⚠️ 但这条限制是**按模型**、不是按厂商的：同样「思考开着 + 对象 tool_choice」，
     * `qwen3-vl-plus` 实测 **200 允许** —— 视觉模型不产生思维链 token，限制对它不适用。
     * 本旗标是**厂商级**的，所以视觉路由本来会白丢一次硬约束。两条出路：
     *   ① 把视觉路由加进 `AI_THINKING_DISABLED_KINDS`（**当前做法**，零代价换回硬约束）；
     *   ② 把这个旗标细化到**模型粒度**（收益是不必连思考一起关掉）。
     * 想放宽之前先实测目标模型 —— 别按厂商一刀切。
     */
    toolChoiceObjectAllowed: false,
    regionEnv: '',
    /**
     * ⚠️ **会。** 2026-09-24 实测：`/ai/homework/ocr` 稳定回
     *
     * ```json
     * "tasks": "\n[{\"subject\": \"语文\", \"text\": \"抄写第3课生字\"}]"
     * ```
     *
     * —— 数组被多包了一层引号。`qwen3-vl-plus` 与 `qwen3-vl-flash` 各两次，
     * **4/4 都一样**；而 OpenAI 的结构化输出开关 `strict: true` 会被接受
     * （HTTP 200）却**不起作用** —— 所以「让厂商保证实参合规」这条路在
     * 百炼兼容模式下走不通，只能在网关侧收一次
     * （见 `schema.js` 的 `repairStringifiedStructures`）。
     *
     * 这也是为什么这件事要记在**厂商**这一层：记清楚「谁需要被收」，
     * 就不必为了它把方舟那边也一起放宽。
     */
    stringifiesStructuredArgs: true,
  },
};

/** 未指定时用方舟 —— 与改动前完全一致，不改变任何既有部署的行为。 */
export const DEFAULT_MODEL_PROVIDER = 'ark';

/**
 * 这个模型 ID 像不像百炼的。
 *
 * **刻意用宽松的判据、只在"明显不像"时报错** —— 百炼的模型名在持续上新
 * （qwen3-max / qwen3-vl-plus / qwen3.8-max / qwen-flash …），
 * 写死一张白名单的后果是「新模型一上线，老配置就拦下来了」，
 * 那是把守卫变成了路障。所以这里反过来判断：**像方舟那种带日期后缀的 ID
 * 就一定不是百炼的**。
 *
 * 方舟形如 `doubao-seed-2-1-pro-260628`（结尾 6 位数字，代表日期）。
 * 百炼的模型名不带这种后缀。
 */
function looksLikeBailianModel(id) {
  const s = String(id ?? '').trim();
  if (s === '') return true; // 空 = 该能力未开通，不是错误（validateConfig 不管这条）
  // 方舟式：结尾是 -YYMMDD 或 -YYYYMMDD。
  if (/-\d{6}$/.test(s) || /-\d{8}$/.test(s)) return false;
  // 方舟还有 `doubao-` / `ep-`（接入点）这类前缀。
  if (/^(doubao|ep)-/i.test(s)) return false;
  return true;
}

/**
 * 这个模型 ID 像不像**方舟**的。
 *
 * 与 `looksLikeBailianModel` 是**反过来**的一对，但判据**刻意不对称**：
 * 上一版只拦「选百炼却填方舟名」，因为那时两套配置共用一个槽位，
 * 「选了方舟却填百炼名」只能靠手抖造成。把两套配置并列存进 `.env.prod`
 * 之后，方向颠倒是**最容易发生的一种错**（复制粘贴时看错一块）——
 * 所以补上这一侧。失败形态同样是安静型的：`invalid_parameter_error`
 * 里未必带模型名，看着像「这个模型没开通」。
 *
 * ⚠️ 判据只有「明显是方舟形态」才返回 true（`doubao-` / `ep-` / 日期后缀），
 * **不是**「像百炼就一定是错的」—— 自建网关上的 `llama3`、`qwen2.5:7b`
 * 都是合法值，把它们拦下来就是把守卫变成路障（本机 Ollama 那条退路就断了）。
 */
function looksLikeArkModel(id) {
  const s = String(id ?? '').trim();
  if (s === '') return false;
  if (/-\d{6}$/.test(s) || /-\d{8}$/.test(s)) return true;
  if (/^(doubao|ep)-/i.test(s)) return true;
  return false;
}

/**
 * 按「当前厂商那一组 → 旧的通用槽」的顺序取一个配置值。
 *
 * ## 为什么需要这个函数
 *
 * 三家（含将来新增的）厂商的配置要在**同一份 `.env.prod` 里并存**，
 * 就必须按前缀分开命名；但既有部署用的是 `ARK_*` 这组通用名字，
 * 不能一夜之间失效。所以读取顺序是：
 *
 * ```
 * ① <当前厂商前缀>_<字段>   —— 两组并存时走这条
 * ② 旧通用名（ARK_ / AI_PRICE_）  —— 只有一套配置的既有部署走这条
 * ```
 *
 * ⚠️ **方舟这一侧两条是同一个名字**（前缀就是 `ARK`），所以方舟的行为
 * 与改动前**逐字节一致** —— 这条回退不是「额外宽容」，而是让
 * 「同前缀」这种情形天然重合，不引入任何新的分支。
 *
 * ⚠️ 回退**允许**了「provider=bailian 却在读 ARK_API_KEY」这种组合。
 * 那不是漏洞，是刻意的兼容：它正是今天的写法。区别在于
 * **现在会把它显式标出来**（见 `loadConfig` 的 `providerEnvScoped`
 * 与 `/ai/health` 的 `modelProviderEnv`），所以它不再是一个没人知道的状态。
 *
 * @param {object} env 环境变量
 * @param {{envPrefix: string}} provider 当前厂商预设
 * @param {string} suffix 字段后缀，如 `API_KEY` / `MODEL_VISION`
 * @param {string} legacyKey 旧通用名，如 `ARK_API_KEY` / `AI_PRICE_VISION_IN`
 */
function providerEnvResolved(env, provider, suffix, legacyKey) {
  const prefixedKey = provider?.envPrefix ? `${provider.envPrefix}_${suffix}` : '';
  if (prefixedKey !== '') {
    const prefixed = env[prefixedKey];
    if (prefixed !== undefined && prefixed !== '') return { value: prefixed, key: prefixedKey };
  }
  return { value: env[legacyKey], key: legacyKey };
}

function providerEnvValue(env, provider, suffix, legacyKey) {
  return providerEnvResolved(env, provider, suffix, legacyKey).value;
}

/**
 * 「按前缀读的那一份没填、于是回退到旧通用名」的字段清单。
 *
 * 这一条是**为了让回退这件事可见**，而不是为了拦它。
 *
 * 回退本身是有意的兼容（见 `providerEnvValue`），但它有一个安静的坏形态：
 * 打算「两套配置并存」，却漏填了其中一项 —— 于是那一项**悄悄用了另一家的值**。
 * 例如 `BAILIAN_API_KEY` 忘了填，就会拿 `ARK_API_KEY`（方舟的 Key）
 * 去打百炼的地址，回 401。而 401 看起来就是「Key 没开通」，
 * 没人会怀疑是「变量名少写了一个前缀」。
 *
 * 模型名那一项已经被 `looksLikeArkModel` 那个守卫拦住了；但 Key 与单价
 * 没有形态可以判 —— 那就不猜（猜错会变成路障），改成**如实报出来**：
 * 部署脚本打印它，`/ai/health` 也回显它。已填全的正常情况是空数组。
 *
 * ⚠️ 方舟那一侧**永远是空数组**（前缀与旧名同字，两者不可能一个空一个非空），
 * 所以这条不会给既有部署增加任何噪音。
 */
export function legacyFallbackKeys(env, provider) {
  if (!provider?.envPrefix) return [];
  const fields = [
    ['API_KEY', 'ARK_API_KEY'],
    ['BASE_URL', 'ARK_BASE_URL'],
    ['MODEL_VISION', 'ARK_MODEL_VISION'],
    ['MODEL_REASONING', 'ARK_MODEL_REASONING'],
    ['MODEL_LIGHT', 'ARK_MODEL_LIGHT'],
    ['PRICE_VISION_IN', 'AI_PRICE_VISION_IN'],
    ['PRICE_VISION_OUT', 'AI_PRICE_VISION_OUT'],
    ['PRICE_REASONING_IN', 'AI_PRICE_REASONING_IN'],
    ['PRICE_REASONING_OUT', 'AI_PRICE_REASONING_OUT'],
    ['PRICE_LIGHT_IN', 'AI_PRICE_LIGHT_IN'],
    ['PRICE_LIGHT_OUT', 'AI_PRICE_LIGHT_OUT'],
    ['THINKING_DISABLED_KINDS', 'AI_THINKING_DISABLED_KINDS'],
  ];
  return fields
    .filter(([suffix, legacy]) => {
      const prefixed = env[`${provider.envPrefix}_${suffix}`];
      return (prefixed === undefined || prefixed === '') && (env[legacy] ?? '') !== '';
    })
    .map(([, legacy]) => legacy);
}

function legacyEnvNotices(env) {
  return Object.entries(RENAMED_ENV)
    .filter(([old]) => env[old] !== undefined && env[old] !== '')
    .map(([old, replacement]) => `${old} 已改名为 ${replacement}（语义由「次数」变为「成本单位」，不能直接沿用旧值）`);
}

export function loadConfig(env = process.env) {
  /**
   * 用哪个厂商的大模型。**默认方舟** —— 与改动前一致，既有部署零行为变化。
   *
   * 认不出的厂商名**不在这里拦**：`loadConfig` 只做解析，`validateConfig`
   * 负责报错（测试里会分别驱动这两件事）。
   */
  const providerName = env.AI_MODEL_PROVIDER || DEFAULT_MODEL_PROVIDER;
  const provider = MODEL_PROVIDERS[providerName] ?? null;

  /**
   * 区域不是随便填的。
   *
   * Serverless 函数与模型服务要在同一区域：一次作业批改要调用若干次模型，
   * 跨区往返的几十毫秒会逐次叠加，在「拍照 → 等结果」这种交互里非常明显。
   * 方舟数据面在 cn-beijing（北京），所以网关也应部署在北京。
   * 百炼没有区域变量（端点固定），故 `provider.regionEnv` 为空串。
   */
  const arkRegion = (provider?.regionEnv ? env[provider.regionEnv] : '')
    || provider?.defaultRegion
    || env.ARK_REGION
    || 'cn-beijing';

  return {
    // 选的哪一家，以及这张表本身（客户端据此决定字段怎么发）。
    modelProvider: providerName,
    modelProviderSpec: provider,

    /**
     * 上面那家的配置是从哪一组环境变量读的（`ARK` / `BAILIAN`）。
     *
     * 与 `modelProvider` 不同：**厂商名可能改了却没生效**
     * （实例缓存、或者环境变量压根没传上去），而这里报的是
     * 「实际参与读值的前缀」。两个一起看才能回答
     * 「我改了 AI_MODEL_PROVIDER，到底生效了没有」。
     */
    providerEnvPrefix: provider?.envPrefix ?? '',

    /**
     * 因为「按前缀的那一份没填」而回退到旧通用名的字段（正常情况是空数组）。
     * 取值与用途见 `legacyFallbackKeys`。
     */
    providerEnvFallbacks: legacyFallbackKeys(env, provider),

    /**
     * ⚠️ 字段名仍叫 `ark`，**刻意不改**。
     *
     * 它现在读的是「当前所选厂商」的配置，名字是历史遗留。
     * 改名的收益是零，风险是**漏改一处** —— 而漏改的失败形态是
     * 「用甲家的地址、乙家的 Key」，报的是 401 或 404，
     * 看起来像「密钥配错了」。`config.ark` 有 10+ 处引用（ark.js / handler.js /
     * handlers.js / dev-server.js），改名的收益撑不起这个风险。
     */
    ark: {
      region: arkRegion,
      // 数据面地址。默认值由厂商预设决定（方舟按区域拼、百炼固定）。
      baseUrl: providerEnvValue(env, provider, 'BASE_URL', 'ARK_BASE_URL')
        || (provider ? provider.defaultBaseUrl(arkRegion) : `https://ark.${arkRegion}.volces.com/api/v3`),
      apiKey: providerEnvValue(env, provider, 'API_KEY', 'ARK_API_KEY') || '',
      models: {
        // 视觉与强推理**通常要分别开通**，部分模型还需单独申请。
        // 这里留空即代表该能力不可用，网关会如实回 model_not_enabled。
        [Capabilities.vision]: providerEnvValue(env, provider, 'MODEL_VISION', 'ARK_MODEL_VISION') || '',
        [Capabilities.reasoning]: providerEnvValue(env, provider, 'MODEL_REASONING', 'ARK_MODEL_REASONING') || '',
        [Capabilities.light]: providerEnvValue(env, provider, 'MODEL_LIGHT', 'ARK_MODEL_LIGHT') || '',
      },
      timeoutMs: intOf(env.AI_MODEL_TIMEOUT_MS, 25000),
      maxAttempts: intOf(env.AI_MODEL_MAX_ATTEMPTS, 2),

      /**
       * 关掉思维链（Chain-of-Thought）的路由名单，空数组 = 一律不关（现状）。
       *
       * ## 为什么需要这个开关
       *
       * 2026-09-20 用真凭证实测（`serverless/ai-gateway` 的方舟联调）：
       * **讲解（`reviewExplain`）在推理型模型下 2/4 用例超客户端 12s 窗口，
       * 最坏 41.6s**（那道「改被动语态」出参 2708 token，其中 2182 是思维链）。
       * 超窗口的后果不是报错 —— 客户端会**安静地退回本地模板**，
       * 从外部看就是「讲解功能好像没用上 AI」。
       *
       * 关掉思维链后同一批题目 6.6–8.4s，**4/4 落进窗口，且全部通过 schema 校验**。
       * 原因是这条链路的输出 schema 本来就要求 `steps` 逐步写出解法 ——
       * 学生看到的分步过程还在，被去掉的是模型给自己看的草稿。
       *
       * ## 为什么默认不关（空数组）
       *
       * `thinking` 是**方舟特有的字段**，不是 OpenAI 兼容协议的一部分。
       * 网关可以指向本机 Ollama / vLLM（见 README「接本机模型」），
       * 那些服务收到不认识的字段可能直接 400 —— 把「本机跑得好好的」变成「上线就全挂」。
       * 所以这是个**显式开关**：谁用方舟、谁自己打开。
       *
       * 另外：判定（`reviewJudge`）**不建议**关 —— 它本来只花 21–84 个思维链 token
       * （实测 3.3–4.1s），关掉省不下时间，而它的准确率直接决定错题是否毕业。
       */
      /**
       * ⚠️ 这份名单**也必须分厂商** —— 它是本次改造里最容易漏掉的一处。
       *
       * 理由在 `MODEL_PROVIDERS.bailian` 的注释里：百炼在思维链开启时
       * **不接受** `tool_choice` 传对象，于是那些路由必须关掉思维链才能拿回
       * 硬约束；方舟没有这条限制，它的名单只用来省时间。所以两家的名单
       * **本来就该不一样**（实测两份 `.env.prod` 的差异：百炼那份多了
       * `reviewExplain,reviewPractice,reviewReferenceBatch`）。
       *
       * 不分厂商的后果全部是安静的：
       *  · 用方舟的短名单跑百炼 → 结构化输出的硬约束**悄悄降级**，偶发 502
       *  · 用百炼的长名单跑方舟 → 白关思维链，讲解变快但**推理质量下降**
       * 两者都不报错，都不会让人想到"名单是上一家的"。
       */
      thinkingDisabledKinds: kindListOf(
        providerEnvValue(env, provider, 'THINKING_DISABLED_KINDS', 'AI_THINKING_DISABLED_KINDS'),
      ),
    },

    /**
     * 语音合成（伴读）：`/ai/tts`。
     *
     * ⚠️ **刻意不跟 `AI_MODEL_PROVIDER` 走**，直接读 `BAILIAN_*`。
     *
     * `qwen3-tts-flash` 只有百炼有。若这里跟着当前厂商取 Key，切到方舟时
     * 伴读会拿方舟的 Key 去打百炼端点，回 401 —— 从外面看是「Key 配错了」，
     * 而实际上聊天那条路好好的。两种能力各有各的凭证，不该共用一个槽位。
     *
     * `enabled` 默认开：没有 Key 时 `synthesizeTts` 会回 `model_not_enabled`，
     * 那是一条能看懂的错，比「端点不存在」好查。
     */
    tts: {
      enabled: env.BAILIAN_TTS_ENABLED !== '0',
      apiKey: String(env.BAILIAN_API_KEY ?? '').trim(),
      baseUrl:
        String(env.BAILIAN_TTS_BASE_URL ?? '').trim() || 'https://dashscope.aliyuncs.com',
      model: String(env.BAILIAN_TTS_MODEL ?? '').trim() || 'qwen3-tts-flash',
      // ⚠️ 11-08：Cherry（芊悦）是**女声**，属于「男声=本机直连 /
      // 女声=云端 Qwen 兜底」的区分约定（见客户端 tts_voice.dart）。
      // 别把 BAILIAN_TTS_VOICE 改成 Ethan / Aiden 等男声，否则一听就
      // 分不出走的是哪条路。新客户端会显式带 voice，这里是老客户端的兜底。
      voice: String(env.BAILIAN_TTS_VOICE ?? '').trim() || 'Cherry',
    },

    /** 请求体上限。防火墙之外的最后一道闸，超过直接 413，不进模型。 */
    maxBodyBytes: intOf(env.AI_MAX_BODY_BYTES, 6 * 1024 * 1024),

    /** 单次请求最多几张作业照片。 */
    maxImages: intOf(env.AI_MAX_IMAGES, 4),

    /** 单次请求照片总体积上限（base64 解码后）。 */
    maxImageBytes: intOf(env.AI_MAX_IMAGE_BYTES, 3 * 1024 * 1024),

    /**
     * 配额：按**成本权重**记账，而不是按调用次数。
     *
     * ## 为什么不能用次数
     *
     * 一次作业批改要过视觉模型、带 4 张照片（输入 token 是纯文本的几倍），
     * 一次文本解析则便宜到可以忽略 —— 设计文档 §3 的估算里这两者差了
     * 两到三个数量级。用「次数」记账会同时错在两个方向：
     * - 学生做了 40 次文字解析就把当日额度用光，而他其实一分钱没花；
     * - 学生做 40 次拍照批改时额度还剩着，成本却已经超了预算。
     *
     * 所以额度单位是**成本单位**，每次调用按能力扣对应权重。
     * 权重不需要精确 —— 精确的是单价（见 `pricing`），这里只要
     * 「贵的场景扣得多」这个排序正确，额度就不会被打歪。
     *
     * ## 两个窗口各管一件事
     *
     * - **分钟窗口**：防脚本猛打。超限回 `rate_limited`（`retryable: true`），
     *   因为等一会儿真的能成。
     * - **天窗口**：防超支。超限回 `quota_exhausted`（**`retryable: false`**）——
     *   今天不会再好了，让客户端立刻回落本地并如实告知，
     *   而不是让它退避重试一个必然失败十几次的请求。
     */
    quota: {
      /**
       * 每分钟最多消耗的成本单位（防脚本猛打）。
       *
       * 定成「约等于一天的量」是刻意的：真正的成本闸门是天窗口，
       * 分钟窗口只管**别在一分钟内把一天的量烧光**。
       * 卡太紧会误伤正常使用 —— 学生对着一份 20 题的卷子点一次「提交检查」，
       * 客户端就会连着发 20 次判定（每次 2 单位 = 40 单位），
       * 一个正常的动作就能撞上限流。
       */
      unitsPerMinute: intOf(env.AI_QUOTA_UNITS_PER_MINUTE, 120),

      /**
       * 每日最多消耗的成本单位（真正的成本闸门）。
       *
       * 200 单位是照着设计文档 §3 的活跃日画像定的：
       * 1 次拍照批改（8）+ 2 份复习卷（20 题判定 ≈ 84）
       * + 讲解与出题（约 30）≈ 122，留一倍余量。
       *
       * 换算成最坏情况的成本：200 单位全走视觉 ≈ 25 次拍照批改，
       * 按 §3 的单价约 ¥0.3/天/学生。而按**次数**限流时，
       * 「每天 200 次」全走视觉就是 ¥2.3/天 —— 差 8 倍。
       * 这就是按成本权重记账的意义。
       */
      unitsPerDay: intOf(env.AI_QUOTA_UNITS_PER_DAY, 200),

      /** 每级能力的单次成本权重。视觉最贵，轻量几乎不计。 */
      weights: {
        [Capabilities.vision]: intOf(env.AI_WEIGHT_VISION, 8),
        [Capabilities.reasoning]: intOf(env.AI_WEIGHT_REASONING, 2),
        [Capabilities.light]: intOf(env.AI_WEIGHT_LIGHT, 1),
      },
    },

    /**
     * 单价：只用于**成本看板**的估算，不参与配额。
     *
     * 单位是「元 / 千 token」。**默认全空是一个刻意的选择**：
     * 价格随官方调价与模型换代而变，设计文档 §3 也写明「下单前以控制台
     * 实际定价为准」。与其写死一份很快过期的价格让看板报出一个错的数字，
     * 不如不配就如实显示「成本未知，仅有用量」——
     * 一个看起来精确的错数字，比「不知道」有害得多。
     *
     * 看板会把「未配单价」和「有调用没返回 usage」都单独标出来：
     * 前者让成本为空，后者让成本变成**下限**。这两种情况都必须显式可见，
     * 否则看板会安静地少报。
     */
    pricing: pricingFrom(env, provider),

    /**
     * 用量指标（成本看板的服务端口径）。
     *
     * ## 口径是**单实例**，这是刻意的
     *
     * 聚合放在进程内存里，响应里明确标 `scope: 'instance'`。
     * 看起来「不如全局准」，但另一条路（把每个计数写进共享 KV）在当前
     * 存储抽象下做不出正确结果：KV 只有 `get/set/incr`，没有键列举，
     * 实例之间无法把各自的快照合并成一份总数。
     *
     * 那就只剩两个选择：报一个**看起来是全局、其实是某个实例**的数字，
     * 或者如实标明口径。这个项目选后者 —— 一个错误的成本数字会导致
     * 错误的经营判断，比「不知道」有害得多。全局口径要靠把审计事件
     * 接到日志/指标服务（见 README 的已知限制）。
     */
    metrics: {
      /** 每个维度最多保留多少个取值（防止高基数把内存吃满）。 */
      maxDimensions: intOf(env.AI_METRICS_MAX_DIMENSIONS, 40),
      /** 延迟分位保留的样本数。窗口有限，所以分位是「最近 N 次」而不是全量。 */
      latencySamples: intOf(env.AI_METRICS_LATENCY_SAMPLES, 500),

      /**
       * 看板的访问口令。
       *
       * 用量数据不是学生数据，但它会把「这套系统一天跑多少量」摊开，
       * 公开可读是不合适的。配了它就要求带 `X-Metrics-Token`；
       * 没配则依赖常规身份校验（本地/内网够用，**公网部署必须配**）。
       * 与健康检查不同：health 只报能力开关，那是给监控探活用的。
       */
      token: env.AI_METRICS_TOKEN || '',
    },

    /** 配置里出现了已改名的旧变量。启动时会被拦下，见 validateConfig。 */
    deprecations: legacyEnvNotices(env),

    /**
     * 单次批量取参考答案的条数上限。
     *
     * 20 是照着「一页卷子」定的：再多就只是把延迟挪到批改那一步，
     * 而一次请求太大时模型漏项的概率也会上升（漏项要靠本地兜底补，
     * 补回来的精度明显更差）。
     */
    maxReferenceBatch: intOf(env.AI_MAX_REFERENCE_BATCH, 20),

    /** 结果缓存时长。相同输入不重复计费。 */
    cacheTtlMs: intOf(env.AI_CACHE_TTL_MS, 10 * 60 * 1000),
    cacheMaxEntries: intOf(env.AI_CACHE_MAX_ENTRIES, 500),

    /**
     * 现在是不是生产环境（`NODE_ENV=production`）。
     *
     * 判定本身在 `shared/env.js` —— 数据服务用同一份，两边**不允许各写一份**：
     * 「生产」这个词一旦分叉，代价是单侧的（一边按生产拦、另一边照旧放行）。
     *
     * 它出现在配置里而不是在 `validateConfig` 里直接读 `process.env`，
     * 是为了让测试能构造两种环境，不必真的去改进程环境变量。
     */
    production: isProduction(env),

    /**
     * 明知配额会被放大、仍要用进程内存兜底的显式确认。
     *
     * 生产环境默认**不许**用 `AI_KV_DRIVER=memory`：多实例下配额会成倍放大，
     * 而且没有任何症状（账单才看得出来）。真要做单实例的自用小部署，
     * 就显式写 `AI_ALLOW_EPHEMERAL_KV=true` —— 与 `SEED_DEMO_DATA=true`
     * 同一个思路：**默认拦，要开就明说**。
     */
    allowEphemeralKv: boolOf(env.AI_ALLOW_EPHEMERAL_KV, false),

    /**
     * 是否强制要求会话 token。
     *
     * ⚠️ 这里的注释曾经写着「默认 false 是过渡状态：当前客户端账号体系还是纯本地的」
     * —— **那句话已经过期**：客户端账号体系已上云（服务端签发 token，
     * 见 `doc/open-items.md` §A2），本机的演示栈也早已用 `AI_REQUIRE_AUTH=true` 起。
     * 所以生产环境的判断标准是明确的：**必须为 true**，
     * 因为 false 时 `studentId` 可以被请求头随意声明，配额与审计都失去意义。
     *
     * 置为 true 后，`studentId` **只从 token 里解**，请求头里那个被忽略 ——
     * 否则「加了鉴权」只是多要求一个字段，伪造者照样能声明自己是别人。
     * token 用 `scripts/issue-session-token.mjs` 签发（见 auth.js）。
     */
    requireAuth: boolOf(env.AI_REQUIRE_AUTH, false),

    /**
     * 共享 KV：限流计数与结果缓存的后端。
     *
     * 不配 `AI_KV_URL` 就退化成进程内存（单实例安全网），
     * 对本地联调与测试足够，**多实例上配额会成倍放大**。见 store.js。
     */
    kv: {
      driver: env.AI_KV_DRIVER || 'memory',
      url: env.AI_KV_URL || '',
      token: env.AI_KV_TOKEN || '',
      timeoutMs: intOf(env.AI_KV_TIMEOUT_MS, 1500),
      /**
       * 共享存储不可用时的配额策略。
       *
       * - `open`（默认）：记一条 `quota_degraded` 审计后放行，仅靠本地计数兜底
       * - `closed`：直接 503。适合「宁可停服也不能超支」的场景
       *
       * 默认选 `open` 的理由：KV 抖一下就把全体学生的 AI 能力停掉，
       * 代价比一次短暂的配额放大高得多。但这是个**业务选择**，
       * 所以做成开关而不是写死。
       */
      failMode: env.AI_KV_FAIL_MODE === 'closed' ? 'closed' : 'open',
    },

    auth: {
      /**
       * 会话 token 的签名密钥。
       *
       * `requireAuth: true` 时必须有值，否则网关会在启动装配时报错 ——
       * 「打开了鉴权开关但没有密钥」如果静默通过，结果是一个永远放行的
       * 假鉴权，比不鉴权更危险。
       */
      sessionSecret: env.AI_SESSION_SECRET || '',
      /** 会话有效期。 */
      sessionTtlSeconds: intOf(env.AI_SESSION_TTL_SECONDS, 12 * 3600),
    },

    /**
     * 模型客户端实现。
     * - `ark`（默认）：真实调用火山方舟
     * - `mock`：确定性假实现，仅用于本地联调与自动化测试
     *
     * mock 会如实把 `meta.model` 标成 `mock`。**绝不能用它兜底线上请求** ——
     * 那等于给用户编数据，而设计文档里已经写明「宁可承认降级，也不要给假数据」。
     */
    modelClient: env.AI_MODEL_CLIENT || 'ark',

    /**
     * 这台部署的身份（`SERVER_INSTANCE_ID`），`/ai/health` 原样回出。
     *
     * 与数据服务的同名配置**必须是同一个值** —— 客户端拿它判断
     * 「192.168.3.80 上那台是不是我的机器」。两边不一致时，数据面能选对、
     * AI 面选不对（或反过来），症状是「能登录但批改连不上」。
     */
    instanceId: env.SERVER_INSTANCE_ID || '',

    upload: {
      /**
       * 图片上传的签名方式。
       * - `proxy`：网关代收后用配置的 URL 前缀回填，仅适合本地联调
       * - `tos`：为火山引擎 TOS 生成直传预签名 URL（生产用法）
       */
      signer: env.AI_UPLOAD_SIGNER || 'proxy',
      /** proxy 模式下回填给客户端的对象 URL 前缀。 */
      proxyUrlBase: env.AI_UPLOAD_URL_BASE || '',
      /**
       * 上传凭证的签名密钥。
       *
       * **刻意不复用 ARK_API_KEY**：模型密钥一旦被用在别处，
       * 泄露面就从「一次调用」变成「一份可长期伪造的上传凭证」。
       */
      signingSecret: env.AI_UPLOAD_SIGNING_SECRET || '',
      ttlSeconds: intOf(env.AI_UPLOAD_TTL_SECONDS, 600),
      tos: {
        bucket: env.TOS_BUCKET || '',
        region: env.TOS_REGION || arkRegion,
        endpoint: env.TOS_ENDPOINT || `tos-${arkRegion}.volces.com`,
        accessKeyId: env.TOS_ACCESS_KEY_ID || '',
        accessKeySecret: env.TOS_ACCESS_KEY_SECRET || '',
        /** 使用临时 AK/SK（STS）时才需要。 */
        securityToken: env.TOS_SECURITY_TOKEN || '',
        /** 上传对象的公共读前缀。配了 CDN 域名就填这里。 */
        objectUrlBase: env.TOS_OBJECT_URL_BASE || '',
        /**
         * 对象 URL 的有效期，**必须明显长于上传凭证**。
         *
         * 模型是在批改时才去抓图的：凭证 10 分钟、对象 URL 也 10 分钟时，
         * 学生传完图去倒杯水回来，批改抓图就是 403。
         * 所以这里默认 1 小时，且不少于上传凭证的 4 倍。
         */
        objectTtlSeconds: intOf(env.TOS_OBJECT_TTL_SECONDS, 3600),
      },
    },
  };
}

/**
 * 哪些能力真的可用。
 *
 * 客户端会拿它来决定「要不要把 3MB 照片发上来」。
 * 因此这里汇报的必须是**真实可调用**的状态：模型 ID 有值**且**有 Key，
 * 少一个条件都算不可用。
 */
export function capabilityReport(config) {
  const hasKey = config.ark.apiKey !== '';
  return {
    vision: hasKey && config.ark.models[Capabilities.vision] !== '',
    reasoning: hasKey && config.ark.models[Capabilities.reasoning] !== '',
    light: hasKey && config.ark.models[Capabilities.light] !== '',
  };
}

/**
 * 启动前的配置自检。
 *
 * 只查「配错了会静默产生错误行为」的那几项 —— 缺 ARM_API_KEY 之类
 * 会在第一次调用时如实报 model_not_enabled，不需要在这里拦。
 *
 * 反过来，`requireAuth: true` 但没有密钥这种组合必须拦下来：
 * 它的失败形态是**永远放行**，从外部看和「鉴权正常工作」一模一样。
 */
export function validateConfig(config) {
  const problems = [];

  // 改过名的旧变量：既不映射也不忽略，启动就报错。理由见 RENAMED_ENV。
  for (const notice of config.deprecations ?? []) {
    problems.push(notice);
  }

  /**
   * 厂商名认不出来 —— **启动就拦**，不回落默认值。
   *
   * 回落的失败形态是：用着方舟的字段、打着方舟的地址，但你以为在用百炼。
   * 那不会报「厂商名拼错了」，只会回 401 或 404（看着像「密钥配错了」），
   * 够查半天。拼错一次的成本远低于查半天的成本。
   */
  if (!config.modelProviderSpec) {
    const known = Object.keys(MODEL_PROVIDERS);
    problems.push(
      `AI_MODEL_PROVIDER=${config.modelProvider} 不是已知的模型厂商。`
        + `可选：${known.join(' / ')}（留空则为 ${DEFAULT_MODEL_PROVIDER}）`,
    );
  }

  /**
   * 厂商与模型 ID 的「形态」对不对 —— 这条专治**跨厂商复制粘贴**。
   *
   * 方舟的模型 ID 带日期后缀（`doubao-seed-2-1-pro-260628`），
   * 百炼的模型名是 `qwen3-max` / `qwen3-vl-plus` 这种。两边**互不认**。
   * 从旧部署复制一整套环境变量过去时，最容易漏改的就是模型名 ——
   * 而它的报错（`invalid_parameter_error`）里**未必带模型名**，很难定位。
   *
   * ⚠️ 2026-09-30 补上**反方向**（选了方舟却填百炼名）。原因不是对称好看：
   * 两套配置现在**并列写在同一份 `.env.prod` 里**（`ARK_*` 与 `BAILIAN_*`），
   * 「复制粘贴时看错是哪一块」从「手抖」变成了**最常见的失手方式**。
   *
   * ⚠️ 两条守卫都**只在端点还是厂商默认地址时**生效。
   * 理由：「两家的模型名互不认」这个前提，在你把 `*_BASE_URL` 指向
   * 自建网关 / 本机 Ollama / vLLM 时就不成立了 —— 那里 `llama3`、
   * `qwen2.5:7b` 都是合法值，拦下来就是把守卫变成路障
   * （README「接本机模型」那条退路会被断掉，`test/probe-ollama.test.js` 盯着它）。
   */
  const spec = config.modelProviderSpec;
  const onDefaultEndpoint = Boolean(spec)
    && config.ark?.baseUrl === spec.defaultBaseUrl(config.ark?.region ?? spec.defaultRegion);

  if (onDefaultEndpoint && spec.label === '阿里云百炼') {
    for (const [cap, id] of Object.entries(config.ark?.models ?? {})) {
      if (id !== '' && !looksLikeBailianModel(id)) {
        problems.push(
          `AI_MODEL_PROVIDER=bailian 但 ${cap} 档的模型 ID 是 "${id}"，`
            + '它不像百炼的模型名（百炼用 qwen3-max / qwen3-vl-plus 这种）。'
            + '多半是从方舟的配置整段复制过来时漏改了 —— 这种错在调用时才报，'
            + '而且报错信息里未必带模型名',
        );
      }
    }
  }

  /**
   * 反方向：选了方舟，模型名却是百炼那一套。
   * 判据比上面那条**严得多**（只认 `doubao-` / `ep-` / 日期后缀这种铁证），
   * 所以不会拦住任何形态陌生的自建模型名。
   */
  if (onDefaultEndpoint && spec.label === '火山引擎方舟') {
    for (const [cap, id] of Object.entries(config.ark?.models ?? {})) {
      if (id !== '' && !looksLikeArkModel(id)) {
        problems.push(
          `AI_MODEL_PROVIDER=ark 但 ${cap} 档的模型 ID 是 "${id}"，`
            + '它不像方舟的模型名（方舟用 doubao-… / ep-… 这种，多带日期后缀）。'
            + '多半是两套配置都写在同一份 .env.prod 里、切换时改错了块 —— '
            + '或者 ARK_MODEL_* 还留着上一家的值。'
            + '若这个端点其实是自建网关/本机模型，请显式设 ARK_BASE_URL 覆盖默认地址',
        );
      }
    }
  }

  if (config.requireAuth && config.auth.sessionSecret === '') {
    problems.push(
      'AI_REQUIRE_AUTH=true 但 AI_SESSION_SECRET 为空：'
        + '打开鉴权却没有签名密钥，会让所有请求都校验失败（或全部放行）',
    );
  }

  /**
   * ===== 生产档：下面这几条在开发环境是**常态**，在生产是「安静地出大事」=====
   *
   * 它们和上面那些的区别在于「什么时候才该拦」：`AI_REQUIRE_AUTH=false`
   * 本机开发时完全正常，所以不能无条件拦 —— 但生产环境必须拦，
   * 因为它的失败形态是**永远放行**，从外部看和「鉴权正常工作」一模一样。
   * 这正是本项目最常踩的那种坑（见 open-items 的「静默失败」清单）。
   */
  if (config.production) {
    if (!config.requireAuth) {
      problems.push(
        '生产环境 AI_REQUIRE_AUTH 不是 true：此时 studentId 由请求头 X-Student-Id 声明，'
          + '而它**可被任意伪造** —— 配额与审计都失去意义。'
          + '接口表现与「鉴权正常工作」完全一样，所以只能在这里拦',
      );
    }

    if (config.modelClient === 'mock') {
      problems.push(
        '生产环境 AI_MODEL_CLIENT=mock：识别 / 批改 / 讲解返回的全是**写死的假数据**，'
          + '界面完全正常、日志也没有异常。联调请用非生产环境',
      );
    }

    if (config.kv.driver !== 'http' && !config.allowEphemeralKv) {
      problems.push(
        `生产环境 AI_KV_DRIVER=${config.kv.driver}（不是 http）：配额计数落在**每个实例各自的内存**里，`
          + '多实例下额度会成倍放大，而且没有任何症状（要等账单才看得出来）。'
          + '指到共享 KV 就配 AI_KV_URL；确实要做单实例自用部署，'
          + '就显式写 AI_ALLOW_EPHEMERAL_KV=true',
      );
    }

    if (config.auth.sessionSecret === DEV_STACK_SECRET) {
      problems.push(
        `生产环境 AI_SESSION_SECRET 用的是仓库里公开的那把开发密钥（${DEV_STACK_SECRET}）：`
          + '任何人拿它都能自己签一张有效的会话票，并以此花你的模型额度',
      );
    }
  }

  const quota = config.quota ?? {};
  const weights = quota.weights ?? {};
  const heaviest = Math.max(0, ...Object.values(weights));
  if (quota.unitsPerDay > 0 && heaviest > quota.unitsPerDay) {
    // 这种情况下最贵的那级能力**一次都调不动**，但接口会一切正常地
    // 返回 429 —— 表现和「模型没开通」很像，排查成本很高。
    problems.push(
      `每日额度 ${quota.unitsPerDay} 单位，而最贵的场景一次就要 ${heaviest} 单位：`
        + '该场景将永远不可用，请调大 AI_QUOTA_UNITS_PER_DAY 或调小权重',
    );
  }

  // 思维链开关里写了不存在的路由名。
  //
  // 这类拼写错误**不会报错、只会静默不生效** —— 表现为「我明明关掉了思维链，
  // 讲解还是超窗口」，而排查方向会落到模型、网络、超时上，因为配置看起来是对的。
  // 和上面那条「声明了配额但没有能力档位」是同一类：部署时就炸掉，不要带到线上。
  const disabledKinds = config.ark?.thinkingDisabledKinds ?? [];
  const knownKinds = Object.keys(CAPABILITY_BY_KIND);
  const unknownKinds = disabledKinds.filter(
    (kind) => kind !== '*' && !knownKinds.includes(kind),
  );
  if (unknownKinds.length > 0) {
    problems.push(
      `AI_THINKING_DISABLED_KINDS 里有不存在的路由名：${unknownKinds.join(' / ')}。`
        + `可选：${knownKinds.join(' / ')}（或用 * 表示全部）`,
    );
  }

  // 「单价填了、但读不出数字」—— 这一条必须响亮地报出来。
  //
  // `floatOf` 把「空」和「看不懂」**都**归成 null，于是 `pricingState` 只看到 null。
  // 六个单价全填成 `¥0.008`（从控制台抄价格时最常见的形态）会被判成
  // 「一个都没配」→ 放行 → 部署成功、看板显示「未配置模型单价」，
  // 而 `.env.prod` 里明明填了。用户只会一遍遍重填，这个状态永远不会消失。
  const invalidPrices = config.pricing?.invalidRaw ?? [];
  if (invalidPrices.length > 0) {
    problems.push(
      `这些单价填了但读不出数字：${invalidPrices.join(' / ')}。`
        + '只接受纯数字，单位是「元 / 千 token」（例：AI_PRICE_VISION_IN=0.008）—— '
        + '不要带货币符号或单位字样：parseFloat 读到前导符号只会得到 NaN',
    );
  }

  const priceState = pricingState(config);
  if (priceState === 'partial') {
    problems.push(
      '成本单价只配了一部分：缺口的那部分会被算成 0，看板报出的总额会偏小。'
        + '要么配齐三级能力的输入/输出单价，要么全部留空（看板会显示「成本未知」）',
    );
  }

  if (config.kv.driver === 'http' && config.kv.url === '') {
    problems.push('AI_KV_DRIVER=http 但 AI_KV_URL 为空');
  }

  if (config.upload.signer === 'tos') {
    const { bucket, accessKeyId, accessKeySecret } = config.upload.tos;
    if (bucket === '' || accessKeyId === '' || accessKeySecret === '') {
      problems.push(
        'AI_UPLOAD_SIGNER=tos 但 TOS_BUCKET / TOS_ACCESS_KEY_ID / '
          + 'TOS_ACCESS_KEY_SECRET 未配齐',
      );
    }
  }

  if (config.upload.signer === 'tos' && config.upload.tos.objectTtlSeconds
      < config.upload.ttlSeconds * 2) {
    problems.push(
      'TOS_OBJECT_TTL_SECONDS 不足上传凭证的 2 倍：'
        + '模型去抓图时对象 URL 很可能已经过期（表现为批改拿不到照片）',
    );
  }

  return problems;
}

/**
 * 单价的配置状态。
 *
 * - `none`：一个都没配 → 看板如实显示「成本未知」
 * - `partial`：配了一半 → 缺的会被当 0，看板会**少报**。这是最坏的一种：
 *   它既没有「未知」的诚实，又没有完整的正确。启动时拦下。
 * - `full`：可以算成本
 */
export function pricingState(config) {
  const inputs = Object.values(config.pricing?.inputPerKToken ?? {});
  const outputs = Object.values(config.pricing?.outputPerKToken ?? {});
  const all = [...inputs, ...outputs];
  if (all.length === 0) return 'none';
  if (all.every((value) => value === null || value === undefined)) return 'none';
  return all.every((value) => typeof value === 'number') ? 'full' : 'partial';
}
