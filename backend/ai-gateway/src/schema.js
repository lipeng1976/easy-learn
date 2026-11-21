/**
 * 网关与模型之间的**结构化输出契约**。
 *
 * 同一个 schema 服务两个用途：
 * 1. 转成 function calling 的 tool 定义，让模型被约束着输出（厂商层防御）
 * 2. 拿到结果后做运行时校验（服务端层防御）
 *
 * 两处共用一份定义，是为了避免「约束用一套、校验用另一套」——
 * 那种情况下模型照着约束输出，却在校验时被判违约，故障会非常难查。
 *
 * 关键词只用标准 JSON Schema 的那些（`minimum` / `minItems` / `minLength`…），
 * 这样可以直接塞进 tool 定义，不需要做关键词翻译。
 */

import { protectLatexEscapes } from './latex-guard.js';

const string = (extra = {}) => ({ type: 'string', ...extra });
const integer = (extra = {}) => ({ type: 'integer', ...extra });
const boolean = (extra = {}) => ({ type: 'boolean', ...extra });
const number = (extra = {}) => ({ type: 'number', ...extra });
const arrayOf = (items, extra = {}) => ({ type: 'array', items, ...extra });

/**
 * 一个二维坐标点。
 *
 * 图形 DSL 里凡是「位置」都是这个形状。抽出来是因为它出现在三个地方
 * （点、尺寸线端点、标记位置），三处各写一遍，改一处时会漏。
 */
const xy = Object.freeze({
  type: 'object',
  additionalProperties: false,
  required: ['x', 'y'],
  properties: { x: number(), y: number() },
});

export const Schemas = {
  /** 拍照识别：文字转录 + 版式切分。 */
  homeworkOcr: {
    name: 'report_homework_ocr',
    description: '把作业照片识别成文字，并按科目标出各自的作业要求',
    type: 'object',
    additionalProperties: false,
    required: ['text', 'subject', 'confidence', 'tasks'],
    properties: {
      text: string({ minLength: 1, description: '照片里的完整文字转录' }),
      subject: string({ description: '识别出的科目；无法判断时填「待确认」' }),
      confidence: { type: 'number', minimum: 0, maximum: 1 },
      tasks: arrayOf(
        {
          type: 'object',
          additionalProperties: false,
          required: ['subject', 'text'],
          properties: {
            subject: string({ minLength: 1 }),
            text: string({ minLength: 1, description: '该科目下的一条作业要求' }),
            // 可选，默认视为 false。**刻意不设成 required**：
            // 加了必填会让模型在没有把握时也必须给一个布尔值，
            // 而它更容易随手填 false —— 那比不给更危险，
            // 因为客户端会把「没标记」和「明确说没问题」当成同一件事。
            // 规则写在提示词里：认不准就标 true。
            uncertain: boolean({
              description:
                '这一条里有没有认不准的字。有则为 true，并在 text 里用（？）标出位置。',
            }),
            // 可选。这一项只有模型能给：它看得见「一张卷子两面」这种**量**，
            // 而规则从标题里只数得出页数和题数。
            // 但拿不准时**宁可空着** —— 给一个像模像样的错数，学生会以为
            // 系统真算过，反而不去改；空着客户端会按标题退回类型默认值。
            estimatedMinutes: integer({
              minimum: 5,
              maximum: 120,
              description:
                '按这一项的内容估个耗时（分钟）。拿不准就省略这个字段，不要猜。',
            }),
          },
        },
        { minItems: 1 },
      ),
    },
  },

  /**
   * 拍照作答：把照片里学生手写的**这一题**的解答转录成文字。
   *
   * ## 为什么与 `homeworkOcr` 分开，而不是复用它
   *
   * 两者看的是同一类东西（手写照片），但**问的问题不一样**：
   * `homeworkOcr` 问的是「这份作业要做什么」→ 输出整卷文字 + 按科目归纳的
   * 作业要求（`tasks`）；这里问的是「学生这一题写了什么」→ 只要一段文字。
   *
   * 复用的后果不是报错，而是**答非所问**：模型拿到「归纳作业要求」的提示词
   * 和带 `tasks` 的输出契约，会努力在单题作答里找出「作业要求」来填，
   * 于是学生写的 `x=5` 可能被归纳成「完成第 3 题」。两处都"成功"，
   * 只有学生看到的内容是错的。
   *
   * ## 为什么没有 `subject` / `tasks`
   *
   * 这两个字段在这里**没有接收方**：拍的是复习页上一道已知题目，
   * 科目和题目原文客户端本来就有，不需要模型再猜一遍。
   * 契约里放一个没人用的必填字段，只会给模型多一个编造的机会
   * （编出来的科目还会被当成真的显示出来）。
   */
  answerOcr: {
    name: 'report_answer_ocr',
    description: '把照片里学生手写的这一道题的解答转录成文字',
    type: 'object',
    additionalProperties: false,
    required: ['text', 'confidence'],
    properties: {
      /**
       * ⚠️ **刻意不设 `minLength`** —— 整个文件里只有这一个 string 字段没有它。
       *
       * 「照片里确实什么都没有」是一个**合法的业务状态**，不是模型偷懒：
       * 客户端就是按「空串 = 没看到作答」写的 —— `_parseAnswerRecognition`
       * 用 `_requireString` 而不是 `_requireNonEmptyString`，并且它的提示文案里
       * 专门有一支「这张照片里没看到手写作答，请重拍或直接输入」。
       *
       * 2026-09-25 实测发现的缺口：提示词原本让模型在没看到作答时返回**占位文案**
       * 「（未看到作答内容）」，而客户端的 `isUsable` 只看「非空 + 来自云端」
       * ⇒ 那段占位文案**被判为可用、填进学生的作答框**，学生一提交就多出
       * 一道判错的题。根因是两侧口径不一致（客户端等空串、服务端给文案），
       * 不是哪一边判据太松。放开 `minLength` 让两侧对齐。
       */
      text: string({
        description:
          '照片里学生手写的解答内容，按原样转录（含数字、符号、单位）。'
          + '只转录学生**写出来的东西**，不要补全、不要订正、不要写解法。'
          + '照片里完全没有手写作答时，这里返回**空字符串**。',
      }),
      /**
       * 认字这件事的把握程度。
       *
       * 它是**唯一**能让「认错了」和「学生真写错了」分开的信号：
       * 转录文字会直接填进学生的作答框并送去判定，认错一个字就可能
       * 把对的答案判成错的，而学生看到的是一份「字迹清楚」的错答案 ——
       * 看不出问题出在识别这一步。
       *
       * 所以规则写在提示词里：宁可调低 confidence，也不要换成一个
       * 读起来通顺的词。客户端据此决定「要不要先让学生核一眼」。
       */
      confidence: { type: 'number', minimum: 0, maximum: 1 },
      /**
       * 认不准的具体位置。
       *
       * 可选：**刻意不设成 required**。一旦必填，模型在完全认得出时
       * 也被迫写点什么，那条「其实没问题的提醒」反而会让人不再看提醒。
       * 也没有做成 `array` —— 一段自由文字更容易说清「第三行的那个数字像 5 又像 6」。
       */
      uncertain: string({
        description:
          '有没有哪个字/数字认不准，写清大概位置（如「第二行的数字像 5 又像 6」）。'
          + '全都认得清就省略这个字段。',
      }),
    },
  },

  /**
   * 作业批改：分数 + **答案错**的明细 + 只影响规范的提醒。
   *
   * ⚠️ `items` 与 `formatIssues` 的边界是这份契约里最要紧的一条：
   * `items` 的每一条都会变成错题库里的一道题，之后被组卷重做、还会生成
   * 变式题。所以「单位没写」「没写答句」这类**答案正确、只是写法不标准**的
   * 问题绝不能混进去 —— 否则学生会反复重做一道他本来就会的题，
   * 而「错题」这两个字也就失去意义了。这类问题走 `formatIssues`，
   * 只在批改页提示一次。
   *
   * 反过来，**答案不完整**（题目两问只答一问）是**做错**、要进 `items` ——
   * 唯一的判据是「该写的内容有没有写对」，不是「写得规不规范」。
   * 「漏答一问」与「没写答句」是这条线上的两端，最容易被混成一个。
   */
  homeworkCheck: {
    name: 'report_homework_check',
    description:
      '批改作业照片，给出评分、每道**答案确实做错**的题，以及只影响书写规范的提醒',
    type: 'object',
    additionalProperties: false,
    required: ['score', 'summary', 'items'],
    properties: {
      score: integer({
        minimum: 0,
        maximum: 100,
        description:
          '0-100 的整数评分。**只由「做错了没有」决定** —— 结果错、过程里'
          + '某一步确实写错/算错、或漏答了题目要求的一问，就扣分；'
          + '只是跳步、写乱、漏单位、没写答句的，不扣分。',
      }),
      summary: string({
        minLength: 1,
        description: '一句话总结，家长看得懂，不要出现专业术语',
      }),
      // 全对时 items 为空数组是合法的 —— 这正是「一次批改把错题清空」的正常路径。
      items: arrayOf(
        {
          type: 'object',
          additionalProperties: false,
          required: ['question', 'knowledgePoint', 'originalAnswer', 'wrongReason'],
          properties: {
            question: string({
              minLength: 1,
              description:
                '这道题的**题干原文**（抄题目本身，不含学生的作答与批改痕迹）。'
                + '分数、根号、幂、上下标一律用 LaTeX 行内公式（如 '
                + '`$\\frac{3}{4}+\\frac{1}{2}$`、`$x^2-5x+6=0$`）。'
                + '这一条会作为错题的题干保存下来，讲解、重做、变式题都靠它 —— '
                + '写成「第 3 题」或者一段概括，等于这道题以后再也没法被重做。',
            }),
            // 可选：不少作业本来就没有题号。
            // **不设 required** —— 逼模型在没编号的卷子上编一个，比空着坏得多。
            questionNo: string({
              description:
                '这道题在作业卷面上的**题号原文**，照抄（`20`、`20(4)`、`三、2`）。'
                + '卷面没有编号、或看不清，就填空字符串，**不要自己编号**。',
            }),
            // 学生这次**写出来的过程**。讲解要知道「他卡在哪一步」，
            // 只知道最终答案是错的，讲出来只能是泛泛而谈。
            //
            // ⚠️ 空串是合法且常见的：选择题、填空题本来就没有过程。
            //    宁可空着，也不要为了填满而编一步出来 ——
            //    编出来的过程会让讲解去纠正一个学生根本没写过的错。
            studentProcess: string({
              description:
                '学生**手写**的解题过程原文（照抄，含算式），只抄他真写了的。'
                + '选择题/填空题没有过程、或过程看不清，填空字符串或「【识别不清】」。'
                + '**不要补**、不要替他把步骤写完整。',
            }),
            // 标准答案。批改这一刻模型同时看到题目与作答，算答案的上下文最全；
            // 组卷时另问一次反而只剩题干。
            standardAnswer: string({
              description:
                '这道题的正确结果（要算出具体值，不要写「见解析」）。'
                + '⚠️ 必须与你的判定自洽：既然判它错，这个答案就不能和学生写的一样。',
            }),
            knowledgePoint: string({
              minLength: 1,
              description: '知识点名（如「分数计算」），不是题目原文',
            }),
            originalAnswer: string({ description: '学生这次的答案' }),
            wrongReason: string({
              description:
                '错在哪，要具体到**事实上写错的那一步**（如「通分时分母没有统一」）。'
                + '「有风险」「不严谨」「容易出错」这类推测不是错误，别写在这里。',
            }),
          },
        },
        {
          description:
            '只放**确实做错了**的题，三种：① 结果错了；'
            + '② 结果对了、但中间某一步本身写错/算错（即使后面绕回了正确答案）；'
            + '③ 漏答了题目要求的一部分（两问只答一问），答案不完整。'
            + '**跳步、写乱、漏单位、没写答句都不算** —— 那些放 formatIssues'
            + '（区别在于：漏答一问是「该写的内容缺了」，没写答句是「内容都在、只是没起头」）。'
            + '「有风险 / 不严谨 / 容易出错」不是错误，不要报。',
        },
      ),
      /**
       * 题面含图的题目清单，**无论判对判错都要列**。
       *
       * 为什么不能只靠 `items`：`items` 只放「判错的题」，而漏判恰恰发生在
       * 「模型认为这题对了」的时候 —— 那一刻它根本不在 items 里，
       * 复核就没有对象。2026-10-23 实测：L 形面积题学生两式都错，
       * 批改给 100 分、items 空，正是这个缺口。
       *
       * 只收「题面含图」的题，是因为复核要走视觉档（配额是纯文本的 8 倍），
       * 全量复核等于每次批改多花一倍视觉费用。纯文字题靠第一次批改就够了。
       */
      figureQuestions: arrayOf(
        {
          type: 'object',
          additionalProperties: false,
          required: ['question', 'studentWork'],
          properties: {
            questionNo: string({
              description: '题号原文，与 items 里的 questionNo 同一写法；没有就填空字符串。',
            }),
            question: string({
              minLength: 1,
              description:
                '这道题的**题干原文**（抄题目本身，不含作答与批改痕迹），用 LaTeX 写公式。'
                + '这一列会单独发给复核，题干残缺会让复核算错。',
            }),
            studentWork: string({
              description:
                '学生在这道题上**写出来的全部内容**，照抄：每一个式子、每一个答案。'
                + '「用不同方法表示面积」这类多问的题，几问就要抄几个式子 —— '
                + '复核是逐个式子验的，漏抄一个就等于放过一个错误。'
                + '看不清就写「【识别不清】」，不要猜、不要替他补步骤。',
            }),
          },
        },
        {
          description:
            '题面含图（几何图、坐标系、统计图、表格图）的题，**判对判错都要列**，'
            + '用于后续的独立验算复核。没有这类题就省略这个字段。',
        },
      ),
      // 刻意**不设成 required**：没有这类问题时它就该缺席，
      // 而不是逼模型为了填满字段硬凑两条出来。
      formatIssues: arrayOf(        {
          type: 'object',
          additionalProperties: false,
          required: ['knowledgePoint', 'detail'],
          properties: {
            knowledgePoint: string({ minLength: 1, description: '知识点名' }),
            detail: string({
              description:
                '规范上哪里不到位、应该怎么改，例如「第 4 题算对了但没写单位 元」',
            }),
          },
        },
        {
          description:
            '答案正确、但写法不规范的地方（漏单位、没写答句、跳步、誊写不整洁…）。'
            + '这些只在批改页提示，不扣分、不进错题库。没有就省略这个字段。',
        },
      ),
    },
  },

  /**
   * 图形题的**独立复核**：只看含图的题，逐个式子验算。
   *
   * 它不是在「再问一次模型对不对」—— 那只是把同一个不确定性抛一次硬币。
   * 复核要拿到的是**式子本身**（参考式 + 学生式 + 变量 + 一组满足图形条件的
   * 取值），然后由 `figure-verify.js` 代入数值判决。
   *
   * 因此这里的 `verdict` 只是**旁证**，最终结论以程序为准（见 handlers.js）：
   * 模型说对、程序算出不等 ⇒ 以程序为准；程序算不了 ⇒ 维持原判。
   */
  homeworkFigureVerify: {
    name: 'report_figure_verify',
    description: '对题面含图的题目逐个式子验算，给出参考式、学生式与判定',
    type: 'object',
    additionalProperties: false,
    required: ['results'],
    properties: {
      results: arrayOf(
        {
          type: 'object',
          additionalProperties: false,
          required: ['question', 'verdict', 'reason', 'knowledgePoint'],
          properties: {
            knowledgePoint: string({
              minLength: 1,
              description:
                '知识点名（如「组合图形面积计算」），不是题目原文。'
                + '复核升格的错题要直接进错题库，这一列会被拿去组卷与出变式题。',
            }),
            question: string({
              minLength: 1,
              description: '题干原文，照抄请求里给的那一条（用于对回原题，不要改写）。',
            }),
            variables: arrayOf(
              { type: 'string', minLength: 1 },
              {
                description:
                  '这道题用到的字母变量，如 ["a","b","c","d"]。'
                  + '**只列题面里出现的**，不要把数字当变量。',
              },
            ),
            preferredValues: {
              type: 'object',
              additionalProperties: { type: 'number' },
              description:
                '一组**满足图形几何条件**的取值，如 {"a":4,"b":7,"c":2,"d":3}。'
                + '必须画得出这个图形：右高不能大于左高、上宽不能大于总宽。'
                + '这组数会用来验算并把算式写给家长看。',
            },
            /**
             * 图形外轮廓的顶点坐标，**按 `preferredValues` 的真实尺寸画**。
             *
             * 这是复核里唯一**不依赖模型代数能力**的证据：程序用鞋带公式
             * 算出面积，再拿它跟学生每个式子比。2026-10-23 实测：
             * 模型给的参考式 `bc-(b-d)(a-c)` 算出 16，而图形真实面积是 32 ——
             * 它把 `ab` 写成了 `bc`。拿那个式子当判据，会把做对的学生判错。
             *
             * 画点比写代数式可靠得多：读图是它的强项，符号推导不是。
             */
            outline: arrayOf(xy, {
              description:
                '图形外轮廓的顶点坐标，按 preferredValues 的真实尺寸（a=4 就画 4 个单位长），'
                + '顺时针或逆时针都行。拐角处必须有一个点，否则面积会算错。'
                + '算不了就省略 —— 程序会退回用参考式比对。',
            }),
            actualArea: number({
              description:
                '你算出的图形面积（数值）。应当与 outline 用鞋带公式算出来的一致；'
                + '两者不一致时程序以 outline 为准（几何比代数可靠）。',
            }),
            referenceExpressions: arrayOf(
              { type: 'string', minLength: 1 },
              {
                description:
                  '正确答案的表达式，可以有多个等价写法（如分割法与补形法各一个）。'
                  + '只写等号右边，例如 "ad + c(b-d)"。**不许写「见解析」**。',
              },
            ),
            studentExpressions: arrayOf(
              { type: 'string', minLength: 1 },
              {
                description:
                  '学生写出来的每一个式子，照抄（同样只抄等号右边的部分）。'
                  + '他写了几问就抄几个，**不许补、不许订正**。',
              },
            ),
            verdict: {
              type: 'string',
              enum: ['correct', 'wrong', 'inconclusive'],
              description:
                'correct=所有式子都成立；wrong=至少一个式子不成立；'
                + 'inconclusive=题面看不清或式子认不出来。**拿不准就选它，不要勉强判错**。',
            },
            reason: string({
              minLength: 1,
              description:
                '判错的理由，具体到**哪一个式子错在哪**（如「第二个式子的外接矩形写成 bc，'
                + '应是 ab」）。判对时写一句为什么成立。'
                + '不要写「经复核」「等等」这类边想边改的句子。',
            }),
          },
        },
        {
          description:
            '逐题输出，顺序与请求一致。请求里有几条就回几条，一条都不许漏；'
            + '实在认不出某一题，也要回一条 verdict=inconclusive 的占位。',
        },
      ),
    },
  },

  /** 单题判定：三态。 */
  reviewJudge: {
    name: 'report_answer_judgement',
    description: '判定学生的答案是否正确',
    type: 'object',
    additionalProperties: false,
    required: ['verdict', 'score', 'comment'],
    properties: {
      verdict: {
        type: 'string',
        enum: ['correct', 'wrong', 'inconclusive'],
        description:
          'correct=确定答对；wrong=确定答错；inconclusive=信息不足无法判断，不要勉强选对错',
      },
      score: integer({ minimum: 0, maximum: 100 }),
      comment: string({ minLength: 1, description: '给学生看的反馈' }),
    },
  },

  /**
   * 错题录入：把照片里的题目**提取**成结构化文本。
   *
   * ## 为什么只提取，不判定对错
   *
   * 学生主动提交的是「他认为自己错了的题」，这件事本身就是结论。
   * 让模型再判一遍会引入一个无法解释的失败模式：模型说这题没错，
   * 学生就录不进去 —— 而他手上明明有一张打了叉的卷子。
   * 所以这里没有任何 verdict / isWrong 字段，也不给 `wrongReason`：
   * 错因是学生自己写的，模型只能「看到什么转录什么」。
   *
   * ## 为什么返回数组
   *
   * 一张照片里常常不止一道题：拍一整张试卷时，一次识别就该把整页的题
   * 都取出来。客户端在单题模式下取第一条、批量模式下逐条确认，
   * 用的是同一份契约 —— 分成两个端点会让「拍一道题」和「拍一页题」
   * 走两条会各自漂的提示词。
   *
   * `questions` 刻意**不设 `minItems`**：照片糊了、拍的是空白页、
   * 只有批改痕迹没有题目 —— 这些都是合法状态，返回空数组即可。
   * 设成必填会逼模型从空白里编一道题出来，而那道题会被录进错题库。
   */
  extractMistakes: {
    name: 'report_extract_mistakes',
    description: '把照片里的题目提取成题干、答案、知识点，供学生确认后录入错题库',
    type: 'object',
    additionalProperties: false,
    required: ['questions', 'confidence'],
    properties: {
      questions: arrayOf({
        type: 'object',
        additionalProperties: false,
        required: ['questionBody', 'confidence'],
        properties: {
          /**
           * 题干原文。
           *
           * 要求「原样转录」而不是「改写成通顺的话」：题干会被存进错题库、
           * 之后拿去讲解和出变式题。被润色过的题干会让模型对着另一道题讲解，
           * 而学生看到的是一份读起来很顺、但答非所问的讲解。
           *
           * 数学表达式用 LaTeX：客户端用 `flutter_math_fork` 渲染，
           * 纯文本写法的 `x^2/3` 在界面上会变成一串看不懂的符号。
           */
          questionBody: string({
            minLength: 1,
            description:
              '题目的完整原文，按照片原样转录（含题号、已知条件、问题）。'
              + '数学表达式用 LaTeX 书写，行内公式用 $...$ 包裹（如 $\\frac{x-1}{2}=3$）。'
              + '不要改写题目、不要补全看不清的条件。',
          }),
          /**
           * 答案。**刻意可选**：很多照片只有题目没有答案。
           *
           * 拿不准就省略 —— 一个编造的答案会被存成参考答案，
           * 然后拿它去判学生做对还是做错。
           */
          answerKey: string({
            description:
              '这道题的正确答案，能确定时才给（如照片里有批改后的正确答案，或题目可解）。'
              + '拿不准就省略这个字段，**不要猜**。',
          }),
          /** 知识点，用于后续组卷、讲解、举一反三的驱动键。 */
          knowledgePoint: string({
            description: '这道题考的知识点（如「一元一次方程」「分数加减」）。拿不准就省略。',
          }),
          confidence: {
            type: 'number',
            minimum: 0,
            maximum: 1,
            description: '对这一条提取结果的把握程度。字迹/印刷不清就调低。',
          },
          /** 与 `answerOcr` 同一条理由：认不准的位置要能说出来。 */
          uncertain: string({
            description:
              '有没有哪个字符认不准，写清位置（如「第二行的系数像 3 又像 8」）。'
              + '全都认得清就省略。',
          }),
        },
      }),
      /**
       * 整张照片的把握。
       *
       * 与逐条的 `confidence` 分开：一整页里有一道题糊了，不等于整页白拍。
       * 合成一个数会让「能用的 7 道」被一份低分整体拖成不可用。
       */
      confidence: {
        type: 'number',
        minimum: 0,
        maximum: 1,
        description: '这张照片整体能不能用。完全没拍到题目就给 0。',
      },
      uncertain: string({
        description: '整张照片层面的问题（如「右下角被裁掉了」）。没问题就省略。',
      }),
    },
  },

  /** 错题讲解。 */
  reviewExplain: {
    name: 'report_mistake_explanation',
    description: '讲解一道错题：考点定位、错因、分步解法、易错提醒、记忆点',
    type: 'object',
    additionalProperties: false,
    required: [
      'knowledgePoint',
      'position',
      'whyWrong',
      'steps',
      'pitfalls',
      'mnemonic',
    ],
    properties: {
      knowledgePoint: string({ minLength: 1 }),
      position: string({ description: '该知识点在教材里的位置' }),
      whyWrong: string({
        minLength: 1,
        description: '针对这道题的错因归因，不要说「粗心」这种没有指导性的话',
      }),
      steps: arrayOf(
        string({
          minLength: 1,
          description: '一步只做一件事，不跳步',
        }),
        { minItems: 1 },
      ),
      pitfalls: arrayOf(string({ minLength: 1 })),
      mnemonic: string({ description: '一句话记忆点' }),
    },
  },

  /**
   * 举一反三出题。
   *
   * 同一个响应里也能带 `referenceAnswer` —— 组卷时每道题都要冻结参考答案，
   * 单独为它发一次请求，一份 20 题的卷子就是 20 次调用。
   * 契约里让它可选：出题时不需要它，取答案时只要它。
   */
  reviewPractice: {
    name: 'report_practice_questions',
    description: '围绕某个知识点出同类型的变式练习题，并给出参考答案',
    type: 'object',
    additionalProperties: false,
    required: ['questions', 'referenceAnswer'],
    properties: {
      questions: arrayOf({
        type: 'object',
        additionalProperties: false,
        required: ['type', 'title', 'content', 'answer', 'difficulty'],
        properties: {
          type: {
            type: 'string',
            enum: ['choice', 'fill', 'judge', 'solution'],
            description:
              '题型，**跟着错题本身的形式走**：原题是选择题就出 choice，'
              + '是判断题就出 judge，是填空就出 fill，其余（计算、证明、'
              + '解答）出 solution。不要为了好批改把一道解答题改成选择题 —— '
              + '学生练的必须是同一类思维。',
          },
          title: string({ minLength: 1 }),
          content: string({
            minLength: 1,
            description:
              '题干。数学式子用 LaTeX 行内公式，如 $\\frac{x-1}{2}=3$、$x^2-5x+6$；'
              + '写成 1/2、x^2/3、sqrt(2) 这类纯文本，学生端渲染不出上下结构。',
          }),
          options: arrayOf(
            string({ minLength: 1 }),
            {
              description:
                'choice 专用：**恰好 4 个**选项，只写选项内容，**不要写 A. / B. 前缀**'
                + '（界面会按序号渲染）。其他题型省略这个字段。'
                + '选项里的数学式子同样用 $...$ 包裹的 LaTeX。',
            },
          ),
          answer: string({
            minLength: 1,
            description:
              '参考答案。没有答案的练习题在闭环里无法判定对错。'
              + 'choice 只填选项字母（A/B/C/D）；judge 只填「正确」或「错误」；'
              + 'fill / solution 填可直接比对的内容。',
          }),
          difficulty: string({ description: '基础 / 提高 / 挑战' }),
          /**
           * 配图。**只有「不看图就没法做」的题才给**，纯文字题整个字段省略。
           *
           * 它不是一张图片，是「点和线」的描述 —— 画由客户端做。
           * 让模型出位图的后果是线长与标注对不上（见 `figure.js` 顶部的说明），
           * 那种图看起来完全正常，但学生照着它推理会得出基于错误前提的结论。
           *
           * 契约里所有字段都必填，是为了让模型**必须想清楚整张图**；
           * 服务端仍会自己再校验一遍，对不上就整张丢掉 —— 契约管的是
           * 「模型愿不愿意给」，校验管的是「给了能不能信」。
           */
          figure: {
            type: 'object',
            additionalProperties: false,
            required: ['type', 'points'],
            properties: {
              type: {
                type: 'string',
                enum: ['plane', 'coord'],
                description:
                  'plane = 平面几何图形（三角形、四边形、圆、组合图形）；'
                  + 'coord = 直角坐标系里的点与函数图像。',
              },
              points: arrayOf(
                {
                  type: 'object',
                  additionalProperties: false,
                  required: ['name', 'x', 'y'],
                  properties: {
                    name: string({
                      minLength: 1,
                      description: '顶点/关键点的字母，如 A。没有字母标号的点不必给。',
                    }),
                    x: number(),
                    y: number(),
                  },
                },
                { minItems: 2 },
              ),
              polygons: arrayOf(
                arrayOf(string({ minLength: 1 }), { minItems: 3 }),
                { description: '用点名的顺序围成的封闭图形，如 [["A","B","C"]]。' },
              ),
              segments: arrayOf(arrayOf(string({ minLength: 1 }), { minItems: 2 }), {
                description: '额外的线段：高、对角线、中位线等。',
              }),
              dashed: arrayOf(arrayOf(string({ minLength: 1 }), { minItems: 2 }), {
                description: '虚线：辅助线、延长线。',
              }),
              dims: arrayOf(
                {
                  type: 'object',
                  additionalProperties: false,
                  required: ['from', 'to', 'text'],
                  properties: {
                    from: xy,
                    to: xy,
                    text: string({
                      minLength: 1,
                      description:
                        '这条尺寸线标的量，如 a、b、5cm、60m。'
                        + '坐标要画在这条边外侧，长度必须与那条边相等。',
                    }),
                  },
                },
                { description: '尺寸标注：一条带箭头的线 + 一个数值/字母。' },
              ),
              labels: arrayOf({
                type: 'object',
                additionalProperties: false,
                required: ['text', 'x', 'y'],
                properties: {
                  text: string({ minLength: 1 }),
                  x: number(),
                  y: number(),
                },
              }),
              marks: arrayOf({
                type: 'object',
                additionalProperties: false,
                required: ['kind', 'at'],
                properties: {
                  kind: { type: 'string', enum: ['rightAngle', 'arc'] },
                  at: xy,
                  text: string({ description: 'arc 标记上的角度，如 50°。' }),
                },
              }),
              vars: arrayOf(
                {
                  type: 'object',
                  additionalProperties: false,
                  required: ['name', 'value'],
                  properties: {
                    name: string({ minLength: 1 }),
                    value: number(),
                  },
                },
                {
                  description:
                    '图上每个字母标注对应的数值，如 [{"name":"a","value":3}]。'
                    + '服务端用它验算答案，给不出就省略。',
                },
              ),
            },
          },
        },
      }),
      referenceAnswer: string({
        description:
          '该知识点的参考答案或通用解题要点。宁可给通用要点，也不要编造一个具体答案',
      }),
    },
  },

  /**
   * 每日概念打卡的题目。
   *
   * ## 为什么只有 choice / judge
   *
   * 判分在 App 本地做**确定性比对**（不走模型，理由见 B29：模型判分会在
   * 等价写法上判错）。本地比对只对「有限答案集」可靠 —— 选择是字母、
   * 判断是 T/F；填空与解答的合法写法无穷多（`0.5` / `1/2` / `二分之一`），
   * 判错时学生只会看到「你做错了」，而其实他做对了。
   *
   * 所以这个约束写进 enum，而不是靠提示词自觉。
   *
   * ## 为什么 options 对判断题也必填
   *
   * 让「判断题」和「选择题」在结构上同形，客户端只写一条渲染路径。
   * judge 的 options 固定为 ["正确","错误"]，服务端会强制覆盖 ——
   * 模型写成别的（比如 ["对","错"]）也不会漏到界面上。
   */
  checkinGenerate: {
    name: 'report_checkin_questions',
    description: '每日概念打卡的短题：选择题与判断题，供 App 本地判分',
    type: 'object',
    additionalProperties: false,
    required: ['questions'],
    properties: {
      questions: arrayOf(
        {
          type: 'object',
          additionalProperties: false,
          required: ['type', 'stem', 'options', 'answer', 'knowledge'],
          properties: {
            type: {
              type: 'string',
              enum: ['choice', 'judge'],
              description:
                'choice = 四选一；judge = 判断题。**不允许**填空 / 解答 / 证明，'
                + '那类题在本地无法可靠判分。',
            },
            stem: string({
              minLength: 1,
              description:
                '题干，一句话。数学式子用 $...$ 包裹的 LaTeX（如 $\\frac{1}{2}+\\frac{1}{3}$）。',
            }),
            options: arrayOf(string({ minLength: 1 }), {
              minItems: 2,
              maxItems: 6,
              description:
                'choice：恰好 4 个选项，只写内容，不带 `A.` 前缀。'
                + 'judge：固定写 ["正确","错误"]。',
            }),
            answer: string({
              minLength: 1,
              description:
                'choice 填选项字母（A/B/C/D，有且只有一个正确）；judge 填 T 或 F。',
            }),
            knowledge: string({
              minLength: 1,
              description:
                '知识点原文，**必须与请求里给的一字不差** —— 客户端按它把结果归档回同一个知识点。',
            }),
            analysis: string({
              description: '一句话说清为什么，不超过 60 字，答错后展示。',
            }),
          },
        },
        { minItems: 1, maxItems: 10 },
      ),
    },
  },

  /**
   * 错题库 → 知识点提示。
   *
   * ## 为什么不是「把每道题都讲一遍」
   *
   * 这里要的是**能贴在计时页上的一句话**，不是讲解。计时页是学生正在做题
   * 的那一屏，一段五步讲解会把注意力从题目上拽走；而一句「通分前先看分母
   * 的最小公倍数」恰好可以边看边用。
   *
   * ## 为什么 knowledgePoint 必须回填、且必须来自请求
   *
   * 客户端会按知识点做去重与「换一条」的轮换。模型若自己造一个新名字，
   * 提示就挂不到任何一条错题上 —— 界面看起来完全正常，只是那条提示
   * 和孩子的错题本没有关系。这种错没有任何报错，只能靠契约禁止。
   */
  reviewTips: {
    name: 'report_knowledge_tips',
    description: '把错题库里的知识点归纳成几条一句话的提示，能直接照着做',
    type: 'object',
    additionalProperties: false,
    required: ['tips'],
    properties: {
      tips: arrayOf(
        {
          type: 'object',
          additionalProperties: false,
          required: ['knowledgePoint', 'text'],
          properties: {
            knowledgePoint: string({
              minLength: 1,
              description:
                '必须**原样**使用请求里给出的某个知识点名称，不要改写、不要合并、不要新造。',
            }),
            text: string({
              minLength: 1,
              description:
                '一句话，40 字以内。直接说这个知识点本身的关键（定义、判定条件、'
                + '易错的那一步），不是「要认真审题」这类空话，也不要写「加油」。',
            }),
          },
        },
        { minItems: 1, maxItems: 6 },
      ),
    },
  },

  /**
   * 批量参考答案。
   *
   * ## 为什么值得多一个端点
   *
   * 组卷时每道题都要冻结一份参考答案。按题调用的话，一页 20 道题就是
   * 20 次往返 —— 延迟是线性的，而输入 token 也会被付 20 遍（每次都要
   * 带上同样的「你是辅导老师」提示词）。一次请求带 20 条，
   * 输入 token 只在提示词上付一遍，往返降到 1 次。
   *
   * ## 契约里写死 index 的理由
   *
   * 模型返回的数组顺序**不保证**与请求一致，长度也不保证相等。
   * 如果按位置对应，一次错位就会让「第 3 题的答案」出现在「第 5 题」上 ——
   * 而这两个错误都不会报错，只会让学生照着别人的答案对答案。
   * 所以要求显式回一个 `index`，由调用方按 index 装配，缺的那几条单独处理。
   */
  reviewReferenceBatch: {
    name: 'report_reference_answers',
    description: '为一批知识点批量给出参考答案，每条带上下标以便对齐',
    type: 'object',
    additionalProperties: false,
    required: ['answers'],
    properties: {
      answers: arrayOf(
        {
          type: 'object',
          additionalProperties: false,
          required: ['index', 'referenceAnswer'],
          properties: {
            index: integer({
              minimum: 0,
              description: '对应请求 items 数组里的下标，从 0 开始',
            }),
            referenceAnswer: string({
              minLength: 1,
              description:
                '可直接与学生对答案比对的短答案；无法给出具体答案时回作答要求原文',
            }),
          },
        },
        { minItems: 1 },
      ),
    },
  },
};

/**
 * 带原题照片的举一反三 —— 与 `reviewPractice` **共用同一份输出契约**。
 *
 * 刻意不复制一份：这两条路径产出的是同一种东西（同类型的变式题），
 * 唯一的差别是模型看不看得见原题。复制会让两份契约慢慢漂开，
 * 而「约束用 A、校验用 B」的故障表现是模型照着约束输出却被判违约，
 * 非常难查（这条教训在本文件顶部写着）。
 */
Schemas.reviewPracticeFigure = Schemas.reviewPractice;

/**
 * 带原题照片的错题讲解 —— 与 `reviewExplain` 共用同一份输出契约。
 *
 * 差别只在**输入**：有照片、有参考答案、有学生当时写的过程。
 * 输出仍然要 `whyWrong / steps / pitfalls / mnemonic` 那四样，
 * 所以没必要再维护第二份契约（说两份迟早会漂开，见上面那段）。
 */
Schemas.reviewExplainFigure = Schemas.reviewExplain;

/**
 * 错题的**讲解配图**：先判「该不该画」，再给坐标。
 *
 * ## 为什么 draw 是必填的布尔值，而不是「figure 可为 null」
 *
 * 「不画」是一个**正当结论**，不是失败。初一错题里六成是有理数运算，
 * 它们本来就画不出图。把这件事做成必填字段，模型才必须给出判断；
 * 而如果只让它「可选地给 figure」，它会倾向于硬凑一张 —— 一张没用的图
 * 比没有图更糟，学生会以为图里有自己没看出来的东西。
 *
 * ## 为什么 figure 复用 reviewPractice 的那份形状
 *
 * 同一套点线描述、同一个 `normalizeFigure` 校验、同一个客户端渲染器。
 * 抄一份出来的后果已经见过很多次：改了一处，另一处继续按旧契约拒绝，
 * 而现象是「有的题能画、有的题画不出来」—— 看起来像两个不同的 bug。
 * 注意 `reviewPractice` 是字面量，所以这里只能**定义完之后**再取，
 * 取的是同一个对象引用，不是副本。
 */
Schemas.reviewFigure = {
  name: 'draw_explain_figure',
  description:
    '判断这道错题的讲解是否需要配图；需要就给出「点和线」的坐标描述',
  type: 'object',
  additionalProperties: false,
  required: ['draw', 'reason'],
  properties: {
    draw: {
      type: 'boolean',
      description:
        'true = 这题配一张图能帮助学生理解；false = 纯符号运算，画图没有意义。'
        + '拿不准时选 false —— 一张对不上题的图比没有图更误导。',
    },
    reason: string({
      minLength: 1,
      description: '为什么画 / 为什么不画，一句话（家长也会看到）',
    }),
    caption: string({
      description: '图下方的一句话，告诉学生这张图要看什么（≤20 字）',
    }),
    figure: Schemas.reviewPractice.properties.questions.items.properties.figure,
  },
};

/**
 * 带原题照片的讲解配图 —— 与 `reviewFigure` 共用同一份输出契约。
 *
 * 差别只在**输入**（多一张照片）。输出仍然是「该不该画 + 坐标」，
 * 所以这里只是同一个对象再挂一个名字：两份契约迟早会漂开。
 */
Schemas.reviewFigurePhoto = Schemas.reviewFigure;

/**
 * 校验一个值是否符合 schema。
 * @returns {string[]} 问题列表，空数组表示通过。每项形如 `items[1].answer 缺失`。
 */
export function validate(schema, value) {
  const problems = [];
  walk(schema, value, '', problems);
  return problems;
}

/**
 * 修掉**传输层双编码**：该是数组/对象的位置，厂商传回来的是一个 JSON 字符串。
 *
 * ## 它是怎么被发现的
 *
 * 2026-09-24 接百炼（OpenAI 兼容端点）后，`/ai/homework/ocr` 稳定失败：
 *
 * ```
 * schema_violation: 模型输出不符合约定结构：tasks 应为数组
 * ```
 *
 * 光看这句没法定位，于是写了 `scripts/probe-route.mjs` 把**模型原文**摊开，
 * 看到的是：
 *
 * ```json
 * "tasks": "\n[{\"subject\": \"语文\", \"text\": \"抄写第3课生字\"}]"
 * ```
 *
 * —— 数组被**序列化成了字符串**（多包了一层引号）。
 * 实测：`qwen3-vl-plus` 与 `qwen3-vl-flash` 各两次，**4/4 都一样**；
 * 而 OpenAI 的结构化输出开关 `strict: true` 会被接受（HTTP 200）**但不起作用**。
 * 所以「靠厂商硬约束实参」这条路在百炼兼容模式下走不通，只能自己收。
 *
 * ## 为什么这不算「宽容」
 *
 * 1. **语义是确定的**：那个字符串解析出来就是我们要的数组。
 *    这不是模型说错了话，是它把同一份数据多包了一层引号。
 * 2. **只放宽形态，不放宽内容**：修完之后**照样走 `validate`**。
 *    字符串里若装了别的东西、或装的是对象而 schema 要数组，一样判违规。
 *    所以它只新增成功路径，不新增失败路径 —— 与「降低校验标准」是两件事。
 * 3. **范围窄**：只对 schema 明确标了 `object`/`array` 的字段动手。
 *    一个 `type: 'string'` 的字段哪怕内容长得像 JSON 也**一个字都不动** ——
 *    学生作文里出现 `[1,2,3]` 是完全正常的。
 * 4. **按厂商开关**：只有声明了「这个厂商会这样」的才修
 *    （见 `config.js` 的 `MODEL_PROVIDERS`）。方舟那边行为一个字节不变。
 *
 * 与 `ark.js` 里那条「读不到 `tool_calls` 就退回 `content`」是同一类：
 * 都没让服务更松，只是把厂商的形态差异**收在一个地方**。
 *
 * ⚠️ 必须在 `validate` **之前**调用，且要对返回值做校验 —— 它不保证修成功。
 *
 * @returns {*} 修好的值。没得修时**原样返回同一个引用**（便于调用方比较）。
 */
export function repairStringifiedStructures(schema, value) {
  return repairNode(schema, value);
}

function repairNode(schema, value) {
  if (schema?.type === 'object') {
    // 该是对象、来的却是别的形态（最常见的是一个字符串）→ 试着解回来。
    if (value === null || typeof value !== 'object' || Array.isArray(value)) {
      return unmarshal(schema, value) ?? value;
    }
    let copy = null;
    for (const [key, child] of Object.entries(schema.properties ?? {})) {
      const before = value[key];
      const after = repairNode(child, before);
      if (after !== before) {
        if (copy === null) copy = { ...value };
        copy[key] = after;
      }
    }
    return copy ?? value;
  }

  if (schema?.type === 'array') {
    if (!Array.isArray(value)) return unmarshal(schema, value) ?? value;
    let copy = null;
    value.forEach((item, index) => {
      const after = repairNode(schema.items, item);
      if (after !== item) {
        if (copy === null) copy = value.slice();
        copy[index] = after;
      }
    });
    return copy ?? value;
  }

  return value;
}

/**
 * 把「本应是结构、却被序列化成字符串」的值解回来。
 *
 * 解出来之后**继续往下修**（`repairNode` 递归一次）—— 因为深层字段
 * 可能各自被序列化过，例如 `questions` 是数组、里面每项的 `options` 又是字符串。
 * 只解一层的话，症状会从「顶层报违规」变成「深层报违规」，看着像两个不同的 bug。
 *
 * 解不出来、或解出来的类型仍不对 → 返回 `null`，交给调用方原样留着，
 * 由 `validate` 去报那句**准确**的违规信息。
 */
function unmarshal(schema, value) {
  if (typeof value !== 'string') return null;
  const text = value.trim();
  if (text === '') return null;

  let parsed;
  try {
    // ⚠️ 必须先过 LaTeX 转义保护：模型把这层字符串少转义时，`\frac` 会被
    // JSON.parse 静默吃成换页符 + `rac`（见 latex-guard.js 的事故记录）。
    parsed = JSON.parse(protectLatexEscapes(text));
  } catch {
    return null;
  }

  const matches = schema.type === 'array'
    ? Array.isArray(parsed)
    : (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed));
  if (!matches) return null;

  return repairNode(schema, parsed);
}

function walk(schema, value, path, problems) {
  const at = path || '(根)';

  if (value === undefined || value === null) {
    problems.push(`${at} 缺失`);
    return;
  }

  if (schema.type === 'object') {
    if (typeof value !== 'object' || Array.isArray(value)) {
      problems.push(`${at} 应为对象`);
      return;
    }
    for (const key of schema.required ?? []) {
      if (value[key] === undefined || value[key] === null) {
        problems.push(`${at}.${key} 缺失`);
      }
    }
    for (const [key, child] of Object.entries(schema.properties ?? {})) {
      if (value[key] === undefined || value[key] === null) continue;
      walk(child, value[key], path ? `${path}.${key}` : key, problems);
    }
    // 多出来的字段只提示不拒绝：多一个字段不影响使用，
    // 但如果因此判违约，就会把一个能用的结果白白降级成模板讲解。
    return;
  }

  if (schema.type === 'array') {
    if (!Array.isArray(value)) {
      problems.push(`${at} 应为数组`);
      return;
    }
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      problems.push(`${at} 至少要有 ${schema.minItems} 项，实际 ${value.length} 项`);
    }
    if (value.length === 0) return;
    value.forEach((item, index) => {
      walk(schema.items, item, `${path}[${index}]`, problems);
    });
    return;
  }

  if (schema.type === 'string') {
    if (typeof value !== 'string') {
      problems.push(`${at} 应为字符串`);
      return;
    }
    if (schema.minLength !== undefined && value.trim().length < schema.minLength) {
      problems.push(`${at} 不能为空`);
    }
    if (schema.enum && !schema.enum.includes(value)) {
      problems.push(`${at} 取值「${value}」不在允许范围 ${schema.enum.join('/')} 内`);
    }
    return;
  }

  if (schema.type === 'boolean') {
    // 以前没有这一支：schema 里写了 boolean 的字段**完全不校验**，
    // 模型回 `uncertain: "是"` 也会被当成通过，然后客户端的 `== true`
    // 判定为假 —— 标记静默丢失，而它正是「这条可能认错了」的唯一信号。
    if (typeof value !== 'boolean') {
      problems.push(`${at} 应为布尔值`);
    }
    return;
  }

  if (schema.type === 'integer' || schema.type === 'number') {
    if (typeof value !== 'number' || !Number.isFinite(value)) {
      problems.push(`${at} 应为数字`);
      return;
    }
    if (schema.type === 'integer' && !Number.isInteger(value)) {
      problems.push(`${at} 应为整数`);
      return;
    }
    if (schema.minimum !== undefined && value < schema.minimum) {
      problems.push(`${at} 不能小于 ${schema.minimum}`);
    }
    if (schema.maximum !== undefined && value > schema.maximum) {
      problems.push(`${at} 不能大于 ${schema.maximum}`);
    }
  }
}

/** 把内部 schema 转成方舟 function calling 的 tool 定义。 */
export function toTool(schema) {
  return {
    type: 'function',
    function: {
      name: schema.name,
      description: schema.description,
      parameters: {
        type: schema.type,
        required: schema.required,
        properties: schema.properties,
        additionalProperties: schema.additionalProperties ?? false,
      },
    },
  };
}
