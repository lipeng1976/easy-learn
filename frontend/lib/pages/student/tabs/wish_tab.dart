import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../constants/app_colors.dart';
import '../../../controllers/point_controller.dart';
import '../../../controllers/student_controller.dart';
import '../../../models/wish_model.dart';
import '../../../utils/date_utils.dart' as date_utils;
import '../../../widgets/point_widgets.dart';
import '../../shared/point_ledger_page.dart';
import '../../../utils/pop_route.dart';

class WishTab extends StatelessWidget {
  const WishTab({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<StudentController>();
    final points = PointController.to;

    return Obx(() {
      // 与家长端、服务端 ORDER BY 同一口径：申请的排在前、新的在上。
      // 这里在页面侧排一次，是因为新建心愿会 insert(0) 到本地列表，
      // 不重拉页面时顺序会跟服务端不一致。
      final activeWishes = sortWishesByRequestTimeDesc(
        controller.wishes.where((w) => !w.isArchived).toList(),
      );
      final archivedWishes = sortWishesByRequestTimeDesc(
        controller.wishes.where((w) => w.isArchived).toList(),
      );
      final account = points.account.value;
      final studentId = points.studentId.value;

      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 心愿能不能兑现取决于余额，所以把余额放在心愿列表上面：
          // 孩子看愿望之前先看到自己攒了多少分，「还差多少」才有参照。
          if (studentId.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: PointBalanceCard(
                account: account,
                compact: true,
                onOpenLedger: () => Get.to(
                  () => PointLedgerPage(studentId: studentId),
                ),
              ),
            ),
          Row(
            children: [
              const Text(
                '我的心愿',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: () => _showCreateWishDialog(context, controller),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新增心愿'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...activeWishes.map(
            (wish) => _WishCard(
              wish: wish,
              balance: account.balance,
              onConfirm: () => controller.confirmWish(wish.id),
              onArchive: () => controller.archiveWish(wish.id),
              onRequestRedeem: () => controller.requestWishRedeem(wish.id),
              onCancelRedeem: () => controller.cancelWishRedeem(wish.id),
            ),
          ),
          if (archivedWishes.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Text(
              '已归档',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(height: 12),
            ...archivedWishes.map(
              (wish) => _WishCard(wish: wish, archived: true),
            ),
          ],
        ],
      );
    });
  }

  void _showCreateWishDialog(
    BuildContext context,
    StudentController controller,
  ) {
    final titleController = TextEditingController();
    final descController = TextEditingController();
    var isPublic = true.obs;
    var expectedDate = Rx<DateTime?>(null);

    Get.dialog(
      AlertDialog(
        title: const Text('新增心愿'),
        content: Obx(() {
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    labelText: '心愿标题',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '心愿描述',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: DateTime.now().add(const Duration(days: 1)),
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) {
                      expectedDate.value = picked;
                    }
                  },
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: '预期时间',
                      border: OutlineInputBorder(),
                      suffixIcon: Icon(Icons.calendar_today, size: 20),
                    ),
                    child: Text(
                      expectedDate.value != null
                          ? date_utils.DateUtilsX.formatChineseDate(
                              expectedDate.value!,
                            )
                          : '选择心愿预期完成日期',
                      style: TextStyle(
                        color: expectedDate.value != null
                            ? AppColors.text
                            : AppColors.textMuted,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => expectedDate.value = null,
                    child: const Text('清除日期', style: TextStyle(fontSize: 12)),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('公开给家长'),
                  value: isPublic.value,
                  onChanged: (v) => isPublic.value = v,
                ),
              ],
            ),
          );
        }),
        actions: [
          TextButton(onPressed: () => popRoute(context), child: const Text('取消')),
          ElevatedButton(
            onPressed: () {
              if (titleController.text.trim().isEmpty) return;
              controller.addWish(
                title: titleController.text.trim(),
                description: descController.text.trim(),
                isPublic: isPublic.value,
                expectedDate: expectedDate.value,
              );
              popRoute(context);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }
}

class _WishCard extends StatelessWidget {
  final WishModel wish;
  final int balance;
  final VoidCallback? onConfirm;
  final VoidCallback? onArchive;
  final VoidCallback? onRequestRedeem;
  final VoidCallback? onCancelRedeem;
  final bool archived;

  const _WishCard({
    required this.wish,
    this.balance = 0,
    this.onConfirm,
    this.onArchive,
    this.onRequestRedeem,
    this.onCancelRedeem,
    this.archived = false,
  });

  @override
  Widget build(BuildContext context) {
    final bothConfirmed = wish.parentConfirmed && wish.studentConfirmed;
    // 取到局部变量才能让 Dart 把可空类型收窄 —— 直接访问 `wish.expectedDate`
    // 是字段读取，判过 null 也不会被提升。
    final expectedDate = wish.expectedDate;
    final hasExpectedDate = expectedDate != null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final expected = expectedDate == null
        ? null
        : DateTime(
            expectedDate.year,
            expectedDate.month,
            expectedDate.day,
          );
    final diff = expected?.difference(today).inDays;

    Color? dateColor;
    String? dateLabel;
    // 已兑现的心愿不该再催逾期：它已经实现了，日期只是历史。
    // 与家长端 `_buildExpectedDateRow` 同一口径。
    if (diff != null && !archived && !bothConfirmed && !wish.isRedeemed) {
      if (diff < 0) {
        dateColor = AppColors.danger;
        dateLabel = '已逾期 ${-diff} 天';
      } else if (diff == 0) {
        dateColor = AppColors.warning;
        dateLabel = '今天到期';
      } else if (diff <= 3) {
        dateColor = AppColors.warning;
        dateLabel = '还有 $diff 天';
      } else {
        dateColor = AppColors.textMuted;
        dateLabel = '还有 $diff 天';
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: archived ? Colors.grey.shade50 : Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            wish.title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(wish.description),
          if (hasExpectedDate) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.event_outlined,
                  size: 16,
                  color: dateColor ?? AppColors.textMuted,
                ),
                const SizedBox(width: 4),
                Text(
                  date_utils.DateUtilsX.formatChineseDate(expectedDate),
                  style: TextStyle(
                    color: dateColor ?? AppColors.textMuted,
                    fontSize: 13,
                  ),
                ),
                if (dateLabel != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: (dateColor ?? AppColors.textMuted).withValues(
                        alpha: 0.12,
                      ),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      dateLabel,
                      style: TextStyle(
                        color: dateColor ?? AppColors.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              if (wish.isPublic) const Text('公开给家长') else const Text('仅自己可见'),
              const Spacer(),
              if (!archived && !wish.parentConfirmed && !wish.studentConfirmed)
                ElevatedButton(onPressed: onConfirm, child: const Text('确认完成'))
              else if (!archived &&
                  wish.parentConfirmed &&
                  !wish.studentConfirmed)
                const Text('等待学生确认', style: TextStyle(color: AppColors.warning))
              else if (!archived &&
                  !wish.parentConfirmed &&
                  wish.studentConfirmed)
                const Text('等待家长确认', style: TextStyle(color: AppColors.warning))
              else if (!archived && bothConfirmed)
                Row(
                  children: [
                    const Text(
                      '已闭环',
                      style: TextStyle(color: AppColors.success),
                    ),
                    const SizedBox(width: 8),
                    TextButton(onPressed: onArchive, child: const Text('归档')),
                  ],
                ),
            ],
          ),
          if (!archived) _buildRedeemRow(),
        ],
      ),
    );
  }

  /// 积分兑换这一行。
  ///
  /// 申请**不扣分**，只是告诉家长「我想兑这个」；扣分发生在家长确认兑现时。
  /// 所以这里余额不够时按钮直接禁用 —— 让孩子点进一个必然失败的操作，
  /// 不如把「还差多少」摆在眼前。
  Widget _buildRedeemRow() {
    if (!wish.needsPoints) return const SizedBox.shrink();

    const divider = SizedBox(height: 10);

    if (wish.isRedeemed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          divider,
          Row(
            children: [
              Icon(Icons.check_circle, size: 16, color: AppColors.success),
              SizedBox(width: 6),
              Text('已兑现', style: TextStyle(color: AppColors.success)),
            ],
          ),
        ],
      );
    }

    if (wish.isRedeemPending) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          divider,
          Row(
            children: [
              const Icon(
                Icons.hourglass_bottom,
                size: 16,
                color: AppColors.warning,
              ),
              const SizedBox(width: 6),
              const Text(
                '已申请兑换，等家长确认',
                style: TextStyle(color: AppColors.warning),
              ),
              const Spacer(),
              TextButton(onPressed: onCancelRedeem, child: const Text('撤回申请')),
            ],
          ),
        ],
      );
    }

    final missing = wish.pointCost - balance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        divider,
        Row(
          children: [
            const Icon(Icons.stars, size: 16, color: AppColors.primary),
            const SizedBox(width: 6),
            Text(
              '兑换需要 ${wish.pointCost} 分',
              style: const TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              missing > 0 ? '还差 $missing 分' : '积分已够',
              style: TextStyle(
                fontSize: 12,
                color: missing > 0 ? AppColors.danger : AppColors.success,
              ),
            ),
            const Spacer(),
            if (missing > 0)
              const Text(
                '先去赚分',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              )
            else
              ElevatedButton(
                onPressed: onRequestRedeem,
                child: const Text('申请兑换'),
              ),
          ],
        ),
        if (wish.isRedeemRejected)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              '上次申请没有被同意，积分没有扣除。',
              style: TextStyle(color: AppColors.danger, fontSize: 12),
            ),
          ),
      ],
    );
  }
}
