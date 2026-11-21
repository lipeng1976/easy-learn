import 'read_cache.dart';
import 'web_storage.dart';

/// Web：浏览器 localStorage。
///
/// 与本地库那份数据（`easy_learn_web_store_v5`）、会话（`easy_learn_session_v1`）
/// 各用各的键。三个键三份寿命：本地库是待迁移的历史数据，会话是随时会被吊销的
/// 凭证，**缓存是随时可以整体丢掉的副本** —— 混在一起的话，
/// 「清一下缓存」会顺手把用户的本地数据带走。
///
/// 配额是这里唯一需要真正处理的事：localStorage 通常只有 5MB，而这份 App
/// 在 Web 上**同时**还存着本地库与作业照片的 base64。写不进去时缓存必须
/// 自己让步（见 `ReadCache.flush` 的收缩重试），绝不能把用户的数据挤掉。
class _HtmlReadCache extends BaseReadCache {
  _HtmlReadCache({required super.limits});

  static const String _key = 'easy_learn_read_cache_v1';

  @override
  Future<String?> readFromPlatform() async => webStorage.read(_key);

  @override
  Future<bool> writeToPlatform(String payload) async =>
      webStorage.write(_key, payload);

  @override
  Future<void> clearPlatform() async => webStorage.remove(_key);
}

ReadCache createPlatformReadCache({required ReadCacheLimits limits}) =>
    _HtmlReadCache(limits: limits);
