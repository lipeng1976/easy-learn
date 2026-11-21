import 'package:easy_learn_app/services/checkin_question_parser.dart';
import 'package:easy_learn_app/widgets/checkin_preview_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 家长预览卡：**答案与解析必须画出来**。
///
/// 与 `checkin_question_card_test.dart` 是两条相反的判据，故意分开：
///
///   · 答题卡（学生）—— 一个字的解析都不能出现；
///   · 预览卡（家长）—— 必须出现，否则家长没法辅导。
///
/// 如果哪天有人把两者合并、加一个 `showAnswer` 开关，这两个文件会同时
/// 失败一次 —— 那正是提醒：这是两个组件，不是同一个组件两种模式。
void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('选择题：正确答案与解析都要出现', (tester) async {
    const question = CheckinQuestion(
      stem: '下列哪个数最大？',
      options: ['1', '2', '3', '4'],
      answer: 'C',
      knowledge: '有理数比较',
      analysis: '最大的是 4，所以选 C',
      type: CheckinQuestionType.choice,
    );

    await tester.pumpWidget(
      wrap(const CheckinPreviewCard(index: 0, question: question)),
    );

    expect(find.text('下列哪个数最大？'), findsOneWidget);
    expect(find.text('答案：C'), findsOneWidget);
    expect(find.textContaining('最大的是 4'), findsOneWidget, reason: '家长要能讲为什么');
    expect(find.textContaining('有理数比较'), findsOneWidget);
    // 正确选项上有勾，家长一眼看到是哪个
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('判断题：答案显示成「正确 / 错误」，不吐 T/F', (tester) async {
    const question = CheckinQuestion(
      stem: '1 是质数。',
      options: ['正确', '错误'],
      answer: 'F',
      knowledge: '质数',
      type: CheckinQuestionType.judge,
    );

    await tester.pumpWidget(
      wrap(const CheckinPreviewCard(index: 0, question: question)),
    );

    // T/F 是内部表示，给家长看的必须是中文
    expect(find.text('答案：错误'), findsOneWidget);
    expect(find.textContaining('T'), findsNothing);
    expect(find.textContaining('F'), findsNothing);
  });

  testWidgets('没有解析时不硬塞一个空的「解析」标题', (tester) async {
    const question = CheckinQuestion(
      stem: '题',
      options: ['1', '2'],
      answer: 'A',
      knowledge: '',
      type: CheckinQuestionType.choice,
    );

    await tester.pumpWidget(
      wrap(const CheckinPreviewCard(index: 0, question: question)),
    );

    expect(find.text('解析'), findsNothing);
    expect(find.text('答案：A'), findsOneWidget);
  });
}
