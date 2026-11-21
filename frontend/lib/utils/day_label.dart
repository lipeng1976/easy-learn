/// 界面上「哪一天」怎么说话（微信口径）。
///
/// 聊天分隔条和错题卡的日期共用这一份 —— 两处各写一个格式化函数的话，
/// 「今天」的边界（日历天 vs 满 24 小时）迟早有一边写错，而错的那边
/// 只在跨零点时看得出来。
///
/// ── 为什么要单独一个文件 ────────────────────────────────────────────────
///
/// 「今天 / 昨天 / 星期三 / 10月12日」这套规则看起来只有几行，但它有
/// 一堆边界：跨年、跨月、一周内、设备时钟比服务器快一点（消息时间在未来）。
/// 写在 widget 里就只能靠截图验，而截图看不出「12月31日 的昨天是 1月1日」
/// 这种错误。这里做成纯函数，`now` 可注入 —— 判据能把每一条边界单独钉住。
///
/// ⚠️ 传进来的一律是**本地时间**。两侧数据源已经统一过：
/// 云端 `timeOr` 走 `toLocal()`，本地库存的就是无时区的本地字符串。
/// 这里不再做时区换算 —— 两处都转会让它差 8 小时。
library;

const _weekdayLabels = [
  '星期一',
  '星期二',
  '星期三',
  '星期四',
  '星期五',
  '星期六',
  '星期日',
];

/// 两条消息是不是同一天。
///
/// 只比年月日，**不比时刻**：凌晨 00:05 和 23:55 是同一天，
/// 而用 `difference().inDays` 判断会把它们算成相邻的两天
/// （`inDays` 是「满 24 小时」的个数，不是「日历天」的差）。
bool isSameCalendarDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 日期分隔条上的文案。
///
/// | 距今 | 显示 |
/// |---|---|
/// | 当天 | `今天` |
/// | 1 天 | `昨天` |
/// | 2–6 天 | `星期三` |
/// | 同年更早 | `10月12日` |
/// | 跨年 | `2025年12月31日` |
///
/// ⚠️ 「1 天」按**日历天**算，不是 24 小时。23:59 发的消息，到第二天 00:01
/// 就该显示「昨天」，虽然只过了 2 分钟 —— 微信也是这个口径，因为人读的是日期。
String formatDayLabel(DateTime when, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final day = DateTime(when.year, when.month, when.day);
  final today = DateTime(current.year, current.month, current.day);
  final diff = today.difference(day).inDays;

  // `<= 0` 而不是 `== 0`：设备时钟比服务器快几秒时， newest 那条会落在
  // 「未来」，显示成「今天」比显示成日期或负数更不突兀。
  if (diff <= 0) return '今天';
  if (diff == 1) return '昨天';
  if (diff < 7) return _weekdayLabels[when.weekday - 1];
  if (when.year == current.year) return '${when.month}月${when.day}日';
  return '${when.year}年${when.month}月${when.day}日';
}

/// 气泡下方的时间：`14:05`。
///
/// 用 24 小时制、不显示秒 —— 聊天里秒没有意义，而它会让每行都多两个字符。
String formatClock(DateTime when) => '${_two(when.hour)}:${_two(when.minute)}';

String _two(int value) => value < 10 ? '0$value' : '$value';
