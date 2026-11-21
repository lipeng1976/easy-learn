import 'dart:async';
import 'dart:convert';

import 'package:easy_learn_app/services/bootstrap_sections.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/http_homework_repository.dart';
import 'package:easy_learn_app/services/http_notification_repository.dart';
import 'package:easy_learn_app/services/http_point_repository.dart';
import 'package:easy_learn_app/services/http_relationship_repository.dart';
import 'package:easy_learn_app/services/http_review_repository.dart';
import 'package:easy_learn_app/services/http_study_plan_repository.dart';
import 'package:easy_learn_app/services/http_wish_repository.dart';
import 'package:easy_learn_app/services/http_workout_repository.dart';
import 'package:easy_learn_app/services/read_cache.dart';
import 'package:easy_learn_app/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 首屏聚合预热（P2-2）。
///
/// ## 这个文件唯一要证明的事
///
/// 「聚合之后，首页那十几次读**一次网络都不打**」。
///
/// 它看起来像一个性能测试，其实是一条**正确性**判据 —— 因为聚合失效的方式
/// 是**完全静默的**：只要「聚合写进缓存的键」与「仓库读的时候算出来的键」
/// 差一个字符，那次读就会落空、改去打网络。界面一模一样，只是慢了十几倍，
/// 而本机（一次往返 0.2ms）连慢都看不出来。
///
/// 所以这里不比对字符串，而是**用真的仓库去打一个假服务端**：
///   · 假服务端只认 `/data/bootstrap`，其余任何请求都记下来（`unexpected`）；
///   · 每条用例结束时断言 `unexpected` 是空的。
///
/// 于是「仓库改了个路径 / 改了个查询参数 / 段名对不上」都会当场变成一条
/// 点名到路径的失败，而不是一个变慢的首页。
///
/// ⚠️ 这些用例**驱动的是真实仓库类**（`HttpXxxRepository`），不是手写的路径清单。
/// 手写清单只能证明「我以为仓库会打这个路径」，而这个文件要证明的恰恰是
/// 「仓库**真的**打了那个路径」。
void main() {
  group('预热生效：首页的读全部不打网络', () {
    test('学生端首屏的每一次读都命中聚合预热的结果', () async {
      final server = _BootServer();
      final client = _client(server);

      // 第一次读会触发聚合（它在缓存里落空 —— 冷启动就是这样）。
      final homework = HttpHomeworkRepository(client);
      await homework.queryHomework('student');
      expect(server.bootstrapCalls, 1, reason: '第一次落空时应当拉一次聚合');
      // 这一次读本身也不该单独打网络：聚合已经把它的段铺好了。
      expect(server.unexpected, isEmpty, reason: '首次读不该在聚合之外再打一次');

      await _studentFirstScreen(client);

      expect(
        server.unexpected,
        isEmpty,
        reason: '这些读全部应当由聚合预热填好；列出来的路径就是聚合没覆盖到的 —— '
            '${server.unexpected}',
      );
    });

    test('家长端首屏（含按孩子循环的两处）也在聚合里', () async {
      final server = _BootServer(children: const ['stu_1', 'stu_2']);
      final client = _client(server, userId: 'par_1', role: 'parent');

      await HttpRelationshipRepository(client).queryRelationships('par_1');
      await HttpHomeworkRepository(client).queryHomeworkByStudentIds(
        const ['stu_1', 'stu_2'],
      );

      // 家长端两处**按孩子循环**的读：这两处正是「孩子越多往返越多」的来源。
      final hwRepo = HttpHomeworkRepository(client);
      for (final child in const ['stu_1', 'stu_2']) {
        await hwRepo.queryHomeworkImages(child);
        await HttpWishRepository(client).queryPublicWishesByStudent(child);
      }
      await HttpPointRepository(client).queryPointLedger('stu_1');
      await HttpPointRepository(client).queryPointRules('stu_1');

      expect(server.bootstrapCalls, 1);
      expect(server.unexpected, isEmpty, reason: '家长端未覆盖的路径：${server.unexpected}');
    });
  });

  group('开关与降级', () {
    test('**默认关**：没打开的 client 一次聚合都不发（单测构造的 client 走这条）', () async {
      final server = _BootServer();
      final client = DataApiClient(
        config: _config,
        session: _MemorySession(token: 't', user: const {'id': 'stu_1', 'role': 'student'}),
        httpClient: server.client,
        cache: _TestCache(),
        now: () => DateTime(2026, 9, 19, 10),
      );

      await client.getJson('/data/homework');

      expect(server.bootstrapCalls, 0, reason: '默认关是一份承诺：它属于装配点');
      expect(server.unexpected, contains('/data/homework'));
    });

    test('聚合失败（服务端还没有这条路由）→ 逐条读照常成功', () async {
      final server = _BootServer()..bootstrapMissing = true;
      final client = _client(server);

      // 聚合 404 之后，这一次读必须**自己**去取，而且真的取到。
      final items = await client.getItems('/data/homework');

      expect(items, isEmpty);
      expect(server.bootstrapCalls, 1);
      expect(server.unexpected, contains('/data/homework'),
          reason: '聚合失败时正常的退路就是逐条读');
      expect(client.bootstrapStats.lastError, isNotEmpty,
          reason: '失败必须留痕：否则「聚合一直没生效」与「聚合正常」在界面上完全一样');
    });

    test('聚合失败只撞一次，不会让后续每次读都再试一遍', () async {
      final server = _BootServer()..bootstrapMissing = true;
      final client = _client(server);

      for (var i = 0; i < 5; i++) {
        await client.getJson('/data/homework');
      }

      expect(server.bootstrapCalls, 1,
          reason: '5 次读最多 1 次聚合；每读一次就撞一次的话，18 次读会变成 18 次失败请求');
    });

    test('换一个世代（写操作作废缓存）之后会重新聚合', () async {
      final server = _BootServer();
      final cache = _TestCache();
      final client = _client(server, cache: cache);

      await client.getJson('/data/homework');
      expect(server.bootstrapCalls, 1);

      // 一次写操作走的就是这条路：`postJson` 成功后调 `invalidateAll()` ——
      // 缓存清空、世代 +1。这里直接调它，免得为了造这个状态去写一个
      // 假服务端本来不支持的 POST。
      await cache.invalidateAll();
      await client.getJson('/data/homework');

      expect(server.bootstrapCalls, 2,
          reason: '写把缓存清空了，此时用一次聚合重新铺满比让接下来十几次读各打一次划算');
    });

    test('并发来的读共用一次聚合（不是各拉一次）', () async {
      final server = _BootServer()..holdBootstrap = true;
      final client = _client(server);

      // 首页那十几次读是并发来的（两个控制器各自 onInit）。
      final reads = <Future<void>>[
        client.getJson('/data/homework'),
        client.getJson('/data/workouts/plans'),
        client.getJson('/data/review/mistakes'),
        client.getJson('/data/study-plans'),
        client.getJson('/data/daily-comments'),
      ];
      // 让它们都走到「等聚合」那一步，再放行。
      await Future<void>.delayed(Duration.zero);
      server.releaseBootstrap();

      await Future.wait(reads);

      expect(server.bootstrapCalls, 1,
          reason: '没有「同一个 Future 交给所有等待者」的话，这里会是 5 次 —— '
              '把 18 次往返换成 18 次聚合，比不做还差');
      expect(server.unexpected, isEmpty);
    });
  });

  group('分段失败的如实上报', () {
    test('服务端报某段失败 → 那一段不预热，其余段照常命中', () async {
      final server = _BootServer()..failedSections = {'reviewMistakes'};
      final client = _client(server);

      await HttpHomeworkRepository(client).queryHomework('student');

      // 失败的段没被铺进缓存，所以这一次读会自己去取 —— 这正是「如实」：
      // 聚合**不假装**那一段有数据。
      await HttpReviewRepository(client).queryReviewMistakes();

      expect(server.unexpected, contains('/data/review/mistakes'));
      expect(client.bootstrapStats.failedSections, 1);
      // 其余段照常
      await HttpWorkoutRepository(client).queryWorkoutPlans();
      expect(server.unexpected, isNot(contains('/data/workouts/plans')));
    });

    test('段数对不上时统计会说话（这是「聚合悄悄失效」的唯一出口）', () async {
      final server = _BootServer()..omitSections = {'studyPlans'};
      final client = _client(server);

      await HttpHomeworkRepository(client).queryHomework('student');

      expect(
        client.bootstrapStats.seeded,
        kBootstrapSections.length - 1,
        reason: '少写了一段就该是少一段 —— 这个数字与表长度不一样时，说明两边漂了',
      );
    });
  });
}

/// 学生端首屏的全部读（与 `tools/walkthrough-cloud.mjs` 量出来的那一组同源）。
Future<void> _studentFirstScreen(DataApiClient client) async {
  await HttpHomeworkRepository(client).queryHomeworkImages('stu_1');
  await HttpWorkoutRepository(client).queryWorkoutPlans();
  await HttpWorkoutRepository(client).queryWorkoutRecords();
  await HttpReviewRepository(client).queryReviewMistakes();
  await HttpReviewRepository(client).queryReviewPapers();
  await HttpReviewRepository(client).queryReviewAttempts();
  await HttpReviewRepository(client).queryPracticeQuestions();
  await HttpReviewRepository(client).queryExplainRecords();
  await HttpReviewRepository(client).queryReviewSummaries();
  await HttpWishRepository(client).queryWishes('student');
  await HttpWishRepository(client).queryUnfulfilledWishes();
  await HttpStudyPlanRepository(client).queryStudyPlans('student');
  await HttpStudyPlanRepository(client).queryStudyPlanCheckins();
  await HttpNotificationRepository(client).queryDailyComments();
  await HttpNotificationRepository(client).queryNotifications(userId: 'stu_1');
  await HttpPointRepository(client).queryPointLedger('stu_1');
  await HttpPointRepository(client).queryPointRules('stu_1');
  await HttpRelationshipRepository(client).queryRelationships('stu_1');
}

const _config = DataConfig(
  baseUrl: 'http://127.0.0.1:8788',
  requestTimeout: Duration(seconds: 5),
);

DataApiClient _client(
  _BootServer server, {
  String userId = 'stu_1',
  String role = 'student',
  _TestCache? cache,
}) =>
    DataApiClient(
      config: _config,
      session: _MemorySession(token: 't', user: {'id': userId, 'role': role}),
      httpClient: server.client,
      cache: cache ?? _TestCache(),
      now: () => DateTime(2026, 9, 19, 10),
      // 装配点（`CloudRuntime`）就是这么打开的。
      bootstrapPrefetch: true,
    );

/// 假服务端：**只认 `/data/bootstrap`**，其余请求一律记进 [unexpected]。
///
/// 这个「一律记下来」是故意的 —— 每条用例末尾断言它是空的，
/// 于是「哪一次读没有被聚合覆盖」会变成一条点名到路径的失败。
class _BootServer {
  _BootServer({List<String> children = const ['stu_1']})
      : students = children,
        acting = children.isNotEmpty ? children.first : '';

  final List<String> students;
  final String acting;

  /// 收到的、**不是** `/data/bootstrap` 的请求路径。
  final List<String> unexpected = <String>[];

  int bootstrapCalls = 0;

  /// 让聚合回 404（模拟「服务端还是上一版，没有这条路由」）。
  bool bootstrapMissing = false;

  /// 让聚合响应挂住，直到 [releaseBootstrap] —— 用来摆出「并发」那个时序。
  bool holdBootstrap = false;
  Completer<void>? _gate;
  bool _released = false;

  /// 服务端如实上报的失败段（`failed` + 段自己的 `ok:false`）。
  Set<String> failedSections = <String>{};

  /// 服务端干脆**不带**这些段（模拟「两边段名漂了」）。
  Set<String> omitSections = <String>{};

  /// 放行聚合响应。
  ///
  /// `_released` 这个标志是必需的：放行可能发生在**请求还没到**的时候
  /// （测试里那句 `Future.delayed` 只是「多半够了」，不是保证）。
  /// 少了它，先放行的那一次会让 `_gate` 还没建就已经放掉，
  /// 于是请求永远挂在 `await _gate.future` 上 —— 表现为**测试超时**，
  /// 而这看起来像被测代码死锁，方向完全错。
  void releaseBootstrap() {
    _released = true;
    _gate?.complete();
  }

  MockClient get client => MockClient((request) async {
        final path = request.url.path;

        if (path != kBootstrapPath) {
          unexpected.add(path);
          return _envelope({'items': <Object>[]});
        }

        bootstrapCalls += 1;

        if (holdBootstrap && !_released) {
          _gate ??= Completer<void>();
          await _gate!.future;
        }

        if (bootstrapMissing) {
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'ok': false,
              'error': {'code': 'not_found', 'message': '未知端点', 'retryable': false},
            })),
            404,
          );
        }

        return _envelope(_bundle());
      });

  /// 造一份与 [kBootstrapSections]**同源**的响应。
  ///
  /// 同源是刻意的：这份载荷对着表生成，所以「表加了段而服务端没加」这类漂
  /// 不会在这里被掩盖 —— 这里要验的是客户端那一半。
  Map<String, dynamic> _bundle() {
    final sections = <String, dynamic>{};
    for (final s in kBootstrapSections) {
      if (omitSections.contains(s.name)) continue;
      final failed = failedSections.contains(s.name);

      switch (s.scope) {
        case BootstrapScope.broad:
          sections[s.name] = failed
              ? {'ok': false, 'error': {'code': 'internal', 'message': '查不动'}}
              : {'ok': true, 'items': <Object>[]};

        case BootstrapScope.perStudent:
          final buckets = <String, dynamic>{};
          for (final sid in students) {
            buckets[sid] = failed
                ? {'ok': false, 'error': {'code': 'internal', 'message': '查不动'}}
                : {'ok': true, 'items': <Object>[]};
          }
          sections[s.name] = {'ok': true, 'byStudent': buckets};

        case BootstrapScope.narrow:
          sections[s.name] = failed
              ? {'ok': false, 'error': {'code': 'internal', 'message': '查不动'}}
              : {'ok': true, 'items': <Object>[]};
      }
    }

    return {
      'actingStudentId': acting,
      'students': students,
      'sections': sections,
      'failed': failedSections.toList(),
    };
  }

  http.Response _envelope(Map<String, dynamic> data) => http.Response.bytes(
        utf8.encode(jsonEncode({'ok': true, 'data': data})),
        200,
      );
}

/// 内存会话。与 `data_api_cache_test.dart` 里那个同构（那边是私有的，
/// 跨文件用不了；将来若再出现第三个副本，就该抽到 `test/helpers/` 下了）。
class _MemorySession extends SessionStore {
  _MemorySession({String? token, Map<String, dynamic>? user})
      // ignore: prefer_initializing_formals
      : _token = token,
        // ignore: prefer_initializing_formals
        _user = user;

  String? _token;
  Map<String, dynamic>? _user;

  @override
  Future<void> initialize() async {}

  @override
  String? get token => _token;

  @override
  Map<String, dynamic>? get user => _user;

  @override
  Future<void> save({required String token, required Map<String, dynamic> user}) async {
    _token = token;
    _user = user;
  }

  @override
  Future<void> clear() async {
    _token = null;
    _user = null;
  }
}

/// 平台侧只在内存里的缓存。
class _TestCache extends BaseReadCache {
  String? platformPayload;

  @override
  Future<String?> readFromPlatform() async => platformPayload;

  @override
  Future<bool> writeToPlatform(String payload) async {
    platformPayload = payload;
    return true;
  }

  @override
  Future<void> clearPlatform() async => platformPayload = null;
}
