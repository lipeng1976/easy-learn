import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../constants/app_colors.dart';
import '../../../controllers/student_controller.dart';
import '../../../models/focus_session_model.dart';
import '../../../models/study_plan_checkin_model.dart';
import '../../../models/study_plan_model.dart';
import '../../../models/workout_model.dart';
import '../../../widgets/daily_practice_block.dart';
import '../../../widgets/reading_task_card.dart';
import '../../../widgets/day_calendar.dart';
import '../../shared/plan_history.dart';
import '../../shared/plan_history_view.dart';
import '../../shared/study_plan_execution.dart';
import '../focus_timer_launcher.dart';
import '../widgets/focus_quick_picker.dart';
import '../widgets/focus_summary_card.dart';
import '../widgets/focus_timer_entry.dart';

class PlanTab extends StatefulWidget {
  const PlanTab({super.key});

  @override
  State<PlanTab> createState() => _PlanTabState();
}

class _PlanTabState extends State<PlanTab> {
  /// 日历上选中的那一天。
  ///
  /// ⚠️ 是**实例字段**，不是 `static`。
  /// 作业页原来的那份是 `static final Rx<DateTime>` —— 那是**跨实例共享的全局状态**，
  /// 一个页面改了选中日期，另一个页面（以及测试里的另一个用例）看得见。
  /// 抽公共控件时顺手改成实例持有（见 `doc/historical-data-plan.md` §1.1 与 §2.5 第 2 条）。
  DateTime _selectedDate = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<StudentController>();

    return Obx(() {
      // 待确认的计划排在最前，确保学生第一时间看到
      final plans = [...controller.studyPlans]
        ..sort((a, b) {
          const pendingOrder = {StudyPlanStatus.pendingStudentConfirm: 0};
          return (pendingOrder[a.status] ?? 1).compareTo(
            pendingOrder[b.status] ?? 1,
          );
        });
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '计划',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          _TodayCheckinBanner(controller: controller),
          const SizedBox(height: 12),
          FocusSummaryCard(controller: controller),
          const SizedBox(height: 12),
          _FreeFocusButton(controller: controller),
          const SizedBox(height: 18),
          // ===== 今日打卡 =====
          //
          // 这一区装的是**每天都要做一遍、每次几分钟**的东西。2026-11-12 起
          // 原本散在「复习」页的两块日常入口（概念训练 / 单词打卡）也并到这里：
          // 复习页只回答「做错的题怎么复习」，日常打卡回答「今天要做什么」。
          //
          // 再往下一层：三件小练（每日概念打卡 / 今日概念训练 / 英语单词打卡）
          // 收进**同一张大卡**里逐行列出 —— 它们本来就是同一类东西，
          // 各占一张卡时孩子要读三遍才知道今天有哪几件小事。
          // 家长刚出的题直接挂在「每日概念打卡」下面，不用先进打卡页才看得见。
          const DailyPracticeBlock(),
          const SizedBox(height: 12),
          // 英文阅读任务。与上面那张卡是两件事：小练按天出题、做完就没了；
          // 阅读是**一本书的长期任务**，没读就顺延到明天，一直挂到整本读完。
          // 合成一块会让「今天还剩几件事」这个数字一半按天算、一半按书算。
          const ReadingTaskCard(),
          const SizedBox(height: 18),
          // ===== 学习计划 =====
          _sectionLabel('学习计划', trailing: '长期规则'),
          if (controller.studyPlans.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Text('暂无学习计划'),
            )
          else ...[
            // 计划页的「某一天」= **那天该做哪些计划 + 打了没有**，
            // 不是「那天创建了哪些计划」—— 计划本身是跨时间的规则（方案 §2.3）。
            WeekStrip(
              selectedDate: _selectedDate,
              today: DateTime.now(),
              onDateSelected: (d) => setState(() => _selectedDate = d),
              marks: _marksForSelectedDate(controller),
            ),
            const SizedBox(height: 12),
            PlanHistorySection(
              day: _historyForSelectedDate(controller),
            ),
          ],
          const SizedBox(height: 12),
          ...plans.map(
              (plan) => Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: plan.status == StudyPlanStatus.pendingStudentConfirm
                        ? AppColors.warning
                        : AppColors.border,
                    width: plan.status == StudyPlanStatus.pendingStudentConfirm
                        ? 1.5
                        : 1,
                  ),
                ),
                child: Column(
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
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _statusColor(plan.status)
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            _statusLabel(plan.status),
                            style: TextStyle(
                              color: _statusColor(plan.status),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(plan.content),
                    Text('类型：${plan.type}'),
                    Text(
                      '时间：${plan.startAt.toLocal().toString().substring(0, 10)} - ${plan.endAt.toLocal().toString().substring(0, 10)}',
                    ),
                    Text('执行周期：${plan.cycleType.label}'),
                    if (plan.cycleType == WorkoutCycleType.weekly)
                      Text('执行日：${plan.customWeekdays.join(', ')}'),
                    const SizedBox(height: 12),
                    if (plan.status == StudyPlanStatus.pendingStudentConfirm)
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () => controller.updateStudyPlanStatus(
                                plan.id,
                                StudyPlanStatus.active,
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.success,
                                foregroundColor: Colors.white,
                              ),
                              child: const Text('接受'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () =>
                                  _showRejectDialog(context, controller, plan),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.danger,
                                side: const BorderSide(color: AppColors.danger),
                              ),
                              child: const Text('拒绝'),
                            ),
                          ),
                        ],
                      )
                    else if (plan.status == StudyPlanStatus.active) ...[
                      // 计划里最常见的是「每天阅读 20 分钟」这类事 ——
                      // 它和作业一样，需要一个「到底花了多久」的答案。
                      FocusTimerEntry(
                        targetId: plan.id,
                        hasRecordedTime:
                            controller.todaySecondsForPlan(plan.id) > 0,
                        onTap: () => FocusTimerLauncher.open(
                          context,
                          controller,
                          FocusTarget.plan(
                            plan,
                            recordedSeconds:
                                controller.todaySecondsForPlan(plan.id),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      PlanExecutionSection(
                        plan: plan,
                        checkinKeys: controller.checkinDateKeys(plan.id),
                        interactive: true,
                          checkedToday: controller.isCheckedInToday(plan.id),
                          onToggleToday: () =>
                              controller.toggleTodayCheckin(plan),
                        ),
                    ]
                    else if (plan.status == StudyPlanStatus.rejected) ...[
                      const Text(
                        '已拒绝，等待家长调整',
                        style: TextStyle(color: AppColors.danger),
                      ),
                      if (plan.rejectReason.isNotEmpty)
                        Text(
                          '拒绝理由：${plan.rejectReason}',
                          style: const TextStyle(color: AppColors.danger),
                        ),
                    ] else
                      const Text(
                        '已完成',
                        style: TextStyle(color: AppColors.primary),
                      ),
                  ],
                ),
              ),
            ),
        ],
      );
    });
  }

  /// 选中那天该执行的计划（按**当前**规则回放 —— 见 `plan_history.dart`）。
  ///
  /// 只看 `active` 的计划：待确认 / 已拒绝 / 已撤回 / 已完成的计划
  /// **在当时也没有在执行**，把它们算进历史会凭空多出「欠着的活」。
  List<StudyPlanModel> _activePlans(StudentController controller) => controller
      .studyPlans
      .where((p) => p.status == StudyPlanStatus.active)
      .toList();

  Map<String, Set<String>> _checkinsByPlan(StudentController controller) {
    final plans = _activePlans(controller);
    return {
      for (final p in plans) p.id: controller.checkinDateKeys(p.id),
    };
  }

  PlanHistoryDay _historyForSelectedDate(StudentController controller) =>
      replayPlanHistory(
        plans: _activePlans(controller),
        date: _selectedDate,
        checkinKeysByPlan: _checkinsByPlan(controller),
      );

  /// 周历上的打点：这一周里哪些天有该做的计划。
  ///
  /// 用 `DayMarks`（通用日历的入参）而不是计划自己的类型 ——
  /// 日历不认识「学习计划」，它只认「这天有什么」。同一天可能既有该做的
  /// 又有打卡，所以两类都填：`homework` 槽放「该做几项」、`checkin` 槽放
  /// 「打了几项」。这样**打点数量本身就编码了「欠着」**（该做的比打的多）。
  Map<String, DayMarks> _marksForSelectedDate(StudentController controller) {
    final plans = _activePlans(controller);
    if (plans.isEmpty) return const {};

    // 只算选中日所在的那一周（周历只显示 7 格）。
    final monday = _selectedDate.subtract(
      Duration(days: _selectedDate.weekday - 1),
    );
    final byPlan = _checkinsByPlan(controller);

    final result = <String, DayMarks>{};
    for (var i = 0; i < 7; i++) {
      final day = DateTime(monday.year, monday.month, monday.day + i);
      final replayed = replayPlanHistory(
        plans: plans,
        date: day,
        checkinKeysByPlan: byPlan,
      );
      if (replayed.scheduledCount == 0 && replayed.checkedCount == 0) continue;
      result[studyPlanDateKey(day)] = DayMarks(
        homework: replayed.scheduledCount,
        checkin: replayed.checkedCount,
      );
    }
    return result;
  }

  /// 拒绝计划弹窗：可选填写拒绝理由
  void _showRejectDialog(
    BuildContext context,
    StudentController controller,
    StudyPlanModel plan,
  ) {
    final reasonCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('拒绝学习计划'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('计划：${plan.title}'),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              maxLines: 3,
              maxLength: 100,
              decoration: const InputDecoration(
                hintText: '说说你的理由（选填），让家长更好地调整计划',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              final reason = reasonCtrl.text.trim();
              Navigator.pop(dialogContext);
              controller.rejectStudyPlan(plan.id, reason: reason);
            },
            child: const Text('确认拒绝'),
          ),
        ],
      ),
    );
  }

  /// 分区标题。与家长端「今天练什么」同一套写法（小标题 + 右侧一句解释），
  /// 同一类信息在两处长得不一样，用户就得重新学一遍怎么读页面。
  Widget _sectionLabel(String text, {String? trailing}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            Text(
              text,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
            ),
            const Spacer(),
            if (trailing != null)
              Text(
                trailing,
                style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
          ],
        ),
      );

  Color _statusColor(StudyPlanStatus status) {
    switch (status) {
      case StudyPlanStatus.pendingStudentConfirm:
        return AppColors.warning;
      case StudyPlanStatus.active:
        return AppColors.success;
      case StudyPlanStatus.rejected:
        return AppColors.danger;
      case StudyPlanStatus.withdrawn:
        return AppColors.textMuted;
      case StudyPlanStatus.completed:
        return AppColors.primary;
    }
  }

  String _statusLabel(StudyPlanStatus status) {
    switch (status) {
      case StudyPlanStatus.pendingStudentConfirm:
        return '待确认';
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
}

/// 今日学习计划打卡提示卡
class _TodayCheckinBanner extends StatelessWidget {
  const _TodayCheckinBanner({required this.controller});

  final StudentController controller;

  @override
  Widget build(BuildContext context) {
    final todays = controller.todayPlans;
    if (todays.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: const Row(
          children: [
            Icon(Icons.event_available, color: AppColors.textMuted),
            SizedBox(width: 8),
            Expanded(child: Text('今天没有需要执行的学习计划')),
          ],
        ),
      );
    }

    final pending = controller.todayPendingCheckinCount;
    final allDone = pending == 0;
    final color = allDone ? AppColors.success : AppColors.warning;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                allDone ? Icons.verified : Icons.notifications_active,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  allDone ? '今天的学习计划已全部打卡，继续保持！' : '今天有 $pending 个学习计划待打卡',
                  style: TextStyle(
                    color: color,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            todays.map((p) => p.title).join('、'),
            style: const TextStyle(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// 「临时打卡」：选个标签就开闹钟。
///
/// 放在计划页顶部而不是作业页：这里是「我今天要做点什么」的地方，
/// 而临时打卡本质上是一个**没写进计划的计划**。
class _FreeFocusButton extends StatelessWidget {
  const _FreeFocusButton({required this.controller});

  final StudentController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () async {
          final label = await showFocusQuickPicker(context);
          if (label == null || !context.mounted) return;
          await FocusTimerLauncher.open(
            context,
            controller,
            FocusTarget.free(label),
          );
        },
        icon: const Icon(Icons.alarm_add_rounded),
        label: const Text('临时打卡 · 记一段时间'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          side: const BorderSide(color: AppColors.primary),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }
}
