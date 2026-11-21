import 'package:easy_learn_app/controllers/data_status_controller.dart';
import 'package:easy_learn_app/services/data_staleness_log.dart';
import 'package:easy_learn_app/widgets/offline_data_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 「陈旧读 / 写没保存」这条**可见性**链路的钉子。
///
/// 它补的是端到端走查扛不动的那一段：`tools/walkthrough-cloud.mjs` 里那条
/// 断网判据要在真浏览器里跑，慢、而且一失败只能看到「没有横幅」。
/// 这里把链路拆开单独验：**上报 → 控制器收到 → 界面渲染出文案**。
/// 走查负责「上报真的会在浏览器里发生」，这里负责「上报之后一定看得见」。
///
/// 背景（迁移计划 §7 方案 B）：断网时读缓存让界面不再空列表，代价是**旧数据
/// 与实时数据长得一模一样**。所以「正在显示旧数据」必须是个能被读到的信号，
/// 而不是一个只写进日志的事实。
void main() {
  setUp(() {
    Get.testMode = true;
    DataStalenessLog.clear();
  });

  tearDown(() {
    DataStalenessLog.clear();
    // `Get.reset()` 必须留着。不调的话，上一个用例注册的控制器会**留在
    // GetX 容器里**，下一个用例的 `Get.put` 就会命中已注册的键、不再新建、
    // 于是也不再 `onInit` —— 订阅没人做，事件自然到不了控制器。
    // 现象是「随便加一条断言都失败」，而它会把人引去查渲染。
    Get.reset();
  });

  /// 挂上横幅，跑完断言，再把自动隐藏的定时器跑干净。
  ///
  /// 最后那一步不是洁癖：`testWidgets` 结束时会检查「还有没有挂着的定时器」，
  /// 有就直接判失败。于是「横幅按预期显示」会因为这个 20 秒后才响的定时器
  /// 而报成失败，日志里连一句 `Expected/Actual` 都没有 —— 看起来像横幅没渲染，
  /// 实际是断言早就过了。
  Future<void> withBanner(
    WidgetTester tester,
    Future<void> Function(DataStatusController c) body, {
    Duration autoHideAfter = const Duration(seconds: 20),
    bool muteTickers = false,
  }) async {
    if (Get.isRegistered<DataStatusController>()) {
      Get.delete<DataStatusController>(force: true);
    }
    final controller =
        Get.put(DataStatusController(autoHideAfter: autoHideAfter));
    // 结构与**真实首页一字不差**：横幅是 `Column` 的孩子，下面跟一个
    // `Expanded`。这一点看着无关紧要，其实是最关键的一处 ——
    // 直接写 `Scaffold(body: OfflineDataBanner(...))` 会给出**有界**高度，
    // 而 `Column` 给非 flex 孩子的是**无界**高度。两种约束下
    // `AnimatedSize` 的行为不同，用前一种验出来的「没问题」是假的。
    Widget tree = Scaffold(
      body: Column(
        children: [
          OfflineDataBanner(status: controller),
          const Expanded(child: SizedBox.expand()),
        ],
      ),
    );
    if (muteTickers) tree = TickerMode(enabled: false, child: tree);
    await tester.pumpWidget(MaterialApp(home: tree));
    await body(controller);
    await tester.pump(autoHideAfter + const Duration(seconds: 1));
    controller.onClose();
  }

  testWidgets('横幅出现时**真的占得到高度**（0 高度等于没显示）',
      (tester) async {
    // 这一条是拿真浏览器走查换来的：断言写的是「找得到这段文字」，
    // 而当时的实际表现是 —— 文字确实建出来了、语义树里却一条都找不到、
    // 截图上那块地方是空的。原因就是容器高度停在 0：
    // 组件在树里、文字在树里，**唯独没占地方**。
    // 所以「渲染出来了」这句话必须用尺寸来钉，不能只用 `find.text`。
    await withBanner(tester, (controller) async {
      DataStalenessLog.add(const DataStaleness(
        kind: DataStalenessKind.staleRead,
        reason: '高度检查',
      ));
      await tester.pump();
      // 让 AnimatedSize 走完：它一开始是 0 高度，需要几帧才长出来。
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('正在显示上次同步的内容'), findsOneWidget);
      final size = tester.getSize(find.byType(OfflineDataBanner));
      expect(size.height, greaterThan(20),
          reason: '高度是 ${size.height} —— 组件在树里但没占地方，用户看不见');
      expect(size.width, greaterThan(100));
    });
  });

  testWidgets('**ticker 被静音时也必须看得见**（可见性不能挂在动画上）',
      (tester) async {
    // 这一条钉的是真浏览器走查里撞到的那个表现：事件到了、`Obx` 也用非空
    // 事件重建过（探针有记录），界面上却什么都没有、语义树里也找不到 ——
    // 因为横幅的高度依赖 `AnimatedSize` 把 0 长到 60，而**动画没跑**：
    // `TickerMode(enabled: false)` 下 ticker 被静音，高度就永远停在 0。
    //
    // 这个失效模式特别危险：数据是旧的要紧得很，提示却**安静地消失**了，
    // 而且不报错、不崩、日志里还有那条事件。所以「看得见」这件事必须
    // 不依赖动画 —— 动画只能是锦上添花。
    await withBanner(tester, (controller) async {
      DataStalenessLog.add(const DataStaleness(
        kind: DataStalenessKind.staleRead,
        reason: '静音环境下的可见性',
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('正在显示上次同步的内容'), findsOneWidget);
      final size = tester.getSize(find.byType(OfflineDataBanner));
      expect(size.height, greaterThan(20),
          reason: '高度 ${size.height} —— ticker 静音时横幅必须照样占地方');
    }, muteTickers: true);
  });

  testWidgets('没有事件时不显示任何东西（对照：否则下面的断言等于没验）',
      (tester) async {
    await withBanner(tester, (_) async {
      expect(find.text('正在显示上次同步的内容'), findsNothing);
      expect(find.text('这次修改没有保存'), findsNothing);
      final size = tester.getSize(find.byType(OfflineDataBanner));
      expect(size.height, 0, reason: '没有要提示的事，就不该占屏幕');
    });
  });

  testWidgets('传输层上报陈旧读 → 横幅出现', (tester) async {
    await withBanner(tester, (controller) async {
      // 走的是传输层真正用的那个入口（`DataStalenessLog.add`），
      // 而不是直接调控制器的 `report` —— 后者会把「订阅」这一环跳过，
      // 而订阅正是这条链路唯一可能悄悄断掉的地方。
      DataStalenessLog.add(const DataStaleness(
        kind: DataStalenessKind.staleRead,
        reason: '现在连不上数据服务，界面显示的是上一次同步下来的内容。',
      ));
      await tester.pump();

      // 先钉住前半段：事件有没有真的到达控制器。
      // 不钉的话，「没渲染」既可能是订阅断了，也可能是 Obx 没重建，
      // 而这两种的分头排查方向完全不同。
      expect(controller.latest.value, isNotNull,
          reason: '控制器没收到事件 —— 断在订阅，不在渲染');
      expect(find.text('正在显示上次同步的内容'), findsOneWidget);
      expect(find.textContaining('上一次同步下来的内容'), findsOneWidget,
          reason: '只给结论不给原因，用户没法判断该不该将就');
    });
  });

  testWidgets('上报发生在控制器建起来之前，也要补上', (tester) async {
    // 真实的时序恰恰是这样：`main()` 里装配传输层 → 路由决定首屏 → 读数据
    // → 首页被建起来。不补的话，横幅要等到**下一次**事件才出现，
    // 而那时用户已经在看一份旧数据了。
    DataStalenessLog.add(const DataStaleness(
      kind: DataStalenessKind.staleRead,
      reason: '发生在建控制器之前',
    ));

    await withBanner(tester, (_) async {
      await tester.pump();
      expect(find.text('正在显示上次同步的内容'), findsOneWidget);
    });
  });

  testWidgets('写没保存是**另一种**语气（警示，且给出下一步动作）', (tester) async {
    await withBanner(tester, (_) async {
      DataStalenessLog.add(const DataStaleness(
        kind: DataStalenessKind.writeDropped,
        reason: '现在连不上数据服务，这次修改没有保存到云端。',
      ));
      await tester.pump();

      expect(find.text('这次修改没有保存'), findsOneWidget);
      expect(find.text('正在显示上次同步的内容'), findsNothing,
          reason: '两件事需要的动作不同，文案不能混成一句');
      expect(find.textContaining('重新提交'), findsOneWidget,
          reason: '断网时反复点同一个按钮必然失败，必须给别的动作');
    });
  });

  testWidgets('横幅会自己消失（短窗口），但连续发生时会续期', (tester) async {
    await withBanner(tester, (_) async {
      DataStalenessLog.add(const DataStaleness(
        kind: DataStalenessKind.staleRead,
        reason: '第一条',
      ));
      await tester.pump();
      expect(find.text('正在显示上次同步的内容'), findsOneWidget);

      await tester.pump(const Duration(seconds: 21));
      expect(find.text('正在显示上次同步的内容'), findsNothing,
          reason: '偶发一次不该一直占着屏幕');

      // 持续离线时每一次读都会再报一次 —— 续期是**想要**的行为：
      // 「刚才那一下」和「一直在离线」需要的反应不同。
      DataStalenessLog.add(const DataStaleness(
        kind: DataStalenessKind.staleRead,
        reason: '第二条',
      ));
      await tester.pump();
      expect(find.textContaining('第二条'), findsOneWidget);
      expect(find.text('已 2 次'), findsOneWidget,
          reason: '只说「最近一次」会让人以为是偶发');
    }, autoHideAfter: const Duration(seconds: 20));
  });
}
