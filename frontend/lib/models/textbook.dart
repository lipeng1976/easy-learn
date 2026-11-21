/// 教材：ima 里的「骨架 MD」导入后落库的样子。
///
/// 一本书 → 若干节，每节一行标题 + 一串考点。**没有正文** —— 出题要的是
/// 「考什么」，正文留在 ima 的 PDF 里（见 `doc/textbook-ima-format.md`）。
class TextbookBook {
  const TextbookBook({
    required this.id,
    required this.title,
    this.subject = '',
    this.unitCount = 0,
    this.sourceMediaId = '',
    this.grade = '',
    this.term = '',
  });

  final String id;
  final String title;
  final String subject;
  final int unitCount;

  /// ima 文件 id：`available` 列表靠它判断「这本导过没有」。
  final String sourceMediaId;

  /// 书的年级 / 学期（如 `七上`）。空串 = 导入时还没标注（老数据）。
  /// 配置页用它比对「这本书是不是当前年级的」。
  final String grade;
  final String term;

  factory TextbookBook.fromJson(Map<String, dynamic> json) => TextbookBook(
        id: (json['id'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        subject: (json['subject'] ?? '').toString(),
        unitCount: (json['unitCount'] as num?)?.toInt() ?? 0,
        sourceMediaId: (json['sourceMediaId'] ?? '').toString(),
        grade: (json['grade'] ?? '').toString(),
        term: (json['term'] ?? '').toString(),
      );
}

/// ima 目录里的一个候选文件（还没导入）。
class TextbookCandidate {
  const TextbookCandidate({
    required this.mediaId,
    required this.fileName,
    this.importedBookId,
    this.unitCount = 0,
  });

  final String mediaId;
  final String fileName;

  /// 非空 = 这本已经导入过（再导会覆盖章节、保留 id）。
  final String? importedBookId;
  final int unitCount;

  bool get imported => importedBookId != null && importedBookId!.isNotEmpty;
}

/// `GET /data/textbook/books` 的结果。
///
/// `connected:false` 是**正常状态**（没开通 ima）：界面把「从 ima 导入」
/// 整块藏起来，但要继续显示已导入的书 —— 已导入的教材不依赖 ima。
class TextbookLibrary {
  const TextbookLibrary({
    this.connected = false,
    this.folderPath = '',
    this.books = const <TextbookBook>[],
    this.available = const <TextbookCandidate>[],
    this.reason = '',
  });

  final bool connected;

  /// ima 里该学科教材应在的目录（「目录没有」时告诉家长建在哪）。
  final String folderPath;

  /// 已导入的书。
  final List<TextbookBook> books;

  /// ima 里可导入的 md（未导入的也在里面）。
  final List<TextbookCandidate> available;

  /// `ima_unavailable` / `folder_missing` / `ima_read_error`，空 = 一切正常。
  final String reason;

  static const empty = TextbookLibrary();

  factory TextbookLibrary.fromJson(Map<String, dynamic> json) {
    List<T> parse<T>(Object? raw, T Function(Map<String, dynamic>) one) {
      if (raw is! List) return <T>[];
      return raw
          .whereType<Map>()
          .map((item) => one(Map<String, dynamic>.from(item)))
          .toList();
    }

    return TextbookLibrary(
      connected: json['connected'] == true,
      folderPath: (json['folderPath'] ?? '').toString(),
      books: parse(json['books'], TextbookBook.fromJson),
      available: parse(
        json['available'],
        (one) => TextbookCandidate(
          mediaId: (one['mediaId'] ?? '').toString(),
          fileName: (one['fileName'] ?? '').toString(),
          importedBookId: one['importedBookId']?.toString(),
          unitCount: (one['unitCount'] as num?)?.toInt() ?? 0,
        ),
      ),
      reason: (json['reason'] ?? '').toString(),
    );
  }
}

/// 一节（章 / 单元）。
class TextbookUnit {
  const TextbookUnit({
    required this.unitNo,
    required this.title,
    this.summary = '',
    this.pageHint = '',
  });

  /// 文档顺序（1 起）—— 不是从标题里解析出的章号。
  final int unitNo;
  final String title;

  /// 「、」分隔的考点。出题时被切成知识点。
  final String summary;
  final String pageHint;

  /// 下拉里显示的一行。带页码是因为家长对着纸质书找章节时，页码比章号快。
  String get label => pageHint.isEmpty ? '$unitNo. $title' : '$unitNo. $title（p$pageHint）';

  factory TextbookUnit.fromJson(Map<String, dynamic> json) => TextbookUnit(
        unitNo: (json['unitNo'] as num?)?.toInt() ?? 0,
        title: (json['title'] ?? '').toString(),
        summary: (json['summary'] ?? '').toString(),
        pageHint: (json['pageHint'] ?? '').toString(),
      );
}
