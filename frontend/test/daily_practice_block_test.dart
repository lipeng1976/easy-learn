import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/checkin_entry_state.dart';
import 'package:easy_learn_app/models/checkin_models.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/services/checkin_question_parser.dart';
import 'package:easy_learn_app/services/http_checkin_repository.dart';
import 'package:easy_learn_app/widgets/daily_practice_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';

/// 学生端计划页「今日打卡」= **一个大方块**，里面逐行列出几件小练。
///
/// 虫子原话（2026-11-12 晚）：
/// 「刚刚生成的题目，在计划标签页里放在每日概念打卡下方，这里和每日概念打卡
///   一样都是花几分钟做的小练习，可以放在一起，例如一个大方块，里面列出这些
///   训练项。」
///
/// 这几条判据盯的是**孩子看不看得见**，不是代码里有没有：
///   · 三件小练必须同时出现在同一块卡里；
///   · 家长刚出的那份题必须挂在「每日概念打卡」下面 —— 只给「待完成 2 份」
///     的数字，孩子还得点进去才知道是哪两科；
///   · 本地模式（没登录云）不画概念打卡那一行 —— 一个点了才说「要联网」的
///     入口比没有更糟。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Get.testMode = true;
    Get.put(AuthController()).currentUser.value = UserModel(
      id: 'stu_001',
      name: '林小宇',
      phone: '13800000001',
      role: 'student',
      avatar: '',
    );
    registerStubDrillController();
    registerStubWordDrillController();
  });

  tearDown(Get.reset);

  /// 造一份打卡卷。题目内容不重要（这一层只显示科目与题量），
  /// 但 `total` 来自题目数，所以不能给空数组。
  CheckinQuiz quiz(
    String subject, {
    int count = 5,
    String date = '2026-11-12',
    String difficulty = '',
  }) =>
      CheckinQuiz(
        id: 'ck_$subject$count$date',
        studentId: 'stu_001',
        quizDate: date,
        subject: subject,
        difficulty: difficulty,
        questions: [
          for (var i = 0; i < count; i++)
            CheckinQuestion(
              stem: '第 ${i + 1} 题',
              options: const ['1', '2', '3', '4'],
              answer: 'A',
              knowledge: '有理数',
              type: CheckinQuestionType.choice,
            ),
        ],
      );

  /// 一个**只用于渲染**的入口状态：不调 load（假库里没有云），直接给值。
  CheckinEntryState entryWith({
    required List<CheckinQuiz> pending,
    int total = 3,
  }) {
    final entry = CheckinEntryState(repository: const UnavailableCheckinRepository());
    entry.progressByStudent['stu_001'] =
        CheckinProgress(pending: pending.length, total: total);
    entry.pendingByStudent['stu_001'] = pending;
    return entry;
  }

  Future<void> pumpBlock(WidgetTester tester, {required Widget block}) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ListView(children: [block]))),
    );
    await tester.pump();
  }

  testWidgets('三件小练在同一个方块里（各占一行，不是三张卡）', (tester) async {
    await pumpBlock(
      tester,
      block: DailyPracticeBlock(
        entry: entryWith(pending: const []),
        isCloud: true,
      ),
    );

    expect(find.text('今日打卡'), findsOneWidget);
    expect(find.text('每日概念打卡'), findsOneWidget);
    expect(find.text('今日概念训练'), findsOneWidget);
    expect(find.text('英语单词打卡'), findsOneWidget);
    // 一整块：三行都在同一个 Card 里（三张卡时这里会是 3 个）。
    expect(
      find.descendant(
        of: find.byType(DailyPracticeBlock),
        matching: find.byType(Card),
      ),
      findsOneWidget,
      reason: '「一个大方块」就是说这些训练项共享一张卡',
    );
  });

  testWidgets('刚出的题挂在「每日概念打卡」下面，一行一份', (tester) async {
    await pumpBlock(
      tester,
      block: DailyPracticeBlock(
        entry: entryWith(
          pending: [
            quiz('数学', count: 5, difficulty: '基础'),
            quiz('英语', count: 3),
          ],
        ),
        isCloud: true,
      ),
    );

    expect(find.text('待完成 2 份'), findsOneWidget);
    // 科目名 + 题量：孩子要知道「哪一科、几道题」才判断得了要不要现在做。
    expect(find.text('数学'), findsOneWidget);
    expect(find.text('英语'), findsOneWidget);
    expect(find.textContaining('共 5 题'), findsOneWidget);
    expect(find.textContaining('基础'), findsOneWidget);
    expect(find.text('去做'), findsNWidgets(2));
  });

  testWidgets('超过 3 份只列 3 行，其余折成「还有 N 份」', (tester) async {
    await pumpBlock(
      tester,
      block: DailyPracticeBlock(
        entry: entryWith(
          pending: [
            quiz('数学', count: 1, date: '2026-11-09'),
            quiz('数学', count: 2, date: '2026-11-10'),
            quiz('数学', count: 3, date: '2026-11-11'),
            quiz('数学', count: 4, date: '2026-11-12'),
            quiz('英语', count: 5),
          ],
        ),
        isCloud: true,
      ),
    );

    // 5 份里只列 3 行 —— 再多会把下面「学习计划」整区顶出屏幕。
    expect(find.text('去做'), findsNWidgets(3));
    expect(find.text('还有 2 份 ›'), findsOneWidget);
  });

  testWidgets('一份都没有时不画空行，只说「还没有题」', (tester) async {
    await pumpBlock(
      tester,
      block: DailyPracticeBlock(
        entry: entryWith(pending: const [], total: 0),
        isCloud: true,
      ),
    );

    expect(find.text('还没有题'), findsOneWidget);
    expect(find.text('去做'), findsNothing);
  });

  testWidgets('本地模式（没连云）不画概念打卡那一行，另外两件照常可用', (tester) async {
    await pumpBlock(
      tester,
      block: DailyPracticeBlock(
        entry: entryWith(pending: const []),
        isCloud: false,
      ),
    );

    expect(
      find.text('每日概念打卡'),
      findsNothing,
      reason: '本地库没有题目快照，放一个点了才说「要联网」的入口比没有更糟',
    );
    expect(find.text('今日概念训练'), findsOneWidget);
    expect(find.text('英语单词打卡'), findsOneWidget);
  });

  test('applyCounts 带明细就覆盖，不带就保留原来那份', () {
    final entry =
        CheckinEntryState(repository: const UnavailableCheckinRepository());

    entry.applyCounts(
      'stu_001',
      pending: 2,
      total: 5,
      pendingQuizzes: [quiz('数学'), quiz('英语')],
    );
    expect(entry.pendingByStudent['stu_001']!.map((one) => one.subject),
        ['数学', '英语']);

    // 老调用点（只有计数）不能把明细清空 —— 清空了计划页那几行会忽然消失，
    // 而孩子并没有做任何事。
    entry.applyCounts('stu_001', pending: 1, total: 5);
    expect(entry.pendingByStudent['stu_001']!.length, 2);
    expect(entry.progressByStudent['stu_001']!.pending, 1);

    // 带明细时是覆盖式：做完一份后那一份要从列表里消失。
    entry.applyCounts(
      'stu_001',
      pending: 1,
      total: 5,
      pendingQuizzes: [quiz('英语')],
    );
    expect(entry.pendingByStudent['stu_001']!.map((one) => one.subject),
        ['英语']);
  });
}
