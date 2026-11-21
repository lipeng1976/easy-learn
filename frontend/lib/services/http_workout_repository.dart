import '../models/workout_model.dart';
import '../repositories/workout_repository.dart';
import 'data_api_client.dart';
import 'data_row_values.dart';

/// 运动计划与运动记录的**服务端实现**（`WorkoutRepository` 的第二个实现）。
///
/// 本地那份在 `local_database_service.dart`。两者实现同一契约，控制器一行不用改。
///
/// ## 两处「照搬本地写法就会错」的地方
///
/// **① 读/写都不带 `studentId`，可见性由 token 推导。**
/// 契约注释点名：「三个方法两边都没有过滤，上云时是越权点」—— 本地是
/// 「取全表 → 调用方按 `studentId` 内存过滤」，单机单库下没问题，上云后等于
/// 每个客户端拉走全库运动数据。所以这里打无参列表端点，过滤下推到服务端
/// （`ctx.students`），不再照抄「取全表」。
///
/// **② `id` 归谁生成 —— 契约与 R2 的直接冲突，且服务端已经裁定。**
/// 契约注释写：「幂等键就是 `record.id` / `plan.id`，**别把 id 改成服务端生成的新值**，
/// 那会把唯一的幂等键弄丢」。而全局规则 R2 是「id 由服务端生成」。
/// 两者正面冲突。读取 `routes/workout.js` 可知：运动这两张表被显式列为 **R2 例外**——
/// 服务端**接受客户端自带 id**，并把它当「幂等键」用（`on conflict (id) do nothing`，
/// 命中回查原行返回同一行，见 `insertWithClientId`）。所以**id 归客户端生成**，
/// 与契约注释一致；R2 的「id 服务端生成」对 `workout_plan` / `workout_record` 不适用。
/// 这一裁定直接写在服务端文件头，客户端照此发送 `id` 即可，无需也不应自己生成。
/// （冲突的取舍不在本文件决定，而是如实记录服务端的裁定。）
class HttpWorkoutRepository implements WorkoutRepository {
  HttpWorkoutRepository(this._api);

  final DataApiClient _api;

  /// 全部运动计划（含未启用的）。
  ///
  /// 无参列表端点：可见范围由服务端从 token 推导（`ctx.students`），
  /// 不再照抄本地的「取全表 → 内存过滤」（见类注释 ①）。
  @override
  Future<List<WorkoutPlan>> queryWorkoutPlans() async {
    final items = await _api.getItems('/data/workouts/plans');
    return items.map(_workoutPlanFromRow).toList();
  }

  /// 全部运动记录。无参列表端点（可见性同 `queryWorkoutPlans`）。
  @override
  Future<List<WorkoutRecord>> queryWorkoutRecords() async {
    final items = await _api.getItems('/data/workouts/records');
    return items.map(_workoutRecordFromRow).toList();
  }

  /// 新增一条运动记录。
  ///
  /// **`id` 是客户端自带、且是幂等键**（见类注释 ②）：服务端 `on conflict (id)
  /// do nothing` + 回查，重试复用同一 id 就返回原行而非插两条。所以这里**原样发送
  /// `record.id`**，绝不自己生成或改写它。时间上行必须带时区（UTC），否则服务端
  /// 按服务端时区解释，静默偏一整天（R3）。
  @override
  Future<void> insertWorkoutRecord(WorkoutRecord record) async {
    await _api.postJson('/data/workouts/records', body: {
      'id': record.id,
      'project': record.project,
      'startAt': utcTimeText(record.start),
      'endAt': utcTimeText(record.end),
      'minutes': record.minutes,
      'feedback': record.feedback,
      'planId': record.planId,
      'studentId': record.studentId,
    });
  }

  /// 新建运动计划。`plan.id` 同为主键、同为幂等键，原样发送（见类注释 ②）。
  @override
  Future<void> insertWorkoutPlan(WorkoutPlan plan) async {
    await _api.postJson('/data/workouts/plans', body: {
      'id': plan.id,
      'title': plan.title,
      'project': plan.project,
      'weekdays': plan.weekdays.join(','),
      'targetMinutes': plan.targetMinutes,
      'isActive': plan.isActive,
      'startDate': utcTimeText(plan.startDate),
      'endDate': utcTimeText(plan.endDate),
      'startTime': plan.startTime,
      'endTime': plan.endTime,
      'cycleType': plan.cycleType.name,
      'customWeekdays': plan.customWeekdays.join(','),
      'studentId': plan.studentId,
    });
  }

  /// 启用 / 停用计划。传的是**目标值**（`setPlanActive` 的语义），重复调用结果相同。
  @override
  Future<void> updateWorkoutPlanActive(String id, bool isActive) async {
    await _api.postJson('/data/workouts/plans/active',
        body: {'id': id, 'isActive': isActive});
  }

  WorkoutPlan _workoutPlanFromRow(Map<String, dynamic> row) {
    return WorkoutPlan(
      id: textOf(row['id']),
      title: textOf(row['title']),
      project: textOf(row['project']),
      weekdays: _weekdayList(row['weekdays']),
      targetMinutes: intOf(row['targetMinutes']),
      isActive: boolOf(row['isActive'], fallback: false),
      // 服务端给的是带 Z 的 UTC，下行必须 .toLocal()。nullable 列用 timeOf。
      startDate: timeOf(row['startDate']),
      endDate: timeOf(row['endDate']),
      // 这两列存的是 '17:30' 这种展示串（DDL 刻意不映射成 TIME），原样取。
      startTime: textOf(row['startTime'], fallback: '08:00'),
      endTime: textOf(row['endTime'], fallback: '09:00'),
      cycleType:
          WorkoutCycleTypeX.fromName(textOf(row['cycleType'], fallback: 'weekly')),
      customWeekdays: _weekdayList(row['customWeekdays']),
      studentId: textOf(row['studentId']),
    );
  }

  WorkoutRecord _workoutRecordFromRow(Map<String, dynamic> row) {
    return WorkoutRecord(
      id: textOf(row['id']),
      project: textOf(row['project']),
      // 业务时间（学生实际做的时刻），下行 .toLocal()。
      start: timeOr(row['startAt'], DateTime.now()),
      end: timeOr(row['endAt'], DateTime.now()),
      minutes: intOf(row['minutes']),
      feedback: textOf(row['feedback']),
      planId: textOf(row['planId']),
      studentId: textOf(row['studentId']),
    );
  }

  /// 把服务端逗号串（与本地 `weekdays`/`customWeekdays` 同形）解析回列表。
  static List<String> _weekdayList(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return const <String>[];
    return raw
        .replaceAll('[', '')
        .replaceAll(']', '')
        .split(',')
        .where((e) => e.trim().isNotEmpty)
        .map((e) => e.trim())
        .toList();
  }
}
