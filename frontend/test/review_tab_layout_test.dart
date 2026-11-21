import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/review_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/student/tabs/review_tab.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/services/simulated_ai_data_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';

/// 复习页的**排版**判据（2026-10-20 改版）。
///
/// 改版做的是减法：标题去掉、两组筛选标签压成一行下拉、三个带边框的
/// 分段改成同一个容器里的三段。这种改动最容易出的问题是**挤爆**——
/// 宽度不够时 Row 会溢出，而溢出在真机上表现为一条黄黑斜纹，
/// 在测试里是一条异常。窄屏（360dp）跑一遍就能把它逼出来。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  tearDown(Get.reset);

  ReviewMistake mistake(String id, String subject, String point) => ReviewMistake(
    id: id,
    subject: subject,
    title: '$point 的一道题',
    originalAnswer: '1',
    wrongReason: '算错了',
    createdAt: DateTime(2020, 3, 5, 9),
    state: ReviewState.pending,
    studentId: 'stu_001',
    knowledgePoint: point,
  );

  void registerControllers() {
    registerStubDrillController();
    registerStubWordDrillController();
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
    student.mistakes.assignAll([
      mistake('m1', '数学', '一元一次方程'),
      mistake('m2', '语文', '古诗词默写'),
    ]);
    Get.put<StudentController>(student);
    Get.put<ReviewController>(
      ReviewController(student: student, ai: const SimulatedAiDataSource()),
    );
  }

  testWidgets('360dp 窄屏下不溢出，且新控件都在位', (tester) async {
    // 宽度取真实窄屏（360dp），高度拉高：卡片在列表下方，
    // `ListView` 不构建视口外的元素，矮屏上 `find` 只会测到「懒构建」。
    tester.view.physicalSize = const Size(360, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    registerControllers();
    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: ReviewTab())),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 错题默认按「本学期」归档筛选，而上面造的错题没有学期 ——
    // 先切到「全部」再看列表，否则测的是筛选而不是卡片。
    Get.find<ReviewController>().showAllTerms();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 排版改版后：一行两个筛选、一个四段控件（一段一个状态）、卡片列表。
    expect(find.text('全部科目'), findsOneWidget, reason: '科目筛选的下拉没出现');
    expect(find.text('掌握率'), findsOneWidget);
    // ⭐ 四段各出现**一次**。原来「待复习」「已掌握」是两次（概览统计 + 分段），
    // 那正是两个口径共用一个词的现场 —— 现在统计行搬进分段了，只该剩一处。
    expect(find.text('待复习'), findsOneWidget);
    expect(find.text('复习中'), findsOneWidget);
    expect(find.text('待批改'), findsOneWidget);
    expect(find.text('已掌握'), findsOneWidget);
    // 资料区是独立一块：没有卷子时显示空态卡。
    expect(find.textContaining('复习资料'), findsWidgets);

    // 原来的大标题去掉了：底部导航已经写着「复习」。
    expect(find.text('错题复习'), findsNothing);

    // 卡片上应能看到日期（这次一并补上的）。
    expect(find.textContaining('2020年3月5日'), findsWidgets);
  });

  testWidgets('科目筛选点得开，选中后生效', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    registerControllers();
    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: ReviewTab())),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('全部科目'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('按科目筛选'), findsOneWidget, reason: '点筛选没有打开选择器');

    await tester.tap(find.text('语文').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final controller = Get.find<ReviewController>();
    expect(controller.selectedSubject.value, '语文');
    expect(
      find.text('一元一次方程 的一道题'),
      findsNothing,
      reason: '选了语文，数学的题还在列表里',
    );
  });
}
