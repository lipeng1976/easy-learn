/// 学科范围：家长配一次，出题时直接用它。
///
/// ## 为什么科目清单写死在这里
///
/// 它是**唯一来源**：配置区、出题色块、服务端白名单（`routes/subject.js`）
/// 三处必须逐字一致。散着写的话，新增一科时总有一处漏掉，症状是
/// 「客户端能选、服务端 400」或反过来「配好了但没有色块」。
/// 服务端那份有 `test/subject-scope.test.js` 逐字断言，客户端这份有
/// `test/subject_board_test.dart` 断言同一串字面量。
///
/// ⚠️ 与 `HomeworkItemNormalizer.subjectNames` 同序同内容（拍照批改的科目
/// 识别也用这一串）；改这里必须同步那边。
const List<String> kSubjectNames = <String>[
  '语文',
  '数学',
  '英语',
  '物理',
  '化学',
  '生物',
  '历史',
  '地理',
  '政治',
  '其他',
];

/// 能出题的科目：**十科全开**。
///
/// 与 [kSubjectNames] 同一个集合（直接引用它，不抄一份 —— 抄一份就会在
/// 下次加科目时漂）。差别只在「题从哪来」：
///   · 十科都能走服务端 AI 出**教材题**（`/data/checkin/generate`）；
///   · 英语额外有一套客户端本地**单词题**（`WordDrillController`，按词表出）。
///     两本资料各管各的：词表走 `/word-scope`，教材走 `/subject-scope`。
///
/// ## 题型只有选择题和判断题
///
/// 全科都限这两种（服务端 `normalizeQuestions` + 网关 schema 双重拦截）。
/// 原因不是「AI 不会出填空题」，而是**判分在客户端本地做**：填空/解答写成
/// `0.5` 与 `1/2`、`x=3` 与 `3` 就会被判错，做对的孩子却不知道自己错在哪。
/// 要开填空必须先把归一化判分做出来，不能只改这里。
const List<String> kSubjectDrillReady = kSubjectNames;

/// 出题题型的人类说法（配置页/发起页用来告诉家长「只会出这两种」）。
const String kCheckinQuestionTypesLabel = '只出选择题 · 判断题';

/// 题量档位：与服务端 `DAILY_COUNTS` 同一口径（不给自由输入）。
const List<int> kSubjectDailyCounts = <int>[3, 5, 8];

/// 难度档位：与 `kCheckinDifficulties` 同一口径。
const List<String> kSubjectDifficulties = <String>['基础', '提高', '挑战'];

/// 「范围条目」在各科叫什么。同一个字段（`points`），家长看到的词必须是他
/// 自己那门课的说法 —— 在历史页写「知识点」会让人以为填错了地方。
String subjectPointLabel(String subject) {
  switch (subject) {
    case '语文':
      return '字词 / 古诗 / 课文';
    case '历史':
      return '时间点 / 关键事件';
    case '英语':
      return '语法 / 时态 / 句型';
    case '数学':
      return '知识点';
    case '物理':
    case '化学':
    case '生物':
      return '章节 / 知识点';
    case '地理':
      return '区域 / 知识点';
    case '政治':
      return '考点';
    default:
      return '范围条目';
  }
}

/// 一科的范围。**未配置**也要能构造（题量/难度有默认值），
/// 这样出题区不必为「还没配」写一条空分支。
class SubjectScope {
  const SubjectScope({
    required this.studentId,
    required this.subject,
    this.dailyCount = 5,
    this.difficulty = '基础',
    this.points = const <String>[],
    this.configured = false,
    this.bookId,
    this.bookTitle,
    this.startUnitNo = 1,
    this.unitsPerDay = 1,
    this.updatedAt,
  });

  final String studentId;
  final String subject;
  final int dailyCount;
  final String difficulty;

  /// 范围条目（数学=知识点 / 语文=字词诗词 / 历史=时间点事件）。
  /// **顺序即优先级**，最多 6 条（服务端也拦）。
  final List<String> points;

  /// 配了教材时的书 id（`subject_book`）。**空 = 没配教材**，
  /// 出题继续走「手填条目 / 错题本聚合同科知识点」那条路。
  ///
  /// 学生的打卡范围只有一处真相：配了书就以书为准（`generateCheckin`
  /// 里教材优先），此时 [points] 不参与出题 —— 两套范围混在一起的话，
  /// 家长会看到「明明配了课本，考的却是手填的那条」。
  final String? bookId;

  /// 书名，只用于显示（列表摘要、配置页标题）。
  final String? bookTitle;

  /// 从第几节开始 —— 同时是**出题游标**：每成功出一次题往后推
  /// [unitsPerDay] 节。起点和游标是同一个数，不做两份。
  final int startUnitNo;

  /// 每天覆盖几节（1~3，与服务端 CHECK 同一口径）。
  final int unitsPerDay;

  /// 服务端有没有这一行。`false` 时 [dailyCount] / [difficulty] 只是默认值。
  final bool configured;
  final String? updatedAt;

  factory SubjectScope.fromJson(
    Map<String, dynamic> json, {
    String? studentId,
    String? subject,
  }) {
    final rawPoints = json['points'];
    final book = json['bookId']?.toString();
    return SubjectScope(
      studentId: (json['studentId'] ?? studentId ?? '').toString(),
      subject: (json['subject'] ?? subject ?? '').toString(),
      dailyCount: (json['dailyCount'] as num?)?.toInt() ?? 5,
      difficulty: (json['difficulty'] ?? '基础').toString(),
      points: rawPoints is List
          ? rawPoints.map((one) => one.toString()).where((one) => one.isNotEmpty).toList()
          : const <String>[],
      configured: json['configured'] == true,
      bookId: (book == null || book.isEmpty) ? null : book,
      bookTitle: json['bookTitle']?.toString(),
      startUnitNo: (json['startUnitNo'] as num?)?.toInt() ?? 1,
      unitsPerDay: (json['unitsPerDay'] as num?)?.toInt() ?? 1,
      updatedAt: json['updatedAt']?.toString(),
    );
  }

  /// 写接口的 body。**整行覆盖**：清空知识点也要能被表达出来。
  Map<String, Object?> toWriteJson() => <String, Object?>{
        'studentId': studentId,
        'subject': subject,
        'dailyCount': dailyCount,
        'difficulty': difficulty,
        'points': points,
        'bookId': bookId ?? '',
        'startUnitNo': startUnitNo,
        'unitsPerDay': unitsPerDay,
      };

  SubjectScope copyWith({
    int? dailyCount,
    String? difficulty,
    List<String>? points,
    bool? configured,
    String? bookId,
    String? bookTitle,
    int? startUnitNo,
    int? unitsPerDay,
    bool clearBook = false,
  }) =>
      SubjectScope(
        studentId: studentId,
        subject: subject,
        dailyCount: dailyCount ?? this.dailyCount,
        difficulty: difficulty ?? this.difficulty,
        points: points ?? this.points,
        configured: configured ?? this.configured,
        bookId: clearBook ? null : (bookId ?? this.bookId),
        // 换书时书名也得跟着换；`clearBook` 用来表达「取消选书」。
        bookTitle: clearBook ? null : (bookTitle ?? this.bookTitle),
        startUnitNo: startUnitNo ?? this.startUnitNo,
        unitsPerDay: unitsPerDay ?? this.unitsPerDay,
        updatedAt: updatedAt,
      );

  /// 配置区那一行的摘要。英语不用它（英文摘要来自词表配置，见 `SubjectBoard`）。
  ///
  /// 配了教材就把书名放前面：家长扫一眼要能看出「这科现在跟着哪本书走」，
  /// 而不是看到「每天 5 题 · 基础」才发现自己早就忘了当初填了什么范围。
  String get summary {
    if (!configured) return '未配置';
    final base = '每天 $dailyCount 题 · $difficulty';
    if (bookId != null && bookId!.isNotEmpty) {
      final book = (bookTitle == null || bookTitle!.isEmpty) ? '教材' : bookTitle!;
      final scope = unitsPerDay > 1 ? '第 $startUnitNo 节起 · 每天 $unitsPerDay 节' : '第 $startUnitNo 节起';
      return '$book · $scope';
    }
    return points.isEmpty ? base : '$base · ${points.length} 个范围';
  }
}
