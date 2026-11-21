import 'dart:async';
import 'dart:io';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/review_controller.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/student/review_paper_page.dart';
import 'package:easy_learn_app/repositories/review_repository.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';

/// 打开卷子时，**题目还在取**不能说成「这份资料还没有题目」。
///
/// ## 这条判据对应的真实故障（2026-10-23）
///
/// 用户：*「待导出进去之后，开始提示这份资料还没有题目，也是过了一段时间
/// 以后才出现」*。
///
/// `openPaper` 是**先设卷、再取题目**，中间那个「卷名已经显示、题目还是空的」
/// 的中间态，早先直接落进 `items.isEmpty` 分支 —— 于是页面写着一句假话。
/// 服务端在局域网时这个窗口只有几十毫秒，用户往往只看到一闪；
/// 网络慢一点就变成「资料生成失败了」。
///
/// ⚠️ 这条判据必须**卡住取题那一步**才有意义（否则窗口太窄，测的是运气）：
/// 用一个可控制的 `Completer` 当闸门，在题目确定还没回来的那一帧断言。
/// 负对照是第二条用例：闸门放开之后，题目必须真的渲染出来 ——
/// 只钉「不显示假话」而不钉「后来显示了真话」，等于允许页面永远转圈。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  Directory? tempDir;

  setUp(() async {
    tempDir = await setUpTestDatabase();
  });

  tearDown(() async {
    Get.reset();
    final dir = tempDir;
    if (dir != null) await tearDownTestDatabase(dir);
  });

  Future<ReviewController> install(WidgetTester tester, _GatedReview repo) async {
    late ReviewController controller;
    await tester.runAsync(() async {
      final auth = Get.put(AuthController());
      auth.currentUser.value = UserModel(
        id: 'stu_001',
        name: '虫子',
        phone: '13800000000',
        role: 'student',
        avatar: '',
      );
      // 卷子是**真库**里的：页面要靠 `papers` 列表认出这份卷子，
      // 认不出来就会走 `paper == null` 的整页转圈，那样这条用例测不到东西。
      await DatabaseService.instance.insertReviewPaperWithItems(
        ReviewPaper(
          id: 'rp_load',
          studentId: 'stu_001',
          title: '数学错题重做卷 · 10月23日',
          subject: '数学',
          itemCount: 1,
          createdAt: DateTime(2026, 10, 23, 8, 30),
        ),
        const [],
      );
      controller = ReviewController(review: repo);
      Get.put(controller);
      await controller.loadReviewData();
    });
    return controller;
  }

  testWidgets('题目还在取的时候，不显示「这份资料还没有题目」', (tester) async {
    final repo = _GatedReview();
    await install(tester, repo);

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 2400);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const GetMaterialApp(home: ReviewPaperPage(paperId: 'rp_load')),
    );
    await tester.pump();

    // 闸门没开 = 题目确定还没回来。
    expect(repo.itemsAsked, isTrue, reason: '页面没有去取卷内题目，这条用例空转');
    expect(
      find.text('这份资料还没有题目'),
      findsNothing,
      reason: '「还在取」被渲染成了「这份卷子是空的」—— 用户就是这么被告知资料生成失败的',
    );
    expect(
      find.byType(CircularProgressIndicator),
      findsWidgets,
      reason: '加载中必须看得见，否则页面是一片空白',
    );
  });

  testWidgets('闸门放开之后，题目真的渲染出来（负对照）', (tester) async {
    final repo = _GatedReview();
    await install(tester, repo);
    await tester.pumpWidget(
      const GetMaterialApp(home: ReviewPaperPage(paperId: 'rp_load')),
    );
    await tester.pump();

    repo.gate.complete([
      ReviewPaperItem(
        id: 'rpi_1',
        paperId: 'rp_load',
        mistakeId: '', // 不取图：这里只验题目什么时候出现
        questionTitle: '分数加法第 1 题',
        questionBody: r'计算 $\frac{1}{2}+\frac{1}{3}$',
        sortOrder: 0,
      ),
    ]);
    await tester.pump();
    await tester.pump();

    expect(find.text('分数加法第 1 题'), findsWidgets);
    expect(find.text('这份资料还没有题目'), findsNothing);
  });
}

/// 只钉 `queryReviewPaperItems`（可卡住），其余一律报错。
///
/// 用 `noSuchMethod` 兜底而不是逐个实现：这份接口有四十来个成员，
/// 逐个写会让「这个替身到底替了什么」淹没在样板代码里。
class _GatedReview implements ReviewRepository {
  final Completer<List<ReviewPaperItem>> gate = Completer();

  /// 页面有没有真的来问题目 —— 不问的话，第一条用例的断言就是空转的绿。
  bool itemsAsked = false;

  @override
  Future<List<ReviewPaperItem>> queryReviewPaperItems(String paperId) {
    itemsAsked = true;
    return gate.future;
  }

  @override
  Future<List<ReviewMistakeImage>> queryMistakeImages(String mistakeId) async =>
      const <ReviewMistakeImage>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '测试替身没有实现 ${invocation.memberName}',
  );
}
