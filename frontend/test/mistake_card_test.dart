import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/pages/student/widgets/mistake_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 错题卡的**内容与入口**判据。
///
/// 两个页面共用这张卡（复习页的待复习列表、某次作业的错题），
/// 所以这里盯的是「卡上有没有该有的东西」和「点得到不到位」——
/// 而不是某个页面的布局。
void main() {
  ReviewMistake mistake({
    String homeworkTitle = '口算20题',
    String questionNo = '20(4)',
  }) => ReviewMistake(
    id: 'm_card',
    subject: '数学',
    title: '列代数式（分段计费）',
    originalAnswer: '2x',
    wrongReason: '第二空列式错误：常数项和符号都不对。',
    createdAt: DateTime(2020, 3, 5, 9),
    state: ReviewState.pending,
    studentId: 'stu_001',
    knowledgePoint: '列代数式',
    // 原卷面题号：家长要对着作业本找这道题时唯一的可靠定位。
    questionNo: questionNo,
    wrongCount: 2,
    sourceHomeworkTitle: homeworkTitle,
  );

  Future<void> pumpCard(
    WidgetTester tester, {
    required ReviewMistake item,
    VoidCallback? onExplain,
    VoidCallback? onPractice,
    VoidCallback? onMarkMastered,
    VoidCallback? onEdit,
    VoidCallback? onDelete,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MistakeCard(
              mistake: item,
              onExplain: onExplain ?? () {},
              onPractice: onPractice ?? () {},
              onMarkMastered: onMarkMastered ?? () {},
              onEdit: onEdit ?? () {},
              onDelete: onDelete ?? () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('卡片上有日期（跨年显示到年）', (tester) async {
    await pumpCard(tester, item: mistake());

    // 2020 年距今超过一年 ⇒ 必须带年份，避免「3月5日」被误读成今年。
    expect(
      find.textContaining('2020年3月5日'),
      findsOneWidget,
      reason: '错题卡上没有日期 —— 学生判断不出这是不是今天那次作业的错题',
    );
  });

  testWidgets('元信息与错因都在卡上，来源作业没丢', (tester) async {
    await pumpCard(tester, item: mistake());

    expect(find.textContaining('数学 · 列代数式'), findsOneWidget);
    expect(
      find.textContaining('第 20(4) 题'),
      findsOneWidget,
      reason: '卡片上没有原题号 —— 家长只能拿着知识点从头翻作业本',
    );
    expect(find.textContaining('来自《口算20题》'), findsOneWidget);
    expect(find.textContaining('错因：第二空列式错误'), findsOneWidget);
    expect(find.textContaining('错 2 次'), findsOneWidget);
  });

  testWidgets('点整张卡片就进详情（不用先找按钮）', (tester) async {
    var explained = 0;
    await pumpCard(tester, item: mistake(), onExplain: () => explained++);

    await tester.tap(find.text('列代数式（分段计费）'));
    await tester.pump();

    expect(explained, 1, reason: '点卡片没有进详情：用户想「看看错在哪」时还得找按钮');
  });

  testWidgets('「举一反三」与溢出菜单各自接对动作', (tester) async {
    var practiced = 0;
    var edited = 0;
    var deleted = 0;
    var mastered = 0;
    await pumpCard(
      tester,
      item: mistake(),
      onPractice: () => practiced++,
      onEdit: () => edited++,
      onDelete: () => deleted++,
      onMarkMastered: () => mastered++,
    );

    await tester.tap(find.text('举一反三'));
    await tester.pump();
    expect(practiced, 1);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(edited, 1);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(deleted, 1);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标记掌握（自评）'));
    await tester.pumpAndSettle();
    expect(mastered, 1);
  });

  testWidgets('没有来源作业时不留一个空的「来自《》」', (tester) async {
    await pumpCard(tester, item: mistake(homeworkTitle: ''));

    expect(find.textContaining('来自《'), findsNothing);
    expect(find.textContaining('数学 · 列代数式'), findsOneWidget);
  });

  testWidgets('没有原题号时不印一个空的「第  题」', (tester) async {
    await pumpCard(tester, item: mistake(questionNo: ''));

    // 老错题（这一列 2026-10-21 才加）题号是空的，空着就整段不显示 ——
    // 印一个「第  题」比不印更让人困惑。
    // ⚠️ 不能只找「第」：错因里就有「第二空列式错误」。
    expect(find.textContaining('第  题'), findsNothing);
    expect(find.textContaining('列代数式 · 来自《'), findsOneWidget);
  });
}
