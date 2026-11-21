import 'database_service.dart';

/// 本机偏好（目前只有一件事：连续学多久提醒休息）。
///
/// ## 为什么存本机、不进用户档案
///
/// 这是「这台设备上的节奏」，不是孩子的属性。换一台手机、换一个平板，
/// 屏幕大小与使用场景都变了，阈值本来就该重新设一次；
/// 把它写进 `app_user` 还有一个具体后果 —— 家长端也会跟着看到并覆盖它。
///
/// 存法见 `app_setting` 表（v27），按 key 覆盖，不需要迁移结构。
abstract final class AppSettings {
  static const String restReminderKey = 'focus.restReminderMinutes';

  /// 默认 40 分钟：一节课的长度。低于 25 分钟提醒太碎，
  /// 高于 60 分钟对小学/初中生已经起不到「保护眼睛」的作用了。
  static const int defaultRestReminderMinutes = 40;

  /// 可选值。`0` = 不提醒。
  static const List<int> restReminderOptions = [25, 40, 50, 60, 0];

  /// 读提醒阈值。
  ///
  /// 读不到 / 读坏了都回到默认值 40，**不抛**：这是设置项，
  /// 它坏掉的正确表现是「用默认节奏」，而不是让计时页打不开。
  static Future<int> restReminderMinutes() async {
    String? raw;
    try {
      raw = await DatabaseService.instance.readLocalSetting(restReminderKey);
    } catch (_) {
      return defaultRestReminderMinutes;
    }
    final parsed = int.tryParse(raw ?? '');
    if (parsed == null) return defaultRestReminderMinutes;
    // 0 是合法值（不提醒）。负数与超过 3 小时的都按脏数据处理。
    if (parsed < 0 || parsed > 180) return defaultRestReminderMinutes;
    return parsed;
  }

  /// 写提醒阈值。写失败不抛：这次设置没生效，下次进页面会读到旧值 ——
  /// 比让「选个 25 分钟」把页面炸掉要好。
  static Future<void> setRestReminderMinutes(int minutes) async {
    try {
      await DatabaseService.instance.writeLocalSetting(
        restReminderKey,
        '$minutes',
      );
    } catch (_) {
      // 见上。设置项不是关键路径。
    }
  }

  /// 给界面用的一句话（「40 分钟」「不提醒」）。
  static String label(int minutes) =>
      minutes <= 0 ? '不提醒' : '$minutes 分钟';
}
