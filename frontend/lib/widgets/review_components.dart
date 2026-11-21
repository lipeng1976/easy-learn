import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../models/homework_model.dart';
import '../models/review_model.dart';
import '../pages/parent/review_paper_detail_page.dart';
import '../pages/student/widgets/review_badges.dart';
import 'homework_status.dart';

/// 复习域共用的页面零件。
///
/// 这些原来都是 `review_parent_tab.dart` 里的私有类。11-15 拆出「学科错题
/// 详情页」和「资料与记录页」之后，同一张卡片要在三个页面出现 —— 复制一份
/// 就会立刻出现「家长页写着 15.5、详情页写着 15」这种漂移，而两边都能编译。
/// 所以集中到这里：**卡片只有一个实现**。

/// `11月15日 20:30` —— 复习域的日期口径。
///
/// 不直接用 `DateUtilsX.formatDateTime`：那是 `2026-11-15 20:30` 的机器口径，
/// 家长端一直是「几月几日 时:分」。两个都留着，各有各的读者。
String formatReviewDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${local.month}月${local.day}日 ${two(local.hour)}:${two(local.minute)}';
}

/// 小节标题：图标 + 标题 + 右侧说明。
class ReviewSectionHeader extends StatelessWidget {
  const ReviewSectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const Spacer(),
        if (trailing != null)
          Text(
            trailing!,
            style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
          ),
      ],
    );
  }
}

/// 空态卡片。**只在真的没有内容时出现**，不拿来占位。
class ReviewEmptyHint extends StatelessWidget {
  const ReviewEmptyHint({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Icon(icon, size: 34, color: AppColors.textMuted),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一份复习资料（试卷）。
class ReviewPaperCard extends StatelessWidget {
  const ReviewPaperCard({super.key, required this.paper});

  final ReviewPaper paper;

  @override
  Widget build(BuildContext context) {
    // ⭐ 这张卡原来**没有任何点击处理**，却和下面「作业提交记录」「错题清单」
    // 长在同一个列表里、视觉上完全一样 —— 家长点了没反应，就报成
    //「错题待导出，点击没反应」。可点的东西必须自己说出来。
    return GestureDetector(
      onTap: () => ParentReviewPaperPage.open(paper.id),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    paper.title,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                PaperStatusBadge(status: paper.status),
                // 箭头是「这里能点」的视觉承诺。学生端同一个位置也有它，
                // 两端不一致时，家长会以为自己这边坏了。
                const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: AppColors.textMuted,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${paper.itemCount} 道题'
              '${paper.knowledgePoints.isEmpty ? '' : ' · ${paper.knowledgePoints.join('、')}'}',
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textMuted,
              ),
            ),
            if (paper.submittedAt != null)
              Text(
                '回传于 ${formatReviewDateTime(paper.submittedAt!)}',
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textMuted,
                ),
              ),
            if (paper.gradedAt != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(
                    Icons.fact_check_outlined,
                    size: 15,
                    color: AppColors.success,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '通过 ${paper.passCount} · 未通过 ${paper.failCount}'
                    ' · 通过率 ${(paper.passRate * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.success,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 一次作业提交记录。
class ReviewSubmissionCard extends StatelessWidget {
  const ReviewSubmissionCard({
    super.key,
    required this.item,
    required this.attachmentText,
    required this.mistakeCount,
    required this.onTap,
  });

  final HomeworkItem item;

  /// 附件摘要（「2 张照片 · 1 个视频」），空串表示没有附件。
  final String attachmentText;
  final int mistakeCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      item.title,
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  HomeworkStatusChip(status: item.status, dense: true),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(
                    Icons.check_circle,
                    size: 15,
                    color: AppColors.success,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${formatReviewDateTime(item.submittedAt!)} 提交'
                      '${attachmentText.isEmpty ? ' · 未上传附件' : ' · $attachmentText'}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.success,
                      ),
                    ),
                  ),
                ],
              ),
              if (item.score != null) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(
                      Icons.auto_awesome,
                      size: 15,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'AI 得分 ${item.score}'
                      '${mistakeCount > 0 ? ' · 错题 $mistakeCount 道' : ' · 全部正确'}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    attachmentText.isEmpty ? '查看批改详情' : '查看附件与批改详情',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: AppColors.primary,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
