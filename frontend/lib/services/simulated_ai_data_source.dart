import '../data/drill_bank.dart';
import '../models/checkin_models.dart';
import '../models/knowledge_tip.dart';
import '../models/mistake_figure.dart';
import '../models/review_model.dart';
import 'ai_data_source.dart';
import 'checkin_question_parser.dart';

/// AI 能力的本地实现。
///
/// **存在的意义不是「占位」**，而是三条真实路径：
/// 1. **离线** —— 学生在没有网络的环境做作业，批改仍需给出结果；
/// 2. **降级** —— 模型超时 / 限流 / 故障时返回它，好过让页面直接报错；
/// 3. **测试** —— 输出由「输入 + 稳定哈希」推导，同一输入永远同一结果。
///
/// 所以接入云端后**不要删掉它**，它是兜底而不是脚手架。
///
/// 所有结果都由 [_stableHash] 推导而非随机数。这不是「假得不够真」，而是
/// 刻意为之：批改结果会写进错题本、驱动组卷与毕业判定，
/// 「学生看到 78 分、家长刷新后看到 91 分」这种事故的代价，
/// 远大于结果随机带来的那点真实感。
class SimulatedAiDataSource implements AiDataSource {
  const SimulatedAiDataSource();

  /// 参考答案剥掉括号说明后超过这个长度，就不再是「可比对的短答案」，
  /// 而是一段作答要求。判定逻辑见 [judgeAnswer]。
  static const int _descriptiveAnswerThreshold = 12;

  @override
  Future<HomeworkCheckOutcome> checkHomework({
    required String subject,
    required String title,
    List<String> imagePaths = const [],
  }) async {
    final seed = _stableHash('$subject|$title');
    final wrongCount = seed % 4; // 0..3

    final points = _knowledgePoints[subject] ?? _defaultKnowledgePoints;
    final items = <HomeworkCheckItem>[];
    final used = <int>{};
    for (var i = 0; i < wrongCount; i++) {
      var index = (seed >> (i * 3 + 1)) % points.length;
      while (used.contains(index)) {
        index = (index + 1) % points.length;
      }
      used.add(index);
      items.add(
        HomeworkCheckItem(
          // 本地兜底拿不到真题目（它根本没有看照片），但**不能留空**：
          // 空题干会让学生端"看起来一切正常、讲解却莫名其妙"，那种
          // 静默不一致正是这套兜底最该避免的。明确标成模拟题干，
          // 学生一眼能看出这是离线结果。
          question: '（本地模拟题干）第 ${i + 1} 题：${points[index]}。',
          // 兜底实现说自己就是「第 N 题」，题号照实给 —— 否则界面上会
          // 一半有条目一半没有，看着像 bug。
          questionNo: '${i + 1}',
          knowledgePoint: points[index],
          originalAnswer:
              _originalAnswers[(seed >> (i * 2)) % _originalAnswers.length],
          wrongReason:
              _wrongReasons[(seed >> (i * 2 + 1)) % _wrongReasons.length],
        ),
      );
    }

    // 无错题给 96-100，有错题按错题数扣分，保证落在 60-100 的合理区间。
    final score = wrongCount == 0
        ? 96 + (seed % 5)
        : (96 - wrongCount * 7 - (seed % 5)).clamp(60, 100);

    final summary = wrongCount == 0
        ? '本次作业全部正确，书写与步骤完整，保持这个状态。'
        : '共发现 $wrongCount 处需要更正：'
              '${items.map((e) => e.knowledgePoint).join('、')}。'
              '建议先看课本对应例题，再重新做一遍。';

    return HomeworkCheckOutcome(
      score: score,
      summary: summary,
      items: items,
    );
  }

  /// 拍照作答的本地实现。
  ///
  /// ## 为什么返回一段**明确的占位文案**，而不是抛错
  ///
  /// 抛错的后果是「离线时这个功能按钮点了没反应」。而问题在于：
  /// **拍照本身在离线时也能用** —— 图片在本地存着，等联网了再传就是。
  /// 所以这里如实回一段说明，让调用方把它填进作答框并告诉学生
  /// 「现在识别不了，你自己敲或者等下再试」，比直接炸掉好。
  ///
  /// ## 为什么 `source` 标成 local 而不是 cloud
  ///
  /// ⚠️ 这是这条链路里最容易出错的**一处**：本地实现返回的是一段
  /// **编造的文字**。如果它被标成 cloud，`isUsable` 会返回 true，
  /// 学生会以为系统真的认出了他写的字 —— 而那段字是模板编的。
  /// 所以这里既给占位文案、又标 local：调用方两重信号都能看到。
  ///
  /// `confidence` 给 0：它不代表「识别得很差」，而代表**根本没识别**。
  @override
  Future<AnswerRecognition> recognizeAnswer({
    required List<String> imagePaths,
    String questionContent = '',
    String knowledgePoint = '',
  }) async {
    if (imagePaths.isEmpty) {
      // 与网关侧同一条判据：没有照片就一定没得识别。
      // 让它返回占位文案会让「客户端忘了传图」表现成「照片里没写字」。
      throw ArgumentError('拍照作答至少需要一张照片');
    }
    return const AnswerRecognition(
      text: '（当前无法识别手写，请直接输入你的答案）',
      confidence: 0,
      source: AiAnswerSource.local,
    );
  }

  /// 错题录入的本地实现：**识别不了，就直说识别不了**。
  ///
  /// 这里刻意不返回一道「模板题」：题干会被存进错题库，之后拿去
  /// 讲解和出变式题 —— 一道编造的题干会一直跟着这个学生，
  /// 而他每次打开都看到一份对着别的题写的讲解。
  ///
  /// 返回空候选 + `source: local`，界面据此提示「请手动填写」。
  /// 这与 [recognizeAnswer] 返回占位文案不是两种风格，而是两种处置：
  /// 作答框里填一句「请直接输入」是**可编辑的提示**；
  /// 题干框里填一句模板文字则会被当成题目存下去。
  @override
  Future<MistakeExtraction> extractMistakes({
    required List<String> imagePaths,
    String hint = '',
  }) async {
    if (imagePaths.isEmpty) {
      // 与网关侧同一条判据：没有照片就一定没得提取。
      throw ArgumentError('错题录入至少需要一张照片');
    }
    return const MistakeExtraction(
      source: AiAnswerSource.local,
      uncertain: '当前无法识别照片里的题目，请手动填写题干',
    );
  }

  /// 纸质卷回传后的单题判定。
  ///
  /// 判定在两种口径下取并集：
  /// 1. **整串比对** —— 学生只写了核心答案（「5/6 < 7/8」）；
  /// 2. **去掉括号过程说明后比对** —— 学生把过程也写全了
  ///    （「5/6 < 7/8（通分后 20/24 < 21/24）」）。
  ///
  /// 两条口径**必须同时作用于两侧**。曾经只剥参考答案、不剥学生答案，
  /// 结果是「写得越完整越容易被判错」—— 认真写过程的孩子反而被判成不会，
  /// 这比不判更伤人，也让举一反三的 3 道题永远凑不齐全对。
  @override
  Future<AnswerJudgement> judgeAnswer({
    required String studentAnswer,
    required String referenceAnswer,
    String subject = '',
    String knowledgePoint = '',
    String questionContent = '',
  }) async {
    final answer = _normalizeForCompare(studentAnswer);
    if (answer.isEmpty) {
      return const AnswerJudgement(
        verdict: AnswerVerdict.wrong,
        score: 0,
        comment: '没有填写答案，按未通过处理。先看一遍讲解，再做一轮。',
      );
    }

    final candidates = <String>{
      answer,
      _normalizeForCompare(_withoutNotes(studentAnswer)),
    };
    final targets = <String>{
      _normalizeForCompare(referenceAnswer),
      _normalizeForCompare(_withoutNotes(referenceAnswer)),
    };
    final correct = candidates.any(
      (candidate) =>
          candidate.isNotEmpty &&
          targets.any(
            (target) =>
                target.isNotEmpty &&
                (target.contains(candidate) || candidate.contains(target)),
          ),
    );

    if (correct) {
      final praise =
          _praiseComments[_stableHash(knowledgePoint) % _praiseComments.length];
      return AnswerJudgement(
        verdict: AnswerVerdict.correct,
        score: 100,
        comment: '答案正确。$praise',
      );
    }

    // 走到这里说明「对不上」，但「对不上」有两种截然不同的原因，必须分开：
    //   - 参考答案是**短答案**（数值、单词、短句）→ 对不上就是真错；
    //   - 参考答案是**作答要求**（「说清条件 + 给出一个具体例子」这类）→
    //     字符串包含关系天然为假，判「错」等于惩罚认真作答的学生。
    // 后者本地没有更强的手段，标为 inconclusive 交给云端模型。
    final bareReference = _normalizeForCompare(_withoutNotes(referenceAnswer));
    if (bareReference.length >= _descriptiveAnswerThreshold) {
      return const AnswerJudgement(
        verdict: AnswerVerdict.inconclusive,
        score: 0,
        comment: '这道题的参考答案是「作答要求」而不是具体答案，'
            '本地无法自动判定对错。已按未通过记录，请对照课本自查一遍。',
      );
    }

    final hint =
        _retryHints[_stableHash('$knowledgePoint|$studentAnswer') %
            _retryHints.length];
    return AnswerJudgement(
      verdict: AnswerVerdict.wrong,
      score: 0,
      comment: '答案与参考答案不一致。$hint',
    );
  }

  /// 讲解配图。
  ///
  /// 本地实现**永远不画**。这不是偷懒：画图这件事的难点在于「坐标必须
  /// 与题目对得上」，而本地实现没有读题的模型，它只能按知识点名硬套
  /// 一个图形模板 —— 套出来的边长、角度多半和那道题无关。
  /// 一张数字对不上的几何图，学生照着推理会得出错误结论，而它看起来
  /// 完全正常（见 `PracticeFigure` 顶部）。所以宁可明说「先看文字讲解」。
  @override
  Future<MistakeFigure> generateFigure({
    required String subject,
    required String knowledgePoint,
    String title = '',
    String questionBody = '',
    String wrongReason = '',
    String referenceAnswer = '',
    String studentProcess = '',
    List<AiSourceImage> images = const [],
  }) async {
    return const MistakeFigure(
      reason: '离线时不画图，先看上面的文字讲解。',
    );
  }

  /// 单题讲解。结构固定，便于渲染与测试。
  ///
  /// 用「科目 + 知识点」稳定哈希选取讲解语料：同一道题讲多少次都一样，
  /// 否则学生和家长会看到两套解释，讲解的可信度直接归零。
  @override
  Future<MistakeExplanation> explainMistake({
    required String subject,
    required String knowledgePoint,
    required String title,
    required String wrongReason,
    String questionBody = '',
    List<AiSourceImage> images = const [],
    String referenceAnswer = '',
    String studentProcess = '',
  }) async {
    // [questionBody] 在这里刻意**不参与**生成：本地实现是确定性兜底，
    // 它给的是「这一类题」的通用解法。把题干塞进模板只会让人以为
    // 这份讲解是针对那道题写的 —— 而它并不是，这正是 `source: local`
    // 要让人看见的事。
    final point = knowledgePoint.isEmpty ? '基础知识' : knowledgePoint;
    final seed = _stableHash('$subject|$point');

    final steps = <String>[
      '圈条件：把已知量和要求圈出来，确认单位一致。',
      '认考点：先判断这道题在考「$point」的哪条判定条件。',
      '写过程：每一步只做一件事，中间结果都写出来，不跳步。',
      '回代验算：把答案带回原题，检查范围和单位是否合理。',
    ];

    final pitfalls = {
      _pitfallBank[seed % _pitfallBank.length],
      _pitfallBank[(seed >> 3) % _pitfallBank.length],
      _pitfallBank[(seed >> 6) % _pitfallBank.length],
    }.toList();

    return MistakeExplanation(
      knowledgePoint: point,
      position: _positionOf(point, subject),
      whyWrong: wrongReason.isEmpty
          ? '这道题的错误集中在「$point」的条件判断上，属于方法没选对，不是计算粗心。'
          : '${_stripPeriod(wrongReason)} 问题的根子在「$point」这一步：'
                '条件没吃透就动笔，后面越算越偏。',
      steps: steps,
      pitfalls: pitfalls,
      mnemonic: _mnemonicOf(point, seed),
    );
  }

  /// 错题库 → 知识点提示（本地兜底）。
  ///
  /// ⚠️ **它给的不是知识点内容**，是一条「自检问句」：本地实现没有教材，
  /// 编一句「一元二次方程的求根公式是……」出来，错了就是让学生把错的
  /// 东西记住。所以这里只做两件能保证为真的事：
  /// 复述错题次数（来自真实数据），并把知识点变成一个可以当场回答的问题。
  ///
  /// 界面上这两类提示的出处是分开的（`KnowledgeTipSource.rule`），
  /// 不会冒充模型归纳的结果。
  @override
  Future<List<MistakeTipDraft>> summarizeMistakeTips({
    required String subject,
    required List<MistakeTipSeed> items,
  }) async {
    return buildRuleTips(items);
  }

  /// 规则提示的**纯函数**版本。
  ///
  /// 计时页要「打开就能显示一条」，不能等一次 Future；而这条同步路径
  /// 与 [summarizeMistakeTips] 必须产出同一份文字 —— 分成两套实现的话，
  /// 联网与离线看到的提示措辞会不一样，而且没人会去比对。
  static List<MistakeTipDraft> buildRuleTips(List<MistakeTipSeed> items) {
    final drafts = <MistakeTipDraft>[];
    for (final seed in items) {
      final point = seed.knowledgePoint.trim();
      if (point.isEmpty || drafts.length >= 6) continue;
      final prefix = seed.wrongCount >= 2
          ? '「$point」你已经错了 ${seed.wrongCount} 次'
          : '「$point」';
      drafts.add(
        MistakeTipDraft(
          knowledgePoint: point,
          text: '$prefix：先用一句话说出它的定义，说不出来就先翻书。',
          source: KnowledgeTipSource.rule,
        ),
      );
    }
    return drafts;
  }

  /// 举一反三出题。
  ///
  /// 由**知识点**驱动，而不是题目名：题目名带着作业前缀（「数学作业A · 分数计算」），
  /// 拿它去找同类题永远找不到。难度与轮次一起参与哈希，所以
  /// 「同一题重做第二遍」会拿到另一组变式，而同一条件下重复出题结果稳定。
  @override
  Future<List<GeneratedQuestion>> generatePractice({
    required String subject,
    required String knowledgePoint,
    String difficulty = '基础',
    int round = 1,
    int count = 3,
    List<AiSourceImage> images = const [],
  }) async {
    final bank = _templateBank(subject, knowledgePoint);
    if (bank.isEmpty) return const [];
    final seed = _stableHash('$subject|$knowledgePoint|$difficulty|$round');
    final start = seed % bank.length;
    return List.generate(count, (index) {
      final entry = bank[(start + index) % bank.length];
      return GeneratedQuestion(
        title: '变式 ${index + 1} · ${entry['title']}',
        content: entry['content'] as String,
        answer: entry['answer'] as String,
        difficulty: difficulty,
      );
    });
  }

  /// 每日概念打卡出题：本地实现**用真实题库兜底，不伪造题干**。
  ///
  /// 与 [generatePractice] 造模板题不同：打卡题会被孩子当成「今天的练习」
  /// 认真做，编出来的题是在浪费她的时间。`kDrillBank` 那 71 道是手写的，
  /// 误区选项照着真实错法设计，正好对上「按错题知识点出题」这个用法。
  ///
  /// 知识点对不上时**不在这里做模糊匹配** —— 别名归一化只该有一处
  /// （`drill_selector` 的 alias 表），这里退化为按稳定哈希从全库取。
  @override
  Future<List<CheckinQuestion>> generateCheckinQuestions({
    required String subject,
    required List<CheckinSeed> items,
    int count = 5,
  }) async {
    if (items.isEmpty) return const [];
    final wanted = {for (final item in items) item.knowledge};
    final matched = kDrillBank.where((q) => wanted.contains(q.knowledge)).toList();
    final pool = matched.isNotEmpty ? matched : kDrillBank;
    if (pool.isEmpty) return const [];

    const letters = 'ABCDEF';
    final start = _stableHash('$subject|${items.map((e) => e.knowledge).join(',')}') % pool.length;
    return List.generate(count.clamp(1, 10), (index) {
      final question = pool[(start + index) % pool.length];
      return CheckinQuestion(
        stem: question.stem,
        options: question.options,
        answer: letters[question.answerIndex],
        knowledge: question.knowledge,
        analysis: question.explain.pitfall,
        type: CheckinQuestionType.choice,
      );
    });
  }

  /// 组卷时冻结一份参考答案。
  ///
  /// 优先取该知识点的模板答案；没有模板时退化为「标准解法要点」。
  /// 宁可给出一份通用的解题要点，也不要假造一个具体答案：
  /// 假的参考答案会把做对的学生判成错的，比没有答案更糟。
  @override
  Future<String> referenceAnswerFor({
    required String subject,
    required String knowledgePoint,
  }) async {
    final byPoint = _knowledgeTemplates[knowledgePoint];
    if (byPoint != null && byPoint.isNotEmpty) {
      return byPoint.first['answer'] as String;
    }
    final bySubject = _subjectTemplates[subject];
    if (bySubject != null && bySubject.isNotEmpty) {
      return bySubject.first['answer'] as String;
    }
    return '按标准解法作答：圈条件 → 认考点 → 写过程 → 回代验算。'
        '${knowledgePoint.isEmpty ? '' : '重点检查「$knowledgePoint」这一步。'}';
  }

  /// 批量版本与逐条版本走同一段循环逻辑，见 [referenceAnswersByLoop]。
  ///
  /// 这里必须显式实现：本类用的是 `implements` 而不是 `extends`，
  /// 接口上的默认方法它继承不到。少写这个方法会**编译不过**（好事），
  /// 而不是在运行时静默退回别处。
  @override
  Future<Map<String, String>> referenceAnswersFor(
    List<ReferenceQuery> queries,
  ) => referenceAnswersByLoop(this, queries);

  /// 按科目检索题库，并把最贴合知识点的题排到前面，
  /// 保证「出题围绕这次错的那个知识点」而不是随便三道同科目题。
  List<Map<String, dynamic>> _templateBank(
    String subject,
    String knowledgePoint,
  ) {
    final pool = <Map<String, dynamic>>[
      ...?_subjectTemplates[subject],
      ...?_knowledgeTemplates[knowledgePoint],
    ];
    if (pool.isEmpty) return _fallbackTemplates(knowledgePoint);
    return pool;
  }

  List<Map<String, dynamic>> _fallbackTemplates(String knowledgePoint) => [
    {
      'title': '概念复述',
      'content': '用自己的话说明「$knowledgePoint」的判定条件，并举一个例子。',
      'answer': '说清条件 + 给出一个符合条件的具体例子。',
    },
    {
      'title': '基础变式',
      'content': '找一道与「$knowledgePoint」同类型的题完成，写出完整过程。',
      'answer': '对照课本例题检查步骤是否完整。',
    },
    {
      'title': '反向变式',
      'content': '把「$knowledgePoint」的条件与结论对调，重新解一遍。',
      'answer': '注意对调后条件是否唯一，不唯一时要讨论。',
    },
  ];

  /// FNV-1a 32 位哈希。用于把「科目 + 标题」映射成稳定的伪随机序列。
  static int _stableHash(String input) {
    var hash = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  /// 去掉空白与全角符号后再比对。
  /// 学生手写录入时全角 / 半角、空格差异极常见，不做归一化会把对的判成错的。
  static String _normalizeForCompare(String input) => input
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('＝', '=')
      .replaceAll('＋', '+')
      .replaceAll('－', '-')
      .replaceAll('×', '*')
      .replaceAll('÷', '/')
      .replaceAll('，', ',')
      .toLowerCase();

  /// 剥掉括号里的过程说明，例如
  /// 「40 平方厘米（(6+10)×5÷2）」→「40 平方厘米」。
  ///
  /// 用「反复剥掉最内层括号」而不是一次正则替换：一次替换碰上嵌套括号
  /// 只会吃掉半截，留下一个孤零零的右括号，反而造出对不上的字符串
  /// （`40 平方厘米×5÷2）` 这种）。剥到不再变化为止才稳。
  static String _withoutNotes(String input) {
    final innermost = RegExp(r'[（(][^（()）]*[）)]');
    var result = input;
    while (true) {
      final next = result.replaceAll(innermost, '');
      if (next == result) return result;
      result = next;
    }
  }

  static String _positionOf(String knowledgePoint, String subject) {
    for (final entry in _knowledgePositions.entries) {
      if (knowledgePoint.contains(entry.key)) return entry.value;
    }
    return '${subject.isEmpty ? '本学科' : subject}对应单元的基础例题与课后练习';
  }

  static String _mnemonicOf(String knowledgePoint, int seed) {
    for (final entry in _mnemonics.entries) {
      if (knowledgePoint.contains(entry.key)) return entry.value;
    }
    return _genericMnemonics[seed % _genericMnemonics.length];
  }

  static String _stripPeriod(String input) =>
      input.endsWith('。') ? input.substring(0, input.length - 1) : input;

  static const Map<String, List<String>> _knowledgePoints = {
    '语文': ['词语理解', '句子赏析', '阅读理解层次', '作文结构', '古诗默写'],
    '数学': ['分数计算', '应用题列式', '几何图形面积', '单位换算', '竖式进位'],
    '英语': ['单词拼写', '时态选择', '句型转换', '阅读理解', '听力细节'],
    '物理': ['受力分析', '速度计算', '电路分析', '密度计算'],
    '化学': ['化学方程式配平', '化合价', '实验现象', '溶液浓度'],
    '科学': ['观察记录完整性', '实验步骤', '结论推导'],
  };

  static const List<String> _defaultKnowledgePoints = ['基础知识', '审题', '解题步骤'];

  static const List<String> _originalAnswers = [
    '步骤跳步，缺少中间过程。',
    '结论正确但依据不充分。',
    '答案与题干的取值范围不符。',
    '书写不规范，部分字迹难以辨认。',
    '只写了结果，没有写单位或标注。',
  ];

  static const List<String> _wrongReasons = [
    '对题目条件的理解出现偏差，建议重新圈画关键词。',
    '方法选择正确，但计算过程有疏漏。',
    '缺少必要的推理依据，需要补充说明。',
    '概念混淆，建议回看课本对应定义。',
    '格式不规范，容易被判为不完整。',
  ];

  static const List<String> _praiseComments = [
    '步骤写得很完整，保持这个习惯。',
    '这次没有跳步，说明方法已经稳了。',
    '比上一次清晰很多，方法选对了。',
    '审题抓住了关键词，这就是上次错的地方。',
  ];

  static const List<String> _retryHints = [
    '再读一遍题目条件，注意取值范围和单位。',
    '把中间步骤写出来，不要直接跳到结果。',
    '回看课本对应例题，对照它的第一步怎么起手。',
    '先确认题干在问什么，再选方法 —— 上次就错在这一步。',
  ];

  static const Map<String, String> _knowledgePositions = {
    '分数': '中高年级下册 · 分数的意义与基本性质',
    '应用': '中高年级 · 解决问题（列式与数量关系）',
    '几何': '中高年级下册 · 图形的面积与周长',
    '单位换算': '中高年级 · 常用量的计量与换算',
    '竖式': '中年级上册 · 乘除法的笔算',
    '词语': '语文 · 词语理解与运用（字词句积累）',
    '句子': '语文 · 句子赏析（修辞与表达效果）',
    '阅读': '语文 · 阅读理解（层次划分与要点概括）',
    '作文': '语文 · 习作（结构与详略安排）',
    '古诗': '语文 · 古诗文默写与理解',
    '单词': '英语 · 词汇（拼读与词形变化）',
    '时态': '英语 · 动词时态与主谓一致',
    '句型': '英语 · 句型转换',
    '听力': '英语 · 听力细节捕捉',
    '受力': '物理 · 力的分析与二力平衡',
    '速度': '物理 · 速度与平均速度',
    '电路': '物理 · 串并联电路与电流规律',
    '密度': '物理 · 密度及测量',
    '方程式': '化学 · 化学方程式与配平',
    '化合价': '化学 · 化合价与化学式',
    '实验': '化学 · 实验现象与操作',
    '溶液': '化学 · 溶液与溶质质量分数',
  };

  static const Map<String, String> _mnemonics = {
    '分数': '先通分，再比较；分母相同看分子，分子相同看分母。',
    '应用': '先找「一份是多少」，再算「有几份」。',
    '几何': '面积先想公式，再看单位是不是同一套。',
    '单位换算': '大化小乘、小化大除，先写进率再动手。',
    '竖式': '进位先记小字，加的时候别忘加回来。',
    '词语': '词不离句 —— 意思要放回句子里才算对。',
    '句子': '先看修辞，再说效果，最后落回情感。',
    '阅读': '一段一句话，段意串起来就是全文。',
    '作文': '开头点题，中间分点，结尾回扣。',
    '古诗': '上下句成对背，先记画面再记字。',
    '单词': '按音节切分记忆，读准了才写得对。',
    '时态': '先看时间词，再定动词形式。',
    '句型': '改句型先找助动词，主语和语序跟着动。',
    '听力': '听前划关键词，听到数字和否定词立刻记。',
    '受力': '先找施力物体，再判方向，最后看平衡。',
    '速度': '先统一单位，再代入公式。',
    '电路': '串联一条路，并联分岔口。',
    '密度': '质量除体积，单位别写混。',
    '方程式': '先配平，再标条件，最后检查原子个数。',
    '化合价': '正负总和为零，先定已知再求未知。',
    '实验': '现象说清颜色、状态、气味三件事。',
    '溶液': '溶质质量除以溶液质量，不是溶剂。',
  };

  static const List<String> _genericMnemonics = [
    '先审题、再动笔、后验算 —— 三步一步都别省。',
    '把过程写出来，分数就写出来了。',
    '同类题做三遍，比刷十道新题有用。',
  ];

  static const List<String> _pitfallBank = [
    '只看结果对不对，不检查过程是否完整，容易被判为不完整而丢分。',
    '把「大约」「至少」这类限定词当装饰，忽略了它直接决定取值范围。',
    '单位没有统一就开始计算，结果数值对、答案仍然算错。',
    '中间步骤跳步，一旦前面错一处，后面全部作废。',
    '凭印象套用上一个相似题的方法，没有确认本题的条件是否一致。',
    '答案算出来就交卷，没有回代检验，错在了本可以自己发现的地方。',
  ];

  static const Map<String, List<Map<String, dynamic>>> _subjectTemplates = {
    '数学': [
      {
        'title': '分数比较',
        'content': '比较大小：5/6 和 7/8',
        'answer': '5/6 < 7/8（通分后 20/24 < 21/24）',
      },
      {
        'title': '分数运算',
        'content': '计算：2/3 + 1/4 = ?',
        'answer': '11/12（通分后 8/12 + 3/12）',
      },
      {
        'title': '小数与分数互化',
        'content': '将 0.625 化为最简分数',
        'answer': '5/8（0.625 = 625/1000 = 5/8）',
      },
      {
        'title': '应用题列式',
        'content': '一本书 240 页，小明第一天看了全书的 1/4，第二天看了余下的 1/3，还剩多少页？',
        'answer': '120 页（第一天 60 页，余 180 页，第二天 60 页，剩 120 页）',
      },
      {
        'title': '几何面积',
        'content': '一个梯形上底 6cm、下底 10cm、高 5cm，求它的面积。',
        'answer': '40 平方厘米（(6+10)×5÷2）',
      },
      {
        'title': '单位换算',
        'content': '3.5 米 = ? 厘米；2 小时 15 分 = ? 分',
        'answer': '350 厘米；135 分',
      },
      {
        'title': '竖式进位',
        'content': '计算：48 × 27 = ?',
        'answer': '1296（注意 4×7 与 8×2 的进位）',
      },
    ],
    '语文': [
      {
        'title': '病句修改',
        'content': '修改病句：通过这次活动，使我明白了团结的重要性。',
        'answer': '删去「通过」或「使」：这次活动使我明白了团结的重要性。',
      },
      {
        'title': '古诗默写',
        'content': '补充诗句：海内存知己，____。',
        'answer': '天涯若比邻（王勃《送杜少府之任蜀州》）',
      },
      {
        'title': '阅读理解',
        'content': '概括短文《春》中「春雨图」的主要特点。',
        'answer': '细密、轻盈、润物无声，营造静谧温馨的氛围。',
      },
      {
        'title': '词语辨析',
        'content': '选词填空：他的建议非常（    ），大家都同意。（A. 诚恳  B. 中肯）',
        'answer': 'B 中肯（强调切中要害，与「大家都同意」呼应）',
      },
      {
        'title': '句子赏析',
        'content': '赏析：山朗润起来了，水涨起来了，太阳的脸红起来了。',
        'answer': '运用拟人和排比，从山、水、太阳三个角度写出春回大地的生机。',
      },
      {
        'title': '作文结构',
        'content': '以「难忘的一件事」为题，写出你的三个分论点（详略安排）。',
        'answer': '起因略写，经过详写（重点写一个细节），结果略写并回扣题目。',
      },
    ],
    '英语': [
      {
        'title': '单词拼写',
        'content': '根据中文写单词：环境 / 周围',
        'answer': 'environment',
      },
      {
        'title': '选词填空',
        'content': 'She ___ (go) to school every day.',
        'answer': 'goes（第三人称单数）',
      },
      {
        'title': '句型转换',
        'content': '改为一般疑问句：He likes apples.',
        'answer': 'Does he like apples?',
      },
      {
        'title': '时态选择',
        'content': 'Look! The children ___ (play) football on the playground.',
        'answer': 'are playing（Look! 提示现在进行时）',
      },
      {
        'title': '词形变化',
        'content': '写出 healthy 的名词形式，并用它造一个句子。',
        'answer': 'health。如：Good health is more important than money.',
      },
      {
        'title': '阅读理解',
        'content': 'Read: Tom gets up at six, runs for twenty minutes, then has breakfast. 问：How long does Tom run?',
        'answer': 'Twenty minutes.',
      },
    ],
    '物理': [
      {
        'title': '受力分析',
        'content': '静止在水平桌面上的书本受到哪些力？',
        'answer': '重力和桌面的支持力，二力平衡。',
      },
      {
        'title': '速度计算',
        'content': '一物体 5 秒内运动了 25 米，求平均速度。',
        'answer': 'v = s/t = 25/5 = 5 m/s',
      },
      {
        'title': '电路分析',
        'content': '串联电路中电流处处相等，对吗？为什么？',
        'answer': '对。串联只有一条电流路径，电荷不会在某处积累。',
      },
      {
        'title': '密度计算',
        'content': '质量 270g 的铝块体积 100cm³，求密度（ρ铝 = 2.7 g/cm³）。',
        'answer': 'ρ = m/V = 270/100 = 2.7 g/cm³，与该金属密度相符。',
      },
      {
        'title': '单位换算',
        'content': '72 km/h 等于多少 m/s？',
        'answer': '20 m/s（除以 3.6）',
      },
    ],
    '化学': [
      {
        'title': '化学方程式',
        'content': '配平：Fe + O₂ → Fe₃O₄',
        'answer': '3Fe + 2O₂ →（点燃）Fe₃O₄',
      },
      {
        'title': '化合价',
        'content': '求 KMnO₄ 中 Mn 的化合价。',
        'answer': '+7（+1 + x + 4×(-2) = 0，x = +7）',
      },
      {
        'title': '实验现象',
        'content': '铁丝在氧气中燃烧的现象是什么？',
        'answer': '剧烈燃烧，火星四射，放出大量热，生成黑色固体。',
      },
      {
        'title': '溶液浓度',
        'content': '20g 食盐溶于 80g 水中，溶质质量分数是多少？',
        'answer': '20%（20 ÷ (20+80) × 100%）',
      },
      {
        'title': '化学式书写',
        'content': '写出硫酸铝的化学式。',
        'answer': 'Al₂(SO₄)₃（Al 为 +3，SO₄ 为 -2）',
      },
    ],
  };

  static const Map<String, List<Map<String, dynamic>>> _knowledgeTemplates = {
    '分数计算': [
      {
        'title': '通分比较',
        'content': '比较大小：4/9 和 5/12',
        'answer': '4/9 > 5/12（通分后 16/36 > 15/36）',
      },
    ],
    '竖式进位': [
      {
        'title': '连续进位',
        'content': '计算：376 × 48 = ?',
        'answer': '18048（注意每一步的进位都要加上）',
      },
    ],
    '单词拼写': [
      {
        'title': '按音节拼写',
        'content': '根据音标写单词：/ˈdɪfɪkəlt/',
        'answer': 'difficult',
      },
    ],
    '时态选择': [
      {
        'title': '时间词定式',
        'content': 'He ___ (finish) his homework an hour ago.',
        'answer': 'finished（an hour ago 提示一般过去时）',
      },
    ],
    '阅读理解层次': [
      {
        'title': '层次划分',
        'content': '给下面这段话划分层次并概括每层意思：先提出观点，再举两个例子，最后总结。',
        'answer': '三层：观点 / 例证 / 总结，概括时每层用一句话。',
      },
    ],
  };
}
