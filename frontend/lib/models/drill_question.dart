/// 每日概念训练的题型分层。
///
/// 分层的依据是「从文字到数学表达」这件事本身的难度，不是题目的计算量 ——
/// 本训练刻意不考计算，考的是**翻译**：
///  · [basic] 单步转换：「一个数的 3 倍」→ `3x`。对准「用字母表示数」；
///  · [advanced] 多步转换/列方程：「3 倍加上 10 等于 40」→ `3x+10=40`；
///  · [composite] 生活情境：相遇、年龄、图形面积——先找关系再列式。
///
/// 每天选题按 3 : 2 : 1 保底（见 `drill_selector.dart`）：基础概念不牢时，
/// 拔高题除了打击信心没有别的作用。
enum DrillTier { basic, advanced, composite }

/// 一道概念训练选择题。
///
/// ## 为什么选项是「字符串」而不是结构化表达式
///
/// 训练的目标是「看懂文字 → 写出式子」，式子必须原样呈现（含 `$...$`），
/// 孩子对照的是**写法**不是计算结果。结构化成 AST 再渲染会引入一层
/// 「渲染器觉得该怎么写」——那不是孩子该看到的东西。
class DrillQuestion {
  const DrillQuestion({
    required this.id,
    required this.pattern,
    required this.knowledge,
    required this.tier,
    required this.stem,
    required this.options,
    required this.answerIndex,
    required this.explain,
  });

  /// 稳定编号。选题的新鲜度、按句式加权都依赖它**不变**——
  /// 换 id 等于把历史记录全部作废，而界面看起来一切正常。
  final String id;

  /// 句式模板 key（如 `n-fold`、`sum-multiple`）。
  ///
  /// 同模板的题是同一类「翻译」的不同数值变体 —— 学生在一个句式上连续
  /// 出错时，加权重的是**这个句式**，不是某一道题。
  final String pattern;

  /// 对齐错题本 `knowledge_point` 的知识点（如「列方程解应用题」）。
  ///
  /// 取值刻意去对齐错题表的既有字符串：选题加权是「她错得多的知识点
  /// 多出题」，两边词不一致时加权会静默失效——加成一个永远为 0 的数，
  /// 不报错，只是「个性化」悄悄不存在了。
  final String knowledge;

  final DrillTier tier;

  /// 题干。可含 `$...$`（走 `MathText` 渲染）。
  final String stem;

  /// 4 个选项。可含 `$...$`。
  final List<String> options;

  /// 正确选项下标（0..3）。
  final int answerIndex;

  final DrillExplain explain;
}

/// 四步法解析 —— 「找主体、找数值、找关系、找目标」。
///
/// 与 `D:\学习资料\数学\初一数学逻辑转换训练手册.docx` 的家长指南一致：
/// **先填完四个空，最后才写式子**。这四个字段就是那四个空，
/// 界面按同样顺序展示，孩子在 App 里练的步骤和家里纸上练的步骤是同一套。
class DrillExplain {
  const DrillExplain({
    required this.subject,
    required this.numbers,
    required this.relation,
    required this.goal,
    required this.pitfall,
  });

  /// 找主体：谁是主角（设为 x 的那个）。
  final String subject;

  /// 找数值：题目里已知的数字。
  final String numbers;

  /// 找关系：关键词对应什么运算/等号（「比…多」→ 加，「倍」→ 乘）。
  final String relation;

  /// 找目标：最后要算什么。
  final String goal;

  /// 常见错因：错误选项错在哪（代入验算的说服力胜过「你错了」）。
  final String pitfall;
}

/// 一次作答的落库记录（`drill_answer` 表）。
///
/// ⚠️ 本记录**只在本机**（与 `knowledge_tip` 同一路线，见
/// `DatabaseService` 的「本机缓存」段）：训练是孩子一个人在手机上完成的
/// 动作，换设备重练一遍没有损失；而上云的代价是每个家庭的孩子互相读到
/// 别人的训练流水。跨设备同步与家长端可见列入后续版本。
class DrillAnswer {
  const DrillAnswer({
    required this.id,
    required this.studentId,
    required this.questionId,
    required this.pattern,
    required this.knowledge,
    required this.tier,
    required this.chosenIndex,
    required this.correct,
    required this.date,
    required this.createdAt,
  });

  final String id;
  final String studentId;

  /// 对应题库里的题（`DrillQuestion.id`）。
  final String questionId;
  final String pattern;
  final String knowledge;
  final DrillTier tier;

  /// 选了哪个选项（0..3）。提交时一定已选，-1 只会出现在构造失败的场景。
  final int chosenIndex;
  final bool correct;

  /// 训练日期 `YYYY-MM-DD`（本地时区）。
  ///
  /// 「每天一组」按这个字段判今天是否已练过 —— 用时间戳判会把
  /// 「昨晚十一点练的」算到第二天头上。
  final String date;

  final DateTime createdAt;

  Map<String, dynamic> toMap() => {
    'id': id,
    'studentId': studentId,
    'questionId': questionId,
    'pattern': pattern,
    'knowledge': knowledge,
    'tier': tier.name,
    'chosenIndex': chosenIndex,
    'correct': correct ? 1 : 0,
    'date': date,
    'createdAt': createdAt.toIso8601String(),
  };

  static DrillAnswer fromMap(Map<String, dynamic> row) {
    return DrillAnswer(
      id: (row['id'] as String?) ?? '',
      studentId: (row['studentId'] as String?) ?? '',
      questionId: (row['questionId'] as String?) ?? '',
      pattern: (row['pattern'] as String?) ?? '',
      knowledge: (row['knowledge'] as String?) ?? '',
      tier: DrillTier.values.firstWhere(
        (t) => t.name == row['tier'],
        orElse: () => DrillTier.basic,
      ),
      chosenIndex: (row['chosenIndex'] as num?)?.toInt() ?? -1,
      correct: ((row['correct'] as num?)?.toInt() ?? 0) == 1,
      date: (row['date'] as String?) ?? '',
      createdAt:
          DateTime.tryParse((row['createdAt'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
