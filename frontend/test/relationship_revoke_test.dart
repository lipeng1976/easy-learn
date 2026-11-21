import 'dart:convert';

import 'package:easy_learn_app/controllers/profile_controller.dart';
import 'package:easy_learn_app/models/chat_message_model.dart';
import 'package:easy_learn_app/models/relationship_model.dart';
import 'package:easy_learn_app/models/user_profile_model.dart';
import 'package:easy_learn_app/repositories/relationship_repository.dart';
import 'package:easy_learn_app/repositories/user_repository.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/http_relationship_repository.dart';
import 'package:easy_learn_app/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 解除结伴（2026-09-26 新增）—— **客户端这一半的判据**。
///
/// 服务端那一半在 `serverless/data-service/test/auth.test.js`
/// （238 条全绿，含三处逐个证伪：复活机制 / 通知 / 仅家长），
/// 它管的是「数据该不该给」。
///
/// 这个文件管另外三件事，每一件都**不报错、只是不对**：
///
///   ① **打到哪个端点**。解除走 `/data/relationship/revoke`，不是 `/status`。
///      打错时的症状很误导：`/status` 的白名单只有 active/rejected，
///      它回一句「status 只能是…」—— 看起来像参数拼错了，
///      而真正的问题是**调错了端点**（所以 `wire_status.dart` 里
///      `removed` 那一支特意给它单独的文案）。
///   ② **body 只有 id**。身份由服务端从 token 解出来；客户端能自报身份的地方
///      就是越权面（这条与本项目其它写接口同源）。
///   ③ **改完必须重拉**，而且**顺序是「先解除、后重拉」**。
///      解除改变的是服务端算出来的可见集合，本地 `relationships` 只是镜像；
///      只改内存那一行的话，家长端别的页面（各自加载过）仍然看得到那个孩子，
///      直到重启 —— 表现是「解除没生效」，而它其实生效了。
///      顺序反了更隐蔽：重拉先跑，拿回来的是 `active`，界面显示「已结伴」。
void main() {
  group('协议：HttpRelationshipRepository', () {
    test('打到 /revoke，body 只有 id', () async {
      final calls = <String>[];
      Map<String, dynamic>? sent;
      final repo = HttpRelationshipRepository(
        _api((request) {
          calls.add('${request.method} ${request.url.path}');
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return {'relationship': null};
        }),
      );

      await repo.revokeRelationship(id: 'rel_1');

      expect(
        calls,
        ['POST /data/relationship/revoke'],
        reason: '解除只有一个请求，且必须打在 /revoke 上（不是 /status）',
      );
      expect(
        sent,
        {'id': 'rel_1'},
        reason: 'body 只该有 id —— 身份由服务端从 token 解，客户端自报就是给越权留门',
      );
    });
  });

  group('ProfileController：重拉的时机与顺序', () {
    test('先解除、后重拉 —— 拉回来的是「已解除」而不是旧的 active', () async {
      final relations = _FakeRelationships();
      final users = _FakeUsers();
      final controller = ProfileController(
        relationships: relations,
        users: users,
      );

      await controller.revokeRelationship(id: 'rel_1', requesterId: 'par_1');

      expect(relations.revoked, ['rel_1'], reason: '必须真的调了仓库');
      expect(relations.queryCalls, 1, reason: '解除后必须重拉关系列表');
      expect(users.queryCalls, 1, reason: 'load() 会同时重拉档案');

      // ★ 这一条钉住的是**顺序**：假仓库在 revoke 之后才会把状态报成 removed。
      // 实现若写成「先 load 再 revoke」，这里拿回的是 `active`，界面会显示
      // 「已结伴」—— 用户看到的是「点了没反应」。
      expect(
        controller.relationships.single.status,
        RelationshipStatus.removed,
        reason: '重拉必须发生在解除**之后**，否则拿回的是解除前的状态',
      );
    });

    test('仓库抛错时原样抛出，**不吞**，也不重拉', () async {
      final relations = _FakeRelationships(
        failWith: StateError('只有家长可以解除结伴'),
      );
      final users = _FakeUsers();
      final controller = ProfileController(
        relationships: relations,
        users: users,
      );

      await expectLater(
        () => controller.revokeRelationship(id: 'rel_1', requesterId: 'par_1'),
        throwsA(isA<StateError>()),
      );

      // 失败还去重拉的话，界面上会**看着像成功**（列表刷新了、状态也没变），
      // 而家长根本不知道自己没解除成功 —— 这是本项目最典型的那类静默失败。
      expect(users.queryCalls, 0, reason: '失败时不该发生任何重拉');
      expect(relations.queryCalls, 0);
    });
  });
}

// ===== 装置 =====

final _config = DataConfig(
  baseUrl: 'http://127.0.0.1:8788',
  requestTimeout: const Duration(seconds: 5),
);

/// 一个能捕获请求的假服务端。`postJson` 期望 `{ok:true, data:{...}}` 信封。
DataApiClient _api(Map<String, dynamic> Function(http.Request) onPost) =>
    DataApiClient(
      config: _config,
      session: _MemorySession(),
      httpClient: MockClient((request) async {
        final data = onPost(request);
        return http.Response.bytes(
          utf8.encode(jsonEncode({'ok': true, 'data': data})),
          200,
        );
      }),
    );

class _MemorySession extends SessionStore {
  @override
  Future<void> initialize() async {}

  @override
  String? get token => 't';

  @override
  Map<String, dynamic>? get user => {'id': 'par_1', 'role': 'parent'};

  @override
  Future<void> save({
    required String token,
    required Map<String, dynamic> user,
  }) async {}

  @override
  Future<void> clear() async {}
}

/// 假关系仓库。**它模拟「解除会改变服务端状态」这件事** ——
/// 重拉的返回值取决于 `revokedThisTime` 有没有被置位，
/// 于是「先 load 再 revoke」这种顺序错误能被断言抓到。
class _FakeRelationships implements RelationshipRepository {
  _FakeRelationships({this.failWith});

  /// 非 null 时 `revokeRelationship` 抛它（模拟服务端 403）。
  final Object? failWith;

  final List<String> revoked = [];
  int queryCalls = 0;
  bool _revokedThisTime = false;

  @override
  Future<List<RelationshipModel>> queryRelationships(String userId) async {
    queryCalls += 1;
    return [
      RelationshipModel(
        id: 'rel_1',
        studentId: 'stu_1',
        parentId: 'par_1',
        senderId: 'par_1',
        studentName: '林小宇',
        parentName: '王老师',
        status: _revokedThisTime
            ? RelationshipStatus.removed
            : RelationshipStatus.active,
      ),
    ];
  }

  @override
  Future<void> revokeRelationship({required String id}) async {
    final failure = failWith;
    if (failure != null) throw failure;
    revoked.add(id);
    _revokedThisTime = true;
  }

  @override
  Future<RelationshipModel> createRelationshipInvitation({
    required String senderId,
    required String targetPhone,
  }) => throw UnimplementedError('本文件不涉及邀请');

  @override
  Future<void> updateRelationshipStatus({
    required String id,
    required RelationshipStatus status,
  }) => throw UnimplementedError('本文件不涉及接受/拒绝');

  @override
  Future<List<ChatMessageModel>> queryChatMessages({
    required String relationshipId,
    required String requesterId,
  }) => throw UnimplementedError('本文件不涉及聊天');

  @override
  Future<ChatMessageModel> sendChatMessage({
    required String relationshipId,
    required String senderId,
    required String content,
  }) => throw UnimplementedError('本文件不涉及聊天');
}

class _FakeUsers implements UserRepository {
  int queryCalls = 0;

  @override
  Future<UserProfileModel?> queryUserProfile(String userId) async {
    queryCalls += 1;
    return UserProfileModel(
      userId: userId,
      name: '王老师',
      gender: '',
      grade: '',
      hobbies: const [],
      bio: '',
    );
  }

  @override
  Future<void> updateUserProfile(UserProfileModel profile) async =>
      throw UnimplementedError('本文件不涉及保存档案');

  @override
  Future<List<Map<String, dynamic>>> queryUsersByIds(List<String> ids) async =>
      throw UnimplementedError('本文件不涉及批量取用户');
}
