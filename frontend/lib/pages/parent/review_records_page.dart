import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/parent_controller.dart';
import '../../models/homework_model.dart';
import '../../models/review_model.dart';
import '../../utils/attachment_summary.dart';
import '../../widgets/review_components.dart';
import 'homework_detail_page.dart';

/// 「资料与记录」独立页：复习资料 / 作业提交记录。
///
/// 为什么从复习页搬出来：这两份都是**历史清单**，不是家长打开复习页时
/// 要看的结论。原来它们各占一段长列表，把真正该看的学科色块顶出了首屏。
/// 搬到这里之后，复习页只留两行入口，数量一眼可见。
class ReviewRecordsPage extends StatelessWidget {
  const ReviewRecordsPage({super.key, this.initialTab = 0});

  /// 0 = 复习资料，1 = 作业提交记录。越界值按 0 处理（不抛）。
  final int initialTab;

  static Future<void> open(BuildContext context, {int initialTab = 0}) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ReviewRecordsPage(initialTab: initialTab),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ParentController>();

    return Obx(() {
      final papers = controller.visibleReviewPapers;
      final submitted = controller.submittedHomeworks;
      final index = initialTab == 1 ? 1 : 0;

      return DefaultTabController(
        length: 2,
        initialIndex: index,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('资料与记录'),
            bottom: TabBar(
              tabs: [
                Tab(text: '复习资料 ${papers.length}'),
                Tab(text: '作业提交 ${submitted.length}'),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              _papers(papers),
              _submissions(controller, submitted),
            ],
          ),
        ),
      );
    });
  }

  Widget _papers(List<ReviewPaper> papers) {
    if (papers.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          ReviewEmptyHint(
            icon: Icons.description_outlined,
            text: '孩子还没有生成过复习资料。生成并做完后，这里会留下批改结果。',
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final paper in papers) ReviewPaperCard(paper: paper),
      ],
    );
  }

  Widget _submissions(
    ParentController controller,
    List<HomeworkItem> submitted,
  ) {
    if (submitted.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          ReviewEmptyHint(
            icon: Icons.inbox_outlined,
            text: '孩子还没有提交过作业。提交后会在这里看到提交时间与附件。',
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final item in submitted)
          ReviewSubmissionCard(
            item: item,
            attachmentText: attachmentSummary(
              controller.imagesOfHomework(item.id),
            ),
            mistakeCount: controller.mistakesOfHomework(item.id).length,
            onTap: () => HomeworkDetailPage.open(item.id),
          ),
      ],
    );
  }
}
