import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'credential_store.dart';

/// 移动端 / 桌面端：文稿目录下两个文件（密钥 + 密文）。
///
/// ## 这个类为什么存在（2026-10-06，见 doc/open-items.md B37）
///
/// 「记住密码 / 上次使用的手机号」原本走一份叫 `webStorage` 的抽象，
/// 而它**只有 Web 有真实实现**（`window.localStorage`）；安卓/iOS 落到
/// `web_storage_stub.dart`，那份是 `read => null` / `write => true` ——
/// **写假装成功、读恒为空**。所以手机上「记住密码」勾了等于没勾，
/// 而且全程零报错。
///
/// 修法与 `SessionStore` / `ReadCache` 完全同构：补 IO 实现 + 三路条件导入
/// + 在 `main` 里 await 载入后再 `runApp`。`main.dart` 的注释里本来就写着
/// 这条规矩（异步读落盘必须在 `runApp` 之前），只是当初没用到这份凭证上。
///
/// ## 口令的存法 —— 这里是有取舍的，别当成显然
///
/// 真正的答案是 **`flutter_secure_storage`**（Android Keystore / iOS
/// Keychain），密钥在硬件里，拿到设备（甚至 root）也读不到明文。
/// 2026-10-06 装不了它：本机 pub.dev 与国内镜像都不可达，沙箱钩子还拦了
/// `pub add`（`CreateFile failed 231`）。**不能为一个依赖让你连包都构建不出来。**
///
/// 退一步用 `package:crypto` 做加密。⚠️ 先说清它**不是**什么：
///
/// - 它**不是真正的机密性** —— 密钥就在隔壁文件里，能读密文的人通常也能读到
///   密钥。它挡的是「应用私有目录被随手翻出来」（adb backup、文件管理器、
///   明文 grep），**挡不住拿到设备 root 的人**。
/// - ⚠️ `package:crypto` **只有哈希与 HMAC，没有任何分组密码**（没有 AES）。
///   所以下面是**用 HMAC-SHA256 造密钥流**（CTR 式的教科书做法），
///   而不是调一个 AES API —— 这段代码里没有 `AesCbc`，「本来想用 AES」这件事
///   只存在于这条注释里。
///
/// 能装 secure_storage 那天，**只需要换掉这个文件** —— 抽象边界就是为那一刻留的。
///
/// ## 为什么不用同一个文件存密钥和密文
///
/// 分开是为了让「换密钥」与「换数据」互不牵连：清掉密文文件就等于忘掉一切，
/// 而密钥还在，下次写入不会重新生成一把（重新生成会让别的密文一起作废）。
class _FileCredentialStore implements CredentialStore {
  static const String _fileName = 'credentials.json';
  static const String _keyFileName = 'credentials.key';

  File? _file;
  File? _keyFile;
  Map<String, String> _cache = const {};
  bool _loaded = false;
  List<int>? _keyBytes;

  /// ⚠️ **必须是 `Random.secure()`**：`Random()` 的种子取自时钟，
  /// 密钥空间就变成「猜得到的时间戳」，那等于没有加密。
  final Random _random = Random.secure();

  Future<Directory> _dir() async {
    final dir = await getApplicationDocumentsDirectory();
    // 与 `session.json` / `read_cache.json` 同一个目录：一个应用一处落盘根。
    final target = Directory(path.join(dir.path, 'easy_learn'));
    if (!await target.exists()) await target.create(recursive: true);
    return target;
  }

  Future<File> _resolveFile() async =>
      _file ??= File(path.join((await _dir()).path, _fileName));

  Future<File> _resolveKeyFile() async =>
      _keyFile ??= File(path.join((await _dir()).path, _keyFileName));

  Future<List<int>> _key() async {
    final cached = _keyBytes;
    if (cached != null) return cached;
    final file = await _resolveKeyFile();
    if (await file.exists()) {
      try {
        final bytes = base64Decode((await file.readAsString()).trim());
        if (bytes.length == 32) return _keyBytes = bytes;
      } catch (_) {
        // 密钥读坏了就重新生成一把：旧密文随之作废（解密失败会当作
        // 「没记住」），用户最多重填一次密码。**不抛** —— 一次密钥文件
        // 损坏不该让 App 起不来。
      }
    }
    final fresh = List<int>.generate(32, (_) => _random.nextInt(256));
    try {
      await file.writeAsString(base64Encode(fresh), flush: true);
    } catch (_) {
      // 写不成也认：这一进程内还能用，只是下次启动换一把新密钥。
    }
    return _keyBytes = fresh;
  }

  /// HMAC-SHA256 生成的密钥流，长度 = [length]。
  ///
  /// 第 i 块 = `HMAC-SHA256(key, nonce || i)`，i 从 0 起、大端 8 字节。
  /// 这是 CTR 模式的经典构造：同一密钥下 **nonce 绝不复用**，
  /// 因此每次加密都配一个随机 nonce 并前置到密文里。
  List<int> _keystream(List<int> key, List<int> nonce, int length) {
    final out = <int>[];
    var counter = 0;
    while (out.length < length) {
      final block = <int>[
        ...nonce,
        // 大端 64 位计数器：显式按字节写，避免 endianness 在不同实现间漂。
        (counter >> 56) & 0xff,
        (counter >> 48) & 0xff,
        (counter >> 40) & 0xff,
        (counter >> 32) & 0xff,
        (counter >> 24) & 0xff,
        (counter >> 16) & 0xff,
        (counter >> 8) & 0xff,
        counter & 0xff,
      ];
      out.addAll(Hmac(sha256, key).convert(block).bytes);
      counter++;
    }
    return out.sublist(0, length);
  }

  /// 加密 + 完整性校验。返回 base64(nonce || mac(16) || ciphertext)。
  ///
  /// **MAC 不是可选的装饰**：没有它，密文被改一个字节之后解密仍然"成功"，
  /// 只是得到一串乱码口令 —— 用户看到的是「自动填了个错的密码」，
  /// 比「没填」难查得多。
  String _seal(String plain, List<int> key) {
    final nonce = List<int>.generate(12, (_) => _random.nextInt(256));
    final body = utf8.encode(plain);
    final stream = _keystream(key, nonce, body.length);
    final cipher = [
      for (var i = 0; i < body.length; i++) body[i] ^ stream[i],
    ];
    final mac = Hmac(sha256, key).convert([...nonce, ...cipher]).bytes.sublist(0, 16);
    return base64Encode([...nonce, ...mac, ...cipher]);
  }

  /// 解密失败返回 null（**不抛**）。
  ///
  /// 失败是合法结局：换过密钥、文件被截断、密文来自另一台设备、MAC 不符。
  /// 抛出去会把「密码框没自动填」升级成「登录页打不开」。
  String? _open(String encoded, List<int> key) {
    try {
      final raw = base64Decode(encoded);
      if (raw.length <= 12 + 16) return null;
      final nonce = raw.sublist(0, 12);
      final mac = raw.sublist(12, 28);
      final cipher = raw.sublist(28);
      final expect = Hmac(sha256, key).convert([...nonce, ...cipher]).bytes.sublist(0, 16);
      // 逐字节比，别用 `==` 比 List（那是引用比较，永远 false 的经典坑）。
      for (var i = 0; i < 16; i++) {
        if (mac[i] != expect[i]) return null;
      }
      final stream = _keystream(key, nonce, cipher.length);
      final body = [
        for (var i = 0; i < cipher.length; i++) cipher[i] ^ stream[i],
      ];
      return utf8.decode(body);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> initialize() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _resolveFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      _cache = {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            '${entry.key}': '${entry.value}',
      };
    } catch (_) {
      // 读坏了当作「什么都没存」。文件**留在原地** —— 它是排查
      // 「为什么记住密码又失效了」的唯一线索（与 session_store_io 同一条理由）。
      _cache = const {};
    }
  }

  @override
  String? read(String key) => _cache[key];

  @override
  Future<String?> readSecret(String key) async {
    final raw = _cache[key];
    if (raw == null || raw.isEmpty) return null;
    return _open(raw, await _key());
  }

  @override
  Future<bool> write(String key, String value, {bool secret = false}) async {
    final stored = secret ? _seal(value, await _key()) : value;
    _cache = {..._cache, key: stored};
    return _persist();
  }

  @override
  Future<void> remove(String key) async {
    if (!_cache.containsKey(key)) return;
    _cache = {..._cache}..remove(key);
    await _persist();
  }

  Future<bool> _persist() async {
    try {
      final file = await _resolveFile();
      // 先写临时文件再改名（与 `read_cache_io` 同一条理由）：写到一半被杀掉
      // 会留下**截断的 JSON**，而它的失败形态恰好是「静默当作没有」——
      // 那正是这个 bug 一开始的样子，不该在新实现里重现一次。
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(_cache), flush: true);
      await tmp.rename(file.path);
      return true;
    } catch (_) {
      // 写盘失败**不影响本次进程**：值已经在内存里。与 session_store_io
      // 同样的取舍 —— 为一次 IO 失败让「记住密码」当场报错，
      // 比它下次启动失效更没道理。
      return false;
    }
  }
}

CredentialStore createPlatformCredentialStore() => _FileCredentialStore();
