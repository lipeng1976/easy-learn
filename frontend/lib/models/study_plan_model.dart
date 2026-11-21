import 'workout_model.dart';

class StudyPlanModel {
  final String id;
  final String title;
  final String content;
  final DateTime startAt;
  final DateTime endAt;
  final String type;
  final StudyPlanStatus status;
  final String studentId;

  /// 执行周期：每天 / 每周 / 每月
  final WorkoutCycleType cycleType;

  /// 周期为“每周”时勾选的执行星期（一~日）
  final List<String> customWeekdays;

  /// 学生拒绝计划时填写的理由（仅状态为已拒绝时展示）
  final String rejectReason;

  StudyPlanModel({
    required this.id,
    required this.title,
    required this.content,
    required this.startAt,
    required this.endAt,
    required this.type,
    required this.status,
    this.studentId = '',
    this.cycleType = WorkoutCycleType.daily,
    this.customWeekdays = const <String>[],
    this.rejectReason = '',
  });

  /// 判断该计划在指定日期是否需要执行（与运动计划同一套周期规则）
  bool appliesToDate(DateTime date) {
    final day = DateTime(date.year, date.month, date.day);
    final startDay = DateTime(startAt.year, startAt.month, startAt.day);
    final endDay = DateTime(endAt.year, endAt.month, endAt.day);
    if (day.isBefore(startDay) || day.isAfter(endDay)) return false;

    switch (cycleType) {
      case WorkoutCycleType.daily:
        return true;
      case WorkoutCycleType.weekly:
        const labels = ['一', '二', '三', '四', '五', '六', '日'];
        return customWeekdays.contains(labels[date.weekday - 1]);
      case WorkoutCycleType.monthly:
        return date.day == startAt.day;
    }
  }

  StudyPlanModel copyWith({
    String? id,
    String? title,
    String? content,
    DateTime? startAt,
    DateTime? endAt,
    String? type,
    StudyPlanStatus? status,
    String? studentId,
    WorkoutCycleType? cycleType,
    List<String>? customWeekdays,
    String? rejectReason,
  }) {
    return StudyPlanModel(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      type: type ?? this.type,
      status: status ?? this.status,
      studentId: studentId ?? this.studentId,
      cycleType: cycleType ?? this.cycleType,
      customWeekdays: customWeekdays ?? this.customWeekdays,
      rejectReason: rejectReason ?? this.rejectReason,
    );
  }
}

enum StudyPlanStatus {
  pendingStudentConfirm,
  active,
  rejected,
  withdrawn,
  completed,
}
