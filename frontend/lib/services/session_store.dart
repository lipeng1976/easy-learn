import 'session_store_stub.dart'
    if (dart.library.io) 'session_store_io.dart'
    if (dart.library.html) 'session_store_html.dart';

/// 会话凭证的落地处（token + 当前用户）。
///
/// ## 为什么必须落盘
///
/// 上云之后，「我是谁」不再由本地库回答，而是由一份**服务端签发的 token** 回答。
/// 不落盘的后果不是「多登一次」这么轻：任何一次冷启动（刷新页面、系统回收进程、
/// 切后台太久）都会让 App 回到未登录状态 —— 而用户看到的是
/// **「我昨天做的作业全没了」**，因为他看到的是空列表。
///
/// ## 为什么不存口令
///
/// 只存 token。token 是**可吊销的**（服务端有会话表），口令不是 ——
/// 把口令留在设备上，等于把它交给每一个能读到这个文件的人，
/// 而注销账号也收不回来。
abstract class SessionStore {
  /// 读一次落盘内容到内存。Web 上是空操作。
  ///
  /// 显式一个 `initialize()` 而不是让 getter 自己去读，是为了让
  /// 「磁盘 I/O 什么时候发生」可预期：请求头里要同步取 token，
  /// 在一个同步 getter 里做异步 I/O 只会得到一个 null。
  Future<void> initialize();

  /// 当前 token。未登录时是空串。
  String? get token;

  /// 当前用户（服务端返回的那一份）。未登录时是 null。
  Map<String, dynamic>? get user;

  bool get isAuthenticated => (token ?? '').isNotEmpty;

  /// 当前用户 id。所有写端点都要靠它判断「这条数据属于谁」。
  String? get userId => user?['id'] as String?;

  /// 当前用户角色（`student` / `parent`）。
  String? get role => user?['role'] as String?;

  Future<void> save({required String token, required Map<String, dynamic> user});

  /// 清掉本地凭证。
  ///
  /// **登出流程的第一步就调它**，而且要在请求之前 —— 见 `HttpAuthApi.logout`
  /// 的说明：登出请求失败（比如断网）不能把用户永远留在一个「已经不想用了」的
  /// 登录态里。
  Future<void> clear();
}

/// 按平台建一个。全局只有一份（凭证是全局状态）。
SessionStore createSessionStore() => createPlatformSessionStore();
