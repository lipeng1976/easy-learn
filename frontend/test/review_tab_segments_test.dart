import 'dart:io';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/review_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/student/tabs/review_tab.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';

/// 复习页的分段：**一段 = 一个状态，tab 上的数字 = tab 里的卡片数**。
///
/// ## 这条判据对应的真实故障（2026-10-23）
///
/// 用户：*「选择待复习，后面数字是 0，但是下面正在复习中……英语有 3 个题目，
/// 这里的信息逻辑有点混乱」*。
///
/// 根因不是算错，是**同一个词有两个定义**：
///   · 概览卡「待复习」用的是 `inPool`（= 非已掌握，含复习中/待批改）；
///   · 分段「待复习」用的是 `state == pending`。
/// 于是同一屏出现「待复习 45」和「待复习 0」。这个测试盯的是修好之后
/// 两者必须是同一个数。
///
/// ⚠️ 判据必须**同时**看数字和内容：只断数字的话，内容换成另一套口径依然
/// 会绿；只断内容的话，正好漏掉用户报的那个数字。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  Directory? tempDir;

  setUp(() async {
    // ⚠️ 不用 `setUpTestDatabase()`：它会灌演示数据，里面有「英语错题重做卷 ·
    // 第1轮」这样的种子卷子，资料区的数量就不再是这个用例造的那两份 ——
    // 判据会变成「种子里有几份」，改一次种子就红一次。
    final dir = await createIsolatedTestDir();
    pointPathProviderTo(dir);
    await DatabaseService.resetForTesting();
    tempDir = dir;
  });

  tearDown(() async {
    Get.reset();
    final dir = tempDir;
    if (dir != null) await tearDownTestDatabase(dir);
  });

  ReviewMistake mistake(
    String id,
    String subject,
    String title,
    ReviewState state,
  ) {
    return ReviewMistake(
      id: id,
      subject: subject,
      title: title,
      originalAnswer: '3/4',
      wrongReason: '约分遗漏',
      knowledgePoint: '$subject知识点',
      wrongCount: 1,
      lastWrongAt: DateTime(2026, 10, 20),
      studentId: 'stu_001',
      createdAt: DateTime(2026, 10, 20),
      state: state,
    );
  }

  /// 装载复习页。
  ///
  /// 错题直接塞进 `StudentController.mistakes`（它就是**唯一**的错题池，
  /// `ReviewController.mistakes` 是转发的），不绕真库 —— 少一次 I/O，
  /// 也避免假时钟里 sqflite 那些永远不返回的 timer。
  /// 卷子仍在真库里：`loadReviewData` 是从库读 papers 的。
  Future<ReviewController> pumpTab(WidgetTester tester) async {
    late ReviewController controller;
    await tester.runAsync(() async {
      registerStubDrillController();
      registerStubWordDrillController();
      final auth = Get.put(AuthController());
      auth.currentUser.value = UserModel(
        id: 'stu_001',
        name: '虫子',
        phone: '13800000000',
        role: 'student',
        avatar: '',
      );

      final student = StudentController();
      student.mistakes.assignAll([
        mistake('rm_en_r1', '英语', '英语复习中甲', ReviewState.reviewing),
        mistake('rm_en_r2', '英语', '英语复习中乙', ReviewState.reviewing),
        mistake('rm_math_p', '数学', '数学待复习丙', ReviewState.pending),
        mistake('rm_math_r', '数学', '数学复习中丁', ReviewState.reviewing),
      ]);

      await DatabaseService.instance.insertReviewPaperWithItems(
        ReviewPaper(
          id: 'rp_math',
          studentId: 'stu_001',
          title: '数学错题重做卷 · 10月20日',
          subject: '数学',
          itemCount: 0,
          createdAt: DateTime(2026, 10, 20),
        ),
        const [],
      );
      await DatabaseService.instance.insertReviewPaperWithItems(
        ReviewPaper(
          id: 'rp_en',
          studentId: 'stu_001',
          title: '英语错题重做卷 · 10月21日',
          subject: '英语',
          itemCount: 0,
          createdAt: DateTime(2026, 10, 21),
        ),
        const [],
      );

      controller = ReviewController(student: student);
      Get.put(controller);
      await controller.loadReviewData();
      // 用户报的场景就是「科目选英语」。
      controller.setSelectedSubject('英语');
    });

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 2600);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: ReviewTab())),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    return controller;
  }

  /// 某个分段项里的全部文字（第 1 个是标签，第 2 个是数字）。
  List<String?> segmentTexts(WidgetTester tester, String label) {
    final item = find
        .ancestor(of: find.text(label), matching: find.byType(Material))
        .first;
    return tester
        .widgetList<Text>(find.descendant(of: item, matching: find.byType(Text)))
        .map((t) => t.data)
        .toList();
  }

  testWidgets('选英语后「待复习」是 0，并且真的没有卡片', (tester) async {
    final controller = await pumpTab(tester);

    expect(controller.selectedSubject.value, '英语');

    expect(
      segmentTexts(tester, '待复习'),
      ['待复习', '0'],
      reason: '英语没有待复习的题；数字必须是 0，而不是全库那个 45',
    );

    expect(find.text('英语复习中甲'), findsNothing);
    expect(find.text('数学待复习丙'), findsNothing);
    expect(
      find.textContaining('没有待复习的错题'),
      findsOneWidget,
      reason: '空态必须说清「这个阶段空了」，而不是一片空白',
    );
  });

  testWidgets('概览卡不再重复四个状态数字（同一组数只出现一次）', (tester) async {
    await pumpTab(tester);

    expect(
      find.text('待复习'),
      findsOneWidget,
      reason: '同一屏出现两次「待复习」就是两个口径打架的源头',
    );
    expect(find.text('待批改'), findsOneWidget);
  });

  testWidgets('切到「复习中」只看到英语的题，且数量与 tab 数字一致', (tester) async {
    await pumpTab(tester);

    await tester.tap(find.text('复习中'));
    await tester.pump();

    expect(
      segmentTexts(tester, '复习中'),
      ['复习中', '2'],
      reason: '英语只有 2 道复习中；数学那道必须被科目筛掉',
    );

    expect(find.text('英语复习中甲'), findsOneWidget);
    expect(find.text('英语复习中乙'), findsOneWidget);
    expect(
      find.text('数学复习中丁'),
      findsNothing,
      reason: '选了英语还混进数学题 = 过滤只作用在数字上、没作用在内容上',
    );
  });

  testWidgets('复习资料按科目筛，标题里的数量与列表一致', (tester) async {
    await pumpTab(tester);

    expect(
      find.text('复习资料 1 份（英语）'),
      findsOneWidget,
      reason: '原来资料段完全不吃筛选：选英语会看到 9 份数学卷',
    );
    expect(find.text('英语错题重做卷 · 10月21日'), findsOneWidget);
    expect(find.text('数学错题重做卷 · 10月20日'), findsNothing);
  });

  testWidgets('待复习空着时，文案指向「题全在卷子里」而不是「没有错题」', (tester) async {
    await pumpTab(tester);

    expect(
      find.textContaining('错题都排进复习资料了'),
      findsOneWidget,
      reason: '不说破这一句，用户会以为错题被清空了',
    );
    expect(find.textContaining('份复习资料还没做完'), findsOneWidget);
  });
}
