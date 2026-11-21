import 'package:flutter/material.dart';

import '../../../constants/app_colors.dart';
import '../../../services/focus_timer_service.dart';
import '../../../utils/duration_text.dart';

/// 卡片上的「专注计时」入口（作业 / 学习计划共用）。
///
/// 它同时兼作**状态显示**：计时中显示实时秒数，暂停时显示「已暂停」。
/// 没有这一行的话，学生点完返回就再也看不到「计时还在跑」，
/// 而那段计时的唯一去处是「结束并保存」—— 会一直挂着。
///
/// 单独成一个文件而不是留在 `homework_tab.dart` 里，是为了能直接给它写widget 测试：
/// 这一行是功能的**唯一入口**，它不出现 = 整个功能不存在，而那种错
/// 在作业页的整体测试里很容易被别的文案淹掉。
class FocusTimerEntry extends StatelessWidget {
  const FocusTimerEntry({
    super.key,
    required this.targetId,
    required this.onTap,
    this.hasRecordedTime = false,
    this.timer,
  });

  /// 作业 / 计划的 id。计时器只按 id 认「是不是当前这一段」。
  final String targetId;
  final VoidCallback onTap;

  /// 这个目标上有没有已经记过的时间（决定右侧写「开始」还是「再计一次」）。
  final bool hasRecordedTime;

  /// 测试注入；生产用应用级单例（跨页面存活）。
  final FocusTimerService? timer;

  @override
  Widget build(BuildContext context) {
    final service = timer ?? FocusTimerService.instance;
    return ValueListenableBuilder<FocusTimerStatus>(
      valueListenable: service.status,
      builder: (context, status, _) {
        final active =
            service.isActiveFor(targetId) && status != FocusTimerStatus.idle;
        final running = active && status == FocusTimerStatus.running;
        return ValueListenableBuilder<int>(
          valueListenable: service.elapsedSeconds,
          builder: (context, seconds, _) {
            return Material(
              color: active
                  ? AppColors.primary.withValues(alpha: 0.08)
                  : const Color(0xFFF8FAFF),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        running ? Icons.timer : Icons.timer_outlined,
                        size: 18,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          running
                              ? '专注计时中'
                              : active
                              ? '计时已暂停'
                              : '专注计时',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: running
                                ? AppColors.primaryDark
                                : AppColors.text,
                          ),
                        ),
                      ),
                      if (active)
                        Text(
                          formatClock(seconds),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primaryDark,
                          ),
                        )
                      else
                        Text(
                          hasRecordedTime ? '再计一次' : '开始',
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: AppColors.primary,
                          ),
                        ),
                      const Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: AppColors.textMuted,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
