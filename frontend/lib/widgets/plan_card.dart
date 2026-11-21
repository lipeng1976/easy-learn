import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../models/study_plan_model.dart';
import '../models/workout_model.dart';

/// 计划卡片的公共外壳与正文 —— 主列表与「已结束」详情页共用。
///
/// 抽出来的理由不是「复用好看」，是**两处必须长得一样**：
/// 详情页里的卡片如果换一套排版，家长会以为那是另一个东西，
/// 也就不会相信主列表里的「N 项」数得对。
enum PlanKind { study, workout }

/// 学习计划状态的中文，主列表 / 详情页 / 入口小框共用一份。
String planStatusLabel(StudyPlanStatus status) {
  switch (status) {
    case StudyPlanStatus.pendingStudentConfirm:
      return '待学生确认';
    case StudyPlanStatus.active:
      return '已生效';
    case StudyPlanStatus.rejected:
      return '已拒绝';
    case StudyPlanStatus.withdrawn:
      return '已撤回';
    case StudyPlanStatus.completed:
      return '已完成';
  }
}

String formatPlanDate(DateTime date) {
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

/// 两类计划只在「底色 / 边框 / 徽标」上分家。
///
/// ⚠️ 合并的是**列表长相**，不是数据：学习计划是 `StudyPlanModel`
/// （带「待学生确认 → 生效 → 完成」的状态机），运动计划是 `WorkoutPlan`
/// （只有启用 / 暂停）。两张表、两套接口，硬揉成一张表会让状态机打架。
class PlanTile extends StatelessWidget {
  const PlanTile({super.key, required this.kind, required this.child});

  final PlanKind kind;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isStudy = kind == PlanKind.study;
    final accent = isStudy ? AppColors.primary : AppColors.warning;
    final label = isStudy ? '学习' : '运动';
    final icon = isStudy
        ? Icons.menu_book_outlined
        : Icons.directions_run_outlined;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        // 底色 = 类型色 8% 叠在白卡上。不用纯色块：正文是深灰，
        // 底色一重对比度就掉；8% 足够「一眼分两堆」，又不影响读字。
        color: Color.alphaBlend(accent.withValues(alpha: 0.08), AppColors.card),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: accent),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: accent,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

/// 学习计划的正文（标题 / 内容 / 时间 / 周期 / 状态）。
///
/// 只读：动作按钮由调用方拼在下面 —— 主列表要「撤回 / 标记完成」，
/// 详情页什么都不用，混在一起就会在详情页里出现「标记完成」而状态早已完成。
class StudyPlanInfo extends StatelessWidget {
  const StudyPlanInfo({super.key, required this.plan, this.showStatus = true});

  final StudyPlanModel plan;
  final bool showStatus;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          plan.title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(plan.content),
        const SizedBox(height: 8),
        Text(
          '时间：${formatPlanDate(plan.startAt.toLocal())} - ${formatPlanDate(plan.endAt.toLocal())}',
        ),
        Text('执行周期：${plan.cycleType.label}'),
        if (plan.cycleType == WorkoutCycleType.weekly)
          Text('执行日：${plan.customWeekdays.join(', ')}'),
        if (showStatus) Text('状态：${planStatusLabel(plan.status)}'),
        if (plan.status == StudyPlanStatus.rejected &&
            plan.rejectReason.isNotEmpty)
          Text(
            '拒绝理由：${plan.rejectReason}',
            style: const TextStyle(color: AppColors.danger),
          ),
      ],
    );
  }
}

/// 运动计划的正文。右上角那行字（进行中 / 已暂停）就是它的状态，
/// 不在下面再重复一遍「状态：」。
///
/// `showStatus=false` 给「已结束」详情页用：那页的段落标题已经写了
/// 「已暂停」，卡片里再写一次就是同一行字出现两遍。
class WorkoutPlanInfo extends StatelessWidget {
  const WorkoutPlanInfo({
    super.key,
    required this.plan,
    this.showStatus = true,
  });

  final WorkoutPlan plan;
  final bool showStatus;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                plan.title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (showStatus)
              Text(
                plan.isActive ? '进行中' : '已暂停',
                style: TextStyle(
                  color: plan.isActive
                      ? AppColors.primary
                      : AppColors.textMuted,
                  fontSize: 12,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text('项目：${plan.project}'),
        Text('目标时长：${plan.targetMinutes} 分钟'),
        Text('周期：${plan.cycleType.label}'),
        if (plan.startDate != null || plan.endDate != null)
          Text(
            '日期：${plan.startDate == null ? '不限' : formatPlanDate(plan.startDate!)} ~ ${plan.endDate == null ? '不限' : formatPlanDate(plan.endDate!)}',
          ),
        Text('时间段：${plan.startTime} ~ ${plan.endTime}'),
        if (plan.cycleType == WorkoutCycleType.weekly)
          Text(
            '执行日：${(plan.customWeekdays.isNotEmpty ? plan.customWeekdays : plan.weekdays).join(', ')}',
          ),
      ],
    );
  }
}
