/// 端点常量**单一来源**。
/// 后端路由改动时只改这里，不要在页面/仓储里手写字符串。
class ApiEndpoints {
  const ApiEndpoints._();

  // 数据服务
  static const String health = '/health';
  static const String login = '/auth/login';
  static const String verifySession = '/auth/verify';
  static const String me = '/auth/me';
  static const String attachments = '/data/attachments';

  /// 读取附件只传 id，不传路径 —— 路径由服务端从库里查。
  static String attachment(String id) => '$attachments/${Uri.encodeComponent(id)}';

  // AI 网关
  static const String aiHealth = '/health';
  static const String reviewTips = '/ai/review/tips';
}
