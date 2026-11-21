import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/subject_colors.dart';
import '../../controllers/parent_controller.dart';
import '../../models/review_model.dart';
import '../../models/subject_mistake_summary.dart';
import '../../widgets/mistake_card.dart';
import '../../widgets/review_components.dart';

/// 某一科的错题详情（家长端「按学科看错题」点色块进来）。
///
/// ## 这一页只做三件事
///
/// 看汇总、看待复习、看已掌握。**没有任何改状态的按钮**：
/// 「标记掌握」「重新组卷」都在孩子端或复习流程里，家长端加了就会变成
/// 第二个真值（家长点了、孩子那边却没做，掌握率立刻失真）。
///
/// 排序按**错得最多的题在前**：87 道数学错题里，家长最该先看到的是那些
/// 反复错的，而不是最新录入的。
class ReviewSubjectPage extends StatelessWidget {
  const ReviewSubjectPage({super.key, required this.subject});

  /// 归一后的科目名（色块传进来的就是它）。
  final String subject;

  /// 用普通 `Navigator.push` 而不是 `Get.toNamed`：
  /// 不依赖全局路由表，判据里用普通 `MaterialApp` 也能点进来。
  static Future<void> open(BuildContext context, String subject) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ReviewSubjectPage(subject: subject),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ParentController>();
    final color = subjectColor(subject);

    return Scaffold(
      appBar: AppBar(title: Text('$subject · 错题')),
      body: Obx(() {
        // 归一必须与色块用同一个函数：否则「科学」在色块里进了「其他」，
        // 点进来却被当成独立科目，详情页会空得像坏了。
        final all = controller.visibleMistakes
            .where((one) => normalizeMistakeSubject(one.subject) == subject)
            .toList();
        final pool = all.where((one) => one.state.inPool).toList()
          ..sort(_byMostWrong);
        final mastered = all
            .where((one) => one.state == ReviewState.mastered)
            .toList()
          ..sort(_byMostWrong);
        final summary = findSubjectSummary(
          summarizeMistakesBySubject(controller.visibleMistakes),
          subject,
        );

        if (all.isEmpty) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: const [
              ReviewEmptyHint(
                icon: Icons.inbox_outlined,
                text: '这一科目前没有错题。孩子之后做错的题会自动进这里。',
              ),
            ],
          );
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (summary != null) _summaryBar(summary, color),
            const SizedBox(height: 18),
            if (pool.isNotEmpty) ...[
              const ReviewSectionHeader(
                icon: Icons.menu_book_outlined,
                title: '待复习',
              ),
              const SizedBox(height: 10),
              for (final mistake in pool)
                MistakeCard(
                  key: Key('review_subject_mistake_${mistake.id}'),
                  mistake: mistake,
                  answerPhotos: controller.answerPhotosOfMistake(mistake.id),
                ),
            ],
            if (mastered.isNotEmpty) ...[
              if (pool.isNotEmpty) const SizedBox(height: 10),
              const ReviewSectionHeader(
                icon: Icons.check_circle_outline,
                title: '已掌握',
              ),
              const SizedBox(height: 10),
              for (final mistake in mastered)
                MistakeCard(
                  key: Key('review_subject_mistake_${mistake.id}'),
                  mistake: mistake,
                  answerPhotos: controller.answerPhotosOfMistake(mistake.id),
                ),
            ],
          ],
        );
      }),
    );
  }

  /// 顶部汇总条：和色块上那块用同一份汇总，数字必须对得上。
  Widget _summaryBar(SubjectMistakeSummary summary, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _stat('待复习', summary.poolCount, color),
              _stat('已掌握', summary.masteredCount, color),
              _stat('累计错', summary.wrongCount, color),
            ],
          ),
          if (summary.hasSelfMastered) ...[
            const SizedBox(height: 8),
            Text(
              '已掌握里有 ${summary.selfMasteredCount} 道是孩子自评，'
              '没有作答证据，不计入掌握率。',
              style: const TextStyle(fontSize: 11.5, height: 1.5),
            ),
          ],
          // 只在真有试卷导入的科目上露这一行：恒为 0 时写「试卷导入 0」
          // 会让人以为导入失败（这个数字曾经一直是 0，因为来源被当成手工录入）。
          if (summary.hasExamImported) ...[
            const SizedBox(height: 6),
            Text(
              '其中 ${summary.examCount} 道来自考试卷导入（ima 整理）。',
              style: const TextStyle(fontSize: 11.5, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stat(String label, int value, Color color) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$value',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 11, color: color)),
        ],
      ),
    );
  }
}

/// 错得多的在前；同错次时新录入的在前（稳定、可解释）。
int _byMostWrong(ReviewMistake a, ReviewMistake b) {
  final byWrong = b.wrongCount.compareTo(a.wrongCount);
  if (byWrong != 0) return byWrong;
  return b.createdAt.compareTo(a.createdAt);
}
