/// 服务端回传的照片用量 —— 「还剩几张」这件事的**唯一来源**。
///
/// ## 为什么这些数字必须由服务端给，客户端不自己算
///
/// 客户端的本地计数永远慢一步：照片行可能是别的设备写进去的、也可能被家长端
/// 清过场（`deleteHomeworkImagesByHomeworkId`）。本地算出来的「已用」只反映
/// **这台设备**见过什么，而配额是**服务端**按学生名下的行数判的。
/// 两边一旦不同步，症状是「这边说还剩 500 张、传上去却回 409」——
/// 而那时学生会以为是自己手机的问题。
///
/// [warnRemaining]（阈值）与 [nearLimit]（结论）同样由服务端给：
/// 客户端只负责把 [nearLimit] 翻译成人话。阈值在客户端抄一份的话，
/// 改配额的人不会想到还有第二处要改，症状是「阈值配了却不见效」。
///
/// ## ⚠️ 它是**附加信息**，拿不到不许影响主流程
///
/// 解析不出来一律回 null（见 [tryParse]），调用方当作「这次没有用量可提示」。
/// 把它当必需字段的后果是：服务端某次改字段名就会让**每一次提交都失败**，
/// 而失败信息看着像网络问题 —— 排查方向从一开始就是错的。
class PhotoUsage {
  const PhotoUsage({
    required this.used,
    required this.quota,
    required this.remaining,
    required this.warnRemaining,
    required this.nearLimit,
  });

  /// 该学生名下**已经存下的**照片张数。
  final int used;

  /// 上限（服务端的 `IMAGE_QUOTA_PER_STUDENT`）。
  final int quota;

  /// 还能再存几张。服务端已经 `max(0, ...)` 过，不会为负。
  final int remaining;

  /// 剩余少到等于它就算「接近上限」（服务端的 `IMAGE_QUOTA_WARN_REMAINING`）。
  final int warnRemaining;

  /// 是否接近上限 —— **服务端下的结论**。
  final bool nearLimit;

  /// 从服务端响应里解析；形状不对回 null（理由见类文档）。
  ///
  /// 逐个字段 `is num` 地判，而不是 `as int`：JSON 里的数字可能是 `double`
  /// （`3000` 被某个中间层转成 `3000.0`），直接 `as int` 会抛 `_TypeError`，
  /// 而那个异常会冒到提交那条链路上，把一次成功的提交说成失败。
  static PhotoUsage? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final used = _intOf(raw['used']);
    final quota = _intOf(raw['quota']);
    final remaining = _intOf(raw['remaining']);
    final warnRemaining = _intOf(raw['warnRemaining']);
    if (used == null || quota == null || remaining == null || warnRemaining == null) {
      return null;
    }
    return PhotoUsage(
      used: used,
      quota: quota,
      remaining: remaining,
      warnRemaining: warnRemaining,
      // 缺 `nearLimit` 时按同一条规则自己判一次：服务端少给这一个字段
      // 不该让提示整个消失（它只是少了「谁下的结论」这一层）。
      nearLimit: raw['nearLimit'] is bool
          ? raw['nearLimit'] as bool
          : remaining <= warnRemaining,
    );
  }

  static int? _intOf(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  @override
  String toString() => 'PhotoUsage($used/$quota, 剩 $remaining, 阈值 $warnRemaining, 接近=$nearLimit)';
}
