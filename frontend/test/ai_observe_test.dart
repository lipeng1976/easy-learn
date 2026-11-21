import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_learn_app/controllers/ai_observe_controller.dart';
import 'package:easy_learn_app/controllers/ai_status_controller.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/pages/parent/ai_observe_page.dart';
import 'package:easy_learn_app/repositories/review_repository.dart';
import 'package:easy_learn_app/services/ai_config.dart';
import 'package:easy_learn_app/services/ai_data_source.dart';
import 'package:easy_learn_app/services/ai_degradation_log.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/services/judgement_ab.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers/db_test_helper.dart';

/// 「运行观察」页。
///
/// 断言重点不是排版，而是**三块数据的诚实边界**：
/// 1. 没配网关是「本机没有云端用量」，不是错误 —— 纯本地运行是正常状态；
/// 2. 没配单价时不报数字（`null`，不是 0）；
/// 3. 成本是下限时要带「≥」号，不能被读成精确值。
///
/// 这几条正是成本看板最容易做假的地方：一个看起来精确的数字
/// 比一个诚实的空缺危险得多。
const _identity = AiIdentity(studentId: 'par_001');

/// 一个「本机库打不开」的仓储替身：只有 [queryJudgementAB] 会炸，别的方法用不到。
///
/// 它存在的理由很具体：**「本机读失败」与「本来就没有记录」在界面上长得一样**
/// （都是空的），而这两件事的处置完全相反 —— 前者要有人去修本地库，
/// 后者什么都不用做。两者混在一起时，一个坏掉的本地库会被读成「这个孩子还没练过」。
class _ExplodingReview implements ReviewRepository {
  @override
  Future<List<JudgementABRecord>> queryJudgementAB({
    String? studentId,
    String? mistakeId,
  }) async {
    throw StateError('本机库打不开');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// 一个「本机读**永远不返回**」的仓储替身。
///
/// 它记的是一次真实故障（2026-09-20 走查第 [5] 步）：本机那次读悬住了，
/// 于是云端那块**永远不会开始**，界面停在初值 spinner 上。最坏的地方不是卡住，
/// 而是它长得像「网关没通」—— 网关侧 0 请求、0 失败，所有证据都指向网络与鉴权。
class _HangingReview implements ReviewRepository {
  final Completer<void> _never = Completer<void>();

  @override
  Future<List<JudgementABRecord>> queryJudgementAB({
    String? studentId,
    String? mistakeId,
  }) async {
    await _never.future;
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

AiConfig _online() => const AiConfig(baseUrl: 'https://gw.test');

http.Response _envelope(int status, Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response _ok(Map<String, dynamic> data) => _envelope(200, {
  'ok': true,
  'data': data,
  'meta': {'requestId': 'r_test'},
});

/// 一份最小可用的网关看板响应。
Map<String, dynamic> metricsPayload({
  double? cost = 0.024,
  bool costIsLowerBound = false,
  String? costNote,
  String pricingState = 'full',
  int failed = 0,
  Map<String, int>? byCode,
}) => {
  'scope': 'instance',
  'scopeNote': '本实例自启动以来的口径。Serverless 多实例下每个实例各算一份。',
  'since': '2026-09-15T10:00:00.000Z',
  'totals': {
    'calls': 9,
    'modelCalls': 4,
    'cached': 3,
    'ruleCalls': 2,
    'failed': failed,
    'units': 14,
    'tokensIn': 4000,
    'tokensOut': 2000,
    'usageMissing': costIsLowerBound ? 1 : 0,
    'images': 1,
    'cost': cost,
  },
  'byCapability': [
    {
      'capability': 'reasoning',
      'calls': 3,
      'modelCalls': 3,
      'tokensIn': 3000,
      'tokensOut': 1500,
      'cost': 0.006,
    },
    {
      'capability': 'vision',
      'calls': 1,
      'modelCalls': 1,
      'tokensIn': 1000,
      'tokensOut': 500,
      'cost': 0.018,
    },
  ],
  'byCode': byCode ?? {},
  'latencyMs': {'samples': 4, 'p50': 120, 'p95': 480, 'max': 640},
  'pricing': {
    'state': pricingState,
    'currency': 'CNY',
    'inputPerKToken': {'reasoning': 0.001, 'vision': 0.008},
    'outputPerKToken': {'reasoning': 0.002, 'vision': 0.02},
  },
  'costIsLowerBound': costIsLowerBound,
  'costNote': costNote,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  Directory? tempDir;

  // 每个用例都要有真实库：控制器**总是**先读本机数据（一致率、降级记录），
  // 所以即使只想验云端口径也绕不开它。
  setUp(() async {
    AiDegradationLog.clear();
    tempDir = await setUpTestDatabase();
  });

  tearDown(() async {
    Get.reset();
    final dir = tempDir;
    if (dir != null) await tearDownTestDatabase(dir);
  });

  group('云端口径', () {
    test('没配网关是「本机没有云端用量」，不是错误', () async {
      var calls = 0;
      final controller = AiObserveController(
        config: const AiConfig(),
        identity: _identity,
        httpClient: MockClient((request) async {
          calls++;
          return _ok(metricsPayload());
        }),
      );

      await controller.load();

      expect(controller.cloudState.value, CloudUsageState.offline);
      expect(controller.cloudMetrics.value, isNull);
      expect(controller.cloudError.value, isEmpty);
      expect(
        calls,
        0,
        reason: '纯本地运行就该一个请求都不发 —— 这不是「失败」，是「本来就没有」',
      );
    });

    test('有网关时解析用量、成本与分档', () async {
      final controller = AiObserveController(
        config: _online(),
        identity: _identity,
        httpClient: MockClient((request) async => _ok(metricsPayload())),
      );

      await controller.load();

      expect(controller.cloudState.value, CloudUsageState.ready);
      final metrics = controller.cloudMetrics.value!;
      expect(metrics.totals.modelCalls, 4);
      expect(metrics.totals.cached, 3);
      expect(metrics.totals.ruleCalls, 2);
      // 「缓存 + 规则」= 没花模型钱但也是业务量，必须能单独读出来。
      expect(metrics.totals.freeCalls, 5);
      expect(metrics.totals.cost, 0.024);
      expect(metrics.hasCost, isTrue);
      expect(metrics.latency.p95, 480);
      expect(metrics.isInstanceScoped, isTrue);
      expect(metrics.pricing.isFull, isTrue);
    });

    test('没配单价时报「成本未知」：cost 是 null，不是 0', () async {
      final controller = AiObserveController(
        config: _online(),
        identity: _identity,
        httpClient: MockClient(
          (request) async => _ok(
            metricsPayload(
              cost: null,
              pricingState: 'none',
              costNote: '未配置模型单价（AI_PRICE_*），因此只提供用量、不估算成本。',
            ),
          ),
        ),
      );

      await controller.load();

      final metrics = controller.cloudMetrics.value!;
      expect(metrics.totals.cost, isNull);
      expect(
        metrics.hasCost,
        isFalse,
        reason: '把「不知道」压成 0 会被读成「不花钱」——这是这个页面最该防的事',
      );
      // 用量照旧要有：成本空不代表用量空。
      expect(metrics.totals.modelCalls, 4);
    });

    test('usage 缺失时成本是下限，界面要带「≥」', () async {
      final controller = AiObserveController(
        config: _online(),
        identity: _identity,
        httpClient: MockClient(
          (request) async => _ok(
            metricsPayload(
              costIsLowerBound: true,
              costNote: '有 1 次模型调用未返回 usage，成本是**下限**。',
            ),
          ),
        ),
      );

      await controller.load();

      final metrics = controller.cloudMetrics.value!;
      expect(metrics.costIsLowerBound, isTrue);
      expect(metrics.totals.usageMissing, 1);
    });

    test('401 说清是运维口令，并说明口令为什么不进客户端', () async {
      final controller = AiObserveController(
        config: _online(),
        identity: _identity,
        httpClient: MockClient(
          (request) async => _envelope(401, {
            'ok': false,
            'error': {
              'code': 'unauthorized',
              'message': '看板口令不正确（需要 X-Metrics-Token）',
              'retryable': false,
            },
          }),
        ),
      );

      await controller.load();

      expect(controller.cloudState.value, CloudUsageState.failed);
      expect(controller.cloudError.value, contains('运维口令'));
      expect(
        controller.cloudError.value,
        contains('刻意不放进客户端'),
        reason: '要让人明白「去运维侧看」是对的，而不是让人想办法把口令塞进 App',
      );
    });

    test('取不到时不留上一份旧数字', () async {
      var fail = false;
      final controller = AiObserveController(
        config: _online(),
        identity: _identity,
        httpClient: MockClient((request) async {
          if (fail) throw const SocketException('boom');
          return _ok(metricsPayload());
        }),
      );

      await controller.load();
      expect(controller.cloudMetrics.value, isNotNull);

      fail = true;
      await controller.refreshCloud();

      expect(controller.cloudState.value, CloudUsageState.failed);
      expect(
        controller.cloudMetrics.value,
        isNull,
        reason: '留着旧数字更危险：它看起来一样精确，但已经不是当下的账了',
      );
    });
  });

  group('本机那块读失败', () {
    test('本机记录读不到，不该把云端那块一起拖住', () async {
      var calls = 0;
      final controller = AiObserveController(
        config: _online(),
        identity: _identity,
        review: _ExplodingReview(),
        httpClient: MockClient((request) async {
          calls++;
          return _ok(metricsPayload());
        }),
      );

      await controller.load();

      // 这条断言是 2026-09-20 那次排查的落点：`load()` 里两块曾经是
      // 一条 `await` 链，前一块抛了后一块**永远不会执行** ——
      // 界面上表现成「云端一直转圈」，而真正坏掉的是本地读。
      expect(
        calls,
        1,
        reason: '本机读失败不是不发云端请求的理由 —— 两块的数据源根本不同',
      );
      expect(controller.cloudState.value, CloudUsageState.ready);
      expect(controller.cloudMetrics.value, isNotNull);
      expect(controller.localError.value, contains('本机记录读取失败'));
    });

    test('本机读失败的原因留在 localError，不混进 cloudError', () async {
      final controller = AiObserveController(
        config: _online(),
        identity: _identity,
        review: _ExplodingReview(),
        httpClient: MockClient((request) async => _ok(metricsPayload())),
      );

      await controller.load();

      expect(
        controller.cloudError.value,
        isEmpty,
        reason: '两块混一个字段，用户会拿着一条本机错误去查网络',
      );
      expect(controller.localError.value, contains('本机库打不开'));
    });

    testWidgets('本机读失败要在卡片上写出来，不能显示成「暂无样本」', (tester) async {      final controller = AiObserveController(
        config: const AiConfig(),
        identity: _identity,
        review: _ExplodingReview(),
      );
      await tester.runAsync(() => controller.load());

      await tester.pumpWidget(
        GetMaterialApp(home: AiObservePage(controller: controller)),
      );
      await tester.pump();

      expect(find.textContaining('本机记录读取失败'), findsOneWidget);
      expect(
        find.textContaining('暂无样本'),
        findsNothing,
        reason: '「读失败」与「本来就没有记录」处置相反：前者要去修本地库，后者什么都不用做',
      );
    });

    test('本机读**悬住**时，云端那块照旧发起请求', () async {
      var calls = 0;
      final controller = AiObserveController(
        config: _online(),
        identity: _identity,
        review: _HangingReview(),
        localReadTimeout: const Duration(milliseconds: 40),
        httpClient: MockClient((request) async {
          calls++;
          return _ok(metricsPayload());
        }),
      );

      await controller.load();

      // 这条是 2026-09-20 那次排查的落点。串行版本里本机那块一悬住，
      // 云端那块就**永远不会开始**，而它的界面停在初值 `loading` 上 ——
      // 现场是「转圈的卡片 + 网关 0 请求 + 0 失败」，每一条证据都指向网关，
      // 而网关根本没被问过。
      expect(calls, 1, reason: '两块的数据源不同，没有任何理由让一块等另一块');
      expect(controller.cloudState.value, CloudUsageState.ready);
    });

    test('本机读悬住时要如实说「超时」，不能让人读成「没有记录」', () async {
      final controller = AiObserveController(
        config: const AiConfig(),
        identity: _identity,
        review: _HangingReview(),
        localReadTimeout: const Duration(milliseconds: 40),
      );

      await controller.load();

      expect(controller.localError.value, contains('超时'));
      // 「一直没返回」与「没有记录」在界面上同形，而处置相反：
      // 前者要去修本机库/存储，后者什么都不用做。所以必须说出来。
      expect(
        controller.localError.value,
        contains('不是「没有记录」'),
        reason: '光说「超时」还不够，要明确否掉那个更容易被接受的解释',
      );
    });
  });

  group('降级记录', () {
    test('降级写进进程级日志，横幅消失后仍查得到', () async {
      final status = AiStatusController(
        autoHideAfter: const Duration(milliseconds: 10),
      );
      status.report(
        AiDegradation(
          operation: 'judgeAnswer',
          reason: '请求超时（12s）',
          code: 'timeout',
          at: DateTime(2026, 9, 15, 10),
        ),
      );

      // 横幅是短命的：超时后 latest 归零。
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(status.latest.value, isNull);

      expect(AiDegradationLog.count, 1, reason: '「刚才降过几次」要活得比横幅久');
      expect(AiDegradationLog.events.first.code, 'timeout');

      final controller = AiObserveController(
        config: const AiConfig(),
        identity: _identity,
      );
      await controller.load();
      expect(controller.degradations.length, 1);
    });

    test('清空只清本机视图，不动累计次数', () async {
      final status = AiStatusController();
      status.report(
        AiDegradation(
          operation: 'checkHomework',
          reason: '模型未开通',
          code: 'model_not_enabled',
          at: DateTime(2026, 9, 15, 10),
        ),
      );

      final controller = AiObserveController(
        config: const AiConfig(),
        identity: _identity,
      );
      await controller.load();
      controller.clearDegradations();

      expect(controller.degradations, isEmpty);
      expect(AiDegradationLog.count, 0);
      expect(
        status.totalCount.value,
        1,
        reason: '「我知道了」不等于「这件事没发生过」',
      );
    });
  });

  group('一致率接进页面', () {
    test('按孩子取一致率，空数据时是「暂无样本」而不是 0%', () async {
      await DatabaseService.instance.insertJudgementABRecords([
        JudgementABRecord(
          id: 'ab_1',
          studentId: 'stu_001',
          mistakeId: 'rm_1',
          channel: AttemptChannel.paper,
          subject: '数学',
          knowledgePoint: '分数比较',
          modelVerdict: AnswerVerdict.correct,
          ruleVerdict: AnswerVerdict.correct,
          createdAt: DateTime(2026, 9, 15, 10),
        ),
        JudgementABRecord(
          id: 'ab_2',
          studentId: 'stu_001',
          mistakeId: 'rm_1',
          channel: AttemptChannel.paper,
          subject: '数学',
          knowledgePoint: '分数比较',
          modelVerdict: AnswerVerdict.correct,
          ruleVerdict: AnswerVerdict.wrong,
          createdAt: DateTime(2026, 9, 15, 11),
        ),
      ]);

      final controller = AiObserveController(
        config: const AiConfig(),
        identity: _identity,
      );
      await controller.load();

      // 没选孩子时是全量；这里只有一个孩子，所以结果一致。
      expect(controller.consistency.value.compared, 2);
      expect(controller.consistency.value.agree, 1);
      expect(controller.consistency.value.consistencyRate, 0.5);

      await controller.selectStudent('stu_002');
      expect(controller.consistency.value.total, 0);
      expect(
        controller.consistency.value.consistencyRate,
        isNull,
        reason: '另一个孩子没有样本时必须是「无」，不能显示 0%',
      );
      expect(controller.consistency.value.isEmpty, isTrue);
    });
  });

  group('页面', () {
    // 注意：`testWidgets` 的函数体跑在**假时钟**里，真实异步 I/O（SQLite FFI）
    // 在里面永远不会完成 —— 直接 `await controller.load()` 会挂死整个文件。
    // 所以载入必须放进 `tester.runAsync`，那段是真时钟。
    testWidgets('离线时显示「本机没有云端用量」，且没有错误色', (tester) async {
      final controller = AiObserveController(
        config: const AiConfig(),
        identity: _identity,
      );
      await tester.runAsync(() => controller.load());

      await tester.pumpWidget(
        GetMaterialApp(home: AiObservePage(controller: controller)),
      );
      await tester.pump();

      expect(find.textContaining('本机没有云端用量'), findsOneWidget);
      // 断言「不产生任何费用」这句：它才是这块要传达的结论。
      // 用更短的「纯本地运行」会同时命中一致率卡片的说明文字 ——
      // 断言太松时，它匹配到别处也照样通过。
      expect(find.textContaining('不产生任何费用'), findsOneWidget);
      // 纯本地是正常状态，不该出现「重试」按钮 —— 那会暗示它出了问题。
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('成本未知时不显示 0，而是给出原因', (tester) async {
      final controller = AiObserveController(
        config: _online(),
        identity: _identity,
        httpClient: MockClient(
          (request) async => _ok(
            metricsPayload(
              cost: null,
              pricingState: 'none',
              costNote: '未配置模型单价（AI_PRICE_*），因此只提供用量、不估算成本。',
            ),
          ),
        ),
      );
      await tester.runAsync(() => controller.load());

      await tester.pumpWidget(
        GetMaterialApp(home: AiObservePage(controller: controller)),
      );
      await tester.pump();

      expect(find.textContaining('未配置模型单价'), findsWidgets);
      expect(find.textContaining('0.0000'), findsNothing);
    });

    testWidgets('成本是下限时显示「≥」号', (tester) async {
      final controller = AiObserveController(
        config: _online(),
        identity: _identity,
        httpClient: MockClient(
          (request) async => _ok(metricsPayload(costIsLowerBound: true)),
        ),
      );
      await tester.runAsync(() => controller.load());

      await tester.pumpWidget(
        GetMaterialApp(home: AiObservePage(controller: controller)),
      );
      await tester.pump();

      expect(
        find.textContaining('≥ 0.0240'),
        findsOneWidget,
        reason: '「≥」必须出现在数字前面 —— 只写进小字说明里会被跳过',
      );
    });
  });
}
