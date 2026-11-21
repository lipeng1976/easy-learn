import 'dart:io';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/parent/homework_detail_page.dart';
import 'package:easy_learn_app/repositories/homework_repository.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';

/// 家长端「作业信息」里能不能看到**孩子实际用了多久**。
///
/// ── 这一条盯的是什么 ────────────────────────────────────────────────────
///
/// 家长端一直有「预计耗时」，而 `homework.actualSeconds` 从专注计时上线那天起
/// 就在库里躺着了（学生端详情页也早就在显示）。家长端读得到、模型也解析了，
/// **只有界面没接** —— 于是家长看到的是「预计 30 分钟」，看不到孩子到底做了
/// 50 分钟还是 8 分钟。
///
/// 这类「数据通了、界面没接」的缺口有个特征：任何一层单独看都是好的。
/// 服务端 `listHomework` 返回 `actual_seconds`、`_fromRow` 解析 `actualSeconds`、
/// `HomeworkItem` 有 `hasActualTime` —— 每一处都经得起检查。
/// 所以判据必须落在**页面上**，而且必须证明那个数字是**从库里读出来的**，
/// 不是界面自己写死的。
///
/// ## 两条口径（比"显示出来"更容易做错）
///
/// 1. **0 秒 ≠ 做了 0 秒**。`actualSeconds == 0` 的真实含义是「没有计时数据」：
///    孩子可能压根没开计时、也可能开了但立刻退出。把它显示成「0 分钟」在家长
///    眼里是一句断言（「孩子一秒没做」），而系统实际什么都不知道。
///    ⇒ 没有数据时要说「孩子未开启计时」。
/// 2. **这个数不是系统自动统计的**。它只在孩子主动开「专注计时」时产生，
///    所以它在家长端的正确读法是「孩子自己记的时间」，不是「在线时长」。
///    这一点决定了文案：不能写「学习时长」那种听起来像被自动监控的词。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  Directory? tempDir;
  late AuthController auth;

  setUp(() async {
    tempDir = await setUpTestDatabase();
    auth = Get.put(AuthController());
  });

  tearDown(() async {
    Get.reset();
    final dir = tempDir;
    if (dir != null) await tearDownTestDatabase(dir);
  });

  /// 以家长 `par_001` 的身份登录 —— 演示种子里他只与 `stu_001` 结伴。
  void signInParent() {
    auth.currentUser.value = UserModel(
      id: 'par_001',
      name: '家长',
      phone: '13900000000',
      role: 'parent',
      avatar: 'parent',
    );
  }

  /// 造一份**已提交**的作业。
  ///
  /// `submittedAt` 不能在 `insertHomework` 里给 —— 它落库时根本不写这一列
  /// （提交是另一个动作）。这里插完再补一次 patch，形状与真实链路一致。
  Future<void> seedHomework({
    required String id,
    int actualSeconds = 0,
    int estimatedMinutes = 30,
    String studentId = 'stu_001',
  }) async {
    await DatabaseService.instance.insertHomework(
      HomeworkItem(
        id: id,
        title: '口算练习',
        subject: '数学',
        imageUrl: '',
        dueAt: DateTime(2026, 10, 20, 20),
        estimatedMinutes: estimatedMinutes.toDouble(),
        actualSeconds: actualSeconds,
        status: HomeworkStatus.finished,
        wrongCount: 0,
        aiEnabled: true,
        userRole: 'student',
        studentId: studentId,
      ),
      'student',
    );
    await DatabaseService.instance.updateHomework(
      HomeworkPatch(id: id)..submittedAt = DateTime(2026, 10, 20, 19),
    );
  }

  /// 控制器用例走这里：普通 `test()` 跑在**真时钟**上。
  Future<ParentController> buildParent() async {
    signInParent();
    final controller = ParentController();
    controller.selectedStudentId.value = 'stu_001';
    await controller.loadData();
    return controller;
  }

  /// 装载作业详情页。
  ///
  /// ⚠️ 读库必须放进 `tester.runAsync`：`testWidgets` 的函数体跑在假时钟上，
  /// 一长串真实 SQLite 查询在假时钟里走不完（会挂死整个文件）。
  /// 同理，控制器要用**不自动加载**的子类，否则 `Get.put` 的 `onInit`
  /// 会在假时钟里再跑一遍 `loadData()`。
  Future<ParentController> openDetail(WidgetTester tester, String homeworkId) async {
    signInParent();
    final ParentController controller = _NoAutoLoadParentController();
    controller.selectedStudentId.value = 'stu_001';
    await tester.runAsync(() => controller.loadData());

    Get.put(controller);

    // 视口放宽：详情页是 `ListView`，懒构建。默认 800×600 下「作业信息」
    // 虽然是第一屏，但一旦上面多出一块横幅就可能把断言挤到视口外 ——
    // 那会让「找不到」变成假绿（什么都没测到，却永远通过）。
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 2400);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: HomeworkDetailPage(homeworkId: homeworkId)),
    );
    await tester.pump();
    return controller;
  }

  group('数据链路（家长端读不读得到孩子记的时间）', () {
    test('孩子计时写入的数，家长端控制器原样读出来', () async {
      await seedHomework(id: 'hw_timed', actualSeconds: 1935);

      final parent = await buildParent();

      expect(
        parent.homeworkById('hw_timed')?.actualSeconds,
        1935,
        reason: '家长端拿到的必须是那个总数（32 分 15 秒），'
            '不是 0、也不是「预计耗时」兜底出来的值',
      );
    });

    test('没计时的作业读回来是 0，而不是被填成预计耗时', () async {
      await seedHomework(id: 'hw_untimed', actualSeconds: 0, estimatedMinutes: 30);

      final parent = await buildParent();

      expect(
        parent.homeworkById('hw_untimed')?.actualSeconds,
        0,
        reason: '0 的含义是「没有计时数据」；'
            '拿预计耗时兜底会把「计划」伪装成「实际」',
      );
    });
  });

  group('家长端界面（数据通了不等于界面接了）', () {
    testWidgets('计时过的作业，页面上真的出现实际用时', (tester) async {
      await tester.runAsync(() => seedHomework(id: 'hw_timed', actualSeconds: 1935));

      await openDetail(tester, 'hw_timed');

      expect(find.text('实际用时'), findsOneWidget);
      expect(
        find.text('32 分 15 秒'),
        findsOneWidget,
        reason: '这个数字必须来自库里的 1935 秒 —— '
            '写死在界面上的常量不会随数据变，下一条用例就是它的反面',
      );
      expect(find.text('孩子未开启计时'), findsNothing);
    });

    testWidgets('另一份作业换了时长，页面跟着变（不是写死的）', (tester) async {
      await tester.runAsync(() => seedHomework(id: 'hw_timed', actualSeconds: 480));

      await openDetail(tester, 'hw_timed');

      expect(find.text('8 分'), findsOneWidget);
      expect(find.text('32 分 15 秒'), findsNothing);
    });

    testWidgets('没计时时说的是「孩子未开启计时」，不是「0 秒」', (tester) async {
      await tester.runAsync(() => seedHomework(id: 'hw_untimed'));

      await openDetail(tester, 'hw_untimed');

      expect(find.text('实际用时'), findsOneWidget, reason: '这一行要在，'
          '家长才知道「有计时这回事、这次没用」；藏掉它等于没这个功能');
      expect(find.text('孩子未开启计时'), findsOneWidget);
      // 反面：任何形态的「0」都不许出现 —— 它会被读成「孩子一秒没做」。
      expect(find.textContaining('0 秒'), findsNothing);
      expect(find.text('0 分'), findsNothing);
    });

    testWidgets('预计耗时照旧显示，没有被实际用时挤掉', (tester) async {
      await tester.runAsync(() => seedHomework(id: 'hw_timed', actualSeconds: 1935));

      await openDetail(tester, 'hw_timed');

      expect(find.text('30 分钟'), findsOneWidget);
      expect(find.text('32 分 15 秒'), findsOneWidget);
    });
  });
}

/// `onInit` 里那句 `loadData()` 是给真机用的。widget 测试跑在假时钟上，
/// 不能让它在 `Get.put` 时自动再跑一遍 —— 读库由测试自己在 `runAsync`
/// 的真时钟里显式调一次（见 `openDetail`）。
class _NoAutoLoadParentController extends ParentController {
  // ⚠️ 位置有讲究：`// ignore:` 只作用于**紧接的下一行**，而这条诊断报在
  // `void onInit() {` 这一行（不是 `@override` 那行）。
  @override
  // ignore: must_call_super
  void onInit() {
    // 刻意留空。
  }
}
