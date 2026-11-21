import '../services/ai_data_source.dart';

/// 降级事件的**进程内**留痕。
///
/// ## 为什么不直接用 `AiStatusController`
///
/// 那个控制器是**学生首页的生命周期**：它跟着首页 `Get.put`，离开时被回收。
/// 而观察页是家长端的一个独立路由 —— 家长打开它的时候，学生首页早就销毁了，
/// 拿到的是一个空列表。做成静态的进程内日志之后，
/// 「学生这一轮用下来到底降级了几次」在同一个 App 运行周期里都查得到。
///
/// ## 为什么不落库
///
/// 降级记录的价值随时间迅速衰减：它回答的是「**刚才**这次是不是离线结果」，
/// 而不是「上个月降级过几次」。为此建一张表、加一次迁移，
/// 换来一份几乎不会被回看的流水，不划算。
/// 真要做长期统计，正确的位置是**网关侧的审计日志**（它本来就在记
/// `ok:false` 与错误码），而不是客户端这台设备上的半份副本。
///
/// 因此本日志的语义被明确限定为：**本机、本次启动以来**。
/// 观察页必须把这句话显示出来，否则用户会把它当成全局统计。
class AiDegradationLog {
  AiDegradationLog._();

  /// 上限。超过就丢最旧的 —— 降级持续发生时最需要看到的是**最近**几条，
  /// 而无限增长的内存列表在长时间运行的 Web 端会真的涨上去。
  static const int capacity = 50;

  static final List<AiDegradation> _events = [];

  /// 最近一次降级。null 表示本次启动还没降级过。
  static AiDegradation? get latest => _events.isEmpty ? null : _events.last;

  /// 全部记录，最新的在前（界面按这个顺序渲染）。
  static List<AiDegradation> get events => _events.reversed.toList();

  static int get count => _events.length;

  static void add(AiDegradation event) {
    _events.add(event);
    if (_events.length > capacity) {
      _events.removeRange(0, _events.length - capacity);
    }
  }

  /// 测试用。
  static void clear() => _events.clear();
}
