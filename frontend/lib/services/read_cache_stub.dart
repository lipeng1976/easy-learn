import 'read_cache.dart';

/// 兜底实现：**只在内存里**。
///
/// 未知平台的缓存退化成「本次启动内有效」，这是可以接受的 ——
/// 缓存本来就不是数据通路，它丢了最坏的结果是**回到纯在线**。
/// 这与 `SessionStore` 的兜底刚好相反：那边丢的是登录态，
/// 所以那边的注释写着「走到这里应当补一个真实实现」。
class _MemoryReadCache extends BaseReadCache {
  _MemoryReadCache({super.limits});

  @override
  Future<String?> readFromPlatform() async => null;

  @override
  Future<bool> writeToPlatform(String payload) async => true;

  @override
  Future<void> clearPlatform() async {}
}

ReadCache createPlatformReadCache({required ReadCacheLimits limits}) =>
    _MemoryReadCache(limits: limits);
