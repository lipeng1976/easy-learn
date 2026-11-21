import 'package:easy_learn_app/models/plan_archive.dart';
import 'package:easy_learn_app/models/study_plan_model.dart';
import 'package:easy_learn_app/models/workout_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「已结束」口径的判据。
///
/// 这一组守的是**口径本身**，不是页面：主列表、底部小框、详情页分段
/// 都从这里取数。口径错一个状态，症状是「卡还在主列表、计数里却没有它」——
/// 两边都不报错，只是数字对不上。
void main() {
  StudyPlanModel study(String id, StudyPlanStatus status) => StudyPlanModel(
    id: id,
    title: '计划 $id',
    content: '内容',
    startAt: DateTime(2026, 11, 1),
    endAt: DateTime(2026, 12, 1),
    type: '综合',
    status: status,
    studentId: 'stu_001',
  );

  WorkoutPlan workout(String id, {required bool active}) => WorkoutPlan(
    id: id,
    title: '运动 $id',
    project: '跳绳',
    weekdays: const ['一'],
    targetMinutes: 15,
    isActive: active,
    studentId: 'stu_001',
  );

  test('学习计划只有 完成/拒绝/撤回 算已结束', () {
    expect(isEndedStudyPlan(StudyPlanStatus.completed), isTrue);
    expect(isEndedStudyPlan(StudyPlanStatus.rejected), isTrue);
    expect(isEndedStudyPlan(StudyPlanStatus.withdrawn), isTrue);
    expect(isEndedStudyPlan(StudyPlanStatus.active), isFalse);
    expect(isEndedStudyPlan(StudyPlanStatus.pendingStudentConfirm), isFalse);
  });

  test('运动计划暂停即已结束', () {
    expect(isEndedWorkoutPlan(workout('w1', active: false)), isTrue);
    expect(isEndedWorkoutPlan(workout('w2', active: true)), isFalse);
  });

  test('active/ended 拆分互补，不重不漏', () {
    final plans = [
      study('a', StudyPlanStatus.active),
      study('b', StudyPlanStatus.completed),
      study('c', StudyPlanStatus.pendingStudentConfirm),
      study('d', StudyPlanStatus.rejected),
    ];
    expect(activeStudyPlans(plans).map((one) => one.id), ['a', 'c']);
    expect(endedStudyPlans(plans).map((one) => one.id), ['b', 'd']);

    final workouts = [
      workout('w1', active: true),
      workout('w2', active: false),
    ];
    expect(activeWorkoutPlans(workouts).map((one) => one.id), ['w1']);
    expect(endedWorkoutPlans(workouts).map((one) => one.id), ['w2']);
  });

  test('计数按状态分开，总数 = 各项之和', () {
    final counts = EndedPlanCounts.of(
      studyPlans: [
        study('a', StudyPlanStatus.completed),
        study('b', StudyPlanStatus.completed),
        study('c', StudyPlanStatus.rejected),
        study('d', StudyPlanStatus.withdrawn),
        study('e', StudyPlanStatus.active),
      ],
      workoutPlans: [
        workout('w1', active: false),
        workout('w2', active: true),
      ],
    );
    expect(counts.completed, 2);
    expect(counts.paused, 1);
    expect(counts.rejected, 1);
    expect(counts.withdrawn, 1);
    expect(counts.total, 5);
    expect(counts.isEmpty, isFalse);
  });

  test('入口文案只写非零项，顺序固定', () {
    const counts = EndedPlanCounts(completed: 2, paused: 1);
    expect(counts.breakdown, '已完成 2 · 已暂停 1');

    const mixed = EndedPlanCounts(
      completed: 1,
      paused: 1,
      rejected: 1,
      withdrawn: 1,
    );
    expect(mixed.breakdown, '已完成 1 · 已暂停 1 · 已拒绝 1 · 已撤回 1');
  });

  test('一项已结束都没有时是空的（入口要整个不出现）', () {
    final counts = EndedPlanCounts.of(
      studyPlans: [study('a', StudyPlanStatus.active)],
      workoutPlans: [workout('w1', active: true)],
    );
    expect(counts.isEmpty, isTrue);
    expect(counts.total, 0);
    expect(counts.breakdown, '');
  });
}
