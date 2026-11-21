import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'session_store.dart';

/// 移动端 / 桌面端：文稿目录下的一个小 JSON 文件。
///
/// 刻意**不用临时目录**（`Directory.systemTemp`）：系统在空间紧张或重启后会
/// 清理它，而清理的后果是用户莫名其妙被登出 —— 这类问题在演示时不会出现，
/// 只在用了一周之后出现。与作业照片落在文稿目录是同一条理由。
class _FileSessionStore extends SessionStore {
  static const String _fileName = 'session.json';

  File? _file;
  String? _token;
  Map<String, dynamic>? _user;

  Future<File> _resolveFile() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await getApplicationDocumentsDirectory();
    final target = Directory(path.join(dir.path, 'easy_learn'));
    if (!await target.exists()) await target.create(recursive: true);
    return _file = File(path.join(target.path, _fileName));
  }

  @override
  Future<void> initialize() async {
    try {
      final file = await _resolveFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final token = decoded['token'];
      final user = decoded['user'];
      if (token is String && token.isNotEmpty && user is Map) {
        _token = token;
        _user = Map<String, dynamic>.from(user);
      }
    } catch (_) {
      // 读坏了就当作没登录，理由同 Web 实现：不让一次解析失败把 App
      // 拦在启动阶段。文件留在原地不删 —— 它是排查「为什么登录态丢了」的唯一线索。
      _token = null;
      _user = null;
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
    try {
      final file = await _resolveFile();
      await file.writeAsString(jsonEncode({'token': token, 'user': user}), flush: true);
    } catch (_) {
      // 写盘失败**不影响本次会话**：token 已经在内存里，这一次登录是可用的，
      // 只是下次冷启动要重新登录。为此抛异常等于让一次登录白做。
    }
  }

  @override
  Future<void> clear() async {
    _token = null;
    _user = null;
    try {
      final file = await _resolveFile();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删不掉也没关系：内存里已经清了，下次启动看到的是过期 token，
      // 服务端会以 token_invalid 拒掉并触发一次重新登录。
    }
  }
}

SessionStore createPlatformSessionStore() => _FileSessionStore();
