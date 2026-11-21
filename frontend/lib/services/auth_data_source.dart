/// 认证相关的数据入口。
///
/// 抽成接口是为了让 `AuthService` 的测试能塞一个内存实现进来
/// （见 `test/auth_service_test.dart`）。实现者用的是 `implements`，
/// 因此**这里每加一个方法，所有实现方都必须显式补上**，继承不到默认实现。
abstract class AuthDataSource {
  Future<Map<String, dynamic>?> findUserByPhone(String phone);

  Future<Map<String, dynamic>?> findUserByWechat(String openId);

  Future<void> saveUser(Map<String, dynamic> user);

  /// 改密码，并把 `passwordUpdatedAt` 一起写上。
  ///
  /// **本期没有界面会调到它** —— 走通得先接入短信网关
  /// （见 `doc/auth-extension-seams.md`）。提前把口子留在这里，
  /// 是为了接入时 `AuthService.resetPasswordBySmsCode` 不必再改数据层。
  ///
  /// 两个约束：
  /// - **`updatedAt` 由调用方传入**，不在实现里取 `DateTime.now()`：
  ///   测试要用注入时钟，实现里偷偷取一次当前时间就没法断言了。
  /// - 用户不存在时**抛异常**，不要静默成功。静默成功会让
  ///   「改密成功但下次还是登不上」这种最难查的问题出现。
  Future<void> updatePassword({
    required String userId,
    required String newPassword,
    required String updatedAt,
  });
}
