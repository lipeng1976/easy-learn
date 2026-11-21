enum WorkoutCycleType { daily, weekly, monthly }

extension WorkoutCycleTypeX on WorkoutCycleType {
  String get label {
    switch (this) {
      case WorkoutCycleType.daily:
        return '每天';
      case WorkoutCycleType.weekly:
        return '每周';
      case WorkoutCycleType.monthly:
        return '每月';
    }
  }

  static WorkoutCycleType fromName(String name) {
    return WorkoutCycleType.values.firstWhere(
      (e) => e.name == name,
      orElse: () => WorkoutCycleType.weekly,
    );
  }
}

class WorkoutPlan {
  final String id;
  final String title;
  final String project;
  final List<String> weekdays;
  final int targetMinutes;
  final bool isActive;
  final DateTime? startDate;
  final DateTime? endDate;
  final String startTime;
  final String endTime;
  final WorkoutCycleType cycleType;
  final List<String> customWeekdays;
  final String studentId;

  WorkoutPlan({
    required this.id,
    required this.title,
    required this.project,
    required this.weekdays,
    required this.targetMinutes,
    required this.isActive,
    this.startDate,
    this.endDate,
    this.startTime = '08:00',
    this.endTime = '09:00',
    this.cycleType = WorkoutCycleType.weekly,
    this.customWeekdays = const <String>[],
    this.studentId = '',
  });

  bool appliesToDate(DateTime date) {
    if (!isActive) return false;

    final day = DateTime(date.year, date.month, date.day);
    final start = startDate;
    final end = endDate;
    if (start != null) {
      final startDay = DateTime(start.year, start.month, start.day);
      if (day.isBefore(startDay)) return false;
    }
    if (end != null) {
      final endDay = DateTime(end.year, end.month, end.day);
      if (day.isAfter(endDay)) return false;
    }

    switch (cycleType) {
      case WorkoutCycleType.daily:
        return true;
      case WorkoutCycleType.weekly:
        final labels = ['一', '二', '三', '四', '五', '六', '日'];
        final dayLabel = labels[date.weekday - 1];
        if (customWeekdays.isNotEmpty) {
          return customWeekdays.contains(dayLabel);
        }
        return weekdays.contains(dayLabel);
      case WorkoutCycleType.monthly:
        if (start != null) {
          return date.day == start.day;
        }
        return false;
    }
  }

  WorkoutPlan copyWith({
    String? id,
    String? title,
    String? project,
    List<String>? weekdays,
    int? targetMinutes,
    bool? isActive,
    DateTime? startDate,
    DateTime? endDate,
    String? startTime,
    String? endTime,
    WorkoutCycleType? cycleType,
    List<String>? customWeekdays,
    String? studentId,
  }) {
    return WorkoutPlan(
      id: id ?? this.id,
      title: title ?? this.title,
      project: project ?? this.project,
      weekdays: weekdays ?? this.weekdays,
      targetMinutes: targetMinutes ?? this.targetMinutes,
      isActive: isActive ?? this.isActive,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      cycleType: cycleType ?? this.cycleType,
      customWeekdays: customWeekdays ?? this.customWeekdays,
      studentId: studentId ?? this.studentId,
    );
  }
}

class WorkoutRecord {
  final String id;
  final String project;
  final DateTime start;
  final DateTime end;
  final int minutes;
  final String feedback;
  final String planId;
  final String studentId;

  WorkoutRecord({
    required this.id,
    required this.project,
    required this.start,
    required this.end,
    required this.minutes,
    required this.feedback,
    this.planId = '',
    this.studentId = '',
  });

  DateTime get date => DateTime(start.year, start.month, start.day);

  bool isSamePlanAndDay(String? planId, DateTime day) {
    final samePlan = planId == null || planId.isEmpty || this.planId == planId;
    final sameDay = date.isAtSameMomentAs(
      DateTime(day.year, day.month, day.day),
    );
    return samePlan && sameDay;
  }
}
