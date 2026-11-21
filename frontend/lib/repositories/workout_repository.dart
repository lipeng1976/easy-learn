import '../models/workout_model.dart';

/// 运动计划与运动记录的数据访问契约（L2）。
///
/// ## 这批方法**两边都没有过滤**，上云时是越权点
///
/// 三个读/写方法都没有 `studentId` 参数，也没有任何 where 条件：
/// 当前是「取回全表 → 调用方按 `studentId` 内存过滤」
/// （`WorkoutPlanModel` / `WorkoutRecord` 都带 `studentId` 列，
/// 过滤发生在拿到列表之后）。
///
/// 单机单库下这是对的——库里只有这台设备的数据。上云后**必须把过滤下推到服务端**：
/// ① 每个客户端都会拉走全库运动数据；② 内存过滤可绕过，等于没有数据隔离。
///
/// 接口这里**刻意不加 `studentId` 参数**——加了会让人以为「传了就安全了」，
/// 而真正的修法是服务端从 token 推导。参数怎么加，等第 2 步身份上移时一起定。
abstract class WorkoutRepository {
  /// 全部运动计划（含未启用的）。
  Future<List<WorkoutPlan>> queryWorkoutPlans();

  /// 全部运动记录。
  Future<List<WorkoutRecord>> queryWorkoutRecords();

  /// 新增一条运动记录。
  ///
  /// **幂等键就是 `record.id`**（建表时 `id` 是主键）。这条很重要：
  /// 上云后客户端重试是常态，只要重试时**复用同一个 id**，重复提交就会撞主键
  /// 而不是插出两条运动记录——「今天跑了几次」不会被网络抖动改成两次。
  ///
  /// 所以别把 id 改成服务端生成的新值：那会**把唯一的幂等键弄丢**，
  /// 而且在离线队列（第 4 步）里客户端必须能自己先定 id。
  Future<void> insertWorkoutRecord(WorkoutRecord record);

  /// 新建运动计划。`plan.id` 同为主键，同上。
  Future<void> insertWorkoutPlan(WorkoutPlan plan);

  /// 启用 / 停用计划。传的是**目标值**，不是「切换」（重复调用结果相同）。
  Future<void> updateWorkoutPlanActive(String id, bool isActive);
}
