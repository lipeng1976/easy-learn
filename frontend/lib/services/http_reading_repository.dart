import '../models/reading_models.dart';
import '../repositories/reading_repository.dart';
import 'data_api_client.dart';

/// 英文阅读的 HTTP 实现（走 `/data/reading/*`）。
///
/// ## 导入要比默认超时等得久
///
/// 一次导入 = 「从 ima 下载 3.4MB → 剥 311 张 base64 → 切 96 课 →
/// 一条 SQL 插 96 行」。实测 3~8 秒，冷启动更久。默认 12 秒在弱网下会
/// 出现「客户端超时了，但服务端其实已经导好了」—— 家长重试一次，
/// 拿到的是幂等返回，看起来像成功，但**第一次那次导入到底成没成没人知道**。
/// 所以给足 45 秒，与服务端出题那条路同一个量级。
class HttpReadingRepository implements ReadingRepository {
  const HttpReadingRepository(this._api);

  final DataApiClient _api;

  static const Duration importTimeout = Duration(seconds: 45);

  String? _sid(String? studentId) => (studentId ?? '').isEmpty ? null : studentId;

  @override
  Future<List<ReadingAvailableBook>> listAvailableBooks({String? studentId}) async {
    final data = await _api.getJson(
      '/data/reading/books/available',
      query: {if (_sid(studentId) != null) 'studentId': _sid(studentId)!},
    );
    // 2xx + connected:false = 「没开通 ima」，不是失败。抛一个内部信号，
    // 让控制器把「从 ima 导入」整块藏掉，而不是弹红色错误。
    if (data['connected'] == false) {
      throw ImaBookSourceUnavailable(data['reason'] as String? ?? 'ima_unavailable');
    }
    final raw = data['books'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) ReadingAvailableBook.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  @override
  Future<ReadingImportResult> importBook({
    required String mediaId,
    String? studentId,
    String fileName = '',
    String title = '',
  }) async {
    final data = await _api.postJson(
      '/data/reading/books/import',
      body: {
        'mediaId': mediaId,
        if (_sid(studentId) != null) 'studentId': _sid(studentId)!,
        if (fileName.isNotEmpty) 'fileName': fileName,
        if (title.isNotEmpty) 'title': title,
      },
      timeout: importTimeout,
    );
    return ReadingImportResult.fromJson(data);
  }

  @override
  Future<List<ReadingBook>> listBooks({String? studentId}) async {
    final data = await _api.getJson(
      '/data/reading/books',
      query: {if (_sid(studentId) != null) 'studentId': _sid(studentId)!},
    );
    final raw = data['books'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) ReadingBook.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  @override
  Future<List<ReadingLessonSummary>> listLessons({
    required String bookId,
    String? studentId,
  }) async {
    final data = await _api.getJson(
      '/data/reading/lessons',
      query: {
        'bookId': bookId,
        if (_sid(studentId) != null) 'studentId': _sid(studentId)!,
      },
    );
    final raw = data['lessons'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) ReadingLessonSummary.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  @override
  Future<ReadingLesson> getLesson({
    required String bookId,
    required int lessonNo,
    String? studentId,
  }) async {
    final data = await _api.getJson(
      '/data/reading/lesson',
      query: {
        'bookId': bookId,
        'lessonNo': '$lessonNo',
        if (_sid(studentId) != null) 'studentId': _sid(studentId)!,
      },
    );
    return ReadingLesson.fromJson(Map<String, dynamic>.from(data['lesson'] as Map? ?? {}));
  }

  @override
  Future<List<ReadingTask>> listTasks({String? studentId}) async {
    final data = await _api.getJson(
      '/data/reading/tasks',
      query: {if (_sid(studentId) != null) 'studentId': _sid(studentId)!},
    );
    final raw = data['tasks'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) ReadingTask.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  @override
  Future<({ReadingTask task, bool created})> createTask({
    required String bookId,
    String? studentId,
  }) async {
    final data = await _api.postJson(
      '/data/reading/tasks',
      body: {
        'bookId': bookId,
        if (_sid(studentId) != null) 'studentId': _sid(studentId)!,
      },
    );
    return (
      task: ReadingTask.fromJson(Map<String, dynamic>.from(data['task'] as Map? ?? {})),
      created: data['created'] == true,
    );
  }

  @override
  Future<ReadingReadResult> readLesson({
    required String taskId,
    required int lessonNo,
    required String day,
    String? studentId,
  }) async {
    final data = await _api.postJson(
      '/data/reading/tasks/read',
      body: {
        'taskId': taskId,
        'lessonNo': lessonNo,
        // 日期由客户端给（R4）：服务端按 UTC 算会在晚上 8 点后记到明天，
        // 而孩子刚读完那一篇，看到的是「今天没读」。
        'day': day,
        if (_sid(studentId) != null) 'studentId': _sid(studentId)!,
      },
    );
    return ReadingReadResult.fromJson(data);
  }

  @override
  Future<ReadingTask> cancelTask({
    required String taskId,
    String? studentId,
  }) async {
    final data = await _api.postJson(
      '/data/reading/tasks/cancel',
      body: {
        'taskId': taskId,
        if (_sid(studentId) != null) 'studentId': _sid(studentId)!,
      },
    );
    return ReadingTask.fromJson(Map<String, dynamic>.from(data['task'] as Map? ?? {}));
  }

  @override
  Future<ReadingLogPage> listLogs({
    String? studentId,
    String? from,
    String? to,
    int limit = 50,
    int offset = 0,
  }) async {
    final data = await _api.getJson(
      '/data/reading/logs',
      query: {
        if (_sid(studentId) != null) 'studentId': _sid(studentId)!,
        // 空串会被服务端当成「没给」——这里干脆不带这个参数，
        // 免得 `/logs?from=` 在某天被解释成「from 是空日期」。
        if ((from ?? '').isNotEmpty) 'from': from!,
        if ((to ?? '').isNotEmpty) 'to': to!,
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    return ReadingLogPage.fromJson(data);
  }
}

/// 纯本地模式：阅读书与任务都在云端（家长与孩子是两个账号，本地各存一份
/// 永远对不上），所以本机模式下整块不可用。
///
/// 明确抛错而不是返回空：返回空会让计划页显示「还没有阅读任务」，
/// 家长会一直点「布置」—— 那个按钮永远不会成功，且没有任何解释。
class UnavailableReadingRepository implements ReadingRepository {
  const UnavailableReadingRepository();

  static const DataApiException _unavailable = DataApiException(
    code: 'unavailable',
    message: '当前是本地模式，阅读任务需要联网；联网版里书和进度会存到云端并同步给家长。',
  );

  @override
  Future<List<ReadingAvailableBook>> listAvailableBooks({String? studentId}) async =>
      throw _unavailable;

  @override
  Future<ReadingImportResult> importBook({
    required String mediaId,
    String? studentId,
    String fileName = '',
    String title = '',
  }) async =>
      throw _unavailable;

  @override
  Future<List<ReadingBook>> listBooks({String? studentId}) async => throw _unavailable;

  @override
  Future<List<ReadingLessonSummary>> listLessons({
    required String bookId,
    String? studentId,
  }) async =>
      throw _unavailable;

  @override
  Future<ReadingLesson> getLesson({
    required String bookId,
    required int lessonNo,
    String? studentId,
  }) async =>
      throw _unavailable;

  @override
  Future<List<ReadingTask>> listTasks({String? studentId}) async => throw _unavailable;

  @override
  Future<({ReadingTask task, bool created})> createTask({
    required String bookId,
    String? studentId,
  }) async =>
      throw _unavailable;

  @override
  Future<ReadingReadResult> readLesson({
    required String taskId,
    required int lessonNo,
    required String day,
    String? studentId,
  }) async =>
      throw _unavailable;

  @override
  Future<ReadingTask> cancelTask({
    required String taskId,
    String? studentId,
  }) async =>
      throw _unavailable;

  @override
  Future<ReadingLogPage> listLogs({
    String? studentId,
    String? from,
    String? to,
    int limit = 50,
    int offset = 0,
  }) async =>
      throw _unavailable;
}
