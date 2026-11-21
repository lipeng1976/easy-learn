import 'dart:async';
import 'dart:convert';

import 'read_cache_stub.dart'
    if (dart.library.io) 'read_cache_io.dart'
    if (dart.library.html) 'read_cache_html.dart';

/// 一条被缓存的读响应。
///
/// 存的是**服务端 `data` 字段的原样副本**，不是反序列化后的模型对象。
/// 理由：模型会随版本变化（新增字段、改类型），而缓存里躺着的是**上一个版本
/// 写进去的东西**。存原始 JSON 的话，旧缓存被新代码读到时走的是与新响应
/// 完全相同的解析路径 —— 解析器怎么写就怎么兼容；存模型对象则需要在反序列化
/// 之后再加一层「旧版本对象」的兼容，而那一层没人会记得写。
class CachedRead {
  const CachedRead({
    required this.data,
    required this.storedAt,
    required this.generation,
  });

  final Map<String, dynamic> data;
  final DateTime storedAt;

  /// 写入时缓存所处的世代。见 [ReadCache.generation]。
  final int generation;

  bool isFreshAt(DateTime now, Duration ttl) =>
      now.difference(storedAt) < ttl;
}

/// 读缓存（迁移计划 §7 方案 B：读缓存优先，写必须在线）。
///
/// ## 它解决的是哪一个具体问题
///
/// 纯在线（方案 A）在断网时的表现不是「慢」，而是**空**：控制器里的读失败
/// 被 `catch (_)` 吞掉，列表停在空状态，用户看到的是
/// **「我昨天做的作业全没了」**。这个误解没有任何办法事后纠正 ——
/// 它发生在用户已经相信了那个数字之后。
///
/// 所以这里的首要职责是**断网时仍能给出上一次看到的数据**，
/// 其次才是省一次往返。
///
/// ## 为什么 lookup 是同步的
///
/// 缓存的**真相在内存里**，落盘只是持久化。如果 [lookup] 每次去读文件，
/// 那么「命中缓存」这条路径自己要付一次磁盘 I/O —— 它比一次本机 HTTP 往返
/// 便宜不了多少，于是整个缓存只剩下「断网可用」这一个好处，
/// 「快」这个好处在实现里被自己吃掉了。
///
/// ## 世代（[generation]）挡的是什么
///
/// 挡的是**飞行中的读把写之后的状态覆盖回写前**。具体时序：
///
/// ```text
/// t0  读命中过期缓存 → 返回旧数据，同时后台发起刷新 R
/// t1  用户写操作 W 成功 → 缓存被整体作废
/// t2  R 才返回（内容是 W 之前的旧数据）→ 若照写不误，缓存里就躺着写前的数据
/// t3  下一次读命中 t2 写进去的旧数据 → 用户看到自己刚改的东西没变
/// ```
///
/// 这是一类**只有在慢网络下才会出现**的 bug：本机演示永远复现不了
/// （t0→t2 只有几毫秒，W 插不进去）。所以它不能靠手测发现，只能靠一个
/// 不变量挡住 —— 于是 [store] 之前必须比对世代，不等就丢弃。
abstract class ReadCache {
  /// 读一次落盘内容到内存。Web 上是空操作。
  Future<void> initialize();

  /// 当前世代。每次写操作成功后 +1。
  int get generation;

  /// 取缓存。**同步** —— 见类注释「为什么 lookup 是同步的」。
  ///
  /// 未命中返回 `null`。过期的条目**照样返回**（由调用方决定怎么用：
  /// 是「先给出去再后台刷新」还是「丢掉」），因为过期不等于没用 ——
  /// 断网时它就是唯一能给出的东西。
  CachedRead? lookup(String key);

  /// 调用方在使用 [lookup] 的结果时登记一下判定结果。
  ///
  /// 「命中且新鲜」与「命中但过期」在排查时是两件完全不同的事
  /// （前者说明 TTL 挡得住重复读，后者说明每次读都多付一次后台刷新），
  /// 所以它们在统计里分开记。
  void noteFresh();

  /// 见 [noteFresh]。
  void noteStale();

  /// 写入。`data` 过大时**静默不缓存**（缓存是尽力而为，不是数据通路）。
  Future<void> store(String key, Map<String, dynamic> data);

  /// 写操作成功后调用：**整体作废**并推进世代。
  ///
  /// 为什么是整体而不是按表精确失效：服务端一次写可能波及不止一张表的读缓存
  /// （发一条家长点评，学生首页的点评列表和未读数都变了），而把「哪次写影响
  /// 哪些读」逐条维护一遍，是一张**会随功能增长而失准的对照表**。
  /// 失效得干净比失效得省事重要 —— 留一条旧数据的代价是用户看到错的分数。
  Future<void> invalidateAll();

  /// 全部清掉（登出、切账号时用）。
  Future<void> clear();

  /// 把内存状态立刻落盘。平时由内部延迟合并，退出前才需要显式调。
  Future<void> flush();

  /// 命中率统计，只用于排查「怎么一直是旧的」这类问题。
  ReadCacheStats get stats;
}

/// 缓存命中情况。刻意不进界面 —— 它是排查用的，不是指标。
class ReadCacheStats {
  const ReadCacheStats({
    this.hits = 0,
    this.misses = 0,
    this.stale = 0,
    this.evictions = 0,
    this.rejected = 0,
  });

  /// 命中且新鲜。
  final int hits;

  /// 未命中（没有这一条）。
  final int misses;

  /// 命中但已过期 / 或作为离线降级给出。
  final int stale;

  /// 因容量上限被淘汰的条目数。
  final int evictions;

  /// 因单条过大而未缓存的次数。持续增长说明某个端点不该走缓存
  /// （典型是带 base64 图片的响应）。
  final int rejected;

  ReadCacheStats copyWith({
    int? hits,
    int? misses,
    int? stale,
    int? evictions,
    int? rejected,
  }) =>
      ReadCacheStats(
        hits: hits ?? this.hits,
        misses: misses ?? this.misses,
        stale: stale ?? this.stale,
        evictions: evictions ?? this.evictions,
        rejected: rejected ?? this.rejected,
      );

  @override
  String toString() =>
      '命中 $hits / 未命中 $misses / 陈旧 $stale / 淘汰 $evictions / 过大拒收 $rejected';
}

/// 容量上限。**必须有**，否则 Web 上会写爆 localStorage。
///
/// 三个上限一起用，因为它们挡的不是同一种东西：
/// - [maxEntryBytes] 挡「一条响应就撑爆配额」—— 带图片 base64 的读最容易触发；
/// - [maxEntries] 挡「几百个小端点慢慢堆积」；
/// - [maxTotalBytes] 挡「每条都不大但乘起来超了」，这才是真正逼近
///   localStorage 5MB 上限的那条路径。
class ReadCacheLimits {
  const ReadCacheLimits({
    this.maxEntryBytes = 128 * 1024,
    this.maxEntries = 24,
    this.maxTotalBytes = 1024 * 1024,
  });

  final int maxEntryBytes;
  final int maxEntries;
  final int maxTotalBytes;
}

/// 缓存条目的内部表示（带字节数，省得每次淘汰都重新序列化量一遍）。
class ReadCacheEntry {
  ReadCacheEntry({
    required this.data,
    required this.storedAt,
    required this.generation,
    required this.bytes,
  });

  final Map<String, dynamic> data;
  final DateTime storedAt;
  final int generation;
  final int bytes;

  CachedRead toCached() => CachedRead(
        data: data,
        storedAt: storedAt,
        generation: generation,
      );
}

/// 内存 + 落盘的通用实现。两处平台实现共同继承它。
///
/// 把逻辑放在这一层，是为了让「TTL 之外的失效规则」**只有一份**。
/// 两个平台各写一遍的话，它们迟早会在某条规则上分叉 —— 而分叉的表现是
/// 「同一个账号在手机上看到的是新的、在浏览器里看到的是旧的」。
abstract class BaseReadCache extends ReadCache {
  BaseReadCache({this.limits = const ReadCacheLimits(), DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final ReadCacheLimits limits;
  final DateTime Function() _now;

  final Map<String, ReadCacheEntry> _entries = <String, ReadCacheEntry>{};
  int _generation = 0;
  ReadCacheStats _stats = const ReadCacheStats();

  /// 延迟落盘：一次读会触发一次 [store]，而读是高频的。
  /// 每次 store 都全量序列化写盘，等于给每次读都加一次磁盘写。
  Timer? _flushTimer;
  bool _dirty = false;

  /// 落盘。平台侧只需实现「写一段文本」，序列化与合并由这里统一做。
  ///
  /// **返回是否真的写成功**。这个返回值不是形式：Web 上 localStorage 配额
  /// 满了以后写入会失败，而失败的那份 payload 会把用户自己的本地库数据
  /// 挤在门外 —— 缓存必须能知道「我该让步了」。
  Future<bool> writeToPlatform(String payload);

  /// 从平台侧读回。没有内容时返回 null。
  Future<String?> readFromPlatform();

  /// 平台侧清空。
  Future<void> clearPlatform();

  @override
  int get generation => _generation;

  @override
  ReadCacheStats get stats => _stats;

  @override
  Future<void> initialize() async {
    try {
      final raw = await readFromPlatform();
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final generation = decoded['generation'];
      if (generation is int) _generation = generation;
      final entries = decoded['entries'];
      if (entries is! Map) return;
      entries.forEach((key, value) {
        if (key is! String || value is! Map) return;
        final data = value['data'];
        final storedAt = value['storedAt'];
        if (data is! Map || storedAt is! String) return;
        final time = DateTime.tryParse(storedAt);
        if (time == null) return;
        final map = Map<String, dynamic>.from(data);
        _entries[key] = ReadCacheEntry(
          data: map,
          storedAt: time,
          generation: value['generation'] is int ? value['generation'] as int : _generation,
          bytes: _byteLength(map),
        );
      });
      _trim();
    } catch (_) {
      // 读坏了就当作没有缓存，**不要抛**：缓存是尽力而为的东西，
      // 让它把 App 拦在启动阶段是最坏的一种交换。
      // 与 SessionStore 不同的是这里连文件都不用删 —— 下一次 store 会覆盖它。
      _entries.clear();
    }
  }

  @override
  CachedRead? lookup(String key) {
    final entry = _entries[key];
    if (entry == null) {
      _stats = _stats.copyWith(misses: _stats.misses + 1);
      return null;
    }
    return entry.toCached();
  }

  @override
  void noteFresh() => _stats = _stats.copyWith(hits: _stats.hits + 1);

  @override
  void noteStale() => _stats = _stats.copyWith(stale: _stats.stale + 1);

  @override
  Future<void> store(String key, Map<String, dynamic> data) async {
    // 序列化**一次**，同时拿到三样东西：能不能编（编不出来就不缓存）、
    // 多大（决定收不收）、以及一份**深拷贝**。
    //
    // 深拷贝这一步不能省：`data` 是调用方手里的那个对象，紧接着就要被反序列化
    // 成模型、交给界面。共享同一个 map 的后果是「界面上改了它，缓存里也变了」——
    // 于是缓存开始积累本不该存在的状态，而它的表现是
    // 「这次读到的数据和上次读到的居然一样」，且只在特定操作序列后出现。
    final String encoded;
    try {
      encoded = jsonEncode(data);
    } catch (_) {
      // 编不出来（含不可序列化的值）—— 当它超限，直接不缓存。
      _stats = _stats.copyWith(rejected: _stats.rejected + 1);
      return;
    }

    final bytes = utf8.encode(encoded).length;
    if (bytes > limits.maxEntryBytes) {
      // 静默拒收。**不抛异常**：调用方（传输层）正在返回一次成功的读，
      // 不能因为「这条太大」把一次正常的读变成失败。
      _stats = _stats.copyWith(rejected: _stats.rejected + 1);
      return;
    }

    final copy = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
    _entries[key] = ReadCacheEntry(
      data: copy,
      storedAt: _now(),
      generation: _generation,
      bytes: bytes,
    );
    _trim();
    _scheduleFlush();
  }

  @override
  Future<void> invalidateAll() async {
    _generation += 1;
    _entries.clear();
    _scheduleFlush();
  }

  @override
  Future<void> clear() async {
    _entries.clear();
    _generation = 0;
    _stats = const ReadCacheStats();
    _flushTimer?.cancel();
    _flushTimer = null;
    _dirty = false;
    try {
      await clearPlatform();
    } catch (_) {
      // 平台侧删不掉时内存已经清了。留着的那份是过期数据，
      // 但它的世代与当前不符 —— 下次 store 会整体覆盖。
    }
  }

  @override
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (!_dirty) return;
    if (_entries.isEmpty) {
      // 空缓存不必留下一个有 generation 的文件：它除了让下次启动多读一次
      // 之外没有作用。但平台侧那份**要删掉**，否则它说的是「上次有数据」。
      _dirty = false;
      try {
        await clearPlatform();
      } catch (_) {}
      return;
    }
    _dirty = false;
    try {
      if (await writeToPlatform(jsonEncode(_snapshot()))) return;
    } catch (_) {
      // 落盘失败只影响「下次启动还能不能读到」，不影响本次运行。
    }
    // 第一次没写进去：**缓存让步**。丢掉一半最旧的再试一次 ——
    // 这是 Web 配额满时的自救，也是磁盘紧张时的合理反应。
    // 再失败就放弃，把 `_dirty` 置回让下一次 store 再试，不在这里死循环。
    evictOldest(_entries.length ~/ 2 + 1);
    _dirty = true;
    if (_entries.isEmpty) return;
    try {
      if (await writeToPlatform(jsonEncode(_snapshot()))) _dirty = false;
    } catch (_) {}
  }

  Future<void> _scheduleFlush() async {
    _dirty = true;
    if (_flushTimer != null) return;
    _flushTimer = Timer(const Duration(milliseconds: 200), () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  Map<String, Object?> _snapshot() => <String, Object?>{
        'generation': _generation,
        'entries': <String, Object?>{
          for (final e in _entries.entries)
            e.key: <String, Object?>{
              'data': e.value.data,
              'storedAt': e.value.storedAt.toUtc().toIso8601String(),
              'generation': e.value.generation,
            },
        },
      };

  /// 按「条数 + 总字节」两个上限淘汰，丢最旧的。
  void _trim() {
    while (_entries.length > limits.maxEntries ||
        _totalBytes() > limits.maxTotalBytes) {
      if (_entries.isEmpty) return;
      final oldest = _entries.entries.reduce(
        (a, b) => a.value.storedAt.isBefore(b.value.storedAt) ? a : b,
      );
      _entries.remove(oldest.key);
      _stats = _stats.copyWith(evictions: _stats.evictions + 1);
    }
  }

  int _totalBytes() =>
      _entries.values.fold(0, (sum, e) => sum + e.bytes);

  static int _byteLength(Map<String, dynamic> data) {
    try {
      return utf8.encode(jsonEncode(data)).length;
    } catch (_) {
      // 编不出来（比如含不可序列化的值）就当它超限，直接不缓存。
      return 1 << 30;
    }
  }

  /// 丢掉最旧的 [count] 条。供平台侧在**写盘被拒**时收缩用 ——
  /// Web 上 localStorage 配额满了以后，浏览器只会让写入失败，
  /// 而失败的那份 payload 会把**用户自己的本地库数据**挤在门外。
  /// 所以这里的处置是「缓存让步」：它本来就是可以丢的东西。
  void evictOldest(int count) {
    final sorted = _entries.entries.toList()
      ..sort((a, b) => a.value.storedAt.compareTo(b.value.storedAt));
    for (var i = 0; i < count && i < sorted.length; i++) {
      _entries.remove(sorted[i].key);
      _stats = _stats.copyWith(evictions: _stats.evictions + 1);
    }
  }

  /// 测试与排查用。
  int get entryCount => _entries.length;
  Set<String> get keys => _entries.keys.toSet();
}

/// 按平台建一个。默认是**关**的 —— 没配数据服务就没有云端读，也就没有缓存。
ReadCache createReadCache({ReadCacheLimits? limits}) =>
    createPlatformReadCache(limits: limits ?? const ReadCacheLimits());
