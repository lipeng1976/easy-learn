import '../models/point_model.dart';

/// 积分账本的数据访问契约（L2）。
///
/// 这一层只负责「把数据取出来 / 写回去」，**不含任何业务判断** ——
/// 分值怎么算、够不够扣、要不要发，都在 `PointController`（L1）。
///
/// 抽这一层是为了把「数据从哪来」与「业务怎么算」分开：将来把本地 SQLite
/// 换成云端 API 时只替换实现，控制器一行不动。
/// 详见 `doc/architecture-refactor-plan.md`。
abstract class PointRepository {
  /// 某个孩子的全部流水，最新在前。
  Future<List<PointLedgerEntry>> queryPointLedger(String studentId);

  /// 家长配过的分值。**没配过的动作在这里没有行**，由调用方回退默认值。
  Future<List<PointRule>> queryPointRules(String studentId);

  /// 覆盖式写入一条规则（复合键 `(studentId, action)` 唯一）。
  Future<void> upsertPointRule(PointRule rule);

  /// 找一条「还活着」的流水（`reversedAt` 为空）。
  ///
  /// ⚠️ 这只用于**给出明确的「重复」结论**，**不承担正确性** ——
  /// 见 [insertPointLedger] 的说明。调用方不能靠它防重。
  Future<PointLedgerEntry?> findActivePointEntry({
    required String studentId,
    required String idempotencyKey,
  });

  /// 记一笔流水。**返回 `false` 表示「因为幂等键冲突，这次没有写入」。**
  ///
  /// ⚠️ **这个返回值是幂等的最终裁决**，调用方必须据此判断是否真的发了分。
  ///
  /// 本地实现靠的是数据库那道部分唯一索引
  /// （`idx_point_ledger_active_key`，建在 `reversedAt IS NULL` 上）
  /// 配合 `ConflictAlgorithm.ignore` + `rowId > 0` —— 这个组合是**原子**的。
  ///
  /// **换成云端实现时，服务端必须提供同等强度的原子保证**：一条唯一约束，
  /// 或一个原子的「若不存在则插入」。只靠调用方「先查一次再插」是不够的 ——
  /// 查与插之间永远有缝，单机时这条缝被单线程事件循环盖住，
  /// 多端并发时会**静默重复发分**（重复发分不报错，只表现为「分不对」）。
  Future<bool> insertPointLedger(PointLedgerEntry entry);

  /// 把一笔标记为已撤销。
  ///
  /// 撤销是**标掉原记录 + 补一笔相反数**，不删记录 —— 账本 append-only
  /// 才使得「合并两端数据」退化成按 id 求并集。
  Future<void> markPointEntryReversed(String id, DateTime reversedAt);

  // ===== 行为扣分配置 =====
  //
  // 这三条给出默认实现而不是 abstract：项目里有几个只测发分/兑换的
  // 假仓库，它们不该因为新增一个无关能力就全编译不过。真正会用行为的
  // 仓库（本地 / HTTP）必须覆盖，覆盖不到就会显式抛 UnimplementedError
  // —— 宁可炸，也不要静默返回空列表让家长以为「没配过行为」。

  Future<List<PointBehavior>> queryPointBehaviors(String studentId) =>
      throw UnimplementedError('$runtimeType 未实现 queryPointBehaviors');

  Future<void> upsertPointBehavior(PointBehavior behavior) =>
      throw UnimplementedError('$runtimeType 未实现 upsertPointBehavior');

  Future<void> deletePointBehavior(String studentId, String id) =>
      throw UnimplementedError('$runtimeType 未实现 deletePointBehavior');
}
