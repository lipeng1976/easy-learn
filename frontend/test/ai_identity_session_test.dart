import 'dart:convert';

import 'package:easy_learn_app/services/ai_api_client.dart';
import 'package:easy_learn_app/services/ai_config.dart';
import 'package:easy_learn_app/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 这组测试守的是 **`AI_REQUIRE_AUTH=true` 能不能真的打开**。
///
/// 打开之前，网关那边所有校验都已就绪、服务端登录也已就绪，
/// 缺的只有客户端这一环：`SessionStore` 里明明存着服务端签发的票，
/// AI 请求却不带 `Authorization`。这类缺口不修，本地怎么测都是绿的 ——
/// 只有开关一开，每一条 AI 调用同时变成 401。
///
/// 而它的症状又具有**误导性**：用户看到的是「AI 功能全挂」，排查方向
/// 会指向网关或模型，根因却是一个没传的字段。
///
/// 三条独立的检查被下面的用例钉住：
/// ① 身份从会话装配，token 与学号来自**同一份**事实；
/// ② 传输层真的把票发出去（断言请求头，不是断言字段）；
/// ③ 登出后立刻不再带票 —— 不能等到运行时重建。

/// 内存会话。字段可变：`save` / `clear` 要改它们。
class _MemorySession extends SessionStore {
  _MemorySession({this.tokenOverride, this.userOverride});

  String? tokenOverride;
  Map<String, dynamic>? userOverride;

  @override
  Future<void> initialize() async {}

  @override
  String? get token => tokenOverride;

  @override
  Map<String, dynamic>? get user => userOverride;

  @override
  Future<void> save({
    required String token,
    required Map<String, dynamic> user,
  }) async {
    tokenOverride = token;
    userOverride = user;
  }

  @override
  Future<void> clear() async {
    tokenOverride = null;
    userOverride = null;
  }
}

AiConfig _config() => const AiConfig(
  baseUrl: 'https://gw.test',
  requestTimeout: Duration(seconds: 5),
);

/// 回一个形状正确的成功信封，并把请求头记下来。
MockClient _recordingClient(List<http.BaseRequest> seen) =>
    MockClient((request) async {
      seen.add(request);
      return http.Response(
        jsonEncode({
          'ok': true,
          'data': {'text': 'x', 'subject': '数学', 'confidence': 0.9, 'tasks': []},
          'meta': {'requestId': 'r'},
        }),
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    });

void main() {
  group('身份从会话装配', () {
    test('本地模式：没有会话时与上云之前逐字相同', () {
      final identity = AiIdentity.resolve(localUserId: 'user_1712');

      expect(identity.studentId, 'user_1712');
      expect(identity.sessionToken, isEmpty);
      expect(identity.authenticated, isFalse);
    });

    test('云端模式：学号取会话里那一个，票一起带上', () {
      final session = _MemorySession(
        tokenOverride: 'v1.payload.sig',
        userOverride: {'id': '6f1c-uuid', 'role': 'student'},
      );

      final identity = AiIdentity.resolve(
        session: session,
        localUserId: 'user_1712',
      );

      expect(identity.sessionToken, 'v1.payload.sig');
      expect(identity.authenticated, isTrue);
      // 关键：学号必须是**会话里**的 id（服务端签发的 uuid），
      // 不是本地库的 id。发本地 id 时网关会记一笔 `declaredStudentId` ——
      // 那条信号是抓伪造用的，被例行请求灌满就等于没有。
      expect(identity.studentId, '6f1c-uuid');
      expect(identity.studentId, isNot('user_1712'));
    });

    test('有票但用户行里没有 id：回退本地学号，票照带', () {
      final session = _MemorySession(
        tokenOverride: 'v1.payload.sig',
        userOverride: const {'role': 'student'},
      );

      final identity = AiIdentity.resolve(
        session: session,
        localUserId: 'user_1712',
      );

      expect(identity.studentId, 'user_1712');
      expect(identity.sessionToken, 'v1.payload.sig');
    });

    test('有票即放行：学号空也不该由客户端自己拦掉', () {
      // `requireAuth` 打开后网关只认票、学号是它自己从载荷里解的。
      // 这时如果还拿学号当门槛，一条「有票但本地用户行还没读出来」的请求
      // 会被客户端拦下 —— 那是把有效凭证当成没身份。
      expect(
        const AiIdentity(studentId: '', sessionToken: 'v1.p.s').usable,
        isTrue,
      );

      // 而没票时的旧规则一字不变。
      expect(const AiIdentity(studentId: '').usable, isFalse);
      expect(
        const AiIdentity(studentId: kAnonymousStudentId).usable,
        isFalse,
      );
    });
  });

  group('传输层真的把票发出去', () {
    test('请求头里有 Authorization，学号与会话一致', () async {
      final seen = <http.BaseRequest>[];
      final session = _MemorySession(
        tokenOverride: 'v1.payload.sig',
        userOverride: {'id': '6f1c-uuid'},
      );

      final client = AiApiClient(
        config: _config(),
        identity: AiIdentity.resolve(session: session),
        identityOf: () => AiIdentity.resolve(session: session),
        client: _recordingClient(seen),
      );

      await client.postJson('/ai/homework/ocr', const {'fileName': 'a.png'});

      expect(seen, hasLength(1));
      expect(seen.single.headers['Authorization'], 'Bearer v1.payload.sig');
      expect(seen.single.headers['X-Student-Id'], '6f1c-uuid');
    });

    test('登出后立刻不再带票 —— 不必等运行时重建', () async {
      final seen = <http.BaseRequest>[];
      final session = _MemorySession(
        tokenOverride: 'v1.payload.sig',
        userOverride: {'id': '6f1c-uuid'},
      );

      final client = AiApiClient(
        config: _config(),
        identity: AiIdentity.resolve(session: session),
        identityOf: () => AiIdentity.resolve(
          session: session,
          localUserId: 'user_1712',
        ),
        client: _recordingClient(seen),
      );

      await client.postJson('/ai/homework/ocr', const {});
      expect(seen.single.headers['Authorization'], 'Bearer v1.payload.sig');

      // 登出：本地凭证立刻清掉（`HttpAuthApi.logout` 的第一步就是这个）。
      await session.clear();

      await client.postJson('/ai/homework/ocr', const {});

      expect(seen, hasLength(2));
      // 第二条不能还带着那张已经作废的票：带上去只会换来一个 401，
      // 而 401 在界面上会被说成「网关拒绝了本次调用」，误导方向。
      expect(seen.last.headers.containsKey('Authorization'), isFalse);
      expect(seen.last.headers['X-Student-Id'], 'user_1712');
    });

    test('本地模式（无会话）请求头里没有 Authorization', () async {
      final seen = <http.BaseRequest>[];
      final client = AiApiClient(
        config: _config(),
        identity: AiIdentity.resolve(localUserId: 'user_1712'),
        client: _recordingClient(seen),
      );

      await client.postJson('/ai/homework/ocr', const {});

      expect(seen.single.headers.containsKey('Authorization'), isFalse);
      expect(seen.single.headers['X-Student-Id'], 'user_1712');
    });
  });
}
