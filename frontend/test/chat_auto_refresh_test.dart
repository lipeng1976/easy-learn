import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/chat_controller.dart';
import 'package:easy_learn_app/models/chat_message_model.dart';
import 'package:easy_learn_app/models/relationship_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/shared/chat_page.dart';
import 'package:easy_learn_app/repositories/relationship_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 虫子的反馈（2026-09-25）：「两个人在线发消息时，是不是不是实时的？
/// 需要手工刷新才能看到。」—— **他猜对了，这不是网络延迟**。
///
/// 旧实现的聊天页只在 `initState` 加载一次，此后没有任何自动刷新
/// （没有 Timer、没有 Stream、服务端也没有推送）：对方发的消息
/// **只有退出聊天页重进才看得到**。修复 = 聊天页前台轮询
/// （`ChatController.startAutoRefresh`，页面 dispose 即停 ——
/// 与 B7 首页「刻意不做轮询」不矛盾，那是后台常驻）。
///
/// 这个文件钉住三条纪律：
///   ① 轮询真的在拉（页面级，pump 过轮询间隔后 queryCalls 要涨）；
///   ② **轮询失败不清屏** —— `loadConversation` 的「失败清空」是为
///      切会话设计的；轮询时清空等于一次网络抖动把正在看的对话刷成白屏；
///   ③ **迟到的旧会话响应不覆盖新会话**（切会话竞态，消息串门不报错）。
class _PollStubRepo implements RelationshipRepository {
  _PollStubRepo();

  /// 按 relationshipId 给出消息；没配置的会话返回空（可增列表）。
  final Map<String, List<ChatMessageModel>> messagesByRelationship = {};

  /// 非 null 时 `queryChatMessages` 抛它。
  Object? queryError;

  int queryCalls = 0;

  @override
  Future<List<RelationshipModel>> queryRelationships(String userId) async => [
        RelationshipModel(
          id: 'rel-1',
          studentId: 'stu-1',
          parentId: 'par-1',
          senderId: 'par-1',
          studentName: '林小宇',
          parentName: '王老师',
          status: RelationshipStatus.active,
        ),
        RelationshipModel(
          id: 'rel-2',
          studentId: 'stu-1',
          parentId: 'par-2',
          senderId: 'par-2',
          studentName: '林小宇',
          parentName: '李妈妈',
          status: RelationshipStatus.active,
        ),
      ];

  @override
  Future<List<ChatMessageModel>> queryChatMessages({
    required String relationshipId,
    required String requesterId,
  }) async {
    queryCalls++;
    final err = queryError;
    if (err != null) throw err;
    return List<ChatMessageModel>.of(
        messagesByRelationship[relationshipId] ?? const <ChatMessageModel>[]);
  }

  @override
  Future<ChatMessageModel> sendChatMessage({
    required String relationshipId,
    required String senderId,
    required String content,
  }) async => ChatMessageModel(
        id: 'srv-1',
        relationshipId: relationshipId,
        senderId: senderId,
        receiverId: 'par-1',
        content: content,
        createdAt: DateTime(2026, 9, 25, 17, 30),
        isRead: false,
      );

  @override
  Future<RelationshipModel> createRelationshipInvitation({
    required String senderId,
    required String targetPhone,
  }) => throw UnimplementedError('本组用例不涉及邀请');

  @override
  Future<void> updateRelationshipStatus({
    required String id,
    required RelationshipStatus status,
  }) => throw UnimplementedError('本组用例不涉及改关系状态');

  @override
  Future<void> revokeRelationship({required String id}) =>
      throw UnimplementedError('本组用例不涉及解除结伴');
}

void _seedUser(String id) {
  Get.put(AuthController());
  Get.find<AuthController>().currentUser.value = UserModel(
    id: id,
    name: '林小宇',
    phone: '13800000001',
    role: 'student',
    avatar: '👦',
  );
}

/// 与 `chat_send_visibility_test.dart` 同一手法：注册子类实例，
/// 让页面 `Get.put(ChatController())` 拿到的就是它。
ChatController _install({RelationshipRepository? repository}) {
  return Get.put<ChatController>(_TestChatController(repository: repository));
}

class _TestChatController extends ChatController {
  _TestChatController({super.repository});
}

void main() {
  setUp(() {
    Get.testMode = true;
  });

  tearDown(() {
    Get.reset();
  });

  group('控制器：refreshOnce（轮询的内核）', () {
    test('对面发来新消息后，轮询一次就能看到 —— 不用退出重进', () async {
      final repo = _PollStubRepo();
      final controller = _install(repository: repo);

      await controller.load('stu-1');
      expect(controller.messages, isEmpty, reason: '前置：进页面时会话是空的');

      // 模拟「对方此刻发了一条」（只落了库，客户端没有任何本地通知）。
      repo.messagesByRelationship['rel-1'] = [
        ChatMessageModel(
          id: 'srv-new',
          relationshipId: 'rel-1',
          senderId: 'par-1',
          receiverId: 'stu-1',
          content: '今晚早点评一下作业',
          createdAt: DateTime(2026, 9, 25, 17, 31),
          isRead: false,
        ),
      ];

      await controller.refreshOnce();

      expect(controller.messages.single.content, '今晚早点评一下作业',
          reason: '旧实现没有任何自动刷新，这条消息要重进页面才看得到');
    });

    test('反面：不轮询（不调 refreshOnce）列表就是不变 —— 保证上条不是恒绿', () async {
      final repo = _PollStubRepo();
      final controller = _install(repository: repo);

      await controller.load('stu-1');
      repo.messagesByRelationship['rel-1'] = [
        ChatMessageModel(
          id: 'srv-new',
          relationshipId: 'rel-1',
          senderId: 'par-1',
          receiverId: 'stu-1',
          content: '这条不会自己出现',
          createdAt: DateTime(2026, 9, 25, 17, 31),
          isRead: false,
        ),
      ];

      expect(controller.messages, isEmpty,
          reason: '这条钉住「旧行为确实看不到新消息」，防止修复后的用例变成恒绿');
    });

    test('轮询失败不清屏：消息保留、failure 不被盖写', () async {
      final repo = _PollStubRepo();
      final controller = _install(repository: repo);

      repo.messagesByRelationship['rel-1'] = [
        ChatMessageModel(
          id: 'srv-1',
          relationshipId: 'rel-1',
          senderId: 'par-1',
          receiverId: 'stu-1',
          content: '正在看的这段对话',
          createdAt: DateTime(2026, 9, 25, 17, 30),
          isRead: false,
        ),
      ];
      await controller.load('stu-1');
      expect(controller.messages.single.content, '正在看的这段对话');

      // 一次网络抖动。
      repo.queryError = Exception('offline');
      await controller.refreshOnce();

      expect(controller.messages.single.content, '正在看的这段对话',
          reason: '轮询失败清空 = 把正在看的对话刷成白屏；'
              '`loadConversation` 的清空语义是为切会话设计的，轮询不许沿用');
      expect(controller.failure.value, isNull,
          reason: '抖动不该把「读失败」的红条顶出来 —— 下一跳大概率就成功');
    });

    test('切会话竞态：迟到的旧会话响应不许覆盖新会话的消息', () async {
      final repo = _PollStubRepo();
      final controller = _install(repository: repo);

      repo.messagesByRelationship['rel-2'] = [
        ChatMessageModel(
          id: 'srv-2',
          relationshipId: 'rel-2',
          senderId: 'par-2',
          receiverId: 'stu-1',
          content: 'rel-2 的消息',
          createdAt: DateTime(2026, 9, 25, 17, 30),
          isRead: false,
        ),
      ];
      await controller.load('stu-1'); // 停在 rel-1，空会话

      // 轮询跑起来（打的是 rel-1），但在它返回前用户切到了 rel-2。
      final refresh = controller.refreshOnce();
      await controller.selectConversation('rel-2');
      expect(controller.messages.single.content, 'rel-2 的消息',
          reason: '前置：新会话的消息已经在树上');
      await refresh;

      expect(controller.messages.single.content, 'rel-2 的消息',
          reason: 'rel-1 的迟到响应若被应用，会把 rel-2 的对话顶掉 —— 消息串门');
    });
  });

  group('页面：轮询的接线与拆线', () {
    testWidgets('聊天页挂着时，过一个轮询间隔 queryCalls 要涨；卸载后要停', (tester) async {
      _seedUser('stu-1');
      final repo = _PollStubRepo();
      _install(repository: repo);

      await tester.pumpWidget(const MaterialApp(home: ChatPage()));
      await tester.pump(); // 让 initState 的 load 发出
      final callsAfterLoad = repo.queryCalls;
      expect(callsAfterLoad, greaterThan(0), reason: '前置：进页面至少读过一次');

      // 过一个轮询周期。
      await tester.pump(ChatController.pollInterval);
      expect(repo.queryCalls, greaterThan(callsAfterLoad),
          reason: '页面挂着却没人拉新消息 = 轮询没接上（虫子反馈的现象本体）');

      // 页面卸载后，定时器必须跟着停 —— 否则它活到进程结束，后台空转打接口。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final callsAfterDispose = repo.queryCalls;
      await tester.pump(ChatController.pollInterval * 2);
      expect(repo.queryCalls, callsAfterDispose,
          reason: '页面走了轮询还在跑 = 定时器泄漏（stopAutoRefresh 没被调用）');
    });
  });
}
