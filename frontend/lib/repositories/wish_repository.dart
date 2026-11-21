import '../models/wish_model.dart';

/// 心愿的数据访问契约（L2）。
///
/// ## 先说一件与鉴权有关的事（上云前必须处理）
///
/// 本接口有 4 个读方法带 `userRole` / `studentId` 参数，它们是**调用方自报的
/// 可见性依据**，不是从身份推导出来的。当前实现直接拿它当 SQL 条件：
///
/// ```dart
/// await db.query('wish', where: 'userRole = ?', whereArgs: [userRole]);
/// ```
///
/// 而按 `studentId` 挑「我结对的孩子」这件事，客户端是**先取全表、再内存过滤**
/// （`ParentController._belongsToBound`）。单机单库下这没问题——库里本来就
/// 只有这一台设备的数据。上云后两件事都会变质：
/// - `userRole` 由客户端给 → 改包把角色写成对方，就能读到对方的心愿；
/// - 全表取回再过滤 → ①每个客户端都下载了全库心愿 ②过滤本身可绕过。
///
/// **服务端实现必须从 token 推导身份**，只接受 `wishId` 这类资源标识，
/// 不接受 `userRole` 作为信任输入。参数留在接口上是为了让本地实现继续可用，
/// 它**不是契约的一部分**（同 [RelationshipRepository] 的说明）。
abstract class WishRepository {
  /// 按**发起角色**取心愿。
  ///
  /// `userRole` 是写入时记在 `wish.userRole` 列上的那个值，不是查询者自己的角色。
  Future<List<WishModel>> queryWishes(String userRole);

  /// 全部公开心愿（`isPublic = 1`），不分角色。
  Future<List<WishModel>> queryPublicWishes();

  /// 某个学生的公开心愿（家长端「孩子的心愿墙」用）。
  Future<List<WishModel>> queryPublicWishesByStudent(String studentId);

  /// 「未闭环」的心愿：**没归档，且双方没都确认**。
  ///
  /// 注意这个定义不等于「没兑现」——`isArchived` 与两个 confirmed 是独立的两组
  /// 字段，本方法只按它们组合判断。改这个口径会同时影响学生端与家长端的待办提醒。
  Future<List<WishModel>> queryUnfulfilledWishes();

  /// 新建心愿。
  ///
  /// [userRole] 会被**写进表**（`wish.userRole` 列），即表里存了一个身份字段。
  /// 上云后这一列应换成由服务端写入的 `creatorId`，不再是客户端传的字符串。
  Future<void> insertWish(WishModel wish, String userRole);

  /// 改确认状态。`null` = **本次不改这个字段**。
  ///
  /// 两个参数都是 `null` 时**静默返回**（不是错误、不抛异常）——
  /// 调用方不必先判断再调用。
  Future<void> updateWishConfirmation({
    required String id,
    bool? parentConfirmed,
    bool? studentConfirmed,
  });

  /// 归档 / 取消归档。传的是**目标值**，不是「切换」（重复调用结果相同）。
  Future<void> updateWishArchived(String id, bool isArchived);

  /// 心愿的兑换状态：定价 / 申请 / 兑现 / 拒绝。
  ///
  /// ## 这个签名是 JSON 安全的，照它做就行
  ///
  /// 清空用**显式的 `clear*` 标志**，而不是靠「传了 null」来推断 ——
  /// 这正是 `updateHomework` 踩过的坑（见 `architecture-refactor-plan.md` §3②）：
  /// `{"a": null}` 与「`a` 这个键不存在」在标准 JSON 库里是同一个东西。
  /// 这里用标志位把意图显式化，序列化后语义不变。
  ///
  /// **但 `redeemedAt` 只能设、不能清**（没有对应的 clear 标志）。将来若要支持
  /// 「撤销兑现」，请补一个 `clearRedeemed`，**不要**改成用 `null` 表达清空。
  ///
  /// ## 为什么不做整体覆盖
  ///
  /// 刻意做成「传什么改什么」，而不是 `updateWish(id, WishModel)` 整行覆盖：
  /// 学生撤回申请和家长同时点兑现，两边各拿一份 `WishModel` 去写，
  /// 后写的会把先写的整段抹掉。只写自己关心的那几列，冲突面小得多。
  ///
  /// 上云后这个「部分更新」语义要原样保留，服务端**不能**退化成整行 replace。
  Future<void> updateWishRedeemState({
    required String id,
    int? pointCost,
    DateTime? redeemRequestedAt,
    DateTime? redeemedAt,
    DateTime? redeemRejectedAt,
    bool clearRedeemRequest,
    bool clearRedeemRejected,
  });
}
