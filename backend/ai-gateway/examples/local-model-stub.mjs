import http from 'node:http';

/**
 * 本机模型替身：一个最小的 **OpenAI 兼容** chat/completions 端点。
 *
 * ## 它是给谁用的
 *
 * 用来回答一个问题：「如果我把大模型部署在本机，网关能不能不改代码接上去？」
 *
 * 答案是能，而且网关这边**一行都不用改** —— 因为它调模型走的就是
 * 标准 OpenAI Chat Completions 协议（`POST {base}/chat/completions`、
 * `Authorization: Bearer`、`tools` + `tool_choice` 做结构化输出、
 * 多模态走 `image_url` 片段）。方舟只是这个协议的一个实现，
 * Ollama / vLLM / llama.cpp / LM Studio / SGLang 也都是。
 *
 * 所以把这个替身跑起来、把 `ARK_BASE_URL` 指过来，整条链路就该通 ——
 * 通不了就说明「不是配置问题，是代码假设了方舟的某个行为」。
 * 这正是它存在的意义：**在下载一个真模型之前，先把这一层验掉。**
 *
 * ## 它怎么生成输出（这一点很重要）
 *
 * 它**不是**在编业务数据，而是**照着请求里的 schema 合成一个结构合法的对象**：
 * 读 `tools[0].function.parameters`，按 `required` / `type` / `enum` /
 * `minItems` 递归造出形状正确的值。于是网关侧 `validate()` 会通过，
 * 链路能一路走到客户端。
 *
 * 这么写有两个好处：
 * - 不同端点（批改 / 判定 / 讲解 / 出题）的 schema 各不相同，而它不用逐个写死 ——
 *   业务契约改了它也不会烂掉。
 * - 顺便证明了 `toTool()` 产出的**确实是标准 JSON Schema**（自研 schema 的字段名
 *   恰好都是 JSON Schema 关键字）。若哪天有人在内部 schema 里加了私有字段，
 *   这个替身会立刻解析不出来 —— 算是条廉价的护栏。
 *
 * ## 用法
 *
 * ```bash
 * node examples/local-model-stub.mjs            # 默认 127.0.0.1:8792
 * PORT=9000 node examples/local-model-stub.mjs
 * ```
 *
 * 然后按 README「接本机模型」那一节的变量起网关即可。
 * **它只回结构合法的占位内容，不懂题目** —— 不要拿它的输出判断效果好坏。
 */

const port = Number.parseInt(process.env.PORT ?? '8792', 10);

/**
 * 按 schema 造一个结构合法的值。
 *
 * 取 `enum[0]`、`minimum`、`minItems` 这些边界值而不是随便填：
 * 随机值会让「第一次跑过了、第二次没跑过」这种偶发变得无从复现。
 */
function synthesize(schema) {
  const spec = schema && typeof schema === 'object' ? schema : {};

  if (Array.isArray(spec.enum) && spec.enum.length > 0) return spec.enum[0];

  switch (spec.type) {
    case 'object': {
      const properties = spec.properties ?? {};
      const out = {};
      for (const key of spec.required ?? []) {
        out[key] = synthesize(properties[key] ?? { type: 'string' });
      }
      return out;
    }
    case 'array': {
      const count = Math.max(1, spec.minItems ?? 1);
      const item = spec.items ?? { type: 'string' };
      return Array.from({ length: count }, () => synthesize(item));
    }
    case 'integer':
    case 'number':
      return spec.minimum ?? 1;
    case 'boolean':
      return true;
    default: {
      // 字符串：先满足 minLength（网关只校验「去空格后非空」）。
      const minLength = Math.max(1, spec.minLength ?? 1);
      let text = '本机模型替身输出';
      while (text.length < minLength) text += '…';
      return text;
    }
  }
}

/** 从请求体里取出「第一个工具函数」的期望形状；取不到就回一个通用对象。 */
function buildArguments(body) {
  const fn = body?.tools?.[0]?.function;
  if (!fn?.parameters) return { ok: true };
  return synthesize(fn.parameters);
}

const server = http.createServer((request, response) => {
  let raw = '';
  request.on('data', (chunk) => {
    raw += chunk;
  });
  request.on('end', () => {
    let body = {};
    try {
      body = JSON.parse(raw || '{}');
    } catch {
      // 故意不返回 400：真实的 OpenAI 兼容服务在 body 坏了时行为各异，
      // 而这里要验的是「网关怎么处理模型的怪响应」，不是替身的健壮性。
    }

    const fnName = body?.tools?.[0]?.function?.name ?? 'report_result';
    // 方舟的 `finish_reason` 在工具调用时是 `tool_calls`；照抄它，
    // 这样网关拿到的形状与真实调用一致（它把这个字段透传给客户端）。
    const finishReason = body?.tools?.length ? 'tool_calls' : 'stop';

    console.log(
      `  ← 收到调用｜model=${body?.model ?? '(未指定)'}`
        + `｜function=${fnName}`
        + `｜images=${countImages(body)}`
        + `｜messages=${body?.messages?.length ?? 0}`,
    );

    const payload = {
      id: `stub-${Date.now()}`,
      object: 'chat.completion',
      model: body?.model ?? 'local-stub',
      choices: [
        {
          index: 0,
          finish_reason: finishReason,
          message: body?.tools?.length
            ? {
                role: 'assistant',
                content: null,
                tool_calls: [
                  {
                    id: 'call_stub_1',
                    type: 'function',
                    function: {
                      name: fnName,
                      arguments: JSON.stringify(buildArguments(body)),
                    },
                  },
                ],
              }
            : { role: 'assistant', content: '本机模型替身：这是一条纯文本回复。' },
        },
      ],
      // 关键的一条：OpenAI 兼容端点**会把各自的原生计数字段映射成**
      // `prompt_tokens` / `completion_tokens`。网关的成本链路只认这两个名字
      // （见 guard.js），所以本机模型这边不用管它自己内部怎么叫。
      // 这行的存在就是为了让 `/ai/metrics` 的 token 计数与成本能真的算出来。
      usage: {
        prompt_tokens: 512,
        completion_tokens: 64,
        total_tokens: 576,
      },
    };

    response.writeHead(200, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify(payload));
  });
});

/** 数一下请求里有几张图 —— 用来确认视觉档真的走了多模态那条路。 */
function countImages(body) {
  const content = body?.messages?.find((m) => m?.role === 'user')?.content;
  if (!Array.isArray(content)) return 0;
  return content.filter((part) => part?.type === 'image_url').length;
}

server.listen(port, '127.0.0.1', () => {
  console.log(`本机模型替身（OpenAI 兼容）：http://127.0.0.1:${port}/v1`);
  console.log('  它只回「结构合法」的占位内容，不懂题目 —— 别拿它评效果。');
  console.log(`  用法：把网关的 ARK_BASE_URL 指到 http://127.0.0.1:${port}/v1`);
});
