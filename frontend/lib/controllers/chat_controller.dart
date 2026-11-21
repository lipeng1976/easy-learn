import 'dart:async';

import 'package:get/get.dart';

import '../models/chat_message_model.dart';
import '../models/relationship_model.dart';
import '../repositories/relationship_repository.dart';
import '../services/data_api_client.dart';
import '../services/database_service.dart';

class ChatController extends GetxController {
  ChatController({RelationshipRepository? repository})
    : _database = repository ?? DatabaseService.instance;

  final RelationshipRepository _database;
  final RxList<RelationshipModel> relationships = <RelationshipModel>[].obs;
  final RxList<ChatMessageModel> messages = <ChatMessageModel>[].obs;
  final RxBool isLoading = false.obs;
  final RxString selectedRelationshipId = ''.obs;
  String? currentUserId;

  /// 最近一次加载/发送的失败原因（`null` = 没有失败）。
  ///
  /// ⚠️ 存在的理由是**区分两种"空"**：`relationships` 为空可能是
  /// 「真的还没有结伴」，也可能是「读失败了」。两者在界面上长得一模一样
  /// （都是空列表），而排查方向完全相反 —— 旧实现把失败咽了下去，
  /// 于是云端模式下「服务端没有聊天端点」这件事被显示成
  /// 「暂无已组队成员，组队成功后才能发送消息」，一句彻头彻尾的误导。
  final RxnString failure = RxnString();

  /// 聊天页在前台时的轮询定时器（[startAutoRefresh] 开、[stopAutoRefresh] 关）。
  Timer? _pollTimer;

  /// 轮询间隔。聊天是两人对话，5 秒是「对方发完一句话、你很快能看到」
  /// 与「别把请求打到骚扰级频率」之间的折中。
  ///
  /// ⚠️ 这是**页面级**轮询：只在聊天页挂载期间跑，页面一走就停 ——
  /// 和 B7 首页「刻意不做轮询」不矛盾（那是后台常驻轮询，那是拿
  /// 电池流量换不缺的时效；这个是前台对话场景，时效本来就是需求）。
  static const Duration pollInterval = Duration(seconds: 5);

  /// 开启聊天页的前台轮询。重复调用是幂等的（页面 initState 重跑不叠加定时器）。
  void startAutoRefresh() {
    _pollTimer ??= Timer.periodic(pollInterval, (_) => refreshOnce());
  }

  /// 停止轮询。聊天页 dispose 时必须调，否则定时器跟着 controller 活到进程结束。
  void stopAutoRefresh() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// 轮询拉一次当前会话。与 [loadConversation] 的区别在**失败语义**：
  ///
  /// `loadConversation` 的「失败清空消息列表」是为**切换会话**设计的 ——
  /// 留着上一段会话的消息会让人以为是这个人说的。但轮询时清空是灾难：
  /// 一次网络抖动就把正在看的对话刷成白屏（而下一跳大概率又成功），
  /// 「闪一下没了又回来」比「晚 5 秒看到」难接受得多。
  /// 所以轮询失败 = **什么都不动**，消息留着、failure 不盖写。
  /// 判据在 `test/chat_auto_refresh_test.dart`。
  Future<void> refreshOnce() async {
    final userId = currentUserId;
    final relationshipId = selectedRelationshipId.value;
    if (userId == null || relationshipId.isEmpty) return;
    try {
      final fresh = await _database.queryChatMessages(
        relationshipId: relationshipId,
        requesterId: userId,
      );
      // 只在还停在同一段对话时应用：用户在定时器触发前后切换了会话，
      // 旧会话的响应迟到会覆盖新会话的消息 —— 消息串门，不报错。
      if (selectedRelationshipId.value != relationshipId) return;
      messages.value = fresh;
      failure.value = null;
    } catch (_) {
      // 静默：见方法注释。轮询失败不改变任何可见状态。
    }
  }

  Future<void> load(String userId) async {
    currentUserId = userId;
    isLoading.value = true;
    failure.value = null;
    try {
      relationships.value = (await _database.queryRelationships(userId))
          .where((item) => item.isActive)
          .toList();
      if (relationships.isNotEmpty) {
        selectedRelationshipId.value = relationships.first.id;
        await loadConversation(relationships.first.id);
      }
    } catch (e) {
      // 如实记下，交给界面显示。**不吞**：吞掉的话「结伴列表读失败」
      // 会伪装成「你还没结伴」，用户会去重新邀请一个早就在的关系。
      failure.value = _readableError(e);
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> selectConversation(String relationshipId) async {
    selectedRelationshipId.value = relationshipId;
    await loadConversation(relationshipId);
  }

  Future<void> loadConversation(String relationshipId) async {
    final userId = currentUserId;
    if (userId == null) return;
    try {
      messages.value = await _database.queryChatMessages(
        relationshipId: relationshipId,
        requesterId: userId,
      );
      failure.value = null;
    } catch (e) {
      // 读消息失败时**清空列表**：留着上一段会话的消息会让人以为
      // 那些话是当前这个人说的。空 + 一句原因，比错的内容安全。
      //
      // ⚠️ **必须写成 `<ChatMessageModel>[]`，不能写 `const []`。**
      // `RxList.value = 某个列表` 是把这个列表**当成底层存储**（不复制），
      // 而 `const []` 是不可增的 —— 之后发送成功时那句 `messages.add(...)`
      // 会抛 `Unsupported operation: Cannot add to an unmodifiable list`。
      //
      // 这条正是真机「发送消息发不出去」的成因，而且是**最阴的一种**：
      //   ① 走进这个 catch 本来就意味着"刚才读过一次、失败了"（网络抖动就够）；
      //   ② 之后发送其实**已经成功落到服务端**，是本地这句 add 炸的；
      //   ③ 界面只会说「消息没发出去」并保留输入框 —— 用户以为自己没发出去，
      //      对方其实收到了。
      // 判据在 `test/chat_send_visibility_test.dart` 的
      // 「读失败之后仍然发得出去」那一条。
      messages.value = <ChatMessageModel>[];
      failure.value = _readableError(e);
    }
  }

  /// 发送。**异常照常抛出**，由调用方决定怎么提示 —— 它离界面更近，
  /// 也知道该保留输入框还是清空。
  Future<void> send(String relationshipId, String content) async {
    final userId = currentUserId;
    if (userId == null || content.trim().isEmpty) return;
    final message = await _database.sendChatMessage(
      relationshipId: relationshipId,
      senderId: userId,
      content: content,
    );
    // 采纳服务端返回的那一行（迁移规则 R2）：`id` / `createdAt` 都由服务端定。
    messages.add(message);
    failure.value = null;
  }

  /// 把异常变成一句人话（与 `chat_page.dart` 同一口径，避免两处措辞漂开）。
  ///
  /// ⚠️ **`userMessage` 而不是 `message`**（2026-10-06）：后者在 `network` /
  /// `timeout` 上是客户端自己拼的 `连不上数据服务（https://…）：ClientException: …`
  /// —— 完整地址加底层英文异常，一起糊到聊天页上。服务端回来的业务文案两者
  /// 完全相同，所以换掉不丢原因，只挡掉不该给人看的那部分。
  String _readableError(Object error) {
    if (error is DataApiException) return error.userMessage;
    return '请检查网络后重试';
  }
}
