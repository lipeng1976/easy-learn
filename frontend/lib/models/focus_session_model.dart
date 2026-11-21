/// 专注计时的「目标」与「流水」。
///
/// 计时最初只服务于作业（[FocusTargetKind.homework]），后来要回答两个新问题：
/// ① 学习计划（阅读、背诵这些）花了多久；② 「今天临时想读 20 分钟」这种
/// **不属于任何作业/计划**的时间怎么记。所以这里把「给什么计时」抽成一个
/// 目标，把「记下来的一段」抽成一条流水。
///
/// ## 为什么目标和流水要分开
///
/// 目标是**这一屏在计什么**（作业 / 计划 / 临时），它活在内存里；
/// 流水是**记下来的那一段**，它要落库、要跨天统计。
/// 之前作业的实现把两者合成一个字段（`homework.actualSeconds`），
/// 于是「今天一共学了多久」这个问题根本答不出来 —— 那份总数里
/// 掺着上周的时间。
library;

import 'homework_model.dart';
import 'study_plan_model.dart';

/// 计时的三种目标。
enum FocusTargetKind { homework, plan, free }

/// 词汇单点：`FocusTargetKind` 的线上写法。
///
/// 与 `wire_status.dart` 同理 —— 一个语义只许一个词、词只许一处定义。
/// 服务端 `focus_session.kind` 存的是这里的 `wire`。
extension FocusTargetKindWire on FocusTargetKind {
  String get wire => switch (this) {
        FocusTargetKind.homework => 'homework',
        FocusTargetKind.plan => 'plan',
        FocusTargetKind.free => 'free',
      };

  static FocusTargetKind fromWire(String? value) => switch (value) {
        'homework' => FocusTargetKind.homework,
        'plan' => FocusTargetKind.plan,
        'free' => FocusTargetKind.free,
        // 未知值一律按「临时」处理：它至少是「学生自己开的一段计时」，
        // 比抛异常把已有记录变成读不出来要好。
        _ => FocusTargetKind.free,
      };
}

/// 一次专注计时在计什么。
class FocusTarget {
  const FocusTarget({
    required this.kind,
    required this.id,
    required this.title,
    required this.subject,
    required this.recordedSeconds,
  });

  final FocusTargetKind kind;

  /// 作业 / 计划的 id。
  ///
  /// 临时计时**没有稳定 id**（同一天可以读两次书），所以它由进入计时页的
  /// 那一刻生成 —— 见 `FocusTimerService.start` 的会话 id，两者是同一个值：
  /// 一次会话一条流水，`id` 就是它的幂等键。
  final String id;

  /// 大标题（作业标题 / 计划标题 / 临时标签）。
  final String title;

  /// 科目。只有它非空时，下方才会去错题本取知识点提示。
  final String subject;

  /// 这次会话之前，这个目标上**已经记录过**的秒数。
  ///
  /// 它只是保存时的基数，不会让计时器从那个数字起步 —— 屏幕上那个大数字
  /// 始终是「本次」。
  final int recordedSeconds;

  /// 给一份作业计时。id 就是作业 id（作业有稳定 id，重复进入是**恢复**）。
  factory FocusTarget.homework(HomeworkItem item) => FocusTarget(
        kind: FocusTargetKind.homework,
        id: item.id,
        title: item.title,
        subject: item.subject,
        recordedSeconds: item.actualSeconds,
      );

  /// 给一个学习计划计时。
  ///
  /// [recordedSeconds] 是**今天**在这个计划上已经投入的秒数：
  /// 计划是按天重复的（不像作业那样一份一个总数），基数必须是当天的。
  factory FocusTarget.plan(
    StudyPlanModel plan, {
    int recordedSeconds = 0,
  }) =>
      FocusTarget(
        kind: FocusTargetKind.plan,
        id: plan.id,
        title: plan.title,
        // 计划的类型（「阅读」「背诵」）当科目用：它决定了下方那块
        // 知识点提示去哪个错题池里找。找不到时提示区会显示空态文案，
        // 不会假装这个科目有错题。
        subject: plan.type,
        recordedSeconds: recordedSeconds,
      );

  /// 临时打卡：今天想读会儿书 / 想动一动。
  ///
  /// ⚠️ **id 在这里现生成**，所以每一次都是一段新的会话 ——
  /// 这正是「今天读了两次书」能被记成两条的原因。
  factory FocusTarget.free(String label, {String? id}) => FocusTarget(
        kind: FocusTargetKind.free,
        id: id ?? 'free_${DateTime.now().microsecondsSinceEpoch}',
        title: FocusQuickLabels.normalize(label),
        subject: '',
        recordedSeconds: 0,
      );

  FocusTarget copyWith({int? recordedSeconds}) => FocusTarget(
        kind: kind,
        id: id,
        title: title,
        subject: subject,
        recordedSeconds: recordedSeconds ?? this.recordedSeconds,
      );
}

/// 记下来的一段专注。
class FocusSession {
  const FocusSession({
    required this.id,
    required this.studentId,
    required this.kind,
    required this.sourceId,
    required this.title,
    required this.date,
    required this.seconds,
    required this.startedAt,
    required this.updatedAt,
  });

  /// 幂等键 = 一次会话一个 id。
  ///
  /// 计时页在暂停 / 离开 / 结束时各写一次（检查点），**都是更新同一行**。
  /// 写成「每次新增一条」的话，暂停三次就变成三条、时长翻三倍，
  /// 而界面上只是「今天读了 1 小时」—— 没有任何报错。
  final String id;

  final String studentId;
  final FocusTargetKind kind;

  /// 作业 / 计划的 id；临时计时为空。
  final String sourceId;

  final String title;

  /// 本地日期 `yyyy-MM-dd`。
  ///
  /// ⚠️ **按天存，不按时刻存**：「今天读了多久」是唯一会被问到的口径，
  /// 而按时刻存的话跨天边界（23:50 开始、00:10 结束）会被算到两天里，
  /// 家长看到的是「昨天 10 分钟、今天 10 分钟」，而孩子明明读了 20 分钟。
  /// 一次会话跨天时，整段记在**结束那天**。
  final String date;

  /// 本次会话的秒数（不是累计总量）。
  final int seconds;

  final DateTime startedAt;
  final DateTime updatedAt;

  Map<String, dynamic> toMap() => {
        'id': id,
        'studentId': studentId,
        'kind': kind.wire,
        'sourceId': sourceId,
        'title': title,
        'date': date,
        'seconds': seconds,
        'startedAt': startedAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory FocusSession.fromMap(Map<String, dynamic> map) => FocusSession(
        id: (map['id'] as String?) ?? '',
        studentId: (map['studentId'] as String?) ?? '',
        kind: FocusTargetKindWire.fromWire(map['kind'] as String?),
        sourceId: (map['sourceId'] as String?) ?? '',
        title: (map['title'] as String?) ?? '',
        date: (map['date'] as String?) ?? '',
        seconds: (map['seconds'] as num?)?.toInt() ?? 0,
        startedAt: DateTime.tryParse((map['startedAt'] as String?) ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        updatedAt: DateTime.tryParse((map['updatedAt'] as String?) ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// 临时打卡的常用标签。
///
/// ⚠️ **只有这一处定义**。选项列表散在界面里的话，
/// 「阅读」在一屏叫「阅读」、在另一屏叫「课外阅读」，
/// 统计就按标题分成两项 —— 而这类分裂在数据上看只是「两个小类」。
abstract final class FocusQuickLabels {
  static const List<String> values = <String>[
    '阅读',
    '运动',
    '练字',
    '背诵',
    '错题复习',
    '其它',
  ];

  /// 不在列表里的自定义标签。空串按「其它」处理。
  static String normalize(String raw) {
    final text = raw.trim();
    return text.isEmpty ? '其它' : text;
  }
}

/// 本地日期键 `yyyy-MM-dd`（与 `studyPlanDateKey` 同形，各自持有是为了
/// 不让「打卡日期」和「专注日期」被将来的一次改动绑死）。
String focusDateKey(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}
