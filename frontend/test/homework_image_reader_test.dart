import 'package:flutter_test/flutter_test.dart';

import 'package:easy_learn_app/models/homework_image_model.dart';
import 'package:easy_learn_app/widgets/homework_image_viewer.dart';

/// 「家长端缩略图一直转圈」的回归判据。
///
/// ## 故障的形状
///
/// 字节其实早就到了（网络面板里那次请求 12ms 就 200），界面却一直在转圈。
/// 而同一个方法在**点开全屏**的那棵树上是好的 —— 于是根因不在「读」，
/// 而在**交出去的那个 Future 本身**。原版这里有**两个独立的坑**：
///
/// ⛔ **主因：自等待死锁。**
/// ```dart
/// final wrapped = base.whenComplete(() => _inflight.remove(key));
/// _inflight[key] = wrapped;   // ← remove 取出来的正是它自己
/// ```
/// `whenComplete` 会 **await 回调返回的 Future**，而 `remove` 返回的就是
/// `wrapped` 本身 → 这个 Future 在等自己完成 → **永不完成**。
/// `FutureBuilder` 于是永远停在 `waiting`，那就是那个转不完的圈。
///
/// **为什么全屏是好的**：`_remember` 在死锁之前就已把字节写进 `_cache`，
/// 全屏那次 `load` 命中的是缓存分支，跟死掉的那个实例毫无关系。
///
/// ⚠️ **次因：交出去的 Future 不是同一个实例。**
/// `FutureBuilder.didUpdateWidget` 比较 `oldWidget.future != widget.future`，
/// 不相等就**把快照重置回 waiting** —— 而 `Future.value(bytes)` 每次都是新实例。
/// 只管死锁、不管实例的话，详情页那层 `Obx` 一开始重建，圈就转回来了。
///
/// 所以这里钉的不变量是**实例**（以及「它真的会完成」），
/// 而不是「能不能读到字节」—— 后者从头到尾都是好的，测它等于没测。
void main() {
  final image = HomeworkImageModel(
    id: '11111111-2222-3333-4444-555555555555',
    studentId: '36e392cd-2d4c-408f-8aef-5672a35cefd4',
    homeworkId: '3b05d1d9-2eb4-40be-bc96-daa5c69dfae9',
    storageKey: '20260920/36e392cd-2d4c-408f-8aef-5672a35cefd4/7d06013f-ca5d-42b5-ae59-3b7e8df1c3b8.jpg',
    fileName: 'scaled_w4.jpg',
    fileSize: 268270,
    mimeType: 'image/jpeg',
    ocrStatus: 'pending',
    ocrText: '',
    createdAt: DateTime(2026, 9, 20, 23, 54),
  );

  setUp(() => HomeworkImageReader.resetForTest());

  test('load 返回的 Future 必须真的会结束（不能自己等自己）', () {
    // 这一条直接钉主因。原版靠 `whenComplete(() => _inflight.remove(key))`
    // 包装，那个 Future 会 await 到它自己 —— 不设超时的话，这条用例
    // 会以「整个测试超时」的形式挂掉，看不出是谁卡住了。
    return HomeworkImageReader.load(image).timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail('load 返回的 Future 在 2 秒内没有完成：'
          '它很可能在内部等自己（whenComplete 的回调返回了 _inflight.remove() 的结果）'),
    );
  });

  test('同一个 key 连调两次拿到的是同一个 Future 实例（还在飞）', () {
    final a = HomeworkImageReader.load(image);
    final b = HomeworkImageReader.load(image);
    expect(identical(a, b), isTrue,
        reason: '两次 load 不是同一个实例 → FutureBuilder 会被判为「换了 future」而重置回 waiting');
    // 收尾，别把未完成的 future 留给下一个用例。
    return a;
  });

  test('**结束之后**再 load 仍然是同一个实例（这条是修复的核心）', () async {
    final first = HomeworkImageReader.load(image);
    await first;

    final again = HomeworkImageReader.load(image);
    expect(identical(again, first), isTrue,
        reason: '结束之后每次返回的都是新的 Future.value() → 每次重建都重置回 loading，'
            '界面就是「一直转圈」而字节早已到手');
  });

  test('父级反复重建（连续 load 50 次）实例始终不变', () async {
    final first = HomeworkImageReader.load(image);
    await first;

    final seen = <Future<Object?>>{first};
    for (var i = 0; i < 50; i++) {
      final f = HomeworkImageReader.load(image);
      expect(identical(f, first), isTrue, reason: '第 $i 次重建时实例变了');
      seen.add(f);
    }
    expect(seen.length, 1, reason: '50 次重建应该只看到一个 Future 实例');
  });

  test('键为空时也返回同一个实例（不构造新的已完成 Future）', () {
    final blank = image.copyWith(storageKey: '');
    final a = HomeworkImageReader.load(blank);
    final b = HomeworkImageReader.load(blank);
    expect(identical(a, b), isTrue, reason: '空键那一支同样会让 FutureBuilder 每次重置');
    return a;
  });

  test('失败不会被永久固定：过了 30 秒窗口才允许重试', () async {
    var now = DateTime(2026, 9, 20, 23, 55);
    HomeworkImageReader.resetForTest(now: () => now);

    final first = HomeworkImageReader.load(image);
    await first; // 测试环境没有数据服务，必然是「拿不到」

    final withinWindow = HomeworkImageReader.load(image);
    expect(identical(withinWindow, first), isTrue,
        reason: '窗口内必须复用 —— 不固定的话每次重建都会重新发一次请求');

    now = now.add(HomeworkImageReader.retryAfterFailure + const Duration(seconds: 1));
    final afterWindow = HomeworkImageReader.load(image);
    expect(identical(afterWindow, first), isFalse,
        reason: '窗口外要放行重试 —— 一起网络抖动不该让这张图在本次运行里永远不可用');
    await afterWindow;
  });

  test('不同 key 之间互不干扰', () async {
    final other = image.copyWith(
      id: '99999999-8888-7777-6666-555555555555',
      storageKey: '20260920/36e392cd-2d4c-408f-8aef-5672a35cefd4/other.jpg',
    );
    final a = HomeworkImageReader.load(image);
    final b = HomeworkImageReader.load(other);
    expect(identical(a, b), isFalse);
    await Future.wait([a, b]);
    expect(identical(HomeworkImageReader.load(image), a), isTrue);
    expect(identical(HomeworkImageReader.load(other), b), isTrue);
  });
}
