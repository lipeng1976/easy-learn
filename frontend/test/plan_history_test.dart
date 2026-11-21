import 'package:easy_learn_app/models/study_plan_model.dart';
import 'package:easy_learn_app/models/workout_model.dart';
import 'package:easy_learn_app/pages/shared/plan_history.dart';
import 'package:easy_learn_app/pages/shared/plan_history_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 计划页的历史：**规则回放**。
///
/// 这一组的核心不是「算得对不对」，而是**算出来的东西与用户记忆不一致时，
/// 界面有没有说实话**。方案 §2.3 把这条写成了硬要求：
/// 历史是按当前规则推算的，要「在界面上诚实」，不能假装是当时的截图。
void main() {
  StudyPlanModel plan({
    String id = 'sp_1',
    String title = '每日阅读',
    WorkoutCycleType cycle = WorkoutCycleType.daily,
    List<String> weekdays = const <String>[],
    StudyPlanStatus status = StudyPlanStatus.active,
    DateTime? startAt,
    DateTime? endAt,
  }) {
    return StudyPlanModel(
      id: id,
      title: title,
      content: '每天读 20 分钟',
      startAt: startAt ?? DateTime(2026, 1, 1),
      endAt: endAt ?? DateTime(2026, 12, 31),
      type: '学习',
      status: status,
      cycleType: cycle,
      customWeekdays: weekdays,
    );
  }

  group('replayPlanHistory', () {
    test('按当前规则回放：把「每周三」改成「每天」后，周二也算「该做」', () {
      // ⭐ 这是整组的核心用例。
      // 事实是：三个月前那天**不是**周三，所以当时确实没有这条计划。
      // 但我们现在只有「当前规则」这一个真相来源，回放的结果必然是「该做」。
      // 这个不一致是**已知且接受**的取舍（Q1）—— 所以它有断言守着，
      // 而不是靠「应该没人会改周期吧」的假设。
      final changed = plan(
        // 现在的规则：每天
        cycle: WorkoutCycleType.daily,
      );
      // 2026-09-22 是周二
      final day = replayPlanHistory(
        plans: [changed],
        date: DateTime(2026, 9, 22),
        checkinKeysByPlan: const {},
      );

      expect(day.entries.single.scheduled, isTrue, reason: '每天 → 周二也算该做');
      expect(
        day.scheduledCount,
        1,
        reason: '这正是「与当时不一致」的地方：当时规则是周三，这天本不该有',
      );
    });

    test('每周规则：只在那几个星期几算该做', () {
      final weekly = plan(
        cycle: WorkoutCycleType.weekly,
        weekdays: const ['一', '三', '五'],
      );
      // 2026-09-21 周一 / 09-22 周二 / 09-23 周三
      expect(
        replayPlanHistory(
          plans: [weekly],
          date: DateTime(2026, 9, 21),
          checkinKeysByPlan: const {},
        ).hasScheduled,
        isTrue,
        reason: '周一该做',
      );
      expect(
        replayPlanHistory(
          plans: [weekly],
          date: DateTime(2026, 9, 22),
          checkinKeysByPlan: const {},
        ).hasScheduled,
        isFalse,
        reason: '周二不在执行日里',
      );
      expect(
        replayPlanHistory(
          plans: [weekly],
          date: DateTime(2026, 9, 23),
          checkinKeysByPlan: const {},
        ).hasScheduled,
        isTrue,
        reason: '周三该做',
      );
    });

    test('打卡只认**日期串相等**，不做时区换算', () {
      // `study_plan_checkin.date` 是一列 `date`，语义是「学生所在地的那一天」。
      // 一旦写成 `DateTime.parse(key).toLocal()` 再比，在 UTC-5 会挪走一天。
      final p = plan();
      final day = replayPlanHistory(
        plans: [p],
        date: DateTime(2026, 9, 20),
        checkinKeysByPlan: {
          'sp_1': {'2026-09-20'},
        },
      );
      expect(day.entries.single.checked, isTrue);
      expect(day.checkedCount, 1);
    });

    test('别的计划的打卡不会算到自己头上', () {
      final p = plan(id: 'sp_1');
      final other = plan(id: 'sp_2', title: '背单词');
      final day = replayPlanHistory(
        plans: [p, other],
        date: DateTime(2026, 9, 20),
        checkinKeysByPlan: {
          'sp_1': {'2026-09-20'},
          'sp_2': const <String>{},
        },
      );
      final byId = {for (final e in day.entries) e.plan.id: e};
      expect(byId['sp_1']!.checked, isTrue);
      expect(byId['sp_2']!.checked, isFalse, reason: '各算各的');
      expect(day.checkedCount, 1);
    });

    test('计划没开始 / 已结束 → 那天不算该做', () {
      // 这条是**反面判据**：没有它，「回放」很容易退化成「只要有计划就算」。
      final future = plan(
        id: 'sp_future',
        startAt: DateTime(2026, 10, 1),
        endAt: DateTime(2026, 12, 31),
      );
      final past = plan(
        id: 'sp_past',
        startAt: DateTime(2026, 1, 1),
        endAt: DateTime(2026, 6, 30),
      );
      expect(
        replayPlanHistory(
          plans: [future],
          date: DateTime(2026, 9, 22),
          checkinKeysByPlan: const {},
        ).hasScheduled,
        isFalse,
        reason: '还没开始',
      );
      expect(
        replayPlanHistory(
          plans: [past],
          date: DateTime(2026, 9, 22),
          checkinKeysByPlan: const {},
        ).hasScheduled,
        isFalse,
        reason: '已经结束',
      );
    });

    test('allChecked 只在「确实有该做的」时才为真', () {
      // 那天本来就没计划 →「全部完成」是**空真**（vacuous truth），
      // 会让界面显示一个绿色的「都做完了」，而实际是什么都没有。
      final noPlan = replayPlanHistory(
        plans: const [],
        date: DateTime(2026, 9, 22),
        checkinKeysByPlan: const {},
      );
      expect(noPlan.allChecked, isFalse, reason: '没该做的事，谈不上「都做完了」');

      final one = replayPlanHistory(
        plans: [plan()],
        date: DateTime(2026, 9, 22),
        checkinKeysByPlan: {
          'sp_1': {'2026-09-22'},
        },
      );
      expect(one.allChecked, isTrue);
    });
  });

  group('replayPlanMonth', () {
    test('只回放参数指定的那个月', () {
      final marks = replayPlanMonth(
        plans: [plan()],
        month: DateTime(2026, 9, 1),
        checkinKeysByPlan: const {},
        today: DateTime(2026, 9, 22),
      );
      expect(marks.length, 22, reason: '9 月 1 日到 9 月 22 日，一天不少');
      expect(marks.keys.every((k) => k.startsWith('2026-09-')), isTrue);
    });

    test('**未来的日子不出现**（不能凭空算出一个「欠着」）', () {
      // 「今天之后该不该做」还取决于用户之后会不会改计划 ——
      // 现在就算出来是**编造事实**，而且会显示成红色的「没打卡」。
      final marks = replayPlanMonth(
        plans: [plan()],
        month: DateTime(2026, 9, 1),
        checkinKeysByPlan: const {},
        today: DateTime(2026, 9, 22),
      );
      expect(marks.containsKey('2026-09-23'), isFalse);
      expect(marks.containsKey('2026-09-30'), isFalse);
      expect(marks.containsKey('2026-09-22'), isTrue, reason: '今天本身要算');
    });

    test('月份天数按真实日历算（9 月 30 天、2 月 28 天）', () {
      final sep = replayPlanMonth(
        plans: [plan()],
        month: DateTime(2026, 9, 1),
        checkinKeysByPlan: const {},
        today: DateTime(2026, 12, 31),
      );
      expect(sep.containsKey('2026-09-30'), isTrue);
      expect(sep.containsKey('2026-10-01'), isFalse, reason: '不跨月');

      final feb = replayPlanMonth(
        plans: [plan()],
        month: DateTime(2026, 2, 1),
        checkinKeysByPlan: const {},
        today: DateTime(2026, 12, 31),
      );
      expect(feb.containsKey('2026-02-28'), isTrue);
      expect(feb.containsKey('2026-02-29'), isFalse, reason: '2026 不是闰年');
    });

    test('没戏的日子不出现在结果里（缺席就是无打点）', () {
      // 一个只在周三执行的计划 → 9 月的周二、周四…都不该有条目。
      final marks = replayPlanMonth(
        plans: [
          plan(cycle: WorkoutCycleType.weekly, weekdays: const ['三']),
        ],
        month: DateTime(2026, 9, 1),
        checkinKeysByPlan: const {},
        today: DateTime(2026, 9, 30),
      );
      // 2026-09-23 是周三，2026-09-22 是周二
      expect(marks.containsKey('2026-09-23'), isTrue);
      expect(marks.containsKey('2026-09-22'), isFalse);
    });

    test('missed / allDone 编码「欠着」与「做完了」', () {
      final marks = replayPlanMonth(
        plans: [plan()],
        month: DateTime(2026, 9, 1),
        checkinKeysByPlan: {
          'sp_1': {'2026-09-21', '2026-09-22'},
        },
        today: DateTime(2026, 9, 22),
      );
      expect(marks['2026-09-22']!.allDone, isTrue);
      expect(marks['2026-09-22']!.missed, isFalse);
      expect(marks['2026-09-20']!.missed, isTrue, reason: '该做但没打卡');
      expect(marks['2026-09-20']!.hasAny, isTrue);
    });
  });

  group('PlanHistorySection 文案（**诚实的判据**）', () {
    Future<void> pump(
      WidgetTester tester, {
      required DateTime date,
      required DateTime today,
      List<StudyPlanModel> plans = const [],
      Map<String, Set<String>> checkins = const {},
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanHistorySection(
              day: replayPlanHistory(
                plans: plans,
                date: date,
                checkinKeysByPlan: checkins,
              ),
              today: today,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('历史日期**显式说明**「按当前计划推算」', (tester) async {
      await pump(
        tester,
        date: DateTime(2026, 6, 10),
        today: DateTime(2026, 9, 22),
        plans: [plan()],
      );
      expect(
        find.text('历史按当前计划推算，与当时可能不同'),
        findsOneWidget,
        reason: '方案 §2.3 与 Q1：不一致是接受的，但**必须让用户看得见**',
      );
    });

    testWidgets('今天**不出现**那句免责声明', (tester) async {
      // 今天就是当下的规则，没有「推算」这回事。
      // 每处都加会把真正需要看清的那一行淹掉 —— 免责声明加多了等于没有。
      await pump(
        tester,
        date: DateTime(2026, 9, 22),
        today: DateTime(2026, 9, 22),
        plans: [plan()],
      );
      expect(find.text('历史按当前计划推算，与当时可能不同'), findsNothing);
      expect(find.text('今天'), findsOneWidget);
    });

    testWidgets('说的是「已打卡/未打卡」（记录），不是「完成/未完成」（评价）', (tester) async {
      // 我们只知道「有没有那条打卡记录」，不知道学生那天是不是真的做了
      // —— 他可能只是忘了点。界面用「完成」是把推测说成了事实。
      await pump(
        tester,
        date: DateTime(2026, 9, 21),
        today: DateTime(2026, 9, 22),
        plans: [plan()],
        checkins: {
          'sp_1': {'2026-09-21'},
        },
      );
      expect(find.text('已打卡'), findsOneWidget);
      expect(find.text('完成'), findsNothing);
      expect(find.text('未完成'), findsNothing);
    });

    testWidgets('没该做计划的那天 → 空态是一句话，不是空白', (tester) async {
      await pump(
        tester,
        date: DateTime(2026, 6, 10),
        today: DateTime(2026, 9, 22),
        // 计划从 10 月才开始
        plans: [
          plan(startAt: DateTime(2026, 10, 1), endAt: DateTime(2026, 12, 31)),
        ],
      );
      expect(find.text('这天没有需要执行的计划'), findsOneWidget);
    });

    testWidgets('有该做但没打卡 → 逐条列出且标「未打卡」', (tester) async {
      await pump(
        tester,
        date: DateTime(2026, 9, 21),
        today: DateTime(2026, 9, 22),
        plans: [plan(title: '每日阅读')],
      );
      expect(find.text('该做 1 项，已打卡 0 项'), findsOneWidget);
      expect(find.text('每日阅读'), findsOneWidget);
      expect(find.text('未打卡'), findsOneWidget);
    });

    testWidgets('不只看数字：该做的每条都列出来', (tester) async {
      await pump(
        tester,
        date: DateTime(2026, 9, 21),
        today: DateTime(2026, 9, 22),
        plans: [
          plan(id: 'sp_1', title: '每日阅读'),
          plan(id: 'sp_2', title: '背单词'),
        ],
        checkins: {
          'sp_2': {'2026-09-21'},
        },
      );
      expect(find.text('该做 2 项，已打卡 1 项'), findsOneWidget);
      expect(find.text('每日阅读'), findsOneWidget);
      expect(find.text('背单词'), findsOneWidget);
      expect(find.text('已打卡'), findsOneWidget);
      expect(find.text('未打卡'), findsOneWidget);
    });
  });

  group('planCheckinDateKeys', () {
    test('汇总所有计划的打卡日期并去重排序', () {
      final keys = planCheckinDateKeys(
        [plan(id: 'sp_1'), plan(id: 'sp_2')],
        {
          'sp_1': {'2026-09-22', '2026-09-20'},
          'sp_2': {'2026-09-21', '2026-09-20'},
        },
      );
      expect(keys, ['2026-09-20', '2026-09-21', '2026-09-22']);
    });

    test('没有打卡 → 空列表', () {
      expect(planCheckinDateKeys([plan()], const {}), isEmpty);
    });
  });
}
