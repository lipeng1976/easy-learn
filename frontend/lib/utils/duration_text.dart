/// 时间文本的唯一格式来源。
///
/// 计时界面、作业卡片、家长端看到的是**同一个数**，只是粒度不同。
/// 各页面自己拼 `${m}分${s}秒` 的后果不是「不好看」，是同一份数据在两处
/// 说成不同的量（一处四舍五入到分、一处截断到秒），而家长与孩子对照时
/// 会以为是计时出了错。
library;

/// `HH:MM:SS` —— 计时器的主显示。
///
/// 小时位**始终显示**，不因为不足一小时而隐藏：这一屏的字号是整页最大的，
/// 位数一变（`12:34` → `01:12:34`）整块文字会横向跳一下，
/// 而计时器最不该给人的感觉就是「它在抖」。
///
/// 负数按 0 处理（时钟回拨、或调用方传错）：显示 `-00:00:03` 只会让人
/// 以为计时器坏了，而真实原因在这里无法表达。
String formatClock(int seconds) {
  final total = seconds < 0 ? 0 : seconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  return '${_two(h)}:${_two(m)}:${_two(s)}';
}

/// 人读的用时：`3 秒` / `12 分 34 秒` / `1 小时 2 分`。
///
/// 一小时以上**丢掉秒**：到这个量级，秒已经不影响「我大概花了多久」的判断，
/// 而多两位数字会让卡片上的这一行换行。
///
/// ⚠️ 0 返回「0 秒」。要不要显示这一行由调用方决定（`HomeworkItem.hasActualTime`），
/// 因为「还没计过时」与「计时了 0 秒」在数据上是同一个值 —— 这个函数不替它猜。
String formatStudyTime(int seconds) {
  final total = seconds < 0 ? 0 : seconds;
  if (total < 60) return '$total 秒';
  if (total < 3600) {
    final m = total ~/ 60;
    final s = total % 60;
    return s == 0 ? '$m 分' : '$m 分 $s 秒';
  }
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  return m == 0 ? '$h 小时' : '$h 小时 $m 分';
}

String _two(int value) => value < 10 ? '0$value' : '$value';
