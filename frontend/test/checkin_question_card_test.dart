import 'package:easy_learn_app/services/checkin_question_parser.dart';
import 'package:easy_learn_app/widgets/checkin_question_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「答题时看不到答案」的判据。
///
/// 题目从服务端下来是**带答案**的（交卷时本机立刻判对错要用）。所以
/// 「孩子看不到答案」不再由接口保证，只能由渲染层保证 —— 这个文件就是那道闸。
///
/// 判据的构造方式：给题目塞一段**只可能来自解析**的文字。题干和选项里都没有
/// 这个词，界面上只要出现它，就一定是有人把解析画出来了。
///
/// ⚠️ 不要用「答案字母 C 不该出现」当判据：选项标签本身就是 A/B/C/D，
///    `C` 必然在界面上。那是假判据，永远会红或者永远会绿。
void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('答题卡只渲染题干与选项，解析一个字都不出现', (tester) async {
    const question = CheckinQuestion(
      stem: '下列哪个数最大？',
      options: ['1', '2', '3', '4'],
      answer: 'C',
      knowledge: '有理数比较',
      analysis: '【解析】把 3 和 4 相加得 7，故选 C',
      type: CheckinQuestionType.choice,
    );

    await tester.pumpWidget(
      wrap(
        CheckinQuestionCard(
          index: 0,
          question: question,
          picked: null,
          onPick: (_) {},
        ),
      ),
    );

    // 该在的都在
    expect(find.text('下列哪个数最大？'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.textContaining('有理数比较'), findsOneWidget);

    // 解析不能出现 —— 这是「答案看不见」的核心判据
    expect(
      find.textContaining('解析'),
      findsNothing,
      reason: '解析里写着答案，画出来就等于把答案给了孩子',
    );
    expect(find.textContaining('相加'), findsNothing);
  });

  testWidgets('判断题也不把答案（T/F）画出来', (tester) async {
    const question = CheckinQuestion(
      stem: '1 是质数。',
      options: ['正确', '错误'],
      answer: 'F',
      knowledge: '质数',
      type: CheckinQuestionType.judge,
    );

    await tester.pumpWidget(
      wrap(
        CheckinQuestionCard(
          index: 0,
          question: question,
          picked: null,
          onPick: (_) {},
        ),
      ),
    );

    // 判断题渲染成「正确 / 错误」两行；判定值 T/F 是内部表示，不该露面。
    expect(find.textContaining('T'), findsNothing);
    expect(find.textContaining('F'), findsNothing);
    expect(find.textContaining('错误'), findsWidgets);
  });

  testWidgets('点选项仍然能用（别为了藏答案把交互改坏）', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      wrap(
        CheckinQuestionCard(
          index: 0,
          question: const CheckinQuestion(
            stem: '题',
            options: ['1', '2'],
            answer: 'B',
            knowledge: '',
            type: CheckinQuestionType.choice,
          ),
          picked: null,
          onPick: calls.add,
        ),
      ),
    );

    await tester.tap(find.text('B'));
    await tester.pump();

    expect(calls, ['B']);
  });
}
