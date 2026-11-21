import 'package:easy_learn_app/models/subject_mistake_summary.dart';
import 'package:easy_learn_app/widgets/subject_mistake_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 学科色块区：分块、兜底、点击语义。
///
/// 这一组盯的是「家长点下去会发生什么」和「哪一科根本不该出现」。
/// 只断言「颜色画出来了」没有意义 —— 色块画错科目、点错科目，界面照样好看。
void main() {
  SubjectMistakeSummary summary(
    String subject,
    int pool, {
    int mastered = 0,
    int self = 0,
    int wrongs = 0,
    int exams = 0,
  }) {
    return SubjectMistakeSummary(
      subject: subject,
      poolCount: pool,
      masteredCount: mastered,
      selfMasteredCount: self,
      wrongCount: wrongs,
      examCount: exams,
    );
  }

  Future<List<String>> pumpBoard(
    WidgetTester tester,
    List<SubjectMistakeSummary> items,
  ) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SubjectMistakeBoard(
              summaries: items,
              onOpen: tapped.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return tapped;
  }

  testWidgets('前 4 科是主色块，第 5 科起收成小色块', (tester) async {
    await pumpBoard(tester, [
      summary('数学', 87, mastered: 1, wrongs: 88),
      summary('英语', 10, wrongs: 10),
      summary('语文', 9, wrongs: 9),
      summary('历史', 2, wrongs: 2),
      summary('物理', 1, wrongs: 1),
    ]);

    for (final subject in ['数学', '英语', '语文', '历史']) {
      expect(
        find.byKey(Key('review_subject_tile_$subject')),
        findsOneWidget,
        reason: '$subject 应在主位',
      );
    }
    expect(find.byKey(const Key('review_subject_tile_物理')), findsNothing);
    expect(find.byKey(const Key('review_subject_chip_物理')), findsOneWidget);
    expect(find.text('物理 · 待复习 1'), findsOneWidget);
  });

  testWidgets('零错题的科目不占位 —— 不画空块、不写「暂无」', (tester) async {
    await pumpBoard(tester, [summary('数学', 3)]);

    expect(find.byKey(const Key('review_subject_tile_数学')), findsOneWidget);
    for (final subject in ['语文', '英语', '物理', '化学']) {
      expect(find.byKey(Key('review_subject_tile_$subject')), findsNothing);
      expect(find.byKey(Key('review_subject_chip_$subject')), findsNothing);
    }
  });

  testWidgets('点主色块回调的是这一科', (tester) async {
    final tapped = await pumpBoard(tester, [
      summary('数学', 87),
      summary('英语', 10),
    ]);

    await tester.tap(find.byKey(const Key('review_subject_tile_英语')));
    await tester.pump();
    expect(tapped, ['英语']);
  });

  testWidgets('点小色块同样能进详情', (tester) async {
    final tapped = await pumpBoard(tester, [
      summary('数学', 87),
      summary('英语', 10),
      summary('语文', 9),
      summary('历史', 2),
      summary('地理', 1),
    ]);

    await tester.tap(find.byKey(const Key('review_subject_chip_地理')));
    await tester.pump();
    expect(tapped, ['地理']);
  });

  testWidgets('有自评掌握时：橙点 + 副行写「（自评 N）」，不混算', (tester) async {
    await pumpBoard(tester, [
      summary('数学', 87, mastered: 3, self: 2),
    ]);

    expect(find.textContaining('已掌握 3（自评 2）'), findsOneWidget);
    // 自评不是「检查通过」——数字不能写成 3 道都是检查通过的。
    expect(find.text('已掌握 3'), findsNothing);
  });

  testWidgets('没有已掌握就不写「已掌握 0」，只留占比', (tester) async {
    await pumpBoard(tester, [
      summary('数学', 9),
      summary('英语', 1),
    ]);

    expect(find.textContaining('已掌握'), findsNothing);
    // 9 / 10 = 90%
    expect(find.text('占全部 90%'), findsOneWidget);
  });

  testWidgets('待复习 0 但已掌握的科目仍然出现（不能因为没待复习就消失）', (
    tester,
  ) async {
    await pumpBoard(tester, [summary('数学', 0, mastered: 4)]);

    expect(find.byKey(const Key('review_subject_tile_数学')), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    expect(find.textContaining('已掌握 4'), findsOneWidget);
  });

  testWidgets('块内写明「查看错题」—— 同一个色块在计划页是出题，不能让人猜', (
    tester,
  ) async {
    await pumpBoard(tester, [summary('数学', 3)]);
    expect(find.text('查看错题 ›'), findsOneWidget);
    expect(find.textContaining('出一组'), findsNothing);
  });
}
