import 'package:easy_learn_app/models/daily_comment_model.dart';
import 'package:easy_learn_app/widgets/parent_comment_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「家长点评」卡片的**日期语义**（2026-10-27 用户报的 bug）。
///
/// 症状：家长点评卡片在任何一天打开，显示的都是"最近那条"，
/// 而它可能是几天前写的 —— 界面从不标日期，读起来就像"今天的点评"。
///
/// 判据（两条必须同时成立）：
/// ① 今天写的 → 右边是「今天 HH:mm」；
/// ② 几天前写的 → 右边是完整日期（含年月日），并且**全卡不出现「今天」**。
/// 只断①的话，旧点评照样可能被写成「今天」；只断②的话，卡片完全
/// 不显示时间也能过 —— 那正是 bug 现在的样子。
void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

  DailyCommentModel commentAt(DateTime createdAt) => DailyCommentModel(
        id: 'dc_1',
        rating: '非常优秀',
        content: '今天专注度不错，继续保持。',
        createdAt: createdAt,
        studentId: 'stu_001',
      );

  testWidgets('今天写的点评 → 标「今天 HH:mm」', (tester) async {
    final now = DateTime(2026, 10, 27, 19, 34);

    await tester.pumpWidget(
      wrap(ParentCommentCard(
        comment: commentAt(DateTime(2026, 10, 27, 19, 43)),
        now: now,
      )),
    );

    expect(find.text('今天 19:43'), findsOneWidget);
    expect(find.text('非常优秀'), findsOneWidget);
  });

  testWidgets('几天前写的点评 → 标完整日期，不能出现「今天」', (tester) async {
    final now = DateTime(2026, 10, 27, 19, 34);

    await tester.pumpWidget(
      wrap(ParentCommentCard(
        comment: commentAt(DateTime(2026, 10, 20, 13, 56)),
        now: now,
      )),
    );

    expect(find.text('2026-10-20 13:56'), findsOneWidget);
    // 只判「有没有形如『今天 19:43』的时间标签」—— 正文里出现「今天」
    // 是正常的，拿 `textContaining('今天')` 判会把正文也算进来（假红）。
    final todayStamp = RegExp(r'^今天 \d{1,2}:\d{2}$');
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && todayStamp.hasMatch((w.data ?? '').trim()),
      ),
      findsNothing,
      reason: '旧点评被标成「今天」正是用户报的那个 bug',
    );
  });

  group('stampFor 边界', () {
    test('昨天 23:59 不是今天（按本地日判，不按 24 小时差）', () {
      final now = DateTime(2026, 10, 27, 9, 0);
      expect(
        ParentCommentCard.stampFor(DateTime(2026, 10, 26, 23, 59), now),
        '2026-10-26 23:59',
      );
    });

    test('今天 00:01 算今天', () {
      final now = DateTime(2026, 10, 27, 19, 34);
      expect(
        ParentCommentCard.stampFor(DateTime(2026, 10, 27, 0, 1), now),
        '今天 00:01',
      );
    });
  });
}
