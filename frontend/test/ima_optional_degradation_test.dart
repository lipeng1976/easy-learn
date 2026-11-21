import 'dart:convert';

import 'package:easy_learn_app/controllers/ima_controller.dart';
import 'package:easy_learn_app/repositories/ima_repository.dart';
import 'package:easy_learn_app/repositories/reading_repository.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/http_ima_repository.dart';
import 'package:easy_learn_app/services/http_reading_repository.dart';
import 'package:easy_learn_app/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 「不是所有人都有 ima」的客户端判据（2026-11-07 定）。
///
/// 硬规矩：ima 是可选能力。没有的话功能可以不出现，但**不能出错**：
///   · `available:false` → 设置页 / 个人信息页的入口整体隐藏；
///   · 状态读失败 → 灰字提示，绝不写红色 `error`；
///   · 书库回 `connected:false` → 翻译成内部信号，不是 `DataApiException`。
///
/// 反面同样要有判据：老服务端不返回 `available`、已连通的书库，
/// 不能被「一律降级」弄成功能凭空消失。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ImaStatus.available（这个部署有没有开通 ima）', () {
    test('available:false → isFeatureEnabled=false，入口应隐藏', () {
      final s = ImaStatus.fromJson(const {'status': 'unconnected', 'available': false});
      expect(s.isFeatureEnabled, isFalse);
      expect(s.isConnected, isFalse);
    });

    test('老服务端不带该字段 → null，按可用处理（不能让升级弄丢功能）', () {
      final s = ImaStatus.fromJson(const {});
      expect(s.available, isNull);
      expect(s.isFeatureEnabled, isTrue);
    });

    test('available:true 的正常响应不受影响', () {
      final s = ImaStatus.fromJson(const {'status': 'active', 'available': true});
      expect(s.isFeatureEnabled, isTrue);
      expect(s.isConnected, isTrue);
    });

    test('本地（无云端）模式明确回 available:false', () async {
      final s = await const UnconfiguredImaRepository().getStatus();
      expect(s.available, isFalse);
      expect(s.isFeatureEnabled, isFalse);
    });
  });

  group('ImaController：读不到状态不等于报错', () {
    test('getStatus 抛 DataApiException → 灰字 hint，红色 error 必须为空', () async {
      final c = ImaController(repo: _ThrowingImaRepo());
      await c.loadStatus();
      expect(c.error.value, isNull, reason: '状态读失败不该变成一条红色错误');
      expect(c.hint.value, isNotNull);
      expect(c.status.value.isConnected, isFalse);
    });

    test('getStatus 抛底层异常（含 URL / 堆栈）→ 也不许拼进界面', () async {
      final c = ImaController(repo: _ThrowingImaRepo(
        message: 'SocketException: http://x/y',
        raw: true,
      ));
      await c.loadStatus();
      expect(c.error.value, isNull);
      expect(c.hint.value, isNot(contains('SocketException')));
    });

    test('正常读到 status 时不留下 hint', () async {
      final c = ImaController(repo: _FakeImaRepo());
      await c.loadStatus();
      expect(c.status.value.isActive, isTrue);
      expect(c.hint.value, isNull);
      expect(c.error.value, isNull);
    });
  });

  group('HttpReadingRepository：2xx + connected:false 是「没开通」', () {
    DataApiClient apiWith(Map<String, dynamic> data) => DataApiClient(
          config: const DataConfig(baseUrl: 'http://127.0.0.1:8788'),
          session: _MemorySession(),
          httpClient: MockClient((request) async => http.Response.bytes(
                utf8.encode(jsonEncode({'ok': true, 'data': data})),
                200,
              )),
        );

    test('connected:false → 抛 ImaBookSourceUnavailable，不是 DataApiException', () async {
      final repo = HttpReadingRepository(apiWith(const {
        'connected': false,
        'folderPath': '教学资料/English',
        'books': <dynamic>[],
        'reason': 'ima_unavailable',
      }));
      await expectLater(
        repo.listAvailableBooks(),
        throwsA(isA<ImaBookSourceUnavailable>()),
      );
    });

    test('反面：connected:true 时书照常解析，不会被误判成没开通', () async {
      final repo = HttpReadingRepository(apiWith({
        'connected': true,
        'books': [
          {'mediaId': 'm1', 'fileName': '基础篇.md', 'title': '基础篇'},
        ],
      }));
      final books = await repo.listAvailableBooks();
      expect(books.length, 1);
      expect(books.first.title, '基础篇');
    });
  });
}

class _FakeImaRepo implements ImaRepository {
  @override
  Future<ImaStatus> getStatus({String? studentId}) async =>
      const ImaStatus(status: 'active', available: true);

  @override
  Future<ImaStatus> connect({
    required String clientId,
    required String apiKey,
    String? studentId,
  }) async =>
      getStatus();

  @override
  Future<void> disconnect({String? studentId}) async {}
}

class _ThrowingImaRepo implements ImaRepository {
  _ThrowingImaRepo({this.message = '服务端开小差了', this.raw = false});

  final String message;
  final bool raw;

  @override
  Future<ImaStatus> getStatus({String? studentId}) async => throw raw
      ? Exception(message)
      : DataApiException(code: 'internal', message: message);

  @override
  Future<ImaStatus> connect({
    required String clientId,
    required String apiKey,
    String? studentId,
  }) async =>
      getStatus();

  @override
  Future<void> disconnect({String? studentId}) async {}
}

/// 内存会话（与其它测试里的同构；SessionStore 有必需 getter，不能用 Object 冒充）。
class _MemorySession extends SessionStore {
  @override
  Future<void> initialize() async {}

  @override
  String? get token => 't';

  @override
  Map<String, dynamic>? get user => const {'id': 'par_1', 'role': 'parent'};

  @override
  Future<void> save({required String token, required Map<String, dynamic> user}) async {}

  @override
  Future<void> clear() async {}
}
