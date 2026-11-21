import '../models/word_checkin.dart';
import 'data_api_client.dart';

/// 单词打卡的云端仓库：**词表真值 + 练习范围 + 成绩摘要**。
///
/// 出题 / 判分 / 错词权重 / 发音都在客户端，所以这里没有「生成题目」。
/// 没连云端（纯本地模式）时一律回空、不抛错 —— 可选能力规矩：功能可以缺，不能错。
abstract class WordRepository {
  Future<WordBookList> listBooks(String studentId);

  Future<Map<String, dynamic>> importBook({
    required String studentId,
    required String mediaId,
    String? fileName,
    String? title,
    String grade = '',
    String term = '',
  });

  Future<List<WordEntry>> listEntries({
    required String studentId,
    required String bookId,
  });

  Future<WordScope> getScope(String studentId);

  Future<WordScope> putScope(WordScope scope);

  Future<void> postDaily({
    required String studentId,
    required String day,
    required int total,
    required int correct,
    required int streak,
    required List<Map<String, dynamic>> wrongWords,
  });

  Future<List<WordDailyResult>> listDaily({
    required String studentId,
    String? from,
    String? to,
    int limit = 30,
    int offset = 0,
  });
}

class WordBookList {
  const WordBookList({
    required this.connected,
    this.available = const <WordAvailableBook>[],
    this.imported = const <WordImportedBook>[],
    this.reason = '',
    this.folderPath = '教学资料/Wordlist',
  });

  final bool connected;
  final List<WordAvailableBook> available;
  final List<WordImportedBook> imported;
  final String reason;
  final String folderPath;

  /// 无 ima 时入口隐藏（`available` 为空也无妨），但**已导入的书仍要能切**。
  bool get importAvailable => connected && available.isNotEmpty;

  factory WordBookList.fromJson(Map<String, dynamic> json) => WordBookList(
        connected: json['connected'] == true,
        available: _list(json['books'], WordAvailableBook.fromJson),
        imported: _list(json['imported'], WordImportedBook.fromJson),
        reason: (json['reason'] ?? '').toString(),
        folderPath: (json['folderPath'] ?? '教学资料/Wordlist').toString(),
      );
}

class HttpWordRepository implements WordRepository {
  const HttpWordRepository(this._api);

  final DataApiClient _api;

  @override
  Future<WordBookList> listBooks(String studentId) async {
    final data = await _api.getJson(
      '/data/word/books',
      query: <String, Object?>{'studentId': studentId},
    );
    return WordBookList.fromJson(data);
  }

  @override
  Future<Map<String, dynamic>> importBook({
    required String studentId,
    required String mediaId,
    String? fileName,
    String? title,
    String grade = '',
    String term = '',
  }) =>
      _api.postJson(
        '/data/word/import',
        body: <String, Object?>{
          'studentId': studentId,
          'mediaId': mediaId,
          'fileName': fileName,
          'title': title,
          'grade': grade,
          'term': term,
        },
      );

  @override
  Future<List<WordEntry>> listEntries({
    required String studentId,
    required String bookId,
  }) async {
    final data = await _api.getJson(
      '/data/word/entries',
      query: <String, Object?>{'studentId': studentId, 'bookId': bookId},
    );
    final raw = data['entries'] as List<dynamic>? ?? const <dynamic>[];
    return raw
        .whereType<Map>()
        .map((one) => WordEntry.fromJson(
              Map<String, dynamic>.from(one),
              studentId: studentId,
              bookId: bookId,
            ))
        .toList();
  }

  @override
  Future<WordScope> getScope(String studentId) async {
    final data = await _api.getJson(
      '/data/word/scope',
      query: <String, Object?>{'studentId': studentId},
    );
    return WordScope.fromJson(data, studentId: studentId);
  }

  @override
  Future<WordScope> putScope(WordScope scope) async {
    final data = await _api.putJson(
      '/data/word/scope',
      body: scope.toWriteJson(),
    );
    return WordScope.fromJson(data, studentId: scope.studentId);
  }

  @override
  Future<void> postDaily({
    required String studentId,
    required String day,
    required int total,
    required int correct,
    required int streak,
    required List<Map<String, dynamic>> wrongWords,
  }) async {
    await _api.postJson(
      '/data/word/daily',
      body: <String, Object?>{
        'studentId': studentId,
        'day': day,
        'total': total,
        'correct': correct,
        'streak': streak,
        'wrongWords': wrongWords,
      },
    );
  }

  @override
  Future<List<WordDailyResult>> listDaily({
    required String studentId,
    String? from,
    String? to,
    int limit = 30,
    int offset = 0,
  }) async {
    final data = await _api.getJson(
      '/data/word/daily',
      query: <String, Object?>{
        'studentId': studentId,
        '?from': from,
        '?to': to,
        'limit': limit,
        'offset': offset,
      },
    );
    return _list(data['results'], WordDailyResult.fromJson);
  }
}

/// 纯本地模式 / 服务端未部署时：全返回空，**绝不抛异常**。
/// 词表若已缓存在本地，打卡照样能跑（控制器不依赖这个仓库的出题结果）。
class UnavailableWordRepository implements WordRepository {
  const UnavailableWordRepository();

  @override
  Future<WordBookList> listBooks(String studentId) async =>
      const WordBookList(connected: false, reason: 'word_unavailable');

  @override
  Future<Map<String, dynamic>> importBook({
    required String studentId,
    required String mediaId,
    String? fileName,
    String? title,
    String grade = '',
    String term = '',
  }) async =>
      <String, dynamic>{
        'imported': false,
        'connected': false,
        'reason': 'word_unavailable',
      };

  @override
  Future<List<WordEntry>> listEntries({
    required String studentId,
    required String bookId,
  }) async =>
      const <WordEntry>[];

  @override
  Future<WordScope> getScope(String studentId) async =>
      WordScope(studentId: studentId);

  @override
  Future<WordScope> putScope(WordScope scope) async => scope;

  @override
  Future<void> postDaily({
    required String studentId,
    required String day,
    required int total,
    required int correct,
    required int streak,
    required List<Map<String, dynamic>> wrongWords,
  }) async {}

  @override
  Future<List<WordDailyResult>> listDaily({
    required String studentId,
    String? from,
    String? to,
    int limit = 30,
    int offset = 0,
  }) async =>
      const <WordDailyResult>[];
}

List<T> _list<T>(
  dynamic raw,
  T Function(Map<String, dynamic>) fromJson,
) =>
    (raw is List ? raw : const <dynamic>[])
        .whereType<Map>()
        .map((one) => fromJson(Map<String, dynamic>.from(one)))
        .toList();
