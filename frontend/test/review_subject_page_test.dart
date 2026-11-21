import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/models/homework_image_model.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/pages/parent/review_subject_page.dart';
import 'package:easy_learn_app/widgets/review_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 学科错题详情页：只显示这一科、分段、排序、只读。
///
/// 为什么值得单独测：色块上写着「数学 87」，点进去却混进语文的题，或者
/// 只显示最新的 10 道 —— 这两种都不报错，家长只会觉得「数字是假的」。
void main() {
  ReviewMistake mistake({
    required String id,
    String subject = '数学',
    ReviewState state = ReviewState.pending,
    int wrongCount = 1,
    bool masteredBySelf = false,
    String title = '题目',
    MistakeSource sourceType = MistakeSource.manual,
  }) {
    return ReviewMistake(
      id: id,
      subject: subject,
      title: title,
      originalAnswer: '',
      wrongReason: '',
      createdAt: DateTime(2026, 11, 15),
      state: state,
      wrongCount: wrongCount,
      masteredBySelf: masteredBySelf,
      sourceType: sourceType,
    );
  }

  Future<void> pumpPage(
    WidgetTester tester,
    List<ReviewMistake> items, {
    String subject = '数学',
  }) async {
    Get.put<ParentController>(_StubParentController(items));
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 1600);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: ReviewSubjectPage(subject: subject)),
    );
    await tester.pump();
  }

  tearDown(Get.reset);

  testWidgets('只显示这一科的错题，别的科不串进来', (tester) async {
    await pumpPage(tester, [
      mistake(id: 'm_math', subject: '数学', title: '数学题'),
      mistake(id: 'm_chinese', subject: '语文', title: '语文题'),
    ]);

    expect(find.text('数学 · 错题'), findsOneWidget);
    expect(find.byKey(const Key('review_subject_mistake_m_math')), findsOneWidget);
    expect(
      find.byKey(const Key('review_subject_mistake_m_chinese')),
      findsNothing,
    );
  });

  testWidgets('白名单外的科目归到「其他」，点进来能看到它', (tester) async {
    await pumpPage(
      tester,
      [mistake(id: 'm_science', subject: '科学', title: '科学题')],
      subject: '其他',
    );

    expect(find.byKey(const Key('review_subject_mistake_m_science')), findsOneWidget);
  });

  testWidgets('待复习与已掌握分开两段，不混排', (tester) async {
    await pumpPage(tester, [
      mistake(id: 'm_pool', title: '还在池里的题'),
      mistake(id: 'm_done', state: ReviewState.mastered, title: '已经掌握的题'),
      mistake(id: 'm_self', state: ReviewState.mastered, masteredBySelf: true),
    ]);

    expect(
      find.descendant(
        of: find.byType(ReviewSectionHeader),
        matching: find.text('待复习'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ReviewSectionHeader),
        matching: find.text('已掌握'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('review_subject_mistake_m_pool')), findsOneWidget);
    expect(find.byKey(const Key('review_subject_mistake_m_done')), findsOneWidget);
    expect(find.byKey(const Key('review_subject_mistake_m_self')), findsOneWidget);
  });

  testWidgets('错得多的排在前面（不是按录入时间）', (tester) async {
    await pumpPage(tester, [
      mistake(id: 'm_once', title: '只错一次', wrongCount: 1),
      mistake(id: 'm_many', title: '错了五次', wrongCount: 5),
    ]);

    final many = tester.getTopLeft(
      find.byKey(const Key('review_subject_mistake_m_many')),
    );
    final once = tester.getTopLeft(
      find.byKey(const Key('review_subject_mistake_m_once')),
    );
    expect(many.dy, lessThan(once.dy));
  });

  testWidgets('自评掌握要说清楚「不计入掌握率」', (tester) async {
    await pumpPage(tester, [
      mistake(id: 'm_self', state: ReviewState.mastered, masteredBySelf: true),
    ]);

    expect(find.textContaining('孩子自评'), findsWidgets);
    expect(find.textContaining('不计入掌握率'), findsOneWidget);
  });

  testWidgets('汇总条与色块同源：待复习 / 已掌握 / 累计错', (tester) async {
    await pumpPage(tester, [
      mistake(id: 'a', wrongCount: 2),
      mistake(id: 'b', wrongCount: 3),
      mistake(id: 'c', state: ReviewState.mastered),
    ]);

    // 待复习 2、已掌握 1、累计错 2+3+1=6
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('6'), findsOneWidget);
  });

  testWidgets('这一科没有错题时给空态，不画空白页', (tester) async {
    await pumpPage(tester, [mistake(id: 'm_chinese', subject: '语文')]);

    expect(find.textContaining('这一科目前没有错题'), findsOneWidget);
    expect(find.byType(ReviewSectionHeader), findsNothing);
  });

  testWidgets('只读：没有任何改错题状态的按钮', (tester) async {
    await pumpPage(tester, [mistake(id: 'm1')]);

    expect(find.text('标记掌握'), findsNothing);
    expect(find.text('重新组卷'), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
  });

  testWidgets('有试卷导入的题时，汇总条说清有几道', (tester) async {
    await pumpPage(tester, [
      mistake(id: 'm_exam1', sourceType: MistakeSource.imaExam),
      mistake(id: 'm_exam2', sourceType: MistakeSource.imaExam),
      mistake(id: 'm_plain'),
    ]);

    expect(find.textContaining('其中 2 道来自考试卷导入'), findsOneWidget);
  });

  testWidgets('没有试卷导入的题时不写「0 道」——那会像导入失败', (tester) async {
    await pumpPage(tester, [mistake(id: 'm_plain')]);

    expect(find.textContaining('来自考试卷导入'), findsNothing);
  });
}

class _StubParentController extends ParentController {
  _StubParentController(List<ReviewMistake> items) {
    mistakesOverride.assignAll(items);
  }

  final mistakesOverride = <ReviewMistake>[].obs;

  // 与 `parent_answer_photos_test.dart` 同一条理由：`onInit` 会触发真读库，
  // 判据里不需要，也不该在假时钟里跑。
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  List<ReviewMistake> get visibleMistakes => mistakesOverride;

  @override
  List<HomeworkImageModel> answerPhotosOfMistake(String mistakeId) => const [];
}
