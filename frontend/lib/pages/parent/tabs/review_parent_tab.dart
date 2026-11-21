import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../constants/app_colors.dart';
import '../../../controllers/parent_controller.dart';
import '../../../models/review_model.dart';
import '../../../models/subject_mistake_summary.dart';
import '../../../services/exam_mistake_api.dart';
import '../../../widgets/exam_mistake_import_sheet.dart';
import '../../../widgets/review_components.dart';
import '../../../widgets/subject_mistake_board.dart';
import '../../student/widgets/review_badges.dart';
import '../review_records_page.dart';
import '../review_subject_page.dart';

/// 家长端「复习监督」页。
///
/// ## 这一页按「家长的动作顺序」分四区（11-15 重排）
///
/// ① **可以做的一件事**：从 ima 导入试卷错题（全页唯一的写操作）；
/// ② **本周结论**：掌握率、本周通过、作答来源（自评警告永远露出，不收起）；
/// ③ **按学科看错题**：色块汇总，点进去看该科详情；
/// ④ **资料与记录**：复习资料 / 作业提交，各一行入口。
///
/// 重排前的版本把 109 张错题卡平铺在页面最底部，前面压着进度卡、薄弱知识点、
/// 复习资料、作业提交记录 —— 家长既看不到学科分布，也滚不到导入入口。
/// 现在「错题明细」按学科收口成色块，明细只在详情页出现。
class ReviewParentTab extends StatelessWidget {
  const ReviewParentTab({super.key, this.examMistakeRepository});

  /// 只为测试注入；线上由 `ExamMistakeImportEntry` 自己按
  /// `DatabaseService.cloud?.api` 构造。
  final ExamMistakeRepository? examMistakeRepository;

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ParentController>();

    return Obx(() {
      final submitted = controller.submittedHomeworks;
      final pool = controller.visiblePoolMistakes;
      final mastered = controller.visibleMasteredMistakes;
      final papers = controller.visibleReviewPapers;
      final weakPoints = controller.visibleWeakPoints();
      final channelTally = controller.visibleWeekChannelTally;
      final summaries = summarizeMistakesBySubject(controller.visibleMistakes);

      final selfCount = channelTally[AttemptChannel.paperSelf] ?? 0;
      final channelTotal = channelTally.values.fold<int>(
        0,
        (sum, value) => sum + value,
      );
      final graduated = controller.visibleWeekGraduated;
      void openChannelSheet() =>
          _showChannelSheet(context, channelTally, graduated);

      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '作业与复习监督',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          // ⭐ 11-15：这个入口原来压在 ListView 最底部的「错题清单」标题下，
          // 前面还有进度卡 / 薄弱知识点 / 复习资料 / 作业提交记录，真机上
          // 家长在首屏根本滚不到，反馈「看不到这个功能」。低频但重要的操作
          // 必须紧跟标题；没开通 ima 时整块隐藏、不留空白、不弹红条。
          if (controller.selectedStudentId.value.isNotEmpty) ...[
            const SizedBox(height: 12),
            ExamMistakeImportEntry(
              studentId: controller.selectedStudentId.value,
              repository: examMistakeRepository,
              onChanged: () => controller.loadData(),
            ),
          ],
          const SizedBox(height: 14),
          _ProgressCard(
            masteryRate: controller.visibleMasteryRate,
            poolCount: pool.length,
            masteredCount: mastered.length,
            weekPassCount: controller.visibleWeekPassCount,
            weekSubmittedPapers: controller.visibleWeekSubmittedPapers,
          ),
          // 自评警告**不默认收起**：它说的是「孩子自己勾了做对、没有作答证据」，
          // 藏进折叠就又变成咱们反复治的那种静默失败 —— 家长看到漂亮的掌握率，
          // 却不知道其中一部分是孩子自己说的。
          if (selfCount > 0) ...[
            const SizedBox(height: 10),
            _SelfAssessBanner(count: selfCount, onTap: openChannelSheet),
          ],
          if (channelTally.isNotEmpty) ...[
            const SizedBox(height: 10),
            _ChannelSummaryRow(
              total: channelTotal,
              passCount: controller.visibleWeekPassCount,
              onTap: openChannelSheet,
            ),
          ],
          const SizedBox(height: 22),
          ReviewSectionHeader(
            icon: Icons.grid_view_outlined,
            title: '按学科看错题',
            trailing: '待复习 ${pool.length} · 已掌握 ${mastered.length}',
          ),
          const SizedBox(height: 10),
          if (summaries.isEmpty)
            const ReviewEmptyHint(
              icon: Icons.emoji_events_outlined,
              text: '目前没有错题记录。孩子做错的题会自动进这里。',
            )
          else
            SubjectMistakeBoard(
              summaries: summaries,
              onOpen: (subject) => ReviewSubjectPage.open(context, subject),
            ),
          if (weakPoints.isNotEmpty) ...[
            const SizedBox(height: 20),
            const ReviewSectionHeader(
              icon: Icons.trending_down_outlined,
              title: '薄弱知识点',
              trailing: '按累计错误次数',
            ),
            const SizedBox(height: 10),
            _WeakPointsCard(entries: weakPoints),
          ],
          const SizedBox(height: 22),
          const ReviewSectionHeader(
            icon: Icons.folder_outlined,
            title: '资料与记录',
          ),
          const SizedBox(height: 10),
          _RecordRow(
            title: '复习资料',
            subtitle: '生成的卷子与批改结果',
            count: papers.length,
            onTap: () => ReviewRecordsPage.open(context),
          ),
          const SizedBox(height: 8),
          _RecordRow(
            title: '作业提交记录',
            subtitle: '提交时间、附件与批改',
            count: submitted.length,
            onTap: () => ReviewRecordsPage.open(context, initialTab: 1),
          ),
        ],
      );
    });
  }

  /// 作答来源明细放进底部弹层：首屏只留一行摘要，明细要看时再看。
  ///
  /// 用 `showModalBottomSheet` 而不是折叠面板：折叠面板会把首屏结构顶下去，
  /// 关掉之后滚动位置又回不来，家长会以为页面「跳了」。
  void _showChannelSheet(
    BuildContext context,
    Map<AttemptChannel, int> tally,
    int graduated,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(18),
          ),
          child: SingleChildScrollView(
            child: _ChannelCard(tally: tally, graduated: graduated),
          ),
        ),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.masteryRate,
    required this.poolCount,
    required this.masteredCount,
    required this.weekPassCount,
    required this.weekSubmittedPapers,
  });

  final double masteryRate;
  final int poolCount;
  final int masteredCount;
  final int weekPassCount;
  final int weekSubmittedPapers;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '错题掌握率',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                '${(masteryRate * 100).round()}%',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.success,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: masteryRate,
              minHeight: 9,
              backgroundColor: AppColors.border,
              valueColor: const AlwaysStoppedAnimation(AppColors.success),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '口径：通过检查毕业的题 ÷（毕业 + 待复习）。孩子自评「标记掌握」不计入。',
            style: TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _stat('待复习', poolCount, AppColors.warning),
              _stat('已掌握', masteredCount, AppColors.success),
              _stat('本周通过', weekPassCount, AppColors.primary),
              _stat('本周回传', weekSubmittedPapers, AppColors.accent),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  weekPassCount > 0
                      ? Icons.check_circle_outline
                      : Icons.info_outline,
                  size: 16,
                  color: weekPassCount > 0
                      ? AppColors.success
                      : AppColors.textMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    weekPassCount > 0
                        ? '本周有 $weekPassCount 次作答被判定通过，复习是有效的。'
                        : '本周还没有通过记录的作答。可以提醒孩子把印出来的卷子做完并回传。',
                    style: const TextStyle(fontSize: 12, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, int value, Color color) {
    return Expanded(
      child: Column(
        children: [
          Text(
            '$value',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// 自评警告条：只讲一件事，不展开渠道明细。
class _SelfAssessBanner extends StatelessWidget {
  const _SelfAssessBanner({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('review_self_assess_banner'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.help_outline,
              size: 16,
              color: AppColors.warning,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '其中 $count 次是孩子自评「做对了」，没有作答证据，掌握率不认它。',
                style: const TextStyle(fontSize: 12, height: 1.5),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              '看明细 ›',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.warning,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 作答来源的一行摘要。点开才是完整的渠道分布。
class _ChannelSummaryRow extends StatelessWidget {
  const _ChannelSummaryRow({
    required this.total,
    required this.passCount,
    required this.onTap,
  });

  final int total;
  final int passCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('review_channel_summary'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.rule_outlined,
              size: 16,
              color: AppColors.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '本周作答 $total 次 · 通过 $passCount 次',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
            const Text(
              '来源明细 ›',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「资料与记录」的一行入口。
class _RecordRow extends StatelessWidget {
  const _RecordRow({
    required this.title,
    required this.subtitle,
    required this.count,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              '$count 份',
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textMuted,
              ),
            ),
            const Icon(
              Icons.chevron_right,
              size: 18,
              color: AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

/// 本周作答的渠道构成：**这个对是判出来的，还是孩子自己说的**。
///
/// 家长端最需要这一块。孩子把卷子交回来、错题从池子里消失，同样会让家长
/// 觉得「在进步」——但如果其中一半是「自评正确」，那其实是孩子自己勾的，
/// 没有任何作答证据。不把这件事摆出来，配套的「掌握率」就成了装饰。
class _ChannelCard extends StatelessWidget {
  const _ChannelCard({required this.tally, required this.graduated});

  final Map<AttemptChannel, int> tally;
  final int graduated;

  @override
  Widget build(BuildContext context) {
    final total = tally.values.fold<int>(0, (sum, value) => sum + value);
    final selfCount = tally[AttemptChannel.paperSelf] ?? 0;
    final ordered = [
      AttemptChannel.paper,
      AttemptChannel.practice,
      AttemptChannel.paperSelf,
    ].where((channel) => (tally[channel] ?? 0) > 0);

    return Container(
      width: double.infinity,
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
              const Icon(
                Icons.rule_outlined,
                size: 17,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              const Text(
                '本周作答来源',
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                '共 $total 次',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...ordered.map((channel) {
            final count = tally[channel] ?? 0;
            final ratio = total == 0 ? 0.0 : count / total;
            final color = attemptChannelColor(channel);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ReviewChannelBadge(channel: channel, compact: true),
                      const Spacer(),
                      Text(
                        '$count 次',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 6,
                      backgroundColor: AppColors.border,
                      valueColor: AlwaysStoppedAnimation(color),
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 2),
          Text(
            graduated > 0 ? '本周 $graduated 道题通过检查移出错题库。' : '本周还没有错题通过检查毕业。',
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
          if (selfCount > 0) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '其中 $selfCount 次是孩子自评「做对了」，没有录入答案、'
                '无法核对。建议挑一到两道要求把答案写下来，掌握率才靠得住。',
                style: const TextStyle(fontSize: 11.5, height: 1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _WeakPointsCard extends StatelessWidget {
  const _WeakPointsCard({required this.entries});

  final List<MapEntry<String, int>> entries;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.key,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '累计错 ${entry.value} 次',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          const Text(
            '这几项是孩子下一轮复习会优先覆盖的内容。',
            style: TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}
