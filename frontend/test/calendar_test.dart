import 'package:easy_learn_app/constants/app_colors.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/models/study_plan_checkin_model.dart';
import 'package:easy_learn_app/models/workout_model.dart';
import 'package:easy_learn_app/services/calendar_summary_service.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/widgets/day_calendar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 日历：`WeekStrip` / `MonthPickerSheet` / 月摘要。
///
/// ## 这个文件防的是什么
///
/// 起因是虫子的一条体验问题：「首页作业、运动、计划那里，日历只有当周的，
/// 没法查历史」。修法分三层，每一层都有一个**安静的坏法**，所以三层都要判据：
///
/// ① **周历的选中态**。原先三份拷贝里，`homework_tab` 那份把选中日期
///    写成 `static final Rx<DateTime>` —— 跨实例共享的全局态。
///    坏法是「单独跑绿、一起跑红」，以及两个孩子的页面互相污染。
///    → 判据：**两个实例各自选中不同日期，互不影响**。
///
/// ② **周历显示哪一周**。原先锚在 `today`，所以从月历选了 3 个月前的某天之后，
///    那 7 格里**一格都没亮**（选中的日子不在本周）。
///    坏法是「点了日期，界面没反应」—— 而它看起来像「点没点中」，不像 bug。
///    → 判据：**选中 90 天前的那天，周历里必须能看到它**。
///
/// ③ **月摘要的缓存与失败**。坏法有两个，都很安静：
///    「缓存不按学生分」→ 家长切孩子之后点**指错人**（比没有点更坏，因为它
///    看起来是有效信息）；「失败也写缓存」→ 那一次断网被记成一整个月没数据，
///    翻回来还是空的且不再重试。
///    → 判据：**切学生要重新取；失败要能重试**（两条都是「重试/重取」的方向）。
/// ## 为什么有一组 `hw()` / `wr()` / `ck()` 工厂，而不是直接 `new`
///
/// 领域模型的必填字段很多（`HomeworkItem` 有 10 个 required、`WorkoutRecord` 有 6 个），
/// 绝大多数与本文件要验的东西无关。逐处写全会让**真正的断言被噪声淹没** ——
/// 读的人得在一屏字段里找那一行 `dueAt`。
///
/// 更要紧的是：这些构造签名会变。写成工厂之后，签名变了**只改一处**；
/// 散在十几处的话，每次都会得到一屏「构造函数参数不匹配」，
/// 而修它们的时候很容易顺手把某个断言改歪。
///
/// ⚠️ 第一版我凭记忆写了 `HomeworkItem(id:, title:, subject:, dueAt:)`，
/// 编译器报了 7 个「Required named parameter must be provided」。
/// **别猜签名，去读模型文件。**
HomeworkItem hw(String id, DateTime dueAt, {String subject = '数学'}) => HomeworkItem(
      id: id,
      title: '$subject 作业',
      subject: subject,
      imageUrl: '',
      dueAt: dueAt,
      estimatedMinutes: 30,
      status: HomeworkStatus.pending,
      wrongCount: 0,
      aiEnabled: false,
      userRole: 'student',
    );

WorkoutRecord wr(String id, DateTime start, {String project = '跑步'}) => WorkoutRecord(
      id: id,
      project: project,
      start: start,
      end: start.add(const Duration(minutes: 30)),
      minutes: 30,
      feedback: '',
    );

StudyPlanCheckin ck(String id, String date) => StudyPlanCheckin(
      id: id,
      planId: 'plan_$id',
      studentId: 'stu_1',
      date: date,
      createdAt: DateTime(2026, 1, 1),
    );

void main() {
  Get.testMode = true;

  // ⭐ 固定「今天」，否则断言随运行日期漂。
  // 挑 2026-09-22（周二）—— 与项目里其他的日期用例同一天。
  final today = DateTime(2026, 9, 22);

  group('DayUtil', () {
    test('isSameDay 按本地日判断，不受时分秒影响', () {
      expect(
        DayUtil.isSameDay(DateTime(2026, 9, 22, 0, 0), DateTime(2026, 9, 22, 23, 59)),
        isTrue,
      );
      expect(DayUtil.isSameDay(DateTime(2026, 9, 22), DateTime(2026, 9, 23)), isFalse);
    });

    test('dayKey / monthKey 是补零的本地日', () {
      expect(DayUtil.dayKey(DateTime(2026, 9, 2)), '2026-09-02');
      expect(DayUtil.monthKey(DateTime(2026, 9, 22)), '2026-09');
      expect(DayUtil.monthKey(DateTime(2026, 12, 31)), '2026-12');
    });

    test('localDayWindow 是 [当天 00:00, 次日 00:00) 的 UTC 瞬时', () {
      final w = DayUtil.localDayWindow(DateTime(2026, 9, 22, 15, 30));
      // 起点必须是那天 00:00（而不是 15:30）—— 否则「某一天的记录」
      // 会从下午三点半才开始，上午的记录取不到。
      final localFrom = w.from.toLocal();
      expect([localFrom.hour, localFrom.minute, localFrom.second], [0, 0, 0]);
      expect(DayUtil.isSameDay(localFrom, DateTime(2026, 9, 22)), isTrue);

      final localTo = w.to.toLocal();
      expect(DayUtil.isSameDay(localTo, DateTime(2026, 9, 23)), isTrue);

      // 右开：to 是**次日**零点。传「当天 23:59:59」会让
      // 23:59:59.500 这种记录丢掉（精度）。
      expect(w.to.difference(w.from).inHours, 24);
    });

    test('daysInMonth 处理平年/闰年/大小月', () {
      expect(DayUtil.daysInMonth(DateTime(2026, 2, 1)), 28);
      expect(DayUtil.daysInMonth(DateTime(2024, 2, 1)), 29);
      expect(DayUtil.daysInMonth(DateTime(2026, 1, 1)), 31);
      expect(DayUtil.daysInMonth(DateTime(2026, 4, 1)), 30);
    });
  });

  group('DayMarks', () {
    test('dotCount 是「有几类数据」，上限 3', () {
      expect(const DayMarks().dotCount, 0);
      expect(const DayMarks(homework: 5).dotCount, 1);
      expect(const DayMarks(homework: 1, workout: 1).dotCount, 2);
      expect(const DayMarks(homework: 1, workout: 1, checkin: 1).dotCount, 3);
      // 计数再多也只有 3 个点 —— 4 个点在 44dp 宽的格子里会糊成一团。
      expect(const DayMarks(homework: 9, workout: 9, checkin: 9).dotCount, 3);
    });

    test('isEmpty 只要有一类就为 false', () {
      expect(const DayMarks().isEmpty, isTrue);
      expect(const DayMarks(checkin: 1).isEmpty, isFalse);
    });

    test('fromJson 缺字段按 0 处理（摘要只回有数据的天）', () {
      final m = DayMarks.fromJson({'date': '2026-09-22', 'homework': 3});
      expect(m.homework, 3);
      expect(m.workout, 0, reason: '响应里没有 workout 键时按 0，不能抛');
      expect(m.checkin, 0);
    });

    test('fromJson 容忍 num（JSON 里 3 与 3.0 都会出现）', () {
      expect(DayMarks.fromJson({'homework': 3.0}).homework, 3);
    });
  });

  group('WeekStrip', () {
    /// 渲染周历并返回「亮着的日期（几号）」。
    Future<List<int>> pumpStrip(
      WidgetTester tester, {
      required DateTime selected,
      Map<String, DayMarks>? marks,
      VoidCallback? onPickMonth,
    }) async {
      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: WeekStrip(
              selectedDate: selected,
              today: today,
              onDateSelected: (_) {},
              marks: marks,
              onPickMonth: onPickMonth,
            ),
          ),
        ),
      );
      await tester.pump();

      // 选中格的底色是 AppColors.primary。
      //
      // ⚠️ 这里的累加器**不能叫 `selected`** —— 外层形参就叫 `selected`（DateTime），
      // 内层同名会把外层的遮蔽掉，于是 `lit.add(n)` 变成 `DateTime.add(Duration)`、
      // `return lit` 变成「返回 DateTime 但声明是 Future<List<int>>」。
      // 报错信息（"argument type 'int' can't be assigned to 'Duration'"）指的方向
      // 与真实原因（变量遮蔽）差得很远，值得记一笔。
      final lit = <int>[];
      for (final cell in tester.widgetList<AnimatedContainer>(find.byType(AnimatedContainer))) {
        final deco = cell.decoration as BoxDecoration?;
        if (deco?.color == AppColors.primary) {
          // 这一格里的日期数字。
          final texts = tester
              .widgetList<Text>(
                find.descendant(
                  of: find.byWidget(cell),
                  matching: find.byType(Text),
                ),
              )
              .map((t) => t.data)
              .whereType<String>();
          for (final t in texts) {
            final n = int.tryParse(t);
            if (n != null) lit.add(n);
          }
        }
      }
      return lit;
    }

    testWidgets('显示含选中日期的那一周，且选中的那天是亮的', (tester) async {
      await pumpStrip(tester, selected: DateTime(2026, 9, 22));
      expect(find.text('22'), findsOneWidget);
      final selected = await pumpStrip(tester, selected: DateTime(2026, 9, 22));
      expect(selected, contains(22), reason: '选中的那天必须亮着');
    });

    testWidgets('选中 90 天前的那天，周历要跳到那一周（不是空亮）', (tester) async {
      // ⚠️ 这是「锚在 today」改成「锚在 selectedDate」的那条判据。
      // 原实现里 `monday = today - (weekday-1)`，所以选了 6 月 24 日之后，
      // 周历仍然显示 9 月那一周 —— **没有一格是选中的**。
      final old = DateTime(2026, 6, 24);
      final selected = await pumpStrip(tester, selected: old);
      expect(
        selected,
        contains(24),
        reason: '选中的日期不在本周时，周历必须翻到那一周 —— 否则用户看不到自己选了哪天',
      );
      // 反面：不该还停在 9 月的那一周。
      //
      // ⚠️ 判据**不能**写成 `find.text('22') == findsNothing`：
      // 6 月那一周是 06-22…06-28，**里面也有一个 22** ——
      // 那种写法会把正确实现判成失败（我第一版就是这么写的）。
      // 要区分「哪一周」只能看**同屏的日期集合**，不能看单个数字。
      //
      // 选的这两个数是算出来的，不是猜的：
      //   六月那周 = 06-22…06-28   （含 28，不含 29）
      //   九月那周 = 09-21…09-27   （含 27，不含 28）
      // 所以 28 只可能在六月这周、09-21 只可能在九月那周 —— 两边都用集合验。
      final shown = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .where((s) => int.tryParse(s) != null)
          .toList();
      expect(
        shown,
        containsAll(<String>['22', '23', '24', '25', '26', '27', '28']),
        reason: '6/22-6/28 那一周全都在',
      );
      expect(shown, contains('28'), reason: '28 只在六月这周出现');
      expect(shown, isNot(contains('21')), reason: '21 只在九月那周出现 —— 它不该在');
    });

    testWidgets('有数据的日期打点，没数据的不打', (tester) async {
      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: WeekStrip(
              selectedDate: today,
              today: today,
              onDateSelected: (_) {},
              marks: {
                '2026-09-24': const DayMarks(homework: 2, checkin: 1),
              },
            ),
          ),
        ),
      );
      await tester.pump();

      // 打点是 4×4 的圆点（BoxShape.circle）。
      final dots = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) {
            final d = c.decoration;
            return d is BoxDecoration && d.shape == BoxShape.circle && d.color == AppColors.primary;
          })
          .length;
      // 9-24 有作业+打卡 = 2 个点。其余格子没有数据。
      expect(dots, 2, reason: '只有 9-24 有数据，应当恰好 2 个点');
    });

    testWidgets('传 onPickMonth 才显示日历图标（向后兼容）', (tester) async {
      await pumpStrip(tester, selected: today);
      expect(find.byIcon(Icons.calendar_month_outlined), findsNothing);

      await pumpStrip(tester, selected: today, onPickMonth: () {});
      expect(find.byIcon(Icons.calendar_month_outlined), findsOneWidget);
    });

    testWidgets('点日期会回调那个日期', (tester) async {
      DateTime? picked;
      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: WeekStrip(
              selectedDate: today,
              today: today,
              onDateSelected: (d) => picked = d,
            ),
          ),
        ),
      );
      await tester.pump();

      // 2026-09-22 是周二 → 本周一是 21 号。点 24 号（周四）。
      await tester.tap(find.text('24'));
      await tester.pump();
      expect(picked, isNotNull);
      expect(DayUtil.isSameDay(picked!, DateTime(2026, 9, 24)), isTrue);
    });

    testWidgets('**两个实例各自选中不同日期，互不影响**（原实现是 static，会串）', (tester) async {
      // 这条是抽公共控件顺带修掉的那个隐患的判据。
      // 原实现 `static final Rx<DateTime> _selectedDate` 让两处共用一份状态。
      // 抽成构造参数之后，**类型上就不可能串**了 —— 这条断言把这件事钉住。
      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                WeekStrip(
                  selectedDate: DateTime(2026, 9, 22),
                  today: today,
                  onDateSelected: (_) {},
                ),
                WeekStrip(
                  selectedDate: DateTime(2026, 9, 10),
                  today: today,
                  onDateSelected: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      // 上面那个亮 22、下面那个亮 10 —— 各自独立。
      expect(find.text('22'), findsOneWidget);
      expect(find.text('10'), findsOneWidget);
    });
  });

  group('MonthPickerSheet', () {
    /// 渲染弹层本体（不起 modal 路由，直接放成页面 —— 少一层不确定性）。
    Future<void> pumpSheet(
      WidgetTester tester, {
      required DateTime selected,
      DateTime? earliest,
      Map<String, DayMarks> marks = const {},
      ValueChanged<DateTime>? onMonthChanged,
      bool loading = false,
      void Function(DateTime?)? onResult,
    }) async {
      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => MonthPickerSheet(
                selectedDate: selected,
                today: today,
                earliestDate: earliest,
                marks: marks,
                onMonthChanged: onMonthChanged,
                loading: loading,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('标题是「年 月」，且默认显示选中那天所在月', (tester) async {
      await pumpSheet(tester, selected: DateTime(2026, 6, 24));
      expect(find.text('2026 年 6 月'), findsOneWidget);
    });

    testWidgets('翻上一个月：标题变、且回调那个月', (tester) async {
      DateTime? asked;
      await pumpSheet(
        tester,
        selected: today,
        onMonthChanged: (m) => asked = m,
      );
      expect(find.text('2026 年 9 月'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      expect(find.text('2026 年 8 月'), findsOneWidget);
      expect(asked, isNotNull);
      expect(DayUtil.monthKey(asked!), '2026-08', reason: '翻月要回调新月，调用方据此取摘要');
    });

    testWidgets('不允许翻到未来（当前月时「下一个月」是禁用的）', (tester) async {
      // 未来的日期没有「历史」可看，而且会给服务端发未来的时间窗。
      await pumpSheet(tester, selected: today);
      final next = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.chevron_right),
          matching: find.byType(IconButton),
        ),
      );
      expect(next.onPressed, isNull, reason: '已经在当前月，下一月按钮应当禁用');
    });

    testWidgets('往回翻之后「下一个月」可以点了', (tester) async {
      await pumpSheet(tester, selected: today);
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();

      final next = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.chevron_right),
          matching: find.byType(IconButton),
        ),
      );
      expect(next.onPressed, isNotNull);
    });

    testWidgets('「回到今天」把视图拉回当前月', (tester) async {
      await pumpSheet(tester, selected: DateTime(2026, 6, 24));
      expect(find.text('2026 年 6 月'), findsOneWidget);

      await tester.tap(find.text('回到今天'));
      await tester.pumpAndSettle();
      expect(find.text('2026 年 9 月'), findsOneWidget, reason: '翻远了要能回来');
    });

    testWidgets('有数据的日期有打点（能被看见才叫打点）', (tester) async {
      await pumpSheet(
        tester,
        selected: today,
        marks: {'2026-09-10': const DayMarks(homework: 1, checkin: 1)},
      );
      final dots = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) {
            final d = c.decoration;
            return d is BoxDecoration && d.shape == BoxShape.circle;
          })
          .length;
      expect(dots, 2, reason: '9-10 有作业+打卡 = 2 个点');
    });

    testWidgets('这个月没有数据时，**说明是一句话**（不是一片灰格子）', (tester) async {
      await pumpSheet(tester, selected: today);
      expect(
        find.text('这个月没有记录'),
        findsOneWidget,
        reason: '没有数据与「加载失败」在界面上必须能区分 —— 否则用户会一直等',
      );

      // 反面：有数据时不该还说「没有记录」。
      await pumpSheet(
        tester,
        selected: today,
        marks: {'2026-09-10': const DayMarks(homework: 1)},
      );
      expect(find.text('这个月没有记录'), findsNothing);
    });

    testWidgets('正在加载时说明「正在读取」，但仍**不遮住**日历', (tester) async {
      await pumpSheet(tester, selected: today, loading: true);
      expect(find.text('正在读取这个月的数据…'), findsOneWidget);
      // 加载中日期仍然可点（日历本身是本地算的，不依赖摘要）。
      expect(find.text('15'), findsOneWidget);
    });

    testWidgets('早于可选最早日的日期不可选（点了真的没反应）', (tester) async {
      // 用 `pick()` 而不是直接 pump `MonthPickerSheet` —— 只有走 `pick()`
      // 才拿得到「用户点了之后返回了哪天」这个值。
      // 只验颜色的话，「不可选」只是**看起来**不可选：
      // 一个没接住 `_selectable` 的 `onTap` 会让它照样可选，而颜色判据照样绿。
      DateTime? popped;
      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  popped = await MonthPickerSheet.pick(
                    context,
                    selectedDate: DateTime(2026, 9, 22),
                    today: today,
                    earliestDate: DateTime(2026, 9, 15),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      // 9-10 早于最早日 9-15 → 不可选（点了不该有反应）。
      // 颜色判据：不可选的日期用 border 色（浅灰），可选的用 text 色。
      final texts = tester.widgetList<Text>(find.byType(Text));
      final ten = texts.firstWhere((t) => t.data == '10');
      final twenty = texts.firstWhere((t) => t.data == '20');
      expect(ten.style?.color, AppColors.border, reason: '9-10 早于最早日 → 显示为不可选');
      expect(twenty.style?.color, isNot(AppColors.border));

      // ⭐ 行为判据：点它**不该**关闭弹层、也不该返回任何日期。
      await tester.tap(find.text('10'));
      await tester.pumpAndSettle();
      expect(popped, isNull, reason: '不可选的日期被点了也不该返回 —— 颜色只是提示，拦截才是行为');
      // ⚠️ 这里**不能**断言 `find.text('打开') == findsNothing`：
      // `showModalBottomSheet` 只把底下的页面**盖住**，它仍在 widget 树上，
      // 所以「打开」永远找得到 —— 那种写法恒失败（我第一版就是这么写的）。
      // 「弹层还开着」的正确判据是：**这一层 modal 路由还在**。
      expect(
        find.byType(ModalBarrier),
        findsWidgets,
        reason: '弹层应当还开着（modal 屏障还在）',
      );
      // 再补一条正面判据：弹层里的按钮还在。
      expect(find.text('回到今天'), findsOneWidget, reason: '弹层内容仍在树上');
    });

    testWidgets('未来的日期不可选', (tester) async {
      await pumpSheet(tester, selected: today);
      final texts = tester.widgetList<Text>(find.byType(Text));
      final future = texts.firstWhere((t) => t.data == '25');
      expect(future.style?.color, AppColors.border, reason: '9-25 在未来 → 不可选');
    });
  });

  group('CalendarSummaryService', () {
    /// 一个最小的假传输层。**只为这一个端点**服务 —— 假 api 越小越不容易
    /// 「测着测试代码而不是被测代码」。
    _FakeApiClient fakeApi(
      List<Map<String, dynamic>> days, {
      int failTimes = 0,
      Map<String, List<Map<String, dynamic>>>? byStudent,
      bool shapeBroken = false,
    }) {
      return _FakeApiClient(
        days: days,
        failTimes: failTimes,
        byStudent: byStudent,
        shapeBroken: shapeBroken,
      );
    }

    test('取到的打点按日期索引', () async {
      final svc = CalendarSummaryService(
        api: fakeApi([
          {'date': '2026-09-22', 'homework': 3, 'workout': 1, 'checkin': 2},
          {'date': '2026-09-20', 'homework': 1},
        ]),
      );
      final marks = await svc.summaryFor(DateTime(2026, 9, 1));
      expect(marks.keys.toSet(), {'2026-09-22', '2026-09-20'});
      expect(marks['2026-09-22']!.homework, 3);
      expect(marks['2026-09-20']!.workout, 0);
    });

    test('同一个 (学生, 月) **只请求一次**（缓存生效）', () async {
      final api = fakeApi([
        {'date': '2026-09-22', 'homework': 1},
      ]);
      final svc = CalendarSummaryService(api: api);
      await svc.summaryFor(DateTime(2026, 9, 1));
      await svc.summaryFor(DateTime(2026, 9, 15));
      await svc.summaryFor(DateTime(2026, 9, 28));

      // 三次调用、同一个键入参 → 只应当发一次请求。
      expect(api.calls.length, 1, reason: '同月内来回翻不重发（方案 §2.5 第 4 条）');
    });

    test('不同月份各自请求一次', () async {
      final api = fakeApi([{'date': '2026-09-22', 'homework': 1}]);
      final svc = CalendarSummaryService(api: api);
      await svc.summaryFor(DateTime(2026, 8, 1));
      await svc.summaryFor(DateTime(2026, 9, 1));
      expect(api.calls.length, 2);
      expect(api.calls.map((q) => q['month']).toSet(), {'2026-08', '2026-09'});
    });

    test('**切换学生必须重新取**（否则家长端的点会指错人）', () async {
      final api = fakeApi(
        const [],
        byStudent: {
          'stu_001': [
            {'date': '2026-09-22', 'homework': 1},
          ],
          'stu_002': [
            {'date': '2026-09-10', 'checkin': 2},
          ],
        },
      );
      final svc = CalendarSummaryService(api: api);

      final a = await svc.summaryFor(DateTime(2026, 9, 1), studentId: 'stu_001');
      expect(a.containsKey('2026-09-22'), isTrue);

      final b = await svc.summaryFor(DateTime(2026, 9, 1), studentId: 'stu_002');
      expect(
        b.containsKey('2026-09-22'),
        isFalse,
        reason: '切到另一个孩子后不能命中上一个孩子的摘要 —— 点错了比没有点更坏',
      );
      expect(b.containsKey('2026-09-10'), isTrue);
      expect(api.calls.length, 2, reason: '两个学生各发一次');
    });

    test('请求带上 month 与 tzOffsetMinutes（服务端不猜时区）', () async {
      final api = fakeApi(const []);
      final svc = CalendarSummaryService(api: api);
      await svc.summaryFor(DateTime(2026, 9, 1));

      final q = api.calls.single;
      expect(q['month'], '2026-09');
      expect(
        q['tzOffsetMinutes'],
        isNotNull,
        reason: '不给时区服务端会 400（它在 R3 那次学乖了，不猜时区）',
      );
      // 学生端不传 studentId → 服务端用 token 推出的全部可见学生。
      expect(q.containsKey('studentId'), isFalse);
    });

    test('请求失败 → 返回空 Map，且**不写缓存**（下次会重试）', () async {
      final api = fakeApi(
        [
          {'date': '2026-09-22', 'homework': 1},
        ],
        failTimes: 1,
      );
      final svc = CalendarSummaryService(api: api);

      final first = await svc.summaryFor(DateTime(2026, 9, 1));
      expect(first, isEmpty, reason: '摘要失败不能让日历打不开');
      expect(svc.lastError, isNotNull, reason: '失败要留痕（界面不显示，排障用）');

      // ⭐ 关键：第二次要**真的重试**。
      // 「失败也写缓存」的坏法是：那一次断网被记成一整个月没数据，
      // 用户翻回来还是空的，而且永远不重试 —— 界面看起来完全正常。
      final second = await svc.summaryFor(DateTime(2026, 9, 1));
      expect(second.containsKey('2026-09-22'), isTrue, reason: '失败不进缓存，第二次应当重试成功');
      expect(api.calls.length, 2);
    });

    test('响应里没有 days → 返回空但要留痕', () async {
      final svc = CalendarSummaryService(api: fakeApi(const [], shapeBroken: true));
      final marks = await svc.summaryFor(DateTime(2026, 9, 1));
      expect(marks, isEmpty);
      expect(svc.lastError, isNotNull, reason: '「形状不对」与「这个月真没数据」必须能区分');
    });

    test('并发请求同一个键只发一次（翻月快时不该连发）', () async {
      final api = fakeApi([
        {'date': '2026-09-22', 'homework': 1},
      ]);
      final svc = CalendarSummaryService(api: api);

      // 三个并发的同一月请求。
      await Future.wait([
        svc.summaryFor(DateTime(2026, 9, 1)),
        svc.summaryFor(DateTime(2026, 9, 1)),
        svc.summaryFor(DateTime(2026, 9, 1)),
      ]);
      expect(
        api.calls.length,
        1,
        reason: '并发读要等**同一个** Future，否则缓存还没写就重复发（首屏预取踩过同一个坑）',
      );
    });

    test('本地模式（api 为 null）返回空，不抛', () async {
      final svc = CalendarSummaryService(api: null);
      expect(await svc.summaryFor(DateTime(2026, 9, 1)), isEmpty);
      // 本地模式不打点是**刻意的**：按天聚合是服务端能力，
      // 本地再实现一遍会让同一件事有两份实现（本项目最贵的 bug 类型）。
    });

    test('invalidate 只清那个学生', () async {
      final api = fakeApi(
        const [],
        byStudent: {
          'stu_001': [
            {'date': '2026-09-22', 'homework': 1},
          ],
          'stu_002': [
            {'date': '2026-09-10', 'checkin': 1},
          ],
        },
      );
      final svc = CalendarSummaryService(api: api);
      await svc.summaryFor(DateTime(2026, 9, 1), studentId: 'stu_001');
      await svc.summaryFor(DateTime(2026, 9, 1), studentId: 'stu_002');
      expect(svc.cacheSize, 2);

      svc.invalidate('stu_001');
      expect(svc.cacheSize, 1, reason: '只清指定学生');
    });
  });

  group('LocalDayMarks（本地模式/兜底的打点）', () {
    test('三个来源各自的「那一天」语义不同，且都对', () {
      final marks = LocalDayMarks.build(
        homework: [
          // 到期日 9-22 15:30 → 归到 9-22
          hw('h1', DateTime(2026, 9, 22, 15, 30)),
        ],
        workoutRecords: [
          // 开始时刻 9-21 07:00 → 归到 9-21
          wr('w1', DateTime(2026, 9, 21, 7)),
        ],
        checkins: [
          // `date` 是纯日期串，直接当键
          ck('c1', '2026-09-20'),
        ],
      );

      expect(marks['2026-09-22']!.homework, 1);
      expect(marks['2026-09-21']!.workout, 1);
      expect(marks['2026-09-20']!.checkin, 1);
      // 三条落在三天，互不干扰。
      expect(marks.length, 3);
    });

    test('同一天多类数据会累加（不是覆盖）', () {
      final marks = LocalDayMarks.build(
        homework: [
          hw('h1', DateTime(2026, 9, 22, 9)),
          hw('h2', DateTime(2026, 9, 22, 10)),
        ],
        workoutRecords: [
          wr('w1', DateTime(2026, 9, 22, 7)),
        ],
        checkins: const [],
      );
      final day = marks['2026-09-22']!;
      expect(day.homework, 2);
      expect(day.workout, 1);
      expect(day.checkin, 0);
    });

    test('打卡的日期串**不做时区换算**（parse+toLocal 会挪走一天）', () {
      // 这是最容易写错的一处：`DateTime.parse('2026-09-20').toLocal()`
      // 在东八区会得到 9-20 08:00 —— 表面上还对；但在 UTC-5 会变成 9-19。
      // 正确做法是**直接用字符串当键**（`date` 就是「学生所在地的那一天」）。
      final marks = LocalDayMarks.build(
        homework: const [],
        workoutRecords: const [],
        checkins: [ck('c1', '2026-09-20')],
      );
      expect(marks.keys.single, '2026-09-20');
    });

    test('空数据 → 空 Map（不抛）', () {
      final marks = LocalDayMarks.build(
        homework: const [],
        workoutRecords: const [],
        checkins: const [],
      );
      expect(marks, isEmpty);
    });
  });
}

/// 最小的假传输层。
///
/// ⚠️ 刻意**不**去继承真实的 `DataApiClient`：那会把这个测试绑到读缓存、
/// 会话、聚合预热等一堆与日历无关的机制上，任何一处改动都会让这里变红 ——
/// 而那些红都不是「日历坏了」。
class _FakeApiClient implements DataApiClient {
  _FakeApiClient({
    required this.days,
    this.failTimes = 0,
    this.byStudent,
    this.shapeBroken = false,
  });

  final List<Map<String, dynamic>> days;
  final Map<String, List<Map<String, dynamic>>>? byStudent;
  final bool shapeBroken;

  /// 前 [failTimes] 次请求抛错（用来验「失败不进缓存、下次重试」）。
  int failTimes;

  final List<Map<String, Object?>> calls = [];

  @override
  Future<Map<String, dynamic>> getJson(String path, {Map<String, Object?>? query}) async {
    calls.add(query ?? const {});
    if (failTimes > 0) {
      failTimes -= 1;
      // ⚠️ `DataApiException` 是**具名**参数（`code:` / `message:`），
      // 不是位置参数 —— 写 `('文案', code: 'x')` 会得到
      // 「Too many positional arguments: 0 allowed, but 1 found」。
      throw const DataApiException(code: 'network_error', message: '模拟失败');
    }
    if (shapeBroken) return {'month': '2026-09'};
    final sid = query?['studentId'];
    final rows = (byStudent != null && sid is String) ? (byStudent![sid] ?? const []) : days;
    return {'month': query?['month'], 'days': rows};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('这个假实现只服务 /data/calendar/summary：${invocation.memberName}');
}
