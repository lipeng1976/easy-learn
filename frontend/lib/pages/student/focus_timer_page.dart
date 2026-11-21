import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../constants/app_colors.dart';
import '../../controllers/student_controller.dart';
import '../../models/focus_session_model.dart';
import '../../models/knowledge_tip.dart';
import '../../services/app_settings.dart';
import '../../services/focus_timer_service.dart';
import '../../services/knowledge_tip_service.dart';
import '../../services/screen_awake.dart';
import '../../services/tts_service.dart';
import '../../utils/duration_text.dart';
import '../../widgets/math_text.dart';

/// 作业专注计时（全屏「闹钟」）。
///
/// ## 它解决的是「时间感」，不是「监督」
///
/// 学生对自己的作业用时几乎没有概念：「这篇作文写了两个小时」通常是猜的。
/// 这一屏把时间放到**屏幕上最大的那个位置**，让「我这道题花了多久」变成
/// 一个看得见的事实，而不是事后回忆。
///
/// 所以这一屏**刻意只有时间**：没有分数、没有排名、没有「你比昨天慢了」。
/// 加了任何评价，学生就会开始为了好看的数字而计时，那个数字立刻失去意义。
///
/// ## 计时口径（三条，都必须能被学生看见）
///
/// 1. **暂停不计入**：上厕所、被叫走、接电话 —— 点暂停，那段不算学习时间；
/// 2. **离开应用自动暂停**：切到别的 App、锁屏都不算。不这么做，
///    「手机放桌上一小时」会被记成学习一小时，而这个数会进学习报告；
/// 3. **大数字是「本次」**：不是这份作业的历史累计。历史累计单独一行，
///    学生一眼能分清「这一次」和「总共」。
///
/// ## 保存时机
///
/// 暂停、离开页面、离开应用、点「结束并保存」四处都会写一次（写的是
/// 「此前 + 本次」的总量，幂等）。它不是「最后才存」——
/// 那样一次误触返回或进程被杀就抹掉一小时的记录，而界面上会显得
/// 计时功能**根本没生效**。
///
/// ## 下方那两块东西
///
/// - **知识点提示**：从当前科目的错题本归纳出来的一句话，每隔一会儿换一条。
///   它只在学生**没有在休息**的时候显示 —— 到点休息时，屏幕上更重要的
///   是那句「让眼睛歇一会儿」。
/// - **休息提醒**：连续专注到阈值（默认 40 分钟，可设置）时整屏变暖色、
///   朗读一句、并在原位置弹出提醒卡。判定口径见 [FocusTimerService]。
class FocusTimerPage extends StatefulWidget {
  const FocusTimerPage({
    super.key,
    required this.target,
    required this.controller,
    this.timer,
    this.tips,
    this.onRestReminder,
  });

  /// 这一屏在给什么计时（作业 / 计划 / 临时打卡）。
  ///
  /// 传目标而不是 `HomeworkItem`：计时这件事对三种目标是一模一样的，
  /// 只有「保存到哪」不同，而那是 `StudentController` 的事。
  final FocusTarget target;
  final StudentController controller;

  /// 测试注入。生产走应用级单例（跨页面存活）。
  final FocusTimerService? timer;

  /// 测试注入。生产走应用级单例（按科目缓存提示）。
  final KnowledgeTipService? tips;

  /// 到点休息时的「出声」方式。
  ///
  /// 生产默认 = 系统朗读（TTS）+ 震动，朗读不可用时退回系统提示音。
  /// 做成可注入是为了让判据不依赖真机语音引擎 —— 测试里只要记录
  /// 「有没有被叫到」，不必真的出声。
  final Future<void> Function(String message)? onRestReminder;

  @override
  State<FocusTimerPage> createState() => _FocusTimerPageState();
}

class _FocusTimerPageState extends State<FocusTimerPage>
    with WidgetsBindingObserver {
  late final FocusTimerService _timer =
      widget.timer ?? FocusTimerService.instance;
  late final KnowledgeTipService _tips =
      widget.tips ?? KnowledgeTipService.instance;

  bool _saving = false;

  /// 最近一次保存失败的原因。显示在页面上，而不是弹一次就走 ——
  /// 学生需要知道「这一小时还没进库」。
  String? _saveError;

  /// 当前显示第几条提示。提示轮换是**按索引轮转**，不是随机：
  /// 随机在只有两三条时会出现「连着两次同一条」，看起来像没换。
  int _tipIndex = 0;

  Timer? _tipRotation;

  /// 页面上的提醒阈值（分钟）。`0` = 不提醒。
  int _restMinutes = AppSettings.defaultRestReminderMinutes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 熄屏会连带触发「离开应用自动暂停」，看起来就是「计时自己停了」。
    // 详见 `ScreenAwake`。
    unawaited(ScreenAwake.keepOn(true));

    // 进入这一屏 = 开始计时（入口本身就是「开始」）。
    // 已有会话则原样恢复：可能是刚才返回过、也可能是被自动暂停了。
    //
    // ⚠️ 必须等这一帧画完再 start：`start()` 会改 `status` / `elapsedSeconds`
    // 这些 notifier，而 `initState` 正处在 build 阶段 —— 在 build 期间通知
    // 监听者，框架会报「setState() or markNeedsBuild() called during build」。
    // 从 `Navigator.push` 进来时这条必现（页面是被别的 widget 的 build 挂上去的），
    // 直接当根页面时只是侥幸没触发 —— 同一个错，两种表现。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_timer.isActiveFor(widget.target.id)) {
        _timer.start(widget.target);
      }
    });

    _timer.restDue.addListener(_onRestDueChanged);
    _tips.tips.addListener(_onTipsChanged);

    unawaited(_loadRestMinutes());
    // 临时打卡没有科目（「运动」不是错题本的科目），那就不问模型 ——
    // 硬拿标签当科目去查，只会得到一句「这个科目的错题还不多」。
    if (widget.target.subject.trim().isNotEmpty) {
      unawaited(_loadTips());
    }

    // 提示轮换：18 秒一条。比这更快会打断阅读，更慢则一次作业只看得到两三条。
    _tipRotation = Timer.periodic(
      const Duration(seconds: 18),
      (_) => _rotateTip(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(ScreenAwake.keepOn(false));
    _tipRotation?.cancel();
    _timer.restDue.removeListener(_onRestDueChanged);
    _tips.tips.removeListener(_onTipsChanged);
    // 兜底：页面以任何方式消失时都不留一个「还在跑」的会话。
    // 不暂停的话，卡片上会一直显示「计时中」，而实际上没有人在看这一屏。
    if (_timer.isRunning) _timer.pause();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 只认「真的离开」的两种。`inactive` 在来电横幅、下拉通知栏时也会触发，
    // 把它当离开会让计时在眨眼间被暂停。
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden) {
      return;
    }
    if (!_timer.isRunning) return;
    _timer.pause(automatic: true);
    // 检查点：离开的这一刻先把累计值写进去。进程如果被系统回收，
    // 丢的只是「暂停之后的几秒」，而不是整段。
    unawaited(_save());
  }

  Future<void> _loadRestMinutes() async {
    final minutes = await AppSettings.restReminderMinutes();
    if (!mounted) return;
    setState(() => _restMinutes = minutes);
    _timer.setRestReminderMinutes(minutes);
  }

  Future<void> _loadTips() async {
    try {
      await _tips.load(
        studentId: widget.controller.studentId,
        subject: widget.target.subject,
        pool: widget.controller.mistakes,
      );
    } catch (_) {
      // 提示是这一屏的附加信息。它取不到时该发生的事是「这一块空着」，
      // 而不是把学生的计时页变成一张错误页。
    }
  }

  void _onTipsChanged() {
    if (!mounted) return;
    final length = _tips.tips.value.length;
    if (length == 0) {
      if (_tipIndex != 0) setState(() => _tipIndex = 0);
      return;
    }
    if (_tipIndex >= length) {
      setState(() => _tipIndex = _tipIndex % length);
    }
  }

  void _rotateTip() {
    final length = _tips.tips.value.length;
    if (length < 2 || !mounted) return;
    setState(() => _tipIndex = (_tipIndex + 1) % length);
  }

  /// `restDue` 从 false 变成 true 的那一下。
  ///
  /// **只在这里出声**，不要放进 `build()`：`ValueNotifier` 只在值真的变化时
  /// 通知，所以这一条路径天然「每次到点只念一次」；写进 build 则会在每次
  /// 重画时重新念一遍 —— 学生只能把手机静音。
  /// （判据见 `focus_timer_page_test.dart` 的「只念一次」：把这一句移到
  ///  build 里，那条用例会立刻变红。）
  void _onRestDueChanged() {
    if (!mounted) return;
    setState(() {});
    if (!_timer.restDue.value) return;
    unawaited(_announceRest());
  }

  Future<void> _announceRest() async {
    final minutes = _timer.restReminderMinutes.value;
    final message = '已经连续专注 $minutes 分钟了。站起来走两步，看看远处，让眼睛歇一会儿。';
    final announce = widget.onRestReminder ?? _defaultRestAnnouncement;
    try {
      await announce(message);
    } catch (_) {
      // 出声失败不是业务失败：屏幕上已经有一张提醒卡。
      // 这里弹一个「朗读失败」只会把休息提醒变成一次故障提示。
    }
  }

  /// 生产环境的「出声」：震动 + 朗读，朗读不可用时退回系统提示音。
  static Future<void> _defaultRestAnnouncement(String message) async {
    try {
      await HapticFeedback.heavyImpact();
    } catch (_) {
      // 网页版 / 部分设备没有震动，忽略。
    }
    if (TtsService.isSupported) {
      try {
        await TtsService.speak(message);
        return;
      } catch (_) {
        // 没有语音引擎 / 没装中文包 → 往下走系统提示音。
      }
    }
    try {
      await SystemSound.play(SystemSoundType.alert);
    } catch (_) {
      // 静音设备上什么都不会发生，这是对的。
    }
  }

  Future<bool> _save() async {
    if (_saving) return false;
    final total = _timer.totalSeconds;
    if (total <= 0) return true;

    setState(() => _saving = true);
    final result = await widget.controller.saveFocusProgress(
      target: widget.target,
      sessionId: _timer.sessionId,
      sessionSeconds: _timer.sessionSeconds,
      totalSeconds: total,
      startedAt: _timer.sessionStartedAt,
    );
    if (!mounted) return result.ok;
    setState(() {
      _saving = false;
      _saveError = result.ok ? null : result.message;
    });
    return result.ok;
  }

  /// 「结束并保存」：写库成功才清会话。
  ///
  /// 失败时**保留会话**，学生可以原地再点一次 —— 把一小时的记录在失败时
  /// 一并清掉，是这一屏最不能犯的错。
  Future<void> _finish() async {
    if (_saving) return;
    if (_timer.isRunning) _timer.pause();
    final ok = await _save();
    if (!ok) return;
    _timer.reset();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// 返回键 / 手势返回。
  Future<void> _handleBack() async {
    // 正在计时时先问一句：误触返回不该把一段专注悄悄结束。
    if (_timer.isRunning) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('计时还在进行'),
          content: Text(
            '已经计时 ${formatClock(_timer.sessionSeconds)}。'
            '返回会暂停计时并保存，下次进来可以继续。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('继续计时'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('暂停并返回'),
            ),
          ],
        ),
      );
      if (leave != true) return;
      _timer.pause();
    }

    final ok = await _save();
    if (!mounted) return;
    // 保存失败也要放人走（离线时不能把人困在这一屏），但把原因带回列表，
    // 由那边弹出来。会话仍然保留，卡片上会显示「继续」，可以再存一次。
    final message = ok ? null : (_saveError ?? '用时没能保存，返回列表后可再试一次');
    Navigator.of(context).pop(message);
  }

  /// 「好，去休息」：把连续计时清零并暂停。
  ///
  /// 为什么顺带暂停：学生按了这颗键就是准备起身了。只清零不暂停的话，
  /// 他走到客厅的十分钟会被记成学习时间 —— 而这十分钟恰恰是本功能
  /// 最想从「学习时长」里排除掉的那一段。
  void _takeBreak() {
    _timer.acknowledgeRest();
    if (_timer.isRunning) {
      _timer.pause();
      unawaited(_save());
    }
  }

  Future<void> _openRestSettings() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF151C26),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Text(
                '连续学多久提醒休息',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '暂停超过 3 分钟才算休息过；短短的停一下不算。',
                style: TextStyle(fontSize: 12, color: Colors.white38),
              ),
            ),
            for (final option in AppSettings.restReminderOptions)
              ListTile(
                title: Text(
                  AppSettings.label(option),
                  style: const TextStyle(fontSize: 14, color: Colors.white),
                ),
                trailing: option == _restMinutes
                    ? const Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(option),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _restMinutes = picked);
    _timer.setRestReminderMinutes(picked);
    await AppSettings.setRestReminderMinutes(picked);
  }

  bool get _resting => _timer.restDue.value;

  @override
  Widget build(BuildContext context) {
    return PopScope<String?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_handleBack());
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0F14),
        body: LayoutBuilder(
          builder: (context, constraints) {
            // 小屏（< 720dp）用紧凑排版：数字小一点、按钮小一点。
            //
            // 不这么做的话，600dp 高的屏上「40 分钟提醒卡 + 两个按钮」会被
            // 挤到可视区之外 —— 一条让你休息的提醒，还得先滑动才点得到按钮，
            // 那比不提醒更让人恼火。
            final compact = constraints.maxHeight < 720;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.25),
                  radius: 1.1,
                  colors: _resting
                      ? const [Color(0xFF3A2A12), Color(0xFF140F08)]
                      : const [Color(0xFF16233A), Color(0xFF0B0F14)],
                ),
              ),
              child: SafeArea(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: compact ? 18 : 24),
                  child: Column(
                    children: [
                      _buildTopBar(),
                      if (compact)
                        const SizedBox(height: 8)
                      else
                        const Spacer(flex: 2),
                      _buildTitle(),
                      SizedBox(height: compact ? 14 : 24),
                      _buildClock(compact),
                      SizedBox(height: compact ? 12 : 16),
                      _buildStatusLine(),
                      SizedBox(height: compact ? 10 : 14),
                      // 提示与休息卡放在一个有界的区域里，并允许滚动：
                      // 小屏同时出现提醒与提示时，固定高度会直接把这一屏撑爆。
                      Expanded(
                        flex: 4,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.only(top: 2),
                          child: _buildTipsAndRest(),
                        ),
                      ),
                      _buildControls(compact),
                      SizedBox(height: compact ? 10 : 16),
                      _buildFootnote(),
                      SizedBox(height: compact ? 8 : 12),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Row(
      children: [
        IconButton(
          onPressed: () => unawaited(_handleBack()),
          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 28),
          color: Colors.white70,
          tooltip: '收起计时',
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.timer_outlined, size: 14, color: Colors.white70),
              const SizedBox(width: 6),
              Text(
                _topBarLabel,
                style: const TextStyle(fontSize: 12.5, color: Colors.white70),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // 提醒阈值就摆在计时页上，不藏到「我的 → 设置」里：
        // 学生正是在这一屏才会想到「40 分钟对我来说太久了」。
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => unawaited(_openRestSettings()),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _resting
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_none_rounded,
                    size: 16,
                    color: _resting ? const Color(0xFFFFC46B) : Colors.white54,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    AppSettings.label(_restMinutes),
                    style: TextStyle(
                      fontSize: 12,
                      color: _resting
                          ? const Color(0xFFFFC46B)
                          : Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTitle() {
    return Text(
      widget.target.title,
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 18,
        height: 1.35,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
    );
  }

  Widget _buildClock(bool compact) {
    return ValueListenableBuilder<int>(
      valueListenable: _timer.elapsedSeconds,
      builder: (context, seconds, _) {
        return AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 500),
          style: TextStyle(
            fontSize: compact ? 58 : 76,
            height: 1.05,
            fontWeight: FontWeight.w200,
            letterSpacing: 2,
            // 到点之后数字变成暖色：不改变布局、不打断阅读，
            // 但余光能看见「有件事发生了」。
            color: _resting ? const Color(0xFFFFC46B) : Colors.white,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          child: Text(formatClock(seconds), textAlign: TextAlign.center),
        );
      },
    );
  }

  Widget _buildStatusLine() {
    return ValueListenableBuilder<FocusTimerStatus>(
      valueListenable: _timer.status,
      builder: (context, status, _) {
        final autoPaused = _timer.autoPaused.value;
        final (text, color, icon) = switch (status) {
          FocusTimerStatus.running => (
            '计时中 · 暂停的时间不计入',
            AppColors.accent,
            Icons.radio_button_checked,
          ),
          FocusTimerStatus.paused => (
            autoPaused ? '已暂停 · 你刚才离开了应用' : '已暂停 · 休息一下也没关系',
            AppColors.warning,
            Icons.pause_circle_outline,
          ),
          FocusTimerStatus.idle => (
            '准备开始',
            Colors.white54,
            Icons.timer_outlined,
          ),
        };
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(text, style: TextStyle(fontSize: 13, color: color)),
          ],
        );
      },
    );
  }

  Widget _buildTipsAndRest() {
    return ValueListenableBuilder<bool>(
      valueListenable: _timer.restDue,
      builder: (context, due, _) {
        // 到点休息时**只显示提醒卡**，提示先让位。
        //
        // 两块都留着的话，在小屏上提醒卡会被挤到需要滚动才能看见按钮的位置 ——
        // 一条「你该休息了」的提醒，还得先滑一下才能点「好」，本身就很不友好。
        // 知识点不会跑，休息只有现在这一次。
        if (due) return _buildRestNotice();
        return _buildTipCard();
      },
    );
  }

  Widget _buildRestNotice() {
    final minutes = _timer.restReminderMinutes.value;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: const Color(0x26FFB74D),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x66FFB74D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.visibility_outlined,
                size: 18,
                color: Color(0xFFFFC46B),
              ),
              SizedBox(width: 8),
              Text(
                '该让眼睛歇一会儿了',
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFFFD9A0),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '已经连续专注 $minutes 分钟。站起来走两步，看看窗外的远处 —— 20 秒就够。',
            style: TextStyle(
              fontSize: 13,
              height: 1.55,
              color: Colors.white.withValues(alpha: 0.82),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _takeBreak,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFFFD9A0),
                    side: const BorderSide(color: Color(0x88FFB74D)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text('好，去休息', style: TextStyle(fontSize: 13)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextButton(
                  onPressed: () => _timer.snoozeRest(),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white60,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text('再学 10 分钟', style: TextStyle(fontSize: 13)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTipCard() {
    if (widget.target.subject.trim().isEmpty) return const SizedBox.shrink();
    return ValueListenableBuilder<List<KnowledgeTip>>(
      valueListenable: _tips.tips,
      builder: (context, tips, _) {
        if (tips.isEmpty) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(
              '这个科目的错题还不多。做完作业批改后，这里会出现针对你的知识点提示。',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: Colors.white.withValues(alpha: 0.38),
              ),
            ),
          );
        }

        final tip = tips[_tipIndex % tips.length];
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 8, 10, 14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.lightbulb_outline,
                    size: 15,
                    color: Colors.white54,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${widget.target.subject} · 知识点提示',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Colors.white54,
                      ),
                    ),
                  ),
                  if (tips.length > 1)
                    TextButton(
                      onPressed: _rotateTip,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white54,
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        '换一条',
                        style: TextStyle(fontSize: 11.5),
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 6, top: 2),
                child: MathText(
                  tip.text,
                  style: TextStyle(
                    fontSize: 14.5,
                    height: 1.55,
                    color: Colors.white.withValues(alpha: 0.88),
                  ),
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: _tips.refreshing,
                builder: (context, refreshing, _) {
                  if (!refreshing) return const SizedBox.shrink();
                  return const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      '正在根据错题本更新…',
                      style: TextStyle(fontSize: 11, color: Colors.white30),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildControls(bool compact) {
    return ValueListenableBuilder<FocusTimerStatus>(
      valueListenable: _timer.status,
      builder: (context, status, _) {
        final running = status == FocusTimerStatus.running;
        return Column(
          children: [
            // 主按钮：整块是一个「闹钟上的那颗键」。
            // 只有这一颗是实心的，其余动作都是文字 —— 计时页不该有第二个
            // 需要选择的按钮。
            Material(
              color: running ? Colors.white : AppColors.primary,
              shape: const CircleBorder(),
              elevation: 0,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () {
                  if (status == FocusTimerStatus.idle) {
                    _timer.start(widget.target);
                    return;
                  }
                  if (running) {
                    _timer.pause();
                    unawaited(_save());
                  } else {
                    _timer.resume();
                  }
                },
                child: SizedBox(
                  width: compact ? 68 : 84,
                  height: compact ? 68 : 84,
                  child: Icon(
                    running ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: compact ? 34 : 40,
                    color: running ? const Color(0xFF0B0F14) : Colors.white,
                  ),
                ),
              ),
            ),
            SizedBox(height: compact ? 6 : 10),
            Text(
              running ? '暂停' : (status == FocusTimerStatus.idle ? '开始' : '继续'),
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
            SizedBox(height: compact ? 10 : 18),
            TextButton(
              onPressed: _saving ? null : () => unawaited(_finish()),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white70,
                disabledForegroundColor: Colors.white24,
              ),
              child: Text(_saving ? '正在保存…' : '结束并保存'),
            ),
            if (_saveError != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _saveError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: AppColors.danger),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 顶栏那颗小标签。
  ///
  /// 作业显示科目、计划显示「学习计划」、临时打卡显示它的标签 ——
  /// 三种目标在这一屏长得一样，学生得知道自己在给什么计时。
  String get _topBarLabel => switch (widget.target.kind) {
    FocusTargetKind.homework =>
      widget.target.subject.isEmpty ? '作业计时' : widget.target.subject,
    FocusTargetKind.plan => '学习计划',
    FocusTargetKind.free => widget.target.title,
  };

  Widget _buildFootnote() {
    final base = _timer.baseSeconds;
    final kind = widget.target.kind;
    return ValueListenableBuilder<int>(
      valueListenable: _timer.elapsedSeconds,
      builder: (context, seconds, _) {
        final total = base + seconds;
        final (historyLine, totalLine) = switch (kind) {
          FocusTargetKind.homework => (
            '这份作业此前已记录 ${formatStudyTime(base)}',
            total <= 0
                ? '只有计时中的时间会记入这份作业'
                : '结束后这份作业的实际用时将是 ${formatStudyTime(total)}',
          ),
          FocusTargetKind.plan => (
            '今天这个计划已投入 ${formatStudyTime(base)}',
            total <= 0
                ? '只有计时中的时间会记入今天'
                : '结束后今天的投入将是 ${formatStudyTime(total)}',
          ),
          // 临时打卡：说清楚会记到哪儿 —— 「记 20 分钟」却不知道记在哪，
          // 下次就不会再用了。
          FocusTargetKind.free => (
            '',
            total <= 0
                ? '只有计时中的时间会记入今天的「${widget.target.title}」'
                : '结束后「${widget.target.title}」将记入 ${formatStudyTime(total)}',
          ),
        };
        return Column(
          children: [
            if (base > 0 && historyLine.isNotEmpty)
              Text(
                historyLine,
                style: const TextStyle(fontSize: 12.5, color: Colors.white54),
              ),
            if (base > 0 && historyLine.isNotEmpty) const SizedBox(height: 4),
            Text(
              totalLine,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, color: Colors.white38),
            ),
          ],
        );
      },
    );
  }
}
