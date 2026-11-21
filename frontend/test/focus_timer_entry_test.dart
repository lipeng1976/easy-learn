import 'package:easy_learn_app/models/focus_session_model.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/pages/student/widgets/focus_timer_entry.dart';
import 'package:easy_learn_app/services/focus_timer_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 作业卡片上那一行「专注计时」。
///
/// 它是整个功能的**唯一入口**：这一行不出现，功能就等于不存在，而且不会有
/// 任何报错。三种状态还各自说不同的话，说错了学生就会在「开始 / 继续 /
/// 再计一次」之间点错 —— 那不是文案问题，是计时口径问题。
class _Clock {
  DateTime value = DateTime(2026, 10, 19, 9, 0, 0);

  DateTime call() => value;

  void advance(int seconds) => value = value.add(Duration(seconds: seconds));
}

HomeworkItem _item({
  String id = 'hw_1',
  int actualSeconds = 0,
}) => HomeworkItem(
  id: id,
  title: '数学练习册 P28',
  subject: '数学',
  imageUrl: '',
  dueAt: DateTime(2026, 10, 19),
  estimatedMinutes: 30,
  actualSeconds: actualSeconds,
  status: HomeworkStatus.pending,
  wrongCount: 0,
  aiEnabled: true,
  needsGrading: true,
  userRole: 'student',
  studentId: 'stu_001',
);

FocusTarget _target(String id, {int recordedSeconds = 0}) => FocusTarget(
  kind: FocusTargetKind.homework,
  id: id,
  title: '作业 $id',
  subject: '数学',
  recordedSeconds: recordedSeconds,
);

void main() {
  late _Clock clock;
  late FocusTimerService timer;
  late int taps;

  setUp(() {
    clock = _Clock();
    timer = FocusTimerService(clock: clock.call);
    taps = 0;
  });

  tearDown(() => timer.reset());

  Future<void> pumpEntry(WidgetTester tester, HomeworkItem item) {
    taps = 0;
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusTimerEntry(
            targetId: item.id,
            hasRecordedTime: item.hasActualTime,
            timer: timer,
            onTap: () => taps++,
          ),
        ),
      ),
    );
  }

  testWidgets('没计过时：说「开始」，不是「再计一次」', (tester) async {
    await pumpEntry(tester, _item());
    expect(find.text('专注计时'), findsOneWidget);
    expect(find.text('开始'), findsOneWidget);
  });

  testWidgets('计过时：「再计一次」—— 但不会显示成 0 秒', (tester) async {
    await pumpEntry(tester, _item(actualSeconds: 754));
    expect(find.text('再计一次'), findsOneWidget);
    expect(find.textContaining('754'), findsNothing, reason: '入口只说状态，历史值在卡片的信息行');
  });

  testWidgets('计时中：实时显示本次秒数', (tester) async {
    await pumpEntry(tester, _item());
    timer.start(_target('hw_1', recordedSeconds: 300));
    clock.advance(9);
    timer.refresh();
    await tester.pump();

    expect(find.text('专注计时中'), findsOneWidget);
    expect(find.text('00:00:09'), findsOneWidget);
    // 收尾停掉 ticker：widget 测试在用例体结束时检查「有没有残留的 Timer」，
    // 而 tearDown 跑在这项检查之后。
    timer.reset();
  });

  testWidgets('暂停：说「计时已暂停」，秒数停在原处', (tester) async {
    await pumpEntry(tester, _item());
    timer.start(_target('hw_1', recordedSeconds: 0));
    clock.advance(9);
    timer.refresh();
    timer.pause();
    await tester.pump();

    expect(find.text('计时已暂停'), findsOneWidget);
    expect(find.text('00:00:09'), findsOneWidget);
  });

  testWidgets('别的作业在计时：这一行不能被点亮', (tester) async {
    await pumpEntry(tester, _item(id: 'hw_1'));
    timer.start(_target('hw_other', recordedSeconds: 0));
    await tester.pump();

    expect(
      find.text('专注计时'),
      findsOneWidget,
      reason: '把别人的计时显示到这份作业上，学生会以为这份已经在计时',
    );
    expect(find.text('专注计时中'), findsNothing);
    timer.reset();
  });

  testWidgets('点整行就进得去 —— 不是只有那个小图标能点', (tester) async {
    await pumpEntry(tester, _item());
    await tester.tap(find.text('专注计时'));
    expect(taps, 1);
  });
}
