import { Capabilities, MODEL_PROVIDERS } from './config.js';
import {
  ErrorCodes,
  GatewayError,
  badRequest,
  modelAuthFailed,
  modelNotEnabled,
  modelTimeout,
  modelUnavailable,
  schemaViolation,
  toGatewayError,
} from './errors.js';
import { protectLatexEscapes } from './latex-guard.js';
import { repairStringifiedStructures, toTool, validate } from './schema.js';

/**
 * 火山方舟的模型客户端。
 *
 * 数据面地址：`https://ark.<region>.volces.com/api/v3/chat/completions`，
 * 鉴权：`Authorization: Bearer <ARK_API_KEY>`。
 *
 * 三级能力路由到三级模型（视觉 / 强推理 / 轻量）。**不按「哪个便宜用哪个」兜底**：
 * 某个能力没配模型就如实报 `model_not_enabled`，绝不用轻量档顶上 ——
 * 拿轻量模型做错题判定会静默产生错判，而错判会让学生对整套闭环失去信任。
 *
 * 重试的职责边界：本类只重试**传输层**失败（429 / 5xx / 超时 / 连不上）。
 * 结构化输出的违约重试由客户端负责（它才能把「上次错在哪」写回提示词），
 * 两边都不重复重试同一类问题，最坏情况的总调用次数是可算的：2×2=4。
 */
/**
 * 这条路由要不要关掉思维链。
 *
 * 名单是**路由名（kind）**而不是能力档位：同一个 `reasoning` 档下，
 * 判定要准（不该关）、讲解/出题要快（该关），按档位做开关会把两件相反的事捆在一起。
 *
 * 抽成导出的纯函数是为了可测 —— 这段判断的失败方式很安静：
 * 名单里拼错一个词的结果是「参数没发出去」，而请求仍然成功，
 * 只有耗时不对。见 `test/thinking.test.js`。
 */
export function thinkingDisabled(disabledKinds, kind) {
  if (!Array.isArray(disabledKinds) || disabledKinds.length === 0) return false;
  if (disabledKinds.includes('*')) return true;
  return typeof kind === 'string' && kind !== '' && disabledKinds.includes(kind);
}

/**
 * 按「所选厂商」拼请求体。**抽成导出的纯函数**，理由有两个：
 *
 * 1. 这里是两家厂商**唯一**的协议分叉点。散在 `complete()` 里的话，
 *    「换个厂商要动几处」就没人说得清了 —— 而现在只需要读这一个函数。
 * 2. 可测。协议差异的失败形态都很安静（字段被静默忽略、或 400 但信息量低），
 *    必须有断言直接盯住「发出去的 body 长什么样」。
 *    见 `test/provider-switch.test.js`。
 *
 * @param {object} params
 * @param {string} params.model 模型 ID
 * @param {object} params.schema 结构化输出 schema
 * @param {string} params.system 系统提示词
 * @param {string|object[]} params.content 用户消息
 * @param {number} params.temperature
 * @param {boolean} params.thinkingOff 这条路由是否要关思维链
 * @param {object|null} params.provider 厂商预设（见 config.js 的 MODEL_PROVIDERS）
 */
export function buildRequestBody({
  model,
  schema,
  system,
  content,
  temperature,
  thinkingOff,
  provider,
}) {
  const body = {
    model,
    messages: [
      { role: 'system', content: system },
      { role: 'user', content },
    ],
    // 结构化输出靠 function calling 硬约束，而不是在提示词里求模型「请返回 JSON」。
    // JSON mode 只保证「是合法 JSON」，不保证「是你想要的字段」。
    tools: [toTool(schema)],
    // ⚠️ 这个值**取决于厂商与思维链状态**，两件事的交点：
    //   · 方舟：思维链开着时也允许传对象 → 始终传对象，结构约束最紧
    //   · 百炼：思维链开着时传对象直接 400 → 此时只能退成 'auto'
    // 注意退成 'auto' 是**有代价的**：不再强制调用指定函数，
    // 结构约束从「硬」降为「软」。所以这里的选择要显式，不能靠「反正都能跑」。
    tool_choice: shouldSendToolChoiceObject({ thinkingOff, provider })
      ? { type: 'function', function: { name: schema.name } }
      : 'auto',
    temperature,
  };

  // 关思维链。**默认不发**（名单为空）—— 见 config.js 里 AI_THINKING_DISABLED_KINDS 的说明。
  //
  // ⚠️ 字段名与取值由厂商决定，**不是**方舟那一套能照搬的：
  //   方舟 body.thinking = { type: 'disabled' }
  //   百炼 body.enable_thinking = false
  // 照搬的后果是「字段不被认识」→ 多数服务端静默忽略 → 思维链根本没关，
  // 讲解悄悄超时，从外部看只是「好像没用上 AI」。
  if (thinkingOff) {
    // ⚠️ `provider` 缺失时**回落到方舟的字段**，而不是静默不发。
    //
    // 理由：`config` 并不总是 `loadConfig()` 造的（测试、以及将来可能出现的
    // 嵌入式用法都会手搓 config）。静默不发的失败形态是「思维链没关掉」——
    // 而它**不会报错**，只是讲解偶尔超时，很难归因。
    // 回落到方舟则与本次改动前的行为**逐字节一致**，不会引入新的静默差异。
    const off = provider?.thinkingOff ?? MODEL_PROVIDERS.ark.thinkingOff;
    body[off.field] = off.value;
  }

  return body;
}

/**
 * 这个请求能不能把 `tool_choice` 发成对象。
 *
 * 规则只有一条，但它**是两个条件的交点**，所以单独成函数：
 * 厂商允许传对象（方舟是、百炼不是）**且** 这条路由没在开思维链
 * —— 百炼的限制只在「思维链开启时」生效。
 *
 * 换句话说：**百炼 + 关思维链** 仍然可以传对象（我们照样拿到硬约束），
 * 只有 **百炼 + 开思维链** 那一小撮请求要退成 'auto'。
 * 这个区分很重要：不做的话会把本来能拿到的结构保证也一起丢掉。
 */
export function shouldSendToolChoiceObject({ thinkingOff, provider }) {
  if (provider && provider.toolChoiceObjectAllowed === false) {
    // 百炼：思维链开着时不能传对象。
    return thinkingOff;
  }
  return true;
}

export class ArkModelClient {
  constructor({ config, fetchImpl, sleep }) {
    this.config = config;
    this.fetch = fetchImpl ?? globalThis.fetch;
    this.sleep = sleep ?? defaultSleep;
  }

  /** 当前真正可调用的能力。供 `/ai/health` 汇报给客户端。 */
  capabilities() {
    const hasKey = this.config.ark.apiKey !== '';
    const models = this.config.ark.models;
    return {
      vision: hasKey && models[Capabilities.vision] !== '',
      reasoning: hasKey && models[Capabilities.reasoning] !== '',
      light: hasKey && models[Capabilities.light] !== '',
    };
  }

  /**
   * 调用一次模型并校验输出结构。
   *
   * @param {object} params
   * @param {string} params.capability 三级能力之一，决定用哪个模型
   * @param {object} params.schema 结构化输出的 schema（见 schema.js）
   * @param {string} params.system 系统提示词
   * @param {string|object[]} params.content 用户消息，多模态时传 content 片段数组
   * @param {string} [params.kind] 路由名（`reviewExplain` 等）。只用来决定要不要关思维链，
   *   不参与选模型 —— 选模型只认 `capability`，两件事分开才不会互相污染。
   * @returns {Promise<{value: object, model: string, usage: object|null, finishReason: string}>}
   */
  async complete({
    capability,
    kind = '',
    schema,
    system,
    content,
    temperature = 0.2,
  }) {
    const model = this.config.ark.models[capability] ?? '';
    if (model === '' || this.config.ark.apiKey === '') {
      throw modelNotEnabled(capability);
    }

    // 请求体由**纯函数**拼，厂商差异集中在 buildRequestBody 里（见那里的注释）。
    // 这里只负责「这条路由要不要关思维链」这个业务判断。
    const body = buildRequestBody({
      model,
      schema,
      system,
      content,
      temperature,
      thinkingOff: thinkingDisabled(this.config.ark.thinkingDisabledKinds, kind),
      provider: this.config.modelProviderSpec,
    });

    const attempts = Math.max(1, this.config.ark.maxAttempts);
    let lastError;

    for (let attempt = 1; attempt <= attempts; attempt++) {
      let result;
      try {
        result = await this.#call(body);
      } catch (cause) {
        // 只有**传输层**失败才在这里重试。见类注释里的职责边界说明。
        lastError = toGatewayError(cause);
        if (!lastError.retryable) break;
        if (attempt < attempts) await this.sleep(backoffMs(attempt));
        continue;
      }

      /**
       * ⚠️ 顺序：**先修形态、再校验**（见 config.js 的 `stringifiesStructuredArgs`）。
       *
       * 有些厂商会把本该是数组/对象的位置序列化成字符串（百炼实测 4/4）。
       * 修完照样走同一份 `validate` —— **只放宽形态、不放宽内容**：
       * 字符串里装的若不是那份结构，一样判违规。
       *
       * 修好的值必须**回填进 result**，因为它后面会被写进缓存并被返回。
       * 只在校验时用、不回填的话，缓存里留下的仍是那个坏值，
       * 于是症状变成「每次都是第一次失败、之后从缓存拿到坏值再失败」。
       */
      const value = this.config.modelProviderSpec?.stringifiesStructuredArgs
        ? repairStringifiedStructures(schema, result.value)
        : result.value;

      const problems = validate(schema, value);
      if (problems.length > 0) {
        // **不在这里重试**：提示词一个字没变，模型大概率原样再错一遍，
        // 白白多烧一次 token。有意义的第二次要带上 retryHint ——
        // 那需要「上次错在哪」这个信息，只有客户端有（它同时握着本地兜底实现）。
        //
        // 注意这里必须直接抛，不能落进上面的 catch：
        // schemaViolation 标了 retryable: true（客户端需要重试），
        // 落进 catch 就会被本类再重试一遍，两处重试叠加成 4 次调用。
        throw schemaViolation(problems);
      }
      return value === result.value ? result : { ...result, value };
    }

    throw lastError;
  }

  async #call(body) {
    // 报错文案里的厂商名必须**跟着 config 走**，不能写死。
    // 写死的后果：切到百炼之后，400 的文案还是「方舟拒绝请求 —— 它通常直接点明是哪个
    // model 不存在」→ 运维去翻方舟控制台找模型名，而真正要改的是百炼的。
    // 这与「用甲家的地址、乙家的 Key」是同一类：**报错指向了错误的方向**。
    const label = providerLabel(this.config);
    const url = `${this.config.ark.baseUrl}/chat/completions`;
    const timeoutMs = this.config.ark.timeoutMs;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);

    let response;
    try {
      response = await this.fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${this.config.ark.apiKey}`,
        },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
    } catch (cause) {
      if (cause?.name === 'AbortError' || cause?.name === 'TimeoutError') {
        throw modelTimeout(`模型调用超过 ${timeoutMs}ms 未返回`);
      }
      throw modelUnavailable(`无法连接${label}：${cause?.message ?? cause}`);
    } finally {
      clearTimeout(timer);
    }

    const text = await response.text().catch(() => '');
    if (!response.ok) {
      throw mapHttpError(response.status, text, body.model, label);
    }

    let payload;
    try {
      payload = JSON.parse(text);
    } catch {
      throw new GatewayError(
        ErrorCodes.modelOutputInvalid,
        `${label}返回的不是合法 JSON`,
        { status: 502, retryable: true },
      );
    }

    return extractResult(payload, body.model, label);
  }
}

/**
 * 从模型响应里取出结构化结果。
 *
 * 优先读 `tool_calls[0].function.arguments`；读不到时回落到 `content`。
 * 这个兜底不是「宽容」，是必需的：并非所有模型/接入点都支持
 * tool calling，只认 tool_calls 会让那些模型 100% 失败，
 * 而症状看起来和「模型不可用」一模一样。
 *
 * ⚠️ 但**兜底不等于等价**。`content` 里是散文时 `parseStructured` 会失败，
 * 于是落到 `model_output_invalid`。而「模型会不会主动调工具」**正是**
 * `tool_choice` 从对象退成 `'auto'` 时丢掉的那部分保证 ——
 * 百炼 + 思维链开着就会退（见 `shouldSendToolChoiceObject`）。
 * 所以这条兜底把「本来会彻底跑不起来」降级成「偶发一条 502、可重试」，
 * 而不是让它变成「一定没事」。想拿到硬约束，就得让那条路由关思维链。
 */
function extractResult(payload, model, label = '模型服务') {
  const choice = payload?.choices?.[0];
  const message = choice?.message;
  if (!message) {
    throw new GatewayError(
      ErrorCodes.modelOutputInvalid,
      `${label}响应里没有 choices[0].message`,
      { status: 502, retryable: true },
    );
  }

  const toolCall = message.tool_calls?.[0];
  const raw = toolCall?.function?.arguments;

  if (raw !== undefined && raw !== null && raw !== '') {
    return {
      value: parseStructured(raw),
      model,
      usage: payload.usage ?? null,
      finishReason: choice.finish_reason ?? '',
    };
  }

  const content = flattenContent(message.content);
  if (content !== '') {
    return {
      value: parseStructured(content),
      model,
      usage: payload.usage ?? null,
      finishReason: choice.finish_reason ?? '',
    };
  }

  throw new GatewayError(
    ErrorCodes.modelOutputInvalid,
    `${label}返回了空结果（finish_reason: ${choice.finish_reason ?? '未知'}）`,
    { status: 502, retryable: true },
  );
}

/** 把可能是「JSON 字符串 / 已解析对象 / 带代码块围栏的字符串」的内容归一成对象。 */
function parseStructured(raw) {
  if (typeof raw === 'object' && raw !== null) return raw;

  const text = String(raw).trim();
  for (const candidate of jsonCandidates(text)) {
    try {
      // ⚠️ 先过 LaTeX 转义保护：模型少转义一层时 `\frac` 会被静默吃成
      // 换页符 + `rac`（见 latex-guard.js 的事故记录）。正常转义的输入
      // 一个字节都不会变 —— 保护是幂等且保守的。
      const parsed = JSON.parse(protectLatexEscapes(candidate));
      if (typeof parsed === 'object' && parsed !== null) return parsed;
    } catch {
      // 试下一个候选形态。
    }
  }

  throw new GatewayError(
    ErrorCodes.modelOutputInvalid,
    `模型输出无法解析为 JSON：${truncate(text)}`,
    { status: 502, retryable: true },
  );
}

/**
 * 按「最可能先是 JSON」的顺序列出候选文本。
 *
 * 现场遇到的脏输出就这三种，按概率排序：
 * 1. 干净 JSON（多数情况，因为 tool_choice 约束住了）
 * 2. 包在 ```json 围栏里，前面可能还有一句「好的，以下是结果：」
 * 3. 前后各有一段废话，但中间那对花括号里是 JSON
 *
 * 第 3 种不能省：模型在提示词里被要求「只输出 JSON」之后，
 * 常见反应是「好的，我明白了。{...}」——只做 trim 的话整条链路直接降级，
 * 而学生看到的会是「AI 讲解暂时不可用」。
 */
function jsonCandidates(text) {
  const candidates = [text];

  const fenced = text.match(/```(?:json|JSON)?\s*([\s\S]*?)```/);
  if (fenced) candidates.push(fenced[1].trim());

  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start >= 0 && end > start) candidates.push(text.slice(start, end + 1));

  return [...new Set(candidates)];
}

/** content 可能是字符串，也可能是 [{type:'text', text}] 片段数组。 */
function flattenContent(content) {
  if (typeof content === 'string') return content.trim();
  if (Array.isArray(content)) {
    return content
      .map((part) => (typeof part === 'string' ? part : part?.text ?? ''))
      .join('')
      .trim();
  }
  return '';
}

/**
 * 报错文案里该显示的厂商名。
 *
 * 取不到时回落「模型服务」而**不是某一家的名字** —— 回落错一家比不回落更糟：
 * 文案会把排查方向指到另一家的控制台去，而那里根本没有这条记录。
 * （`config` 并不总是 `loadConfig()` 造的：测试、以及将来的嵌入式用法会手搓，
 *   所以这里必须能容忍缺字段。）
 */
function providerLabel(config) {
  return config?.modelProviderSpec?.label ?? '模型服务';
}

/** 把 HTTP 状态码映射成带 retryable 语义的网关错误。 */
function mapHttpError(status, text, model, label = '模型服务') {
  const detail = extractErrorMessage(text);

  if (status === 401 || status === 403) {
    return modelAuthFailed(detail || `HTTP ${status}`);
  }
  if (status === 429) {
    return modelUnavailable(`${label}限流（429）：${detail || '请稍后重试'}`);
  }
  if (status === 408) {
    return modelTimeout(`${label}侧超时`);
  }
  if (status >= 500) {
    return modelUnavailable(`${label}服务异常（${status}）：${detail}`);
  }
  // 剩下的 4xx 基本是「模型 ID 写错 / 参数不被支持」。
  // 把对方返回的原文带出来 —— 它通常直接点明是哪个 model 不存在，
  // 而这条信息只能在运维侧用，不该被吞掉。
  return badRequest(`${label}拒绝请求（${status}，model=${model}）：${detail}`);
}

function extractErrorMessage(text) {
  try {
    const parsed = JSON.parse(text);
    return (
      parsed?.error?.message ??
      parsed?.message ??
      parsed?.error?.code ??
      truncate(text)
    );
  } catch {
    return truncate(text);
  }
}

function truncate(value, max = 200) {
  const text = String(value ?? '');
  return text.length <= max ? text : `${text.slice(0, max)}…`;
}

function backoffMs(attempt) {
  // 不做指数退避：一次批改的等待预算本来就只有十几秒，
  // 退避到 2s、4s 反而先把用户的耐心耗尽。
  return 300 * attempt;
}

const defaultSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export { Capabilities };
