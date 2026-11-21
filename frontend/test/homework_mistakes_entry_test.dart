import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/review_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/student/homework_mistakes_page.dart';
import 'package:easy_learn_app/pages/student/tabs/homework_tab.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/services/simulated_ai_data_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 「批改结果 → 这次作业的错题」这条入口。
///
/// 这条判据存在的理由很具体：`queryReviewMistakesByHomeworkId` 早就在
/// 模型 / 服务端 / 客户端仓储三层实现好了，但**一个调用点都没有** ——
/// 批改结果上的「错题 N 道」是一段纯文字，学生点不动。
/// 这种「机制都在、就是没接上」的缺陷不会报错，只能靠一条
/// 「真的点进去、真的看到那几道题、且查的是这份作业」的判据盯住。
///
/// ⚠️ 全程不碰真实数据库：`testWidgets` 在假时钟里跑，sqflite 的 I/O 靠真实
/// 定时器驱动，await 它**不会报错、只会永远等**（表现为测试挂住）。
/// 数据入口通过 [homeworkMistakesLoader] 替换。
/// 真库那边的「按作业过滤 + 最新在前」由 `mistake_order_test.dart` 盯。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  late Future<List<ReviewMistake>> Function(String) originalLoader;

  setUp(() {
    originalLoader = homeworkMistakesLoader;
  });

  tearDown(() {
    homeworkMistakesLoader = originalLoader;
    Get.reset();
  });

  HomeworkItem graded({required int wrongCount, String id = 'hw_ui'}) =>
      HomeworkItem(
        id: id,
        title: '口算20题',
        subject: '数学',
        imageUrl: '',
        dueAt: DateTime.now(),
        estimatedMinutes: 10,
        status: HomeworkStatus.finished,
        wrongCount: wrongCount,
        aiEnabled: true,
        userRole: 'student',
        studentId: 'stu_001',
        submittedAt: DateTime.now(),
        checkedAt: DateTime.now(),
        score: 80,
        summary: '有两道题符号写反了。',
      );

  ReviewMistake mistakeFor(String homeworkId, String id) => ReviewMistake(
    id: id,
    subject: '数学',
    title: '第 $id 题',
    originalAnswer: '2x',
    wrongReason: '符号写反了',
    createdAt: DateTime(2026, 10, 20, 9),
    state: ReviewState.pending,
    studentId: 'stu_001',
    homeworkId: homeworkId,
    sourceHomeworkTitle: '口算20题',
  );

  /// 注册页面需要的控制器。
  ///
  /// ⚠️ 注册 key 必须是父类类型（`Get.put<ReviewController>(...)`）——
  /// 写成推断出的子类会让页面 `Get.find` 报「没注册」。
  void registerControllers({HomeworkItem? homework}) {
    Get.put(AuthController()).currentUser.value = UserModel(
      id: 'stu_001',
      name: '林小宇',
      phone: '13800000001',
      role: 'student',
      avatar: '👦',
    );
    final student = StudentController(
      aiCheckDelay: Duration.zero,
      imageStorage: LocalImageStorageService(useMemory: true),
    );
    if (homework != null) student.homeworkList.assignAll([homework]);
    Get.put<StudentController>(student);
    Get.put<ReviewController>(
      ReviewController(student: student, ai: const SimulatedAiDataSource()),
    );
  }

  void useTallScreen(WidgetTester tester) {
    // 作业卡在列表下方：默认 800×600 里它不会被构建，
    // 于是 `find` 找不到 —— 那是判据在测「懒构建」而不是测入口。
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('点「错题 N 道」进入本次作业的错题，且查的是这一份作业', (tester) async {
    useTallScreen(tester);
    final asked = <String>[];
    homeworkMistakesLoader = (homeworkId) async {
      asked.add(homeworkId);
      return [
        mistakeFor(homeworkId, 'ui_1'),
        mistakeFor(homeworkId, 'ui_2'),
      ];
    };

    final item = graded(wrongCount: 2);
    registerControllers(homework: item);

    await tester.pumpWidget(
      GetMaterialApp(home: Scaffold(body: HomeworkTab())),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.textContaining('错题 2 道'),
      findsOneWidget,
      reason: '批改结果上没有错题入口 —— 学生只能自己绕到复习页去翻',
    );

    await tester.tap(find.textContaining('错题 2 道'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('本次作业的错题'), findsOneWidget, reason: '点了没跳转');
    expect(
      asked,
      ['hw_ui'],
      reason: '页面查的不是被点的那份作业 —— 会看到别的作业的错题',
    );
    expect(find.textContaining('共 2 道错题'), findsOneWidget);
    expect(find.text('第 ui_1 题'), findsOneWidget);
    expect(find.text('第 ui_2 题'), findsOneWidget);
  });

  testWidgets('这次作业没有错题时给出空状态，而不是一片空白', (tester) async {
    homeworkMistakesLoader = (homeworkId) async => const <ReviewMistake>[];
    registerControllers();

    await tester.pumpWidget(
      const GetMaterialApp(
        home: HomeworkMistakesPage(homeworkId: 'hw_empty', homeworkTitle: '口算20题'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('这次作业没有错题'), findsOneWidget);
  });

  testWidgets('读不出来时显式失败，不伪装成「没有错题」', (tester) async {
    homeworkMistakesLoader = (homeworkId) async =>
        throw StateError('数据服务没响应');
    registerControllers();

    await tester.pumpWidget(
      const GetMaterialApp(
        home: HomeworkMistakesPage(homeworkId: 'hw_error', homeworkTitle: '口算20题'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('错题没能读出来'), findsOneWidget);
    expect(
      find.text('这次作业没有错题'),
      findsNothing,
      reason: '读失败被说成「没有错题」—— 学生会以为自己这次全对',
    );
    expect(find.text('重试'), findsOneWidget);
  });
}
