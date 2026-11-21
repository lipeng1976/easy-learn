import 'dart:io';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/parent/review_paper_detail_page.dart';
import 'package:easy_learn_app/pages/parent/review_records_page.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';

/// 家长端复习页的资料卡片**能点开**（用户报「错题待导出，点击没反应」）。
///
/// ── 这一条盯的是什么 ────────────────────────────────────────────────────
///
/// 家长端「复习资料」卡片原来**完全没有 `onTap`**：没有箭头、没有按钮、
/// 点了没有任何反应。而它和同一页的「作业提交记录」「错题清单」卡片
/// 视觉上一模一样 —— 家长自然以为能点。
///
/// 更麻烦的是它自带一个「待导出」徽章：家长看到这三个字，会以为**自己**
/// 该去导出，而导出入口只存在于学生端。所以修法不是「加个点击效果」，
/// 是**点开之后把「卡在谁手上」说清楚**。
///
/// ## 测试结构：只有一条走真实导航
///
/// 每条 `testWidgets` 自己读库、自己 pump 页面。除「点得动」那条外，
/// 其余都**直接装载详情页** —— 不经过列表页、不经过 `Get.to`。
///
/// 这不是偷懒：早先所有用例都走同一条导航路径，结果「点得动」一旦变红，
/// 后面的用例就全部连带变红（上一条的路由/异步查询没收干净）——
/// 证伪时看到「4 条红」，会误判成「改一处坏了 4 个机制」。
/// **判据必须能单独失败。**
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

  void signInParent() {
    auth.currentUser.value = UserModel(
      id: 'par_001',
      name: '家长',
      phone: '13900000000',
      role: 'parent',
      avatar: 'parent',
    );
  }

  ReviewPaperItem item({
    required String id,
    required String paperId,
    required String title,
    String body = '',
    String answer = '',
    int sortOrder = 0,
  }) {
    return ReviewPaperItem(
      id: id,
      paperId: paperId,
      mistakeId: 'rm_$id',
      questionTitle: title,
      questionBody: body,
      answerKey: answer,
      sortOrder: sortOrder,
    );
  }

  Future<void> seedPaper({
    required String id,
    required String title,
    PaperStatus status = PaperStatus.draft,
    String studentId = 'stu_001',
    List<ReviewPaperItem> items = const [],
  }) async {
    await DatabaseService.instance.insertReviewPaperWithItems(
      ReviewPaper(
        id: id,
        studentId: studentId,
        title: title,
        subject: '数学',
        knowledgePoints: const ['分数加法'],
        status: status,
        itemCount: items.length,
        createdAt: DateTime(2026, 10, 20, 9),
      ),
      items,
    );
  }

  /// 登录家长 + 读库。返回的控制器**已放进 Get**，页面能 `Get.find` 到。
  ///
  /// ⚠️ 局部变量必须显式标注 `ParentController`：`Get.put` 的注册 key 是
  /// **变量的静态类型**。写成 `final c = _NoAutoLoadParentController()`
  /// 会注册在私有子类名下，页面 `Get.find<ParentController>()` 当场找不到 ——
  /// 症状是「控制器没注册」，而真正原因只是少了一个类型标注。
  Future<ParentController> installParent(
    WidgetTester tester,
    Future<void> Function() seed,
  ) async {
    signInParent();
    final ParentController controller = _NoAutoLoadParentController();
    controller.selectedStudentId.value = 'stu_001';
    await tester.runAsync(() async {
      await seed();
      await controller.loadData();
    });
    Get.put(controller);
    return controller;
  }

  /// 直接装载卷内预览页。
  ///
  /// 读库在 `runAsync` 的真时钟里等 —— 详情页自己的 `initState` 也读真 SQLite，
  /// 而 `pumpAndSettle` 会在加载圈（无限动画）上一直转。
  Future<void> pumpDetail(
    WidgetTester tester,
    String paperId, {
    required Future<void> Function() seed,
    Future<List<ReviewMistakeImage>> Function(String mistakeId)? photoLoader,
  }) async {
    await installParent(tester, seed);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 2400);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      GetMaterialApp(
        home: ParentReviewPaperPage(
          paperId: paperId,
          // 默认把取图整段换掉：假时钟里 sqflite I/O 永远不返回，
          // 真读会让这条用例以「dispose 后仍有 pending timer」假红。
          // 原题照片的渲染行为由 `review_item_photos_test.dart` 单独盯。
          photoLoader: photoLoader ?? (_) async => const [],
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
  }

  group('卷内预览的内容', () {
    testWidgets('详情页显示卷内题目，公式渲染成块而不是 LaTeX 原文', (tester) async {
      await pumpDetail(
        tester,
        'rp_1',
        seed: () => seedPaper(
          id: 'rp_1',
          title: '数学错题重做卷 · 第1轮',
          items: [
            item(
              id: 'rpi_1',
              paperId: 'rp_1',
              title: '分数加法第 1 题',
              body: r'计算 $\frac{1}{2}+\frac{1}{3}$ 的值',
              answer: r'$\frac{5}{6}$',
            ),
            item(
              id: 'rpi_2',
              paperId: 'rp_1',
              title: '分数减法第 2 题',
              sortOrder: 1,
            ),
          ],
        ),
      );

      expect(find.text('卷内题目（快照）'), findsOneWidget);
      expect(find.text('分数加法第 1 题'), findsOneWidget);
      expect(find.text('分数减法第 2 题'), findsOneWidget);
      expect(
        find.textContaining(r'\frac'),
        findsNothing,
        reason: '题干里的 LaTeX 没被渲染 —— 家长会以为题目写错了',
      );
    });

    testWidgets('卷内题目挂上了原题照片（与孩子端同一个组件）', (tester) async {
      // 只验**接线**：卷内题目的 `mistakeId` 有没有被拿去取图。
      // 取图整段换成一个立刻失败的桩 —— 真图渲染由
      // `review_item_photos_test.dart` 单独盯，这里不重复也不碰网络。
      final asked = <String>[];
      await pumpDetail(
        tester,
        'rp_photo',
        photoLoader: (mistakeId) async {
          asked.add(mistakeId);
          throw StateError('本用例只验接线，不取真图');
        },
        seed: () => seedPaper(
          id: 'rp_photo',
          title: '数学错题重做卷 · 10月23日',
          items: [item(id: 'rpi_p1', paperId: 'rp_photo', title: '带图的题')],
        ),
      );
      await tester.pump();

      expect(
        asked,
        ['rm_rpi_p1'],
        reason: '卷内题目的 mistakeId 没被拿去取图 —— 家长永远看不到原题照片',
      );
      // 取不到图时必须有文字占位：空白框会被读成「这题本来没图」。
      expect(find.textContaining('原题照片暂时读不到'), findsOneWidget);
    });

    testWidgets('「待导出」时说清导出要孩子做，不是家长', (tester) async {
      await pumpDetail(
        tester,
        'rp_draft',
        seed: () => seedPaper(
          id: 'rp_draft',
          title: '待导出的资料',
          items: [item(id: 'rpi_d', paperId: 'rp_draft', title: '第 1 题')],
        ),
      );

      // ⚠️ 断言要用只在这一块出现的句子。原来写「家长端只能看」，
      // 而底部说明写的是「家长端只能查**看**」—— 子串同样命中。
      // 那样这条判据就变成「底部说明有没有进视口」（`ListView` 懒构建），
      // 页面一短就假红，报的原因完全不是要测的那件事。
      expect(find.textContaining('这份卷子要由孩子'), findsOneWidget);
      expect(find.textContaining('不能导出'), findsOneWidget);
    });

    testWidgets('两份资料各是各的，不串题', (tester) async {
      await pumpDetail(
        tester,
        'rp_b',
        seed: () async {
          await seedPaper(
            id: 'rp_a',
            title: 'A 卷',
            items: [item(id: 'rpi_a', paperId: 'rp_a', title: 'A 卷的题')],
          );
          await seedPaper(
            id: 'rp_b',
            title: 'B 卷',
            items: [item(id: 'rpi_b', paperId: 'rp_b', title: 'B 卷的题')],
          );
        },
      );

      expect(find.text('B 卷的题'), findsOneWidget);
      expect(
        find.text('A 卷的题'),
        findsNothing,
        reason: '按 paperId 查题 —— 串题说明查询没带上这一份的 id',
      );
    });
  });

  group('归属校验（页面能被直接打开，不能只靠入口过滤）', () {
    testWidgets('不属于当前孩子的资料，打开后明说不在记录中', (tester) async {
      signInParent();
      final ParentController controller = _NoAutoLoadParentController();
      controller.selectedStudentId.value = 'stu_001';
      await tester.runAsync(() async {
        await seedPaper(
          id: 'rp_other',
          title: '别人家的卷子',
          studentId: 'stu_999',
          items: [item(id: 'rpi_o', paperId: 'rp_other', title: '不该看见')],
        );
        await controller.loadData();

        // ⚠️ 这一步是这条判据的关键，别删。
        //
        // `loadData()` 在写入 `reviewPapers` 时就已经按结伴关系过滤了一遍，
        // 所以别的孩子的卷**根本进不来** —— 只走 `loadData` 的话，页面里
        // 那句归属判断永远不会被执行，这条用例就会**永远绿**（空转的绿）。
        // 这里直接把全量塞回去，模拟「数据入口变了」或「有别的写路径」：
        // 页面自己必须还认得出来。
        controller.reviewPapers.assignAll(
          await DatabaseService.instance.queryReviewPapers(),
        );
      });
      Get.put(controller);

      await tester.pumpWidget(
        const GetMaterialApp(home: ParentReviewPaperPage(paperId: 'rp_other')),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();

      expect(find.textContaining('不在孩子的记录中'), findsOneWidget);
      expect(find.text('不该看见'), findsNothing);
    });
  });

  group('点得动（唯一走真实导航的一条）', () {
    testWidgets('点复习页的资料卡片会进入卷内预览', (tester) async {
      await installParent(
        tester,
        () => seedPaper(
          id: 'rp_1',
          title: '数学错题重做卷 · 第1轮',
          items: [item(id: 'rpi_1', paperId: 'rp_1', title: '分数加法第 1 题')],
        ),
      );

      // 11-15：资料列表从复习页搬进「资料与记录」独立页。这条判据测的是
      // 「列表上的卡片能不能点开」，所以跟着列表走 —— 不是把断言删掉。
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1000, 2400);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const GetMaterialApp(home: ReviewRecordsPage()),
      );
      await tester.pump();

      await tester.tap(find.text('数学错题重做卷 · 第1轮'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byType(ParentReviewPaperPage),
        findsOneWidget,
        reason: '卡片没挂导航 —— 用户报的「点击没反应」就是这一句',
      );
      expect(find.text('分数加法第 1 题'), findsOneWidget);
    });
  });
}

/// 理由同 `parent_answer_photos_test.dart`：`onInit` 里的 `loadData()` 是给真机的，
/// 在假时钟里会挂住（它读真 SQLite）。
class _NoAutoLoadParentController extends ParentController {
  @override
  // ignore: must_call_super
  void onInit() {
    // 刻意留空。
  }
}
