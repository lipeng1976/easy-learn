import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../constants/app_colors.dart';
import '../../../controllers/review_controller.dart';
import '../../../models/review_model.dart';
import '../../../widgets/math_text.dart';

/// 组卷前的「选题」页：手工勾选要重做的错题。
///
/// ## 为什么要有这一步
///
/// 以前「生成错题资料」是**自动全量**：按薄弱度挑最多 10 道，学生没得选。
/// 结果是学生拿到一张「不知道为什么会是这几道」的卷子 —— 他可能只想先
/// 做最近错的那 3 道，却被迫做一整张 10 道的卷子，做完的意愿反而下降。
///
/// 这里让学生自己圈范围：默认勾选「错得最多」的题（错得多的排在前面、
/// 默认选中），一眼就能看到哪些是重点易错题，勾掉不想做的、勾上想做的，
/// 点「生成」才开始组卷。
class MistakePickPage extends StatefulWidget {
  const MistakePickPage({super.key});

  @override
  State<MistakePickPage> createState() => _MistakePickPageState();
}

class _MistakePickPageState extends State<MistakePickPage> {
  final ReviewController controller = Get.find<ReviewController>();

  /// 已勾选的错题 id（用 LinkedHashSet 保持「错得多的在前」的顺序）。
  final Set<String> _selected = <String>{};

  /// 默认选中的题量上限。与 [ReviewService.defaultPaperLimit] 一致：
  /// 一次印 10 道已经够多，再多的题做不完，闭环会死在「印了但没做」。
  static const int _defaultPickLimit = 10;

  @override
  void initState() {
    super.initState();
    // 默认勾选「错得最多」的前 N 道。按 wrongCount 降序、同分按入池时间。
    final candidates = _sortedCandidates();
    for (final mistake in candidates.take(_defaultPickLimit)) {
      _selected.add(mistake.id);
    }
  }

  /// 待复习的错题，按「错得越多越靠前」排序。
  ///
  /// 走 `viewOf` 而不是 `poolMistakes`：**选题范围必须和列表上看到的一致**。
  /// 用 `poolMistakes` 时它只按科目筛、不看学期，于是会出现
  /// 「列表说待复习 0 道，点生成却能勾出别的学期的题」。
  List<ReviewMistake> _sortedCandidates() {
    final list = controller.viewOf(ReviewState.pending);
    list.sort((a, b) {
      final byWrong = b.wrongCount.compareTo(a.wrongCount);
      if (byWrong != 0) return byWrong;
      return a.createdAt.compareTo(b.createdAt);
    });
    return list;
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.add(id)) {
        _selected.remove(id);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selected.clear();
      _selected.addAll(_sortedCandidates().map((m) => m.id));
    });
  }

  void _clearAll() {
    setState(() => _selected.clear());
  }

  Future<void> _compose() async {
    if (_selected.isEmpty) {
      Get.snackbar('还没选题', '至少勾选一道错题再生成');
      return;
    }
    final result = await controller.composeAndPrintPaper(
      mistakeIds: _selected.toList(),
    );
    if (!mounted) return;
    if (!result.ok) {
      Get.snackbar('未能生成', result.message);
      return;
    }
    // 组卷成功：关掉选题页，让复习页切到「复习资料」段。
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final candidates = _sortedCandidates();
    // 已排进别的卷子、或回传等批改的题不在这个列表里。不说一句的话，
    // 学生会以为「错题少了」—— 而这正是最容易被当成 bug 的形态。
    final busyCount = controller.reviewingMistakes.length +
        controller.verifyingMistakes.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择要重做的错题'),
        actions: [
          TextButton(
            onPressed: _selectAll,
            child: const Text('全选', style: TextStyle(fontSize: 13)),
          ),
          TextButton(
            onPressed: _clearAll,
            child: const Text('清空', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
      body: candidates.isEmpty
          ? const _EmptyPickHint()
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              itemCount: candidates.length + (busyCount > 0 ? 1 : 0),
              itemBuilder: (context, index) {
                // 第一条是说明条，后面的才是题。
                if (busyCount > 0 && index == 0) {
                  return _BusyNotice(count: busyCount);
                }
                final mistake =
                    candidates[index - (busyCount > 0 ? 1 : 0)];
                return _PickTile(
                  mistake: mistake,
                  selected: _selected.contains(mistake.id),
                  onToggle: () => _toggle(mistake.id),
                );
              },
            ),
      bottomNavigationBar: _ComposeBar(
        selectedCount: _selected.length,
        onCompose: _selected.isEmpty ? null : _compose,
      ),
    );
  }
}

/// 「有 N 道题不在这里」的说明条。
///
/// 那些题已经排进别的卷子（复习中）或回传等批改，不能重复进新卷 ——
/// 但学生看不到它们时第一反应是「我的错题去哪了」。一行灰字比让人猜便宜。
class _BusyNotice extends StatelessWidget {
  const _BusyNotice({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline,
            size: 15,
            color: AppColors.warning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '另有 $count 道题已在别的卷子里（复习中或等批改），做完那份再选',
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: AppColors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PickTile extends StatelessWidget {
  const _PickTile({
    required this.mistake,
    required this.selected,
    required this.onToggle,
  });

  final ReviewMistake mistake;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final isFrequent = mistake.wrongCount >= 3;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.primary.withValues(alpha: 0.06)
            : AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? AppColors.primary : AppColors.border,
          width: selected ? 1.4 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Checkbox(selected: selected),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MathText(
                        mistake.title,
                        maxLines: 2,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _metaLine(mistake),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (isFrequent)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.danger,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '错 ${mistake.wrongCount} 次',
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  )
                else if (mistake.wrongCount > 1)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.danger.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '错 ${mistake.wrongCount} 次',
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _metaLine(ReviewMistake mistake) {
    final parts = <String>[
      if (mistake.subject.isNotEmpty) mistake.subject,
      if (mistake.knowledgePoint.isNotEmpty) mistake.knowledgePoint,
      if (mistake.questionNo.isNotEmpty) '第 ${mistake.questionNo} 题',
    ];
    return parts.join(' · ');
  }
}

class _Checkbox extends StatelessWidget {
  const _Checkbox({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? AppColors.primary : Colors.transparent,
        border: Border.all(
          color: selected ? AppColors.primary : AppColors.textMuted,
          width: 1.5,
        ),
      ),
      child: selected
          ? const Icon(Icons.check, size: 15, color: Colors.white)
          : null,
    );
  }
}

class _ComposeBar extends StatelessWidget {
  const _ComposeBar({required this.selectedCount, required this.onCompose});

  final int selectedCount;
  final VoidCallback? onCompose;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(
          color: AppColors.card,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            Text(
              '已选 $selectedCount 道',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.text,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: onCompose,
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                label: const Text('生成错题资料'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyPickHint extends StatelessWidget {
  const _EmptyPickHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.check_circle_outline,
              size: 48,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: 12),
            const Text(
              '没有可选的错题',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              '完成作业并提交检查后，错题会自动进错题库',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
