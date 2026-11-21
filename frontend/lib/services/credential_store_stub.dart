import 'credential_store.dart';

/// 兜底实现：**只在内存里**。
///
/// ⚠️ 它存在的意义是让「未知平台」也能编译 —— **不是**让安卓/iOS 悄悄退化成
/// 「记住密码永远不生效，但看起来保存成功了」。
///
/// 这正是 B37 的成因（2026-10-06）：那份 `web_storage_stub.dart` 返回
/// `write => true`，于是失败是**无声的**。所以这里的 `write` 明确返回
/// `false` —— 至少「存不下」是一个可观察的事实，而不是一句谎话。
///
/// 目前 Web 与 IO 都有真实实现（`credential_store_html.dart` /
/// `credential_store_io.dart`）。走到这里说明出现了第三种编译目标
/// （比如 WASM），那时应当**补一个真实实现**，而不是让用户去猜
/// 为什么手机号记不住。
class _MemoryCredentialStore implements CredentialStore {
  final Map<String, String> _memory = {};

  @override
  Future<void> initialize() async {}

  @override
  String? read(String key) => _memory[key];

  @override
  Future<String?> readSecret(String key) async => _memory[key];

  @override
  Future<bool> write(String key, String value, {bool secret = false}) async {
    _memory[key] = value;
    // 明确 false：本次进程内能读到，但它**没有落盘**。
    // 返回 true 会复刻 B37 那个「成功得很安静」的形态。
    return false;
  }

  @override
  Future<void> remove(String key) async {
    _memory.remove(key);
  }
}

CredentialStore createPlatformCredentialStore() => _MemoryCredentialStore();
