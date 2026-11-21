import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/parent_controller.dart';
import '../../models/plan_archive.dart';
import '../../models/study_plan_model.dart';
import '../../widgets/plan_card.dart';

/// 已结束的计划（家长端「计划」页底部小框点进来）。
///
/// ## 为什么单独一页
///
/// 主列表只留还会产生新任务的计划。已完成 / 已暂停 / 已拒绝 / 已撤回这些
/// 不再推进的，占着大卡片只是让页面越滚越长 —— 计划一多，家长要滑三屏
/// 才能看到「今天还有什么要做」。收进这里，主列表回到「一屏看完」。
///
/// ## 只读，除了「恢复计划」
///
/// 已完成 / 拒绝 / 撤回在状态机上都是终态，这里不提供回退（回退会让
/// 「做过的事」重新变成待办）。唯一的动作是**已暂停的运动计划 → 恢复**：
/// 主列表已经不显示它了，没有这个按钮家长就再也找不到恢复入口。
class PlansArchivePage extends StatelessWidget {
  const PlansArchivePage({super.key});

  /// 与错题详情页一致：用普通 `Navigator.push`，不依赖全局路由表。
  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const PlansArchivePage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ParentController>();

    return Scaffold(
      appBar: AppBar(title: const Text('已结束的计划')),
      body: Obx(() {
        // ⚠️ 必须在这里读（Obx 内），否则「换了孩子 / 恢复了计划」不会重建。
        final workoutPlans = controller.visibleWorkoutPlans;
        final studyPlans = controller.visibleStudyPlans;

        final completed = endedStudyPlans(studyPlans)
            .where((one) => one.status == StudyPlanStatus.completed)
            .toList();
        final rejected = endedStudyPlans(studyPlans)
            .where((one) => one.status == StudyPlanStatus.rejected)
            .toList();
        final withdrawn = endedStudyPlans(studyPlans)
            .where((one) => one.status == StudyPlanStatus.withdrawn)
            .toList();
        final paused = endedWorkoutPlans(workoutPlans);

        final counts = EndedPlanCounts.of(
          studyPlans: studyPlans,
          workoutPlans: workoutPlans,
        );
        if (counts.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                '还没有已结束的计划。',
                style: TextStyle(color: AppColors.textMuted),
              ),
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              '这一页只做归档：已完成的计划不会再出现新的待办，'
              '已暂停的运动计划可以随时恢复。',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textMuted,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 14),
            if (completed.isNotEmpty) ...[
              _sectionTitle('已完成', completed.length),
              ...completed.map(
                (plan) => PlanTile(
                  kind: PlanKind.study,
                  child: StudyPlanInfo(plan: plan, showStatus: false),
                ),
              ),
            ],
            if (paused.isNotEmpty) ...[
              _sectionTitle('已暂停', paused.length),
              ...paused.map(
                (plan) => PlanTile(
                  kind: PlanKind.workout,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      WorkoutPlanInfo(plan: plan, showStatus: false),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () => controller.toggleWorkoutPlan(plan.id),
                        child: const Text('恢复计划'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (rejected.isNotEmpty) ...[
              _sectionTitle('已拒绝', rejected.length),
              ...rejected.map(
                (plan) => PlanTile(
                  kind: PlanKind.study,
                  child: StudyPlanInfo(plan: plan, showStatus: false),
                ),
              ),
            ],
            if (withdrawn.isNotEmpty) ...[
              _sectionTitle('已撤回', withdrawn.length),
              ...withdrawn.map(
                (plan) => PlanTile(
                  kind: PlanKind.study,
                  child: StudyPlanInfo(plan: plan, showStatus: false),
                ),
              ),
            ],
          ],
        );
      }),
    );
  }

  Widget _sectionTitle(String title, int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(width: 6),
          Text(
            '$count 项',
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}
