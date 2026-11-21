/// 英文阅读的模型。
///
/// ## 这里的字段名与服务端**逐字对应**
///
/// 服务端 `routes/reading.js` 里每个响应字段都写死了驼峰名（`lessonCount`、
/// `nextLessonNo`…），SQL 列是蛇形（`lesson_count`）。中间只有服务端那一次
/// 映射，客户端不再转换 —— 两边各转一次的下场是「字段名对不上」变成
/// 一个**静默的空值**：卡片显示 0/0，没有任何报错，也查不出是谁改的。
///
/// ## 为什么进度不存成「今天的第几篇」
///
/// 任务挂在书上（见 `sql/023_reading.sql`）。一次任务只有
/// [ReadingTask.doneLessons] / [ReadingTask.totalLessons] 两个数，
/// 没有「今天该读第几篇」这个概念 —— 断更几天再回来，进度原样还在。
library;

/// 一本已导入的书。
class ReadingBook {
  const ReadingBook({
    required this.id,
    required this.title,
    this.author = '',
    this.intro = '',
    this.lessonCount = 0,
    this.source = 'ima',
    this.activeTaskCount = 0,
  });

  final String id;
  final String title;
  final String author;
  final String intro;
  final int lessonCount;

  /// `ima` / `manual`。v1 只有 `ima`，但显示来源是为了让家长知道
  /// 「这本书是从知识库哪个目录来的」。
  final String source;

  /// 这本书当前有几份**进行中**的任务。用于决定按钮是「布置」还是「继续」。
  final int activeTaskCount;

  bool get hasActiveTask => activeTaskCount > 0;

  factory ReadingBook.fromJson(Map<String, dynamic> json) => ReadingBook(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '未命名书籍',
        author: json['author'] as String? ?? '',
        intro: json['intro'] as String? ?? '',
        lessonCount: (json['lessonCount'] as num?)?.toInt() ?? 0,
        source: json['source'] as String? ?? 'ima',
        activeTaskCount: (json['activeTaskCount'] as num?)?.toInt() ?? 0,
      );
}

/// ima 知识库里**可以导入**的一本书（还没导进 App）。
class ReadingAvailableBook {
  const ReadingAvailableBook({
    required this.mediaId,
    required this.fileName,
    required this.title,
    this.importedBookId,
    this.importedLessonCount = 0,
  });

  final String mediaId;
  final String fileName;
  final String title;

  /// 非空表示这本已经导入过了。界面据此把「导入」换成「已导入 · N 课」，
  /// 否则家长会反复点，而服务端只是幂等地把同一本书返回一次 —— 界面上
  /// 看不出任何变化，他会以为没成功。
  final String? importedBookId;
  final int importedLessonCount;

  bool get imported => (importedBookId ?? '').isNotEmpty;

  factory ReadingAvailableBook.fromJson(Map<String, dynamic> json) {
    final id = json['importedBookId'] as String?;
    return ReadingAvailableBook(
      mediaId: json['mediaId'] as String? ?? '',
      fileName: json['fileName'] as String? ?? '',
      title: json['title'] as String? ?? '未命名书籍',
      importedBookId: (id ?? '').isEmpty ? null : id,
      importedLessonCount: (json['importedLessonCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 一次阅读任务 = 一本书。
///
/// `status` 只有三种：`active`（进行中）/ `done`（读完）/ `cancelled`（家长撤了）。
class ReadingTask {
  const ReadingTask({
    required this.id,
    required this.bookId,
    required this.bookTitle,
    this.dailyTarget = 1,
    this.status = 'active',
    this.doneLessons = 0,
    this.totalLessons = 0,
    this.nextLessonNo,
    this.finished = false,
    this.readLessonNos = const [],
  });

  final String id;
  final String bookId;
  final String bookTitle;

  /// 每天建议读几篇。v1 服务端固定 1，但客户端不写死 —— 卡片上的
  /// 「今日 0/1 篇」要靠它算，写死就改不动了。
  final int dailyTarget;

  final String status;
  final int doneLessons;
  final int totalLessons;

  /// 下一篇该读第几课。`null` = 没有下一篇（读完了 / 任务撤销了）。
  /// **不要用 0 表示没有**：0 是合法课号的相邻值，判空写错就变成「读第 0 课」。
  final int? nextLessonNo;

  /// 是否已经读完。
  ///
  /// ⚠️ 与 `nextLessonNo == null` **不是一回事**：被家长撤掉的任务也没有
  /// 下一篇，但它不算读完。混成一个判断，家长会看到一张被自己撤掉的卡
  /// 写着「已读完」。
  final bool finished;

  /// 已读的课号（升序）。用于阅读页判断「这一课我读过没有」，
  /// 以及课目录上的打勾标记。
  final List<int> readLessonNos;

  bool get isActive => status == 'active';
  bool get isCancelled => status == 'cancelled';

  /// 进度 0~1。总篇数为 0 时返回 0（不能返回 NaN —— 进度条拿到 NaN 会抛）。
  double get progress =>
      totalLessons <= 0 ? 0 : (doneLessons / totalLessons).clamp(0.0, 1.0);

  bool hasRead(int lessonNo) => readLessonNos.contains(lessonNo);

  factory ReadingTask.fromJson(Map<String, dynamic> json) {
    final raw = json['readLessonNos'];
    return ReadingTask(
      id: json['id'] as String? ?? '',
      bookId: json['bookId'] as String? ?? '',
      bookTitle: json['bookTitle'] as String? ?? '未命名书籍',
      dailyTarget: (json['dailyTarget'] as num?)?.toInt() ?? 1,
      status: json['status'] as String? ?? 'active',
      doneLessons: (json['doneLessons'] as num?)?.toInt() ?? 0,
      totalLessons: (json['totalLessons'] as num?)?.toInt() ?? 0,
      nextLessonNo: (json['nextLessonNo'] as num?)?.toInt(),
      finished: json['finished'] == true,
      readLessonNos: raw is List
          ? [for (final item in raw) if (item is num) item.toInt()]
          : const [],
    );
  }
}

/// 词条。
class ReadingVocabulary {
  const ReadingVocabulary({
    required this.word,
    this.no = 0,
    this.phonetic = '',
    this.meaning = '',
    this.detail = '',
  });

  final int no;
  final String word;
  final String phonetic;
  final String meaning;

  /// 典型例句 / 最常用法 / 联想记忆。原书排版太松，不拆成结构化字段 ——
  /// 拆下去必然出错，而错的是学生看到的释义。
  final String detail;

  factory ReadingVocabulary.fromJson(Map<String, dynamic> json) => ReadingVocabulary(
        no: (json['no'] as num?)?.toInt() ?? 0,
        word: json['word'] as String? ?? '',
        phonetic: json['phonetic'] as String? ?? '',
        meaning: json['meaning'] as String? ?? '',
        detail: json['detail'] as String? ?? '',
      );
}

/// 一课的全文。
class ReadingLesson {
  const ReadingLesson({
    required this.lessonNo,
    required this.title,
    this.titleZh = '',
    this.body = '',
    this.translation = '',
    this.vocabulary = const [],
    this.charCount = 0,
  });

  final int lessonNo;
  final String title;
  final String titleZh;

  /// 英文正文。段落之间是空行 —— 渲染时按空行分段，不要按单个 `\n` 断，
  /// 原书里一句话被折行的地方会因此变成好几段。
  final String body;
  final String translation;
  final List<ReadingVocabulary> vocabulary;
  final int charCount;

  List<String> get paragraphs => [
        for (final block in body.split(RegExp(r'\n\s*\n')))
          if (block.trim().isNotEmpty) block.trim(),
      ];

  List<String> get translationParagraphs => [
        for (final block in translation.split(RegExp(r'\n\s*\n')))
          if (block.trim().isNotEmpty) block.trim(),
      ];

  factory ReadingLesson.fromJson(Map<String, dynamic> json) {
    final vocab = json['vocabulary'];
    return ReadingLesson(
      lessonNo: (json['lessonNo'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      titleZh: json['titleZh'] as String? ?? '',
      body: json['body'] as String? ?? '',
      translation: json['translation'] as String? ?? '',
      vocabulary: vocab is List
          ? [
              for (final item in vocab)
                if (item is Map) ReadingVocabulary.fromJson(Map<String, dynamic>.from(item)),
            ]
          : const [],
      charCount: (json['charCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 课目录里的一行（不含正文）。
class ReadingLessonSummary {
  const ReadingLessonSummary({
    required this.lessonNo,
    required this.title,
    this.titleZh = '',
    this.charCount = 0,
  });

  final int lessonNo;
  final String title;
  final String titleZh;
  final int charCount;

  factory ReadingLessonSummary.fromJson(Map<String, dynamic> json) => ReadingLessonSummary(
        lessonNo: (json['lessonNo'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        titleZh: json['titleZh'] as String? ?? '',
        charCount: (json['charCount'] as num?)?.toInt() ?? 0,
      );
}

/// 导入一本书的结果。
class ReadingImportResult {
  const ReadingImportResult({
    required this.book,
    required this.imported,
    this.skipped = const [],
  });

  final ReadingBook book;

  /// `false` 表示这本书之前就导过，这次只是把它取回来。
  /// 界面要说「已经导入过了」，不要假装刚完成一次耗时的切课。
  final bool imported;

  /// 有课号但解析不出正文的课。非空时界面要如实提示，**不能静默忽略** ——
  /// 家长会以为整本书 96 课都在。
  final List<int> skipped;

  factory ReadingImportResult.fromJson(Map<String, dynamic> json) {
    final raw = json['skipped'];
    return ReadingImportResult(
      book: ReadingBook.fromJson(Map<String, dynamic>.from(json['book'] as Map? ?? {})),
      imported: json['imported'] == true,
      skipped: raw is List
          ? [for (final item in raw) if (item is num) item.toInt()]
          : const [],
    );
  }
}

/// 一条打卡记录：某天读了某一篇。
///
/// `day` 是**客户端本地日**（`yyyy-MM-dd`），由打卡时一起提交（R4）。
/// 所以这里不要拿 `readAt` 去推日期 —— 服务端时区与孩子所在时区不同时，
/// 晚上 8 点后打的卡会在 UTC 里落成第二天。
class ReadingLogEntry {
  const ReadingLogEntry({
    required this.id,
    required this.taskId,
    required this.bookId,
    required this.bookTitle,
    required this.lessonNo,
    required this.day,
    this.lessonTitle = '',
    this.lessonTitleZh = '',
    this.readAt,
  });

  final String id;
  final String taskId;
  final String bookId;
  final String bookTitle;
  final int lessonNo;

  /// 本地日 `yyyy-MM-dd`。
  final String day;

  /// 课名。服务端做了 `left join`：老记录即使对应的课被重导入删掉，
  /// 这一条**仍然要出现**（只是没有标题），不能整条消失。
  final String lessonTitle;
  final String lessonTitleZh;

  /// 打卡时刻（带时区）。只用来显示「19:42」，不参与日期判断。
  final DateTime? readAt;

  /// 显示用的标题：中文标题优先，其次英文。
  String get displayTitle =>
      lessonTitleZh.isNotEmpty ? lessonTitleZh : lessonTitle;

  factory ReadingLogEntry.fromJson(Map<String, dynamic> json) {
    final rawAt = json['readAt'];
    return ReadingLogEntry(
      id: json['id'] as String? ?? '',
      taskId: json['taskId'] as String? ?? '',
      bookId: json['bookId'] as String? ?? '',
      bookTitle: json['bookTitle'] as String? ?? '',
      lessonNo: (json['lessonNo'] as num?)?.toInt() ?? 0,
      day: json['day'] as String? ?? '',
      lessonTitle: json['lessonTitle'] as String? ?? '',
      lessonTitleZh: json['lessonTitleZh'] as String? ?? '',
      readAt: rawAt is String && rawAt.isNotEmpty
          ? DateTime.tryParse(rawAt)?.toLocal()
          : null,
    );
  }
}

/// 一页打卡记录（服务端分页）。
class ReadingLogPage {
  const ReadingLogPage({
    this.logs = const [],
    this.total = 0,
    this.hasMore = false,
  });

  final List<ReadingLogEntry> logs;

  /// 当前筛选条件下的**总条数**（不是本页条数）。界面用来说
  /// 「一共 128 次打卡」—— 只报本页条数会让人以为历史只有 30 条。
  final int total;
  final bool hasMore;

  factory ReadingLogPage.fromJson(Map<String, dynamic> json) {
    final raw = json['logs'];
    return ReadingLogPage(
      logs: raw is List
          ? [
              for (final item in raw)
                if (item is Map)
                  ReadingLogEntry.fromJson(Map<String, dynamic>.from(item)),
            ]
          : const [],
      total: (json['total'] as num?)?.toInt() ?? 0,
      hasMore: json['hasMore'] == true,
    );
  }
}

/// 打卡的结果。
class ReadingReadResult {
  const ReadingReadResult({
    required this.task,
    this.already = false,
    this.taskDone = false,
  });

  final ReadingTask task;

  /// 这一课之前已经读过了（断网重试 / 双端同时点）。进度没有变化，
  /// 但界面**不该报错** —— 孩子看到的应该是「还是 3/96」，不是一句红色提示。
  final bool already;

  /// 这一次之后整本书读完了。
  final bool taskDone;

  factory ReadingReadResult.fromJson(Map<String, dynamic> json) => ReadingReadResult(
        task: ReadingTask.fromJson(Map<String, dynamic>.from(json['task'] as Map? ?? {})),
        already: json['already'] == true,
        taskDone: json['taskDone'] == true,
      );
}
