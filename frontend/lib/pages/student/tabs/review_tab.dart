import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../constants/app_colors.dart';
import '../../../controllers/review_controller.dart';
import '../../../models/review_model.dart';
import '../mistake_detail_page.dart';
import '../mistake_edit_page.dart';
import '../mistake_pick_page.dart';
import '../review_check_page.dart';
import '../review_paper_page.dart';
import '../review_report_page.dart';
import '../review_summary_page.dart';
import '../widgets/mistake_card.dart';
import '../widgets/review_badges.dart';
import '../widgets/review_export_sheet.dart';

/// 学生端「复习」页。
///
/// 四段式：**待复习 / 复习中 / 待批改 / 已掌握**，下面再接一块「复习资料」。
///
/// 分段按**错题状态**分，一段一个状态 —— 于是 tab 上的数字就是 tab 里的
/// 卡片数，永远不会互相打脸。早先是一段装多个状态（「待复习」里同时装着
/// 复习中和待批改），计数只数第一个，页面上就出现了「待复习 0」下面却
/// 躺着 3 张卡。
///
/// 「复习资料」不占分段位：它是**卷子**，有自己的生命周期（草稿 → 打印 →
/// 回传 → 批改），一份卷子里可以有多道题。把它和状态放在同一排，等于
/// 把两种东西混成一个维度 —— 它既没法参与学期筛选，计数口径也和旁边不同。
class ReviewTab extends StatefulWidget {
  const ReviewTab({super.key});

  @override
  State<ReviewTab> createState() => _ReviewTabState();
}

class _ReviewTabState extends State<ReviewTab> {
  final ReviewController controller = Get.find<ReviewController>();
  int _segment = 0;

  @override
  void initState() {
    super.initState();
    controller.loadReviewData();
    // 默认筛选只在这里定一次：放到 build 里会在用户切到「全部」之后
    // 又被重建拉回当前学期（Rx 写入还会触发「build 期间 setState」）。
    controller.ensureTermFilter();
  }

  Future<void> _composeAndPrint() async {
    // 与列表同一口径（科目 + 学期）：否则会出现「待复习 0 道」却仍能生成卷子。
    final pending = controller.viewOf(ReviewState.pending);
    if (pending.isEmpty) {
      Get.snackbar('暂无可复习的错题', '完成作业并提交检查后，错题会自动进入错题库');
      return;
    }
    // 先让学生手工圈范围（默认勾选错得最多的题），确定后再组卷。
    // 以前是直接自动全量组卷，学生没得选 —— 拿到一张「不知道为什么会是
    // 这几道」的卷子，做的意愿反而下降。
    final picked = await Get.to<bool>(() => const MistakePickPage());
    if (picked != true || !mounted) return;

    setState(() => _segment = 1);

    final paperId = controller.activePaper.value?.id;
    if (paperId == null) {
      Get.snackbar('资料已生成', '选好的错题已经生成复习资料');
      return;
    }
    // 组好之后立刻问「怎么取走」。三条路对设备的要求完全不同 ——
    // 家里没打印机的人要下载或转发，直接唤起打印只会让他卡在一个
    // 他并不打算打开的对话框里。
    await openReviewExportSheet(
      context: context,
      controller: controller,
      paperId: paperId,
    );
  }

  /// 分段的顺序 = 错题走完闭环的顺序，**一段就是一个状态**。
  ///
  /// 这样「tab 上的数字」和「tab 里的卡片数」永远是同一个数。
  /// 早先是一段装了两个状态（「待复习」里塞着复习中、待批改），
  /// 计数只数第一个 —— 于是页面上写着「待复习 0」，下面却躺着 3 张卡。
  static const List<ReviewState> _segmentStates = [
    ReviewState.pending,
    ReviewState.reviewing,
    ReviewState.verifying,
    ReviewState.mastered,
  ];

  /// 资料区是否展开。
  ///
  /// 默认展开：资料卡上挂着「导出 / 回传批改」两个入口，收起来就等于把它们
  /// 藏进一次点击之后。它排在分段下面而不是占一个分段位，是因为
  /// **卷子不是错题状态** —— 一份卷子里可以有多道题，而且它有自己的生命周期。
  bool _papersOpen = true;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final counts = <ReviewState, int>{
        for (final state in _segmentStates) state: controller.viewOf(state).length,
      };
      final current = _segmentStates[_segment];

      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          // 这里曾经放着「今日概念训练」与「英语单词打卡」两块入口。
          // 2026-11-12 搬到**计划页**：那两块答的是「今天要做什么」，
          // 而这一页答的是「做错的题怎么复习」。混在一起的后果是孩子
          // 一进复习页先看到两块「今日任务」，错题状态被推到下面，
          // 两个心智模型互相干扰。
          // 标题去掉了：底部导航已经写着「复习」，这一行只是把内容往下推。
          _OverviewCard(
            masteryRate: controller.filteredMasteryRate,
            busy: controller.isBusy.value,
            onCompose: _composeAndPrint,
            onManualAdd: () => Get.to(() => const MistakeEditPage()),
            onReport: () => Get.to(() => const ReviewReportPage()),
          ),
          const SizedBox(height: 12),
          _openPaperHint(
            counts[ReviewState.reviewing]! + counts[ReviewState.verifying]!,
          ),
          // 归档 + 科目压成一行两个下拉。原来是两整行标签，一屏里三分之一
          // 被筛选占掉，往下翻才看得到错题。
          _filterBar(),
          const SizedBox(height: 12),
          _segments(counts),
          const SizedBox(height: 10),
          ..._sectionFor(current),
          const SizedBox(height: 18),
          ..._paperSection(),
        ],
      );
    });
  }

  /// 一条「卷子还没闭环」的提示。
  ///
  /// 为什么必须有：`reviewing` 会把题从待复习池里抽走，而抽走的原因
  /// （印出去的卷子没做、没回传）在页面上**一个字都没有**。用户只看到
  /// 「待复习 0」，会以为错题不见了。这句话把那 45 道题的处境说破。
  Widget _openPaperHint(int inFlight) {
    final papers = controller.openPapers;
    if (papers.isEmpty) return const SizedBox.shrink();

    final text = inFlight > 0
        ? '${papers.length} 份复习资料还没做完 · $inFlight 道题在等它们'
        : '${papers.length} 份复习资料还没做完';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _segment = 1),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              children: [
                const Icon(
                  Icons.assignment_outlined,
                  size: 16,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: AppColors.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 一行筛选：`学期` + `科目`。两个都是下拉，点开才是选择器。
  ///
  /// 取舍：科目从「平铺标签」变成「点开再选」，多一次点击。
  /// 但筛选是低频动作，而平铺的代价是每加一个科目就多占一行，
  /// 且「学期」「科目」两组标签在视觉上完全同权，看不出哪个在管哪一段。
  Widget _filterBar() {
    return Row(
      children: [
        Expanded(
          child: _filterPill(
            icon: Icons.event_note_outlined,
            label: controller.termFilterLabel,
            onTap: _openTermPicker,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _filterPill(
            icon: Icons.folder_outlined,
            label: controller.selectedSubject.value == '全部'
                ? '全部科目'
                : controller.selectedSubject.value,
            onTap: _openSubjectPicker,
          ),
        ),
      ],
    );
  }

  Widget _filterPill({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 9, 6, 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Icon(icon, size: 15, color: AppColors.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.text,
                  ),
                ),
              ),
              const Icon(
                Icons.arrow_drop_down,
                size: 18,
                color: AppColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openSubjectPicker() async {
    final subjects = controller.mistakeSubjects;
    final current = controller.selectedSubject.value;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                '按科目筛选',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            for (final subject in subjects)
              ListTile(
                dense: true,
                title: Text(
                  subject == '全部' ? '全部科目' : subject,
                  style: const TextStyle(fontSize: 13.5),
                ),
                trailing: subject == current
                    ? const Icon(
                        Icons.check,
                        size: 18,
                        color: AppColors.primary,
                      )
                    : null,
                onTap: () => Navigator.of(context).pop(subject),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null) controller.setSelectedSubject(picked);
  }

  Future<void> _openTermPicker() async {
    final options = controller.termOptions;
    final selected = <String>{
      if (!controller.termFilterAll.value) ...controller.selectedTermKeys,
    };
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '按学期筛选',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text(
                  '只列出题库里出现过的学期。未归档 = 升级前的历史错题。',
                  style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                ),
                // 「本学期」原来是一个常驻标签，现在收进选择器：
                // 它是这里最高频的一档，不能因为收起筛选而变得难选。
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      controller.showCurrentTerm();
                    },
                    icon: const Icon(Icons.today_outlined, size: 16),
                    label: const Text(
                      '只看本学期',
                      style: TextStyle(fontSize: 12.5),
                    ),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final option in options)
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: selected.contains(option.key),
                          title: Text(
                            '${option.label}（${option.count}）',
                            style: const TextStyle(fontSize: 13.5),
                          ),
                          onChanged: (checked) => setSheetState(() {
                            if (checked == true) {
                              selected.add(option.key);
                            } else {
                              selected.remove(option.key);
                            }
                          }),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(<String>{}),
                      child: const Text('清空（看全部）'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 6),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(selected),
                      child: const Text('应用'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result == null) return;
    controller.selectTermKeys(result);
  }

  /// 四段切换：`待复习 / 复习中 / 待批改 / 已掌握`。
  ///
  /// 做成**一个容器里的四个分段**，而不是四个各自带边框的方块 ——
  /// 后者在界面上是四个并列的按钮，看起来像四个动作；
  /// 而这里其实只有一个动作（换视图），选中态本来就该表现为「同一组的当前项」。
  ///
  /// 「复习资料」不再占一个分段位：它是**卷子**，不是错题状态。混在一起时
  /// 它既不参与筛选、计数口径也和旁边两段不同，一眼就看得出是异类。
  Widget _segments(Map<ReviewState, int> counts) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: List.generate(_segmentStates.length, (index) {
          final state = _segmentStates[index];
          final active = _segment == index;
          final color = active ? AppColors.primary : AppColors.textMuted;
          return Expanded(
            child: Material(
              color: active ? AppColors.card : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _segment = index),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 2,
                  ),
                  // 四段比三段窄，「待复习 105」这种长度会顶出去。
                  // 缩放比省略号好：数字是这一段唯一的信息，不能截掉。
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          state.label,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: active
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: color,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${counts[state] ?? 0}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: active
                                ? AppColors.primary
                                : AppColors.textMuted.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  // ===== 分段内容 =====

  /// 把某个状态下的题渲染成卡片。
  ///
  /// 三种卡不是三套数据，而是**同一个状态在闭环里的三个阶段**：
  /// 待复习可以编辑/自评掌握，复习中只能看（下一步在纸上），
  /// 已掌握是档案。所以这里按状态分派，而不是按「在哪个 tab」分派。
  List<Widget> _sectionFor(ReviewState state) {
    final items = controller.viewOf(state).toList();
    if (items.isEmpty) return [_emptyFor(state)];

    switch (state) {
      case ReviewState.pending:
        // 错得越多的题越靠前：让学生一眼看到「重点易错题」，而不是被新错题
        // 插队。同分时按入池时间，先错的先复习。
        items.sort((a, b) {
          final byWrong = b.wrongCount.compareTo(a.wrongCount);
          if (byWrong != 0) return byWrong;
          return a.createdAt.compareTo(b.createdAt);
        });
        return items
            .map(
              (mistake) => MistakeCard(
                mistake: mistake,
                onExplain: () =>
                    Get.to(() => MistakeDetailPage(mistakeId: mistake.id)),
                onPractice: () async {
                  final result = await controller.generatePractice(mistake.id);
                  Get.snackbar(result.ok ? '已出题' : '未能出题', result.message);
                  if (result.ok) {
                    Get.to(() => MistakeDetailPage(mistakeId: mistake.id));
                  }
                },
                onMarkMastered: () async {
                  final result = await controller.markMasteredBySelf(mistake.id);
                  Get.snackbar(result.ok ? '已标记' : '未标记', result.message);
                },
                onEdit: () async {
                  await Get.to(() => MistakeEditPage(mistakeId: mistake.id));
                  // 编辑可能改了知识点或科目，回来要刷新列表上的展示。
                  if (mounted) setState(() {});
                },
                onDelete: () async {
                  final result = await controller.removeMistake(mistake.id);
                  Get.snackbar(result.ok ? '已删除' : '未能删除', result.message);
                },
              ),
            )
            .toList();

      case ReviewState.reviewing:
      case ReviewState.verifying:
        // 新排进卷子的在前：这两个状态关心的是「最近那批卷子」。
        items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return items
            .map(
              (mistake) => _InFlightCard(
                mistake: mistake,
                // 以前这张卡**点不动** —— 题确实在「复习中」，但点它没有任何反应，
                // 用户不知道该去哪看这道题（实测反馈「卡不到想去」）。
                onTap: () =>
                    Get.to(() => MistakeDetailPage(mistakeId: mistake.id)),
              ),
            )
            .toList();

      case ReviewState.mastered:
        return items
            .map(
              (mistake) => _MasteredCard(
                mistake: mistake,
                onOpen: () =>
                    Get.to(() => MistakeDetailPage(mistakeId: mistake.id)),
              ),
            )
            .toList();
    }
  }

  /// 每个分段的空态**各说各的**。
  ///
  /// 四段共用一句「当前筛选下没有错题」的话，用户分不清是「这个阶段空了」
  /// 还是「整个错题本空了」—— 而这两种情况的下一步动作完全不同。
  Widget _emptyFor(ReviewState state) {
    final subject = controller.selectedSubject.value;
    final scope = subject == '全部' ? '' : '$subject ';
    final termHint = controller.termFilterAll.value
        ? null
        : '当前只看「${controller.termFilterLabel}」。切到「全部」可以看其它学期。';

    switch (state) {
      case ReviewState.pending:
        return _EmptyCard(
          icon: Icons.check_circle_outline,
          title: '$scope' '没有待复习的错题',
          hint:
              termHint ??
              (controller.openPapers.isNotEmpty
                  // 这条最关键：待复习空着，常常不是「没错题」，
                  // 而是题全被抽进卷子里了。不说破，用户会以为错题丢了。
                  ? '错题都排进复习资料了，去「复习中」看看那 '
                        '${controller.openPapers.length} 份卷子'
                  : '完成作业并提交检查后，错题会自动收集到这里'),
        );
      case ReviewState.reviewing:
        return _EmptyCard(
          icon: Icons.edit_note_outlined,
          title: '$scope' '没有正在复习的题',
          hint:
              termHint ??
              '点上面的「生成错题资料」，选好的题会排进卷子，出现在这里',
        );
      case ReviewState.verifying:
        return _EmptyCard(
          icon: Icons.hourglass_empty,
          title: '$scope' '没有等着批改的题',
          hint: termHint ?? '做完卷子后，在下方资料卡上点「回传批改」',
        );
      case ReviewState.mastered:
        return _EmptyCard(
          icon: Icons.emoji_events_outlined,
          title: '$scope' '还没有已掌握的错题',
          hint: termHint ?? '做对并通过检查的错题会移到这里，保留错因供回溯',
        );
    }
  }

  // ===== 资料 =====

  /// 资料区：**卷子不是错题状态**，所以它不占分段位，单独成块。
  ///
  /// 排在最下面而不是最上面：学生先看「我还有哪些题要复习」，再往下才是
  /// 「我已经生成了哪些卷子」。顺序反了，第一屏就成了「已有产物」，
  /// 而真正要动手的东西被推到下面。
  ///
  /// 数量按**当前科目**筛（学期这一维卷子没有，见 `visiblePapers` 的注释），
  /// 标题里把科目写出来 —— 数字和列表必须是一回事。
  List<Widget> _paperSection() {
    final papers = controller.visiblePapers;
    if (papers.isEmpty) {
      return const [
        _EmptyCard(
          icon: Icons.picture_as_pdf_outlined,
          title: '还没有生成过复习资料',
          hint: '在「待复习」里点「生成错题资料」，选好题就会生成可打印的重做卷',
        ),
      ];
    }

    final open = controller.openPapers;
    int countOf(PaperStatus status) =>
        open.where((paper) => paper.status == status).length;
    final parts = <String>[
      if (countOf(PaperStatus.draft) > 0)
        '待打印 ${countOf(PaperStatus.draft)}',
      if (countOf(PaperStatus.printed) > 0)
        '待完成 ${countOf(PaperStatus.printed)}',
      if (countOf(PaperStatus.submitted) > 0)
        '待批改 ${countOf(PaperStatus.submitted)}',
    ];
    final subject = controller.selectedSubject.value;

    return [
      _paperSectionHeader(
        papers.length,
        subject,
        parts.isEmpty ? '全部已批改' : parts.join(' · '),
      ),
      if (_papersOpen)
        ...papers.map(
          (paper) => _PaperCard(paper: paper, controller: controller),
        ),
    ];
  }

  Widget _paperSectionHeader(int count, String subject, String summary) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _papersOpen = !_papersOpen),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            child: Row(
              children: [
                const Icon(
                  Icons.folder_open_outlined,
                  size: 17,
                  color: AppColors.textMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '复习资料 $count 份'
                        '${subject == '全部' ? '' : '（$subject）'}',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        summary,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  _papersOpen ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: AppColors.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({
    required this.masteryRate,
    required this.busy,
    required this.onCompose,
    required this.onManualAdd,
    required this.onReport,
  });

  final double masteryRate;
  final bool busy;
  final VoidCallback onCompose;
  final VoidCallback onManualAdd;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 四个统计搬进分段了：它们本来就是「四个状态各有多少」，
          // 在分段里显示一次就够。原来在这里再放一遍，等于同一组数字
          // 出现两次，而且两处的过滤口径还不一样。
          Row(
            children: [
              const Text(
                '掌握率',
                style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: masteryRate,
                    minHeight: 6,
                    backgroundColor: AppColors.border,
                    valueColor: const AlwaysStoppedAnimation(
                      AppColors.success,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(masteryRate * 100).round()}%',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.success,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          const Text(
            '按当前筛选统计 · 自评「标记掌握」不计入',
            style: TextStyle(fontSize: 10.5, color: AppColors.textMuted),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: busy ? null : onCompose,
              icon: const Icon(Icons.auto_awesome_outlined),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 11),
              ),
              label: Text(busy ? '正在生成…' : '生成错题资料'),
            ),
          ),
          // 两个次要动作改成无边框的文字按钮：原来是两个描边按钮，
          // 和主按钮挤在一起时三者同权，看不出该先点哪个。
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: onManualAdd,
                  icon: const Icon(Icons.edit_note_outlined, size: 16),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  label: const Text(
                    '手工录入',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: onReport,
                  icon: const Icon(Icons.insights_outlined, size: 16),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  label: const Text(
                    '学习报告',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


class _InFlightCard extends StatelessWidget {
  const _InFlightCard({required this.mistake, required this.onTap});

  final ReviewMistake mistake;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = mistakeStateColor(mistake.state);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        mistake.title,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${mistake.knowledgePoint.isEmpty ? mistake.subject : mistake.knowledgePoint}'
                        ' · 已重做 ${mistake.reviewRound} 轮',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      // 「复习中」是个很容易卡住的状态：题从「待复习」里消失了，
                      // 但下一步不是在这里做，而是去做那张卷子。这句话就是为了
                      // 让人知道该去哪 —— 之前这里一个字都没有。
                      Text(
                        mistake.state == ReviewState.verifying
                            ? '已回传，等批改'
                            : '已排进重做卷，做完在下方「复习资料」里回传',
                        style: TextStyle(
                          fontSize: 11,
                          color: color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                MistakeStateBadge(state: mistake.state),
                const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: AppColors.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PaperCard extends StatelessWidget {
  const _PaperCard({required this.paper, required this.controller});

  final ReviewPaper paper;
  final ReviewController controller;

  @override
  Widget build(BuildContext context) {
    final summary = controller.summaryOfPaper(paper.id);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 卷名可点：进详情页看这份卷子印了哪些题。
          // 列表卡片只回答「有几份资料」，卷内快照必须单独一页才说得清。
          InkWell(
            onTap: () => Get.to(() => ReviewPaperPage(paperId: paper.id)),
            child: Row(
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
                const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: AppColors.textMuted,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${paper.itemCount} 道题'
            '${paper.knowledgePoints.isEmpty ? '' : ' · ${paper.knowledgePoints.join('、')}'}',
            style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
          ),
          if (paper.gradedAt != null)
            Text(
              '批改于 ${_formatDate(paper.gradedAt!)} · 通过 ${paper.passCount} / 未通过 ${paper.failCount}',
              style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
            ),
          if (summary != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                summary.body,
                style: const TextStyle(fontSize: 12.5, height: 1.5),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => openReviewExportSheet(
                    context: context,
                    controller: controller,
                    paperId: paper.id,
                  ),
                  icon: const Icon(Icons.ios_share_outlined, size: 16),
                  label: const Text(
                    '导出 / 转发',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    if (paper.status == PaperStatus.graded ||
                        paper.status == PaperStatus.closed) {
                      if (summary != null) {
                        Get.to(() => ReviewSummaryPage(paperId: paper.id));
                      } else {
                        Get.snackbar('暂无报告', '这份资料没有生成报告');
                      }
                      return;
                    }
                    Get.to(() => ReviewCheckPage(paperId: paper.id));
                  },
                  icon: Icon(
                    paper.status == PaperStatus.graded
                        ? Icons.summarize_outlined
                        : Icons.fact_check_outlined,
                    size: 16,
                  ),
                  label: Text(
                    paper.status == PaperStatus.graded ? '看报告' : '回传批改',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MasteredCard extends StatelessWidget {
  const _MasteredCard({required this.mistake, required this.onOpen});

  final ReviewMistake mistake;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onOpen,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.success.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.verified_outlined,
                  size: 16,
                  color: AppColors.success,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    mistake.title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  mistake.masteredBySelf ? '自评掌握' : '检查通过',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
            if (mistake.knowledgePoint.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 22),
                child: Text(
                  mistake.knowledgePoint,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({
    required this.icon,
    required this.title,
    required this.hint,
  });

  final IconData icon;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Icon(icon, size: 38, color: AppColors.textMuted),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
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
