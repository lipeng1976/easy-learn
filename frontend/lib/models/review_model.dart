/// 复习模块领域模型。
///
/// 设计基线见 `doc/复习模块设计.md`：**一个池、三条路、一个出口**。
/// - 一个池：错题库（[ReviewMistake]），每道题是一条有生命周期与证据链的档案；
/// - 三条路：纸质卷（[ReviewPaper] + [ReviewPaperItem]）、讲解（[MistakeExplanation]）、
///   举一反三（[AiPracticeQuestion]）；
/// - 一个出口：通过检查即毕业移出待复习池。
///
/// 三条路的判定结果统一写入 [ReviewAttempt]，因此「打印做题」和「AI 出题」在数据上等价，
/// 毕业判定只看证据、不看走了哪条路，闭环不会分裂成两套逻辑。
library;

import 'dart:convert';

import 'practice_figure.dart';

/// 错题生命周期状态。
///
/// 相比最初的 `pending / mastered` 两态，这里补上了中间态：
/// 不加中间态就无法回答「这道题是印在卷子上了，还是做完等批改」，
/// 组卷也就无法避免把同一道题重复塞进两份卷子。
enum ReviewState {
  /// 待复习：在池中，可被组卷选中。
  pending,

  /// 复习中：已入卷且资料已导出，等待线下完成。
  reviewing,

  /// 待批改：已回传，等待判定。
  verifying,

  /// 已掌握：已毕业，移出待复习池，保留在「已掌握档案」中供回溯。
  mastered,
}

extension ReviewStateLabel on ReviewState {
  String get label => switch (this) {
    ReviewState.pending => '待复习',
    ReviewState.reviewing => '复习中',
    ReviewState.verifying => '待批改',
    ReviewState.mastered => '已掌握',
  };

  /// 是否仍在「待复习池」里（已掌握的题不再出现在池中）。
  bool get inPool => this != ReviewState.mastered;
}

/// 复习资料（试卷）的生命周期。
enum PaperStatus {
  /// 已组卷、尚未导出打印。
  draft,

  /// 已导出/打印，等待学生线下完成。
  printed,

  /// 学生已回传，等待批改。
  submitted,

  /// 已批改（有结果）。
  graded,

  /// 已归档。
  closed,
}

extension PaperStatusLabel on PaperStatus {
  String get label => switch (this) {
    PaperStatus.draft => '待导出',
    PaperStatus.printed => '待作答',
    PaperStatus.submitted => '待批改',
    PaperStatus.graded => '已批改',
    PaperStatus.closed => '已归档',
  };
}

/// 卷内单题的批改结果。
enum PaperItemResult { pending, correct, wrong }

/// 作答证据的来源渠道。
enum AttemptChannel {
  /// 纸质卷 + AI 判定（学生录入了答案，由 AI 比对参考答案）。
  paper,

  /// 纸质卷 + 学生自评（学生只标记对错，未录入答案）。
  paperSelf,

  /// 举一反三练习。
  practice,
}

extension AttemptChannelLabel on AttemptChannel {
  String get label => switch (this) {
    AttemptChannel.paper => '纸质卷 · AI 判定',
    AttemptChannel.paperSelf => '纸质卷 · 自评',
    AttemptChannel.practice => '举一反三练习',
  };
}

/// 举一反三单题状态。
enum PracticeState { pending, correct, wrong }

/// 变式题的题型。
///
/// 词只在这里定义一次，网关契约里的 `type` 取值与它**逐字对应**
/// （`choice` / `fill` / `judge` / `solution`）。
///
/// 为什么要有题型：选择题与判断题的答案**可以被确定地比对**，
/// 不需要模型判一遍。这不只是省钱 —— 模型判选择题时会有概率性波动，
/// 同一个答案两次得到不同结论，学生完全无法理解。
///
/// 老数据没有这个字段，一律按 [solution] 处理：那是加题型之前唯一的形态
/// （文字作答 + 拍照识别 + 模型判定），按它走与以前完全一致。
enum PracticeQuestionType {
  /// 选择题：四个选项，答案存字母 `A`–`D`。
  choice,

  /// 填空题：短答，走模型判定。
  fill,

  /// 判断题：答案归一成「正确 / 错误」，本地比对。
  judge,

  /// 解答题：文字或拍照作答，走模型判定。
  solution;

  /// 是否能**完全本地**判定。
  ///
  /// `fill` 看起来也能字符串比对，但填空的正确答案常有多种等价写法
  /// （`1/2` 与 `0.5`、`x=2` 与 `2`），硬比对会把做对的判成错的 ——
  /// 那比多花一次模型调用糟得多。所以只有答案集合封闭的两种才本地判。
  bool get isLocallyGradable =>
      this == PracticeQuestionType.choice || this == PracticeQuestionType.judge;

  String get label => switch (this) {
    PracticeQuestionType.choice => '选择',
    PracticeQuestionType.fill => '填空',
    PracticeQuestionType.judge => '判断',
    PracticeQuestionType.solution => '解答',
  };

  /// 解析模型返回的 `type`。
  ///
  /// 不认识的取值回落到 [solution]（而不是报错让整组作废）：
  /// 一道题的类型没读懂，其余三道仍然是可做的题；整组退掉才是真的损失。
  /// 但回落之后**必须仍然能作答** —— `solution` 就是最宽松的那条路。
  static PracticeQuestionType parse(String? raw) {
    final value = (raw ?? '').trim().toLowerCase();
    for (final type in PracticeQuestionType.values) {
      if (type.name == value) return type;
    }
    return switch (value) {
      '选择' || '选择题' || 'single_choice' || 'single' => choice,
      '填空' || '填空题' || 'blank' => fill,
      '判断' || '判断题' || 'true_false' => judge,
      '解答' || '解答题' || 'answer' => solution,
      _ => solution,
    };
  }
}

/// 讲解渠道。
enum ExplainChannel { ai, self }

/// 总结报告的范围。
enum SummaryScope { paper, week, month }

/// 错题的来源。
///
/// 词只在这里定义一次：作业批改、扫描录入、手工录入、老师口述。
/// 家长端据此区分「系统批出来的」与「孩子自己记下来的」——两者的可信度
/// 本来就不一样，混成一个「手工录入」会让这个区分永久丢失。
enum MistakeSource {
  /// 由作业批改产出（`homeworkId` 非空）。
  homework,

  /// 拍试卷/作业后由 AI 提取。
  scan,

  /// 纯文字手工录入。
  manual,

  /// 老师口头布置或课堂记录。
  teacher,

  /// 「计划」里每日打卡做错的题。
  ///
  /// 与 [homework] 分开：它不是作业批改的产物，没有 `homeworkId`，
  /// 也不该出现在「某份作业产生了哪些错题」里。但它是**复习的正式来源** ——
  /// 计划负责按教材/家长范围做碎片练习，做错的题就是复习要啃的原料。
  checkin,

  /// 考试卷错题，由家长在 ima 里整理成 MD 后从家长端「复习」页导入。
  ///
  /// 与 [homework] / [checkin] 都不是一回事：没有 `homeworkId`，也不是
  /// 每日练习做错的，而是**一张已经考完的卷子**上的错题。服务端用
  /// `source_type='ima_exam'` + `source_ref=mediaId` 做幂等（同一份 MD
  /// 重导会整体替换，撤销也只删这一份）。
  imaExam,
}

extension MistakeSourceLabel on MistakeSource {
  String get label => switch (this) {
    MistakeSource.homework => '作业批改',
    MistakeSource.scan => '拍照录入',
    MistakeSource.manual => '手工录入',
    MistakeSource.teacher => '老师布置',
    MistakeSource.checkin => '每日打卡',
    MistakeSource.imaExam => '试卷导入',
  };
}

/// 落库 / 上行协议用的取值（**唯一一处**）。
///
/// ⚠️ 不能直接用 `name`：服务端写的是下划线的 `ima_exam`，Dart 枚举名是
/// `imaExam`。上行若发 `imaExam`，服务端导入时的幂等删除
/// （`source_type='ima_exam'`）就漏掉这一行 —— 家长只是改了个错因，
/// 重新导入同一份试卷就会多出一整套题，而且**不报错**。
String mistakeSourceWire(MistakeSource source) =>
    source == MistakeSource.imaExam ? 'ima_exam' : source.name;

/// 把库里的字符串解析成 [MistakeSource]。
///
/// 两种写法都认：Dart 枚举名（本地 sqflite 存的是它）与服务端 / 历史数据的
/// 下划线 wire 名。只认其中一种，就会出现「本机看是试卷导入、云端看是手工录入」。
///
/// 老数据没有这一列：`homeworkId` 非空说明来自作业批改，否则只能算手工录入。
/// **不要默认成 homework** —— 那会让家长以为一条随手记的题是系统批出来的。
MistakeSource mistakeSourceOf(String? raw, {String homeworkId = ''}) {
  final value = (raw ?? '').trim();
  if (value.isNotEmpty) {
    for (final source in MistakeSource.values) {
      if (source.name == value || mistakeSourceWire(source) == value) {
        return source;
      }
    }
  }
  return homeworkId.isEmpty ? MistakeSource.manual : MistakeSource.homework;
}

/// 错题库条目。
///
/// 除了「这题错了」，还记录**错了几次、错在哪个知识点、来自哪份作业**——
/// 这三项是组卷选题、薄弱知识点画像与出题难度的全部依据。
/// 没有它们，"薄弱"就只能靠人肉回忆。
class ReviewMistake {
  final String id;
  final String subject;

  /// **短标题**，用于列表与卷面展示（如「一元二次方程 · 第 3 题」）。
  ///
  /// ⚠️ 它不是题目原文。题目原文在 [questionBody]。
  /// 曾经讲解接口把 title 当题干发给模型，模型拿到的是一句标签，
  /// 于是讲不具体——这是「讲解不准」最根本的一层原因。
  final String title;

  /// 题目原文（可含 `$...$` 包裹的 LaTeX）。
  ///
  /// 为空表示这条错题没留下题干（历史数据、或批改时没识别出来）。
  /// 所有 AI 用题的取值顺序固定为：`questionBody` → `title`。
  final String questionBody;

  /// 这道题在**原作业卷面上的题号原文**（如 `20`、`20(4)`、`三、2`）。
  ///
  /// 空串 = 卷面本来没有题号，或批改时没认出来。
  ///
  /// ⚠️ 它只是**给人看的定位信息**：不参与判分、不参与组卷排序 ——
  /// 重做卷的题号永远是那张卷子自己的 `1..N`。加这一列的理由很具体：
  /// 家长要对着作业本找出「第 20 题」，光有知识点是找不到的。
  final String questionNo;

  /// 学生这次**写出来的解题过程**（批改时抄下来的原文，可能为空）。
  ///
  /// 用途只有一个：讲解时能指出「你这一步就错了」。
  /// 空串 = 选择题/填空题（本来没过程）、或当时没识别出来。
  final String studentProcess;

  /// 正确答案（可选）。
  ///
  /// **空串是合法值**：拿不准时不猜，比编一个答案安全。
  final String answerKey;

  /// 错题来源。见 [MistakeSource]。
  final MistakeSource sourceType;

  /// 录入时的年级快照（如「初一」）。
  ///
  /// 存快照而不是读档案：升年级后，这道题仍然要能回答「我当时几年级错的」。
  final String grade;

  /// 录入时的学期快照：`上` / `下`；空串 = 未填写。
  final String term;

  /// 关联图片数量（列表角标用，避免为每行单独查一次图片表）。
  final int imageCount;

  /// 学生原来的错误答案（留痕用，不是参考答案）。
  final String originalAnswer;
  final String wrongReason;
  final DateTime createdAt;
  final ReviewState state;
  final String studentId;

  /// 错题来源作业。AI 批改产出的错题会带上 homeworkId，
  /// 家长端即可在作业详情里列出「这份作业产生了哪些错题」。
  /// 手工录入的历史错题此字段为空。
  final String homeworkId;

  /// 知识点标签。组卷、讲解、举一反三全部按它驱动。
  final String knowledgePoint;

  /// 这道题累计做错的次数（首次入池为 1，每次回炉 +1）。
  ///
  /// 注意它统计的是**这一道题**，而不是知识点：同一知识点上的两道错题是两道
  /// 不同的题，合并成一条会让错题本丢掉真实题目内容。知识点的薄弱度由
  /// 「按知识点汇总 wrongCount」得出，见 `ParentController.visibleWeakPoints`。
  final int wrongCount;

  /// 最近一次做错的时间，配合 [wrongCount] 计算带时间衰减的薄弱度。
  final DateTime? lastWrongAt;

  /// 来源作业标题快照。作业被删后错题仍能说清「这是哪次作业错的」。
  final String sourceHomeworkTitle;

  /// 毕业时间。
  final DateTime? masteredAt;

  /// 是否由学生自评「标记掌握」而非通过检查毕业。
  /// 自评不计入掌握率，避免掌握率被「点一下就算会」污染。
  final bool masteredBySelf;

  /// 已完成的重做轮次。
  final int reviewRound;

  /// 最近一次复习时间。
  final DateTime? lastReviewedAt;

  ReviewMistake({
    required this.id,
    required this.subject,
    required this.title,
    this.questionBody = '',
    this.questionNo = '',
    this.studentProcess = '',
    this.answerKey = '',
    this.sourceType = MistakeSource.manual,
    this.grade = '',
    this.term = '',
    this.imageCount = 0,
    required this.originalAnswer,
    required this.wrongReason,
    required this.createdAt,
    required this.state,
    this.studentId = '',
    this.homeworkId = '',
    this.knowledgePoint = '',
    this.wrongCount = 1,
    this.lastWrongAt,
    this.sourceHomeworkTitle = '',
    this.masteredAt,
    this.masteredBySelf = false,
    this.reviewRound = 0,
    this.lastReviewedAt,
  });

  ReviewMistake copyWith({
    String? id,
    String? subject,
    String? title,
    String? questionBody,
    String? questionNo,
    String? studentProcess,
    String? answerKey,
    MistakeSource? sourceType,
    String? grade,
    String? term,
    int? imageCount,
    String? originalAnswer,
    String? wrongReason,
    DateTime? createdAt,
    ReviewState? state,
    String? studentId,
    String? homeworkId,
    String? knowledgePoint,
    int? wrongCount,
    DateTime? lastWrongAt,
    String? sourceHomeworkTitle,
    DateTime? masteredAt,
    bool? masteredBySelf,
    int? reviewRound,
    DateTime? lastReviewedAt,
  }) {
    return ReviewMistake(
      id: id ?? this.id,
      subject: subject ?? this.subject,
      title: title ?? this.title,
      questionBody: questionBody ?? this.questionBody,
      questionNo: questionNo ?? this.questionNo,
      studentProcess: studentProcess ?? this.studentProcess,
      answerKey: answerKey ?? this.answerKey,
      sourceType: sourceType ?? this.sourceType,
      grade: grade ?? this.grade,
      term: term ?? this.term,
      imageCount: imageCount ?? this.imageCount,
      originalAnswer: originalAnswer ?? this.originalAnswer,
      wrongReason: wrongReason ?? this.wrongReason,
      createdAt: createdAt ?? this.createdAt,
      state: state ?? this.state,
      studentId: studentId ?? this.studentId,
      homeworkId: homeworkId ?? this.homeworkId,
      knowledgePoint: knowledgePoint ?? this.knowledgePoint,
      wrongCount: wrongCount ?? this.wrongCount,
      lastWrongAt: lastWrongAt ?? this.lastWrongAt,
      sourceHomeworkTitle: sourceHomeworkTitle ?? this.sourceHomeworkTitle,
      masteredAt: masteredAt ?? this.masteredAt,
      masteredBySelf: masteredBySelf ?? this.masteredBySelf,
      reviewRound: reviewRound ?? this.reviewRound,
      lastReviewedAt: lastReviewedAt ?? this.lastReviewedAt,
    );
  }

  /// 「最新在前」——错题列表排序的**唯一口径**。
  ///
  /// 三个数据源（服务端 / 本地 sqlite / Web 内存表）各自给出的是数据库自然顺序，
  /// 谁都没写 `order by`。列表要「一眼找到刚提交的作业」，就必须在一个地方定死顺序，
  /// 否则同一批数据在三种模式下顺序不同，而界面上看不出是排序没做。
  ///
  /// ⚠️ 同一份作业批量入库的错题 `createdAt` 常常**完全相同**（同一次批改写进来的）。
  /// 没有第二关键字时，两次查询可能给出不同顺序 —— 用户看到的是「列表自己在动」。
  /// 所以用 `id` 兜底，保证全序。
  static int byNewestFirst(ReviewMistake a, ReviewMistake b) {
    final byTime = b.createdAt.compareTo(a.createdAt);
    if (byTime != 0) return byTime;
    return b.id.compareTo(a.id);
  }

  /// 带时间衰减的薄弱度：错得越多越薄弱，最近错的权重更高。
  ///
  /// 用 `wrongCount` 打底、按距今天数线性衰减（30 天归零）。
  /// 这是一个**排序信号**而非精确模型，目的是让组卷优先覆盖真正反复错的题。
  double weaknessScore(DateTime now) {
    final reference = lastWrongAt ?? createdAt;
    final days = now.difference(reference).inHours / 24.0;
    final decay = (1 - days / 30.0).clamp(0.2, 1.0);
    return wrongCount * decay;
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'subject': subject,
    'title': title,
    'questionBody': questionBody,
    'questionNo': questionNo,
    'studentProcess': studentProcess,
    'answerKey': answerKey,
    'sourceType': sourceType.name,
    'grade': grade,
    'term': term,
    'imageCount': imageCount,
    'originalAnswer': originalAnswer,
    'wrongReason': wrongReason,
    'createdAt': createdAt.toIso8601String(),
    'state': state.name,
    'studentId': studentId,
    'homeworkId': homeworkId,
    'knowledgePoint': knowledgePoint,
    'wrongCount': wrongCount,
    'lastWrongAt': lastWrongAt?.toIso8601String(),
    'sourceHomeworkTitle': sourceHomeworkTitle,
    'masteredAt': masteredAt?.toIso8601String(),
    'masteredBySelf': masteredBySelf ? 1 : 0,
    'reviewRound': reviewRound,
    'lastReviewedAt': lastReviewedAt?.toIso8601String(),
  };

  static ReviewMistake fromMap(Map<String, dynamic> row) {
    final homeworkId = (row['homeworkId'] as String?) ?? '';
    return ReviewMistake(
      id: (row['id'] as String?) ?? '',
      subject: (row['subject'] as String?) ?? '',
      title: (row['title'] as String?) ?? '',
      questionBody: (row['questionBody'] as String?) ?? '',
      questionNo: (row['questionNo'] as String?) ?? '',
      studentProcess: (row['studentProcess'] as String?) ?? '',
      answerKey: (row['answerKey'] as String?) ?? '',
      sourceType: mistakeSourceOf(
        row['sourceType'] as String?,
        homeworkId: homeworkId,
      ),
      grade: (row['grade'] as String?) ?? '',
      term: (row['term'] as String?) ?? '',
      imageCount: _asInt(row['imageCount']),
      originalAnswer: (row['originalAnswer'] as String?) ?? '',
      wrongReason: (row['wrongReason'] as String?) ?? '',
      createdAt: _parseDate(row['createdAt']) ?? DateTime.now(),
      state: ReviewState.values.firstWhere(
        (e) => e.name == row['state'],
        orElse: () => ReviewState.pending,
      ),
      studentId: (row['studentId'] as String?) ?? '',
      homeworkId: homeworkId,
      knowledgePoint: (row['knowledgePoint'] as String?) ?? '',
      wrongCount: _asInt(row['wrongCount'], fallback: 1),
      lastWrongAt: _parseDate(row['lastWrongAt']),
      sourceHomeworkTitle: (row['sourceHomeworkTitle'] as String?) ?? '',
      masteredAt: _parseDate(row['masteredAt']),
      masteredBySelf: _asInt(row['masteredBySelf']) == 1,
      reviewRound: _asInt(row['reviewRound']),
      lastReviewedAt: _parseDate(row['lastReviewedAt']),
    );
  }
}

/// 错题图片。
///
/// 与 `homework_image` **分表**：作业图片的生命周期跟着作业走（重新批改会覆盖），
/// 错题图片必须独立于作业存在——作业删了，错题还在。
class ReviewMistakeImage {
  final String id;
  final String studentId;
  final String mistakeId;
  final String storageKey;
  final String mimeType;
  final int fileSize;
  final int sortOrder;
  final DateTime? createdAt;

  const ReviewMistakeImage({
    required this.id,
    this.studentId = '',
    required this.mistakeId,
    required this.storageKey,
    this.mimeType = 'image/jpeg',
    this.fileSize = 0,
    this.sortOrder = 0,
    this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'studentId': studentId,
    'mistakeId': mistakeId,
    'storageKey': storageKey,
    'mimeType': mimeType,
    'fileSize': fileSize,
    'sortOrder': sortOrder,
    'createdAt': createdAt?.toIso8601String(),
  };

  static ReviewMistakeImage fromMap(Map<String, dynamic> row) {
    return ReviewMistakeImage(
      id: (row['id'] as String?) ?? '',
      studentId: (row['studentId'] as String?) ?? '',
      mistakeId: (row['mistakeId'] as String?) ?? '',
      storageKey: (row['storageKey'] as String?) ?? '',
      mimeType: (row['mimeType'] as String?) ?? 'image/jpeg',
      fileSize: _asInt(row['fileSize']),
      sortOrder: _asInt(row['sortOrder']),
      createdAt: _parseDate(row['createdAt']),
    );
  }
}

/// 复习资料（试卷）。
///
/// 它是把「生成资料」从一句提示语升级成**可冻结、可导出、可回传、可批改、可结算**
/// 的一等实体。每个阶段都留时间戳，形成可回溯的过程链。
class ReviewPaper {
  final String id;
  final String studentId;
  final String title;
  final String subject;

  /// 本次覆盖的知识点。
  final List<String> knowledgePoints;
  final PaperStatus status;
  final int itemCount;
  final int passCount;
  final int failCount;
  final DateTime createdAt;
  final DateTime? exportedAt;
  final DateTime? submittedAt;
  final DateTime? gradedAt;
  final DateTime? closedAt;

  /// 导出的打印页路径（Web 端为空，走浏览器打印）。
  final String filePath;
  final String note;

  ReviewPaper({
    required this.id,
    required this.studentId,
    required this.title,
    this.subject = '',
    this.knowledgePoints = const [],
    this.status = PaperStatus.draft,
    this.itemCount = 0,
    this.passCount = 0,
    this.failCount = 0,
    required this.createdAt,
    this.exportedAt,
    this.submittedAt,
    this.gradedAt,
    this.closedAt,
    this.filePath = '',
    this.note = '',
  });

  ReviewPaper copyWith({
    String? id,
    String? studentId,
    String? title,
    String? subject,
    List<String>? knowledgePoints,
    PaperStatus? status,
    int? itemCount,
    int? passCount,
    int? failCount,
    DateTime? createdAt,
    DateTime? exportedAt,
    DateTime? submittedAt,
    DateTime? gradedAt,
    DateTime? closedAt,
    String? filePath,
    String? note,
  }) {
    return ReviewPaper(
      id: id ?? this.id,
      studentId: studentId ?? this.studentId,
      title: title ?? this.title,
      subject: subject ?? this.subject,
      knowledgePoints: knowledgePoints ?? this.knowledgePoints,
      status: status ?? this.status,
      itemCount: itemCount ?? this.itemCount,
      passCount: passCount ?? this.passCount,
      failCount: failCount ?? this.failCount,
      createdAt: createdAt ?? this.createdAt,
      exportedAt: exportedAt ?? this.exportedAt,
      submittedAt: submittedAt ?? this.submittedAt,
      gradedAt: gradedAt ?? this.gradedAt,
      closedAt: closedAt ?? this.closedAt,
      filePath: filePath ?? this.filePath,
      note: note ?? this.note,
    );
  }

  double get passRate => itemCount == 0 ? 0 : passCount / itemCount;

  Map<String, dynamic> toMap() => {
    'id': id,
    'studentId': studentId,
    'title': title,
    'subject': subject,
    'knowledgePoints': knowledgePoints.join(','),
    'status': status.name,
    'itemCount': itemCount,
    'passCount': passCount,
    'failCount': failCount,
    'createdAt': createdAt.toIso8601String(),
    'exportedAt': exportedAt?.toIso8601String(),
    'submittedAt': submittedAt?.toIso8601String(),
    'gradedAt': gradedAt?.toIso8601String(),
    'closedAt': closedAt?.toIso8601String(),
    'filePath': filePath,
    'note': note,
  };

  static ReviewPaper fromMap(Map<String, dynamic> row) {
    return ReviewPaper(
      id: (row['id'] as String?) ?? '',
      studentId: (row['studentId'] as String?) ?? '',
      title: (row['title'] as String?) ?? '',
      subject: (row['subject'] as String?) ?? '',
      knowledgePoints: ((row['knowledgePoints'] as String?) ?? '')
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      status: PaperStatus.values.firstWhere(
        (e) => e.name == row['status'],
        orElse: () => PaperStatus.draft,
      ),
      itemCount: _asInt(row['itemCount']),
      passCount: _asInt(row['passCount']),
      failCount: _asInt(row['failCount']),
      createdAt: _parseDate(row['createdAt']) ?? DateTime.now(),
      exportedAt: _parseDate(row['exportedAt']),
      submittedAt: _parseDate(row['submittedAt']),
      gradedAt: _parseDate(row['gradedAt']),
      closedAt: _parseDate(row['closedAt']),
      filePath: (row['filePath'] as String?) ?? '',
      note: (row['note'] as String?) ?? '',
    );
  }
}

/// 卷内单题——**快照**。
///
/// 题目字段在组卷时从错题复制过来，之后不再跟随原错题变化。
/// 纸质卷一旦印出去，学生手上的纸和库里的题就分叉了；
/// 若批改时实时读原错题，题目内容随时可能对不上。
/// 快照是「先打印、后完成、再检查」这条链路能成立的前提。
class ReviewPaperItem {
  final String id;
  final String paperId;
  final String mistakeId;
  final String subject;
  final String knowledgePoint;
  final String questionTitle;
  final String questionBody;
  final String originalAnswer;
  final String wrongReason;
  final String answerKey;
  final int sortOrder;
  final String studentAnswer;
  final PaperItemResult result;
  final String photoPath;
  final String comment;
  final DateTime? checkedAt;

  /// 旧卷子的题干里拼过这一行（2026-10-21 之前）。
  ///
  /// 那时组卷会把「上次的答案 / 上次的错因」写进 `questionBody`，而现在改成
  /// 由渲染层从 [originalAnswer] / [wrongReason] 单独排。历史卷子的题干是**快照**，
  /// 不会被重写 —— 渲染时必须认出这种老格式，否则同一段提示会被印两遍。
  static const String legacyAnswerPrefix = '上次的答案：';

  bool get hasLegacyHints => questionBody.contains(legacyAnswerPrefix);

  ReviewPaperItem({
    required this.id,
    required this.paperId,
    required this.mistakeId,
    this.subject = '',
    this.knowledgePoint = '',
    required this.questionTitle,
    this.questionBody = '',
    this.originalAnswer = '',
    this.wrongReason = '',
    this.answerKey = '',
    this.sortOrder = 0,
    this.studentAnswer = '',
    this.result = PaperItemResult.pending,
    this.photoPath = '',
    this.comment = '',
    this.checkedAt,
  });

  ReviewPaperItem copyWith({
    String? id,
    String? paperId,
    String? mistakeId,
    String? subject,
    String? knowledgePoint,
    String? questionTitle,
    String? questionBody,
    String? originalAnswer,
    String? wrongReason,
    String? answerKey,
    int? sortOrder,
    String? studentAnswer,
    PaperItemResult? result,
    String? photoPath,
    String? comment,
    DateTime? checkedAt,
  }) {
    return ReviewPaperItem(
      id: id ?? this.id,
      paperId: paperId ?? this.paperId,
      mistakeId: mistakeId ?? this.mistakeId,
      subject: subject ?? this.subject,
      knowledgePoint: knowledgePoint ?? this.knowledgePoint,
      questionTitle: questionTitle ?? this.questionTitle,
      questionBody: questionBody ?? this.questionBody,
      originalAnswer: originalAnswer ?? this.originalAnswer,
      wrongReason: wrongReason ?? this.wrongReason,
      answerKey: answerKey ?? this.answerKey,
      sortOrder: sortOrder ?? this.sortOrder,
      studentAnswer: studentAnswer ?? this.studentAnswer,
      result: result ?? this.result,
      photoPath: photoPath ?? this.photoPath,
      comment: comment ?? this.comment,
      checkedAt: checkedAt ?? this.checkedAt,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'paperId': paperId,
    'mistakeId': mistakeId,
    'subject': subject,
    'knowledgePoint': knowledgePoint,
    'questionTitle': questionTitle,
    'questionBody': questionBody,
    'originalAnswer': originalAnswer,
    'wrongReason': wrongReason,
    'answerKey': answerKey,
    'sortOrder': sortOrder,
    'studentAnswer': studentAnswer,
    'result': result.name,
    'photoPath': photoPath,
    'comment': comment,
    'checkedAt': checkedAt?.toIso8601String(),
  };

  static ReviewPaperItem fromMap(Map<String, dynamic> row) {
    return ReviewPaperItem(
      id: (row['id'] as String?) ?? '',
      paperId: (row['paperId'] as String?) ?? '',
      mistakeId: (row['mistakeId'] as String?) ?? '',
      subject: (row['subject'] as String?) ?? '',
      knowledgePoint: (row['knowledgePoint'] as String?) ?? '',
      questionTitle: (row['questionTitle'] as String?) ?? '',
      questionBody: (row['questionBody'] as String?) ?? '',
      originalAnswer: (row['originalAnswer'] as String?) ?? '',
      wrongReason: (row['wrongReason'] as String?) ?? '',
      answerKey: (row['answerKey'] as String?) ?? '',
      sortOrder: _asInt(row['sortOrder']),
      studentAnswer: (row['studentAnswer'] as String?) ?? '',
      result: PaperItemResult.values.firstWhere(
        (e) => e.name == row['result'],
        orElse: () => PaperItemResult.pending,
      ),
      photoPath: (row['photoPath'] as String?) ?? '',
      comment: (row['comment'] as String?) ?? '',
      checkedAt: _parseDate(row['checkedAt']),
    );
  }
}

/// 作答证据——**毕业判定的唯一依据**。
///
/// 三条路（纸质卷 / 自评 / 练习）的每一次作答都写在这里。
/// 掌握数不再靠「取列表第一条」累加，而是按 paperId / mistakeId 聚合查询得出。
class ReviewAttempt {
  final String id;
  final String studentId;
  final String mistakeId;
  final String paperId;
  final String itemId;
  final AttemptChannel channel;
  final int round;
  final String answer;
  final bool correct;
  final int score;
  final String comment;
  final DateTime createdAt;

  ReviewAttempt({
    required this.id,
    required this.studentId,
    required this.mistakeId,
    this.paperId = '',
    this.itemId = '',
    required this.channel,
    this.round = 1,
    this.answer = '',
    required this.correct,
    this.score = 0,
    this.comment = '',
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'studentId': studentId,
    'mistakeId': mistakeId,
    'paperId': paperId,
    'itemId': itemId,
    'channel': channel.name,
    'round': round,
    'answer': answer,
    'correct': correct ? 1 : 0,
    'score': score,
    'comment': comment,
    'createdAt': createdAt.toIso8601String(),
  };

  static ReviewAttempt fromMap(Map<String, dynamic> row) {
    return ReviewAttempt(
      id: (row['id'] as String?) ?? '',
      studentId: (row['studentId'] as String?) ?? '',
      mistakeId: (row['mistakeId'] as String?) ?? '',
      paperId: (row['paperId'] as String?) ?? '',
      itemId: (row['itemId'] as String?) ?? '',
      channel: AttemptChannel.values.firstWhere(
        (e) => e.name == row['channel'],
        orElse: () => AttemptChannel.paper,
      ),
      round: _asInt(row['round']),
      answer: (row['answer'] as String?) ?? '',
      correct: _asInt(row['correct']) == 1,
      score: _asInt(row['score']),
      comment: (row['comment'] as String?) ?? '',
      createdAt: _parseDate(row['createdAt']) ?? DateTime.now(),
    );
  }
}

/// 举一反三题目（落库）。
///
/// 相比原先只存内存的 `SimilarQuestion`，落库的意义在于：
/// 练完能作为**毕业证据**被追溯，而不是做完即丢、下次重来。
class AiPracticeQuestion {
  final String id;
  final String studentId;
  final String sourceMistakeId;
  final String knowledgePoint;
  final String subject;
  final String title;
  final String content;
  final String answer;
  final String difficulty;
  final String studentAnswer;
  final PracticeState state;
  final int round;
  final DateTime createdAt;
  final DateTime? checkedAt;

  /// 题型。老数据没有这一列，按 [PracticeQuestionType.solution] 处理。
  final PracticeQuestionType questionType;

  /// 选择题的四个选项（**不含 `A.` 前缀**，前缀由界面按序号渲染）。
  ///
  /// 只存选项文本、答案只存字母，是为了让判定变成一次字符串相等：
  /// 如果选项里带着 `A.`、答案也带 `A.`，前缀格式一漂（模型有时写
  /// `A、`、有时写 `A.`）判定就会静默失效 —— 那正是最难查的一类错。
  final List<String> options;

  /// 配图（点、线、标注的结构化描述）。为空表示这道题不需要图。
  ///
  /// 必须落库：不落的话，退出错题详情再进来图就没了 ——
  /// 而「重新打开图不见了」正是最难归因的那类症状（页面看着正常，
  /// 只是少了一块）。JSON 文本存在 `figureJson` 列里，与 `options` 同样处理。
  final PracticeFigure? figure;

  AiPracticeQuestion({
    required this.id,
    this.studentId = '',
    required this.sourceMistakeId,
    this.knowledgePoint = '',
    required this.subject,
    required this.title,
    required this.content,
    required this.answer,
    this.difficulty = '基础',
    this.studentAnswer = '',
    this.state = PracticeState.pending,
    this.round = 1,
    required this.createdAt,
    this.checkedAt,
    this.questionType = PracticeQuestionType.solution,
    this.options = const [],
    this.figure,
  });

  AiPracticeQuestion copyWith({
    String? id,
    String? studentId,
    String? sourceMistakeId,
    String? knowledgePoint,
    String? subject,
    String? title,
    String? content,
    String? answer,
    String? difficulty,
    String? studentAnswer,
    PracticeState? state,
    int? round,
    DateTime? createdAt,
    DateTime? checkedAt,
    PracticeQuestionType? questionType,
    List<String>? options,
    PracticeFigure? figure,
  }) {
    return AiPracticeQuestion(
      id: id ?? this.id,
      studentId: studentId ?? this.studentId,
      sourceMistakeId: sourceMistakeId ?? this.sourceMistakeId,
      knowledgePoint: knowledgePoint ?? this.knowledgePoint,
      subject: subject ?? this.subject,
      title: title ?? this.title,
      content: content ?? this.content,
      answer: answer ?? this.answer,
      difficulty: difficulty ?? this.difficulty,
      studentAnswer: studentAnswer ?? this.studentAnswer,
      state: state ?? this.state,
      round: round ?? this.round,
      createdAt: createdAt ?? this.createdAt,
      checkedAt: checkedAt ?? this.checkedAt,
      questionType: questionType ?? this.questionType,
      options: options ?? this.options,
      figure: figure ?? this.figure,
    );
  }

  bool get isChoice => questionType == PracticeQuestionType.choice;
  bool get isJudge => questionType == PracticeQuestionType.judge;

  Map<String, dynamic> toMap() => {
    'id': id,
    'studentId': studentId,
    'sourceMistakeId': sourceMistakeId,
    'knowledgePoint': knowledgePoint,
    'subject': subject,
    'title': title,
    'content': content,
    'answer': answer,
    'difficulty': difficulty,
    'studentAnswer': studentAnswer,
    'state': state.name,
    'round': round,
    'createdAt': createdAt.toIso8601String(),
    'checkedAt': checkedAt?.toIso8601String(),
    // 本地库（sqflite）不接受 List 列，选项按 JSON 文本存。
    // `options` 这个键与它一一对应，读的时候也只有这一条路。
    'questionType': questionType.name,
    'optionsJson': jsonEncode(options),
    // 有图才写。空字符串与 NULL 在读侧都当作「没有图」，
    // 但写 NULL 更省空间，也让 `figureJson IS NULL` 能直接数出「有多少道题带图」。
    'figureJson': figure == null ? null : jsonEncode(figureToJson(figure!)),
  };

  static AiPracticeQuestion fromMap(Map<String, dynamic> row) {
    return AiPracticeQuestion(
      id: (row['id'] as String?) ?? '',
      studentId: (row['studentId'] as String?) ?? '',
      sourceMistakeId: (row['sourceMistakeId'] as String?) ?? '',
      knowledgePoint: (row['knowledgePoint'] as String?) ?? '',
      subject: (row['subject'] as String?) ?? '',
      title: (row['title'] as String?) ?? '',
      content: (row['content'] as String?) ?? '',
      answer: (row['answer'] as String?) ?? '',
      difficulty: (row['difficulty'] as String?) ?? '基础',
      studentAnswer: (row['studentAnswer'] as String?) ?? '',
      state: PracticeState.values.firstWhere(
        (e) => e.name == row['state'],
        orElse: () => PracticeState.pending,
      ),
      round: _asInt(row['round'], fallback: 1),
      createdAt: _parseDate(row['createdAt']) ?? DateTime.now(),
      checkedAt: _parseDate(row['checkedAt']),
      questionType: PracticeQuestionType.parse(row['questionType'] as String?),
      options: _decodeOptions(row['optionsJson']),
      figure: _decodeFigure(row['figureJson']),
    );
  }

  /// 把配图写回接口用的 JSON 形状（与服务端 DSL 一致）。
  ///
  /// 走这一个函数而不是在 [toMap] 里直接拼，是为了让「存进去的」和
  /// 「模型给的」是同一种结构 —— 否则读回来再走一遍 `PracticeFigure.parse`
  /// 就得维护第二套字段名，两套一漂就是静默丢图。
  static Map<String, dynamic> figureToJson(PracticeFigure figure) {
    return {
      'type': figure.type,
      'points': [
        for (final point in figure.points)
          {'name': point.name, 'x': point.x, 'y': point.y},
      ],
      'polygons': figure.polygons,
      'segments': figure.segments,
      'dashed': figure.dashed,
      'dims': [
        for (final dim in figure.dims)
          {
            'from': {'x': dim.from.dx, 'y': dim.from.dy},
            'to': {'x': dim.to.dx, 'y': dim.to.dy},
            'text': dim.text,
          },
      ],
      'labels': [
        for (final label in figure.labels)
          {'text': label.text, 'x': label.at.dx, 'y': label.at.dy},
      ],
      'marks': [
        for (final mark in figure.marks)
          {
            'kind': mark.kind,
            'at': {'x': mark.at.dx, 'y': mark.at.dy},
            if (mark.text.isNotEmpty) 'text': mark.text,
          },
      ],
    };
  }

  /// 读配图。
  ///
  /// 解不开就当没有图（返回 null），**不抛异常**：一条坏掉的 figure JSON
  /// 不该让整页复习打不开。宁可少一张图，也不能让错题本白屏。
  static PracticeFigure? _decodeFigure(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    try {
      return PracticeFigure.parse(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// 解开选项 JSON。
  ///
  /// 解析失败返回空列表、不抛异常：一条坏掉的选项 JSON 不该让整页
  /// 复习打不开。真正要防的是「选项没了还当成选择题展示」——
  /// 那由 `ReviewService.isUsablePractice` 在入库与展示两处拦下。
  static List<String> _decodeOptions(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.whereType<String>().toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
}

/// 讲解记录（过程留痕）。
///
/// 讲解**不构成毕业**——看懂 ≠ 会做。它的价值是降低下一次做错的概率，
/// 所以只作为过程指标：它进入错题时间线，但不改变掌握率。
class ExplainRecord {
  final String id;
  final String studentId;
  final String mistakeId;
  final String knowledgePoint;
  final ExplainChannel channel;
  final String summary;
  final int staySeconds;
  final DateTime createdAt;

  ExplainRecord({
    required this.id,
    this.studentId = '',
    required this.mistakeId,
    this.knowledgePoint = '',
    this.channel = ExplainChannel.ai,
    this.summary = '',
    this.staySeconds = 0,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'studentId': studentId,
    'mistakeId': mistakeId,
    'knowledgePoint': knowledgePoint,
    'channel': channel.name,
    'summary': summary,
    'staySeconds': staySeconds,
    'createdAt': createdAt.toIso8601String(),
  };

  static ExplainRecord fromMap(Map<String, dynamic> row) {
    return ExplainRecord(
      id: (row['id'] as String?) ?? '',
      studentId: (row['studentId'] as String?) ?? '',
      mistakeId: (row['mistakeId'] as String?) ?? '',
      knowledgePoint: (row['knowledgePoint'] as String?) ?? '',
      channel: ExplainChannel.values.firstWhere(
        (e) => e.name == row['channel'],
        orElse: () => ExplainChannel.ai,
      ),
      summary: (row['summary'] as String?) ?? '',
      staySeconds: _asInt(row['staySeconds']),
      createdAt: _parseDate(row['createdAt']) ?? DateTime.now(),
    );
  }
}

/// 总结报告。
class ReviewSummary {
  final String id;
  final String studentId;
  final SummaryScope scope;
  final String scopeKey;
  final int totalCount;
  final int passCount;
  final int masteredCount;
  final int remainCount;
  final double passRate;
  final List<String> weakPoints;
  final String body;
  final DateTime generatedAt;

  ReviewSummary({
    required this.id,
    this.studentId = '',
    required this.scope,
    required this.scopeKey,
    this.totalCount = 0,
    this.passCount = 0,
    this.masteredCount = 0,
    this.remainCount = 0,
    this.passRate = 0,
    this.weakPoints = const [],
    this.body = '',
    required this.generatedAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'studentId': studentId,
    'scope': scope.name,
    'scopeKey': scopeKey,
    'totalCount': totalCount,
    'passCount': passCount,
    'masteredCount': masteredCount,
    'remainCount': remainCount,
    'passRate': passRate,
    'weakPoints': weakPoints.join(','),
    'body': body,
    'generatedAt': generatedAt.toIso8601String(),
  };

  static ReviewSummary fromMap(Map<String, dynamic> row) {
    return ReviewSummary(
      id: (row['id'] as String?) ?? '',
      studentId: (row['studentId'] as String?) ?? '',
      scope: SummaryScope.values.firstWhere(
        (e) => e.name == row['scope'],
        orElse: () => SummaryScope.paper,
      ),
      scopeKey: (row['scopeKey'] as String?) ?? '',
      totalCount: _asInt(row['totalCount']),
      passCount: _asInt(row['passCount']),
      masteredCount: _asInt(row['masteredCount']),
      remainCount: _asInt(row['remainCount']),
      passRate: _parseDouble(row['passRate']),
      weakPoints: ((row['weakPoints'] as String?) ?? '')
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      body: (row['body'] as String?) ?? '',
      generatedAt: _parseDate(row['generatedAt']) ?? DateTime.now(),
    );
  }
}

/// AI 讲解内容（值对象，结构固定便于渲染与测试）。
class MistakeExplanation {
  /// 考点定位：知识点 + 它在教材里的位置。
  final String knowledgePoint;
  final String position;

  /// 为什么会错：针对该题错误原因的归因。
  final String whyWrong;

  /// 正确解法：分步骤。
  final List<String> steps;

  /// 易错提醒：同类陷阱。
  final List<String> pitfalls;

  /// 一句话记忆点。
  final String mnemonic;

  const MistakeExplanation({
    required this.knowledgePoint,
    required this.position,
    required this.whyWrong,
    required this.steps,
    required this.pitfalls,
    required this.mnemonic,
  });
}

/// 错题生命周期的某一件事（过程时间线用，计算得出、不落库）。
class MistakeTimelineEntry {
  final DateTime at;
  final String title;
  final String detail;
  final TimelineKind kind;

  /// 这条记录来自哪条作答渠道。只有「作答」类条目才有值。
  ///
  /// 不加这个字段时，时间线只能按 [kind] 上色，「自评通过」和「AI 判定通过」
  /// 都是绿色 —— 学生一眼看过去会以为两者等价，而这恰恰是闭环里最不能含糊的一点。
  final AttemptChannel? channel;

  const MistakeTimelineEntry({
    required this.at,
    required this.title,
    this.detail = '',
    required this.kind,
    this.channel,
  });
}

enum TimelineKind { created, explained, paperIssued, practiced, failed, mastered }

DateTime? _parseDate(Object? value) {
  if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
  return null;
}

int _asInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

double _parseDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}
