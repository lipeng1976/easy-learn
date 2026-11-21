import 'dart:typed_data';

import '../models/checkin_models.dart';
import '../models/knowledge_tip.dart';
import '../models/mistake_figure.dart';
import '../models/practice_figure.dart';
import '../models/review_model.dart';
import 'checkin_question_parser.dart';

/// AI 能力数据源抽象。
///
/// 与 `OcrDataSource` / `AuthDataSource` 同构：调用方只依赖本接口，
/// 生产环境注入 HTTP 实现 —— 走自建 Serverless 函数转发到模型厂商，
/// 厂商 API Key 只存在于函数的环境变量里，**不进客户端产物**。
/// （Web 端会编译进 JS，移动端可反编译，客户端直连必然泄露 Key。）
///
/// 两件事刻意**不**放在这里：
/// - **拍照识别**已由 `OcrDataSource` 承担，重复抽象只会造出两套并存的实现；
/// - **文本解析**（`HomeworkTextParser.parse`）是纯规则，不需要模型。
///
/// 本地实现见 `SimulatedAiDataSource`。它在**离线、模型故障、单元测试**
/// 三种场景下都是最终兜底路径，不是临时脚手架 —— 学习类应用必须能在
/// 没有网络的环境里继续用，而确定性输出是自动化测试的前提。
abstract class AiDataSource {
  /// 作业批改。
  ///
  /// [imagePaths] 是作业照片的本地路径。本地实现忽略它（一期批改是模拟的），
  /// 云端实现必须用它 —— 没有图片的作业批改在真实场景里不成立。
  Future<HomeworkCheckOutcome> checkHomework({
    required String subject,
    required String title,
    List<String> imagePaths = const [],
  });

  /// 单题判定。
  ///
  /// 这是闭环里唯一**直接驱动「错题毕业」**的判定：判对一次，这道题就出池。
  /// 所以返回三态而不是布尔 —— [AnswerVerdict.inconclusive] 表示规则无法判定，
  /// 调用方应保守按未通过处理，并在接入云端后升级给模型再判一次。
  Future<AnswerJudgement> judgeAnswer({
    required String studentAnswer,
    required String referenceAnswer,
    String subject = '',
    String knowledgePoint = '',
    String questionContent = '',
  });

  /// 拍照作答：把手写的**这一题**解答转录成文字。
  ///
  /// ## 它是输入方式，不是判定方式
  ///
  /// 返回的只是文字，**没有任何对错结论**。调用方要把这段文字**填进作答框**
  /// 让学生看见、能改，然后照常走 [judgeAnswer]。
  /// 这样做的理由很实在：拍照容易认错字，而认错一个数字就会让学生
  /// 「明明做对了却被判错」。让他在提交前看一眼，是把纠错权还给他。
  ///
  /// ## 为什么不像 [checkHomework] 那样传文件名
  ///
  /// 拍的是当前正在做的那一道题，题干与知识点客户端本来就有，
  /// 直接作为上下文传给模型即可（[questionContent] / [knowledgePoint]），
  /// 不需要再拿文件名去反推。
  ///
  /// [imagePaths] 是本地路径，语义与 [checkHomework] 一致：本地实现忽略它，
  /// 云端实现必须用它。本地实现返回一段**确定性的**占位文字，
  /// 而不是抛错 —— 离线时学生仍然要能作答（只是得自己敲字）。
  Future<AnswerRecognition> recognizeAnswer({
    required List<String> imagePaths,
    String questionContent = '',
    String knowledgePoint = '',
  });

  /// 错题录入：把照片里的**题目**提取成结构化文本。
  ///
  /// ## 与 [recognizeAnswer] 的分工
  ///
  /// 那条要的是「学生这一题写了什么」，这条要的是「这上面印着什么」。
  /// 两者的接收方完全不同：作答文字会被送去判定对错，题干会被存进
  /// 错题库、之后拿去讲解和出变式题。共用一个实现的后果不是报错，
  /// 而是模型对着学生手写的答案讲题 —— 讲解读起来通顺，只是答非所问。
  ///
  /// ## 只提取，不判定
  ///
  /// 学生提交的是**他认定的错题**，对错已经由他定下。所以这里没有
  /// verdict / score 字段：加了就会出现「模型说这题没错，学生录不进去」，
  /// 而他手上明明有一张打了叉的卷子。
  ///
  /// ## 为什么返回列表
  ///
  /// 一张照片常常不止一道题（整页试卷）。单题录入取第一条、
  /// 批量录入逐条确认，用的是同一份契约 —— 拆成两个端点会让
  /// 「拍一道题」和「拍一页题」走两套会各自漂的提示词。
  ///
  /// 照片里没拍到题目时返回**空候选**而不是抛错：拍糊、拍空白页
  /// 都是常见状态，调用方要能把它和「网络坏了」分开。
  Future<MistakeExtraction> extractMistakes({
    required List<String> imagePaths,
    String hint = '',
  });

  /// 单题讲解。
  ///
  /// [questionBody] 是**题目原文**，[title] 只是「作业标题 · 知识点」这样的
  /// 标签。两者必须分开传：把标签当题干发给模型，讲解会讲得头头是道，
  /// 只是讲的是别的东西 —— 而学生看不出哪里不对。
  ///
  /// [questionBody] 可以为空（历史错题没有这一列），那时模型只能按
  /// [title] 尽力而为，讲解质量会明显下降 —— 这是事实，不要用标签假装题干。
  ///
  /// ## [images] 为什么必须有
  ///
  /// 实测（2026-10-23）「用不同的方法表示下图的面积」这道题：只发一句题干，
  /// 模型回来的是「横向切 / 竖向切 / 补形 / 化简比较」这一套通用流程 ——
  /// 它连那个 L 形长什么样都不知道。而错题详情页上**本来就有这张照片**，
  /// 不带过去纯属信息浪费。有图时走视觉档。
  ///
  /// [referenceAnswer] 与 [studentProcess] 同理：讲解要指出「你这一步错了」，
  /// 就得先知道正确答案和他写了什么。这两样在库里有就传，没有就留空 ——
  /// **空串是合法值**，不要用「暂无」之类的占位文案冒充。
  ///
  /// 与 [generatePractice] 在业务上是两个动作（学生可能只想看讲解、不出题），
  /// 因此接口层保持分离。云端实现可以在 HTTP 层把两者合并成一次往返 ——
  /// 打开错题详情时这两件事几乎总是一起发生，拆成两次请求等于付两遍输入
  /// token、等两倍延迟。
  Future<MistakeExplanation> explainMistake({
    required String subject,
    required String knowledgePoint,
    required String title,
    required String wrongReason,
    String questionBody = '',
    List<AiSourceImage> images = const [],
    String referenceAnswer = '',
    String studentProcess = '',
  });

  /// 讲解配图：**这题该不该画，该画成什么样**。
  ///
  /// 返回里 `figure == null` 是**正常结果**，不是失败：初一六成错题是
  /// 有理数运算，那些题的关系全在式子里，画出来只会挤占讲解的位置。
  /// 调用方不要把它当错误弹窗，也不要因此重试 —— 重试只会再花一次钱，
  /// 拿到同一个「不该画」。
  ///
  /// [images] 传原题照片。面积题的「如图」全在照片里，纯文本档看不见
  /// 就只能凭想象画（实测会把「大矩形减缺口」的边长认错）。
  Future<MistakeFigure> generateFigure({
    required String subject,
    required String knowledgePoint,
    String title = '',
    String questionBody = '',
    String wrongReason = '',
    String referenceAnswer = '',
    String studentProcess = '',
    List<AiSourceImage> images = const [],
  });

  /// 举一反三出题。
  ///
  /// [images] 是**原题照片**。带上它，模型才知道原题长什么样 —— 只给
  /// 知识点名时它看不见图，遇到几何题会主动避开配图（实测：给
  /// 「几何图形面积」出的是「长方形长 8 宽 5」）。没有照片的历史错题
  /// 传空列表即可，那条路走纯文本模型。
  Future<List<GeneratedQuestion>> generatePractice({
    required String subject,
    required String knowledgePoint,
    String difficulty = '基础',
    int round = 1,
    int count = 3,
    List<AiSourceImage> images = const [],
  });

  /// 错题库 → 知识点提示（一句话）。
  ///
  /// 与 [explainMistake] 的差别是**粒度**，不是长短：讲解回答「这一道题
  /// 怎么解」，提示回答「这一类题最该记住哪一句」。计时页只有一行的位置，
  /// 塞一段五步讲解会把学生从正在做的题上拽走 —— 而那一屏的全部意义
  /// 就是让他专心做题。
  ///
  /// [items] 已由调用方按知识点聚合（同一知识点只出现一次）。
  /// 返回结果可能少于传入的知识点：模型拿不准时应当跳过，而不是编一句。
  Future<List<MistakeTipDraft>> summarizeMistakeTips({
    required String subject,
    required List<MistakeTipSeed> items,
  });

  /// 每日概念打卡出题：按知识点出几道**可判定**的短题。
  ///
  /// 只出 choice / judge。这不是偷懒 —— 填空与解答的合法写法无穷多
  /// （`0.5` / `1/2`），自动比对必然把做对的判错，而学生只会看到「你做错了」。
  ///
  /// ⚠️ **打卡已经不走这个方法了**（2026-10-27）：聚合错题、调网关、落库
  /// 都在数据服务里（`POST /data/checkin/generate`），客户端一次请求拿到题。
  /// 这个接口**没有调用方了**，留着只是将来做离线题库时不用重写一遍 ——
  /// 接回去之前先想清楚：题目从哪来、判分用哪份答案。
  Future<List<CheckinQuestion>> generateCheckinQuestions({
    required String subject,
    required List<CheckinSeed> items,
    int count = 5,
  });

  /// 组卷时冻结参考答案。
  ///
  /// 契约要求：宁可返回一份**通用的解题要点**，也不要编造一个具体答案。
  /// 假的参考答案会把做对的学生判成错的，比没有答案更糟。
  Future<String> referenceAnswerFor({
    required String subject,
    required String knowledgePoint,
  });

  /// 批量取参考答案。
  ///
  /// 与 [referenceAnswerFor] 的关系是「同一次动作、不同的往返次数」：
  /// 组一卷 20 道题，逐条调用就是 20 次往返，而且每次都要重付一遍同样的
  /// 提示词输入 token。云端实现会把它压成**一次请求**（服务端按 index 回包），
  /// 本地实现则逐条算 —— 契约相同，调用方不必分支。
  ///
  /// 默认实现刻意**串行**而不是 `Future.wait`：本地实现是纯计算，
  /// 并发只会让「谁先返回」变得不确定，而组卷要求同一批题每次得到同一份答案。
  ///
  /// 返回的映射以 [ReferenceQuery.key] 为键。**实现必须覆盖全部入参**：
  /// 少一条就等于纸上那道题没有参考答案，学生做完也没法对错。
  Future<Map<String, String>> referenceAnswersFor(
    List<ReferenceQuery> queries,
  ) => referenceAnswersByLoop(this, queries);
}

/// 逐条取答案的默认实现。
///
/// 提成顶层函数而不是写在接口的默认方法里，是因为本地实现用的是
/// `implements` 而不是 `extends`：接口的默认方法它继承不到，只能自己再写一遍。
/// 与其让同一个循环存在两份（改一处漏一处），不如让两边都调它。
Future<Map<String, String>> referenceAnswersByLoop(
  AiDataSource source,
  List<ReferenceQuery> queries,
) async {
  final answers = <String, String>{};
  for (final query in queries) {
    // 同一知识点只问一次：重复条目既多付一遍模型调用，
    // 也会在同一份答案上产生两条来源不同的记录。
    if (answers.containsKey(query.key)) continue;
    answers[query.key] = await source.referenceAnswerFor(
      subject: query.subject,
      knowledgePoint: query.knowledgePoint,
    );
  }
  return answers;
}

/// 一次「按知识点取参考答案」的请求。
///
/// 做成值对象而不是三个位置参数，是为了让 `subject + knowledgePoint`
/// 成为一个**可比较的键** —— 批量接口要去重、要回填，没有键就只能靠下标对齐，
/// 而下标在服务端乱序回包时会静默错位。
class ReferenceQuery {
  const ReferenceQuery({
    required this.subject,
    required this.knowledgePoint,
    this.questionTitle = '',
  });

  final String subject;
  final String knowledgePoint;

  /// 题目原文（可空）。带上它，模型是对着**这道题**给答案，
  /// 而不是只凭知识点名猜 —— 同名知识点下的题目差异可能很大。
  final String questionTitle;

  /// 去重与回填用的键。
  ///
  /// 用 `\u0000` 拼接而不是 `|` 或 `:`：知识点名里本来就可能有这些字符，
  /// 用它们拼键会让「数学|分数」与「数学」+「分数」撞成同一个键，
  /// 于是两页不同的题共用了一份答案，而且不会报任何错。
  String get key => '$subject\u0000$knowledgePoint';
}

/// 一次「本该走云端、结果回落到了本地」的记录。
///
/// 存在的意义是**不许把兜底结果伪装成 AI 输出**。
/// 本地实现给出的是通用模板，看起来煞有介事 —— 所以「这次的讲解其实来自模板」
/// 必须是一个能被读到的信号，而不是只写在日志里。
///
/// 设计文档里把 `degraded` 标在服务端响应上；落地时判定权收到了客户端，
/// 因为**只有客户端持有确定性兜底实现**：网关无法生成一份「本地版讲解」，
/// 它只能如实报错。所以服务端负责快速失败并给出 `retryable`，
/// 客户端负责回落并上报。
class AiDegradation {
  const AiDegradation({
    required this.operation,
    required this.reason,
    required this.at,
    this.code = '',
  });

  /// 哪个动作降级了：`checkHomework` / `judgeAnswer` / `explainMistake` /
  /// `generatePractice` / `referenceAnswerFor`。
  final String operation;

  /// 给人看的原因。
  final String reason;

  /// 机器可读的错误码（`timeout` / `rate_limited` / `schema_violation` …）。
  final String code;

  final DateTime at;

  @override
  String toString() => 'AiDegradation($operation, $code): $reason';
}

/// 降级事件回调。
typedef AiDegradationListener = void Function(AiDegradation event);

/// 单题判定结论。
enum AnswerVerdict {
  /// 确定答对。
  correct,

  /// 确定答错。
  wrong,

  /// **规则无法判定。**
  ///
  /// 典型场景：参考答案本身是一段「作答要求」（如「说清条件 + 给出一个符合
  /// 条件的具体例子」），而不是可与学生答案比对的短答案。这类题目用字符串
  /// 包含关系判定必然为假，直接判「错」就是在惩罚认真作答的学生。
  ///
  /// 本地实现没有更强的手段，调用方按未通过处理；接入云端后这一态应当
  /// **升级给模型判定**，而不是当作错误吞掉。
  inconclusive,
}

/// 单题判定结果。
class AnswerJudgement {
  const AnswerJudgement({
    required this.verdict,
    required this.score,
    required this.comment,
    this.source = AiAnswerSource.local,
  });

  final AnswerVerdict verdict;

  /// 0-100。满分仅当 [verdict] 为 [AnswerVerdict.correct]。
  final int score;

  /// 给学生的反馈文案。
  final String comment;

  /// 这份结论是模型给的，还是本地兜底给的。
  ///
  /// 与 [HomeworkCheckOutcome.source] 同一条理由：结论**要落库**，
  /// 而落库之后拿到的只有一个 `review_attempt` 行 —— 回调那条流早就散了。
  ///
  /// 方向同样是刻意的：默认 [AiAnswerSource.local]，**拿不准时按本地算**。
  /// 反过来的话，一个忘记赋值的实现会把模板结论标成模型产出。
  ///
  /// 影子比对（`JudgementShadow`）靠它决定「这次要不要记一笔」：
  /// 本地结论没有模型侧可比，比出来的是「规则 vs 规则」。
  final AiAnswerSource source;

  /// 是否通过。只有明确判定为对才算通过 ——
  /// `inconclusive` 不算通过，理由见 [AnswerVerdict.inconclusive]。
  bool get passed => verdict == AnswerVerdict.correct;
}

/// 一次拍照作答的识别结果。
///
/// ⚠️ **它里面没有 verdict / score，这是刻意的**：这条链路只负责
/// 「把照片变成可编辑的文字」。一旦这里返回对错，就会出现
/// 「学生还没确认转录对不对，系统已经给了结论」—— 而他改都改不了，
/// 因为结论已经写进界面了。
class AnswerRecognition {
  const AnswerRecognition({
    required this.text,
    required this.confidence,
    this.uncertain = '',
    this.source = AiAnswerSource.local,
  });

  /// 照片里学生写出来的内容，原样转录。
  ///
  /// 可能是空串或占位文案（例如「（未看到作答内容）」）——
  /// **不要**把它当成「学生没作答」的判据，调用方要么让重拍、
  /// 要么让学生自己敲。见 [isUsable]。
  final String text;

  /// 识别把握，0-1。
  ///
  /// 这是唯一能把「认错了」和「学生真写错了」分开的信号：
  /// 转录文字会被送去判定，认错一个字就可能把对的判成错的，
  /// 而界面上那份转录读起来完全正常，谁也看不出问题出在认字这一步。
  final double confidence;

  /// 认不准的具体位置，交由学生核对。空串表示「都认得清」。
  final String uncertain;

  /// 这份转录是模型给的，还是本地兜底给的。
  ///
  /// 与 `AnswerJudgement.source` 同一条理由，且更有必要：
  /// 本地兜底给出的是一段**编造的文字**，如果被当成识别结果，
  /// 学生会以为系统真的认出了他写的字。
  final AiAnswerSource source;

  /// 低于这个把握就值得让学生核一眼。
  ///
  /// 0.8 与 `kOcrConfidenceFloor` 取同一个值，含义也一致：**它回答的是
  /// 「值不值得核对」，不是「算不算识别成功」**。这两件事在两条链路上
  /// 都必须分开 —— 合起来的后果是「认出来了但把握低」的结果被整份丢掉，
  /// 而学生看到的提示是「没能认出来」。见 `HomeworkOcrResult.needsReview`。
  static const double confidenceFloor = 0.8;

  /// 这份转录**像不像真的认出了东西**。
  ///
  /// 空文本、或本地兜底出来的占位文字，都不算。调用方据此决定
  /// 「填进作答框后要不要提示学生自己核对」。
  ///
  /// 刻意**不看 [confidence]**：本地兜底的 confidence 是 0，
  /// 云端识别出「照片里根本没写字」时 confidence 也很低，
  /// 但这两件事的处置不一样（一个要重拍，一个要自己敲）。
  /// 把两个条件揉进一个 getter，调用方就没法区分它们了。
  bool get isUsable => text.trim().isNotEmpty && source.isCloud;

  /// 值不值得提醒学生核对一遍。
  bool get needsReview => !isUsable || confidence < confidenceFloor;
}

/// 从照片里提取出来的一道题。
///
/// ⚠️ **没有 verdict / score**，理由见 [AiDataSource.extractMistakes]：
/// 学生提交的是他认定的错题，不需要模型再判一遍对错。
class ExtractedMistake {
  const ExtractedMistake({
    required this.questionBody,
    this.answerKey = '',
    this.knowledgePoint = '',
    this.confidence = 0,
    this.uncertain = '',
  });

  /// 题干原文（数学表达式为 LaTeX）。
  ///
  /// 这是要**落库**的字段：之后讲解、出变式题都对着它。
  /// 所以它必须完整到能独立作答 —— 缺了「已知条件」的题干会让
  /// 模型解一道不存在的题。
  final String questionBody;

  /// 参考答案。空串表示「照片里没有、也不该猜」。
  ///
  /// ⚠️ 它会被存成 `answerKey`，之后拿去判定学生做对还是做错。
  /// 调用方要让**学生确认**再入库，不要因为模型给了就当成事实。
  final String answerKey;

  /// 知识点，组卷 / 讲解 / 举一反三的驱动键。空串表示没识别出来。
  final String knowledgePoint;

  /// 对这一条的把握，0-1。
  final double confidence;

  /// 认不准的位置，给人看。空串表示都认得清。
  final String uncertain;

  /// 低于这个把握的候选要在界面上**标黄并默认不勾选**。
  ///
  /// 0.6 比 `AnswerRecognition.confidenceFloor`（0.8）松：那里的文字
  /// 直接决定了「判对还是判错」，错一个字就毁一条结论；这里的题干
  /// 学生会在表单里通读一遍再提交，容错空间更大。
  /// 阈值不同是有意的 —— 两个场景的错代价不一样。
  static const double reviewFloor = 0.6;

  /// 值不值得让学生先核一眼。
  bool get needsReview => confidence < reviewFloor;
}

/// 一次错题提取的结果。
///
/// 与 [AnswerRecognition] 一样，`source` 决定这份结果**能不能当真**：
/// 本地兜底返回的是空列表（不是编造的题目），标 `local` 让界面
/// 如实说「识别不了，请手填」，而不是显示一片空白让人以为没拍到。
class MistakeExtraction {
  const MistakeExtraction({
    this.candidates = const [],
    this.confidence = 0,
    this.uncertain = '',
    this.source = AiAnswerSource.local,
  });

  /// 提取到的题目，按从上到下、从左到右排序。
  ///
  /// 空列表是**合法状态**（照片糊了 / 拍的是空白页 / 离线），
  /// 调用方不能把它当异常。
  final List<ExtractedMistake> candidates;

  /// 整张照片的把握。与逐条的 confidence 分开：
  /// 一页里糊了一道题，不该把能用的另外七道一起判成不可用。
  final double confidence;

  /// 整张照片层面的问题（「右下角被裁掉了」）。空串表示没有。
  final String uncertain;

  /// 模型给的还是本地兜底给的。
  final AiAnswerSource source;

  /// 这份提取**像不像真的认出了题目**。
  ///
  /// 刻意不看 [confidence]：云端识别出「照片里没有题目」时 confidence
  /// 也很低，但那是「要重拍」，而本地兜底是「得自己敲」——
  /// 两种处置不一样，揉进一个 getter 就没法区分了。
  bool get isUsable => source.isCloud && candidates.isNotEmpty;

  /// 值不值得提醒学生核对。
  bool get needsReview => !isUsable || confidence < AnswerRecognition.confidenceFloor;
}

/// 一份 AI 结果的来源。
///
/// 为什么要把「来源」放进结果本身，而不是靠 [AiDegradation] 回调去旁听：
/// 回调是**流**，而批改结果是**要落库的数据**。学生这边降级了、家长那边
/// 是另一个会话（另一台设备、另一次启动），它拿到的只有库里那条记录。
/// 来源不跟着数据走的话，家长看到的就是一份通用模板被当作 AI 批改结论。
enum AiAnswerSource {
  /// 本地确定性兜底（`SimulatedAiDataSource`）。
  ///
  /// 语义是「模型没用上，退到了模板」——**不是**「用规则算出来的」。
  local,

  /// 云端模型。
  cloud,

  /// 本地**规则**判定（选择题比对选项、判断题比对对错）。
  ///
  /// 与 [local] 必须分开：`local` 意味着这次没拿到模型、结果要打折看；
  /// `rule` 意味着这题根本不需要模型，结论是确定的。
  /// 混成一个值会让「选择题判得又快又准」被读成「这次模型挂了」。
  rule;

  /// 结论是否来自模型。
  ///
  /// 影子比对（`JudgementShadow`）只对模型结论记账 —— 规则判定没有
  /// 「模型侧」可比，硬记一条就成了「规则 vs 规则」。
  bool get isCloud => this == AiAnswerSource.cloud;

  /// 是否走了确定性路径（规则或本地兜底），即**没有**模型参与。
  bool get isDeterministic => !isCloud;
}

/// 一次作业批改的结果。
class HomeworkCheckOutcome {
  const HomeworkCheckOutcome({
    required this.score,
    required this.summary,
    required this.items,
    this.formatIssues = const [],
    this.source = AiAnswerSource.local,
  });

  /// 0-100 的整数评分。
  ///
  /// **只由答案的对错决定**，书写规范问题不扣分。
  final int score;

  /// 便于家长理解的一句话总结。
  final String summary;

  /// 答案确实做错的题，可直接构造成错题本条目。
  ///
  /// ⚠️ 这个列表会**整条进错题库**，之后被组卷重做、还会生成变式题。
  /// 所以「算对了但没写单位」这类规范问题不属于这里 —— 那是 [formatIssues]。
  /// 把规范问题放进来，学生会反复重做一道他本来就会的题。
  final List<HomeworkCheckItem> items;

  /// 答案正确、只是写法不规范的地方（漏单位、没写答句、跳步…）。
  ///
  /// 只在批改结果里提示一次，**不进错题库、也不影响 [score]**。
  /// 默认空列表：没有这类问题时模型会省略该字段，那不是错误。
  final List<HomeworkFormatIssue> formatIssues;

  /// 这份结果是模型给的，还是本地兜底给的。
  ///
  /// 默认值是 [AiAnswerSource.local]，方向是刻意的：**拿不准时按本地算**。
  /// 反过来的话，一个忘记赋值的实现会让模板结果被标成 AI 产出 ——
  /// 那正是这套机制要防的事。
  final AiAnswerSource source;

  int get wrongCount => items.length;
}

/// 批改发现的单个错题。
class HomeworkCheckItem {
  const HomeworkCheckItem({
    required this.question,
    required this.knowledgePoint,
    required this.originalAnswer,
    required this.wrongReason,
    this.questionNo = '',
    this.studentProcess = '',
    this.standardAnswer = '',
  });

  /// 学生这次**写出来的过程**（照抄，可能为空）。
  ///
  /// 为什么单独要：讲解要说清「他卡在哪一步」，只知道最终答案是错的，
  /// 讲出来只能是泛泛而谈。而这个过程只在批改那一刻看得到 ——
  /// 作业照片之后可能被删掉。
  ///
  /// ⚠️ 空串是常态（选择题、填空题没有过程）。**绝不能为了填满而补**：
  /// 编出来的步骤会让讲解去纠正一个学生根本没写过的错。
  final String studentProcess;

  /// 模型算出的正确结果。
  ///
  /// 批改这一刻它同时看到题目与作答，算答案的上下文比组卷时更全。
  /// ⚠️ 实测它会算错（2026-10-21：一道「a×a」的选择题给了错误选项），
  /// 所以它**只在错题详情里作参考**；重做卷的答案页仍然走
  /// `referenceAnswersFor` 单独问一次。
  final String standardAnswer;

  /// 这道题在**原作业卷面上的题号原文**（`20`、`20(4)`、`三、2`…）。
  ///
  /// 空串 = 卷面没有题号，或模型没认出来。
  ///
  /// 为什么单独要一个字段而不是写进 [question]：家长/老师要**对着作业本
  /// 找出那道题**，题号是唯一可靠的定位；而题干里混一个「第 3 题」前缀，
  /// 以后想拿它去搜题、去组卷都会被污染。
  ///
  /// ⚠️ 模型有可能自己编题号。所以它只用于**展示**，绝不参与判分与排序
  /// —— 编错了最多是列表上显示一个错的「第 X 题」，不会造出假错题。
  final String questionNo;

  /// 题干原文（含 LaTeX 行内公式）。
  ///
  /// 批改这一步是**唯一**能同时看到题目与作答的时机，所以题干必须在这里
  /// 抄下来。以前这里只有知识点，调用方只好把「作业标题 · 知识点」塞进
  /// `ReviewMistake.title` 当题目 —— 讲解拿到一句标签，自然只能讲得笼统。
  ///
  /// 允许为空：模型偶尔会漏（或题干确实拍不全）。为空时调用方回退到
  /// [knowledgePoint] 拼出的标题，**而不是让整份批改作废** —— 一次批改里
  /// 有一条没题干，不该把另外几条真错题连带丢掉。解析层对空值会留痕迹
  /// （`question_missing`），所以这不是静默降级。
  final String question;

  /// 知识点名（如「分数计算」）。
  ///
  /// 这是**组卷、讲解、举一反三的驱动键**，不是展示用的题目名。
  /// 展示名由调用方拼成「作业标题 · 知识点」，两者必须分开存 ——
  /// 混在一起以后就再也拆不出来了。
  final String knowledgePoint;

  /// 学生这次的答案。
  final String originalAnswer;

  /// 错误原因说明。
  final String wrongReason;
}

/// 批改发现的**书写规范**问题（答案本身是对的）。
///
/// 与 [HomeworkCheckItem] 分开的理由，是这两类东西的**去向完全不同**：
///
/// - 错题 → 进错题库，会被组卷重做、还会生成变式题；
/// - 规范问题 → 只在这次批改里提示一次，然后就没有下文了。
///
/// 混在一起的实际后果已经实测过：一份答案全对的卷子报了 5 条「错题」，
/// 其中 3 条是「没写单位」—— 学生于是反复重做他本来就会的题，
/// 而「错题」这两个字也就不再意味着「我不会」。
class HomeworkFormatIssue {
  const HomeworkFormatIssue({
    required this.knowledgePoint,
    required this.detail,
  });

  /// 知识点名，与 [HomeworkCheckItem.knowledgePoint] 同源，便于按点归类。
  final String knowledgePoint;

  /// 哪里不规范、应该怎么改，例如「第 4 题算对了但没写单位 元」。
  final String detail;
}

/// 一道生成的变式题。
///
/// 刻意不带 id / studentId / createdAt —— 那些是**落库实体**
/// （`AiPracticeQuestion`）的属性，由调用方在入库时生成。
/// provider 只负责「生成题目内容」这一件事。
class GeneratedQuestion {
  const GeneratedQuestion({
    required this.title,
    required this.content,
    required this.answer,
    required this.difficulty,
    this.questionType = PracticeQuestionType.solution,
    this.options = const [],
    this.figure,
  });

  final String title;
  final String content;
  final String answer;
  final String difficulty;

  /// 题型。由模型按错题本身决定（选择/填空/判断/解答）。
  ///
  /// 默认 [PracticeQuestionType.solution] 是刻意的：解析层不认识某个取值时
  /// 会回落到它，而它是**最宽松**的那条路 —— 一道被误判成解答题的填空题
  /// 仍然能做、能被模型判；反过来把解答题当成选择题则会直接没法作答。
  final PracticeQuestionType questionType;

  /// 选择题的选项（不含 `A.` 前缀）。非选择题为空。
  final List<String> options;

  /// 配图。为空表示这道题**不需要图**（纯文字题）。
  ///
  /// 它是「点和线」的描述（[PracticeFigure]），不是图片：模型只能描述结构，
  /// 画由客户端做。让模型出位图的后果是线长与标注数字对不上 ——
  /// 那种图看起来完全正常，学生照着它推理就会得出基于错误前提的结论。
  final PracticeFigure? figure;
}

/// 随请求一起送出去的**题目照片**（举一反三的原题、错题讲解的原题）。
///
/// 只带字节，不带 storageKey：网关拿不到客户端的本地存储，
/// 而错题照片在客户端本来就不在本地（是经 `sign-read` 取的）。
class AiSourceImage {
  const AiSourceImage({required this.bytes, this.mimeType = 'image/jpeg'});

  final Uint8List bytes;
  final String mimeType;
}
