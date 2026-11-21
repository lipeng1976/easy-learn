import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'read_cache.dart';

/// 移动端 / 桌面端：文稿目录下的一个 JSON 文件。
///
/// 与 `session.json` 同目录，但**是两个文件**：寿命不同。
/// token 是服务端随时可能吊销的凭证，缓存是随时可以整体丢掉的副本 ——
/// 合成一个文件之后，「清一下缓存」会把登录态一起带走。
class _FileReadCache extends BaseReadCache {
  _FileReadCache({required super.limits});

  static const String _fileName = 'read_cache.json';

  File? _file;

  Future<File> _resolveFile() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await getApplicationDocumentsDirectory();
    final target = Directory(path.join(dir.path, 'easy_learn'));
    if (!await target.exists()) await target.create(recursive: true);
    return _file = File(path.join(target.path, _fileName));
  }

  @override
  Future<String?> readFromPlatform() async {
    final file = await _resolveFile();
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<bool> writeToPlatform(String payload) async {
    final file = await _resolveFile();
    // 先写临时文件再改名：这份文件可能有一百多 KB，
    // 写到一半被杀掉（切后台、系统回收）会留下一个**截断的 JSON**，
    // 而截断的 JSON 恰好是最难看出问题的那种坏 —— 下次启动它会被
    // 静默当成「没有缓存」，于是「缓存偶尔失效」变成一件无法复现的事。
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(payload, flush: true);
    await tmp.rename(file.path);
    return true;
  }

  @override
  Future<void> clearPlatform() async {
    final file = await _resolveFile();
    if (await file.exists()) await file.delete();
  }
}

ReadCache createPlatformReadCache({required ReadCacheLimits limits}) =>
    _FileReadCache(limits: limits);
