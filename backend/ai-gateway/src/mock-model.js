import { Capabilities } from './config.js';
import { GatewayError, ErrorCodes, schemaViolation } from './errors.js';
import { validate } from './schema.js';

/**
 * 确定性的假模型客户端，**仅用于本地联调与自动化测试**。
 *
 * 它与客户端那边的 `SimulatedAiDataSource` 是两个不同的东西，不要混淆：
 * - `SimulatedAiDataSource` 是**产品的一部分**：离线可用、模型故障降级、测试确定性，
 *   要长期留着。
 * - 本类只是**测试夹具**：没有 Key、没有网络时也能把整条网关链路跑通，
 *   顺带让「模型返回了不合契约的东西」这种用例可以稳定复现。
 *
 * 因此它有两道约束：
 * 1. 必须显式配置 `AI_MODEL_CLIENT=mock` 才会启用，默认永不启用。
 * 2. 返回的 `model` 字段固定为 `mock`，会一路透传到响应的 `meta.model` 上 ——
 *    让任何人一眼看出这不是真模型的结果。
 *    设计文档里那条「宁可承认降级，也不要给假数据」，在这里同样成立。
 */
export class MockModelClient {
  /**
   * @param {object} params
   * @param {object} params.config
   * @param {(call: object) => object|null} [params.intercept]
   *   测试钩子：可以按调用序号返回自定义结果（含故意违约的结果），
   *   用来复现「第一次不合契约、第二次修好」这类链路。
   */
  constructor({ config, intercept } = {}) {
    this.config = config ?? {};
    this.intercept = intercept;
    this.calls = [];
  }

  capabilities() {
    const enabled = {};
    for (const capability of Object.values(Capabilities)) enabled[capability] = true;
    return enabled;
  }

  async complete({ capability, schema, content }) {
    const call = {
      index: this.calls.length,
      capability,
      schemaName: schema.name,
      content,
    };
    this.calls.push(call);

    const injected = this.intercept?.(call);
    if (injected) {
      if (injected.error) throw injected.error;
      return this.#finish(injected.value, schema);
    }

    return this.#finish(buildMockValue(schema.name, content), schema);
  }

  #finish(value, schema) {
    const problems = validate(schema, value);
    if (problems.length > 0) {
      throw schemaViolation(problems);
    }
    return {
      value,
      model: 'mock',
      usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
      finishReason: 'tool_calls',
    };
  }
}

/** FNV-1a：跨进程稳定，保证同一输入永远得到同一份「模型输出」。 */
export function stableHash(input) {
  let hash = 0x811c9dc5;
  const text = String(input ?? '');
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash >>> 0;
}

function pick(bank, seed) {
  return bank[seed % bank.length];
}

/** 从提示词里蹭出参数。真实链路里这些是结构化请求字段。 */
function readField(content, key) {
  const match = promptText(content).match(new RegExp(`${key}[：:]\\s*([^\\n]+)`));
  return match ? match[1].trim() : '';
}

/** 提示词可能是纯字符串，也可能是多模态的片段数组。 */
function promptText(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => (typeof part === 'string' ? part : part?.text ?? ''))
      .join('\n');
  }
  return '';
}

/**
 * 按 **schema.name** 分发，而不是去猜提示词的措辞。
 *
 * 试过按提示词里的字眼判断，结果是灾难：提示词改一个字
 * （「判定学生的答案」→「判定这个答案」），mock 就悄悄走进另一个分支，
 * 返回一个形状完全不对的结果，表现为「网关突然全面 502」。
 * schema.name 是契约的一部分，稳定且机器可读，是唯一正确的分派依据。
 */
function buildMockValue(schemaName, content) {
  const seed = stableHash(`${schemaName}|${promptText(content).slice(0, 400)}`);
  const knowledgePoint = readField(content, '知识点') || '分数计算';
  const subject = readField(content, '科目') || '数学';

  switch (schemaName) {
    case 'report_homework_ocr':
      return {
        text: '数学：完成第1-20题\n语文：背诵第二课',
        subject: '数学',
        confidence: 0.9,
        tasks: [
          { subject: '数学', text: '完成第1-20题' },
          { subject: '语文', text: '背诵第二课' },
        ],
      };

    /**
     * 拍照作答的转录。
     *
     * 刻意**从提示词里把题干读出来**再回填一部分 —— 而不是回一句固定的
     * 「（模拟作答）」。理由是这条链路的下游是 `reviewJudge`：
     * 如果 mock 每次都回同一段无关文字，任何一端「转录结果没被用上、
     * 用的还是空答案」的 bug 都测不出来（判定那侧照样有答案可判）。
     * 回填题干能让学生看到「照片里的东西真的进了作答框」这件事在测试里可见。
     *
     * `confidence` 固定 0.9：mock 的职责是「结构合法的正常输出」，
     * 低置信度那条分支由测试通过 intercept 显式注入。
     */
    case 'report_answer_ocr': {
      const question = readField(content, '这一题的题干');
      return {
        text: question === '' ? '（模拟：照片里的手写作答）' : `（模拟作答）${question}`,
        confidence: 0.9,
      };
    }

    /**
     * 错题录入的题目提取。
     *
     * 条数随提示词里的 `hint` 变化：给了范围就回 1 条，没给就回 2 条。
     * 这样客户端那条「一张照片里有多道题，让学生挑一道」的分支
     * 在 mock 下也走得通，不必另写一个假网关。
     *
     * 第二条刻意给低 confidence（0.55）：`ExtractedMistake.needsReview`
     * 的标黄与「请对照原图核对」只有在低分候选上才看得见 ——
     * 全给 0.9 的话，那条分支到上线都没人碰过。
     */
    case 'report_extract_mistakes': {
      const hint = readField(content, '这次只需要提取');
      const count = hint === '' ? 2 : 1;
      return {
        questions: Array.from({ length: count }, (_, index) => ({
          questionBody:
            index === 0
              ? '计算：$\\frac{1}{2}+\\frac{1}{3}$ 的值。'
              : '解方程：$2x+5=13$。',
          answerKey: index === 0 ? '$\\frac{5}{6}$' : 'x=4',
          knowledgePoint: index === 0 ? '分数加法' : '一元一次方程',
          confidence: index === 0 ? 0.92 : 0.55,
          ...(index === 0
            ? {}
            : { uncertain: '第二行的系数看不清，可能是 2 也可能是 7' }),
        })),
        confidence: hint === '' ? 0.86 : 0.92,
      };
    }

    /**
     * 错题库 → 知识点提示。
     *
     * **知识点必须从提示词里读出来**：客户端会按 `knowledgePoint` 把提示
     * 挂回错题，「换一条」也按它去重。mock 若回一个固定名字，
     * 「提示挂错了知识点」这一类 bug 在测试里永远看不见。
     */
    /**
     * 每日概念打卡的短题。
     *
     * 题量跟着提示词里的「题量：N」走，知识点取第一条编号项 —— 这样
     * 「客户端要 5 道就真的回 5 道」「knowledge 用的是请求里的原文」
     * 这两件事在 mock 下也能被断言到。题型交替出：只回选择题的话，
     * 判断题那条渲染/判分分支在联调里永远走不到。
     */
    case 'report_checkin_questions': {
      const raw = promptText(content);
      const points = [...raw.matchAll(/^\d+\.\s*([^\n（(]+)/gm)].map((match) =>
        match[1].trim(),
      ).filter((point) => point !== '');
      const knowledge = points[0] ?? '分数计算';
      const countMatch = raw.match(/题量[：:]\s*(\d+)/);
      const requested = Number.parseInt(countMatch?.[1] ?? '2', 10);
      const count = Math.min(Math.max(Number.isFinite(requested) ? requested : 2, 1), 10);
      return {
        questions: Array.from({ length: count }, (_, index) =>
          index % 2 === 0
            ? {
                type: 'choice',
                stem: `$\\frac{1}{${index + 2}}+\\frac{1}{${index + 3}}$ 的值是？`,
                options: ['$\\frac{1}{6}$', '$\\frac{2}{5}$', '$\\frac{5}{12}$', '$\\frac{1}{2}$'],
                answer: 'B',
                knowledge,
                analysis: '先通分再相加。',
              }
            : {
                type: 'judge',
                stem: '判断：$0.5$ 与 $\\frac{1}{2}$ 相等。',
                options: ['正确', '错误'],
                answer: 'T',
                knowledge,
                analysis: '同一个数的两种写法。',
              },
        ),
      };
    }

    case 'report_knowledge_tips': {
      // 只认**行首**的「知识点：」。不以行首锚定的话，提示词里那句
      // 「有 2 个知识点：」也会被匹配上，而 `\s*` 会吃掉换行、
      // 把下一行整行变成知识点名（踩过：回给客户端的是「知识点：一元二次方程」）。
      const points = [...promptText(content).matchAll(/^知识点[：:][ \t]*(.+?)(?:｜|$)/gm)]
        .map((match) => match[1].trim())
        .filter((point) => point !== '');
      const unique = [...new Set(points)].slice(0, 3);
      return {
        tips: unique.map((point) => ({
          knowledgePoint: point,
          text: `${point}：先圈出已知条件，再判断用哪条判定，最后回代验算。`,
        })),
      };
    }

    case 'report_homework_check': {
      const wrongCount = seed % 3;
      return {
        score: 100 - wrongCount * 20,
        summary:
          wrongCount === 0
            ? '全部正确，可以进入下一轮复习了。'
            : `共有 ${wrongCount} 处错误，集中在${knowledgePoint}这一步。`,
        items: Array.from({ length: wrongCount }, (_, index) => ({
          question: `计算 $\\frac{${index + 1}}{4}+\\frac{1}{2}$ 的值。`,
          knowledgePoint,
          originalAnswer: `（模拟作答 ${index + 1}）`,
          wrongReason: '通分时分母没有统一，后面越算越偏。',
        })),
      };
    }

    /**
     * 图形题复核的默认返回：**一条都没有**（= 不升级任何题）。
     *
     * 这是个刻意的默认值：mock 的批改结果里本来就没有 figureQuestions，
     * 正常路径不会走到这里。万一走到了（测试自己注入了图题），
     * 返回空 results 等于「没查出问题」，不会悄悄改变既有用例的结论。
     */
    case 'report_figure_verify':
      return { results: [] };

    case 'report_answer_judgement': {
      const verdict = pick(['correct', 'wrong', 'inconclusive'], seed);
      return {
        verdict,
        score: verdict === 'correct' ? 100 : 0,
        comment:
          verdict === 'correct'
            ? '答案正确，方法也用对了。'
            : verdict === 'wrong'
              ? '结果不对，检查一下通分这一步。'
              : '这道题的信息不足以判断，先看一遍讲解。',
      };
    }

    case 'report_mistake_explanation':
      return {
        knowledgePoint,
        position: `人教版${subject}·${knowledgePoint}`,
        whyWrong: '条件没吃透就动笔，后面越算越偏。',
        steps: [
          '圈条件：把已知量和要求圈出来，确认单位一致。',
          '认考点：判断这道题在考哪条判定条件。',
          '写过程：每一步只做一件事，中间结果都写出来。',
          '回代验算：把答案带回原题，检查范围和单位。',
        ],
        pitfalls: ['单位不统一直接相加减', '把「多几倍」当成「是几倍」'],
        mnemonic: `${knowledgePoint}先统单位，再动笔。`,
      };

    case 'report_reference_answers': {
      // 从提示词里把请求的下标读回来，模拟「模型逐条回包」。
      //
      // 这里刻意**不照抄请求顺序**：真实模型不保证顺序，而契约要求按 index 对齐。
      // mock 守着请求顺序的话，客户端那侧「按 index 装配」的代码就永远测不到 ——
      // 一旦真实模型乱序，第 3 题的答案会印到第 5 题上，而且不会报任何错。
      const rows = [
        ...promptText(content).matchAll(/^(\d+)\. 科目：.*?｜知识点：([^｜\n]+)/gm),
      ].map((match) => ({
        index: Number.parseInt(match[1], 10),
        knowledgePoint: match[2].trim(),
      }));

      return {
        answers: rows
          .reverse()
          .map((row) => ({
            index: row.index,
            referenceAnswer: `${row.knowledgePoint}：先统一单位，再按步骤计算。`,
          })),
      };
    }

    case 'report_practice_questions': {
      // 取参考答案时按契约返回空题集：questions 可以为空，referenceAnswer 必须有值。
      const onlyReference = promptText(content).includes('questions 请返回空数组');
      const requested = Number.parseInt(readField(content, '题量'), 10);
      const count = onlyReference
        ? 0
        : Number.isFinite(requested) && requested > 0
          ? requested
          : 3;

      return {
        questions: Array.from({ length: count }, (_, index) => {
          // 四种题型轮着出，让端到端测试能同时覆盖「本地判定」与「模型判定」两条路。
          const type = ['choice', 'fill', 'judge', 'solution'][index % 4];
          const base = {
            type,
            title: `${knowledgePoint}·变式 ${index + 1}`,
            content: `（模拟题干 ${index + 1}）围绕${knowledgePoint}的计算题。`,
            difficulty: pick(['基础', '提高', '挑战'], seed + index),
          };
          if (type === 'choice') {
            return {
              ...base,
              options: ['2x+1=5', '3x-1=4', 'x/2=2', '4x=6'],
              answer: 'A',
            };
          }
          if (type === 'judge') return { ...base, answer: '正确' };
          return { ...base, answer: `（模拟答案 ${index + 1}）` };
        }),
        referenceAnswer: `${knowledgePoint}：先统一单位，再按步骤计算。`,
      };
    }

    default:
      // 大声失败。静默返回一个形状不对的结果，会让排查方向完全跑偏。
      throw new GatewayError(
        ErrorCodes.internal,
        `Mock 客户端不认识 schema「${schemaName}」，请同步更新 mock-model.js`,
        { status: 500 },
      );
  }
}
