// 判据：`putJson` 发出去的必须是 **PUT**，不是 POST。
//
// 这条判据是补的，因为踩过一次真实事故（2026-11-12）：`_send` 里写的是
// 「GET 走 get，其余一律 post」，于是 `putJson` 在线上发出的是 POST，
// 服务端路由只注册了 `PUT /data/word/scope` ⇒ 405 ⇒ 家长端「保存没成功」。
//
// 为什么之前的判据全绿：服务端探针用 node 自己拼的 PUT 打服务端（对的），
// 客户端单测只断「返回了被采纳的那行数据」（假 client 不关心动词）。
// **两边都没错，错在接缝。** 所以这里直接盯发出去的报文。

import 'dart:convert';

import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _config = DataConfig(baseUrl: 'http://127.0.0.1:8788');

Map<String, dynamic> _ok(Map<String, dynamic> data) => <String, dynamic>{
      'ok': true,
      'data': data,
    };

Map<String, dynamic> _fail(String code, String message) => <String, dynamic>{
      'ok': false,
      'error': <String, dynamic>{'code': code, 'message': message},
    };

http.Response _json(Map<String, dynamic> body, int status) => http.Response(
      jsonEncode(body),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );

void main() {
  test('putJson 发的是 PUT（不是 POST）', () async {
    final seen = <String>[];
    final client = DataApiClient(
      config: _config,
      session: _MemorySession(token: 't', user: const <String, dynamic>{
        'id': 'stu_1',
        'role': 'parent',
      }),
      httpClient: MockClient((request) async {
        seen.add('${request.method} ${request.url.path}');
        if (request.method != 'PUT') {
          // 服务端就是这样拒的：路径在、方法不对 ⇒ 405。
          return _json(_fail('method_not_allowed', 'Method Not Allowed'), 405);
        }
        return _json(_ok(<String, dynamic>{'bookId': 'b1'}), 200);
      }),
    );

    final data = await client.putJson(
      '/data/word/scope',
      body: <String, Object?>{'bookId': 'b1'},
    );

    expect(seen, <String>['PUT /data/word/scope'],
        reason: '动词发错时服务端回 405，家长看到的是「保存没成功」——'
            '而客户端代码里明明写着 putJson');
    expect(data['bookId'], 'b1');
  });

  test('postJson 仍然发 POST（没被顺手改坏）', () async {
    final seen = <String>[];
    final client = DataApiClient(
      config: _config,
      session: _MemorySession(token: 't', user: const <String, dynamic>{
        'id': 'stu_1',
        'role': 'student',
      }),
      httpClient: MockClient((request) async {
        seen.add(request.method);
        return _json(_ok(<String, dynamic>{'saved': true}), 200);
      }),
    );

    await client.postJson('/data/word/daily', body: <String, Object?>{'total': 10});

    expect(seen, <String>['POST']);
  });

  test('PUT 被 405 拒掉时必须抛错，不能当成保存成功', () async {
    final client = DataApiClient(
      config: _config,
      session: _MemorySession(token: 't', user: const <String, dynamic>{
        'id': 'stu_1',
        'role': 'parent',
      }),
      httpClient: MockClient((request) async =>
          _json(_fail('method_not_allowed', 'Method Not Allowed'), 405)),
    );

    await expectLater(
      client.putJson('/data/word/scope', body: <String, Object?>{'bookId': 'b1'}),
      throwsA(isA<DataApiException>()
          .having((e) => e.status, 'status', 405)
          .having((e) => e.code, 'code', 'method_not_allowed')),
      reason: '把 405 吞掉就会变成「页面说已保存、服务端一行都没有」',
    );
  });
}

class _MemorySession extends SessionStore {
  _MemorySession({this.token, this.user});

  @override
  String? token;

  @override
  Map<String, dynamic>? user;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> save({
    required String token,
    required Map<String, dynamic> user,
  }) async {
    this.token = token;
    this.user = user;
  }

  @override
  Future<void> clear() async {
    token = null;
    user = null;
  }
}
