import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/models/homework_photo_draft.dart';
import 'package:easy_learn_app/models/op_result.dart';
import 'package:easy_learn_app/pages/student/widgets/homework_submit_sheet.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/widgets/needs_grading_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 提交面板上的「需要批改」开关。
///
/// 这一层刻意**不碰数据库**：面板里真正会出错的不是数据，而是
/// 「开关的初值有没有跟着作业走」「改完之后界面上的说法有没有跟着变」。
/// 提交之后到底批没批，由 `homework_submission_flow_test.dart` 那几条
/// 真实 SQLite 的用例负责，两边分工。
///
/// 不让 controller 里出现这条作业，`_homework` 就会回落到传进来的那份 ——
/// 这正好把「面板只依赖传入的作业」这件事也一起钉住了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  HomeworkItem homeworkWith({required bool needsGrading, bool aiEnabled = true}) =>
      HomeworkItem(
        id: 'hw_read',
        title: '朗读课文第5课',
        subject: '语文',
        imageUrl: '',
        dueAt: DateTime(2026, 9, 17, 20),
        estimatedMinutes: 10,
        status: HomeworkStatus.pending,
        wrongCount: 0,
        aiEnabled: aiEnabled,
        needsGrading: needsGrading,
        userRole: 'student',
        studentId: 'stu_001',
      );

  /// 打开提交面板，返回控制器（面板挂上去之后才能查里面的控件）。
  Future<void> openSheet(WidgetTester tester, HomeworkItem homework) async {
    final controller = StudentController(
      imageStorage: LocalImageStorageService(useMemory: true),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => openHomeworkSubmitSheet(
                context: context,
                controller: controller,
                homework: homework,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  bool switchValue(WidgetTester tester) =>
      tester.widget<Switch>(find.byType(Switch)).value;

  testWidgets('朗读类作业：开关默认是关的，按钮不说「开始 AI 批改」', (tester) async {
    await openSheet(tester, homeworkWith(needsGrading: false));

    // 口径继承作业上存的那份 —— 面板不该自己重新猜一遍。
    expect(switchValue(tester), isFalse);
    expect(find.text('无需批改'), findsOneWidget);
    expect(find.text('确认提交'), findsOneWidget);
    expect(find.text('提交并开始 AI 批改'), findsNothing);
    // 开关关着的时候要说清「附件只是留档」，否则学生以为交了个没用的东西。
    expect(find.textContaining('家长仍能看到你提交的附件'), findsOneWidget);
  });

  testWidgets('书面作业：开关默认是开的', (tester) async {
    await openSheet(tester, homeworkWith(needsGrading: true));

    expect(switchValue(tester), isTrue);
    expect(find.text('提交后 AI 批改'), findsOneWidget);
    expect(find.text('提交并开始 AI 批改'), findsOneWidget);
  });

  testWidgets('学生改开关：文案跟着变，方向两边都要对', (tester) async {
    await openSheet(tester, homeworkWith(needsGrading: false));

    // 关 → 开
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(switchValue(tester), isTrue);
    expect(find.text('提交并开始 AI 批改'), findsOneWidget);
    expect(find.text('确认提交'), findsNothing);

    // 开 → 关（false 不是「不改」，这个方向最容易写反）
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(switchValue(tester), isFalse);
    expect(find.text('确认提交'), findsOneWidget);
  });

  testWidgets('AI 批改没开时要说实话：勾了也批不了', (tester) async {
    await openSheet(tester, homeworkWith(needsGrading: true, aiEnabled: false));

    // 作业要批改，但这台环境批不了 —— 标签和提示都不能说「提交后 AI 批改」。
    expect(find.text('AI 批改未开启'), findsOneWidget);
    expect(find.text('提交并开始 AI 批改'), findsNothing);
    expect(find.textContaining('实际上不会批改'), findsOneWidget);
  });

  testWidgets('开关组件本身：两种状态的说明文字不同', (tester) async {
    var value = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => NeedsGradingSwitch(
              value: value,
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      ),
    );

    expect(find.text('只上传照片留档，不检查对错'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('提交后由 AI 检查对错，错了进错题本'), findsOneWidget);
  });

  /// 提交之后面板关不关。
  ///
  /// 这条用例的由来：面板是 **Flutter 原生 `showModalBottomSheet`** 打开的，
  /// 而 `_submit` 里关面板那行写的是 `Get.isBottomSheetOpen` —— 这个标记只跟
  /// `Get.bottomSheet` 走，在原生面板下**恒为 false**，所以那行从来没执行过。
  /// 现象是：学生点了「确认提交」、看到「提交成功」，面板却还敞着，他以为没交上，
  /// 于是再点一次 —— 第二次会把同一批照片**重复入库**。
  ///
  /// 是真浏览器走查把它抓出来的：`flutter analyze` 看不出（类型都对），
  /// `flutter test` 里也没有真实面板的关闭。所以这里用假控制器把行为钉死。
  testWidgets('提交成功：面板关掉；提交失败：面板留着', (tester) async {
    final controller = _FakeSubmitController(
      homework: homeworkWith(needsGrading: false),
    );
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => openHomeworkSubmitSheet(
                context: context,
                controller: controller,
                homework: homeworkWith(needsGrading: false),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('确认提交'), findsOneWidget);

    // 先失败一次：照片还在面板里，关掉等于让他重拍一遍。
    controller.next = const OpResult.fail('网络不给力');
    await tester.tap(find.text('确认提交'));
    await tester.pumpAndSettle();
    expect(
      find.text('确认提交'),
      findsOneWidget,
      reason: '提交失败后面板不该关，照片还要留着让他重试',
    );

    // 再成功一次：这次必须关。
    controller.next = const OpResult.success('作业已提交');
    await tester.tap(find.text('确认提交'));
    await tester.pumpAndSettle();
    expect(
      find.text('确认提交'),
      findsNothing,
      reason: '提交成功后面板要关，否则学生以为没交上会再点一次',
    );
    expect(controller.calls, 2);

    // 收尾：GetX 的 snackbar 自带「到点自动关」的定时器，而且它是**排队**的
    // （第一条关掉第二条才显示、又新建一个定时器）。测试结束时还有定时器活着，
    // 框架会判「A Timer is still pending」—— 多推几轮把队列排空。
    // 注意 `pumpAndSettle` 不干这事：它只推进会排帧的定时器。
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 4));
    }
    await tester.pumpAndSettle();
  });
}

/// 只回答「提交成不成功」的控制器。
///
/// 不碰数据库：这条用例要验的是**面板自己的关闭行为**，
/// 真实落库那条路由 `homework_submission_flow_test.dart` 负责。
class _FakeSubmitController extends StudentController {
  _FakeSubmitController({required HomeworkItem homework})
    : super(imageStorage: LocalImageStorageService(useMemory: true)) {
    homeworkList.add(homework);
  }

  OpResult next = const OpResult.success('作业已提交');
  int calls = 0;

  @override
  Future<OpResult> submitHomework({
    required String homeworkId,
    List<HomeworkPhotoDraft> photos = const <HomeworkPhotoDraft>[],
    bool? needsGrading,
  }) async {
    calls++;
    return next;
  }
}
