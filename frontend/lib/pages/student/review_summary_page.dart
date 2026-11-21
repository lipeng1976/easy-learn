import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/review_controller.dart';
import '../../models/review_model.dart';
import '../../services/review_service.dart';
import 'widgets/review_export_sheet.dart';
import '../../utils/pop_route.dart';

/// 单卷报告：**这一轮到底发生了什么、还差什么、下一步做什么**。
///
/// 它是「有总结」这件事的落点。报告刻意不写成一句「加油」，
/// 而是把数字摆出来（题量 = 通过 + 未通过，必须自洽）、
/// 把没过关的知识点点名，并给出下一步动作 ——
/// 否则学生看完只知道"错了"，仍然不知道明天先看哪一页。
class ReviewSummaryPage extends StatefulWidget {
  const ReviewSummaryPage({super.key, required this.paperId});

  final String paperId;

  @override
  State<ReviewSummaryPage> createState() => _ReviewSummaryPageState();
}

class _ReviewSummaryPageState extends State<ReviewSummaryPage> {
  final ReviewController controller = Get.find<ReviewController>();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    controller.openPaper(widget.paperId);
  }

  Future<void> _composeNextRound() async {
    setState(() => _busy = true);
    final result = await controller.composeAndPrintPaper();
    if (mounted) setState(() => _busy = false);
    if (!result.ok) {
      Get.snackbar('暂时不能组卷', result.message);
      return;
    }
    Get.snackbar('下一轮已生成', result.message);
    if (!mounted) return;
    final paperId = controller.activePaper.value?.id;
    if (paperId != null) {
      await openReviewExportSheet(
        context: context,
        controller: controller,
        paperId: paperId,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final summary = controller.summaryOfPaper(widget.paperId);
      final paper = controller.paperById(widget.paperId);
      final items = controller.activePaperItems.toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      final weak = controller.weakPoints;

      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: const Text('复习报告')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          children: [
            _HeadlineCard(
              paper: paper,
              summary: summary,
              itemCount: items.length,
            ),
            const SizedBox(height: 12),
            if (summary != null) _ConclusionCard(summary: summary),
            if (weak.isNotEmpty) ...[
              const SizedBox(height: 12),
              _WeakPointsCard(weakPoints: weak),
            ],
            const SizedBox(height: 12),
            const Text(
              '逐题结果',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (items.isEmpty)
              const Text(
                '这份资料没有留下逐题记录',
                style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
              )
            else
              ...items.map((item) => _ResultRow(item: item)),
            const SizedBox(height: 4),
            const Text(
              '数字口径：通过率 = 通过题数 ÷ 本卷题数；自评掌握不计入掌握率。',
              style: TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _composeNextRound,
                icon: const Icon(Icons.auto_awesome_outlined, size: 16),
                label: Text(
                  _busy ? '正在组卷…' : '把没过的题再组一轮',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => popRoute(context),
                icon: const Icon(Icons.arrow_back, size: 16),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                label: const Text('返回复习页'),
              ),
            ),
          ],
        ),
      );
    });
  }
}

class _HeadlineCard extends StatelessWidget {
  const _HeadlineCard({
    required this.paper,
    required this.summary,
    required this.itemCount,
  });

  final ReviewPaper? paper;
  final ReviewSummary? summary;
  final int itemCount;

  @override
  Widget build(BuildContext context) {
    final total = summary?.totalCount ?? paper?.itemCount ?? itemCount;
    final pass = summary?.passCount ?? paper?.passCount ?? 0;
    final fail = (summary?.remainCount ?? paper?.failCount ?? 0);
    final rate = summary?.passRate ?? (total == 0 ? 0.0 : pass / total);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            paper?.title ?? '复习报告',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          if (paper?.gradedAt != null) ...[
            const SizedBox(height: 4),
            Text(
              '批改于 ${_formatDate(paper!.gradedAt!)}',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textMuted,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              _metric('本卷题数', '$total', AppColors.text),
              _metric('通过', '$pass', AppColors.success),
              _metric('未通过', '$fail', AppColors.danger),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Text(
                '通过率',
                style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: rate,
                    minHeight: 9,
                    backgroundColor: AppColors.border,
                    valueColor: AlwaysStoppedAnimation(
                      rate >= 0.8 ? AppColors.success : AppColors.warning,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(rate * 100).round()}%',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '通过 $pass + 未通过 $fail = $total 道',
            style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _metric(String label, String value, Color color) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _ConclusionCard extends StatelessWidget {
  const _ConclusionCard({required this.summary});

  final ReviewSummary summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.assignment_turned_in_outlined,
                size: 17,
                color: AppColors.primary,
              ),
              const SizedBox(width: 7),
              const Text(
                '本轮结论',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            summary.body,
            style: const TextStyle(fontSize: 13, height: 1.7),
          ),
        ],
      ),
    );
  }
}

class _WeakPointsCard extends StatelessWidget {
  const _WeakPointsCard({required this.weakPoints});

  final List<WeakKnowledgePoint> weakPoints;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.trending_down_outlined,
                size: 17,
                color: AppColors.danger,
              ),
              const SizedBox(width: 7),
              const Text(
                '待复习池的薄弱知识点',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '按累计错误次数排序，决定下一轮先组哪些题。',
            style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
          ),
          const SizedBox(height: 10),
          ...weakPoints.map(
            (point) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      point.name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${point.mistakeCount} 道 · 累计错 ${point.wrongCount} 次',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.item});

  final ReviewPaperItem item;

  @override
  Widget build(BuildContext context) {
    final (color, label, icon) = switch (item.result) {
      PaperItemResult.correct => (
        AppColors.success,
        '通过',
        Icons.check_circle_outline,
      ),
      PaperItemResult.wrong => (AppColors.danger, '未通过', Icons.cancel_outlined),
      PaperItemResult.pending => (
        AppColors.textMuted,
        '未判定',
        Icons.help_outline,
      ),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 17, color: color),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '${item.sortOrder + 1}. ${item.questionTitle}',
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
          if (item.knowledgePoint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 4),
              child: Text(
                item.knowledgePoint,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textMuted,
                ),
              ),
            ),
          if (item.comment.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 4),
              child: Text(
                item.comment,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: AppColors.text,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${local.month}月${local.day}日 ${two(local.hour)}:${two(local.minute)}';
}
