/// 数据层「不新鲜 / 没保存」的一次留痕（迁移计划 §7 方案 B）。
///
/// ## 为什么必须有这个东西
///
/// 方案 B 让断网时**仍然读得到数据**（来自缓存）。这消掉了纯在线方案的
/// 那个致命表现（断网 = 空列表 = 「我昨天的作业全没了」），
/// 但同时制造了一个新的、更隐蔽的误解：
///
/// > 用户看到的是一份**和实时数据长得一模一样**的旧数据。
///
/// 界面上没有任何东西能把「这是今早同步的」与「这是此刻的」区分开 ——
/// 而这正是最难挽回的一类错：家长看到一个「已完成」而孩子其实刚改成
/// 「未交」，他会基于这个数字做判断，并且**不会再回来核对**。
///
/// 所以「正在显示旧数据」必须是个能被读到的信号，不是一个只写进日志的事实。
///
/// ## 为什么不做成 SnackBar
///
/// 同 `AiStatusController` 的理由：读发生在**九个仓库、七八个页面**上，
/// 最容易漏的恰恰是后台自己跑起来的那些读（进首页时的列表加载、
/// 提交之后的重新拉取）。逐个页面弹一次的结果必然是漏掉大多数，
/// 所以只维护一个状态位、由首页统一渲染成一条横幅。
class DataStaleness {
  const DataStaleness({
    required this.kind,
    required this.reason,
    this.at,
  });

  final DataStalenessKind kind;

  /// 给人看的一句话。**直接可展示**。
  final String reason;

  /// 发生时间。为 null 时由日志补当前时间。
  final DateTime? at;

  @override
  String toString() => '[${kind.name}] $reason';
}

/// 两种**必须让用户知道**的数据层事件。
///
/// 刻意只有两种：多一种就多一次「用户决定忽略横幅」的机会，
/// 而这两种的共同点是**用户此刻的判断会建立在错的前提上**。
enum DataStalenessKind {
  /// 读到了旧数据：断网，界面显示的是上一次同步下来的内容。
  staleRead,

  /// 写没成功：断网，这次修改**没有保存**，而且本地也没有留。
  ///
  /// 这一条是方案 B「写必须在线」的配套。没有它的话，「写必须在线」
  /// 会退化成「写悄悄丢了」—— 因为控制器里的写路径全是 `catch (_)`，
  /// 用户看到的是一次「看起来成功」的提交。
  writeDropped,
}

/// 进程内日志 + 实时订阅点。
///
/// ## 为什么是静态的（而不是 GetX 控制器）
///
/// `DataApiClient` 在 `main()` 里、`runApp` **之前**就被装配出来了
/// （见 `CloudRuntime.fromEnvironment`）。那时候还没有 GetX 容器，
/// 也还没有任何一个页面 —— 所以传输层不能持有控制器。
///
/// 反过来，控制器是后来才出现的，于是它**订阅**这里。方向是
/// 「服务层广播、界面层订阅」，而不是「服务层往上找界面」。
/// 与 `AiRuntime.onDegraded` 回调相比，这样做的好处是不需要保证
/// 「先建提示位、再装配运行时」那个顺序 —— 那种顺序依赖一旦写错，
/// 症状是「第一次事件没人报」，而它只在启动那一瞬间发生。
///
/// ## 为什么不落库
///
/// 同 `AiDegradationLog`：它回答的是「**刚才**这次是不是旧的」，
/// 而不是「这个月旧过几回」。长期统计的正确位置是服务端的审计日志
/// （它本来就在记每个请求），而不是客户端这台设备上的半份副本。
class DataStalenessLog {
  DataStalenessLog._();

  /// 上限。持续离线时最需要看到的是最近几条，而无限增长的列表
  /// 在长时间运行的 Web 端会真的涨上去。
  static const int capacity = 50;

  static final List<DataStaleness> _events = <DataStaleness>[];
  static final List<void Function(DataStaleness)> _listeners = [];

  /// 订阅新事件。返回取消订阅的函数。
  static void Function() subscribe(void Function(DataStaleness) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// 最近一次。null 表示本次启动没有发生过。
  static DataStaleness? get latest => _events.isEmpty ? null : _events.last;

  /// 全部记录，最新的在前（界面按这个顺序渲染）。
  static List<DataStaleness> get events => _events.reversed.toList();

  static int get count => _events.length;

  /// 传输层调用它。**不抛异常、不阻塞** —— 上报不能反过来影响那次请求。
  static void add(DataStaleness event) {
    _events.add(event);
    if (_events.length > capacity) {
      _events.removeRange(0, _events.length - capacity);
    }
    for (final listener in List.of(_listeners)) {
      try {
        listener(event);
      } catch (_) {
        // 一个订阅者坏掉不该让整条读路径失败。这里的异常如果冒出去，
        // 会把一次**成功的读**变成失败 —— 那是最不值的一种连带损失。
      }
    }
  }

  /// 测试用。
  static void clear() {
    _events.clear();
    _listeners.clear();
  }
}
