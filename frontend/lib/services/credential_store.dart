import 'credential_store_stub.dart'
    if (dart.library.io) 'credential_store_io.dart'
    if (dart.library.html) 'credential_store_html.dart';

/// 「上次登录的手机号 / 记住的密码」这类**登录页凭证**的落地处。
///
/// ## 为什么必须是一个独立的抽象（2026-10-06，见 doc/open-items.md B37）
///
/// 它原先复用的是 `webStorage` —— 那份抽象**只有 Web 有真实实现**。
/// 安卓/iOS 落到 `web_storage_stub.dart`，而那份的 `read` 恒 `null`、
/// `write` 返回 `true`：**写假装成功、读恒为空**。于是手机上
/// 「记住密码 / 上次使用：…」永远是空的，且**全程零报错**
/// （用户只会说「好像经常没什么作用」）。
///
/// 教训：`webStorage` 这个名字本身就写着「Web」。
/// 一个只在 Web 成立的实现，被当成跨平台接口用了第三次才被发现。
///
/// ## 凭证 ≠ 业务数据
///
/// 它要在「客户端数据库还没打开」的时候就能读（登录页首帧要填手机号），
/// 也不能因为一次库迁移失败跟着丢。所以独立落盘，不进 `easy_learn.db`。
///
/// ## 同步 API 是刻意的
///
/// [read] 是同步的 —— 登录页在 `initState` 里要立刻拿到手机号，
/// 那里没有 await 的位置（填晚一帧会看到输入框先空后闪）。
/// 代价是**必须先 [initialize]**：异步的磁盘/存储读取只在那里发生，
/// `read` 之后只读内存。`main` 会在 `runApp` 之前 await 它，
/// 与 `CloudRuntime.initialize` 是同一条规矩（见 `main.dart` 的注释）。
abstract class CredentialStore {
  /// 把落盘的凭证读进内存。**必须在使用 [read] 之前 await 完成**。
  Future<void> initialize();

  /// 读一个**明文**键（手机号、角色这类本身不敏感的东西）。
  String? read(String key);

  /// 读一个**密文**键（口令）。
  ///
  /// 拆成独立方法而不是给 [read] 加参数：调用方必须显式说出「这个键是密文」，
  /// 否则用错了读法**不会报错**，只会得到一串 base64 当作口令填进去。
  /// 解密失败返回 `null`（换过密钥/文件损坏/来自另一台设备都算）。
  Future<String?> readSecret(String key);

  /// 写入。`secret: true` 时调用方要求**加密落盘**。
  ///
  /// 返回是否写盘成功。失败是可能发生的（存储满、权限），
  /// 但**不当成异常** —— 调用方关心的是「这次进程内能不能用」。
  Future<bool> write(String key, String value, {bool secret = false});

  /// 删掉一个键。
  ///
  /// ⚠️ **是异步的，调用方必须 await**：移动端要落盘。
  /// 若立刻跨实例去读（「remove 之后读不到」那条判据就是这么写的），
  /// 不 await 就会读到**还没删掉的旧值** —— 那条判据会偶发地红，
  /// 而红的原因是竞态而不是功能坏了。声明成 `void` 等于对调用方撒谎。
  Future<void> remove(String key);
}

/// 新建一份独立的凭证 store。
///
/// 与 `session_store.dart` 的 `createSessionStore()` 同一个范式：各平台文件里的
/// `createPlatformCredentialStore` 是**实现细节**，不对外暴露，调用方只认这个名字。
///
/// 测试必须用它而不是上面那个单例：同一个实例有内存缓存，于是
/// 「写进去读得回来」在**恒空的 stub 上也会通过**（`write` 返回 true、值进内存）。
/// 只有每次新建、跨实例读，才逼得出一条真落盘的判据。
CredentialStore createCredentialStore() => createPlatformCredentialStore();

/// 全应用一份。与 `webStorage` 同样的用法，但**在移动端是真的**。
final CredentialStore credentialStore = createCredentialStore();

/// 登录页凭证的键。集中在这里，避免字符串散落导致「写进 A 读的是 B」。
///
/// ⚠️ **键名与旧的 `webStorage` 版本逐字一致，是刻意保留的**：
/// Web 上老用户已经用这两个键存过东西（明文），改名等于把他们的
/// 「上次登录 / 记住的密码」全部作废。移动端那边从来没有写进去过
/// （stub 的 `write` 只返回 true、不落盘），所以不受影响。
class CredentialKeys {
  const CredentialKeys._();

  /// 上次登录：`{phone, role, method}` 的 JSON。**明文**。
  static const String lastLogin = 'easy_learn_last_login_v1';

  /// 勾了「记住密码」时的口令。
  ///
  /// - 移动端（`credential_store_io.dart`）：**密文**（HMAC-SHA256 密钥流）。
  /// - Web（`credential_store_html.dart`）：**明文**，见那份实现里的取舍说明
  ///   （浏览器本来就是明文，改了会让老用户的密码读不出来）。
  static const String password = 'easy_learn_remember_v1';
}
