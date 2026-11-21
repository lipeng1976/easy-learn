import 'dart:async';

import 'package:get/get.dart';

import '../services/data_staleness_log.dart';

/// 数据层「不新鲜 / 没保存」的**跨页面**状态位（迁移计划 §7 方案 B）。
///
/// ## 它订阅，而不是被注入
///
/// `DataApiClient` 在 `main()` 里、`runApp` **之前**就被装配好了
/// （见 `CloudRuntime.fromEnvironment`），那时没有任何控制器。所以方向必须是
/// 「传输层广播 → 控制器订阅」，反过来（构造时把一个控制器递给传输层）
/// 就得保证「先建控制器、再装配传输层」这个顺序，而那是一次**写错就只在
/// 启动那一瞬间出错**的依赖 —— 症状是「第一次事件没人报」。
///
/// ## 为什么是控制器而不是各页弹 SnackBar
///
/// 读发生在九个仓库、七八个页面上，最容易漏的恰恰是后台自己跑起来的那些读
/// （进首页时的列表加载、提交之后的重新拉取）。逐个页面弹一次的结果必然是
/// 漏掉大多数，所以只维护一个状态位、由首页统一渲染成一条横幅。
class DataStatusController extends GetxController {
  DataStatusController({this.autoHideAfter = const Duration(seconds: 20)});

  /// 提示自动消失的时间。
  ///
  /// 用超时而不是等一个「恢复」信号，是因为**没有这个信号**：
  /// 传输层只上报失败、不上报「这次成功了」，而给每次成功都加一条回调
  /// 等于把遥测塞进业务主路径。折中是短窗口：偶发一次就不打扰太久，
  /// 持续离线则因为每次读都会续期而一直显示 —— 这恰好是想要的行为。
  final Duration autoHideAfter;

  /// 最近一次事件。`null` 表示当前没有需要提示的。
  final Rx<DataStaleness?> latest = Rx<DataStaleness?>(null);

  /// 本次会话累计次数。
  ///
  /// 与 [latest] 分开：只显示「最近一次」会让人以为是偶发，
  /// 而「已经 12 次」和「刚第 1 次」需要的反应完全不同。
  final RxInt totalCount = 0.obs;

  Timer? _timer;
  void Function()? _unsubscribe;

  bool get isShowing => latest.value != null;

  @override
  void onInit() {
    super.onInit();
    _unsubscribe = DataStalenessLog.subscribe(report);
    // 订阅的作用是「从此刻起」。而横幅可能不是第一个建起来的
    // （学生首页与家长首页各挂一个，切角色会重建），事件却是单次广播的 ——
    // 不补现状的话，第二个页面上的横幅要等到**下一次**事件才出现，
    // 而那时用户已经在看一份旧数据了。
    _adoptExisting();
  }

  /// 把订阅之前就已经发生的那一次补上。
  void _adoptExisting() {
    final existing = DataStalenessLog.latest;
    if (existing == null) return;
    totalCount.value = DataStalenessLog.count;
    latest.value = existing;
    _timer?.cancel();
    _timer = Timer(autoHideAfter, () => latest.value = null);
  }

  /// 记一次事件。由订阅回调调用（测试里也可以直接调）。
  ///
  /// ⚠️ 这里**只更新界面状态，不写日志**。日志由传输层写入，而写入时正是
  /// 广播的时机 —— 在这里再 `add` 一次会触发一次新的广播，于是
  /// `add → 广播 → report → add → …` 无限递归。第一次真跑就会栈溢出。
  void report(DataStaleness event) {
    totalCount.value += 1;
    latest.value = event;
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
    _unsubscribe?.call();
    _unsubscribe = null;
    _timer?.cancel();
    super.onClose();
  }
}
