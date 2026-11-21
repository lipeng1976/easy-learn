import 'dart:async';
import 'dart:convert';

import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/data_staleness_log.dart';
import 'package:easy_learn_app/services/read_cache.dart';
import 'package:easy_learn_app/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 真机上报的那一类失败（2026-09-25）：**偶发的连接被掐断**。
///
/// ## 现象与它为什么难查
///
/// 学生登录后首屏弹一条横幅，文案里嵌着
/// `ClientException: Software caused connection abort, uri=https://…/data/study-plans`，
/// 而**后面所有功能都正常**。三个特征叠在一起：
///
///   · 它不是超时（超时会是 `TimeoutException`），所以「慢」这条线整个是错的；
///   · 它**偶发** —— 拿单次手测当判据，两次结果能完全相反（见下）；
///   · 它**自己会好**，所以「重试一下就好了」这件事从来没被写进代码。
///
/// 实测（`build/probe-concurrency-scan.mjs` 对云端真打 186 次）才把触发条件
/// 收窄到一格：**复用连接 + 并发 ≥8**。每次新建连接那 93 次全过。
///
/// ## 这里钉的两件事
///
/// 1. **GET 瞬时失败重试一次**，POST 不重试（写不幂等）；
/// 2. **横幅只说人话** —— 底层异常原文与 URL 一个字都不许进去。
///
/// 第 2 条不是审美问题：`photo_failure_reason_test.dart` 早就为照片那条路
/// 立过同一条规矩（「取不到原因时不许编：只说张数，不带内部错误文本」），
/// 横幅这条路上漏了。
void main() {
  setUp(DataStalenessLog.clear);

  group('瞬时连接被掐断：GET 重试一次', () {
    test('第一次断、第二次通 → 读成功，且**不给用户看任何提示**', () async {
      final server = _Server(failFirstGets: 1, payload: {'items': [{'id': 'v1'}]});
      final client = _client(server, cache: null);

      final data = await client.getJson('/data/homework');

      expect((data['items'] as List).first['id'], 'v1');
      expect(server.getCalls, 2,
          reason: '第一次断了、第二次救回来 —— 这就是重试的全部意义');
      expect(DataStalenessLog.count, 0,
          reason: '这次读**成功了**。成功还给用户弹「连不上」，就是拿事故的语气报平安');
    });

    test('两次都断 → 如实抛 network，且**只重试一次**（不是重试到成功为止）', () async {
      final server = _Server(failFirstGets: 99);
      final client = _client(server, cache: null);

      await expectLater(
        client.getJson('/data/homework'),
        throwsA(isA<DataApiException>()
            .having((e) => e.code, 'code', 'network')
            .having((e) => e.isOffline, 'isOffline', isTrue)),
      );

      expect(server.getCalls, 2,
          reason: '重试次数必须封顶。不封顶的话，服务端真的挂了会让每个读都变成无限重试');
    });

    test('反面：POST **不**重试 —— 写不幂等，盲重试会插出两条', () async {
      final server = _Server(failFirstPosts: 99);
      final client = _client(server, cache: null);

      await expectLater(
        client.postJson('/data/workouts/records', body: {'minutes': 30}),
        throwsA(isA<DataApiException>()),
      );

      expect(server.postCalls, 1,
          reason: '「其实成功了但响应没回来」那一次会变成两条记录；'
              '运动记录按天去重，插出两条等于改掉「今天跑了几次」');
    });

    test('反面：业务拒绝（403）不重试 —— 重试一百次也不会变成你的', () async {
      final server = _Server(status: 403);
      final client = _client(server, cache: null);

      await expectLater(
        client.getJson('/data/homework'),
        throwsA(isA<DataApiException>()
            .having((e) => e.code, 'code', 'forbidden')),
      );

      expect(server.getCalls, 1, reason: '权限问题重试没有意义，只会白等一个往返');
    });

    test('反面：超时**不**重试 —— 重试只会把等待翻倍', () async {
      final server = _Server()..gate = Completer<void>();
      addTearDown(() {
        if (!server.gate!.isCompleted) server.gate!.complete();
      });
      final client = _client(
        server,
        cache: null,
        timeout: const Duration(milliseconds: 60),
      );

      await expectLater(
        client.getJson('/data/homework'),
        throwsA(isA<DataApiException>()
            .having((e) => e.code, 'code', 'timeout')),
      );

      expect(server.getCalls, 1,
          reason: '服务端慢的时候重试，是把「等 10 秒」变成「等 20 秒」—— '
              '比直接如实失败更坏，而且掩盖了服务端的问题');
    });
  });

  group('横幅是给人看的，不是给开发者看的', () {
    test('底层异常原文、URL、英文类名**一个字都不许进横幅**', () async {
      final server = _Server(failFirstGets: 99);
      final client = _client(server, cache: _TestCache());

      await expectLater(
        client.getJson('/data/homework'),
        throwsA(isA<DataApiException>()),
      );

      final reason = DataStalenessLog.latest!.reason;
      expect(reason, '网络不可用，请检查网络后重试，界面显示的是上一次同步下来的内容。',
          reason: '精确到整句：改回 \${e.message} 会立刻把这一条顶红');
      for (final leak in [
        'ClientException',
        'Software caused connection abort',
        'https://',
        'http://',
        '127.0.0.1',
      ]) {
        expect(reason, isNot(contains(leak)),
            reason: '「$leak」漏进了用户可见的文案 —— '
                '用户从这句话里得不到任何能据以行动的信息');
      }
    });

    test('写没保存那条横幅同理（两处是同一个错，只修一处等于没修）', () async {
      final server = _Server(failFirstPosts: 99);
      final client = _client(server, cache: _TestCache());

      await expectLater(
        client.postJson('/data/homework/update', body: {'status': 'done'}),
        throwsA(isA<DataApiException>()),
      );

      final event = DataStalenessLog.latest!;
      expect(event.kind, DataStalenessKind.writeDropped);
      expect(event.reason, '网络不可用，请检查网络后重试，这次修改没有保存到云端。');
      expect(event.reason, isNot(contains('ClientException')));
      expect(event.reason, isNot(contains('http://')));
    });
  });

  group('userMessage：谁能直接展示', () {
    test('本地生成的两个 code 给中文；服务端回的原文照旧可展示', () {
      expect(
        const DataApiException(
          code: 'network',
          message: '连不上数据服务（http://x/data/a）：ClientException: boom',
        ).userMessage,
        '网络不可用，请检查网络后重试',
      );
      expect(
        const DataApiException(
          code: 'timeout',
          message: '数据服务 10 秒没有响应（http://x/data/a）',
        ).userMessage,
        '网络较慢或服务繁忙，请稍后重试',
      );
      // 服务端回的业务文案本来就该原样给用户 —— 换掉它等于丢掉原因。
      expect(
        const DataApiException(code: 'forbidden', message: '这不是你的').userMessage,
        '这不是你的',
      );
      expect(
        const DataApiException(code: 'token_invalid', message: '凭证已失效，请重新登录')
            .userMessage,
        '凭证已失效，请重新登录',
      );
    });
  });
}

final _config = DataConfig(
  baseUrl: 'http://127.0.0.1:8788',
  requestTimeout: const Duration(seconds: 5),
);

DataApiClient _client(
  _Server server, {
  required ReadCache? cache,
  Duration? timeout,
}) =>
    DataApiClient(
      config: timeout == null ? _config : _config.copyWith(requestTimeout: timeout),
      session: _MemorySession(
        token: 't',
        user: {'id': 'stu_1', 'role': 'student'},
      ),
      httpClient: server.client,
      cache: cache,
      now: () => DateTime(2026, 9, 25, 10),
    );

/// 假服务端：能数请求、能「前 N 次抛异常」、能挂起、能被拒。
class _Server {
  _Server({
    this.failFirstGets = 0,
    this.failFirstPosts = 0,
    this.status = 200,
    this.payload,
  });

  /// 前 N 次 **GET** 抛 `ClientException`。数的是「第几次」，不是布尔 ——
  /// 布尔只能表达「一直坏」，而这里真正要验的是「坏一次之后好起来」。
  final int failFirstGets;
  final int failFirstPosts;
  final int status;
  final Map<String, dynamic>? payload;

  /// 非 null 时请求挂在这里 —— 用来把「超时」摆出来（超时**不**重试）。
  Completer<void>? gate;

  final List<String> calls = [];
  int _gets = 0;
  int _posts = 0;

  int get getCalls => calls.where((c) => c.startsWith('GET')).length;
  int get postCalls => calls.where((c) => c.startsWith('POST')).length;

  MockClient get client => MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        final isGet = request.method == 'GET';
        final seen = isGet ? ++_gets : ++_posts;
        final threshold = isGet ? failFirstGets : failFirstPosts;

        if (seen <= threshold) {
          // ⚠️ 逐字复刻真机上报的那一条，而不是自己编一个 `boom`：
          // 判据要盯的是**真实文本**有没有漏进界面，编一个就测不出来。
          throw http.ClientException(
            'Software caused connection abort',
            request.url,
          );
        }

        final currentGate = gate;
        if (currentGate != null) await currentGate.future;

        final ok = status == 200;
        return http.Response.bytes(
          utf8.encode(jsonEncode(<String, dynamic>{
            'ok': ok,
            if (ok) 'data': payload ?? {'items': <Object>[]},
            if (!ok)
              'error': {'code': 'forbidden', 'message': '这不是你的', 'retryable': false},
          })),
          status,
        );
      });
}

class _MemorySession extends SessionStore {
  _MemorySession({String? token, Map<String, dynamic>? user})
      : _token = token,
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
  Future<void> save({
    required String token,
    required Map<String, dynamic> user,
  }) async {
    _token = token;
    _user = user;
  }

  @override
  Future<void> clear() async {
    _token = null;
    _user = null;
  }
}

/// 平台侧只在内存里的缓存（与 `data_api_cache_test.dart` 里那个同构）。
///
/// 这里**刻意留着**：横幅那条判据要求走在 `_readWithCache` 里——
/// `cache == null` 的那条快路是 `return _send(...)`，它**不经过**
/// `_reportStaleRead`，于是「文案里有没有漏异常」根本不会被执行到。
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
