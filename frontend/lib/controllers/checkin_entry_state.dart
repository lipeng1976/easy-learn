import 'package:get/get.dart';

import '../models/checkin_models.dart';
import '../repositories/checkin_repository.dart';
import '../services/database_service.dart';
import 'checkin_controller.dart';

/// 某学生的打卡进度（入口卡颜色的唯一来源）。
///
/// ## 2026-10-29 起口径变了：从「今天」改成「全部没做的」
///
/// 原来统计「今天出了几份、做完几份」。可打卡已经**不再限定当天**：
/// 家长头天出的题，孩子第二天照样要做。继续按天统计的话，卡片会在
/// 「今天没出题」时亮着绿标「待完成」，点进去却发现一份都没有 ——
/// 用户报的「看得到未完成、点进去没有」正是这两处口径打架。
///
/// 现在卡片和页面看的是**同一个数**：还有几份没交。
class CheckinProgress {
  const CheckinProgress({required this.pending, required this.total});

  /// 还没交卷的份数（跨天累计）。
  final int pending;

  /// 一共几份（跨天累计）。
  final int total;

  /// 一份都没有：既没出过题，也没做过。此时卡片不该亮绿标「待完成」，
  /// 那会让家长以为"系统在催他"，而其实家长根本没出过题。
  bool get empty => total == 0;

  /// 出过题，且全都做完了。
  bool get allDone => total > 0 && pending == 0;

  /// 还有没做的（做了一部分也算）。
  bool get hasPending => pending > 0;
}

/// 「还有几份打卡没做」—— 入口卡（`CheckinEntryCard`）颜色的唯一来源。
///
/// ## 为什么不是卡自己查一次就完事
///
/// 卡片常驻计划标签页：孩子做完打卡**返回计划页时不会重建**，
/// 卡自己查的那一次结果已经过期 —— 做完了还挂着「待完成」的颜色，
/// 醒目就变成了误导。所以必须有个**跨页面的状态**：
/// [CheckinController] 在 load / 出题 / 交卷三个时点调 [applyCounts]
/// 把权威数推过来，卡片进入时再调 [load] 拉一次初始值兜底。
///
/// ## 推送必须双向
///
/// 只在交卷时往前推、从不回退的话：别处删了数据卡片还亮着「已完成」，
/// 孩子点进去却是一份没答过的题 —— 用户报的「数据乱了」就是它。
/// 所以 [applyCounts] 覆盖式写入，pending/total 都以推过来的为准。
///
/// ## 查询失败不挡入口
///
/// 服务端连不上时保持现状：颜色错一次是小事，把入口藏掉是大事。
/// 真错了，孩子点进去页面自己会报错。
class CheckinEntryState extends GetxController {
  CheckinEntryState({CheckinRepository? repository})
      : _repo = repository ?? DatabaseService.checkin;

  final CheckinRepository _repo;

  /// studentId -> 打卡进度。
  ///
  /// key 不含日期：每次进页面 [load] 都会重查覆盖，这是**全量**口径，
  /// 不存在「昨天的数带到今天」这回事了。
  final RxMap<String, CheckinProgress> progressByStudent =
      <String, CheckinProgress>{}.obs;

  /// studentId -> **还没交的那几份**（按出题顺序，先出的先做）。
  ///
  /// 计划页的「今日打卡」要把刚出的题直接列在「每日概念打卡」下面 ——
  /// 只给一个「待完成 2 份」的数字，孩子还得点进去才知道是哪两科。
  /// 只取前 [previewLimit] 份：多了也没有信息量（同一科出十份时，
  /// 列十行只会把下面「学习计划」整区顶出屏幕）。
  final RxMap<String, List<CheckinQuiz>> pendingByStudent =
      <String, List<CheckinQuiz>>{}.obs;

  /// 入口卡最多带几份明细。列表页仍然是全量（`limit = 0`）。
  static const int previewLimit = 6;

  Future<void> load({String? studentId}) async {
    final id = studentId ?? CheckinController.targetStudentId();
    if (id == null || !DatabaseService.isCloud) return;
    try {
      // 两个数要两次请求。未完成那份顺便把**明细**也取回来（计划页要逐条列），
      // 所以它带 limit；总份数只用 `total`（过滤后的总数，跟 limit 无关），
      // 只要 1 条。并行发，别让入口卡多等一个来回。
      final pages = await Future.wait([
        _repo.getQuizzes(
          studentId: id,
          status: CheckinQuizStatus.pending,
          limit: previewLimit,
        ),
        _repo.getQuizzes(studentId: id, status: CheckinQuizStatus.all, limit: 1),
      ]);
      applyCounts(
        id,
        pending: pages[0].total,
        total: pages[1].total,
        pendingQuizzes: pages[0].items,
      );
    } catch (_) {
      // 刻意吞掉：见类注释「查询失败不挡入口」。
    }
  }

  /// 由 [CheckinController] 在 load / 出题 / 交卷三个时点推过来。
  ///
  /// 覆盖式写入：pending/total 以推过来的为准（存量被删时变小同样生效）。
  ///
  /// [pendingQuizzes] 缺省（null）时**不动**已缓存的明细：老调用点只有
  /// 计数、没有列表，硬清空会让计划页那几行忽然消失。
  void applyCounts(
    String? studentId, {
    required int pending,
    required int total,
    List<CheckinQuiz>? pendingQuizzes,
  }) {
    final id = studentId ?? CheckinController.targetStudentId();
    if (id == null) return;
    progressByStudent[id] = CheckinProgress(pending: pending, total: total);
    if (pendingQuizzes != null) {
      pendingByStudent[id] = List<CheckinQuiz>.unmodifiable(pendingQuizzes);
    }
  }
}
