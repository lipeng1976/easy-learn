import 'dart:convert';

import 'session_store.dart';
import 'web_storage.dart';

/// Web：浏览器 localStorage。
///
/// 与本地库那份数据（`easy_learn_web_store_v5`）**放在同一个 localStorage 里**，
/// 但用的是两个键 —— 它们是两份寿命完全不同的东西：本地库那份是待迁移的历史
/// 数据，token 这份是随时会被服务端吊销的凭证。塞进同一个键里，
/// 「清缓存重登」会把用户的本地数据一起带走。
class _HtmlSessionStore extends SessionStore {
  static const String _key = 'easy_learn_session_v1';

  String? _token;
  Map<String, dynamic>? _user;

  @override
  Future<void> initialize() async {
    final raw = webStorage.read(_key);
    if (raw == null || raw.isEmpty) return;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return;
      final token = json['token'];
      final user = json['user'];
      if (token is String && token.isNotEmpty && user is Map) {
        _token = token;
        _user = Map<String, dynamic>.from(user);
      }
    } catch (_) {
      // 落盘内容坏了就当作没登录。
      //
      // **不要在这里抛异常**：这个键可能是上一个版本写的，而用一次
      // 「解析失败」把 App 拦在启动阶段，用户能做的一切就是卸载重装。
      // 解密失败 → 当未登录 → 去登录页，是一条能自愈的路。
      await clear();
    }
  }

  @override
  String? get token => _token;

  @override
  Map<String, dynamic>? get user => _user;

  @override
  Future<void> save({required String token, required Map<String, dynamic> user}) async {
    _token = token;
    _user = Map<String, dynamic>.of(user);
    webStorage.write(_key, jsonEncode({'token': token, 'user': user}));
  }

  @override
  Future<void> clear() async {
    _token = null;
    _user = null;
    webStorage.remove(_key);
  }
}

SessionStore createPlatformSessionStore() => _HtmlSessionStore();
