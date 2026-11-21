import '../../models/study_plan_checkin_model.dart';
import '../../models/study_plan_model.dart';

/// 计划页的「历史」：**用当前规则回放**某一天该做哪些计划、做了没有。
///
/// ⚠️ 这里刻意**没有**「当时的规则」这个概念 —— 我们只存计划本身
/// （`study_plan` 是一段跨时间的规则），**不存每日快照**。
/// 所以「三个月前那天该做哪些计划」是拿**今天的规则**倒推出来的。
///
/// 后果是真实存在的：如果中途把「每周一三五」改成了「每天」，
/// 那三个月前的周二也会被算成「该做」—— 这在当时并不是事实。
///
/// 这是一个**已知且刻意接受**的取舍（见 `doc/historical-data-plan.md` §2.3 与 Q1），
/// 但**必须让用户看得见**：界面上一律标注「按当前计划推算」，
/// 不能假装历史是当时的截图。这个类只负责算，不负责措辞；
/// 措辞在 `plan_history_view.dart` 的 `PlanHistorySection`。
class PlanHistoryDay {
  const PlanHistoryDay({
    required this.date,
    required this.entries,
  });

  /// 被回放的那一天（已归零到 00:00 本地时间）
  final DateTime date;

  /// 那天应该执行的计划，每条带上「打卡打没打」
  final List<PlanHistoryEntry> entries;

  /// 那天有该做的计划（不管打没打）
  bool get hasScheduled => entries.any((e) => e.scheduled);

  /// 那天实际打了卡的计划数
  int get checkedCount => entries.where((e) => e.checked).length;

  /// 那天该做的计划数
  int get scheduledCount => entries.where((e) => e.scheduled).length;

  /// 该做的都打了（且那天确实有该做的）
  bool get allChecked => scheduledCount > 0 && checkedCount == scheduledCount;
}

/// 单条计划在某一天的「该做 + 做了没有」
class PlanHistoryEntry {
  const PlanHistoryEntry({
    required this.plan,
    required this.scheduled,
    required this.checked,
  });

  final StudyPlanModel plan;

  /// 按**当前**规则，这一天是否轮到它
  final bool scheduled;

  /// 这一天有没有留过打卡记录（`study_plan_checkin.date` 就是「那一天」本身）
  final bool checked;
}

/// 把 [plans] 按**当前规则**回放到 [date] 这一天。
///
/// [checkinKeysByPlan] 是「计划 id → 该计划的打卡日期串集合」
/// （形如 `{'sp_1': {'2026-09-20', '2026-09-22'}}`），来自仓储的按计划分组。
///
/// ⚠️ 打卡只认**日期串相等**，**绝不做时区换算**：
/// `study_plan_checkin.date` 是一列 `date`，语义就是「学生所在地的那一天」。
/// 把 `'2026-09-20'` 解析成 `DateTime` 再 `toLocal()` 在 UTC-5 会变成 9-19 ——
/// 同一件事在别处已经踩过一次（见 `LocalDayMarks` 与方案 §2.3）。
PlanHistoryDay replayPlanHistory({
  required List<StudyPlanModel> plans,
  required DateTime date,
  required Map<String, Set<String>> checkinKeysByPlan,
}) {
  final day = DateTime(date.year, date.month, date.day);
  final key = studyPlanDateKey(day);

  final entries = <PlanHistoryEntry>[
    for (final plan in plans)
      PlanHistoryEntry(
        plan: plan,
        scheduled: plan.appliesToDate(day),
        checked: checkinKeysByPlan[plan.id]?.contains(key) ?? false,
      ),
  ];

  return PlanHistoryDay(date: day, entries: entries);
}

/// 一天在日历上的状态 —— 给 `WeekStrip` / 打点用。
///
/// 与 `PlanHistoryDay` 分开是有意的：日历只要一个「这天有戏吗」的概览，
/// 不需要把每条计划都算出来。
class PlanDayMark {
  const PlanDayMark({
    required this.scheduled,
    required this.checked,
  });

  /// 这天有该执行的计划
  final int scheduled;

  /// 这天打了卡的计划数
  final int checked;

  bool get hasAny => scheduled > 0 || checked > 0;

  /// 该做的都打了（那天确实有该做的）
  bool get allDone => scheduled > 0 && checked == scheduled;

  /// 该做但没全做 —— 日历上要能一眼看出「这天欠着」
  bool get missed => scheduled > checked;
}

/// 把一整个月的计划规则回放成「日期串 → 概览」，供日历打点。
///
/// 只回放 **[month] 那一个月**（不跨月），因为调用方总是按月取。
/// 没戏的日子不会出现在结果里 —— 日历的缺席就是「无打点」。
Map<String, PlanDayMark> replayPlanMonth({
  required List<StudyPlanModel> plans,
  required DateTime month,
  required Map<String, Set<String>> checkinKeysByPlan,
  DateTime? today,
}) {
  final first = DateTime(month.year, month.month, 1);
  // `DateTime(y, m + 1, 0)` = 这个月最后一天（下月 0 号）。
  final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
  final todayDay = today == null
      ? null
      : DateTime(today.year, today.month, today.day);

  final result = <String, PlanDayMark>{};
  for (var i = 0; i < daysInMonth; i++) {
    final day = first.add(Duration(days: i));
    // 未来的日子不算「历史」：它该不该做还取决于用户之后会不会改计划，
    // 现在就算出一个「欠着」是**编出来的事实**。
    if (todayDay != null && day.isAfter(todayDay)) break;

    final replayed = replayPlanHistory(
      plans: plans,
      date: day,
      checkinKeysByPlan: checkinKeysByPlan,
    );
    if (!replayed.hasScheduled && replayed.checkedCount == 0) continue;

    result[studyPlanDateKey(day)] = PlanDayMark(
      scheduled: replayed.scheduledCount,
      checked: replayed.checkedCount,
    );
  }
  return result;
}
