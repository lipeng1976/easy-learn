import '../models/user_profile_model.dart';

/// 用户与档案的数据访问契约（L2）。
///
/// 只管读写，不含「谁能看谁的档案」这类判断 —— 那属于鉴权，
/// 上云后归服务端（见 [RelationshipRepository] 的说明）。
abstract class UserRepository {
  /// 读一个用户的档案。
  ///
  /// 返回值可空：用户不存在与「档案字段为空」是两件事，
  /// 前者是 `null`，后者是一个字段为空的 `UserProfileModel`。
  Future<UserProfileModel?> queryUserProfile(String userId);

  /// 读-合并-写：**只改传入的字段，其余列保留**。
  ///
  /// 实现里不做整行 replace —— 那会把这次没带的字段一起抹成空。
  Future<void> updateUserProfile(UserProfileModel profile);

  /// 按 id 批量取用户行（家长端把 `studentId` 解析成孩子姓名用）。
  ///
  /// 返回的是**原始行**而不是模型：调用方只用到 `name`/`avatar` 这类展示字段，
  /// 包一层模型反而会把「用户不存在」和「字段缺失」混在一起。
  Future<List<Map<String, dynamic>>> queryUsersByIds(List<String> ids);
}
