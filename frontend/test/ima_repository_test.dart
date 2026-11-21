import 'dart:convert';

import 'package:easy_learn_app/controllers/ima_controller.dart';
import 'package:easy_learn_app/repositories/ima_repository.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/http_ima_repository.dart';
import 'package:easy_learn_app/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ========== 1. ImaStatus 模型解析 ==========

void main() {
  group('ImaStatus.fromJson', () {
    test('解析 status / kbs / ownerUserId', () {
      final s = ImaStatus.fromJson({
        'status': 'active',
        'kbs': [
          {'studentId': 's1', 'kbId': 'k1', 'kbName': '伴学-李雨霏-s1'},
        ],
        'ownerUserId': 'p1',
      });
      expect(s.isActive, isTrue);
      expect(s.isExpired, isFalse);
      expect(s.kbs.length, 1);
      expect(s.kbs[0].kbId, 'k1');
      expect(s.kbs[0].kbName, '伴学-李雨霏-s1');
      expect(s.ownerUserId, 'p1');
    });

    test('缺字段时回退默认（unconnected，空 kbs）', () {
      final s = ImaStatus.fromJson(const {});
      expect(s.status, 'unconnected');
      expect(s.isConnected, isFalse);
      expect(s.kbs, isEmpty);
      expect(s.ownerUserId, isNull);
    });

    test('expired 不算已连接', () {
      final s = ImaStatus.fromJson(const {'status': 'expired'});
      expect(s.isExpired, isTrue);
      expect(s.isConnected, isFalse);
    });
  });

  // ========== 2. UnconfiguredImaRepository（本地模式） ==========

  group('UnconfiguredImaRepository', () {
    const repo = UnconfiguredImaRepository();

    test('getStatus 恒为未连接', () async {
      final s = await repo.getStatus();
      expect(s.isConnected, isFalse);
    });

    test('connect 抛 unavailable', () async {
      expect(
        () => repo.connect(clientId: 'c', apiKey: 'a'),
        throwsA(
          isA<DataApiException>().having((e) => e.code, 'code', 'unavailable'),
        ),
      );
    });

    test('disconnect 是空操作', () async {
      await repo.disconnect(); // 不应抛
    });
  });

  // ========== 3. HttpImaRepository（经假 DataApiClient） ==========

  group('HttpImaRepository', () {
    const config = DataConfig(
      baseUrl: 'http://127.0.0.1:8788',
      requestTimeout: Duration(seconds: 5),
    );

    DataApiClient buildClient(_ImaServer server) => DataApiClient(
          config: config,
          session: _MemorySession(token: 't', user: {'id': 'par_1', 'role': 'parent'}),
          httpClient: server.client,
        );

    test('getStatus 解析信封里的 data', () async {
      final server = _ImaServer(
        statusPayload: {
          'status': 'active',
          'kbs': [
            {'studentId': 's1', 'kbId': 'kb1', 'kbName': '伴学-学生-s1'},
          ],
          'ownerUserId': 'par_1',
        },
      );
      final repo = HttpImaRepository(buildClient(server));
      final s = await repo.getStatus();
      expect(s.isActive, isTrue);
      expect(s.kbs.length, 1);
      expect(s.kbs[0].kbId, 'kb1');
      expect(server.calls.first, 'GET /data/ima/status');
    });

    test('connect 发送 clientid / apikey 并解析返回', () async {
      final server = _ImaServer(
        connectPayload: {
          'status': 'active',
          'kbs': [
            {'studentId': 's1', 'kbId': 'kb1', 'kbName': '伴学-学生-s1'},
          ],
        },
      );
      final repo = HttpImaRepository(buildClient(server));
      final s = await repo.connect(clientId: 'cid', apiKey: 'akey');
      expect(s.isActive, isTrue);
      final call = server.calls.first;
      expect(call, 'POST /data/ima/connect');
      // 发送的 body 必须是小写的 clientid / apikey（与服务端对齐）。
      final sent = server.bodies.first;
      expect(sent['clientid'], 'cid');
      expect(sent['apikey'], 'akey');
      expect(sent.containsKey('clientId'), isFalse);
    });

    test('connect 服务端回 401 → 抛 DataApiException', () async {
      final server = _ImaServer(
        rejection: {'code': 'ima_auth_failed', 'message': '密钥错误'},
      );
      final repo = HttpImaRepository(buildClient(server));
      expect(
        () => repo.connect(clientId: 'x', apiKey: 'y'),
        throwsA(
          isA<DataApiException>().having((e) => e.code, 'code', 'ima_auth_failed'),
        ),
      );
    });

    test('disconnect 走 POST /data/ima/disconnect', () async {
      final server = _ImaServer();
      final repo = HttpImaRepository(buildClient(server));
      await repo.disconnect();
      expect(server.calls, contains('POST /data/ima/disconnect'));
    });
  });

  // ========== 4. ImaController（经假 ImaRepository） ==========

  group('ImaController', () {
    test('connect 成功：状态变 active 且返回 true', () async {
      final repo = _FakeImaRepo();
      final c = ImaController(repo: repo);
      c.clientId.value = 'cid';
      c.apiKey.value = 'akey';
      final ok = await c.connect();
      expect(ok, isTrue);
      expect(c.status.value.isActive, isTrue);
      expect(c.error.value, isNull);
      expect(repo.lastConnected, isNotNull);
    });

    test('connect 缺字段：不发起、报错', () async {
      final repo = _FakeImaRepo();
      final c = ImaController(repo: repo); // clientId / apiKey 都为空
      final ok = await c.connect();
      expect(ok, isFalse);
      expect(repo.lastConnected, isNull);
      expect(c.error.value, contains('不能为空'));
    });

    test('connect 失败：回滚状态、记录错误，不污染', () async {
      final repo = _FakeImaRepo(failConnect: true, initial: ImaStatus.unconnected);
      final c = ImaController(repo: repo);
      c.clientId.value = 'cid';
      c.apiKey.value = 'akey';
      final ok = await c.connect();
      expect(ok, isFalse);
      // 失败后状态不应残留 active
      expect(c.status.value.isConnected, isFalse);
      expect(c.error.value, '密钥错误');
    });

    test('disconnect：调用仓库并回读状态', () async {
      final repo = _FakeImaRepo(initial: ImaStatus.unconnected);
      final c = ImaController(repo: repo);
      await c.disconnect();
      expect(repo.disconnected, isTrue);
    });
  });

  // 个人页徽标：四个状态各一句，且「还在取」与「取不到」必须分开。
  // 这两句混同的后果是「加载完了还写着加载中」，看着像卡死。
  group('imaStatusLabel', () {
    test('null + 未失败 = 加载中…', () {
      expect(imaStatusLabel(null, failed: false), '加载中…');
    });

    test('null + 失败 = 状态未知（不是加载中）', () {
      expect(imaStatusLabel(null, failed: true), '状态未知');
    });

    test('active / expired / unconnected 各对应一句', () {
      expect(imaStatusLabel(const ImaStatus(status: 'active'), failed: false), '已开启');
      expect(imaStatusLabel(const ImaStatus(status: 'expired'), failed: false), '已失效');
      expect(
        imaStatusLabel(const ImaStatus(status: 'unconnected'), failed: false),
        '未开启',
      );
    });

    test('失败标记不影响已知状态的文案（只知道没连上就不该说未知）', () {
      expect(imaStatusLabel(const ImaStatus(status: 'active'), failed: true), '已开启');
    });
  });
}

/// 假服务端：按路径返回信封，按 rejection 返回失败信封。
class _ImaServer {
  _ImaServer({this.statusPayload, this.connectPayload, this.rejection});

  Map<String, dynamic>? statusPayload;
  Map<String, dynamic>? connectPayload;

  /// 非 null 时返回一个 `ok:false` 信封（模拟密钥错误等）。
  Map<String, dynamic>? rejection;

  final List<String> calls = [];
  final List<Map<String, dynamic>> bodies = [];

  MockClient get client => MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (rejection != null) {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'ok': false, 'error': rejection})),
            400,
          );
        }
        if (request.method == 'POST' && request.body.isNotEmpty) {
          bodies.add(
            jsonDecode(request.body) as Map<String, dynamic>,
          );
        }
        final data = request.method == 'GET'
            ? (statusPayload ?? {'status': 'unconnected', 'kbs': []})
            : (connectPayload ?? {'status': 'active', 'kbs': []});
        return http.Response.bytes(
          utf8.encode(jsonEncode({'ok': true, 'data': data})),
          200,
        );
      });
}

/// 与 data_api_cache_test.dart 同款的假会话。
class _MemorySession extends SessionStore {
  _MemorySession({String? token, Map<String, dynamic>? user})
      // ignore: prefer_initializing_formals
      : _token = token,
        // ignore: prefer_initializing_formals
        _user = user;

  String? _token;
  Map<String, dynamic>? _user;

  @override
  String? get token => _token;

  @override
  Map<String, dynamic>? get user => _user;

  @override
  bool get isAuthenticated => _token != null && _token!.isNotEmpty;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> save({String? token, Map<String, dynamic>? user}) async {
    _token = token;
    _user = user;
  }

  @override
  Future<void> clear() async {
    _token = null;
    _user = null;
  }
}

/// 假仓库：用于驱动 ImaController 的逻辑（成功 / 失败 / 断开）。
class _FakeImaRepo implements ImaRepository {
  _FakeImaRepo({this.initial = ImaStatus.unconnected, this.failConnect = false});

  final ImaStatus initial;
  final bool failConnect;

  ImaStatus? lastConnected;
  bool disconnected = false;

  @override
  Future<ImaStatus> getStatus({String? studentId}) async => initial;

  @override
  Future<ImaStatus> connect({
    required String clientId,
    required String apiKey,
    String? studentId,
  }) async {
    if (failConnect) {
      throw DataApiException(code: 'ima_auth_failed', message: '密钥错误');
    }
    lastConnected = ImaStatus(
      status: 'active',
      kbs: const [ImaStudentKb(studentId: 's1', kbId: 'kb1', kbName: '伴学-学生-s1')],
    );
    return lastConnected!;
  }

  @override
  Future<void> disconnect({String? studentId}) async {
    disconnected = true;
  }
}
