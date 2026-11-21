import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/focus_session_model.dart';

/// 一次专注计时的三种状态。
///
/// `idle` 是「这份作业上没有会话」；`paused` 是「有会话、但没在计时」。
/// 两者在界面上要说不同的话（「开始」 vs 「继续」），所以不能合成一个 bool。
enum FocusTimerStatus { idle, running, paused }

/// 专注计时器。
///
/// ## 它算的是什么
///
/// **只算「计时中」的时间**。暂停期间、离开应用期间都不计入 —— 学生要回答
/// 的问题是「我在这份作业上花了多久」，不是「这个页面开了多久」。
///
/// 时间用**墙钟差**累加（`DateTime` 相减），不是「每秒 +1」：
/// 定时器会漂、系统会省电、前台队列会积压，按 tick 数计时的话，
/// 一次 40 分钟的作业能少算几分钟，而且**没有任何报错**。
/// ticker 只负责「让界面重画」，不负责计量。
///
/// ## 为什么不落盘
///
/// 计时会话只活在内存里。落盘会带出一个必须先回答的问题：**进程被杀掉的
/// 那段时间算不算学习时间？** 没有诚实的答案 —— 算，等于把一夜算成学习；
/// 不算，等于假装没发生过。所以口径是「会话随进程结束」，
/// 并由页面在暂停 / 离开页面的那一刻**先把累计值写进作业**（检查点），
/// 把损失限制在「最后一次暂停之后的几秒」。
///
/// ## 为什么是整份覆盖，不是增量
///
/// 见 `HomeworkPatch.actualSeconds`：增量在网络重试下会重复累加。
class FocusTimerService {
  FocusTimerService({
    DateTime Function()? clock,
    this.tickInterval = const Duration(seconds: 1),
  }) : _clock = clock ?? DateTime.now;

  /// 全应用共用一份。
  ///
  /// 计时必须跨页面存活：学生按下返回去看一眼作业照片，回来时那个数字
  /// 还得在。做成页面级实例的话，回去一趟就等于「放弃本次」，
  /// 而界面不会提示这一点。
  static final FocusTimerService instance = FocusTimerService();

  final DateTime Function() _clock;
  final Duration tickInterval;

  /// 本次会话累计的秒数（不含此前的历史记录）。
  final ValueNotifier<int> elapsedSeconds = ValueNotifier<int>(0);

  final ValueNotifier<FocusTimerStatus> status = ValueNotifier<FocusTimerStatus>(
    FocusTimerStatus.idle,
  );

  /// 最近一次暂停是不是**因为离开应用**自动触发的。
  ///
  /// 界面据此说「你离开过应用，已暂停」，而不是「你点了暂停」——
  /// 学生没点过的事，界面不能替他记成点了。
  final ValueNotifier<bool> autoPaused = ValueNotifier<bool>(false);

  /// **连续**专注的秒数（不含此前的历史记录，也不含被算作休息的暂停）。
  ///
  /// 与 [elapsedSeconds] 的区别只有一个：休息够久之后它会归零。
  /// 大数字仍然用 [elapsedSeconds]（本次一共计了多久），
  /// 这个数只服务于「该不该提醒休息」。
  final ValueNotifier<int> continuousSeconds = ValueNotifier<int>(0);

  /// 连续学多久提醒一次休息。`0` = 不提醒。
  final ValueNotifier<int> restReminderMinutes = ValueNotifier<int>(40);

  /// 已经到提醒点了。
  ///
  /// 页面监听它来触发一次「变色 + 朗读 + 字幕」；学生点「我休息好了」
  /// 或「再学 10 分钟」之后回到 false。
  final ValueNotifier<bool> restDue = ValueNotifier<bool>(false);

  /// 暂停超过这个时长才算「休息过」。
  ///
  /// 3 分钟是刻意选的：上个厕所、被叫去接个电话都在这个量级以内，
  /// 而「起来活动一下」通常超过它。比这更短的暂停如果也清零，
  /// 学生会发现「暂停 10 秒再继续」就能绕开提醒。
  static const Duration breakGrace = Duration(minutes: 3);

  /// 这一屏在给什么计时。**空闲时是 null**（不是空串），
  /// 这样「有没有会话」只有一个判据，不会出现「有 target 但 id 为空」。
  FocusTarget? _target;

  /// 会话 id = 落库那一行的幂等键。一次会话一个，检查点重复保存用它更新同一行。
  String _sessionId = '';

  /// 会话开始的时刻（墙钟）。写流水时记进 `startedAt`。
  DateTime? _sessionStartedAt;

  int _baseSeconds = 0;
  int _accumulatedSeconds = 0;
  DateTime? _runStartedAt;
  Timer? _ticker;

  /// 上一次「休息结束」那一刻的 [sessionSeconds]。
  ///
  /// 用差值算连续时长，而不是单独开一个计数器：墙钟被回拨、
  /// 暂停再继续这些情况下，差值天然是对的，而计数器需要每一处都记得加。
  int _continuousOffset = 0;

  /// 「再学 N 分钟」额外推后的秒数。
  int _snoozeOffset = 0;

  /// 进入暂停的时刻，用来判断这次暂停算不算休息。
  DateTime? _pausedAt;

  /// 当前在计什么。null = 没有会话。
  FocusTarget? get target => _target;

  /// 当前目标的 id（没有会话时是空串）。
  String get targetId => _target?.id ?? '';

  /// 当前是否有一段计时正在进行（含已暂停的会话）。
  bool get hasSession => _target != null;

  /// 这个 id 是不是**当前**在计的那一个。
  ///
  /// 页面每次进入都会调一次 `start`，靠这里判断「是恢复还是新开」。
  bool isActiveFor(String id) => _target != null && _target!.id == id;

  /// 本次会话的幂等键。
  String get sessionId => _sessionId;

  /// 本次会话开始的时刻。
  DateTime? get sessionStartedAt => _sessionStartedAt;

  /// 这次会话开始之前，作业上已经记录过的秒数。
  int get baseSeconds => _baseSeconds;

  /// 本次会话的秒数。
  int get sessionSeconds => _elapsed;

  /// 本次会话 + 此前记录的**总量** —— 也就是保存时要写进作业的那个数。
  int get totalSeconds => _baseSeconds + _elapsed;

  /// 连续专注的秒数（休息够久或点过「我休息好了」后归零）。
  int get continuous => _elapsed - _continuousOffset;

  bool get isRunning => status.value == FocusTimerStatus.running;

  /// 开始一次新会话。
  ///
  /// `recordedSeconds` = 作业上已有的实际用时（`HomeworkItem.actualSeconds`）。
  /// 它只作为**保存时的基数**参与计算，不会让计时器从那个数字起步 ——
  /// 屏幕上那个大数字始终是「本次」，学生一眼能看出这一次到底做了多久。
  ///
  /// 对同一份作业重复调用是**幂等**的：不清零、不重开。
  /// 重开会让「回到页面时自动恢复」这条路径把累计时间洗掉，
  /// 而那正是最容易发生的事（每次进页面都会调一次）。
  void start(FocusTarget target) {
    if (_target != null &&
        _target!.id == target.id &&
        status.value != FocusTimerStatus.idle) {
      return;
    }
    _stopTicker();
    _target = target;
    // 新会话 = 新的幂等键。临时打卡没有稳定的目标 id，
    // 所以这一次用它当身份（见 `FocusTarget.id` 的说明）。
    _sessionId = 'fs_${_clock().microsecondsSinceEpoch}';
    _sessionStartedAt = _clock();
    _baseSeconds = target.recordedSeconds < 0 ? 0 : target.recordedSeconds;
    _accumulatedSeconds = 0;
    _runStartedAt = null;
    autoPaused.value = false;
    elapsedSeconds.value = 0;
    // 新会话 = 新的一段连续学习。上一份作业的「已经坐了一小时」不该算到这一份上。
    _continuousOffset = 0;
    _snoozeOffset = 0;
    _pausedAt = null;
    continuousSeconds.value = 0;
    restDue.value = false;
    resume();
  }

  /// 继续计时（开始之后的第一次也走这里）。
  void resume() {
    if (_target == null) return;
    if (status.value == FocusTimerStatus.running) return;

    // 这次暂停够不够长，决定了「连续时长要不要重新开始算」。
    // 不够长（喝口水、想一想）就接着算；够长就是休息过了。
    final pausedAt = _pausedAt;
    if (pausedAt != null && _clock().difference(pausedAt) >= breakGrace) {
      _continuousOffset = _elapsed;
      _snoozeOffset = 0;
    }
    _pausedAt = null;

    _runStartedAt = _clock();
    autoPaused.value = false;
    status.value = FocusTimerStatus.running;
    elapsedSeconds.value = _elapsed;
    _recompute();
    _startTicker();
  }

  /// 暂停，返回本次会话的秒数。
  ///
  /// [automatic] = true 表示不是学生点的（离开应用）。两种暂停在计时口径上
  /// 完全一样，只是界面文案不同 —— **自动暂停绝不能悄悄继续计时**：
  /// 那会把「手机放在桌上两小时」记成学习两小时。
  int pause({bool automatic = false}) {
    if (status.value == FocusTimerStatus.running) {
      _accumulatedSeconds = _elapsed;
      _runStartedAt = null;
      _stopTicker();
      status.value = FocusTimerStatus.paused;
      elapsedSeconds.value = _accumulatedSeconds;
      autoPaused.value = automatic;
      // 记下暂停时刻：继续时要靠它判断这次算不算休息。
      _pausedAt = _clock();
      _recompute();
    }
    return _accumulatedSeconds;
  }

  /// 结束会话并清空（调用方先把 [totalSeconds] 写进作业）。
  void reset() {
    _stopTicker();
    _target = null;
    _sessionId = '';
    _sessionStartedAt = null;
    _baseSeconds = 0;
    _accumulatedSeconds = 0;
    _runStartedAt = null;
    autoPaused.value = false;
    elapsedSeconds.value = 0;
    _continuousOffset = 0;
    _snoozeOffset = 0;
    _pausedAt = null;
    continuousSeconds.value = 0;
    restDue.value = false;
    status.value = FocusTimerStatus.idle;
  }

  /// 设置「连续学多久提醒休息」。`0` = 不提醒。
  ///
  /// 立刻重算一次：学生如果在第 30 分钟把阈值从 40 改成 25，
  /// 这条提醒**当场**就该出现，而不是等到下一次 tick。
  void setRestReminderMinutes(int minutes) {
    final value = minutes < 0 ? 0 : (minutes > 180 ? 180 : minutes);
    restReminderMinutes.value = value;
    _recompute();
  }

  /// 学生点了「我休息好了」：连续时长从现在重新算。
  void acknowledgeRest() {
    _continuousOffset = _elapsed;
    _snoozeOffset = 0;
    _recompute();
  }

  /// 「再学 10 分钟」：把这一轮的提醒点往后推。
  void snoozeRest([Duration extra = const Duration(minutes: 10)]) {
    _snoozeOffset += extra.inSeconds;
    _recompute();
  }

  /// 重算连续时长与「该不该提醒」。
  ///
  /// 只在 tick、暂停、继续、改阈值、点按钮这几处调用。
  /// 不放进 `_elapsed` 的 getter 里：getter 每帧都会被调用，
  /// 在那里写 notifier 会在 build 期间触发监听者重画。
  void _recompute() {
    final value = continuous;
    continuousSeconds.value = value < 0 ? 0 : value;

    final minutes = restReminderMinutes.value;
    final threshold = minutes <= 0 ? 0 : minutes * 60 + _snoozeOffset;
    final due = threshold > 0 && continuousSeconds.value >= threshold;
    if (due != restDue.value) restDue.value = due;
  }

  /// 让 ticker 之外也能拿到最新值（测试用：把注入的时钟往前拨之后调它）。
  @visibleForTesting
  void refresh() {
    if (status.value == FocusTimerStatus.running) {
      elapsedSeconds.value = _elapsed;
      _recompute();
    }
  }

  /// 当前秒数。计时中按墙钟现算，暂停时就是累计值。
  int get _elapsed {
    final startedAt = _runStartedAt;
    if (startedAt == null) return _accumulatedSeconds;
    final diff = _clock().difference(startedAt);
    // 系统时间被回拨（学生手动改时间 / 时区跳变）时，差额会是负数。
    // 夹到 0 而不是让它抵掉已累计的部分 —— 抵掉的话学生看到时间往回跳。
    return _accumulatedSeconds + (diff.isNegative ? 0 : diff.inSeconds);
  }

  void _startTicker() {
    _stopTicker();
    _ticker = Timer.periodic(tickInterval, (_) {
      elapsedSeconds.value = _elapsed;
      _recompute();
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @visibleForTesting
  void dispose() {
    _stopTicker();
    elapsedSeconds.dispose();
    status.dispose();
    autoPaused.dispose();
    continuousSeconds.dispose();
    restReminderMinutes.dispose();
    restDue.dispose();
  }
}
