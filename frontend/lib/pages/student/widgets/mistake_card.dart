import 'package:flutter/material.dart';

import '../../../constants/app_colors.dart';
import '../../../models/review_model.dart';
import '../../../utils/day_label.dart';
import '../../../widgets/math_text.dart';

/// 一道待复习错题的卡片。
///
/// 两处共用：复习页的「待复习」列表、以及从批改结果点进来的
/// 「这次作业的错题」。做成公共组件不是为了复用省事，而是因为
/// **同一道题在两个页面长得不一样**时，用户会以为是两道不同的题。
///
/// ## 排版口径
///
/// 标题 → 一行元信息 → 错因（最多两行）→ 操作。
/// 元信息（科目 / 知识点 / 来源作业 / 日期）原先是三个独立标签，
/// 一行放不下就换行，于是一屏里每张卡的高度都不一样 —— 这正是
/// 「排版乱」的主要来源。压成一行静音文字后高度才稳定，列表才扫得动。
///
/// 错因**截断到两行**：它是模型写的整段分析，常常十几行；
/// 在列表里全展开会让「找一道题」变成「读十篇讲解」。全文在详情页。
class MistakeCard extends StatelessWidget {
  const MistakeCard({
    super.key,
    required this.mistake,
    required this.onExplain,
    required this.onPractice,
    required this.onMarkMastered,
    required this.onEdit,
    required this.onDelete,
  });

  final ReviewMistake mistake;

  /// 进详情页（讲解）。整张卡片点击也走这条。
  final VoidCallback onExplain;
  final VoidCallback onPractice;
  final VoidCallback onMarkMastered;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final meta = _metaLine(mistake);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      // 整卡可点：用户想「看看错在哪」时不该先去找按钮。
      // ⚠️ `InkWell` 放在 `Container` 里面、`Material` 外面时水波纹会被裁掉，
      // 所以用 `Material` 包一层透明色。
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onExplain,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: MathText(
                        mistake.title,
                        maxLines: 2,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          height: 1.35,
                        ),
                      ),
                    ),
                    if (mistake.wrongCount > 1) ...[
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            // 错 3 次及以上 = 重点易错题，用实心红底白字，
                            // 一眼扫过去就知道哪些题最需要先啃。
                            color: mistake.wrongCount >= 3
                                ? AppColors.danger
                                : AppColors.danger.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '错 ${mistake.wrongCount} 次',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: mistake.wrongCount >= 3
                                  ? Colors.white
                                  : AppColors.danger,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
                if (mistake.wrongReason.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  MathText(
                    '错因：${mistake.wrongReason}',
                    maxLines: 2,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.text,
                      height: 1.5,
                    ),
                  ),
                ],
                const SizedBox(height: 2),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: onExplain,
                      icon: const Icon(Icons.lightbulb_outline, size: 16),
                      label: const Text(
                        '讲解',
                        style: TextStyle(fontSize: 12.5),
                      ),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: onPractice,
                      icon: const Icon(Icons.auto_awesome, size: 16),
                      label: const Text(
                        '举一反三',
                        style: TextStyle(fontSize: 12.5),
                      ),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    const Spacer(),
                    // 标记掌握 / 编辑 / 删除收进溢出菜单：
                    // 三个动作加起来每周用不到一次，全摊成按钮会把
                    // 「讲解」「举一反三」这两个真正高频的入口挤散。
                    PopupMenuButton<String>(
                      tooltip: '更多操作',
                      icon: const Icon(
                        Icons.more_vert,
                        size: 20,
                        color: AppColors.textMuted,
                      ),
                      onSelected: (value) {
                        if (value == 'mastered') {
                          onMarkMastered();
                        } else if (value == 'edit') {
                          onEdit();
                        } else if (value == 'delete') {
                          onDelete();
                        }
                      },
                      itemBuilder: (context) => [
                        _menuItem(
                          'mastered',
                          Icons.check_circle_outline,
                          AppColors.success,
                          '标记掌握（自评）',
                        ),
                        _menuItem(
                          'edit',
                          Icons.edit_outlined,
                          AppColors.primary,
                          '编辑',
                        ),
                        _menuItem(
                          'delete',
                          Icons.delete_outline,
                          AppColors.danger,
                          '删除',
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    Color color,
    String label,
  ) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 13.5)),
        ],
      ),
    );
  }

  /// 一行元信息：`数学 · 一元一次方程 · 来自《…》 · 10月20日`。
  ///
  /// 日期用 [formatDayLabel]，和聊天分隔条同一口径（今天 / 昨天 / 10月20日）。
  /// 原来是绝对没有日期，只有「来自《作业名》」—— 用户要判断「这是不是
  /// 今天那次作业的错题」只能回忆作业名，这正是他要求补日期的原因。
  static String _metaLine(ReviewMistake mistake) {
    final parts = <String>[
      if (mistake.subject.isNotEmpty) mistake.subject,
      if (mistake.knowledgePoint.isNotEmpty) mistake.knowledgePoint,
      // 原卷面题号：家长要对着作业本找这道题，光有知识点找不到。
      // 空串（老错题 / 没编号的作业）就不显示，不占位。
      if (mistake.questionNo.isNotEmpty) '第 ${mistake.questionNo} 题',
      if (mistake.sourceHomeworkTitle.isNotEmpty)
        '来自《${mistake.sourceHomeworkTitle}》',
      formatDayLabel(mistake.createdAt),
    ];
    return parts.join(' · ');
  }
}
