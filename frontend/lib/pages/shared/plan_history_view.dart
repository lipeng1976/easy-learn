import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/study_plan_model.dart';
import 'plan_history.dart';

/// 计划页的「某一天做了什么」区块 —— 用的是**规则回放**的结果。
///
/// ⚠️ 这个控件的**核心职责不是排版，是诚实**。
/// 历史是拿当前规则倒推的，不是当时的快照；用户看到的每一处数字都可能
/// 与「他记忆里那天的样子」不一致。所以：
///
/// 1. 标题带日期，且**任何**非今天的历史都显式标注「按当前计划推算」；
/// 2. 不写「完成 / 未完成」这种像**事实**的词，写「已打卡 / 未打卡」（这是记录）；
/// 3. 「该做 X 项」如实说是推算出来的，而不是「当时有 X 项」。
class PlanHistorySection extends StatelessWidget {
  const PlanHistorySection({
    super.key,
    required this.day,
    this.today,
  });

  final PlanHistoryDay day;

  /// 注入「今天」是为了测试能定性 —— 传 null 就用真实当前时间。
  final DateTime? today;

  @override
  Widget build(BuildContext context) {
    final now = today ?? DateTime.now();
    final isToday =
        day.date.year == now.year &&
        day.date.month == now.month &&
        day.date.day == now.day;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history, size: 18, color: AppColors.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${_cnDate(day.date)} 的计划',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                isToday ? '今天' : '历史',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isToday ? AppColors.primary : AppColors.textMuted,
                ),
              ),
            ],
          ),
          // ⭐ 只在**非今天**时出现。
          // 今天不需要免责声明：今天就是当下的规则，没有「推算」这回事。
          // 每处都加会把真正需要看清的那一行淹掉。
          if (!isToday) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline,
                  size: 14,
                  color: AppColors.textMuted,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '历史按当前计划推算，与当时可能不同',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textMuted.withValues(alpha: 0.95),
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          if (day.scheduledCount == 0)
            const Text(
              '这天没有需要执行的计划',
              style: TextStyle(color: AppColors.textMuted),
            )
          else ...[
            Text(
              '该做 ${day.scheduledCount} 项，已打卡 ${day.checkedCount} 项',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            ...day.entries
                .where((e) => e.scheduled)
                .map((e) => _entryRow(e)),
          ],
        ],
      ),
    );
  }

  Widget _entryRow(PlanHistoryEntry e) {
    final color = e.checked ? AppColors.success : AppColors.warning;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(
            e.checked ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              e.plan.title,
              style: TextStyle(
                color: e.checked ? AppColors.text : AppColors.textMuted,
                decoration: e.checked ? null : TextDecoration.none,
              ),
            ),
          ),
          Text(
            // 说的是**记录**，不是**评价**：我们只知道「有没有那条打卡」，
            // 不知道学生那天是不是真的做了（他可能只是忘了点）。
            e.checked ? '已打卡' : '未打卡',
            style: TextStyle(fontSize: 12, color: color),
          ),
        ],
      ),
    );
  }
}

/// `9月22日` —— 计划页的历史标题用。
///
/// 刻意不带年份：跨年时才有意义，而绝大多数查看都在同一年内。
/// 真需要年份的场景（翻到去年）由标题上方的月份选择器承担。
String _cnDate(DateTime d) => '${d.month}月${d.day}日';

/// 计划页的日历打点：从 `PlanDayMark` 映射到通用日历的 `DayMarks`。
///
/// 单独放一个函数而不是塞进 `StudyPlanModel`，是因为 `DayMarks` 属于日历控件、
/// 计划只提供原始事实 —— 让模型依赖控件会把依赖方向反过来。
List<String> planCheckinDateKeys(
  List<StudyPlanModel> plans,
  Map<String, Set<String>> checkinKeysByPlan,
) {
  final all = <String>{};
  for (final p in plans) {
    all.addAll(checkinKeysByPlan[p.id] ?? const <String>{});
  }
  return all.toList()..sort();
}
