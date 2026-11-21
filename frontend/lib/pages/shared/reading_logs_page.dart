import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/reading_controller.dart';
import '../../models/reading_models.dart';

/// 阅读打卡记录页（学生 / 家长共用）。
///
/// ## 为什么单独一页，而不是塞进计划页
///
/// 计划页要回答的是「今天读哪篇」。记录是另一件事 —— 孩子想回顾
/// 「我这周读了几天」，家长想核对「昨天到底读没读」。把几十条记录摊在
/// 计划页里，会把「今天该做的事」压到屏幕外面去。
///
/// ## 筛选不给「默认最近 N 天」
///
/// 服务端不设默认窗口（见 `routes/reading.js` 的 listLogs），这里也
/// 只在用户点了某个范围之后才带 `from`/`to`。默认落在「近 30 天」是
/// **界面上明确选中的状态**，不是一段看不见的过滤 —— 家长能看见自己
/// 在看哪一段，切「全部」就能看到更早的。
///
/// ## 按天分组
///
/// 记录一条条平铺时，「哪天读了、哪天没读」要靠自己数日期。按天分组后，
/// 一个日期头 + 篇数就是一天的完整答案。
class ReadingLogsPage extends StatefulWidget {
  const ReadingLogsPage({super.key});

  @override
  State<ReadingLogsPage> createState() => _ReadingLogsPageState();
}

/// 时间窗选项。
enum _LogRange { today, week, month, all, custom }

class _ReadingLogsPageState extends State<ReadingLogsPage> {
  late final ReadingController controller;

  _LogRange _range = _LogRange.month;

  /// 自定义窗口（只在 [_LogRange.custom] 时使用）。
  DateTime? _customFrom;
  DateTime? _customTo;

  @override
  void initState() {
    super.initState();
    controller = Get.isRegistered<ReadingController>()
        ? Get.find<ReadingController>()
        : Get.put(ReadingController());
    _reload();
  }

  static String _fmt(DateTime at) {
    final m = at.month.toString().padLeft(2, '0');
    final d = at.day.toString().padLeft(2, '0');
    return '${at.year}-$m-$d';
  }

  /// 当前选项对应的窗口。`(null, null)` = 不限。
  (String?, String?) _window() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (_range) {
      case _LogRange.today:
        return (_fmt(today), _fmt(today));
      case _LogRange.week:
        // 含今天在内的 7 天：今天减 6。
        return (_fmt(today.subtract(const Duration(days: 6))), _fmt(today));
      case _LogRange.month:
        return (_fmt(today.subtract(const Duration(days: 29))), _fmt(today));
      case _LogRange.all:
        return (null, null);
      case _LogRange.custom:
        final from = _customFrom;
        final to = _customTo;
        return (from == null ? null : _fmt(from), to == null ? null : _fmt(to));
    }
  }

  Future<void> _reload() async {
    final (from, to) = _window();
    await controller.loadLogs(from: from, to: to);
  }

  Future<void> _pickCustom() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _customFrom != null && _customTo != null
          ? DateTimeRange(start: _customFrom!, end: _customTo!)
          : null,
      helpText: '选择要查的日期范围',
      saveText: '查这段',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _range = _LogRange.custom;
      _customFrom = picked.start;
      _customTo = picked.end;
    });
    await _reload();
  }

  Future<void> _select(_LogRange next) async {
    if (next == _LogRange.custom) {
      await _pickCustom();
      return;
    }
    if (_range == next) return;
    setState(() => _range = next);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('阅读打卡记录')),
      body: Obx(() {
        // ignore: invalid_use_of_protected_member —— 在 Obx 里读 RxList.value 是 GetX 标准写法。
        final logs = controller.logs.value;
        final loading = controller.logsLoading.value;
        final error = controller.logsError.value;

        return RefreshIndicator(
          onRefresh: _reload,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _RangeBar(
                selected: _range,
                onSelect: _select,
                customLabel: _customLabel(),
              ),
              const SizedBox(height: 12),
              if (error != null && error.isNotEmpty) ...[
                _ErrorBanner(message: error),
                const SizedBox(height: 12),
              ],
              if (loading && logs.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (logs.isEmpty)
                _EmptyHint(range: _range)
              else ...[
                Text(
                  // 报**总数**而不是本页条数：只显示「30 次」会让人以为
                  // 历史只有 30 条（其实是分页）。
                  '共 ${controller.logsTotal.value} 次打卡',
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                ),
                const SizedBox(height: 10),
                for (final group in _groupByDay(logs)) ...[
                  _DayGroup(day: group.$1, entries: group.$2),
                  const SizedBox(height: 12),
                ],
                if (controller.logsHasMore.value) ...[
                  const SizedBox(height: 4),
                  Center(
                    child: OutlinedButton(
                      onPressed: controller.logsLoadingMore.value
                          ? null
                          : () => controller.loadLogs(append: true),
                      child: controller.logsLoadingMore.value
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('加载更早的记录'),
                    ),
                  ),
                ],
              ],
            ],
          ),
        );
      }),
    );
  }

  String? _customLabel() {
    if (_range != _LogRange.custom) return null;
    final from = _customFrom;
    final to = _customTo;
    if (from == null || to == null) return null;
    return '${from.month}/${from.day} - ${to.month}/${to.day}';
  }

  /// 把已排好序（天倒序）的记录切成「一天一组」。
  static List<(String, List<ReadingLogEntry>)> _groupByDay(
    List<ReadingLogEntry> logs,
  ) {
    final out = <(String, List<ReadingLogEntry>)>[];
    String? currentDay;
    var bucket = <ReadingLogEntry>[];
    for (final entry in logs) {
      if (entry.day != currentDay) {
        if (bucket.isNotEmpty) out.add((currentDay!, bucket));
        currentDay = entry.day;
        bucket = <ReadingLogEntry>[];
      }
      bucket.add(entry);
    }
    if (bucket.isNotEmpty && currentDay != null) out.add((currentDay, bucket));
    return out;
  }
}

/// 顶部的时间窗选项。
class _RangeBar extends StatelessWidget {
  const _RangeBar({
    required this.selected,
    required this.onSelect,
    this.customLabel,
  });

  final _LogRange selected;
  final Future<void> Function(_LogRange) onSelect;
  final String? customLabel;

  @override
  Widget build(BuildContext context) {
    final items = <(_LogRange, String)>[
      (_LogRange.today, '今天'),
      (_LogRange.week, '近 7 天'),
      (_LogRange.month, '近 30 天'),
      (_LogRange.all, '全部'),
      (_LogRange.custom, customLabel ?? '选日期'),
    ];
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final (value, label) = items[index];
          final active = value == selected;
          return ChoiceChip(
            label: Text(label),
            selected: active,
            onSelected: (_) => onSelect(value),
            labelStyle: TextStyle(
              fontSize: 13,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? Colors.white : AppColors.text,
            ),
            selectedColor: AppColors.primary,
            backgroundColor: AppColors.card,
            showCheckmark: false,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: active ? AppColors.primary : AppColors.border,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 一天：日期头 + 那天的每一条。
class _DayGroup extends StatelessWidget {
  const _DayGroup({required this.day, required this.entries});

  /// `yyyy-MM-dd`。
  final String day;
  final List<ReadingLogEntry> entries;

  @override
  Widget build(BuildContext context) {
    // 同一天里跨了多本书时，每条要带书名 —— 否则「第 3 篇」看不出是哪本书。
    final books = entries.map((e) => e.bookTitle).toSet();
    final showBook = books.length > 1;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Row(
              children: [
                const Icon(Icons.event_available_outlined,
                    size: 16, color: AppColors.success),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _dayLabel(day),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  '${entries.length} 篇',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.success,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppColors.border),
            _LogRow(entry: entries[i], showBook: showBook),
          ],
        ],
      ),
    );
  }

  /// `今天 / 昨天 / 11月6日 周五`。
  ///
  /// 全部用日期字符串或纯日期对象算，**不碰服务器时间**：`day` 本来
  /// 就是孩子打卡时给的本地日（R4），拿 `readAt` 去推会在时区上偏一天。
  static String _dayLabel(String day) {
    final parts = day.split('-');
    if (parts.length != 3) return day;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return day;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(y, m, d);
    final diff = today.difference(that).inDays;
    if (diff == 0) return '今天 · $m月$d日';
    if (diff == 1) return '昨天 · $m月$d日';
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return '$m月$d日 周${weekdays[that.weekday - 1]}';
  }
}

/// 一条记录：`第 4 篇` + 标题 + 时间。
class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry, required this.showBook});

  final ReadingLogEntry entry;
  final bool showBook;

  @override
  Widget build(BuildContext context) {
    final at = entry.readAt;
    final time = at == null
        ? ''
        : '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '第 ${entry.lessonNo} 篇',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.displayTitle.isEmpty ? '（这一篇的标题已不可用）' : entry.displayTitle,
                  style: const TextStyle(fontSize: 13, height: 1.4),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (showBook && entry.bookTitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    // 跨书时把书名带上：同一个「第 3 篇」在两个书名下是两篇课文。
                    '《${entry.bookTitle}》',
                    style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (time.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              time,
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.range});

  final _LogRange range;

  @override
  Widget build(BuildContext context) {
    // 空也要分两种说法：这个窗口里没读，和「一次都还没读过」。
    // 混成一句「暂无记录」的话，刚开始用的家长会以为功能没生效。
    final text = range == _LogRange.all
        ? '还没有任何阅读打卡记录。孩子读一篇、点一次「我读完了，打卡」，这里就会有。'
        : '这段时间没有打卡记录。换「全部」看看更早的记录。';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.history_toggle_off, size: 20, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textMuted,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: AppColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12, height: 1.5, color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}
