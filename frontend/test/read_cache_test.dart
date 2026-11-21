import 'package:easy_learn_app/services/read_cache.dart';
import 'package:flutter_test/flutter_test.dart';

/// 读缓存（迁移计划 §7 方案 B）的行为。
///
/// 这些用例全部**不碰网络**：它们验的是缓存自己的规则（TTL、世代、容量、
/// 坏数据自愈），网络那一半在 `data_api_cache_test.dart`。
///
/// 分开的理由是失败时的定位完全不同：一个是「缓存规则写错了」，
/// 一个是「缓存接进传输层的方式错了」。
void main() {
  group('基本存取', () {
    test('未命中返回 null，并记一次 miss', () async {
      final cache = _TestCache();
      expect(cache.lookup('a'), isNull);
      expect(cache.stats.misses, 1);
      expect(cache.stats.hits, 0);
    });

    test('写入后命中，内容与写入的一致', () async {
      final cache = _TestCache();
      await cache.store('a', {'items': [1, 2], 'n': 3});
      final hit = cache.lookup('a');
      expect(hit, isNotNull);
      expect(hit!.data['n'], 3);
      expect(hit.data['items'], [1, 2]);
    });

    test('存的是响应副本，调用方之后改原 map 不影响缓存', () async {
      final cache = _TestCache();
      final payload = <String, dynamic>{'n': 1, 'nested': {'deep': 1}};
      await cache.store('a', payload);

      payload['n'] = 999;
      (payload['nested'] as Map)['deep'] = 999;

      expect(cache.lookup('a')!.data['n'], 1,
          reason: '缓存必须与调用方共享的这份可变对象脱钩');
      expect((cache.lookup('a')!.data['nested'] as Map)['deep'], 1,
          reason: '浅拷贝不够 —— 嵌套的那层同样会被改到');
    });
  });

  group('新鲜度', () {
    test('TTL 内是新鲜的，之外不是', () {
      final storedAt = DateTime(2026, 9, 19, 10);
      final entry = CachedRead(
        data: const {},
        storedAt: storedAt,
        generation: 0,
      );
      expect(
        entry.isFreshAt(storedAt.add(const Duration(seconds: 9)), const Duration(seconds: 15)),
        isTrue,
      );
      expect(
        entry.isFreshAt(storedAt.add(const Duration(seconds: 16)), const Duration(seconds: 15)),
        isFalse,
      );
    });

    test('过期条目**照样返回**（断网时它是唯一能给的东西）', () async {
      final clock = _Clock(DateTime(2026, 9, 19, 10));
      final cache = _TestCache(clock: clock);
      await cache.store('a', {'n': 1});

      clock.value = clock.value.add(const Duration(minutes: 5));

      // lookup 只管「有没有」，不管「新不新」—— 新鲜度判断在传输层。
      // 让 lookup 自己丢掉过期的条目，就会把「断网时给一份旧的」这条路堵死。
      expect(cache.lookup('a'), isNotNull);
    });
  });

  group('世代与作废', () {
    test('invalidateAll 清空并推进世代', () async {
      final cache = _TestCache();
      await cache.store('a', {'n': 1});
      expect(cache.generation, 0);

      await cache.invalidateAll();

      expect(cache.lookup('a'), isNull);
      expect(cache.generation, 1,
          reason: '世代必须前进 —— 它是飞行中的后台刷新弃写回的依据');
    });

    test('新写入的条目带上当前世代', () async {
      final cache = _TestCache();
      await cache.invalidateAll(); // generation → 1
      await cache.store('a', {'n': 1});
      expect(cache.lookup('a')!.generation, 1);
    });

    test('clear 把世代也归零（它是换账号，不是一次写）', () async {
      final cache = _TestCache();
      await cache.store('a', {'n': 1});
      cache.lookup('a');
      await cache.invalidateAll();

      await cache.clear();

      expect(cache.lookup('a'), isNull);
      expect(cache.generation, 0);
      expect(cache.stats.hits, 0,
          reason: '统计也要跟着重置，否则「换了账号」之后命中率看起来还在涨');
    });
  });

  group('容量', () {
    test('超过条数上限时丢最旧的', () async {
      final clock = _Clock(DateTime(2026, 9, 19, 10));
      final cache = _TestCache(
        clock: clock,
        limits: const ReadCacheLimits(maxEntries: 2),
      );

      await cache.store('old', {'n': 1});
      clock.value = clock.value.add(const Duration(seconds: 1));
      await cache.store('mid', {'n': 2});
      clock.value = clock.value.add(const Duration(seconds: 1));
      await cache.store('new', {'n': 3});

      expect(cache.entryCount, 2);
      expect(cache.keys, isNot(contains('old')), reason: '丢的必须是最旧的');
      expect(cache.keys, containsAll(<String>['mid', 'new']));
      expect(cache.stats.evictions, greaterThan(0));
    });

    test('总字节超限也会淘汰', () async {
      final clock = _Clock(DateTime(2026, 9, 19, 10));
      final cache = _TestCache(
        clock: clock,
        limits: const ReadCacheLimits(
          maxEntries: 100,
          maxTotalBytes: 200,
          maxEntryBytes: 10 * 1024,
        ),
      );

      // 每条约 100 字节，存 3 条必然越过 200 的总上限。
      for (var i = 0; i < 3; i++) {
        clock.value = clock.value.add(const Duration(seconds: 1));
        await cache.store('k$i', {'blob': 'x' * 100});
      }

      expect(cache.entryCount, lessThan(3));
    });

    test('单条过大时静默拒收，**不抛异常**', () async {
      final cache = _TestCache(limits: const ReadCacheLimits(maxEntryBytes: 64));

      // 不能抛：调用方此刻正在返回一次**成功的读**，
      // 因为「这条太大」把它变成失败是最坏的一种连带损失。
      await cache.store('big', {'blob': 'x' * 500});

      expect(cache.lookup('big'), isNull);
      expect(cache.stats.rejected, 1);
    });
  });

  group('落盘与自愈', () {
    test('落盘后由新实例载入，内容还在', () async {
      final first = _TestCache();
      await first.store('a', {'n': 7});
      await first.flush();
      expect(first.platformPayload, isNotNull);

      final second = _TestCache();
      second.seedPayload(first.platformPayload!);
      await second.initialize();

      expect(second.lookup('a')!.data['n'], 7);
      expect(second.generation, first.generation);
    });

    test('落盘内容坏掉时当作没有缓存，**不抛**', () async {
      final cache = _TestCache();
      cache.seedPayload('{ 这不是 json');

      // 不能抛：缓存是尽力而为的东西，让它把 App 拦在启动阶段
      // 是最坏的一种交换。
      await cache.initialize();

      expect(cache.entryCount, 0);
      expect(cache.lookup('a'), isNull);
    });

    test('落盘内容里字段缺失的条目被跳过，其余照常载入', () async {
      final cache = _TestCache();
      cache.seedPayload(
        '{"generation":3,"entries":{'
        '"good":{"data":{"n":1},"storedAt":"2026-09-19T02:00:00.000Z","generation":3},'
        '"noTime":{"data":{"n":2}},'
        '"badTime":{"data":{"n":3},"storedAt":"昨天"}'
        '}}',
      );
      await cache.initialize();

      expect(cache.keys, <String>{'good'});
      expect(cache.generation, 3);
    });

    test('写盘被拒时缓存让步：丢一半再试，最终写成功', () async {
      final clock = _Clock(DateTime(2026, 9, 19, 10));
      final cache = _TestCache(clock: clock);
      for (var i = 0; i < 6; i++) {
        clock.value = clock.value.add(const Duration(seconds: 1));
        await cache.store('k$i', {'n': i});
      }
      expect(cache.entryCount, 6);

      // 第一次写入被拒（模拟 localStorage 配额满），之后放开。
      cache.failNextWrite = true;
      await cache.flush();

      expect(cache.platformPayload, isNotNull, reason: '收缩之后必须成功写出去');
      expect(cache.entryCount, lessThan(6),
          reason: '代价是丢掉一部分缓存 —— 缓存是让步的那一方');
      expect(cache.stats.evictions, greaterThan(0));
    });

    test('清空后再 flush 会把平台侧那份也删掉', () async {
      final cache = _TestCache();
      await cache.store('a', {'n': 1});
      await cache.flush();
      expect(cache.platformPayload, isNotNull);

      await cache.invalidateAll();
      await cache.flush();

      expect(cache.platformPayload, isNull,
          reason: '留着一个只剩 generation 的文件，下次启动会以为「上次有数据」');
    });
  });
}

/// 可改的时钟。构造时把 `call` 交给缓存，之后改 [value] 就能让它看到时间前进。
class _Clock {
  _Clock(this.value);

  DateTime value;

  DateTime call() => value;
}

/// 测试替身：平台侧只是一个内存字符串。
class _TestCache extends BaseReadCache {
  _TestCache({super.limits, _Clock? clock})
      : super(now: clock == null ? null : () => clock.value);

  /// 平台侧那份 payload。
  String? platformPayload;

  /// 置 true 时下一次写盘失败。用来验「写不进去时缓存让步」。
  bool failNextWrite = false;

  void seedPayload(String payload) => platformPayload = payload;

  @override
  Future<String?> readFromPlatform() async => platformPayload;

  @override
  Future<bool> writeToPlatform(String payload) async {
    if (failNextWrite) {
      failNextWrite = false;
      return false;
    }
    platformPayload = payload;
    return true;
  }

  @override
  Future<void> clearPlatform() async => platformPayload = null;
}
