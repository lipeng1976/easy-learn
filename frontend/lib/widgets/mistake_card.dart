import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../models/homework_image_model.dart';
import '../models/review_model.dart';
import '../pages/parent/homework_detail_page.dart';
import '../pages/student/widgets/review_badges.dart';
import 'homework_image_viewer.dart';
import 'math_text.dart';
import 'review_components.dart';

/// 一张错题卡：题目、状态、知识点、错因、作答照片、来源作业。
///
/// 原来它是家长端复习页里的私有类。11-15 新增「学科错题详情页」后，
/// 同一个孩子的一道题要在两处出现 —— 复制一份的代价是两边会慢慢长出
/// 不同的标签和口径（本项目已经因此栽过几次）。所以抽成公共组件：
/// **改这里，两个页面一起变**。
class MistakeCard extends StatelessWidget {
  const MistakeCard({super.key, required this.mistake, this.answerPhotos = const []});

  final ReviewMistake mistake;

  /// 孩子在**复习这道题时拍的作答照片**（可空）。
  ///
  /// 为什么它和作业照片是两回事：这些照片的 `homeworkId` 为空，
  /// 关联靠 `batchId == 题目 id`（见 `ParentController.answerPhotosOfMistake`）。
  /// 传进来的必须是**已经按这道错题筛过的**那一组 —— 这里不再做归属判断，
  /// 避免同一条规则在两层各写一遍、然后慢慢漂开。
  final List<HomeworkImageModel> answerPhotos;

  @override
  Widget build(BuildContext context) {
    final mastered = mistake.state == ReviewState.mastered;
    // 自评掌握不给绿色：它和「检查通过」在可信度上不是一回事，
    // 同一个绿色会让家长把「孩子自己说会了」看成「系统确认会了」。
    final color = mastered
        ? (mistake.masteredBySelf ? AppColors.textMuted : AppColors.success)
        : mistakeStateColor(mistake.state);
    final label = mastered
        ? (mistake.masteredBySelf ? '自评掌握' : '检查通过')
        : mistake.state.label;
    return Container(
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
                // 题目是从卷面 OCR / 批改结果来的，本身就可能带 `$...$`。
                child: MathText(
                  mistake.title,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    height: 1.4,
                  ),
                ),
              ),
              ReviewTag(text: label, color: color),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ReviewTag(text: mistake.subject, color: AppColors.textMuted),
              if (mistake.knowledgePoint.isNotEmpty)
                ReviewTag(
                  text: mistake.knowledgePoint,
                  color: AppColors.primary,
                ),
              ReviewTag(
                text: '错 ${mistake.wrongCount} 次',
                color: AppColors.danger,
              ),
              if (mistake.reviewRound > 0)
                ReviewTag(
                  text: '重做 ${mistake.reviewRound} 轮',
                  color: AppColors.accent,
                ),
              if (mistake.sourceHomeworkTitle == '手工录入')
                const ReviewTag(
                  text: '手工录入',
                  color: AppColors.textMuted,
                  icon: Icons.edit_note_outlined,
                ),
            ],
          ),
          if (mistake.wrongReason.isNotEmpty) ...[
            const SizedBox(height: 8),
            MathText(
              '错因：${mistake.wrongReason}',
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.text,
                height: 1.5,
              ),
            ),
          ],
          // 孩子复习这道题时拍的作答照片。**没有就不占位** ——
          // 一张灰色的「暂无照片」会让家长以为孩子该拍没拍，
          // 而多数错题本来就是在作业里批出来的、压根没有这道题的拍照作答。
          if (answerPhotos.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(
                  Icons.photo_camera_outlined,
                  size: 15,
                  color: AppColors.textMuted,
                ),
                const SizedBox(width: 5),
                Text(
                  '孩子的作答照片（${answerPhotos.length} 张）',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.text,
                  ),
                ),
                const Spacer(),
                const Text(
                  '复习这道题时拍的',
                  style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                ),
              ],
            ),
            const SizedBox(height: 8),
            HomeworkImageGrid(images: answerPhotos, thumbnailSize: 74),
          ],
          if (mistake.state == ReviewState.mastered &&
              mistake.masteredAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${formatReviewDateTime(mistake.masteredAt!)} 移出错题库'
                '${mistake.masteredBySelf ? '（孩子自评，未经过检查）' : ''}',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textMuted,
                ),
              ),
            ),
          if (mistake.homeworkId.isNotEmpty) ...[
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: () => HomeworkDetailPage.open(mistake.homeworkId),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.link, size: 16),
              label: const Text('查看来源作业', style: TextStyle(fontSize: 12.5)),
            ),
          ],
        ],
      ),
    );
  }
}
