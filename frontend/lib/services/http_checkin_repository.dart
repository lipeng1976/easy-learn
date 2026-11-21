import '../models/checkin_models.dart';
import '../repositories/checkin_repository.dart';
import 'data_api_client.dart';

/// 打卡的 HTTP 实现（走 `/data/checkin/*`）。
///
/// 出题也在服务端（`POST /data/checkin/generate`），客户端只负责
/// 「发起 / 取 / 交卷」三件事。题目是**带答案**回来的：交卷时本机会
/// 立刻判对错，不等这一趟网络。答题界面不渲染答案（见 `CheckinQuestion.answer`）。
class HttpCheckinRepository implements CheckinRepository {
  const HttpCheckinRepository(this._api);

  final DataApiClient _api;

  /// 出题的等待上限。
  ///
  /// 服务端要「查错题 → 调网关 → 落库」，实测 5 秒上下（缓存命中 0.1 秒），
  /// 冷启动更久。客户端必须比服务端等得久：12 秒默认值下，服务端可能
  /// **已经把题存好了**而客户端先报超时，用户点重试又生成一份覆盖掉 ——
  /// 明明成功却显示失败，是最难解释的一类故障。
  static const Duration generateTimeout = Duration(seconds: 45);

  @override
  Future<CheckinQuizPage> getQuizzes({
    String? studentId,
    CheckinQuizStatus status = CheckinQuizStatus.all,
    String subject = '',
    int limit = 0,
    int offset = 0,
  }) async {
    final data = await _api.getJson(
      '/data/checkin/quiz',
      query: {
        if (studentId != null && studentId.isNotEmpty) 'studentId': studentId,
        // 不传 quizDate：跨天。老服务端（不认 status）会退回「今天的全部」，
        // 那种组合下页面只会少看到东西、不会看到错的 —— 可以接受。
        if (status != CheckinQuizStatus.all) 'status': status.wire,
        // 空串不发：老服务端不认这个参数，发了也只是被忽略，但日志里会多出
        // 一条看起来像「按空科目过滤」的记录，排查时误导人。
        if (subject.isNotEmpty) 'subject': subject,
        if (limit > 0) 'limit': '$limit',
        if (offset > 0) 'offset': '$offset',
      },
    );
    final raw = data['quizzes'];
    // `quizzes: []` 是「还没有打卡」，不是错误。把它当异常会让页面
    // 一进来就显示红色报错，而其实什么都没坏。
    final items = raw is List
        ? [
            for (final item in raw)
              if (item is Map) _parseEntry(Map<String, dynamic>.from(item)),
          ]
        : const <CheckinQuiz>[];
    // `total` 缺失时退化成「本页条数」：老服务端只回 quizzes，
    // 那种情况下 hasMore 必然是 false（一次拿全），别让它变成 true 让
    // 页面去请求一个不存在的第二页。
    final total = data['total'] is num ? (data['total'] as num).toInt() : items.length;
    return CheckinQuizPage(
      items: items,
      total: total,
      hasMore: data['hasMore'] == true,
    );
  }

  /// 每科已交卷的份数与最近一次成绩。
  ///
  /// 分页页面上显示「数学 12 份」时数字必须是真数 —— 见
  /// [CheckinSubjectSummary] 的说明。服务端一次 `group by` 回来，
  /// 不含题目，所以这个请求很轻。
  @override
  Future<List<CheckinSubjectSummary>> subjectSummaries({String? studentId}) async {
    final data = await _api.getJson(
      '/data/checkin/summary',
      query: {
        if (studentId != null && studentId.isNotEmpty) 'studentId': studentId,
      },
    );
    final raw = data['subjects'];
    // 一份都没交过 = 空列表，不是错误（页面照常渲染「还没有完成的打卡」）。
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) CheckinSubjectSummary.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  /// 一条 `{quiz, result}` 记录 → 题目快照（已交卷时挂上存档结果）。
  CheckinQuiz _parseEntry(Map<String, dynamic> entry) {
    final quizMap = entry['quiz'];
    if (quizMap is! Map) {
      throw const DataApiException(
        code: 'bad_response',
        message: '打卡记录里没有 quiz 字段',
      );
    }
    final parsed = CheckinQuiz.fromJson(Map<String, dynamic>.from(quizMap));

    // 已经交过卷时把结果挂上去：家长打开能看到分数与逐题明细，
    // 学生也不会把同一份题再答一遍。
    // 服务端从 2026-10-27 起在 result 里返回派生的逐题明细（items），
    // 这里原样透传 —— 不再像以前那样硬给空列表。
    final answered = entry['result'];
    if (answered is Map) {
      return parsed.copyWith(
        submittedResult: CheckinSubmitResult.fromJson(
          {...Map<String, dynamic>.from(answered), 'quizId': parsed.id},
        ),
      );
    }
    return parsed;
  }

  @override
  Future<List<CheckinSeed>> loadSeeds({String? studentId, String? subject}) async {
    final data = await _api.getJson(
      '/data/checkin/seeds',
      query: {
        if (studentId != null && studentId.isNotEmpty) 'studentId': studentId,
        if (subject != null && subject.isNotEmpty) 'subject': subject,
      },
    );
    final raw = data['seeds'];
    // 没有错题 = 空列表，不是错误：家长打开配置页时错题本可能还是空的，
    // 那时该显示「先录错题，或者直接输入要练的知识点」。
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) CheckinSeed.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  @override
  Future<CheckinQuiz> generate({
    String? studentId,
    required String quizDate,
    String subject = '数学',
    int count = 5,
    List<String> knowledgePoints = const [],
    String difficulty = '',
  }) async {
    final data = await _api.postJson(
      '/data/checkin/generate',
      body: {
        if (studentId != null && studentId.isNotEmpty) 'studentId': studentId,
        'quizDate': quizDate,
        'subject': subject,
        'count': count,
        // 空数组 / 空串**不发**：用不到的字段不进请求体，
        // 服务端日志读起来才不会像「家长选了 0 个知识点」。
        if (knowledgePoints.isNotEmpty) 'knowledgePoints': knowledgePoints,
        if (difficulty.isNotEmpty) 'difficulty': difficulty,
      },
      timeout: generateTimeout,
    );
    final quiz = data['quiz'];
    if (quiz is! Map) {
      throw const DataApiException(
        code: 'bad_response',
        message: '服务端没有返回打卡内容（出题接口必须回被采纳的那一行）',
      );
    }
    return CheckinQuiz.fromJson(Map<String, dynamic>.from(quiz));
  }

  @override
  Future<CheckinSubmitResult> submit({
    required String quizId,
    required Map<int, String> picked,
  }) async {
    final data = await _api.postJson(
      '/data/checkin/submit',
      body: {
        'quizId': quizId,
        'answers': [
          for (final entry in picked.entries) {'index': entry.key, 'picked': entry.value},
        ],
      },
    );
    return CheckinSubmitResult.fromJson(data);
  }
}

/// 纯本地模式：没有云端就没有「题目快照」，打卡不可用。
///
/// 明确抛错而不是返回空：返回空会让界面显示「今天还没发起」，
/// 于是家长会一直点「发起」—— 那个按钮永远不会成功，且没有任何解释。
///
/// 出题**也**不可用（不是「本地也能出」）：答案必须在服务端生成。
/// 本地出题等于把答案放到孩子手边，那正是这次改造要堵掉的东西。
class UnavailableCheckinRepository implements CheckinRepository {
  const UnavailableCheckinRepository();

  static const DataApiException _unavailable = DataApiException(
    code: 'unavailable',
    message: '当前是本地模式，打卡需要联网；联网版里这道题会存到云端并同步给家长。',
  );

  @override
  Future<CheckinQuizPage> getQuizzes({
    String? studentId,
    CheckinQuizStatus status = CheckinQuizStatus.all,
    String subject = '',
    int limit = 0,
    int offset = 0,
  }) async {
    throw _unavailable;
  }

  @override
  Future<List<CheckinSubjectSummary>> subjectSummaries({String? studentId}) async {
    throw _unavailable;
  }

  @override
  Future<List<CheckinSeed>> loadSeeds({String? studentId, String? subject}) async {
    throw _unavailable;
  }

  @override
  Future<CheckinQuiz> generate({
    String? studentId,
    required String quizDate,
    String subject = '数学',
    int count = 5,
    List<String> knowledgePoints = const [],
    String difficulty = '',
  }) async {
    throw _unavailable;
  }

  @override
  Future<CheckinSubmitResult> submit({
    required String quizId,
    required Map<int, String> picked,
  }) async {
    throw _unavailable;
  }
}
