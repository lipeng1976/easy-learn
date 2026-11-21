import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/study_plan_checkin_model.dart';
import '../../models/study_plan_model.dart';

/// 计划从开始日到今天（不超过结束日）应执行的次数
int planScheduledCountUntilToday(StudyPlanModel plan, {DateTime? today}) {
  final now = today ?? DateTime.now();
  final endDay = DateTime(plan.endAt.year, plan.endAt.month, plan.endAt.day);
  var cursor = DateTime(
    plan.startAt.year,
    plan.startAt.month,
    plan.startAt.day,
  );
  final stop = now.isBefore(endDay)
      ? DateTime(now.year, now.month, now.day)
      : endDay;
  var count = 0;
  while (!cursor.isAfter(stop)) {
    if (plan.appliesToDate(cursor)) count++;
    cursor = cursor.add(const Duration(days: 1));
  }
  return count;
}

/// 已打卡次数（只统计开始日至今天、且不超过结束日的记录）
int planCheckedCount(
  StudyPlanModel plan,
  Set<String> checkinKeys, {
  DateTime? today,
}) {
  final now = today ?? DateTime.now();
  return checkinKeys.where((key) {
    final d = DateTime.tryParse(key);
    if (d == null) return false;
    return plan.appliesToDate(d) &&
        !d.isAfter(DateTime(now.year, now.month, now.day));
  }).length;
}

/// 计划卡片上的“今日执行 + 进度 + 近7天”区块（学生可打卡，家长只读）
class PlanExecutionSection extends StatelessWidget {
  const PlanExecutionSection({
    super.key,
    required this.plan,
    required this.checkinKeys,
    required this.interactive,
    this.checkedToday = false,
    this.onToggleToday,
  });

  final StudyPlanModel plan;
  final Set<String> checkinKeys;

  /// true=学生端可点击打卡；false=家长端只读
  final bool interactive;
  final bool checkedToday;
  final VoidCallback? onToggleToday;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final scheduledToday = plan.appliesToDate(today);
    final scheduled = planScheduledCountUntilToday(plan, today: today);
    final done = planCheckedCount(plan, checkinKeys, today: today);
    final progress = scheduled == 0 ? 0.0 : done / scheduled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (scheduledToday)
          interactive
              ? SizedBox(
                  width: double.infinity,
                  child: checkedToday
                      ? OutlinedButton.icon(
                          onPressed: onToggleToday,
                          icon: const Icon(Icons.check_circle, size: 18),
                          label: const Text('今日已打卡（点此可撤销）'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.success,
                            side: const BorderSide(color: AppColors.success),
                          ),
                        )
                      : ElevatedButton.icon(
                          onPressed: onToggleToday,
                          icon: const Icon(Icons.task_alt, size: 18),
                          label: const Text('今日打卡'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                          ),
                        ),
                )
              : Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color:
                        (checkedToday ? AppColors.success : AppColors.warning)
                            .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        checkedToday ? Icons.check_circle : Icons.schedule,
                        size: 16,
                        color: checkedToday
                            ? AppColors.success
                            : AppColors.warning,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        checkedToday ? '今日已打卡' : '今日待打卡',
                        style: TextStyle(
                          color: checkedToday
                              ? AppColors.success
                              : AppColors.warning,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                )
        else
          const Text('今日非执行日', style: TextStyle(color: AppColors.textMuted)),
        const SizedBox(height: 10),
        Row(
          children: [
            const Text('执行进度', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  minHeight: 8,
                  backgroundColor: AppColors.border,
                  valueColor: const AlwaysStoppedAnimation(AppColors.success),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text('$done/$scheduled 次'),
          ],
        ),
        const SizedBox(height: 8),
        _RecentWeekStrip(plan: plan, checkinKeys: checkinKeys),
      ],
    );
  }
}

/// 近 7 天打卡情况小圆点
class _RecentWeekStrip extends StatelessWidget {
  const _RecentWeekStrip({required this.plan, required this.checkinKeys});

  final StudyPlanModel plan;
  final Set<String> checkinKeys;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    const labels = ['一', '二', '三', '四', '五', '六', '日'];
    final days = List.generate(7, (i) => today.subtract(Duration(days: 6 - i)));

    return Row(
      children: days.map((date) {
        final scheduled = plan.appliesToDate(date);
        final done = checkinKeys.contains(studyPlanDateKey(date));
        final isToday =
            date.year == today.year &&
            date.month == today.month &&
            date.day == today.day;
        final isPast = date.isBefore(
          DateTime(today.year, today.month, today.day),
        );

        Color color;
        if (done) {
          color = AppColors.success;
        } else if (scheduled && isPast) {
          color = AppColors.danger;
        } else if (scheduled && isToday) {
          color = AppColors.warning;
        } else {
          color = AppColors.border;
        }

        return Expanded(
          child: Column(
            children: [
              Text(
                labels[date.weekday - 1],
                style: TextStyle(
                  fontSize: 11,
                  color: isToday ? AppColors.primary : AppColors.textMuted,
                  fontWeight: isToday ? FontWeight.w700 : FontWeight.normal,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: done ? color : Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 1.5),
                ),
                child: done
                    ? const Icon(Icons.check, size: 13, color: Colors.white)
                    : null,
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
