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

/// 读缓存接进传输层之后的行为（迁移计划 §7 方案 B）。
///
/// 这里最有价值的两条是**不看不知道**的：
///
/// - 「写成功之后下一次读必须打到网络」。它看起来显然，但缓存是整体作废的，
///   而作废发生在 `postJson` 成功之后、由传输层自己触发 —— 一旦有人把它挪到
///   调用方去记，几十个写调用点里漏掉任何一个都会表现为「改完了但看到的还是旧的」。
/// - 「写之前发起的后台刷新不得回写」。这条**没有真跑就发现不了**：
///   它只在「读命中过期缓存 → 用户在这期间完成一次写 → 刷新才返回」这个
///   时序下出现，而本机演示时那个窗口只有几毫秒宽。症状是
///   「改完刷新一下又变回去了」。
void main() {
  setUp(DataStalenessLog.clear);
  tearDown(DataStalenessLog.clear);

  group('没装配缓存时行为不变', () {
    test('每次读都打网络（本地模式走的就是这条路）', () async {
      final server = _Server();
      final client = _client(server, cache: null);

      await client.getJson('/data/homework');
      await client.getJson('/data/homework');

      expect(server.getCalls, 2);
    });
  });

  group('在线：缓存优先', () {
    test('TTL 内第二次读直接用缓存，不再打网络', () async {
      final server = _Server();
      final cache = _TestCache();
      final client = _client(server, cache: cache);

      final first = await client.getJson('/data/homework');
      server.payload = {'items': [{'id': 'changed'}]};
      final second = await client.getJson('/data/homework');

      expect(server.getCalls, 1);
      expect(second['items'], first['items'], reason: 'TTL 内应当就是缓存那一份');
      expect(cache.stats.hits, 1);
    });

    test('TTL 外先给缓存、再后台刷新，下一次读拿到新的', () async {
      final server = _Server(payload: {'items': [{'id': 'v1'}]});
      final clock = _Clock(DateTime(2026, 9, 19, 10));
      final cache = _TestCache(clock: clock);
      final client = _client(server, cache: cache, clock: clock);

      await client.getJson('/data/homework'); // 写入 v1

      // 服务端已经有新数据了，但客户端还没到过期点。
      server.payload = {'items': [{'id': 'v2'}]};
      clock.value = clock.value.add(const Duration(seconds: 20));

      final stale = await client.getJson('/data/homework');
      expect((stale['items'] as List).first['id'], 'v1',
          reason: '过期的那一次必须**先把手里的给出去** —— 断网可用全靠这一条');

      await pumpEventQueue(); // 让后台刷新跑完
      expect(server.getCalls, 2, reason: '后台那次刷新是真的发出去了');

      final fresh = await client.getJson('/data/homework');
      expect((fresh['items'] as List).first['id'], 'v2');
      expect(server.getCalls, 2, reason: '刷新已经更新了缓存，这一次不必再打网络');
    });
  });

  group('写：成功即作废', () {
    test('写成功之后下一次读打到网络，并拿到新数据', () async {
      final server = _Server(payload: {'items': [{'id': 'v1'}]});
      final cache = _TestCache();
      final client = _client(server, cache: cache);

      await client.getJson('/data/homework');
      server.payload = {'items': [{'id': 'v2'}]};

      await client.postJson('/data/homework/update', body: {'id': 'x'});
      await pumpEventQueue();

      final after = await client.getJson('/data/homework');
      expect((after['items'] as List).first['id'], 'v2');
      expect(server.getCalls, 2);
    });

    test('**写之前发起的后台刷新不得回写**（世代校验）', () async {
      final server = _Server(payload: {'items': [{'id': 'v1'}]});
      final clock = _Clock(DateTime(2026, 9, 19, 10));
      final cache = _TestCache(clock: clock);
      final client = _client(server, cache: cache, clock: clock);

      await client.getJson('/data/homework');
      clock.value = clock.value.add(const Duration(seconds: 20));

      // 这一次读触发后台刷新，而刷新**挂住不返回** —— 模拟慢网络。
      server.gate = Completer<void>();
      final stale = await client.getJson('/data/homework');
      expect((stale['items'] as List).first['id'], 'v1');

      // 刷新还挂在网络上时，用户完成了一次写。
      await client.postJson('/data/homework/update', body: {'id': 'x'});
      await pumpEventQueue();

      // 现在才放刷新回来。它手里是**写之前**的数据。
      server.payload = {'items': [{'id': '写之前的旧数据'}]};
      server.gate!.complete();
      await pumpEventQueue();
      server.gate = null;

      // 关键断言：缓存里不能有它写回来的东西。
      final key = cache.keys.isEmpty ? null : cache.keys.first;
      final cached = key == null ? null : cache.lookup(key);
      expect(cached, isNull,
          reason: '写之后缓存必须是空的 —— 回写会让用户「改完又变回去」');

      // 而且下一次读必须打到网络。
      server.payload = {'items': [{'id': 'v3'}]};
      final after = await client.getJson('/data/homework');
      expect((after['items'] as List).first['id'], 'v3');
    });
  });

  group('离线：两条可见的降级', () {
    test('有缓存时返回缓存，并记一条 staleRead', () async {
      final server = _Server(payload: {'items': [{'id': 'v1'}]});
      final clock = _Clock(DateTime(2026, 9, 19, 10));
      final cache = _TestCache(clock: clock);
      final client = _client(server, cache: cache, clock: clock);

      await client.getJson('/data/homework');
      clock.value = clock.value.add(const Duration(seconds: 20));
      server.offline = true;

      final data = await client.getJson('/data/homework');

      expect((data['items'] as List).first['id'], 'v1',
          reason: '这就是方案 B 相对纯在线的全部价值：断网时不是空列表');
      await pumpEventQueue(); // 后台刷新失败后才会记那一条

      expect(DataStalenessLog.count, 1);
      expect(DataStalenessLog.latest!.kind, DataStalenessKind.staleRead);
    });

    test('没有缓存时如实抛错（编一个比报错更坏）', () async {
      final server = _Server()..offline = true;
      final cache = _TestCache();
      final client = _client(server, cache: cache);

      await expectLater(
        client.getJson('/data/homework'),
        throwsA(isA<DataApiException>()
            .having((e) => e.code, 'code', 'network')
            .having((e) => e.isOffline, 'isOffline', isTrue)),
      );
      expect(DataStalenessLog.latest!.kind, DataStalenessKind.staleRead);
    });

    test('写离线失败 → 记一条 writeDropped 并照常抛出', () async {
      final server = _Server()..offline = true;
      final client = _client(server, cache: _TestCache());

      await expectLater(
        client.postJson('/data/homework/update', body: {}),
        throwsA(isA<DataApiException>()),
      );

      expect(DataStalenessLog.latest!.kind, DataStalenessKind.writeDropped,
          reason: '方案 B 的「写必须在线」靠这条才成立 —— 否则写会悄悄丢掉');
    });

    test('非离线的写失败**不**上报（那是业务错误，调用方自己处理）', () async {
      final server = _Server()..rejection = {'code': 'forbidden', 'message': '这不是你的'};
      final client = _client(server, cache: _TestCache());

      await expectLater(
        client.postJson('/data/homework/update', body: {}),
        throwsA(isA<DataApiException>()),
      );

      expect(DataStalenessLog.count, 0);
    });
  });

  group('不缓存的那些读', () {
    test('认证端点永远真打网络（它是验证，不是数据）', () async {
      final server = _Server(payload: {'user': {'id': 'u1'}});
      final client = _client(server, cache: _TestCache());

      await client.getJson('/auth/me');
      await client.getJson('/auth/me');

      expect(server.getCalls, 2,
          reason: '用缓存回答「这个 token 还算数吗」等于没验证 —— '
              '被吊销的 token 会让用户进入已登录状态，直到第一次业务请求才失败');
    });

    test('拿不到身份时不缓存（宁可不缓存，也不能串数据）', () async {
      final server = _Server();
      final client = DataApiClient(
        config: _config,
        session: _MemorySession(), // 没有 token / user
        httpClient: server.client,
        cache: _TestCache(),
        now: () => DateTime(2026, 9, 19, 10),
      );

      await client.getJson('/data/homework');
      await client.getJson('/data/homework');

      expect(server.getCalls, 2);
    });

    test('同一台设备换账号，不会读到上一个人的缓存', () async {
      final server = _Server(payload: {'items': [{'id': '孩子的数据'}]});
      final cache = _TestCache();
      final session = _MemorySession(user: {'id': 'stu_1', 'role': 'student'});
      final client = DataApiClient(
        config: _config,
        session: session,
        httpClient: server.client,
        cache: cache,
        now: () => DateTime(2026, 9, 19, 10),
      );

      await client.getJson('/data/homework');

      // 同一个 App、同一个缓存文件，换了个人登录。
      session.userOverride = {'id': 'par_1', 'role': 'parent'};
      server.payload = {'items': [{'id': '家长看到的数据'}]};
      final after = await client.getJson('/data/homework');

      expect(server.getCalls, 2, reason: '身份变了就是另一个键，必须重新读');
      expect((after['items'] as List).first['id'], '家长看到的数据');
    });
  });

  group('凭证失效', () {
    test('token 被拒时连缓存一起清掉', () async {
      final server = _Server(payload: {'items': [{'id': 'v1'}]});
      final clock = _Clock(DateTime(2026, 9, 19, 10));
      final cache = _TestCache(clock: clock);
      final session = _MemorySession(
        token: 'bad',
        user: {'id': 'stu_1', 'role': 'student'},
      );
      final client = DataApiClient(
        config: _config,
        session: session,
        httpClient: server.client,
        cache: cache,
        now: () => clock.value,
      );

      await client.getJson('/data/homework');
      expect(cache.keys, isNotEmpty);

      server.rejection = {'code': 'token_invalid', 'message': '凭证已失效'};
      // 要让它真的打一次网络：TTL 内的缓存会把它挡住，
      // 而这里验的正是「打到网络之后被拒」那一支。
      clock.value = clock.value.add(const Duration(seconds: 20));
      await client.getJson('/data/homework');
      await pumpEventQueue();

      // 注意这一支**不会抛给调用方**：读命中了缓存，先给出去的是一份旧数据，
      // 而 403 是后台刷新拿到的。这是读缓存固有的性质 —— 代价由
      // 「下一次进首页时 AuthController 看到没有身份、走登录页」兜住。
      expect(cache.keys, isEmpty,
          reason: '凭证没了，缓存里那份是按上一个身份存的，跟着作废');
      expect(session.token, isNull,
          reason: '顺带把本地凭证也清掉，下一次进首页走的是登录页那条正常路径');
    });
  });
}

final _config = DataConfig(
  baseUrl: 'http://127.0.0.1:8788',
  requestTimeout: const Duration(seconds: 5),
);

DataApiClient _client(_Server server, {required ReadCache? cache, _Clock? clock}) =>
    DataApiClient(
      config: _config,
      session: _MemorySession(
        token: 't',
        user: {'id': 'stu_1', 'role': 'student'},
      ),
      httpClient: server.client,
      cache: cache,
      now: clock == null ? () => DateTime(2026, 9, 19, 10) : () => clock.value,
    );

/// 假服务端。能数请求、能挂起、能离线、能被拒。
class _Server {
  _Server({Map<String, dynamic>? payload}) : payload = payload ?? {'items': <Object>[]};

  Map<String, dynamic> payload;

  /// 非 null 时 GET 会挂在这里不返回 —— 用来把「慢网络」这个时序摆出来。
  Completer<void>? gate;

  bool offline = false;

  /// 非 null 时返回一个 `ok:false` 信封。
  Map<String, dynamic>? rejection;

  final List<String> calls = [];

  int get getCalls => calls.where((c) => c.startsWith('GET')).length;

  MockClient get client => MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (offline) throw http.ClientException('connect failed');
        if (rejection != null) {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'ok': false, 'error': rejection})),
            403,
          );
        }
        final currentGate = gate;
        if (currentGate != null && request.method == 'GET') {
          await currentGate.future;
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({'ok': true, 'data': payload})),
          200,
        );
      });
}

class _Clock {
  _Clock(this.value);

  DateTime value;

  DateTime call() => value;
}

/// 内存会话。`userOverride` 用来模拟「同一台设备换账号」。
///
/// 下面两个字段是**可变**的（`clear` 与 `save` 都要改它们），换成初始化
/// 形参就没法再提供 setter，所以这里的赋值是有意的。
///
/// 注意 `// ignore:` 后面**不能**跟解释文字：分析器会把整行剩余部分当成
/// 规则名去匹配，结果就是「注释写了、但没生效」。解释只能写在上面。
class _MemorySession extends SessionStore {
  _MemorySession({String? token, Map<String, dynamic>? user})
      // ignore: prefer_initializing_formals
      : _token = token,
        // ignore: prefer_initializing_formals
        _user = user;

  String? _token;
  Map<String, dynamic>? _user;

  /// 换账号用。
  set userOverride(Map<String, dynamic>? value) => _user = value;

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

/// 平台侧只在内存里的缓存，与 `read_cache_test.dart` 里的那个同构。
class _TestCache extends BaseReadCache {
  _TestCache({_Clock? clock}) : super(now: clock == null ? null : () => clock.value);

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
