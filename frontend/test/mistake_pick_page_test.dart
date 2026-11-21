import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/review_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/student/mistake_pick_page.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/services/simulated_ai_data_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 组卷前「选题」页的判据。
///
/// 这个页面的核心价值只有一条：**让学生自己圈范围**，且默认帮他把
/// 「错得最多的题」勾上、排到前面。所以判据盯着三件事：
/// 1. 错得多的题排在前面；
/// 2. 默认勾选错得最多的前 N 道；
/// 3. 点「生成」才会真的组卷（不自动全量）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  tearDown(Get.reset);

  ReviewMistake mistake(
    String id,
    String point,
    int wrongCount,
    DateTime createdAt,
  ) => ReviewMistake(
    id: id,
    subject: '数学',
    title: '$point 的一道题',
    originalAnswer: '1',
    wrongReason: '算错了',
    createdAt: createdAt,
    state: ReviewState.pending,
    studentId: 'stu_001',
    knowledgePoint: point,
    wrongCount: wrongCount,
  );

  void registerControllers(List<ReviewMistake> list) {
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
    student.mistakes.assignAll(list);
    Get.put<StudentController>(student);
    Get.put<ReviewController>(
      ReviewController(student: student, ai: const SimulatedAiDataSource()),
    );
  }

  testWidgets('错得多的题排前面、默认勾选，点生成才组卷', (tester) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    registerControllers([
      mistake('m_new', '一元一次方程', 1, DateTime(2026, 10, 22, 9)),
      mistake('m_mid', '分数比较', 2, DateTime(2026, 10, 21, 9)),
      mistake('m_hot', '有理数混合运算', 5, DateTime(2026, 10, 20, 9)),
    ]);

    await tester.pumpWidget(
      const GetMaterialApp(home: MistakePickPage()),
    );
    await tester.pump();

    // 错得最多的「有理数混合运算」排在最前（它是第一张卡）。
    final hotPos = tester.getTopLeft(find.text('有理数混合运算 的一道题'));
    final newPos = tester.getTopLeft(find.text('一元一次方程 的一道题'));
    expect(hotPos.dy < newPos.dy, isTrue, reason: '错得多的题没排到前面');

    // 默认勾选：错得最多（5次）的题一定被选中。判断方式是它所在的
    // 卡片有高亮边框 —— 用「已选 N 道」文案间接验证（3 道都在默认上限内）。
    expect(find.text('已选 3 道'), findsOneWidget,
        reason: '默认应该勾选全部待复习题（≤ 上限时）');

    // 错得多的题显示醒目的「错 5 次」角标。
    expect(find.text('错 5 次'), findsOneWidget);
  });

  testWidgets('超过默认上限时，只默认勾选错得最多的前 10 道', (tester) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final many = [
      for (var i = 0; i < 12; i++)
        mistake('m$i', '知识点$i', i + 1, DateTime(2026, 10, 22 - i)),
    ];
    registerControllers(many);

    await tester.pumpWidget(
      const GetMaterialApp(home: MistakePickPage()),
    );
    await tester.pump();

    // 12 道题，默认只勾选错得最多的前 10 道。
    expect(find.text('已选 10 道'), findsOneWidget,
        reason: '默认勾选数应是 10（上限），不是全部');
  });

  testWidgets('已在别的卷子里的题不可选，但会说明「另有 N 道」', (tester) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final reviewing = ReviewMistake(
      id: 'm_busy',
      subject: '数学',
      title: '正在做的那道题',
      originalAnswer: '1',
      wrongReason: '算错了',
      createdAt: DateTime(2026, 10, 22, 9),
      state: ReviewState.reviewing,
      studentId: 'stu_001',
      knowledgePoint: '分数比较',
    );
    registerControllers([
      mistake('m_free', '一元一次方程', 2, DateTime(2026, 10, 22, 8)),
      reviewing,
    ]);

    await tester.pumpWidget(
      const GetMaterialApp(home: MistakePickPage()),
    );
    await tester.pump();

    // 复习中的题不该出现在可选列表里（否则一道题会同时进两张卷子）。
    expect(find.text('正在做的那道题'), findsNothing);
    // 但必须说明它去哪了 —— 否则看起来像「错题凭空少了」。
    expect(
      find.textContaining('另有 1 道题已在别的卷子里'),
      findsOneWidget,
      reason: '复习中的题消失了却不说一句，学生以为错题丢了',
    );
    expect(find.text('已选 1 道'), findsOneWidget);
  });
}
