/// 业务操作结果。
///
/// 控制器不再用「弹个 snackbar 然后什么都不返回」的方式表达失败：
/// 页面拿不到结果就无法区分「提交成功」和「状态不允许提交」，
/// 自动化测试也无从断言。所有有副作用的写操作统一返回 [OpResult]。
class OpResult {
  const OpResult._(this.ok, this.message);

  const OpResult.success([String message = '']) : this._(true, message);

  const OpResult.fail(String message) : this._(false, message);

  final bool ok;

  /// 成功时为提示语（可为空），失败时为失败原因。
  final String message;

  @override
  String toString() => ok ? 'OpResult.ok($message)' : 'OpResult.fail($message)';
}
