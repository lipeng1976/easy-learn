import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../constants/app_colors.dart';
import '../../../controllers/parent_controller.dart';
import '../../../utils/date_utils.dart' as date_utils;
import '../../../utils/pop_route.dart';
import '../../../widgets/int_input_dialog.dart';

class WishesParentTab extends StatelessWidget {
  const WishesParentTab({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ParentController>();

    return Obx(() {
      final activeWishes = controller.visibleWishes
          .where((w) => !w.isArchived)
          .toList();
      final balance = controller.points.account.value.balance;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              const Text(
                '公开心愿',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              // 家长在这里做定价与兑现决定，得先看得见孩子有多少分，
              // 否则「够不够扣」只能靠猜。
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.stars, size: 14, color: AppColors.primary),
                    const SizedBox(width: 4),
                    Text(
                      '孩子有 $balance 分',
                      style: const TextStyle(
                        color: AppColors.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (activeWishes.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  '孩子还没有公开的心愿',
                  style: TextStyle(color: AppColors.textMuted),
                ),
              ),
            ),
          ...activeWishes.map(
            (wish) => Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    wish.title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(wish.description),
                  if (wish.expectedDate != null) ...[
                    const SizedBox(height: 8),
                    _buildExpectedDateRow(wish),
                  ],
                  const SizedBox(height: 10),
                  _buildCostChip(wish),
                  const SizedBox(height: 10),
                  _buildStatusRow(context, controller, wish),
                ],
              ),
            ),
          ),
        ],
      );
    });
  }

  /// 定价状态。
  Widget _buildCostChip(dynamic wish) {
    final cost = (wish.pointCost as int?) ?? 0;
    final text = cost > 0 ? '兑现需要 $cost 积分' : '不需要积分';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: (cost > 0 ? AppColors.warning : AppColors.success).withValues(
          alpha: 0.12,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: cost > 0 ? AppColors.warning : AppColors.success,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildStatusRow(
    BuildContext context,
    ParentController controller,
    dynamic wish,
  ) {
    // 兑换申请优先显示 —— 孩子正等着，这是唯一需要家长立刻做决定的事。
    if (wish.isRedeemPending) {
      final cost = (wish.pointCost as int?) ?? 0;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text(
            '孩子申请兑现',
            style: TextStyle(color: AppColors.warning),
          ),
          ElevatedButton(
            onPressed: () async {
              final result = await controller.approveWishRedeem(wish.id);
              Get.snackbar(result.ok ? '已兑现' : '还不能兑现', result.message);
            },
            child: Text(cost > 0 ? '同意并扣 $cost 分' : '同意兑现'),
          ),
          OutlinedButton(
            onPressed: () => _confirmReject(context, controller, wish),
            child: const Text('拒绝'),
          ),
        ],
      );
    }

    if (wish.isRedeemed) {
      return Row(
        children: const [
          Icon(Icons.check_circle, size: 16, color: AppColors.success),
          SizedBox(width: 6),
          Text('已兑现', style: TextStyle(color: AppColors.success)),
        ],
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (!wish.parentConfirmed)
          const Text('待家长确认', style: TextStyle(color: AppColors.warning))
        else if (!wish.studentConfirmed)
          const Text(
            '等待学生确认',
            style: TextStyle(color: AppColors.warning),
          )
        else
          const Text('已闭环', style: TextStyle(color: AppColors.success)),
        if (wish.studentConfirmed && wish.isRedeemRejected)
          const Text('上次申请已拒绝', style: TextStyle(color: AppColors.danger)),
        const SizedBox(width: 4),
        // 定价：家长单方决定，孩子还没申请前都能改。
        // 申请之后藏起来 —— 否则会出现「按 30 分攒够了，家长改成 50」。
        if (!wish.isRedeemPending)
          TextButton(
            onPressed: () => _editCost(context, controller, wish),
            child: const Text('设置积分'),
          ),
        if (!wish.parentConfirmed)
          ElevatedButton(
            onPressed: () => controller.confirmWish(wish.id),
            child: const Text('确认已实现'),
          ),
      ],
    );
  }

  Future<void> _editCost(
    BuildContext context,
    ParentController controller,
    dynamic wish,
  ) async {
    final value = await showIntInputDialog(
      title: '设置兑换积分',
      initial: (wish.pointCost as int?) ?? 0,
      label: '需要的积分',
      hint: '孩子申请兑现、你确认之后才会扣分。填 0 表示这个心愿不消耗积分。',
      // 心愿定价不设上限，也不显示「范围 x – y 分」那一行。
      max: null,
      // 清空输入框 = 0 = 不消耗积分。这是这个弹窗原本的口径，原样保留。
      emptyValue: 0,
    );
    if (value == null) return;
    await controller.setWishPointCost(wish.id as String, value);
  }

  Future<void> _confirmReject(
    BuildContext context,
    ParentController controller,
    dynamic wish,
  ) async {
    // 弹窗**直接返回理由文本**，而不是「确认了没有」再回头去读它内部那个
    // `TextEditingController`：那个控制器随弹窗一起销毁，出来之后再读就晚了。
    final reason = await Get.dialog<String>(const _RejectRedeemDialog());
    if (reason == null) return; // 取消
    await controller.rejectWishRedeem(wish.id as String, reason: reason);
  }

  Widget _buildExpectedDateRow(dynamic wish) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final expected = DateTime(
      wish.expectedDate.year,
      wish.expectedDate.month,
      wish.expectedDate.day,
    );
    final diff = expected.difference(today).inDays;
    final bothConfirmed = wish.parentConfirmed && wish.studentConfirmed;

    Color? color;
    String? label;
    // 已兑现 = 已实现，不再催逾期。与学生端 `_WishCard` 同一口径。
    if (!bothConfirmed && !wish.isRedeemed) {
      if (diff < 0) {
        color = AppColors.danger;
        label = '已逾期 ${-diff} 天';
      } else if (diff == 0) {
        color = AppColors.warning;
        label = '今天到期';
      } else if (diff <= 3) {
        color = AppColors.warning;
        label = '还有 $diff 天';
      } else {
        color = AppColors.textMuted;
        label = '还有 $diff 天';
      }
    } else {
      color = AppColors.textMuted;
    }

    return Row(
      children: [
        Icon(Icons.event_outlined, size: 16, color: color),
        const SizedBox(width: 4),
        Text(
          date_utils.DateUtilsX.formatChineseDate(wish.expectedDate),
          style: TextStyle(color: color, fontSize: 13),
        ),
        if (label != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 「拒绝这次兑换」弹窗。
///
/// 做成 `StatefulWidget` 的理由与 `showIntInputDialog` 完全相同：输入框控制器
/// 必须由**还活着的 State** 持有（原写法是 `await Get.dialog(...)` 之后
/// 立刻 `dispose()`，而那个 Future 在 `pop()` 的瞬间就完成了，弹窗还要再走
/// 一段退场动画 —— 于是控制器在弹窗尚未消失时就被销毁，debug 下抛
/// `A TextEditingController was used after being disposed`，**取消和确定都会**）。
///
/// 它比通用数字弹窗多一条：返回的是**理由文本**而不是「确认了没有」，
/// 这样调用方不必在弹窗销毁之后再去读一个已经没了的控制器。
/// 取消返回 `null`；确定返回理由（**可能为空串**，空串是合法的「不写说明」）。
class _RejectRedeemDialog extends StatefulWidget {
  const _RejectRedeemDialog();

  @override
  State<_RejectRedeemDialog> createState() => _RejectRedeemDialogState();
}

class _RejectRedeemDialogState extends State<_RejectRedeemDialog> {
  final TextEditingController _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('拒绝这次兑换？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '积分不会扣除，孩子可以再申请。',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            decoration: const InputDecoration(
              labelText: '说明（可选）',
              hintText: '例如：这个月已经去过一次了',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => popRoute<String>(context),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: () => popRoute<String>(context, _reason.text.trim()),
          child: const Text('确定拒绝'),
        ),
      ],
    );
  }
}
