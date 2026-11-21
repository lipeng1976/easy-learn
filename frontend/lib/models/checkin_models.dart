import '../services/checkin_question_parser.dart';

/// 出题难度。与复核/举一反三那条链路的 `difficulty` **是同一套词**
/// （`review_model.dart`、`ai_data_source.dart` 里的默认值也是「基础」）。
///
/// 不另造「简单 / 中等 / 困难」：同一个概念在档案里叫两个名字，
/// 统计时就永远对不上，而且两边都不会报错。
const List<String> kCheckinDifficulties = ['基础', '提高', '挑战'];

/// 没指定难度。空串表示「没要求」而不是「基础」——
/// 后者会让统计里凭空多出一批「基础」题，而那些题其实没人指定过。
const String kCheckinDifficultyNone = '';

/// 出题的锚点：一个知识点 + 它在错题本里的情况。
///
/// 现在它有两个来源：
///   · **服务端聚合**（`GET /data/checkin/seeds`）—— 家长挑知识点时的候选；
///   · **家长手选**（`POST /data/checkin/generate` 的 `knowledgePoints`）——
///     这时 `wrongCount` 可能是 0，表示这个知识点还没有错题记录。
///
/// ⚠️ `wrongCount == 0` 有两种意思：真的没错过，和「是家长新加的」。
/// 界面上要按「还没有错题记录」说，别显示成「错过 0 次」——
/// 后者看起来像个统计错误。
class CheckinSeed {
  const CheckinSeed({
    required this.knowledge,
    this.wrongCount = 0,
    this.wrongReason = '',
  });

  final String knowledge;
  final int wrongCount;
  final String wrongReason;

  factory CheckinSeed.fromJson(Map<String, dynamic> json) => CheckinSeed(
        knowledge: json['knowledge'] as String? ?? '',
        wrongCount: (json['wrongCount'] as num?)?.toInt() ?? 0,
        wrongReason: json['wrongReason'] as String? ?? '',
      );
}

/// 家长发起打卡时填的那份范围。
///
/// 它只是**界面到控制器**的搬运结构，不入库：真正落库的是出题结果
/// （`checkin_quiz`）。所以这里刻意没有 `studentId` —— 归属由调用方
/// 单独传，免得同一件事在两层各存一份、某天只改了一处。
class CheckinSetup {
  const CheckinSetup({
    required this.subject,
    required this.count,
    required this.knowledgePoints,
    required this.difficulty,
  });

  final String subject;
  final int count;

  /// 家长勾选 + 手输的知识点，**顺序即优先级**（最多 6 个）。
  /// 空列表 = 不出指定范围，由服务端从错题本自动挑。
  final List<String> knowledgePoints;

  /// 空串 = 不指定难度。
  final String difficulty;
}

/// 一份打卡任务（题目快照 + 状态）。
///
/// 题目复用 [CheckinQuestion]：网关返回什么、本地判分用什么、入库存什么，
/// 用的必须是**同一个模型**。分成两套的话，字段名一漂（`stem` / `question`）
/// 就会表现成「题目显示不出来但接口 200」。
class CheckinQuiz {
  const CheckinQuiz({
    required this.id,
    required this.studentId,
    required this.quizDate,
    required this.questions,
    this.subject = '',
    this.difficulty = '',
    this.status = 'pending',
    this.submittedResult,
  });

  final String id;
  final String studentId;

  /// `yyyy-MM-dd`，**本地日**（服务端不生成，见 R4）。
  final String quizDate;
  final List<CheckinQuestion> questions;
  final String subject;

  /// 家长发起时指定的难度（基础 / 提高 / 挑战）；空串 = 没要求。
  ///
  /// 它是**出题参数**，不是题目属性：事后从题目本身看不出当初要的是哪一档
  /// （同样考有理数，`(-3)+5` 是基础，`(-3)^2-5×(-2)` 就能算提高）。
  /// 所以服务端把它随打卡一起存下来，学生端的标题栏会显示它。
  final String difficulty;

  /// `pending`（还没答）/ `done`（已提交）。
  final String status;

  /// 已经交过卷时的结果（家长端打开就能看到分数，不用再答一遍）。
  ///
  /// 它是**另一个端点字段**（`GET /data/checkin/quiz` 的 `result`），
  /// 不放在 quiz 的 JSON 里 —— 所以由仓库层 `copyWith` 挂上来。
  final CheckinSubmitResult? submittedResult;

  CheckinQuiz copyWith({CheckinSubmitResult? submittedResult}) => CheckinQuiz(
        id: id,
        studentId: studentId,
        quizDate: quizDate,
        questions: questions,
        subject: subject,
        difficulty: difficulty,
        status: status,
        submittedResult: submittedResult ?? this.submittedResult,
      );

  bool get isDone => status == 'done';
  int get total => questions.length;

  factory CheckinQuiz.fromJson(Map<String, dynamic> json) {
    final raw = (json['questions'] as List?) ?? const [];
    return CheckinQuiz(
      id: json['id'] as String? ?? '',
      studentId: json['studentId'] as String? ?? '',
      quizDate: json['quizDate'] as String? ?? '',
      subject: json['subject'] as String? ?? '',
      difficulty: json['difficulty'] as String? ?? '',
      status: json['status'] as String? ?? 'pending',
      questions: [
        for (final item in raw)
          if (item is Map)
            CheckinQuestion(
              stem: item['stem'] as String? ?? '',
              options: [
                for (final option in (item['options'] as List? ?? const []))
                  option.toString(),
              ],
              answer: (item['answer'] as String? ?? '').toUpperCase(),
              knowledge: item['knowledge'] as String? ?? '',
              analysis: item['analysis'] as String?,
              type: item['type'] == 'judge'
                  ? CheckinQuestionType.judge
                  : CheckinQuestionType.choice,
            ),
      ],
    );
  }

  /// 写回服务端时只送题目本身 —— id / 日期 / 归属由调用方显式给出，
  /// 免得两份真相（模型里一份、请求体一份）打架。
  static List<Map<String, dynamic>> encodeQuestions(List<CheckinQuestion> list) =>
      [for (final q in list) q.toJson()];
}

/// 单题判定结果（服务端复算后回传）。
class CheckinItemResult {
  const CheckinItemResult({
    required this.index,
    required this.picked,
    required this.answer,
    required this.correct,
    this.knowledge = '',
  });

  final int index;
  final String picked;
  final String answer;
  final bool correct;
  final String knowledge;

  factory CheckinItemResult.fromJson(Map<String, dynamic> json) => CheckinItemResult(
        index: (json['index'] as num?)?.toInt() ?? 0,
        picked: json['picked'] as String? ?? '',
        answer: json['answer'] as String? ?? '',
        correct: json['correct'] == true,
        knowledge: json['knowledge'] as String? ?? '',
      );
}

/// 提交结果。
///
/// 有两种来源，字段完全一样：
///   · [CheckinSubmitResult.judge] —— 交卷那一瞬在本机算出来的（[synced] = false）；
///   · 服务端 `POST /data/checkin/submit` 回传的那份（[synced] = true）。
///
/// 页面先显示前者（立刻出分），服务端返回后换成后者（存档真值 + ima 状态）。
class CheckinSubmitResult {
  const CheckinSubmitResult({
    required this.quizId,
    required this.score,
    required this.total,
    required this.items,
    this.imaSynced = false,
    this.synced = true,
    this.mistakesAdded = 0,
    this.mistakesFailed = false,
    this.submittedAt,
  });

  final String quizId;
  final int score;
  final int total;
  final List<CheckinItemResult> items;

  /// 这份打卡做错的题里，有几道成功写进了错题本。
  ///
  /// 「计划里做错的题就是复习的原料」—— 这条链由服务端在交卷同一事务里完成，
  /// 这里只负责如实告诉孩子。`0` 且没有失败 = 全对，不需要提。
  final int mistakesAdded;

  /// 错题写进错题本失败了（028 未迁移 / 权限问题）。
  ///
  /// **成绩已经保存**，失败的只是归档；界面要单独说一句，
  /// 不能让孩子以为「做错了但复习里会自己出现」。
  final bool mistakesFailed;

  /// ima 档案是否推送成功。**false 不代表提交失败** —— 可选同步没开/失败
  /// 都不影响作答入库，界面只在需要时用它说明一句。
  final bool imaSynced;

  /// 这份结果是否已经存到服务端。
  ///
  /// `false` 只可能来自 [CheckinSubmitResult.judge]：分数已经出来了，
  /// 但还没写进库（网络断了、服务端抽风）。界面要如实说「没同步」并给重试，
  /// 不能让孩子以为成绩已经存好了。
  final bool synced;

  /// 交卷时刻（服务端 `checkin_result.submitted_at`）。
  ///
  /// 「今天完成」按它判定，而不是 `quiz.quizDate` —— 后者是**出题日**，
  /// 家长头晚出题、孩子次日才做时两者差一天（本机库里真有这种行）。
  /// `GET /data/checkin/quiz` 的 result 里已经带这个字段；提交接口不回，
  /// 交卷那一刻由控制器用本机时钟补上并保留（见 `CheckinController._store`）。
  /// 老服务端完全没给时 `checkinDoneDateKey` 退回出题日，绝不猜成「今天」——
  /// 否则所有历史记录会被一锅端进今天的框里，而且不报错。
  final DateTime? submittedAt;

  /// 本地判分：交卷那一瞬就能出结果，不等网络。
  ///
  /// 规则与服务端 `submitCheckin` 逐条对齐 —— 两边算出来必须一样，
  /// 否则孩子看到的分数和家长看到的分永远不同，而且谁都不报错：
  ///   · 答案与作答都 `trim()` + 转大写，再比字符串相等；
  ///   · 没选（空串）恒为错，不给「没选也算对」留口子；
  ///   · 题目里没有答案（脏数据）也恒为错 —— 缺答案时送分是更坏的失败。
  ///
  /// 服务端随后会按同一份题目快照复算并回传，那一刻以服务端为准。
  factory CheckinSubmitResult.judge({
    required String quizId,
    required List<CheckinQuestion> questions,
    required Map<int, String> picked,
    DateTime? submittedAt,
  }) {
    var score = 0;
    final items = <CheckinItemResult>[];
    for (var index = 0; index < questions.length; index++) {
      final answer = questions[index].answer.trim().toUpperCase();
      final mine = (picked[index] ?? '').trim().toUpperCase();
      final correct = mine.isNotEmpty && mine == answer;
      if (correct) score += 1;
      items.add(
        CheckinItemResult(
          index: index,
          picked: mine,
          answer: answer,
          correct: correct,
          knowledge: questions[index].knowledge,
        ),
      );
    }
    return CheckinSubmitResult(
      quizId: quizId,
      score: score,
      total: questions.length,
      items: items,
      synced: false,
      submittedAt: submittedAt,
    );
  }

  factory CheckinSubmitResult.fromJson(Map<String, dynamic> json) {
    final ima = json['ima'];
    final mistakes = json['mistakes'];
    return CheckinSubmitResult(
      quizId: json['quizId'] as String? ?? '',
      score: (json['score'] as num?)?.toInt() ?? 0,
      total: (json['total'] as num?)?.toInt() ?? 0,
      items: [
        for (final item in (json['items'] as List? ?? const []))
          if (item is Map) CheckinItemResult.fromJson(Map<String, dynamic>.from(item)),
      ],
      imaSynced: ima is Map && ima['synced'] == true,
      mistakesAdded: mistakes is Map ? (mistakes['added'] as num?)?.toInt() ?? 0 : 0,
      mistakesFailed: mistakes is Map && mistakes['failed'] == true,
      submittedAt: _parseDateTime(json['submittedAt']),
    );
  }

  static DateTime? _parseDateTime(Object? value) =>
      value == null ? null : DateTime.tryParse(value.toString());

  /// 换掉存档真值时保留本机那个交卷时刻（提交接口不回 `submittedAt`）。
  CheckinSubmitResult copyWith({DateTime? submittedAt}) => CheckinSubmitResult(
        quizId: quizId,
        score: score,
        total: total,
        items: items,
        imaSynced: imaSynced,
        synced: synced,
        mistakesAdded: mistakesAdded,
        mistakesFailed: mistakesFailed,
        submittedAt: submittedAt ?? this.submittedAt,
      );
}

/// 打卡列表的过滤口径。
///
/// 「做没做完」由**成绩行在不在**决定（服务端与客户端同一口径），
/// 不看 `status` 字段 —— 那个字段理论上同步，但脏数据出现时页面按成绩行渲染。
enum CheckinQuizStatus {
  all,
  pending,
  done;

  String get wire => name;
}

/// 一页打卡记录。
///
/// 为什么要 `total` 而不是「返回数 < limit 就没更多了」：
/// 最后一页恰好填满时（比如正好 20 条、每页 10）前者会说还有，后者能判对；
/// 而反过来，中间某页因为数据被删少返回几条时，后者会提前认为到底了。
/// 服务端在一次查询里把 `count` 和当页一起算好，客户端不必再猜。
class CheckinQuizPage {
  const CheckinQuizPage({
    required this.items,
    required this.total,
    required this.hasMore,
  });

  final List<CheckinQuiz> items;

  /// 满足过滤条件的**总条数**（不是本页条数）。
  final int total;

  /// 还有下一页。
  final bool hasMore;

  static const empty = CheckinQuizPage(items: [], total: 0, hasMore: false);
}

/// 一科的「已完成」汇总（学生端已完成区的科目色块用）。
///
/// ## 为什么是一个专门的模型，而不是数 `doneRuns`
///
/// `doneRuns` 只是**当前加载的那一页**（10 条）。用它数出来的「数学 7 份」
/// 在翻页前永远是错的，而且没有任何报错 —— 这正是这个仓库里最典型的一类
/// 静默失败。数字必须来自服务端 `GET /data/checkin/summary` 的 `group by`。
///
/// ## `lastScore == null` 与 0 分是两件事
///
/// 0 分 = 做过且全错；null = 没有这份数据。混成 0 会让色块上写着
/// 「最近 0/5」，家长以为孩子交了白卷。
class CheckinSubjectSummary {
  const CheckinSubjectSummary({
    required this.subject,
    required this.done,
    this.lastSubmittedAt,
    this.lastScore,
    this.lastTotal,
  });

  final String subject;

  /// 这一科**已交卷**的份数。
  final int done;

  final DateTime? lastSubmittedAt;
  final int? lastScore;
  final int? lastTotal;

  /// 有成绩时给「最近 4/5」，否则给不出 —— 不要编一个 0/0。
  String? get lastScoreLabel =>
      lastScore == null || lastTotal == null ? null : '最近 $lastScore/$lastTotal';

  factory CheckinSubjectSummary.fromJson(Map<String, dynamic> json) {
    final at = json['lastSubmittedAt'];
    return CheckinSubjectSummary(
      subject: (json['subject'] ?? '').toString().isEmpty
          ? '其他'
          : json['subject'].toString(),
      done: (json['done'] as num?)?.toInt() ?? 0,
      lastSubmittedAt: at == null ? null : DateTime.tryParse(at.toString()),
      lastScore: (json['lastScore'] as num?)?.toInt(),
      lastTotal: (json['lastTotal'] as num?)?.toInt(),
    );
  }
}
