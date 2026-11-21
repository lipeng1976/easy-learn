import 'study_plan_model.dart';
import 'workout_model.dart';

/// 计划的「已结束」口径 —— 只有这一处定义。
///
/// 家长端「计划」页原来把所有状态平铺成大卡片，计划一多就滚不到底；
/// 已完成 / 已暂停的还留在主列表里，越堆越长。现在主列表只放**还会产生
/// 新任务**的计划，其余收进「已结束」入口。
///
/// 判据必须集中在这里：页面与入口各写一遍 `status == completed`，漏一个
/// 状态就会「卡还在主列表、但计数里没有它」，两边都对不上还不报错。
bool isEndedStudyPlan(StudyPlanStatus status) =>
    status == StudyPlanStatus.completed ||
    status == StudyPlanStatus.rejected ||
    status == StudyPlanStatus.withdrawn;

/// 运动计划只有启用 / 暂停两种，暂停即「已结束」。
bool isEndedWorkoutPlan(WorkoutPlan plan) => !plan.isActive;

/// 还会推进的计划（待学生确认 + 已生效）。
List<StudyPlanModel> activeStudyPlans(Iterable<StudyPlanModel> plans) =>
    plans.where((one) => !isEndedStudyPlan(one.status)).toList();

List<StudyPlanModel> endedStudyPlans(Iterable<StudyPlanModel> plans) =>
    plans.where((one) => isEndedStudyPlan(one.status)).toList();

List<WorkoutPlan> activeWorkoutPlans(Iterable<WorkoutPlan> plans) =>
    plans.where((one) => !isEndedWorkoutPlan(one)).toList();

List<WorkoutPlan> endedWorkoutPlans(Iterable<WorkoutPlan> plans) =>
    plans.where(isEndedWorkoutPlan).toList();

/// 「已结束」的分状态计数，给入口小框与详情页分段标题用。
///
/// 顺序固定为 已完成 → 已暂停 → 已拒绝 → 已撤回：入口那行文字与详情页
/// 段落顺序由同一份数据产生，免得两处写得不一样、看着像两套东西。
class EndedPlanCounts {
  const EndedPlanCounts({
    this.completed = 0,
    this.paused = 0,
    this.rejected = 0,
    this.withdrawn = 0,
  });

  factory EndedPlanCounts.of({
    required Iterable<StudyPlanModel> studyPlans,
    required Iterable<WorkoutPlan> workoutPlans,
  }) {
    var completed = 0;
    var rejected = 0;
    var withdrawn = 0;
    for (final one in studyPlans) {
      switch (one.status) {
        case StudyPlanStatus.completed:
          completed += 1;
        case StudyPlanStatus.rejected:
          rejected += 1;
        case StudyPlanStatus.withdrawn:
          withdrawn += 1;
        case StudyPlanStatus.pendingStudentConfirm:
        case StudyPlanStatus.active:
          break;
      }
    }
    final paused = workoutPlans.where(isEndedWorkoutPlan).length;
    return EndedPlanCounts(
      completed: completed,
      paused: paused,
      rejected: rejected,
      withdrawn: withdrawn,
    );
  }

  final int completed;
  final int paused;
  final int rejected;
  final int withdrawn;

  int get total => completed + paused + rejected + withdrawn;

  bool get isEmpty => total == 0;

  /// 形如「已完成 2 · 已暂停 1」；为 0 的项不出现（避免「已拒绝 0」这种噪音）。
  String get breakdown {
    final parts = <String>[
      if (completed > 0) '已完成 $completed',
      if (paused > 0) '已暂停 $paused',
      if (rejected > 0) '已拒绝 $rejected',
      if (withdrawn > 0) '已撤回 $withdrawn',
    ];
    return parts.join(' · ');
  }
}
