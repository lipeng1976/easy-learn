import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/notification_controller.dart';
import '../../controllers/parent_controller.dart';
import '../../controllers/profile_controller.dart';
import '../../models/relationship_model.dart';

class BindingPage extends StatefulWidget {
  const BindingPage({super.key});

  @override
  State<BindingPage> createState() => _BindingPageState();
}

class _BindingPageState extends State<BindingPage> {
  final phoneController = TextEditingController();
  final profileController = Get.put(ProfileController());

  @override
  void initState() {
    super.initState();
    final user = Get.find<AuthController>().currentUser.value;
    if (user != null) profileController.load(user.id);
  }

  @override
  void dispose() {
    phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = Get.find<AuthController>().currentUser.value;
    final isParent = user?.role == 'parent';
    final myId = user?.id ?? '';

    return Scaffold(
      appBar: AppBar(title: const Text('伴学结伴')),
      body: RefreshIndicator(
        onRefresh: () => profileController.load(myId),
        child: Obx(() {
          if (profileController.isLoading.value) {
            return const Center(child: CircularProgressIndicator());
          }

          final all = profileController.relationships;
          final pendingReceived = all
              .where(
                (r) =>
                    r.status == RelationshipStatus.pending && !r.isSentBy(myId),
              )
              .toList();
          final pendingSent = all
              .where(
                (r) =>
                    r.status == RelationshipStatus.pending && r.isSentBy(myId),
              )
              .toList();
          final active = all
              .where((r) => r.status == RelationshipStatus.active)
              .toList();
          final others = all
              .where(
                (r) =>
                    r.status == RelationshipStatus.rejected ||
                    r.status == RelationshipStatus.removed,
              )
              .toList();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildInviteCard(isParent),
              const SizedBox(height: 20),
              if (pendingReceived.isNotEmpty) ...[
                _buildSectionHeader(
                  '待确认的结伴请求',
                  count: pendingReceived.length,
                  color: AppColors.warning,
                ),
                const SizedBox(height: 8),
                ...pendingReceived.map(
                  (r) => _buildPendingReceivedCard(r, isParent, myId),
                ),
                const SizedBox(height: 16),
              ],
              if (pendingSent.isNotEmpty) ...[
                _buildSectionHeader(
                  '我发出的邀请',
                  count: pendingSent.length,
                  color: AppColors.primary,
                ),
                const SizedBox(height: 8),
                ...pendingSent.map((r) => _buildPendingSentCard(r, isParent)),
                const SizedBox(height: 16),
              ],
              if (active.isNotEmpty) ...[
                _buildSectionHeader(
                  '已结伴',
                  count: active.length,
                  color: AppColors.success,
                ),
                const SizedBox(height: 8),
                ...active.map((r) => _buildActiveCard(r, isParent)),
                const SizedBox(height: 16),
              ],
              if (others.isNotEmpty) ...[
                _buildSectionHeader('其他', count: others.length),
                const SizedBox(height: 8),
                ...others.map((r) => _buildOtherCard(r, isParent, myId)),
              ],
              if (all.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: Center(
                    child: Text(
                      '还没有结伴关系，快去邀请吧',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                ),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildInviteCard(bool isParent) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isParent ? Icons.school : Icons.family_restroom,
                color: AppColors.primary,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                isParent ? '按手机号邀请学生' : '按手机号邀请家长',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: phoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              hintText: '输入对方手机号',
              border: OutlineInputBorder(),
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () =>
                  _invite(Get.find<AuthController>().currentUser.value!.id),
              icon: const Icon(Icons.send, size: 18),
              label: const Text('发送结伴邀请'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, {int? count, Color? color}) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 18,
          decoration: BoxDecoration(
            color: color ?? AppColors.textMuted,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        if (count != null && count > 0) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: (color ?? AppColors.textMuted).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                color: color ?? AppColors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildPendingReceivedCard(
    RelationshipModel item,
    bool isParent,
    String myId,
  ) {
    final otherName = isParent ? item.studentName : item.parentName;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: AppColors.warning.withValues(alpha: 0.12),
            child: const Icon(Icons.person_add_alt_1, color: AppColors.warning),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  otherName,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isParent
                      ? '学生 ${item.studentName} 向您发出结伴邀请'
                      : '家长 ${item.parentName} 向您发出结伴邀请',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                onPressed: () => _respond(item.id, RelationshipStatus.active),
                icon: const Icon(Icons.check_circle, color: AppColors.success),
                label: const Text(
                  '通过',
                  style: TextStyle(color: AppColors.success),
                ),
              ),
              TextButton.icon(
                onPressed: () => _respond(item.id, RelationshipStatus.rejected),
                icon: const Icon(Icons.cancel, color: AppColors.danger),
                label: const Text(
                  '拒绝',
                  style: TextStyle(color: AppColors.danger),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPendingSentCard(RelationshipModel item, bool isParent) {
    final otherName = isParent ? item.studentName : item.parentName;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: AppColors.primary.withValues(alpha: 0.12),
            child: const Icon(Icons.hourglass_top, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  otherName,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '等待对方确认邀请',
                  style: TextStyle(
                    color: AppColors.warning.withValues(alpha: 0.9),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text(
              '待确认',
              style: TextStyle(
                color: AppColors.warning,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveCard(RelationshipModel item, bool isParent) {
    final otherName = isParent ? item.studentName : item.parentName;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: AppColors.success.withValues(alpha: 0.12),
            child: const Icon(Icons.link, color: AppColors.success),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  otherName,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isParent ? '学生：${item.studentName}' : '家长：${item.parentName}',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Get.toNamed('/chat'),
            icon: const Icon(
              Icons.chat_bubble_outline,
              color: AppColors.primary,
            ),
            tooltip: '发消息',
          ),
          // 解除入口**只对家长渲染**（2026-09-26 的产品决定）。
          //
          // 学生看不到这个按钮，不是「禁用」——比起点了报错的按钮，
          // 不给一个本来就不该出现的按钮更诚实（服务端也会 403 挡一层，
          // 但那是边界，不是界面设计）。
          if (isParent)
            IconButton(
              onPressed: () => _revoke(item),
              icon: const Icon(Icons.link_off, color: AppColors.danger),
              tooltip: '解除结伴',
            ),
        ],
      ),
    );
  }

  Widget _buildOtherCard(RelationshipModel item, bool isParent, String myId) {
    final otherName = isParent ? item.studentName : item.parentName;
    final label = _statusLabel(item.status, item.isSentBy(myId));
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: AppColors.border,
            child: Icon(
              item.status == RelationshipStatus.rejected
                  ? Icons.person_off_outlined
                  : Icons.person_outline,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              otherName,
              style: const TextStyle(fontSize: 15, color: AppColors.textMuted),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.textMuted.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _invite(String senderId) async {
    final phone = phoneController.text.trim();
    if (phone.isEmpty) {
      Get.snackbar('提示', '请输入对方手机号');
      return;
    }
    try {
      await profileController.inviteByPhone(senderId: senderId, phone: phone);
      phoneController.clear();
      Get.snackbar('邀请已发送', '等待对方确认后即可结伴');
    } catch (error) {
      Get.snackbar('发送失败', error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _respond(String id, RelationshipStatus status) async {
    await profileController.updateRelationship(id, status);
    final action = status == RelationshipStatus.active ? '已通过' : '已拒绝';
    Get.snackbar(
      action,
      status == RelationshipStatus.active ? '结伴成功' : '已拒绝邀请',
    );

    if (Get.isRegistered<NotificationController>()) {
      Get.find<NotificationController>().addNotification(
        title: '结伴通知',
        body: status == RelationshipStatus.active ? '结伴成功，可以开始聊天了' : '已拒绝结伴邀请',
      );
    }
  }

  /// 解除结伴（**家长端，单方立即生效**）。
  ///
  /// 二次确认必须做，而**内容比「确定吗？」重要得多**：这个动作在家长眼里
  /// 是「孩子的数据忽然全没了」。所以确认框要把三件事说清：
  ///
  ///   ① 数据**不会被删除** —— 孩子的记录都还在他那边；
  ///   ② **重新结伴后仍能看到全部历史**，包括解除这段时间孩子自己记的。
  ///      这一条是 2026-09-26 与产品确认过的口径，**必须让人在点之前知道** ——
  ///      否则「解除」会被理解成「清空」，而它其实只是「暂时看不见」；
  ///   ③ 孩子会收到一条通知 —— 所以别指望这是悄悄断开。
  ///
  /// ⚠️ 成功后要刷**两个**控制器，少一个就会看到「列表里已解除、首页还看得到孩子」：
  ///   · `ProfileController` —— 重拉 profile 与关系列表；
  ///   · `ParentController` —— 它自己缓存了 `boundStudents` / 作业 / 照片 /
  ///     打卡账本，且都是按「当时 active 的关系」过滤过的。不重拉的话
  ///     那个孩子会继续出现在首页、积分、复习各页 —— 数据是旧的，但看起来像是
  ///     「解除没生效」。
  ///
  /// 失败不吞：非家长是 403、关系不是 active 也是 403，两种都该让用户看见。
  Future<void> _revoke(RelationshipModel item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('解除与 ${item.studentName} 的结伴？'),
        content: const Text(
          '解除后你将看不到 TA 的作业、打卡与错题，也不能再和 TA 发消息。\n\n'
          '· 数据不会被删除，孩子的记录都还在他那边；\n'
          '· 如果以后重新结伴，你仍然可以看到全部历史，'
          '包括这段时间孩子自己记录的；\n'
          '· 孩子会收到一条「结伴已解除」的通知。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              '解除结伴',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final myId = Get.find<AuthController>().currentUser.value?.id ?? '';
    try {
      await profileController.revokeRelationship(id: item.id, requesterId: myId);
      if (Get.isRegistered<ParentController>()) {
        await Get.find<ParentController>().loadData();
      }
      Get.snackbar('已解除', '你与 ${item.studentName} 的结伴已解除');
    } catch (e) {
      Get.snackbar('解除失败', e.toString().replaceFirst('Bad state: ', ''));
    }
  }

  String _statusLabel(RelationshipStatus status, bool isSentByMe) {
    switch (status) {
      case RelationshipStatus.pending:
        return isSentByMe ? '等待对方确认' : '等待我确认';
      case RelationshipStatus.active:
        return '已结伴';
      case RelationshipStatus.rejected:
        return '已拒绝';
      case RelationshipStatus.removed:
        return '已解除';
    }
  }
}
