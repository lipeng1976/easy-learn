import 'data_api_client.dart';

/// 服务端签发的一次会话。
class RemoteAccount {
  const RemoteAccount({required this.token, required this.user});

  /// 会话 token。**必须立刻落盘**（见 `session_store.dart`）。
  final String token;

  /// 服务端返回的用户行（`id / name / phone / role / avatar …`）。
  ///
  /// 注意 `id` 现在是**服务端生成的 uuid**，与本地那份 `user_1712…` 不是一回事 ——
  /// 上云之后这串 id 就是 `studentId`、是 `point_ledger.student_id`、
  /// 是所有归属列的取值来源。
  final Map<String, dynamic> user;
}

/// 账号相关的四条端点（登录 / 注册 / 登出 / 改密）。
///
/// ## 它为什么不是一个 `AuthDataSource` 实现
///
/// `AuthDataSource` 是**本地库的形状**：`findUserByPhone` 返回含明文口令的行，
/// `AuthService` 自己拿它跟用户输入比。服务端没有这个动作 ——
/// 口令在那儿是 scrypt 哈希，比对发生在服务端进程里，而且登录顺带签发会话。
///
/// 硬把两者对上的结果是「客户端拿一个哈希去比」，那不仅没意义，
/// 还会让人以为口令校验还在客户端（于是把它当安全边界）。
///
/// 所以云端登录是**另一条路径**：`AuthService` 在云端模式下直接调这里。
class HttpAuthApi {
  HttpAuthApi(this._api);

  final DataApiClient _api;

  /// 登录。
  ///
  /// `role` 传上去是**校验**而不是声明：服务端在 `role` 与账号实际角色不符时
  /// 会拒掉（登录页要求用户选身份，这条守着它）。不传就不校验。
  ///
  /// 成功后**立刻采纳会话**（写入 `SessionStore`），因为后面每一个请求都要用它。
  Future<RemoteAccount> login({
    required String phone,
    required String password,
    String? role,
  }) async {
    final data = await _api.postJson('/auth/login', body: {
      'phone': phone,
      'password': password,
      if (role != null && role.isNotEmpty) 'role': role,
    });
    return _adopt(data);
  }

  /// 注册。成功后同样直接拿到会话（服务端注册即登录）。
  Future<RemoteAccount> register({
    required String phone,
    required String password,
    required String role,
    String? name,
  }) async {
    final data = await _api.postJson('/auth/register', body: {
      'phone': phone,
      'password': password,
      'role': role,
      if (name != null && name.isNotEmpty) 'name': name,
    });
    return _adopt(data);
  }

  /// 读当前身份。冷启动时用它验证本地那份 token 还算不算数。
  Future<Map<String, dynamic>> me() async {
    final data = await _api.getJson('/auth/me');
    return Map<String, dynamic>.from(data['user'] as Map? ?? const {});
  }

  /// 登出。
  ///
  /// ## 顺序是刻意的：**先清本地，再打服务端**
  ///
  /// 反过来的话，一次失败的登出请求（断网、服务重启、token 已过期）
  /// 会把用户永远留在一个「他明确表示不想再用」的登录态里 ——
  /// 而他能做的只有卸载重装。
  ///
  /// ## 但「先清」有个必须配套的动作：**把 token 抓住带过去**
  ///
  /// 服务端靠 `Authorization` 头里的 token 判断该吊销**哪一个**会话
  /// （`routes/auth.js` 的 `logout` 用 `ctx.sessionId`，而它来自 `resolveIdentity`）。
  /// 清完本地再发、又让客户端自己从会话里取凭证，那条请求就是**未认证**的 ——
  /// 结果是 401，然后被下面的 catch 当成「已经登出」吞掉。
  ///
  /// 症状是**静默且严重**的：用户点了登出、界面回到登录页，而**服务端那个会话
  /// 一直活着**，谁拿着这个 token 都能继续读到全部数据（换台设备、翻一遍历史请求
  /// 都能拿到）。这不是「多点一次登录」的体验问题，是一次没能完成的登出。
  ///
  /// 这条是被 `test/cloud_live_test.dart` 抓出来的：用例在登出后拿同一个 token
  /// 再问一次 `/auth/me`，期望 `token_invalid`，实际拿到了一份完整的用户信息。
  Future<void> logout() async {
    final token = _api.session.token;
    await _api.session.clear();
    if (token == null || token.isEmpty) return; // 本来就没登录，没什么可吊销
    try {
      await _api.postJson('/auth/logout', authToken: token);
    } on DataApiException catch (e) {
      // 401 等于「这个会话已经没了」—— 目标达成了。
      // 其他失败（网络、5xx）也不该冒泡给界面：服务端的会话有过期时间，
      // 它迟早会自己消失。
      if (!e.needsReLogin) {
        // 只留一行日志，不打扰用户。
        // ignore: avoid_print
        print('[auth] 登出请求未成功（本地凭证已清）：$e');
      }
    }
  }

  /// 改密。
  ///
  /// ⚠️ 服务端改密会**吊销全部旧会话并签发一个新的** —— 必须用返回的 token
  /// 覆盖本地那一份，否则当前这台设备会当场被登出（用户看到的是一次
  /// 「改密成功」之后立刻跳回登录页）。
  Future<RemoteAccount> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final data = await _api.postJson('/auth/password', body: {
      'currentPassword': currentPassword,
      'newPassword': newPassword,
    });
    return _adopt(data);
  }

  /// 当前设备列表（「登录设备管理」用）。
  Future<List<Map<String, dynamic>>> sessions() =>
      _api.getItems('/auth/sessions');

  Future<RemoteAccount> _adopt(Map<String, dynamic> data) async {
    final token = data['token'];
    final user = data['user'];
    if (token is! String || token.isEmpty || user is! Map) {
      // 服务端返回了成功但没有 token —— 这是协议违约，不是业务失败。
      // 静默继续会让「登录成功但每个请求都 401」，排查方向会完全跑偏。
      throw DataApiException(
        code: 'bad_response',
        message: '服务端登录响应里缺少 token 或 user',
      );
    }
    final account = RemoteAccount(
      token: token,
      user: Map<String, dynamic>.from(user),
    );
    await _api.session.save(token: account.token, user: account.user);
    return account;
  }
}
