import '../models/study_plan_checkin_model.dart';
import '../models/study_plan_model.dart';
import '../models/workout_model.dart';
import '../repositories/study_plan_repository.dart';
import 'data_api_client.dart';
import 'data_row_values.dart';
import 'wire_status.dart';

/// 学习计划与打卡的**服务端实现**（`StudyPlanRepository` 的第二个实现）。
///
/// 本地那份在 `local_database_service.dart`。两者实现同一契约，控制器一行不用改。
///
/// ## 三处「照搬本地写法就会错」的地方
///
/// **① 可见性不再由客户端过滤。** 本地 `queryStudyPlans` 里
/// 「`student` 就返回全表、家长只按 `userRole` 过滤」那条规则，上云后是**跨学生越权**
/// （见契约类注释的陷阱⑥）。服务端改成「范围永远来自身份（`ctx.students`），
/// 学生的全量 / 家长的只自己发的」—— 所以 `queryStudyPlans` 的 `userRole`
/// 参数和 `queryStudyPlanCheckins` 的「取全表再内存过滤」**都不能照抄**：
/// 这里直接打一个无参的列表端点，可见范围由 token 推导（见各自方法注释）。
///
/// **② `userRole` / 归属由服务端写。** 本地把 `userRole` 当数据列存（家长发起记
/// `parent`、学生自建记 `student`）。服务端从 `ctx.role` 推导 `user_role`，
/// 客户端送来的 `userRole` 参数既不可信也无用，留着只为签名不变。
/// `studentId` 同理：body 里它是「在可见集合里挑一个」，越界 403。
///
/// **③ `status` 两侧词表不同，客户端不能直接上行 `.name`**（映射集中在 `wire_status.dart`）。
///
/// ## `study_plan.status` 的两套词
///
/// 客户端（`StudyPlanStatus`）：`pendingStudentConfirm / active / rejected / withdrawn / completed`
/// 服务端（`STUDY_PLAN_STATUSES`，见 `serverless/data-service/src/vocab.js`）：
/// `pending / active / rejected / completed / expired`
///
/// `active` 两侧已同词（2026-09-20 服务端由 `accepted` 统一过来）。
/// **剩下的差异不是命名风格**：
///
/// - `pendingStudentConfirm` ↔ 服务端 `pending`：同一个语义、两个词。合并它要动客户端的
///   **落库值**（枚举 `.name` 直接进本地 SQLite），所以暂时保留一对一映射。
/// - `withdrawn`（家长撤回）**服务端没有对应值** —— 不能硬塞成 `expired`（那是「到期自动失效」，
///   发起方与含义都不同）。所以上行时**显式抛错**暴露冲突，而不是静默吞掉。
/// - `expired` 是服务端独有、客户端枚举没有 —— 下行回落到 `withdrawn` 仅是「不崩」的兜底，
///   **不是语义等价**。真正该做的是客户端也补一个 `expired`，而不是把两个不同的结束原因
///   混成一个（那样「谁把它结束的」这条信息就没了）。
///
/// 两套词的完整对照、理由与判据都在 `wire_status.dart` / `test/wire_status_test.dart`。
///
/// **理想的收尾**：客户端补上 `expired` 后，剩下的只是两个词的名字 ——
/// 那时映射层可以整体删掉。在此之前，集中在一处胜过每个调用点各写一份 switch。
class HttpStudyPlanRepository implements StudyPlanRepository {
  HttpStudyPlanRepository(this._api);

  final DataApiClient _api;

  /// `userRole` 被**刻意忽略**（见类注释 ① ②）。
  ///
  /// 本地实现里它同时决定「过滤方式」和「写入 `user_role` 列」；上云后这两件事
  /// 都收归服务端（按 token 过滤 + 由 `ctx.role` 写列）。这个参数留着只为签名不变。
  @override
  Future<List<StudyPlanModel>> queryStudyPlans(String userRole) async {
    // 无参列表端点：可见范围由服务端从 token 推导（`ctx.students`），
    // 不再照抄本地的「student 返回全表」。照抄在这里是跨学生越权。
    final items = await _api.getItems('/data/study-plans');
    return items.map(_studyPlanFromRow).toList();
  }

  /// 新建计划。
  ///
  /// `userRole` 忽略（服务端写 `user_role`，见类注释 ②）。`status` 走显式映射：
  /// 若本地状态在服务端无对应（`withdrawn`），不送该字段，让列保持 NULL ——
  /// 新建计划在实际业务里只会以 `pendingStudentConfirm` / `active` 起步，两者都有映射，
  /// 所以这一支只是兜底，不掩盖冲突。
  @override
  Future<void> insertStudyPlan(StudyPlanModel plan, String userRole) async {
    final serverStatus = studyPlanStatusToWire(plan.status);
    final body = <String, Object?>{
      'title': plan.title,
      'content': plan.content,
      'startAt': utcTimeText(plan.startAt),
      'endAt': utcTimeText(plan.endAt),
      'type': plan.type,
      'cycleType': plan.cycleType.name,
      'studentId': plan.studentId,
      'customWeekdays':
          plan.customWeekdays.isEmpty ? null : plan.customWeekdays.join(','),
      'rejectReason': plan.rejectReason.isEmpty ? null : plan.rejectReason,
    };
    if (serverStatus != null) body['status'] = serverStatus;
    await _api.postJson('/data/study-plans', body: body);
  }

  /// 改计划状态（确认 / 拒绝 / 完成）。
  ///
  /// ⚠️ 契约与方法注释都写明「本方法不做状态机校验，只把 status 写下去」。
  /// 服务端 `updatePlanStatus` 也只校验 status 是已知词（拦拼写），不校验流转，
  /// 校验权明确归 L1（控制器）—— 别出现「两边都以为对方在拦」。
  ///
  /// `rejectReason` 仅在传入时写入；服务端 `toOptionalText` 会把空串规范成 NULL
  /// （读端按 NULL 判断「有没有被拒绝过」），与本地语义一致。
  ///
  /// ⚠️ `withdrawn` 在服务端词表里没有对应值（见类注释），无法持久化：
  /// 这里直接抛错把冲突逼出来，而不是静默吞掉或硬塞一个近似词。
  @override
  Future<void> updateStudyPlanStatus(
    String id,
    StudyPlanStatus status, {
    String? rejectReason,
  }) async {
    final serverStatus = studyPlanStatusToWire(status);
    if (serverStatus == null) {
      // 诚实暴露词表缺口：应由服务端在 `STUDY_PLAN_STATUSES`（`src/vocab.js`）
      // 扩充 `withdrawn`，而不是在客户端把「撤回」伪装成 `expired` / `completed`。
      throw Exception(
        'study_plan.status=$status 在服务端词表（pending/active/rejected/'
        'completed/expired）中无对应值，无法上云持久化；该冲突待服务端扩充词表解决。',
      );
    }
    final body = <String, Object?>{'id': id, 'status': serverStatus};
    if (rejectReason != null) body['rejectReason'] = rejectReason;
    await _api.postJson('/data/study-plans/status', body: body);
  }

  /// 取全部打卡记录，但**无参、不下推过滤到客户端**。
  ///
  /// 本地实现是「取全表 → 调用方按 `studentId` 内存过滤」。上云后那等于
  /// 每个客户端都拉走全库打卡记录（契约注释点名的越权点），所以这里打
  /// 无参的 `listCheckins`：服务端按 token 推导可见范围（`ctx.students`），
  /// 客户端不再「取全表」。过滤的差异到此为止，之后仍按模型原样返回。
  @override
  Future<List<StudyPlanCheckin>> queryStudyPlanCheckins() async {
    final items = await _api.getItems('/data/study-plans/checkins');
    return items.map(_checkinFromRow).toList();
  }

  /// 打卡（同一天同一计划重复调用只应留下一条）。
  ///
  /// 幂等来自服务端的 `UNIQUE(plan_id, date)` + `on conflict … do nothing`，
  /// 与本地 `ConflictAlgorithm.replace` 同族，不是「先查后插」。
  /// 服务端返回 `{created: true/false, item}`：
  /// `created == true` 表示这次是新插的，`false` 表示撞唯一键、把已存在的那行原样返回
  /// —— **这就是幂等的证据**（重复提交不会翻倍，也不会 409）。
  /// 契约返回 `void`，所以我们读一次 `created` 仅作记录，不向上暴露。
  ///
  /// 注意：服务端**自行生成** `id` 与 `createdAt`（见 `checkin()`），
  /// 客户端 `checkin.id` 在此被忽略；幂等键是 `(planId, date)` 而非 id。
  /// `date` 必须是客户端给的纯日期（学生所在时区的今天），不能由服务端按 UTC 算，
  /// 否则「晚 8 点后打卡记到明天」。
  @override
  Future<void> insertStudyPlanCheckin(StudyPlanCheckin checkin) async {
    final result = await _api.postJson('/data/study-plans/checkin', body: {
      'planId': checkin.planId,
      'studentId': checkin.studentId,
      'date': checkin.date,
    });
    // 读一次 `created`：幂等证据（true=新插，false=命中唯一键返回原行）。
    // 契约要求 void，仅在此记录，不向上暴露。
    final _ = result['created'] as bool?;
  }

  /// 取消打卡。按**自然键**（计划 + 日期）删，不是按 id（与本地一致）。
  @override
  Future<void> deleteStudyPlanCheckin(String planId, String date) async {
    await _api.postJson('/data/study-plans/checkin/delete',
        body: {'planId': planId, 'date': date});
  }

  // 状态词的翻译不在这里，在 `wire_status.dart` —— 关系与学习计划两份映射
  // 集中在同一处，且那份文件有单测（`test/wire_status_test.dart`）。
  // 这里只留一句结论：`withdrawn` 服务端没有对应值，上行时**显式失败**，
  // 不会静默改写成 `expired` 那种「看起来像、其实换了件事」的值。

  StudyPlanModel _studyPlanFromRow(Map<String, dynamic> row) {
    return StudyPlanModel(
      id: textOf(row['id']),
      title: textOf(row['title']),
      content: textOf(row['content']),
      // 服务端给的是带 Z 的 UTC，必须 .toLocal()，否则显示差一个时区。
      startAt: timeOr(row['startAt'], DateTime.now()),
      endAt: timeOr(row['endAt'], DateTime.now()),
      type: textOf(row['type']),
      status: studyPlanStatusFromWire(row['status'] as String?),
      studentId: textOf(row['studentId']),
      cycleType: WorkoutCycleTypeX.fromName(textOf(row['cycleType'], fallback: 'daily')),
      customWeekdays: _weekdayList(row['customWeekdays']),
      rejectReason: textOf(row['rejectReason']),
    );
  }

  StudyPlanCheckin _checkinFromRow(Map<String, dynamic> row) {
    return StudyPlanCheckin(
      id: textOf(row['id']),
      planId: textOf(row['planId']),
      studentId: textOf(row['studentId']),
      // `date` 在库里是纯日期（DATE），但服务端 `rowToApi` 会把它序列化成
      // `YYYY-MM-DDTHH:MM:SS.000Z`（甚至因时区变前一天）。原样比较会永远对不上，
      // 导致「打卡后刷新又变回待打卡」。统一归一成纯 `yyyy-MM-dd`。
      date: studyPlanDateKeyFromRaw(row['date']),
      // 服务端 `createdAt` 是带 Z 的 UTC，必须 .toLocal()，否则显示差一个时区。
      createdAt: timeOr(row['createdAt'], DateTime.now()),
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
