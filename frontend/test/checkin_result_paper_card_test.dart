import 'package:easy_learn_app/constants/app_colors.dart';
import 'package:easy_learn_app/services/checkin_question_parser.dart';
import 'package:easy_learn_app/widgets/checkin_result_paper_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

CheckinQuestion _choice({
  required String answer,
  String? analysis,
}) =>
    CheckinQuestion(
      stem: r'若 $a>0$，则 $\frac{a}{2}$ 是正数',
      options: ['2', '4', '6'],
      answer: answer,
      knowledge: r'偶数定义 $\frac{a}{2}\in\mathbb{Z}$',
      analysis: analysis,
      type: CheckinQuestionType.choice,
    );

CheckinQuestion _judge(String answer) => CheckinQuestion(
      stem: '三角形的内角和是 180 度',
      options: const ['正确', '错误'],
      answer: answer,
      knowledge: '内角和',
      analysis: '平面几何基本定理',
      type: CheckinQuestionType.judge,
    );

/// 选项行是带边框的 Container；正确项绿边、选错项红边、其它默认灰边。
/// 用边框颜色把这两种「高亮」抓出来，避免靠文字猜。
bool _borderColorIs(Widget w, Color c) {
  if (w is Container && w.decoration is BoxDecoration) {
    final border = (w.decoration as BoxDecoration).border;
    if (border is Border) return border.top.color == c;
  }
  return false;
}

Finder _optionWith(Color c) =>
    find.byWidgetPredicate((w) => _borderColorIs(w, c));

void main() {
  testWidgets('选择题答对：正确项绿色，没有浅红项', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CheckinResultPaperCard(
            index: 0,
            question: _choice(answer: 'B'),
            picked: 'B',
            correct: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 正确项（B）绿色高亮。
    expect(_optionWith(AppColors.success), findsOneWidget,
        reason: '答对的题：正确选项必须绿色');
    // 没有选错的浅红项（选中的就是正确答案）。
    expect(_optionWith(AppColors.danger), findsNothing,
        reason: '答对的题不该出现浅红项');
    expect(find.text('你的答案：B'), findsOneWidget);
    // 答对了就不该再补「正确答案」那一行（避免重复）。
    expect(find.textContaining('正确答案'), findsNothing);
  });

  testWidgets('选择题答错：选中的项浅红，正确项绿色', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CheckinResultPaperCard(
            index: 0,
            question: _choice(answer: 'B'),
            picked: 'A',
            correct: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 正确项 B 仍是绿色（和推给家长的试卷一致）。
    expect(_optionWith(AppColors.success), findsOneWidget,
        reason: '答错的题：标准答案必须绿色');
    // 学生选错的 A 是浅红。
    expect(_optionWith(AppColors.danger), findsOneWidget,
        reason: '答错的题：学生选中的那项必须浅红');
    expect(find.text('你的答案：A'), findsOneWidget);
    expect(find.text('正确答案：B'), findsOneWidget);
  });

  testWidgets('判断题答错：选「正确」浅红，标准答案「错误」绿色', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CheckinResultPaperCard(
            index: 0,
            question: _judge('F'),
            picked: 'T',
            correct: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_optionWith(AppColors.success), findsOneWidget,
        reason: '标准答案「错误」必须绿色');
    expect(_optionWith(AppColors.danger), findsOneWidget,
        reason: '学生选的「正确」必须浅红');
    expect(find.text('你的答案：正确'), findsOneWidget);
    expect(find.text('正确答案：错误'), findsOneWidget);
  });

  testWidgets('含解析时解析块要渲染', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CheckinResultPaperCard(
            index: 0,
            question: _choice(answer: 'B', analysis: '因为 2×2=4'),
            picked: 'B',
            correct: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('解析'), findsOneWidget);
    expect(find.text('因为 2×2=4'), findsOneWidget);
  });
}
