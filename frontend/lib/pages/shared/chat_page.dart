import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/chat_controller.dart';
import '../../services/data_api_client.dart';
import '../../utils/day_label.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final controller = Get.put(ChatController());
  final inputController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final user = Get.find<AuthController>().currentUser.value;
    if (user != null) controller.load(user.id);
    // 前台轮询：聊天页挂着的时候，每 5 秒拉一次当前会话 ——
    // 否则对方的消息只有重进页面才看得到（这不是网络延迟，
    // 旧实现根本没有任何自动刷新）。页面一走就停。
    controller.startAutoRefresh();
  }

  @override
  void dispose() {
    controller.stopAutoRefresh();
    inputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = Get.find<AuthController>().currentUser.value;
    return Scaffold(
      appBar: AppBar(title: const Text('伴学消息')),
      body: Obx(() {
        // ⚠️ **先看失败，再看空。** 这两者在旧实现里长得一样（都是空列表），
        // 而方向相反：前者是「读不到」，后者是「你还没结伴」。
        // 把失败显示成「暂无已组队成员」，会让用户去重新邀请一个早就存在的关系。
        final failure = controller.failure.value;
        if (failure != null) {
          return _buildFailure(failure);
        }
        if (controller.relationships.isEmpty) {
          return const Center(child: Text('暂无已组队成员，组队成功后才能发送消息'));
        }
        final selectedId = controller.selectedRelationshipId.value;
        final relationship = controller.relationships.firstWhere(
          (r) => r.id == selectedId,
          orElse: () => controller.relationships.first,
        );
        final otherName = relationship.studentId == user?.id
            ? relationship.parentName
            : relationship.studentName;
        return Column(
          children: [
            _buildPartnerSelector(user?.id ?? ''),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              color: AppColors.primary.withValues(alpha: 0.08),
              child: Text('正在与 $otherName 对话'),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: controller.messages.length,
                itemBuilder: (context, index) {
                  final messages = controller.messages;
                  final message = messages[index];
                  final mine = message.isMine(user?.id ?? '');
                  // 只在**跨天**时插入日期分隔条。
                  // 每条都标日期会把聊天记录变成一张表，而人真正需要区分的是
                  // 「这一段是哪天说的」—— 同一天里连续几十条共享一个日期。
                  final previous = index > 0 ? messages[index - 1] : null;
                  final showDay = previous == null ||
                      !isSameCalendarDay(previous.createdAt, message.createdAt);

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (showDay) _buildDayDivider(message.createdAt),
                      Align(
                        alignment: mine
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: mine
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          children: [
                            Container(
                              constraints: const BoxConstraints(maxWidth: 300),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: mine ? AppColors.primary : Colors.white,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: AppColors.border),
                              ),
                              child: Text(
                                message.content,
                                style: TextStyle(
                                  color: mine ? Colors.white : AppColors.text,
                                ),
                              ),
                            ),
                            // 每条都标时刻，但**压低存在感**（10px 灰字）：
                            // 它是要被查的，不是要被读的。原来是干脆没有 ——
                            // 用户的原话是「看不出时间」，那不只是缺日期，
                            // 同一小时里连发了什么顺序也分不清。
                            Padding(
                              padding: const EdgeInsets.only(
                                top: 3,
                                left: 4,
                                right: 4,
                                bottom: 10,
                              ),
                              child: Text(
                                formatClock(message.createdAt),
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: inputController,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(relationship.id),
                        decoration: const InputDecoration(
                          hintText: '输入消息',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: () => _send(relationship.id),
                      icon: const Icon(Icons.send),
                      tooltip: '发送消息',
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      }),
    );
  }

  /// 跨天时的日期分隔条。
  ///
  /// 用胶囊而不是一行裸文字：裸文字混在气泡之间时，扫一眼分不出
  /// 「这是系统提示还是某个人说的话」。这也是用户要的「明显看得出来」。
  Widget _buildDayDivider(DateTime when) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.textMuted.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            formatDayLabel(when),
            style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
          ),
        ),
      ),
    );
  }

  Widget _buildPartnerSelector(String currentUserId) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: AppColors.border),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: controller.relationships.map((rel) {
            final otherName = rel.studentId == currentUserId
                ? rel.parentName
                : rel.studentName;
            final isSelected = rel.id == controller.selectedRelationshipId.value;
            return Padding(
              padding: const EdgeInsets.only(right: 10),
              child: GestureDetector(
                onTap: () => controller.selectConversation(rel.id),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppColors.primary
                        : AppColors.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: isSelected
                          ? AppColors.primary
                          : AppColors.border,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 12,
                        backgroundColor: isSelected
                            ? Colors.white
                            : AppColors.primary,
                        child: Text(
                          otherName.isNotEmpty ? otherName[0] : '?',
                          style: TextStyle(
                            fontSize: 12,
                            color: isSelected
                                ? AppColors.primary
                                : Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        otherName,
                        style: TextStyle(
                          color: isSelected ? Colors.white : AppColors.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  /// 加载失败时的界面：说清原因 + 给一个重试入口。
  ///
  /// 不给重试按钮的话，用户唯一能做的是退出去再进来 —— 而这条路径在
  /// 「失败是暂时的（网络抖动）」时能好，在「失败是持续的（端点不对）」时
  /// 只是把同一个错重演一遍，还多花一次页面往返。按钮让这一次重试变便宜。
  Widget _buildFailure(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 40, color: AppColors.border),
            const SizedBox(height: 12),
            const Text(
              '消息没能加载',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.text),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                final user = Get.find<AuthController>().currentUser.value;
                if (user != null) controller.load(user.id);
              },
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  /// 发送。
  ///
  /// ⚠️ **这里必须自己接异常。** 旧实现在云端模式下每次都会抛 `not_implemented`
  /// （服务端当时没有聊天端点），而 `_send` 既不 catch、也不看结果 ——
  /// 于是异常一路冒到 `Obx` 之外被框架吞掉，表现是**点发送按钮毫无反应**，
  /// 而且 `clear()` 照跑，用户以为自己发出去了。
  ///
  /// 两条纪律：
  ///   ① **失败不清空输入框** —— 内容还在，用户可以直接重试，不用重打一遍；
  ///   ② **失败要说出来** —— 静默失败是本项目的头号 bug 类型，
  ///      一次「点不动」比一句错误提示难查得多。
  Future<void> _send(String relationshipId) async {
    final content = inputController.text.trim();
    if (content.isEmpty) return;
    try {
      await controller.send(relationshipId, content);
      inputController.clear();
    } catch (e) {
      if (!mounted) return;
      Get.snackbar(
        '消息没发出去',
        _readableError(e),
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

  /// 把异常变成一句人话。
  ///
  /// ⚠️ 走 `userMessage` 而不是 `message`（2026-10-06 修正）：这里原先的注释写着
  /// 「自带面向用户的 `message`，直接用」—— 那句话**只对服务端回的文案成立**。
  /// `network` / `timeout` 的 `message` 是客户端自己拼的，带完整 URL 与底层
  /// 英文异常。`userMessage` 对服务端文案原样回落、只把这两个 code 换成人话，
  /// 所以换掉不丢原因。
  /// 其余异常不把 `toString()` 糊到界面上（那是给开发者看的），换成一句可行动的提示。
  String _readableError(Object error) {
    if (error is DataApiException) return error.userMessage;
    return '请检查网络后重试';
  }
}
