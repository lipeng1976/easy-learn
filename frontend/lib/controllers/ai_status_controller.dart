import 'dart:async';

import 'package:get/get.dart';

import '../services/ai_data_source.dart';
import '../services/ai_degradation_log.dart';

/// AI 降级的**跨页面**状态位。
///
/// ## 为什么需要它
///
/// 本地兜底给出的是通用模板，摆出来煞有介事 —— 一份「分数计算要多练」的讲解
/// 和模型真给的讲解在界面上长得一模一样。如果降级只写进日志，学生就会
/// 把模板当成针对自己错题的讲解，而这件事**没有任何办法事后补救**。
///
/// ## 为什么是控制器而不是各个页面各弹一个 SnackBar
///
/// 降级发生在数据层，而页面有七八个（作业、复习、错题详情、组卷、检查…）。
/// 逐个页面弹 SnackBar 的结果必然是漏掉大多数：最容易漏的恰恰是
/// **后台自己跑起来的那些调用**（进首页时的能力探测、自动批改），
/// 而它们不挂在任何一个页面的生命周期上。
///
/// 所以只维护一个状态位，由首页统一渲染成一条横幅。
class AiStatusController extends GetxController {
  AiStatusController({this.autoHideAfter = const Duration(seconds: 20)});

  /// 提示自动消失的时间。
  ///
  /// 用超时而不是等一个「恢复」信号，是因为**没有这个信号**：
  /// 数据层只上报降级、不上报「这次成功」，而给每次成功都加一条回调
  /// 等于把遥测塞进业务主路径。折中是短窗口：降级只发生一次就不打扰太久，
  /// 持续降级则因为每次都会续期而一直显示。
  final Duration autoHideAfter;

  /// 最近一次降级。`null` 表示当前没有需要提示的降级。
  final Rx<AiDegradation?> latest = Rx<AiDegradation?>(null);

  /// 本次会话累计降级次数。
  ///
  /// 与 [latest] 分开：只显示「最近一次」会让人以为偶发，
  /// 而「连续 5 次」和「偶尔 1 次」需要的反应完全不同
  /// （前者是服务端挂了，后者可能只是某一次超时）。
  final RxInt totalCount = 0.obs;

  Timer? _timer;

  /// 是否正在显示降级提示。
  bool get isShowing => latest.value != null;

  /// 记一次降级。
  void report(AiDegradation event) {
    totalCount.value += 1;
    latest.value = event;
    // 同时写进进程级日志：横幅是短命的（超时就消失），
    // 而「刚才到底降级了几次」需要活得比横幅久。
    // 观察页在其他路由、甚至另一个角色的会话里，靠的就是这一份。
    AiDegradationLog.add(event);
    _timer?.cancel();
    _timer = Timer(autoHideAfter, () => latest.value = null);
  }

  /// 手动关掉提示。**不重置累计次数** —— 关掉横幅表示「我知道了」，
  /// 不表示「这件事没发生过」。
  void dismiss() {
    _timer?.cancel();
    latest.value = null;
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }
}
