import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/controllers/point_controller.dart';
import 'package:easy_learn_app/models/point_model.dart';
import 'package:easy_learn_app/models/wish_model.dart';
import 'package:easy_learn_app/pages/parent/tabs/wishes_parent_tab.dart';
import 'package:easy_learn_app/repositories/point_repository.dart';
import 'package:easy_learn_app/repositories/wish_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 家长端「心愿 →设置积分」弹窗。
///
/// 用户报的形态是：**改或没改、点取消或点保存，都报错**。
/// 「两个按钮都出错」这个共性是判据的入口 —— 两条路径在界面上唯一的共同
/// 步骤就是「关掉这个弹窗」，所以问题几乎不可能在保存的业务逻辑里。
///
/// 这一组刻意**不连数据库**（控制器数据源全部换成桩）：被测的是弹窗自身的
/// 生命周期，而真库那串串行查询在 `testWidgets` 的假时钟里会留下
/// 未完成的定时器，失败形态是一句和本 bug 毫无关系的「数据库已关闭」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  tearDown(Get.reset);

  WishModel wish({int pointCost = 10}) => WishModel(
    id: 'w_1',
    title: '周末去动物园',
    description: '想去看看长颈鹿',
    isPublic: true,
    parentConfirmed: true,
    studentConfirmed: true,
    isArchived: false,
    pointCost: pointCost,
  );

  /// 只实现被这一组用到的那个写方法，其余显式抛错 ——
  /// 返回空值的话，「页面开始调别的方法了」会安静地变成一次空操作。
  ({
    Future<void> Function(WidgetTester tester) open,
    _StubWishRepo repo,
  })
  openTab({int pointCost = 10}) {
    final repo = _StubWishRepo();
    Future<void> open(WidgetTester tester) async {
      Get.put(PointController(repository: _StubPointRepo()), permanent: true);
      // 泛型要显式写出来：`Get.put` 是按**泛型参数**登记实例的，
      // 让它推断成子类名的话，页面那句 `Get.find<ParentController>()` 找不到。
      final parent = Get.put<ParentController>(
        _NoLoadParentController(wishes: repo)..wishes.value = [
          wish(pointCost: pointCost),
        ],
      );
      expect(
        identical(Get.find<ParentController>(), parent),
        isTrue,
        reason: '页面必须用注入进来的那一份',
      );

      await tester.pumpWidget(
        GetMaterialApp(home: Scaffold(body: const WishesParentTab())),
      );
      await tester.pump();
    }

    return (open: open, repo: repo);
  }

  Finder costButton() => find.widgetWithText(TextButton, '设置积分');

  /// 收尾：把「已设置」那条提示条关掉。
  ///
  /// 保存成功会弹一条 snackbar，它自带 3 秒自动消失定时器。不理会它有两个后果：
  /// 用例结束时框架补一句「A Timer is still pending」；而且 **GetX 的 snackbar
  /// 队列是全局静态的，`Get.reset()` 清不掉**，那条提示条会残留到下一个用例 ——
  /// 之后任何 `Get.back()` 都会先去关它（见 `GetNavigation.back`），
  /// 下一个用例就会莫名其妙地失败。
  ///
  /// 这里不用 `pump(Duration(seconds: 4))` 把时间跳过去：那样会让退场动画的
  /// ticker 在异常的时间点被驱动，框架会报 `elapsedInSeconds >= 0.0` 断言。
  /// 直接关掉再 settle，干净且确定。
  Future<void> dismissSnackbar(WidgetTester tester) async {
    Get.closeAllSnackbars();
    await tester.pumpAndSettle();
  }

  testWidgets('取消：关掉弹窗，不写库、不报错', (tester) async {
    final harness = openTab();
    final repo = harness.repo;
    await harness.open(tester);

    await tester.tap(costButton());
    await tester.pumpAndSettle();
    expect(find.text('设置兑换积分'), findsOneWidget, reason: '前置：弹窗确实开了');

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(find.text('设置兑换积分'), findsNothing, reason: '弹窗该关掉了');
    expect(repo.writes, isEmpty, reason: '取消不该写库');
    // 这一句是本次 bug 的核心判据：取消路径上没有业务逻辑，
    // 唯一可能出错的就是弹窗自己关掉的过程。
    expect(
      tester.takeException(),
      isNull,
      reason: '关弹窗的过程中抛了异常 —— 用户看到的就是「点取消也报错」',
    );
  });

  testWidgets('上一次操作留下的提示条还开着时，取消依然要能关掉弹窗', (tester) async {
    final harness = openTab();
    final repo = harness.repo;
    await harness.open(tester);

    // 真实场景：家长刚给上一个心愿定完价，屏幕上那条「已设置」还没消失
    // （它要挂 3 秒），这时他点开下一个心愿的定价弹窗。
    Get.snackbar('已设置', '兑现需要 35 积分');
    await tester.pump();
    await tester.pump();
    // 前置断言不能省：提示条没真的出现的话，这条用例就什么都没验到。
    expect(find.text('已设置'), findsOneWidget, reason: '前置：提示条确实在屏幕上');

    await tester.tap(costButton());
    await tester.pumpAndSettle();
    expect(find.text('设置兑换积分'), findsOneWidget, reason: '前置：弹窗确实开了');

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    // **GetX 的 `Get.back()` 有个兼容性 hack**（`GetNavigation.back`）：
    // 只要当前有 snackbar 还活着，它会去关那条 snackbar 然后 `return`，
    // 根本不 pop 弹窗 —— 用户看到的是「点取消没反应」，得再点一次。
    expect(
      find.text('设置兑换积分'),
      findsNothing,
      reason: '提示条还开着，不该把「关弹窗」这件事吃掉',
    );
    expect(repo.writes, isEmpty);

    await dismissSnackbar(tester);
  });

  testWidgets('保存：写下去的是输入框里那个值，且不报错', (tester) async {
    final harness = openTab();
    final repo = harness.repo;
    await harness.open(tester);

    await tester.tap(costButton());
    await tester.pumpAndSettle();
    expect(find.text('设置兑换积分'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '35');
    await tester.tap(find.widgetWithText(ElevatedButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.text('设置兑换积分'), findsNothing);
    expect(repo.writes, [35], reason: '落库的必须是输入框里的新值');
    expect(
      tester.takeException(),
      isNull,
      reason: '改完保存同样会在关弹窗这一步报错',
    );

    // 保存成功会弹一条「已设置」，收尾把它关掉，别把残局留给下一个用例。
    await dismissSnackbar(tester);
  });

  testWidgets('保存 0：这是「不消耗积分」的正式表达，不是「没填」', (tester) async {
    final harness = openTab(pointCost: 30);
    final repo = harness.repo;
    await harness.open(tester);

    await tester.tap(costButton());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '0');
    await tester.tap(find.widgetWithText(ElevatedButton, '保存'));
    await tester.pumpAndSettle();

    expect(repo.writes, [0]);
    expect(tester.takeException(), isNull);

    await dismissSnackbar(tester);
  });

  testWidgets('原始定价会预填在输入框里', (tester) async {
    final harness = openTab(pointCost: 42);
    final repo = harness.repo;
    await harness.open(tester);

    await tester.tap(costButton());
    await tester.pumpAndSettle();

    // 家长多半只改一个数字。不预填的话「改价」就得先记住原来的值再输一遍。
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '42',
    );
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(repo.writes, isEmpty);
  });
}

/// `ParentController.onInit` 会调 `loadData()` 拉一整套家长端数据（连库）。
/// 这一组考的是弹窗，不需要那些数据 —— 所以**只把 `loadData` 摘掉**，
/// 而不是把 `onInit` 整个覆盖掉：`onInit` 里那条 `ever(selectedStudentId, …)`
/// 订阅要照常生效，否则测的就不是真实的控制器了。
///
/// 摘掉之后，页面其余取数逻辑与生产**完全一致**（`visibleWishes` / `points`
/// 都是真实现，只有数据来自注入的桩）。
class _NoLoadParentController extends ParentController {
  _NoLoadParentController({super.wishes});

  @override
  Future<void> loadData() async {
    // 刻意不拉数据。
  }
}

class _StubWishRepo implements WishRepository {
  /// 每一次 `updateWishRedeemState` 记下的新定价。
  final List<int> writes = <int>[];

  @override
  Future<void> updateWishRedeemState({
    required String id,
    int? pointCost,
    DateTime? redeemRequestedAt,
    DateTime? redeemedAt,
    DateTime? redeemRejectedAt,
    bool clearRedeemRequest = false,
    bool clearRedeemRejected = false,
  }) async {
    if (pointCost != null) writes.add(pointCost);
  }

  @override
  Future<List<WishModel>> queryWishes(String userRole) =>
      throw UnimplementedError('这一组不读心愿列表');

  @override
  Future<List<WishModel>> queryPublicWishes() =>
      throw UnimplementedError('这一组不读心愿列表');

  @override
  Future<List<WishModel>> queryPublicWishesByStudent(String studentId) =>
      throw UnimplementedError('这一组不读心愿列表');

  @override
  Future<List<WishModel>> queryUnfulfilledWishes() =>
      throw UnimplementedError('这一组不读心愿列表');

  @override
  Future<void> insertWish(WishModel wish, String userRole) =>
      throw UnimplementedError('这一组不建心愿');

  @override
  Future<void> updateWishConfirmation({
    required String id,
    bool? parentConfirmed,
    bool? studentConfirmed,
  }) => throw UnimplementedError('这一组不改确认状态');

  @override
  Future<void> updateWishArchived(String id, bool isArchived) =>
      throw UnimplementedError('这一组不归档');
}

class _StubPointRepo implements PointRepository {
  @override
  Future<List<PointLedgerEntry>> queryPointLedger(String studentId) async => [];

  @override
  Future<List<PointRule>> queryPointRules(String studentId) async => [];

  // 本文件只测心愿定价弹窗，用不到行为配置；返回空表等价于「没配过行为」。
  @override
  Future<List<PointBehavior>> queryPointBehaviors(String studentId) async =>
      const [];

  @override
  Future<void> upsertPointBehavior(PointBehavior behavior) async {}

  @override
  Future<void> deletePointBehavior(String studentId, String id) async {}

  @override
  Future<PointLedgerEntry?> findActivePointEntry({
    required String studentId,
    required String idempotencyKey,
  }) async => null;

  @override
  Future<bool> insertPointLedger(PointLedgerEntry entry) async => true;

  @override
  Future<void> markPointEntryReversed(String id, DateTime reversedAt) async {}

  @override
  Future<void> upsertPointRule(PointRule rule) async {}
}
