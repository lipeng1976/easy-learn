import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

/// 日期工具。**只此一份** —— 三个页面原先各写了一遍 `_isSameDay`。
///
/// 抽出来的理由不是「少写几行」，而是这类比较**很容易写出「差一天」的版本**
/// 而没有任何东西会报错：
///   · 用 `DateTime ==` 比 —— 带时分秒的两个时刻永远不等，选中态看上去没反应；
///   · 用 `difference(...).inDays == 0` —— 跨零点时因时长不足 24 小时而复真，
///     于是「昨天」也亮着；
///   · 忘了 `toLocal()` —— UTC 存的时刻在本地夜里会被算到另一天，
///     这正是本项目 R3 那次（时间上行不带时区 → 静默偏一整天）的同一个坑。
///
/// 这里统一成「先 `toLocal()` 再逐字段比年/月/日」，与原先三处逐字相同，
/// 所以是**行为零变化**的搬迁。
class DayUtil {
  const DayUtil._();

  /// 同一天（按**本地时区**的日历日判断）。
  static bool isSameDay(DateTime first, DateTime second) {
    final a = first.toLocal();
    final b = second.toLocal();
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  /// 抹掉时分秒，只留本地日历日。用于比较与做 Map 的键。
  ///
  /// ⚠️ 用本地日的 `yyyy-MM-dd` 字符串当键，**不要**用 `DateTime` 本身：
  /// `DateTime` 的 `==` 带毫秒，当键会出现「同一天两个键」。
  static DateTime dayOnly(DateTime d) {
    final local = d.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  /// 本地日的 `yyyy-MM-dd`。这是与服务端 `GET /data/calendar/summary`
  /// 约定的日期形制（`month` 参数与响应里的 `date` 字段都是这个）。
  static String dayKey(DateTime d) {
    final local = d.toLocal();
    final m = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$m-$day';
  }

  /// 本地日的 `yyyy-MM`。月摘要的请求参数。
  static String monthKey(DateTime d) {
    final local = d.toLocal();
    final m = local.month.toString().padLeft(2, '0');
    return '${local.year}-$m';
  }

  /// 某一天的 `[本地日 00:00, 次日 00:00)` 对应的两个 UTC 瞬时。
  ///
  /// ## 为什么这个换算在客户端做，而不是把日期直接传给服务端
  ///
  /// `history_data` 那一侧的列是 `timestamptz`（绝对时刻），而「这是哪一天」
  /// 取决于看的人在哪个时区。服务端**不知道**用户在哪个时区，也不该猜 ——
  /// 猜错就是静默偏一整天（R3 的教训）。所以约定是：
  /// **客户端算好两个 UTC 瞬时传上去，服务端只做 `t >= from and t < to`。**
  ///
  /// 注意 `to` 是**次日零点**而不是「当日 23:59:59」：`to` 是**开**区间，
  /// 传次日零点可以把「23:59:59.500」这种也包进来，不会因为精度丢一毫秒的记录。
  /// 服务端那几条断言盯着「右开」这件事（见 `test/calendar.test.js`）。
  static ({DateTime from, DateTime to}) localDayWindow(DateTime day) {
    final start = dayOnly(day);
    return (from: start.toUtc(), to: start.add(const Duration(days: 1)).toUtc());
  }

  /// 这个月的第一天（本地）。
  static DateTime firstDayOfMonth(DateTime d) {
    final local = d.toLocal();
    return DateTime(local.year, local.month, 1);
  }

  /// 这个月有多少天。
  static int daysInMonth(DateTime d) {
    final local = d.toLocal();
    // 「下个月 0 号」= 这个月最后一天。比 `[1,3,5,...]` 那种表可靠。
    return DateTime(local.year, local.month + 1, 0).day;
  }
}

/// 某一周 / 某一天的「有没有数据」。
///
/// 三个数字与 `GET /data/calendar/summary` 的响应字段**一一对应**
/// （`homework` / `workout` / `checkin`）。用命名构造而不是位置参数：
/// 三项都是 int，位置传反了编译器不会响，而症状是「作业的点点在运动格子上」。
class DayMarks {
  final int homework;
  final int workout;
  final int checkin;

  const DayMarks({this.homework = 0, this.workout = 0, this.checkin = 0});

  /// 有没有任何数据。日历用它决定「这天要不要打点」。
  bool get isEmpty => homework == 0 && workout == 0 && checkin == 0;

  /// 打点最多显示 3 个（再多就糊成一团了）。
  static const int maxDots = 3;

  /// 供打点用的「有数据的类别数」，上限 [maxDots]。
  int get dotCount {
    var n = 0;
    if (homework > 0) n++;
    if (workout > 0) n++;
    if (checkin > 0) n++;
    return n > maxDots ? maxDots : n;
  }

  /// 从服务端摘要的一行解析。**缺字段按 0 处理**，不抛异常 ——
  /// 摘要端点只回「有数据的天」，某一天可能只有作业没有打卡，
  /// 那时 `checkin` 键在响应里根本不存在。
  factory DayMarks.fromJson(Map<String, dynamic> json) {
    int pick(String key) {
      final v = json[key];
      if (v is int) return v;
      if (v is num) return v.toInt();
      return 0;
    }

    return DayMarks(homework: pick('homework'), workout: pick('workout'), checkin: pick('checkin'));
  }
}

/// 一周七格。**选中态由调用方持有**（实例字段，不是 `static`）。
///
/// ## 为什么这个类必须是 `StatelessWidget` 且**不持有选中态**
///
/// 它原来的三份拷贝里有两种存法：
///   · `workout_tab` / `overview_tab` 用实例字段（正常）；
///   · `homework_tab` 用 `static final Rx<DateTime> _selectedDate`
///     —— 那是**跨实例共享的全局状态**。测试里一个用例改了选中日期，
///     另一个用例看得见（串测）；将来做「记忆上次查看位置」也会串。
///
/// 抽公共控件时把这件事**在类型上**定死：选中态是构造参数，组件只负责画。
/// 这样新加一处日历时，没有「顺手写成 static」的机会。
class WeekStrip extends StatelessWidget {
  /// 当前选中的那一天。
  final DateTime selectedDate;

  /// 「今天」。显式传入而不是内部 `DateTime.now()`：
  /// 测试与走查要能钉住「今天是哪天」，否则断言会随运行日期漂移。
  final DateTime today;

  final ValueChanged<DateTime> onDateSelected;

  /// 点右侧日历图标。为 null 时不显示图标（保持向后兼容）。
  final VoidCallback? onPickMonth;

  /// 每一天的打点（按 [DayUtil.dayKey] 取）。为 null 时不打点。
  ///
  /// 默认 null 是刻意的：周历在**没有**摘要数据时应当**照常显示日期**，
  /// 只是没有小点。这样摘要请求失败/慢不会让日历本身消失
  /// （同「它是加速手段，不是数据通路」的处置）。
  final Map<String, DayMarks>? marks;

  const WeekStrip({
    super.key,
    required this.selectedDate,
    required this.today,
    required this.onDateSelected,
    this.onPickMonth,
    this.marks,
  });

  @override
  Widget build(BuildContext context) {
    // 显示哪一周？**跟着选中日期走**，不是「永远显示今天那一周」。
    //
    // ⚠️ 这是与原实现的一个**行为差异，而且是必要的**：原实现锚在 `today`，
    // 所以从月历里选了 3 个月前的某天之后，周历仍然显示本周 ——
    // 那 7 格里**没有一格是选中的**，用户看到「点了日期但没任何东西亮起来」。
    // 锚在 `selectedDate` 上，选中的那天必然在可见范围内。
    //
    // 未选中（= 选中就是今天）时，两者等价 —— 所以这不是「顺手改」，
    // 它是「月历跳转」这个新能力的前提。
    final anchor = DayUtil.dayOnly(selectedDate);
    final monday = anchor.subtract(Duration(days: anchor.weekday - 1));
    const labels = ['一', '二', '三', '四', '五', '六', '日'];

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          ...List.generate(7, (index) {
            final date = monday.add(Duration(days: index));
            final isSelected = DayUtil.isSameDay(date, selectedDate);
            final isToday = DayUtil.isSameDay(date, today);
            final dayMarks = marks?[DayUtil.dayKey(date)];
            return Expanded(
              child: GestureDetector(
                onTap: () => onDateSelected(date),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: isSelected ? AppColors.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    border: isToday && !isSelected
                        ? Border.all(color: AppColors.primary)
                        : null,
                  ),
                  child: Column(
                    children: [
                      Text(
                        labels[index],
                        style: TextStyle(
                          color: isSelected ? Colors.white : AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${date.day}',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: isSelected ? Colors.white : AppColors.text,
                        ),
                      ),
                      // 高度固定：有「今天」两个字的一格比别的格高，
                      // 会让整行随选中状态跳动。原实现是靠 `if (isToday)` 加一个
                      // SizedBox，选中今天时又去掉 —— 周历会在点「今天」时抖一下。
                      SizedBox(
                        height: 16,
                        child: _FootNote(isToday: isToday, isSelected: isSelected, marks: dayMarks),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
          if (onPickMonth != null)
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: IconButton(
                // 日历图标：点它弹完整月历（历史数据方案 §2.1）。
                // 放在周历**右侧**而不是页面上方，是因为它属于日历这个控件 ——
                // 用户找不到「历史」入口时，第一眼会看向日历。
                icon: const Icon(Icons.calendar_month_outlined, size: 20),
                color: AppColors.primary,
                tooltip: '查看历史日期',
                visualDensity: VisualDensity.compact,
                onPressed: onPickMonth,
              ),
            ),
        ],
      ),
    );
  }
}

/// 格子底部：优先显示「今天」，其次显示打点。
///
/// 两者同时出现时（今天是今天且有数据）显示「今天」—— 那个信息的价值更高，
/// 而打点在选中时也看得到列表。
class _FootNote extends StatelessWidget {
  final bool isToday;
  final bool isSelected;
  final DayMarks? marks;

  const _FootNote({required this.isToday, required this.isSelected, this.marks});

  @override
  Widget build(BuildContext context) {
    if (isToday) {
      return Text(
        '今天',
        style: TextStyle(
          fontSize: 10,
          color: isSelected ? Colors.white : AppColors.primary,
        ),
      );
    }
    final m = marks;
    if (m == null || m.isEmpty) return const SizedBox.shrink();

    final dotColor = isSelected ? Colors.white : AppColors.primary;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(
        m.dotCount,
        (_) => Container(
          width: 4,
          height: 4,
          margin: const EdgeInsets.symmetric(horizontal: 1.5),
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

/// 完整月历弹层。**这是「查历史」的入口**。
///
/// ## 里面必须有四样，少一样就会立刻回来问第二次
///
/// 1. **可翻月**（左右箭头 + 年月标题）；
/// 2. **有数据的日期打点** —— 没有它就只能让人一格一格点；
/// 3. **回今天**按钮 —— 翻远了没有回来的路，是最常见的抱怨；
/// 4. **范围钳制**：晚于今天不可选（未来还没发生），早于 [earliestDate] 不可选
///    （更早的时候这个孩子还没数据）。
///
/// ## 为什么用 `showModalBottomSheet` 而不是 `Get.dialog`
///
/// 与项目里其他弹层保持一致（用 `Get.bottomSheet` 风格的模态）。**关键不在这里**，
/// 而在「弹层关闭后调用方怎么拿到结果」——见下面 [pick] 的说明。
///
/// ## ⚠️ 不要在 `await` 之后立即 `dispose()` 控制器
///
/// 这个控件本身没有 `TextEditingController`，所以不涉及那个坑；
/// 但记在这里因为它是本项目**真机报回来的**一个 bug（`5b16c00`）：
/// `Get.dialog` 的 Future 在 `pop()` 被**调用那一瞬**就完成（`Route.didComplete`），
/// **不等退场动画**，所以「await 完就 dispose」会在动画期间被重建的
/// `TextField` 撞上已释放的控制器。
class MonthPickerSheet extends StatefulWidget {
  /// 当前选中的那一天（打开时高亮）。
  final DateTime selectedDate;

  /// 今天。显式传入，理由同 [WeekStrip.today]。
  final DateTime today;

  /// 可选的最早一天（含）。为 null 表示不限（不推荐 —— 见 §2.1 的第 4 条）。
  final DateTime? earliestDate;

  /// 每一天的打点。按 [DayUtil.dayKey] 取。
  final Map<String, DayMarks> marks;

  /// 翻月时回调：`(该月第一天)`。调用方据此去取那个月的摘要。
  ///
  /// **由调用方去取**（而不是在这个 StatefulWidget 里发请求）：
  /// 摘要请求要缓存、要处理失败、要按学生切换，那些都属于页面/控制器的职责。
  /// 这个控件只管「用户想看哪个月」，这样它在测试里可以完全脱网跑。
  final ValueChanged<DateTime>? onMonthChanged;

  /// 某个月是不是正在加载摘要。为 true 时在下方显示一行提示 ——
  /// **不要显示转圈遮住日历**：日历本身是可用的（只是没打点），
  /// 遮住它会让用户在等的时候连日期都点不了。
  final bool loading;

  const MonthPickerSheet({
    super.key,
    required this.selectedDate,
    required this.today,
    this.earliestDate,
    this.marks = const {},
    this.onMonthChanged,
    this.loading = false,
  });

  /// 弹出月历，返回选中的那一天；用户没选（点了外面/取消）时返回 null。
  ///
  /// ⚠️ 返回 null 与「选了今天」必须能区分开，所以这里返回 `DateTime?` 而不是
  /// 直接回一个默认值 —— 后者会让「用户取消了」变成「用户选了今天」。
  static Future<DateTime?> pick(
    BuildContext context, {
    required DateTime selectedDate,
    required DateTime today,
    DateTime? earliestDate,
    Map<String, DayMarks> marks = const {},
    ValueChanged<DateTime>? onMonthChanged,
    ValueNotifier<bool>? loading,
    ValueNotifier<Map<String, DayMarks>>? marksNotifier,
  }) {
    return showModalBottomSheet<DateTime>(
      context: context,
      // 内容高度是自适应的（6 行 × 7 列 + 标题 + 按钮），
      // 固定高度会在小屏上被裁掉最后一行（也就是「回今天」按钮）。
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ValueListenableBuilder<bool>(
        valueListenable: loading ?? ValueNotifier<bool>(false),
        builder: (_, isLoading, child) => ValueListenableBuilder<Map<String, DayMarks>>(
          valueListenable: marksNotifier ?? ValueNotifier<Map<String, DayMarks>>(marks),
          builder: (_, liveMarks, child) => MonthPickerSheet(
            selectedDate: selectedDate,
            today: today,
            earliestDate: earliestDate,
            marks: liveMarks,
            onMonthChanged: onMonthChanged,
            loading: isLoading,
          ),
        ),
      ),
    );
  }

  @override
  State<MonthPickerSheet> createState() => _MonthPickerSheetState();
}

class _MonthPickerSheetState extends State<MonthPickerSheet> {
  /// 正在显示的月份（该月 1 号，本地）。
  ///
  /// ⚠️ **这是实例字段，不是 `static`** —— 见 [WeekStrip] 的说明。
  /// 原来的 `homework_tab` 那份把选中日期写成 `static final Rx`，
  /// 那是跨实例共享的全局状态，测试之间会串。
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    _month = DayUtil.firstDayOfMonth(widget.selectedDate);
  }

  void _goMonth(int delta) {
    final next = DateTime(_month.year, _month.month + delta, 1);
    // 不让用户翻到未来（未来的日期没有「历史」可看）。
    if (next.isAfter(DayUtil.firstDayOfMonth(widget.today))) return;
    setState(() => _month = next);
    widget.onMonthChanged?.call(next);
  }

  void _backToToday() {
    setState(() => _month = DayUtil.firstDayOfMonth(widget.today));
    widget.onMonthChanged?.call(DayUtil.firstDayOfMonth(widget.today));
  }

  /// 这一天能不能选。
  bool _selectable(DateTime date) {
    final d = DayUtil.dayOnly(date);
    if (d.isAfter(DayUtil.dayOnly(widget.today))) return false;
    final earliest = widget.earliestDate;
    if (earliest != null && d.isBefore(DayUtil.dayOnly(earliest))) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final days = DayUtil.daysInMonth(_month);
    // 月历的第一格是周一 —— 与周历的 `一 二 三 …` 一致，不要一个月是周日开头、
    // 另一个是周一开头（那种不一致用户一眼能看出，但很难描述）。
    final leading = DayUtil.firstDayOfMonth(_month).weekday - 1;
    const labels = ['一', '二', '三', '四', '五', '六', '日'];

    final canGoNext = !_month.isBefore(DayUtil.firstDayOfMonth(widget.today));

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 14,
        // 让内容避开手势条（全面屏手机底部那条）。
        bottom: 16 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 抓手：视觉上表明「可以往下拖关掉」。
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                tooltip: '上一个月',
                onPressed: () => _goMonth(-1),
              ),
              Expanded(
                child: Text(
                  '${_month.year} 年 ${_month.month} 月',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                tooltip: '下一个月',
                // 到当前月就停：再往后是未来，没有数据。
                onPressed: canGoNext ? null : () => _goMonth(1),
              ),
            ],
          ),

          if (widget.loading)
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text(
                '正在读取这个月的数据…',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ),

          Row(
            children: [
              for (final label in labels)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                    ),
                  ),
                ),
            ],
          ),

          // 6 行足够任何月份（含前面留白）。用固定 6 行而不是按需行数：
          // 行数随月份变化会让弹层高度在翻月时跳动。
          for (var row = 0; row < 6; row++)
            Row(
              children: [
                for (var col = 0; col < 7; col++)
                  Expanded(
                    child: _dayCell(row * 7 + col - leading + 1, days),
                  ),
              ],
            ),

          const SizedBox(height: 8),
          const Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 10),

          Row(
            children: [
              // 空态说明：这个月一条数据都没有。**必须说清楚**，
              // 否则用户看到一片灰格子会以为是加载失败。
              Expanded(
                child: Text(
                  widget.marks.isEmpty && !widget.loading
                      ? '这个月没有记录'
                      : '有记录的日期会显示小圆点',
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                ),
              ),
              TextButton(
                onPressed: _backToToday,
                child: const Text('回到今天'),
              ),
              const SizedBox(width: 4),
              FilledButton(
                // 取消：不返回日期（`pop()` 无参 → Future 完成值是 null）。
                // 调用方据此**不改**当前选中日期 —— 这就是「取消」该有的语义。
                onPressed: () => Navigator.of(context).pop(),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.background,
                  foregroundColor: AppColors.text,
                ),
                child: const Text('取消'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 一格。`dayNumber <= 0` 或超出本月天数 → 空占位。
  Widget _dayCell(int dayNumber, int daysInMonth) {
    if (dayNumber < 1 || dayNumber > daysInMonth) {
      return const SizedBox(height: 46);
    }
    final date = DateTime(_month.year, _month.month, dayNumber);
    final isSelected = DayUtil.isSameDay(date, widget.selectedDate);
    final isToday = DayUtil.isSameDay(date, widget.today);
    final selectable = _selectable(date);
    final dayMarks = widget.marks[DayUtil.dayKey(date)];

    return GestureDetector(
      onTap: selectable ? () => Navigator.of(context).pop(date) : null,
      child: Container(
        height: 46,
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary
              : (isToday ? AppColors.background : Colors.transparent),
          borderRadius: BorderRadius.circular(10),
          border: isToday && !isSelected ? Border.all(color: AppColors.primary) : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$dayNumber',
              style: TextStyle(
                fontSize: 15,
                fontWeight: isSelected || isToday ? FontWeight.w700 : FontWeight.w400,
                // 不可选：未来、或早于「第一条数据那天」。
                color: !selectable
                    ? AppColors.border
                    : (isSelected ? Colors.white : AppColors.text),
              ),
            ),
            SizedBox(
              height: 8,
              child: (dayMarks != null && !dayMarks.isEmpty)
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(
                        dayMarks.dotCount,
                        (_) => Container(
                          width: 4,
                          height: 4,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: BoxDecoration(
                            color: isSelected ? Colors.white : AppColors.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// 「打开月历 → 管打点 → 回填选中日」这一整段。**三页共用一份**。
///
/// ## 为什么抽出来（而不是三处各写一遍）
///
/// 上一轮抽 `WeekStrip` 之前的教训就是**三份逐字相同的拷贝**：
/// 抽的时候才发现 `homework_tab` 那份把选中日期写成 `static final Rx`
/// （跨实例全局态），另两份是实例字段 —— 也就是说**三份拷贝早就漂了**，
/// 只是漂在没人看的地方。
///
/// 这次的要求是「历史怎么查在三页里必须是同一件事」，那就不能靠三份拷贝
/// 来维持 —— 那等于把「它们是同一件事」当成一个**希望**。抽成一处之后，
/// 「同一件事」变成了**编译期事实**：改一次，三页一起改。
///
/// 差异只有两处，作为参数传进来：
///   · [localMarks] —— 「还没有服务端摘要时先显示什么」（各页有各自的列表来源）；
///   · [fetchSummary] —— 「怎么取某个月的打点」（家长端要多带一个孩子 id）。
///
/// ## 三个必须这么写的地方
///
/// ① **打点与加载态是弹层自己的状态**，用 `ValueNotifier` 而不是 `setState`：
///    弹层是**另一个** route，从调用方 `setState` 改不动它。
///
/// ② **翻月时先把打点清空再请求**（见 [MonthPickerSheet] 的 `onMonthChanged`）。
///    不清的话，上个月的小圆点会留在新月份的格子上 ——
///    那些点会指向错误的日子，而它**看起来是有效信息**。
///
/// ③ **`fetchSummary` 是异步的，而用户随时可以关掉弹层。**
///    所以有一个 `disposed` 标志：往已 dispose 的 `ValueNotifier` 写 `value`
///    会抛「A ValueNotifier was used after being disposed」。
///    这不是防御性编程 —— 请求没回来就关弹层是完全正常的操作。
///
/// ⚠️ 参数用 `DayMarksFetcher` 这个**函数类型**，而不是直接收
/// `CalendarSummaryService` —— 后者定义在 `services/calendar_summary_service.dart`，
/// 而那个文件 `import` 本文件（它要用 `DayMarks` / `DayUtil`）。
/// 直接引用会形成**循环 import**：Dart 大多数情况下能编过，
/// 但静态初始化顺序会变得不可预期（某一边的顶层常量变成 null），
/// 而那种故障只在启动时出现、还依赖 import 顺序 —— 属于最难查的一类。
/// 传函数就断开了这个环，顺带让测试不必构造真服务。
typedef DayMarksFetcher = Future<Map<String, DayMarks>> Function(DateTime month);

class MonthPickerLauncher {
  const MonthPickerLauncher._();

  /// 打开月历。返回用户选中的日期；取消时返回 null。
  ///
  /// [localMarks] 是「本地算出来的打点」，作为摘要回来之前的先行值；
  /// 传 null 表示「什么都不先显示」（也是合法的，只是开头没有圆点）。
  /// [fetchSummary] 传 null = 本地模式：翻月不打点，日历照常可用。
  static Future<DateTime?> open(
    BuildContext context, {
    required DateTime selectedDate,
    DayMarksFetcher? fetchSummary,
    Map<String, DayMarks>? localMarks,
  }) async {
    final marksNotifier = ValueNotifier<Map<String, DayMarks>>(localMarks ?? const {});
    final loading = ValueNotifier<bool>(false);
    var disposed = false;

    try {
      return await MonthPickerSheet.pick(
        context,
        selectedDate: selectedDate,
        today: DateTime.now(),
        marks: marksNotifier.value,
        loading: loading,
        marksNotifier: marksNotifier,
        onMonthChanged: fetchSummary == null
            ? null
            : (next) async {
                // 先标「正在读」并**清掉旧打点**：见类注释 ②。
                loading.value = true;
                marksNotifier.value = const {};
                final fresh = await fetchSummary(next);
                if (disposed) return;
                marksNotifier.value = fresh;
                loading.value = false;
              },
      );
    } finally {
      disposed = true;
      marksNotifier.dispose();
      loading.dispose();
    }
  }
}
