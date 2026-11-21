import 'package:easy_learn_app/services/focus_timer_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easy_learn_app/models/focus_session_model.dart';

/// 手调时钟。计时器的全部正确性都压在「时间从哪来」上：
/// 真实时钟跑 40 分钟没法测，而按 tick 数计时的实现又抓不到漂移，
/// 所以这里把「现在几点」交给测试控制，逐秒断言。
class _Clock {
  DateTime value = DateTime(2026, 10, 19, 9, 0, 0);

  DateTime call() => value;

  void advance(int seconds) {
    value = value.add(Duration(seconds: seconds));
  }
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
  });

  tearDown(() => timer.dispose());

  test('开始之后按墙钟累计 —— 不是每秒 +1', () {
    timer.start(_target('hw_1', recordedSeconds: 0));
    expect(timer.status.value, FocusTimerStatus.running);

    clock.advance(90);
    // 刻意**不**等 ticker：这条断言要证明「数字来自墙钟差」。
    // 若实现靠 Timer 每秒 +1，这里拿到的是 0。
    expect(timer.sessionSeconds, 90);
    expect(timer.totalSeconds, 90);
  });

  test('暂停期间不计入：离开 10 分钟回来，只多算离开前那一段', () {
    timer.start(_target('hw_1', recordedSeconds: 0));
    clock.advance(120);

    final paused = timer.pause();
    expect(paused, 120);
    expect(timer.status.value, FocusTimerStatus.paused);

    clock.advance(600); // 上厕所 / 被叫走
    expect(timer.sessionSeconds, 120, reason: '暂停的时间不能记成学习时间');

    timer.resume();
    clock.advance(30);
    expect(timer.sessionSeconds, 150);
  });

  test('本次会话与历史记录分开：大数字是本次，总量另算', () {
    timer.start(_target('hw_1', recordedSeconds: 300));
    clock.advance(60);
    expect(timer.sessionSeconds, 60, reason: '屏幕上那个大数字只能算这一次');
    expect(timer.baseSeconds, 300);
    expect(timer.totalSeconds, 360, reason: '写库时才是「此前 + 本次」');
  });

  test('同一份作业重复 start 是幂等的 —— 页面每次进来都会调它', () {
    timer.start(_target('hw_1', recordedSeconds: 300));
    clock.advance(45);
    timer.start(_target('hw_1', recordedSeconds: 300));
    expect(
      timer.sessionSeconds,
      45,
      reason: '重开会把刚计的时间洗掉，而进页面就会触发一次',
    );
  });

  test('自动暂停：原因是「离开应用」，不是学生点的', () {
    timer.start(_target('hw_1', recordedSeconds: 0));
    clock.advance(10);

    timer.pause(automatic: true);
    expect(timer.status.value, FocusTimerStatus.paused);
    expect(timer.autoPaused.value, isTrue);

    // 继续之后标记要清掉：否则界面会一直说「你刚才离开了应用」，
    // 而学生已经回来很久了。
    timer.resume();
    expect(timer.autoPaused.value, isFalse);
  });

  test('手动暂停不会被说成自动暂停', () {
    timer.start(_target('hw_1', recordedSeconds: 0));
    timer.pause();
    expect(timer.autoPaused.value, isFalse);
  });

  test('系统时间被回拨时不倒扣已累计的时间', () {
    timer.start(_target('hw_1', recordedSeconds: 0));
    clock.advance(100);
    timer.pause();
    timer.resume();

    clock.advance(-2000); // 学生手动改时间
    expect(timer.sessionSeconds, 100, reason: '时间往回跳，累计值不能跟着往回跳');
  });

  test('reset 之后是干净的 idle：没有会话、没有残留数字', () {
    timer.start(_target('hw_1', recordedSeconds: 120));
    clock.advance(30);
    timer.pause();

    timer.reset();
    expect(timer.status.value, FocusTimerStatus.idle);
    expect(timer.hasSession, isFalse);
    expect(timer.sessionSeconds, 0);
    expect(timer.totalSeconds, 0);
    expect(timer.elapsedSeconds.value, 0);
  });

  test('会话跟着作业走：另一份作业不算它的', () {
    timer.start(_target('hw_1', recordedSeconds: 0));
    expect(timer.isActiveFor('hw_1'), isTrue);
    expect(timer.isActiveFor('hw_2'), isFalse);
  });
}
