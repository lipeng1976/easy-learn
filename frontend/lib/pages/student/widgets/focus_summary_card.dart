import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../constants/app_colors.dart';
import '../../../controllers/student_controller.dart';
import '../../../utils/duration_text.dart';

/// 「今天投入了多少」。
///
/// 只回答一件事：**今天**。不是本周、不是累计 —— 家长问的是
/// 「今天读了多久」，而一个「已累计 8 小时」的大数字对今天没有任何意义。
///
/// 什么都不显示的条件也很硬：今天一条流水都没有时**整块不出现**。
/// 摆一个「今天 0 分钟」在这里等于每天提醒孩子「你今天还没学」，
/// 而计时这个功能是为了让他看见自己做了什么，不是为了催。
class FocusSummaryCard extends StatelessWidget {
  const FocusSummaryCard({super.key, required this.controller});

  final StudentController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // 依赖 `focusSessions` 这个 RxList 本身：加一条/改一条都会刷新。
      final total = controller.todayFocusSeconds;
      if (total <= 0) return const SizedBox.shrink();
      final rows = controller.todayFocusByTitle;

      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.schedule, size: 18, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '今天已投入 ${formatStudyTime(total)}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primaryDark,
                    ),
                  ),
                ),
              ],
            ),
            if (rows.length > 1) ...[
              const SizedBox(height: 6),
              Text(
                rows
                    .map((r) => '${r.title} ${formatStudyTime(r.seconds)}')
                    .join(' · '),
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ],
        ),
      );
    });
  }
}
