import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../constants/subject_colors.dart';
import '../models/subject_mistake_summary.dart';

/// 家长端「按学科看错题」的色块区。
///
/// 为什么按学科分块而不是继续平铺：一个孩子的 109 条错题里，数学占 88 条
/// （真库实测）。平铺时其它三科被压到页面很下面，家长根本看不到 —— 而这
/// 一页本来就是要回答「现在最该管哪一科」。
///
/// ## 和「计划」标签的色块刻意不同的两点
///
/// 1. **排序**：计划页固定按白名单顺序（配一次长期有效）；这里按待复习数
///    降序 —— 先看到最该管的科。
/// 2. **点击语义**：计划页点色块是出题 / 去配置；这里**只是查看**。
///    同一个视觉、不同后果，所以块内动作文字必须写清楚（「查看错题 ›」），
///    不能只靠颜色让人猜。
class SubjectMistakeBoard extends StatelessWidget {
  const SubjectMistakeBoard({
    super.key,
    required this.summaries,
    required this.onOpen,
  });

  /// 已按「待复习降序」排好的汇总（见 `summarizeMistakesBySubject`）。
  /// **不在这里重新排序**：排序口径只有一处，页面不参与算账。
  final List<SubjectMistakeSummary> summaries;

  /// 点某一块时回调科目名。注入而不是直接 `Get.to`：
  /// 判据里换成计数回调就能验证「点数学传的是不是数学」，不需要起真路由。
  final ValueChanged<String> onOpen;

  /// 主位色块的数量：两行四块，正好铺满首屏。
  static const int primaryCount = 4;

  @override
  Widget build(BuildContext context) {
    final primary = summaries.take(primaryCount).toList();
    final rest = summaries.skip(primaryCount).toList();
    final allTotal = summaries.fold<int>(0, (sum, one) => sum + one.total);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < primary.length; i += 2)
          Padding(
            padding: EdgeInsets.only(
              bottom: i + 2 < primary.length ? 10 : 0,
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _tile(primary[i], allTotal)),
                  const SizedBox(width: 10),
                  if (i + 1 < primary.length)
                    Expanded(child: _tile(primary[i + 1], allTotal))
                  else
                    // 奇数块时留半格空位：让最后一块仍然是一半宽，
                    // 不会被拉伸成整行（家长会以为那一科特别重要）。
                    const Expanded(child: SizedBox.shrink()),
                ],
              ),
            ),
          ),
        if (rest.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final one in rest)
                ActionChip(
                  key: Key('review_subject_chip_${one.subject}'),
                  avatar: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: subjectColor(one.subject),
                      shape: BoxShape.circle,
                    ),
                  ),
                  label: Text(
                    '${one.subject} · 待复习 ${one.poolCount}',
                    style: TextStyle(
                      fontSize: 12,
                      color: subjectColor(one.subject),
                    ),
                  ),
                  onPressed: () => onOpen(one.subject),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _tile(SubjectMistakeSummary summary, int allTotal) {
    final color = subjectColor(summary.subject);
    final ratio = allTotal == 0
        ? 0
        : (summary.total / allTotal * 100).round();

    // 副行的三段按需拼：没有已掌握就不写「已掌握 0」，否则四块里
    // 全是 0 会让人以为数据没加载。
    final details = <String>[
      if (summary.masteredCount > 0)
        summary.hasSelfMastered
            ? '已掌握 ${summary.masteredCount}（自评 ${summary.selfMasteredCount}）'
            : '已掌握 ${summary.masteredCount}',
      if (ratio > 0) '占全部 $ratio%',
    ];

    return InkWell(
      key: Key('review_subject_tile_${summary.subject}'),
      borderRadius: BorderRadius.circular(14),
      onTap: () => onOpen(summary.subject),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                // 科目名必须写着：只靠底色区分，色弱的人分不出哪块是哪科。
                Expanded(
                  child: Text(
                    summary.subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                ),
                // 橙点 = 这一科里有「孩子自评掌握」的题。不展开解释，
                // 具体几条在副行的「（自评 N）」里，详情页也按段分开。
                if (summary.hasSelfMastered)
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: AppColors.warning,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${summary.poolCount}',
              maxLines: 1,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: color,
                height: 1.0,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '待复习',
              maxLines: 1,
              style: TextStyle(fontSize: 11, color: color),
            ),
            if (details.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                details.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: color),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '查看错题 ›',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
