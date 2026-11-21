import 'dart:convert';

/// 英语单词打卡的数据模型。
///
/// 服务端 = 词表真值 + 练习范围 + 成绩摘要；客户端 = 出题 / 判分 / 权重 / 发音。
/// 所以这里的 [WordQuestion] **同时是落库行**：`word_answer` 一行一题，
/// 把题目快照（词、选项、答案字母、当时用的书与范围）一并存下来 —— 回看
/// 已完成的那组题时不需要再依赖词表或网络，也不受「家长中途改了范围」影响。

enum WordDirection { en2zh, zh2en }

WordDirection directionFromName(String raw) =>
    raw == 'zh2en' ? WordDirection.zh2en : WordDirection.en2zh;

String directionName(WordDirection direction) =>
    direction == WordDirection.en2zh ? 'en2zh' : 'zh2en';

/// 一条词表词条（服务端下发 + 本地缓存共用一张表）。
class WordEntry {
  const WordEntry({
    required this.id,
    required this.studentId,
    required this.bookId,
    required this.unit,
    required this.unitOrder,
    required this.word,
    required this.phonetic,
    required this.primaryMeaning,
    required this.normalizedWord,
    required this.sortNo,
    this.distractorPool = const <String>[],
  });

  final String id;
  final String studentId;
  final String bookId;
  final String unit;
  final int unitOrder;
  final String word;
  final String phonetic;
  final String primaryMeaning;
  final String normalizedWord;
  final int sortNo;

  /// 干扰项候选词 id（建池时算一次，存 JSON 字符串）。
  final List<String> distractorPool;

  factory WordEntry.fromJson(
    Map<String, dynamic> json, {
    required String studentId,
    required String bookId,
  }) =>
      WordEntry(
        id: (json['id'] ?? '').toString(),
        studentId: studentId,
        bookId: bookId,
        unit: (json['unit'] ?? '').toString(),
        unitOrder: _asInt(json['unitOrder']),
        word: (json['word'] ?? '').toString(),
        phonetic: (json['phonetic'] ?? '').toString(),
        primaryMeaning: (json['primaryMeaning'] ?? '').toString(),
        normalizedWord: (json['normalizedWord'] ?? '').toString(),
        sortNo: _asInt(json['sortNo']),
      );

  WordEntry withPool(List<String> pool) => WordEntry(
        id: id,
        studentId: studentId,
        bookId: bookId,
        unit: unit,
        unitOrder: unitOrder,
        word: word,
        phonetic: phonetic,
        primaryMeaning: primaryMeaning,
        normalizedWord: normalizedWord,
        sortNo: sortNo,
        distractorPool: pool,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'studentId': studentId,
        'bookId': bookId,
        'unit': unit,
        'unitOrder': unitOrder,
        'word': word,
        'phonetic': phonetic,
        'primaryMeaning': primaryMeaning,
        'normalizedWord': normalizedWord,
        'sortNo': sortNo,
        'distractorPool': jsonEncode(distractorPool),
      };

  factory WordEntry.fromMap(Map<String, dynamic> map) => WordEntry(
        id: (map['id'] ?? '').toString(),
        studentId: (map['studentId'] ?? '').toString(),
        bookId: (map['bookId'] ?? '').toString(),
        unit: (map['unit'] ?? '').toString(),
        unitOrder: _asInt(map['unitOrder']),
        word: (map['word'] ?? '').toString(),
        phonetic: (map['phonetic'] ?? '').toString(),
        primaryMeaning: (map['primaryMeaning'] ?? '').toString(),
        normalizedWord: (map['normalizedWord'] ?? '').toString(),
        sortNo: _asInt(map['sortNo']),
        distractorPool: _decodeStringList(map['distractorPool']),
      );
}

/// 家长配一次的练习范围（服务端 `word_scope` 是唯一真值）。
class WordScope {
  const WordScope({
    required this.studentId,
    this.bookId = '',
    this.bookTitle = '',
    this.unitMode = 'learned',
    this.currentUnit = '',
    this.selectedUnits = const <String>[],
    this.units = const <String>[],
    this.dailyCount = 10,
    this.configured = false,
  });

  final String studentId;
  final String bookId;
  final String bookTitle;
  final String unitMode;
  final String currentUnit;
  final List<String> selectedUnits;
  final List<String> units;
  final int dailyCount;
  final bool configured;

  bool get hasBook => bookId.isNotEmpty;

  factory WordScope.fromJson(Map<String, dynamic> json, {String? studentId}) =>
      WordScope(
        studentId:
            (studentId ?? json['studentId'] ?? '').toString(),
        bookId: (json['bookId'] ?? '').toString(),
        bookTitle: (json['bookTitle'] ?? '').toString(),
        unitMode: (json['unitMode'] ?? 'learned').toString(),
        currentUnit: (json['currentUnit'] ?? '').toString(),
        selectedUnits: _decodeStringList(json['selectedUnits']),
        units: _decodeStringList(json['units']),
        dailyCount: _asInt(json['dailyCount'], fallback: 10),
        configured: json['configured'] == true,
      );

  Map<String, Object?> toWriteJson() => <String, Object?>{
        'studentId': studentId,
        'bookId': bookId,
        'unitMode': unitMode,
        'currentUnit': currentUnit,
        'selectedUnits': selectedUnits,
        'dailyCount': dailyCount,
      };
}

/// 一道双向选择题。**渲染层只读 stem / options，不看 answer**。
class WordQuestion {
  const WordQuestion({
    required this.id,
    required this.wordId,
    required this.word,
    required this.primaryMeaning,
    required this.direction,
    required this.stem,
    required this.options,
    required this.answerIndex,
    required this.bookId,
    required this.bookTitle,
    required this.unitMode,
    required this.currentUnit,
    this.studentId = '',
    this.date = '',
    this.picked = '',
    this.correct = false,
    this.createdAt = '',
  });

  final String id;
  final String wordId;
  final String word;
  final String primaryMeaning;
  final WordDirection direction;
  final String stem;
  final List<String> options;
  final int answerIndex;

  /// 范围快照：已完成回放要能显示「当时用的哪本书」。
  /// 当天已作答的那组不随家长改范围重算（未作答则按新范围重出，见 §5.4.3）。
  final String bookId;
  final String bookTitle;
  final String unitMode;
  final String currentUnit;

  // ↓ 落 `word_answer` 时才有的字段
  final String studentId;
  final String date;
  final String picked;
  final bool correct;
  final String createdAt;

  String get answer => String.fromCharCode(65 + answerIndex);

  /// 判分口径与 `CheckinSubmitResult.judge` 同源：trim + 大写 + 相等，
  /// **空作答恒错**（不填不能算对）。
  bool judge(String? rawPicked) {
    final value = (rawPicked ?? '').trim().toUpperCase();
    if (value.isEmpty) return false;
    return value == answer.trim().toUpperCase();
  }

  String? get pickedLetterOrNull => picked.trim().isEmpty ? null : picked;

  WordQuestion copyWith({
    String? studentId,
    String? date,
    String? picked,
    bool? correct,
    String? createdAt,
  }) =>
      WordQuestion(
        id: id,
        wordId: wordId,
        word: word,
        primaryMeaning: primaryMeaning,
        direction: direction,
        stem: stem,
        options: options,
        answerIndex: answerIndex,
        bookId: bookId,
        bookTitle: bookTitle,
        unitMode: unitMode,
        currentUnit: currentUnit,
        studentId: studentId ?? this.studentId,
        date: date ?? this.date,
        picked: picked ?? this.picked,
        correct: correct ?? this.correct,
        createdAt: createdAt ?? this.createdAt,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'studentId': studentId,
        'date': date,
        'wordId': wordId,
        'direction': directionName(direction),
        'stem': stem,
        'optionsJson': jsonEncode(options),
        'answer': answer,
        'picked': picked,
        'correct': correct ? 1 : 0,
        'word': word,
        'primaryMeaning': primaryMeaning,
        'bookId': bookId,
        'bookTitle': bookTitle,
        'unitMode': unitMode,
        'currentUnit': currentUnit,
        'createdAt': createdAt,
      };

  factory WordQuestion.fromMap(Map<String, dynamic> map) => WordQuestion(
        id: (map['id'] ?? '').toString(),
        studentId: (map['studentId'] ?? '').toString(),
        date: (map['date'] ?? '').toString(),
        wordId: (map['wordId'] ?? '').toString(),
        direction: directionFromName((map['direction'] ?? '').toString()),
        stem: (map['stem'] ?? '').toString(),
        options: _decodeStringList(map['optionsJson']),
        answerIndex: _answerIndexOf(map['answer']),
        word: (map['word'] ?? '').toString(),
        primaryMeaning: (map['primaryMeaning'] ?? '').toString(),
        bookId: (map['bookId'] ?? '').toString(),
        bookTitle: (map['bookTitle'] ?? '').toString(),
        unitMode: (map['unitMode'] ?? '').toString(),
        currentUnit: (map['currentUnit'] ?? '').toString(),
        picked: (map['picked'] ?? '').toString(),
        correct: _asInt(map['correct']) == 1,
        createdAt: (map['createdAt'] ?? '').toString(),
      );
}

/// 家长端的成绩摘要（云上 `word_daily_result` 一行）。
class WordDailyResult {
  const WordDailyResult({
    required this.day,
    required this.total,
    required this.correct,
    required this.streak,
    this.wrongWords = const <String>[],
  });

  final String day;
  final int total;
  final int correct;
  final int streak;
  final List<String> wrongWords;

  double get accuracy => total == 0 ? 0 : correct / total;

  factory WordDailyResult.fromJson(Map<String, dynamic> json) => WordDailyResult(
        day: (json['day'] ?? '').toString(),
        total: _asInt(json['total']),
        correct: _asInt(json['correct']),
        streak: _asInt(json['streak']),
        wrongWords: (json['wrongWords'] as List<dynamic>? ?? const <dynamic>[])
            .map((one) => one is Map ? (one['word'] ?? '').toString() : one.toString())
            .where((one) => one.isNotEmpty)
            .toList(),
      );
}

/// ima 里可导入的一份词表。
class WordAvailableBook {
  const WordAvailableBook({
    required this.mediaId,
    required this.fileName,
    required this.title,
    this.importedBookId,
    this.importedWordCount = 0,
  });

  final String mediaId;
  final String fileName;
  final String title;
  final String? importedBookId;
  final int importedWordCount;

  factory WordAvailableBook.fromJson(Map<String, dynamic> json) =>
      WordAvailableBook(
        mediaId: (json['mediaId'] ?? '').toString(),
        fileName: (json['fileName'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        importedBookId: json['importedBookId'] as String?,
        importedWordCount: _asInt(json['importedWordCount']),
      );
}

/// 已导入的书（家长换书用）。
class WordImportedBook {
  const WordImportedBook({
    required this.id,
    required this.title,
    this.unitCount = 0,
    this.wordCount = 0,
    this.grade = '',
    this.term = '',
  });

  final String id;
  final String title;
  final int unitCount;
  final int wordCount;

  /// 词的年级 / 学期。空串 = 未标注（老数据）。
  final String grade;
  final String term;

  factory WordImportedBook.fromJson(Map<String, dynamic> json) =>
      WordImportedBook(
        id: (json['id'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        unitCount: _asInt(json['unitCount']),
        wordCount: _asInt(json['wordCount']),
        grade: (json['grade'] ?? '').toString(),
        term: (json['term'] ?? '').toString(),
      );
}

int _asInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

int _answerIndexOf(dynamic letter) {
  final one = (letter ?? '').toString().trim().toUpperCase();
  if (one.length != 1) return 0;
  final code = one.codeUnitAt(0);
  return (code >= 65 && code <= 90) ? code - 65 : 0;
}

List<String> _decodeStringList(dynamic raw) {
  if (raw is List) return raw.map((one) => one.toString()).toList();
  if (raw is String && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((one) => one.toString()).toList();
    } catch (_) {
      return const <String>[];
    }
  }
  return const <String>[];
}
