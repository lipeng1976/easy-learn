import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/review_controller.dart';
import '../../models/review_model.dart';
import '../../services/review_service.dart';
import '../../widgets/math_text.dart';
import 'review_check_page.dart';
import 'review_summary_page.dart';
import 'widgets/review_badges.dart';
import 'widgets/review_export_sheet.dart';
import 'widgets/review_item_photos.dart';

/// 复习资料详情：**先看清这份卷子印了什么，再决定导出 / 回传 / 看报告**。
///
/// 为什么单独成页，而不是把内容塞进资料列表的卡片里：
/// 卷内是**快照**，它和学生手上那张纸一一对应。把快照摊在列表里会让人以为
/// 看到的是「当前错题」，而快照恰恰是「印出去那一刻的题」——
/// 这两个概念混在一起，批改时就会有人拿现在的题去对过去的纸。
class ReviewPaperPage extends StatefulWidget {
  const ReviewPaperPage({super.key, required this.paperId});

  final String paperId;

  @override
  State<ReviewPaperPage> createState() => _ReviewPaperPageState();
}

class _ReviewPaperPageState extends State<ReviewPaperPage> {
  final ReviewController controller = Get.find<ReviewController>();

  /// 答案页默认收起：这份卷子多半还没做，摊开答案等于把练习变成抄写。
  bool _showAnswers = false;

  /// 卷内题目是否还在取。
  ///
  /// ⛔ 这一位**不能省**。`openPaper` 是先设 `activePaper`、再 await 取题目，
  /// 所以「卷名已经能显示了、题目还是空的」是一个真实存在的中间态。
  /// 早先这个中间态直接落到 `items.isEmpty` 分支，于是页面上写着
  /// 「这份资料还没有题目」——用户读到的意思是「卷子是空的」，
  /// 而真相是「还在取」。网络慢一点，这句假话就停留几十毫秒到几百毫秒，
  /// 用户会以为资料生成失败了（本机部署下服务端在局域网，症状时有时无）。
  ///
  /// 同族陷阱：`openPaper` 换一份卷时 `activePaperItems` 里还留着**上一份**
  /// 的题，不看这一位的话，要么闪一下别人的题，要么张冠李戴。
  bool _loadingItems = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_loadingItems) setState(() => _loadingItems = true);
    try {
      await controller.openPaper(widget.paperId);
    } finally {
      // `openPaper` 失败也要把「加载中」收掉，否则页面永远转圈 ——
      // 转圈和「没有题目」是两种不同的坏，至少前者不会骗人。
      if (mounted) setState(() => _loadingItems = false);
    }
  }

  ReviewPaper? _paper() {
    final direct = controller.paperById(widget.paperId);
    if (direct != null) return direct;
    final active = controller.activePaper.value;
    return active?.id == widget.paperId ? active : null;
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final paper = _paper();
      if (paper == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('复习资料')),
          body: const Center(child: CircularProgressIndicator()),
        );
      }
      final items = controller.activePaperItems.toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      final finished =
          paper.status == PaperStatus.graded ||
          paper.status == PaperStatus.closed;

      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: const Text('复习资料'),
          actions: [
            if (items.any((item) => item.answerKey.isNotEmpty))
              TextButton.icon(
                onPressed: () => setState(() => _showAnswers = !_showAnswers),
                icon: Icon(
                  _showAnswers ? Icons.visibility_off : Icons.visibility,
                  size: 16,
                ),
                label: Text(
                  _showAnswers ? '收起答案' : '看答案',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
          ],
        ),
        body: _loadingItems
            ? const Center(child: CircularProgressIndicator())
            : items.isEmpty
            ? const Center(
                child: Text(
                  '这份资料还没有题目',
                  style: TextStyle(color: AppColors.textMuted),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  _PaperHeaderCard(paper: paper),
                  const SizedBox(height: 12),
                  if (finished) _ResultCard(paper: paper),
                  if (finished) const SizedBox(height: 12),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '卷内题目（快照）',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        '${items.length} 道',
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '题目内容在组卷时已冻结，之后改错题也不会改这份卷子。',
                    style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 10),
                  ...items.map(
                    (item) => _ItemCard(
                      item: item,
                      showAnswer: _showAnswers,
                      controller: controller,
                    ),
                  ),
                ],
              ),
        bottomNavigationBar: _bottomBar(paper, finished),
      );
    });
  }

  Widget _bottomBar(ReviewPaper paper, bool finished) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: const BoxDecoration(
          color: AppColors.card,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!finished)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => openReviewExportSheet(
                    context: context,
                    controller: controller,
                    paperId: paper.id,
                  ),
                  icon: const Icon(Icons.ios_share_outlined, size: 16),
                  label: const Text(
                    '打印 / 下载 / 转发',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
            if (!finished) const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  if (finished) {
                    Get.to(() => ReviewSummaryPage(paperId: paper.id));
                  } else {
                    Get.to(() => ReviewCheckPage(paperId: paper.id));
                  }
                },
                icon: Icon(
                  finished
                      ? Icons.summarize_outlined
                      : Icons.fact_check_outlined,
                ),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                label: Text(finished ? '看这份卷子的报告' : '我做完了，回传批改'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaperHeaderCard extends StatelessWidget {
  const _PaperHeaderCard({required this.paper});

  final ReviewPaper paper;

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
              Expanded(
                child: Text(
                  paper.title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              PaperStatusBadge(status: paper.status),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ReviewTag(
                text: '${paper.itemCount} 道题',
                color: AppColors.textMuted,
              ),
              if (paper.subject.isNotEmpty)
                ReviewTag(text: paper.subject, color: AppColors.primary),
              ...paper.knowledgePoints.map(
                (point) => ReviewTag(text: point, color: AppColors.accent),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _StageRow(
            label: '组卷',
            value: paper.createdAt,
            color: AppColors.primary,
          ),
          _StageRow(
            label: '导出',
            value: paper.exportedAt,
            color: AppColors.accent,
          ),
          _StageRow(
            label: '回传',
            value: paper.submittedAt,
            color: AppColors.warning,
          ),
          _StageRow(
            label: '批改',
            value: paper.gradedAt,
            color: AppColors.success,
            last: true,
          ),
        ],
      ),
    );
  }
}

/// 过程链：组卷 → 导出 → 回传 → 批改。
///
/// 四个时间戳一行一个，缺的那一环保持灰色 —— 「卡在哪一步」一眼可见，
/// 比只显示一个状态标签有用得多。
class _StageRow extends StatelessWidget {
  const _StageRow({
    required this.label,
    required this.value,
    required this.color,
    this.last = false,
  });

  final String label;
  final DateTime? value;
  final Color color;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final done = value != null;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 4),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: done ? color : AppColors.border,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 34,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: done ? AppColors.text : AppColors.textMuted,
                fontWeight: done ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          Text(
            done ? _formatDate(value!) : '—',
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.paper});

  final ReviewPaper paper;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          _metric('通过', paper.passCount, AppColors.success),
          _metric('未通过', paper.failCount, AppColors.danger),
          _metric('通过率', (paper.passRate * 100).round(), AppColors.primary),
        ],
      ),
    );
  }

  Widget _metric(String label, int value, Color color) {
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
            style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.item,
    required this.showAnswer,
    required this.controller,
  });

  final ReviewPaperItem item;
  final bool showAnswer;

  /// 只为取原题照片：`loadMistakeImages` 是唯一的取图入口，
  /// 这里再走一份实现就会让「学生端有图、家长端没图」这种差异出现。
  final ReviewController controller;

  @override
  Widget build(BuildContext context) {
    final color = switch (item.result) {
      PaperItemResult.correct => AppColors.success,
      PaperItemResult.wrong => AppColors.danger,
      PaperItemResult.pending => AppColors.textMuted,
    };
    final label = switch (item.result) {
      PaperItemResult.correct => '通过',
      PaperItemResult.wrong => '未通过',
      PaperItemResult.pending => '待作答',
    };
    // 已作答的题标出渠道：这条对是 AI 按参考答案判出来的，还是学生自己说对，
    // 可信度完全不同；详情页不标，家长端标了也没人会去对照。
    final channel = item.result == PaperItemResult.pending
        ? null
        : ReviewService.channelForAnswer(item.studentAnswer);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 22,
                height: 22,
                margin: const EdgeInsets.only(right: 8, top: 1),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Center(
                  child: Text(
                    '${item.sortOrder + 1}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: MathText(
                  item.questionTitle,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(width: 8),
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
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (channel != null)
                ReviewChannelBadge(channel: channel, compact: true),
              if (item.knowledgePoint.isNotEmpty)
                ReviewTag(text: item.knowledgePoint, color: AppColors.accent),
            ],
          ),
          if (item.questionBody.isNotEmpty) ...[
            const SizedBox(height: 8),
            MathText(
              item.questionBody,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: AppColors.text,
              ),
            ),
          ],
          // 原题照片紧跟在题干后面：错题里的图往往就是题目本身
          // （「如图」两个字之外别无信息），把它挪到答案区下面会被漏看。
          ReviewItemPhotos(
            key: ValueKey<String>('photo-${item.id}-${item.mistakeId}'),
            mistakeId: item.mistakeId,
            loader: controller.loadMistakeImages,
          ),
          if (item.studentAnswer.isNotEmpty) ...[
            const SizedBox(height: 8),
            _Line(label: '卷面作答', value: item.studentAnswer),
          ],
          if (showAnswer && item.answerKey.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              child: MathText(
                '参考答案：${item.answerKey}',
                style: const TextStyle(fontSize: 12.5, height: 1.5),
              ),
            ),
          ],
          if (item.comment.isNotEmpty) ...[
            const SizedBox(height: 6),
            _Line(label: '批改', value: item.comment),
          ],
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    // 原来是 `RichText`：label 灰、value 正常色。公式没法塞进那条 span 流里，
    // 所以换成整段 `MathText`，两段同色 —— 用全角冒号隔开，读起来仍然清楚。
    // 这里的内容（卷面作答 / 批改评语）恰恰是最可能带算式的两行。
    return MathText(
      '$label：$value',
      style: const TextStyle(
        fontSize: 12.5,
        height: 1.5,
        color: AppColors.text,
      ),
    );
  }
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${local.month}月${local.day}日 ${two(local.hour)}:${two(local.minute)}';
}
