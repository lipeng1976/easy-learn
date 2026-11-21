import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/parent_controller.dart';
import '../../models/review_model.dart';
import '../../services/local_seed_service.dart';
import '../../widgets/math_text.dart';
import '../student/widgets/review_badges.dart';
import '../student/widgets/review_item_photos.dart';

/// 家长端「复习资料」的卷内预览 —— **只读**。
///
/// ── 为什么要有这一页 ────────────────────────────────────────────────────
///
/// 家长端复习页的资料卡原来是**纯静态**的：没有 `onTap`、没有箭头、没有按钮。
/// 但它和「作业提交记录」「错题清单」卡片长在同一个列表里，视觉上一模一样 ——
/// 家长自然会去点，而点了没有任何反应。用户报的「错题待导出，点击没反应」
/// 就是这里。
///
/// 点开之后家长要看的是**这份卷子到底印了哪些题**（不是要导出）。导出、打印、
/// 回传批改都是孩子的动作，家长端没有、也不该有那些入口 ——
/// 所以这一页的底部明确写着「导出/回传请孩子在手机上操作」。
/// 把「你没权限」说清楚，比让按钮消失更不容易让人反复试。
///
/// ⚠️ 页面必须自己校验 `paperId` 是否属于**当前可见的孩子**：
/// 入口虽然只从已过滤的列表来，但页面能被直接 `Get.to` 打开，
/// 而本地模式下没有 RLS 兜底。
class ParentReviewPaperPage extends StatefulWidget {
  const ParentReviewPaperPage({
    super.key,
    required this.paperId,
    this.photoLoader,
  });

  final String paperId;

  /// 取某道错题的原题照片。
  ///
  /// 默认走本地/云端仓储；**留这个口子是为了 widget 测试**：
  /// 假时钟里 sqflite I/O 永远不返回，页面里任何一次真库读取都会以
  /// 「dispose 之后仍有 pending timer」的形式假红（已经栽过）。
  /// 生产代码不传，行为与没有这个参数时逐字相同。
  final Future<List<ReviewMistakeImage>> Function(String mistakeId)? photoLoader;

  static void open(String paperId) {
    Get.to(() => ParentReviewPaperPage(paperId: paperId));
  }

  @override
  State<ParentReviewPaperPage> createState() => _ParentReviewPaperPageState();
}

class _ParentReviewPaperPageState extends State<ParentReviewPaperPage> {
  List<ReviewPaperItem>? _items;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await LocalSeedService.reviewPaperItems(widget.paperId);
      if (!mounted) return;
      setState(() => _items = items);
    } catch (_) {
      if (!mounted) return;
      // 失败要能看见 —— 空列表和「读失败」在界面上必须长得不一样，
      // 否则家长会把「没读出来」读成「这份卷子没有题」。
      setState(() => _error = '这份资料的题目没能读出来，请稍后重试。');
    }
  }

  /// 只认**当前可见孩子**的资料。
  ReviewPaper? _paper() {
    final parent = Get.find<ParentController>();
    for (final paper in parent.visibleReviewPapers) {
      if (paper.id == widget.paperId) return paper;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final paper = _paper();

    if (paper == null) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: const Text('复习资料')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '这份资料已不在孩子的记录中，可能已被删除。',
              style: TextStyle(color: AppColors.textMuted),
            ),
          ),
        ),
      );
    }

    final items = _items;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('复习资料')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          _HeaderCard(paper: paper),
          const SizedBox(height: 12),
          _StatusHint(status: paper.status),
          const SizedBox(height: 16),
          if (_error.isNotEmpty)
            _EmptyBox(text: _error)
          else if (items == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (items.isEmpty)
            const _EmptyBox(text: '这份资料里还没有题目。')
          else ...[
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '卷内题目（快照）',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
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
              '题目在组卷时已冻结，之后改错题不会改这份卷子。',
              style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < items.length; i++)
              _ItemCard(
                item: items[i],
                index: i,
                photoLoader:
                    widget.photoLoader ?? LocalSeedService.reviewMistakeImages,
              ),
          ],
          const SizedBox(height: 6),
          const _ReadOnlyNote(),
        ],
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.paper});

  final ReviewPaper paper;

  @override
  Widget build(BuildContext context) {
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
              Expanded(
                child: Text(
                  paper.title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              PaperStatusBadge(status: paper.status),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${paper.itemCount} 道题'
            '${paper.knowledgePoints.isEmpty ? '' : ' · ${paper.knowledgePoints.join('、')}'}',
            style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
          ),
          if (paper.gradedAt != null) ...[
            const SizedBox(height: 8),
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
        ],
      ),
    );
  }
}

/// 一句话说清「这份卷子现在卡在谁手上」。
///
/// ⭐ 这是家长端点开之后最该看到的东西：他看到「待导出」会以为**自己**能导出，
/// 而导出入口只存在于孩子那侧。不把这句写出来，卡片就算能点开，
/// 家长下一步仍然是满屏找按钮。
class _StatusHint extends StatelessWidget {
  const _StatusHint({required this.status});

  final PaperStatus status;

  @override
  Widget build(BuildContext context) {
    final (icon, color, text) = switch (status) {
      PaperStatus.draft => (
        Icons.ios_share_outlined,
        AppColors.warning,
        '还没导出打印。这份卷子要由孩子在自己的手机上打开「复习 → 复习资料」导出，'
            '家长端只能看，不能导出。',
      ),
      PaperStatus.printed => (
        Icons.edit_note_outlined,
        AppColors.primary,
        '已导出打印，等孩子做完纸质卷后回传批改。',
      ),
      PaperStatus.submitted => (
        Icons.hourglass_bottom,
        AppColors.primary,
        '孩子已回传，等批改结果。',
      ),
      PaperStatus.graded => (
        Icons.fact_check_outlined,
        AppColors.success,
        '已批改，下面是每道题的结果。',
      ),
      PaperStatus.closed => (
        Icons.archive_outlined,
        AppColors.textMuted,
        '这份资料已归档。',
      ),
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12.5,
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

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.item,
    required this.index,
    required this.photoLoader,
  });

  final ReviewPaperItem item;

  final Future<List<ReviewMistakeImage>> Function(String mistakeId) photoLoader;

  /// 列表位置而不是 `sortOrder`：题号要**连续**。
  /// `sortOrder` 是排序键，删过题之后可能跳号，界面上就会从「3」跳到「5」。
  final int index;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (item.result) {
      PaperItemResult.correct => ('通过', AppColors.success),
      PaperItemResult.wrong => ('未通过', AppColors.danger),
      PaperItemResult.pending => ('待作答', AppColors.textMuted),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
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
                    '${index + 1}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),
              Expanded(
                // 题干可能带 LaTeX（模型写错题时就是 `$...$`），
                // 家长端原来整页都没有公式渲染，这里必须走 MathText。
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
          if (item.knowledgePoint.isNotEmpty) ...[
            const SizedBox(height: 8),
            ReviewTag(text: item.knowledgePoint, color: AppColors.accent),
          ],
          if (item.questionBody.isNotEmpty &&
              item.questionBody != item.questionTitle) ...[
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
          // 与孩子那侧的快照页**同一个组件**：家长看到的就是孩子看到的。
          ReviewItemPhotos(
            key: ValueKey<String>('photo-${item.id}-${item.mistakeId}'),
            mistakeId: item.mistakeId,
            loader: photoLoader,
          ),
          if (item.studentAnswer.isNotEmpty) ...[
            const SizedBox(height: 8),
            _Line(label: '卷面作答', value: item.studentAnswer),
          ],
          if (item.answerKey.isNotEmpty) ...[
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
    return RichText(
      text: TextSpan(
        style: const TextStyle(
          fontSize: 12.5,
          height: 1.5,
          color: AppColors.text,
        ),
        children: [
          TextSpan(
            text: '$label：',
            style: const TextStyle(
              color: AppColors.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(text: value),
        ],
      ),
    );
  }
}

class _EmptyBox extends StatelessWidget {
  const _EmptyBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
      ),
    );
  }
}

class _ReadOnlyNote extends StatelessWidget {
  const _ReadOnlyNote();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 4),
      child: Text(
        '家长端只能查看。导出打印、回传批改、重新作答都要孩子在学生端操作。',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
      ),
    );
  }
}
