import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/models/homework_image_model.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/pages/parent/tabs/review_parent_tab.dart';
import 'package:easy_learn_app/widgets/mistake_card.dart';
import 'package:easy_learn_app/widgets/subject_mistake_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 复习页的四区结构。
///
/// 盯三件事，每一条改回去都**不会报错**：
///   ① 学科色块必须在首屏（不是被压在页面中间）；
///   ② 错题明细不再平铺在复习页（否则色块白做，页面照样很长）；
///   ③ 自评警告默认露出（藏起来就又变成静默失败）。
void main() {
  ReviewMistake mistake({
    required String id,
    String subject = '数学',
    ReviewState state = ReviewState.pending,
    int wrongCount = 1,
  }) {
    return ReviewMistake(
      id: id,
      subject: subject,
      title: '题目 $id',
      originalAnswer: '',
      wrongReason: '',
      createdAt: DateTime(2026, 11, 15),
      state: state,
      wrongCount: wrongCount,
    );
  }

  Future<void> pumpTab(
    WidgetTester tester,
    List<ReviewMistake> items, {
    Map<AttemptChannel, int> tally = const {},
  }) async {
    Get.put<ParentController>(
      _StubParentController(items, tally),
    );
    tester.view.devicePixelRatio = 1.0;
    // 400×820 ≈ 主流手机竖屏的 dp 尺寸。
    tester.view.physicalSize = const Size(400, 820);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ReviewParentTab())),
    );
    await tester.pump();
  }

  tearDown(Get.reset);

  testWidgets('学科色块在首屏内，第一行完整可见', (tester) async {
    await pumpTab(tester, [
      for (var i = 0; i < 87; i++) mistake(id: 's$i'),
      for (var i = 0; i < 10; i++) mistake(id: 'e$i', subject: '英语'),
    ]);

    final board = find.byType(SubjectMistakeBoard);
    expect(board, findsOneWidget);

    final top = tester.getTopLeft(board).dy;
    expect(top, lessThan(820), reason: '色块区整体必须在首屏');

    final firstTile = find.byKey(const Key('review_subject_tile_数学'));
    expect(firstTile, findsOneWidget);
    expect(
      tester.getBottomLeft(firstTile).dy,
      lessThan(820),
      reason: '第一块要完整露出来，不能只露一条边',
    );
  });

  testWidgets('错题明细不再平铺在复习页 —— 题目只在详情页出现', (tester) async {
    await pumpTab(tester, [
      for (var i = 0; i < 20; i++) mistake(id: 's$i'),
    ]);

    // 前置：色块确实画出来了。否则下面的 findsNothing 是空转的绿。
    expect(find.byType(SubjectMistakeBoard), findsOneWidget);
    expect(find.byType(MistakeCard), findsNothing);
    expect(find.text('错题清单'), findsNothing);
  });

  testWidgets('零错题的科目不占位，白名单外的科目进「其他」', (tester) async {
    await pumpTab(tester, [
      mistake(id: 'm1', subject: '数学'),
      mistake(id: 'm2', subject: '科学'),
    ]);

    expect(find.byKey(const Key('review_subject_tile_数学')), findsOneWidget);
    expect(find.byKey(const Key('review_subject_tile_其他')), findsOneWidget);
    expect(find.byKey(const Key('review_subject_tile_语文')), findsNothing);
    expect(find.byKey(const Key('review_subject_tile_物理')), findsNothing);
  });

  testWidgets('自评警告默认露出，不折起来', (tester) async {
    await pumpTab(
      tester,
      [mistake(id: 'm1')],
      tally: const {AttemptChannel.paper: 1, AttemptChannel.paperSelf: 2},
    );

    expect(find.byKey(const Key('review_self_assess_banner')), findsOneWidget);
    expect(find.textContaining('没有作答证据'), findsOneWidget);
  });

  testWidgets('资料与提交记录收成两行入口，数量照实写', (tester) async {
    await pumpTab(tester, [mistake(id: 'm1')]);

    expect(find.text('资料与记录'), findsOneWidget);
    expect(find.text('复习资料'), findsOneWidget);
    expect(find.text('作业提交记录'), findsOneWidget);
    // 当前没有资料也没有提交记录 —— 两行都该写 0 份，而不是藏起来。
    expect(find.text('0 份'), findsNWidgets(2));
  });

  testWidgets('一题都没有时给空态，并且不画空色块', (tester) async {
    await pumpTab(tester, const []);

    expect(find.byType(SubjectMistakeBoard), findsNothing);
    expect(find.textContaining('目前没有错题记录'), findsOneWidget);
  });
}

class _StubParentController extends ParentController {
  _StubParentController(List<ReviewMistake> items, this._tally) {
    mistakesOverride.assignAll(items);
  }

  final List<ReviewMistake> mistakesOverride = [];
  final Map<AttemptChannel, int> _tally;

  // 与 `parent_answer_photos_test.dart` 同一条理由：`onInit` 会触发真读库。
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  List<ReviewMistake> get visibleMistakes => mistakesOverride;

  @override
  List<HomeworkImageModel> answerPhotosOfMistake(String mistakeId) => const [];

  @override
  Map<AttemptChannel, int> get visibleWeekChannelTally => _tally;
}
