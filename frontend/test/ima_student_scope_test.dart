import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_learn_app/controllers/ima_controller.dart';
import 'package:easy_learn_app/repositories/ima_repository.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/http_ima_repository.dart';
import 'package:easy_learn_app/services/read_cache.dart';
import 'package:easy_learn_app/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 「ima 配置主体是学生」的客户端判据（2026-11-08 定稿，设计见
/// `doc/ima-integration-design.md` §2）。
///
/// 盯三件事：
///   ① 三个端点都把「当前伴学学生」带下去（GET 走 query / POST 走 body）；
///   ② 切孩子时状态**立刻清空**并重新拉，且不同学生的读缓存不串；
///   ③ 学生 / 姓名按服务端回显，父母共管看到的是同一份。
///
/// 底线不变：没有 ima 时依旧不报错（`ima_optional_degradation_test.dart` 全绿）。

const _config = DataConfig(
  baseUrl: 'http://127.0.0.1:8788',
  requestTimeout: Duration(seconds: 5),
);

void main() {
  group('ImaStatus 学生字段', () {
    test('解析 studentId / studentName', () {
      final s = ImaStatus.fromJson(const {
        'status': 'active',
        'studentId': 's1',
        'studentName': '李雨霏',
        'kbs': [
          {'studentId': 's1', 'kbId': 'kb1', 'kbName': '伴学-李雨霏-s1'},
        ],
      });
      expect(s.studentId, 's1');
      expect(s.studentName, '李雨霏');
      expect(s.kbs.single.studentId, 's1');
    });

    test('老服务端没回这两个字段 → null，功能不炸', () {
      final s = ImaStatus.fromJson(const {'status': 'unconnected'});
      expect(s.studentId, isNull);
      expect(s.studentName, isNull);
    });
  });

  group('HttpImaRepository 传学生', () {
    test('getStatus → query 带 studentId', () async {
      final server = _Server();
      final repo = HttpImaRepository(_client(server));
      await repo.getStatus(studentId: 's2');
      expect(server.gets.single.queryParameters['studentId'], 's2');
    });

    test('connect → body 带 studentId，且仍是小写 clientid/apikey', () async {
      final server = _Server();
      final repo = HttpImaRepository(_client(server));
      await repo.connect(clientId: 'cid', apiKey: 'akey', studentId: 's2');
      final body = server.bodies.single;
      expect(body['studentId'], 's2');
      expect(body['clientid'], 'cid');
      expect(body['apikey'], 'akey');
    });

    test('disconnect → body 带 studentId', () async {
      final server = _Server();
      final repo = HttpImaRepository(_client(server));
      await repo.disconnect(studentId: 's2');
      expect(server.bodies.single['studentId'], 's2');
    });

    test('不传 studentId（学生端 / 老服务端）→ 不带空参数', () async {
      final server = _Server();
      final repo = HttpImaRepository(_client(server));
      await repo.getStatus();
      await repo.disconnect();
      expect(server.gets.single.queryParameters.containsKey('studentId'), isFalse,
          reason: '空串与「没传」在服务端是两种语义');
      expect(server.bodies.single.containsKey('studentId'), isFalse);
    });

    test('切孩子不会命中上一个孩子的读缓存', () async {
      final server = _Server();
      final client = _client(server, cache: _TestCache());
      final repo = HttpImaRepository(client);
      // 服务端按学生回不同状态；如果缓存键不含 query，第二次会拿回第一次那份。
      server.payloadFor = (req) => {
        'status': 'active',
        'studentId': req.url.queryParameters['studentId'],
        'kbs': <Object>[],
      };
      final a = await repo.getStatus(studentId: 's1');
      final b = await repo.getStatus(studentId: 's2');
      expect(a.studentId, 's1');
      expect(b.studentId, 's2');
      expect(server.gets.length, 2, reason: '两个学生必须各自打一次网络，不能共用缓存');
    });
  });

  group('ImaController 切孩子', () {
    test('切孩子立刻清空状态并重新拉该学生的配置', () async {
      final repo = _ScopeRepo();
      final c = ImaController(repo: repo);
      await c.loadStatus();
      expect(c.status.value.isActive, isTrue);

      c.bindStudent('s2');
      expect(c.status.value.isConnected, isFalse,
          reason: '不清的话，从已配好的老大切到没配的老二，界面会继续显示「已开启」');
      expect(c.status.value.kbs, isEmpty);
      expect(c.status.value.studentId, 's2');
      expect(c.status.value.available, isTrue, reason: '部署级开关不该被学生切换清掉');

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(repo.statusCalls, contains('s2'));
      expect(c.status.value.studentId, 's2');
    });

    test('同一个学生重复绑定不重复发请求', () async {
      final repo = _ScopeRepo();
      final c = ImaController(repo: repo);
      c.bindStudent('s1', reload: false);
      c.bindStudent('s1', reload: false);
      await c.loadStatus();
      expect(repo.statusCalls, ['s1']);
    });

    test('connect / disconnect 也带着当前学生', () async {
      final repo = _ScopeRepo();
      final c = ImaController(repo: repo);
      c.bindStudent('s2', reload: false);
      c.clientId.value = 'cid';
      c.apiKey.value = 'akey';
      await c.connect();
      await c.disconnect();
      expect(repo.connectCalls, ['s2']);
      expect(repo.disconnectCalls, ['s2']);
    });

    test('快速切孩子：上一个学生的慢响应不覆盖当前学生', () async {
      final repo = _SlowImaRepo();
      final c = ImaController(repo: repo);
      c.bindStudent('s1', reload: false);
      final slow = c.loadStatus(); // s1 的请求挂住
      c.bindStudent('s2', reload: false);
      await c.loadStatus(); // s2 先回来
      expect(c.status.value.studentId, 's2');

      repo.finishSlow(); // s1 的响应迟到
      await slow;
      expect(c.status.value.studentId, 's2',
          reason: '迟到的旧响应不能把界面改回上一个孩子的「已开启 + 库名」');
    });

    test('源码契约：家长端切孩子确实绑到了 ParentController', () {
      // UI 绑定这段没法用纯 Dart 构造真实 ParentController（它会拉本地库），
      // 但「有没有注册 ever 监听」必须有人盯着：漏了的表现是
      // 「在首页切了孩子，进 ima 设置页还停在原来那个」，页面本身全绿。
      final src = File('lib/controllers/ima_controller.dart').readAsStringSync();
      expect(src, contains('Get.isRegistered<ParentController>()'));
      expect(src, contains('ever<String>(parent.selectedStudentId'));
      expect(src, contains('bindStudent(id)'));
    });
  });
}

DataApiClient _client(_Server server, {ReadCache? cache}) => DataApiClient(
      config: _config,
      session: _MemorySession(token: 't', user: const {'id': 'par_1', 'role': 'parent'}),
      httpClient: server.client,
      cache: cache,
    );

/// 假服务端：记录 GET 的 Uri（含 query）与 POST 的 body。
class _Server {
  final List<Uri> gets = [];
  final List<Map<String, dynamic>> bodies = [];
  Map<String, dynamic> Function(http.Request req)? payloadFor;

  MockClient get client => MockClient((request) async {
        Map<String, dynamic> data;
        if (request.method == 'GET') {
          gets.add(request.url);
          data = payloadFor?.call(request) ??
              const {'status': 'unconnected', 'kbs': <Object>[]};
        } else {
          bodies.add(
            request.body.isEmpty
                ? <String, dynamic>{}
                : jsonDecode(request.body) as Map<String, dynamic>,
          );
          data = const {'status': 'active', 'kbs': <Object>[]};
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({'ok': true, 'data': data})),
          200,
        );
      });
}

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
  bool get isAuthenticated => token != null && token!.isNotEmpty;

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

/// 内存读缓存（与 data_api_cache_test.dart 同构）。
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

/// 第一次 getStatus 挂住，第二次立即返回：模拟快速切孩子时的慢响应。
class _SlowImaRepo implements ImaRepository {
  final Completer<ImaStatus> _slow = Completer<ImaStatus>();
  int calls = 0;

  void finishSlow() => _slow.complete(const ImaStatus(
        status: 'active',
        available: true,
        studentId: 's1',
        studentName: '李雨霏',
        kbs: [ImaStudentKb(studentId: 's1', kbId: 'kb1', kbName: '伴学-李雨霏-s1')],
      ));

  @override
  Future<ImaStatus> getStatus({String? studentId}) async {
    calls += 1;
    if (calls == 1) return _slow.future;
    return ImaStatus(status: 'active', available: true, studentId: studentId);
  }

  @override
  Future<ImaStatus> connect({
    required String clientId,
    required String apiKey,
    String? studentId,
  }) async =>
      ImaStatus(status: 'active', studentId: studentId);

  @override
  Future<void> disconnect({String? studentId}) async {}
}

/// 记录每次调用收到的 studentId，并按学生回一份 active 状态。
class _ScopeRepo implements ImaRepository {
  final List<String?> statusCalls = [];
  final List<String?> connectCalls = [];
  final List<String?> disconnectCalls = [];

  ImaStatus _for(String? id) => ImaStatus(
        status: 'active',
        available: true,
        studentId: id,
        studentName: '李雨霏',
        kbs: const [ImaStudentKb(studentId: 's1', kbId: 'kb1', kbName: '伴学-李雨霏-s1')],
      );

  @override
  Future<ImaStatus> getStatus({String? studentId}) async {
    statusCalls.add(studentId);
    return _for(studentId);
  }

  @override
  Future<ImaStatus> connect({
    required String clientId,
    required String apiKey,
    String? studentId,
  }) async {
    connectCalls.add(studentId);
    return _for(studentId);
  }

  @override
  Future<void> disconnect({String? studentId}) async {
    disconnectCalls.add(studentId);
  }
}
