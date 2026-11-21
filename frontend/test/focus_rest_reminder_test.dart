import 'package:easy_learn_app/services/focus_timer_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easy_learn_app/models/focus_session_model.dart';

/// 连续专注与休息提醒的口径。
///
/// 这一组判据要挡住的都是**看起来正常**的错法：
///   · 用「本次会话总时长」当连续时长 ⇒ 学生休息回来一坐下就被提醒；
///   · 任何暂停都清零 ⇒ 学生学会「暂停 10 秒再继续」来绕开提醒；
///   · 提醒是一个状态却每帧触发 ⇒ 语音从头念到尾，学生只能静音。
class _Clock {
  DateTime value = DateTime(2026, 10, 19, 9, 0, 0);

  DateTime call() => value;

  void advance(int seconds) => value = value.add(Duration(seconds: seconds));
}

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

  setUp(() {
    clock = _Clock();
    timer = FocusTimerService(clock: clock.call);
    timer.setRestReminderMinutes(40);
  });

  tearDown(() => timer.dispose());

  test('连续 40 分钟触发一次提醒，之后不再反复触发', () {
    timer.start(_target('hw_1', recordedSeconds: 0));
    clock.advance(39 * 60);
    timer.refresh();
    expect(timer.restDue.value, isFalse, reason: '39 分钟还不该提醒');

    clock.advance(60);
    timer.refresh();
    expect(timer.restDue.value, isTrue);
    expect(timer.continuousSeconds.value, 40 * 60);

    // 提醒是个状态：再过 10 分钟它仍然是 true，但页面不会重复出声
    // （那边的去重由 `_restAnnounced` 负责，这里只锁状态语义）。
    clock.advance(10 * 60);
    timer.refresh();
    expect(timer.restDue.value, isTrue);
  });

  test('暂停 2 分钟不算休息：回来接着算，还是到点', () {
    timer.start(_target('hw_1', recordedSeconds: 0));
    clock.advance(38 * 60);
    timer.pause();

    clock.advance(2 * 60); // 喝口水
    timer.resume();
    clock.advance(3 * 60);
    timer.refresh();

    expect(
      timer.restDue.value,
      isTrue,
      reason: '短暂停如果也清零，学生按一下暂停就能绕开提醒',
    );
  });

  test('暂停 5 分钟算休息过：连续时长从头算', () {
    timer.start(_target('hw_1', recordedSeconds: 0));
    clock.advance(38 * 60);
    timer.pause();

    clock.advance(5 * 60); // 起来走了一圈
    timer.resume();
    clock.advance(3 * 60);
    timer.refresh();

    expect(timer.restDue.value, isFalse);
    expect(timer.continuousSeconds.value, 3 * 60);
    expect(
      timer.sessionSeconds,
      41 * 60,
      reason: '休息的时间不计入学习时长，但之前的学习不能丢',
    );
  });

  test('「我休息好了」立刻清零连续时长', () {
    timer.start(_target('hw_1', recordedSeconds: 0));
    clock.advance(45 * 60);
    timer.refresh();
    expect(timer.restDue.value, isTrue);

    timer.acknowledgeRest();
    expect(timer.restDue.value, isFalse);
    expect(timer.continuousSeconds.value, 0);
    expect(timer.sessionSeconds, 45 * 60, reason: '清零的只是「连续」，不是学习时长');
  });

  test('「再学 10 分钟」把提醒点推后 10 分钟，而不是取消', () {
    timer.start(_target('hw_1', recordedSeconds: 0));
    clock.advance(45 * 60);
    timer.refresh();
    timer.snoozeRest();
    expect(timer.restDue.value, isFalse);

    clock.advance(4 * 60);
    timer.refresh();
    expect(timer.restDue.value, isFalse, reason: '45+4 还没到 50');

    clock.advance(60);
    timer.refresh();
    expect(timer.restDue.value, isTrue);
  });

  test('阈值可改：40 改成 25 时，已经在第 30 分钟的这次当场提醒', () {
    timer.start(_target('hw_1', recordedSeconds: 0));
    clock.advance(30 * 60);
    timer.refresh();
    expect(timer.restDue.value, isFalse);

    timer.setRestReminderMinutes(25);
    expect(
      timer.restDue.value,
      isTrue,
      reason: '改完要立刻重算；等下一次 tick 会让「我刚改的」看起来没生效',
    );
  });

  test('阈值 0 = 不提醒', () {
    timer.setRestReminderMinutes(0);
    timer.start(_target('hw_1', recordedSeconds: 0));
    clock.advance(120 * 60);
    timer.refresh();
    expect(timer.restDue.value, isFalse);
    expect(timer.continuousSeconds.value, 120 * 60);
  });

  test('换一份作业：连续时长从零开始', () {
    timer.start(_target('hw_1', recordedSeconds: 0));
    clock.advance(30 * 60);
    timer.pause();

    timer.start(_target('hw_2', recordedSeconds: 0));
    expect(timer.continuousSeconds.value, 0);
    expect(timer.restDue.value, isFalse);
  });
}
