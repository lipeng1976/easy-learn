import 'session_store.dart';

/// 兜底实现：**只在内存里**。
///
/// 它存在的意义是让「未知平台」也能编译 —— 而不是让某个平台悄悄退化成
/// 每次启动都要重新登录。目前 Web 与 IO 都有真实实现，走到这里说明
/// 出现了第三种编译目标（比如 WASM），那时应当**补一个真实实现**，
/// 而不是让用户去猜为什么登录态留不住。
class _MemorySessionStore extends SessionStore {
  String? _token;
  Map<String, dynamic>? _user;

  @override
  Future<void> initialize() async {}

  @override
  String? get token => _token;

  @override
  Map<String, dynamic>? get user => _user;

  @override
  Future<void> save({required String token, required Map<String, dynamic> user}) async {
    _token = token;
    _user = Map<String, dynamic>.of(user);
  }

  @override
  Future<void> clear() async {
    _token = null;
    _user = null;
  }
}

SessionStore createPlatformSessionStore() => _MemorySessionStore();
