import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/review_controller.dart';
import '../../models/review_model.dart';
import '../../services/local_seed_service.dart';
import 'mistake_detail_page.dart';
import 'mistake_edit_page.dart';
import 'widgets/mistake_card.dart';

/// 本页的数据入口。
///
/// 生产就是仓储那条查询；判据把它换成一个假函数，好在**不碰真实数据库**的
/// 前提下走完「点按钮 → 打开页面 → 渲染卡片」整条链。
///
/// ⚠️ 为什么要在页面这一层留口子、而不是让判据去造一个库：
/// `testWidgets` 跑在假时钟里，sqflite 的 I/O 由真实定时器驱动 ——
/// 在假时钟里 await 它**不会失败，只会永远等下去**（表现为测试挂住）。
///
/// ⚠️ 它是全局可变量，判据用完必须还原（`tearDown` 里恢复旧值）。
@visibleForTesting
Future<List<ReviewMistake>> Function(String homeworkId) homeworkMistakesLoader =
    LocalSeedService.mistakesByHomework;

/// 「这次作业错在哪」——批改结果页点「错题 N 道」进来的页面。
///
/// 之前这个入口是死的：`queryReviewMistakesByHomeworkId` 从模型到服务端到
/// 客户端仓储全都实现了，但没有任何界面调它，批改结果上的「错题 N 道」
/// 是一段纯文字。学生看到「错了 3 道」之后必须自己去复习页翻，
/// 而复习页混着历次作业的错题。
///
/// ⚠️ 数据**按作业现查**，不从 `ReviewController.mistakes` 里过滤。
/// 批改刚结束那一刻内存里那份列表可能还没刷新，过滤会得到「没有错题」——
/// 那对一个明知自己错了三道题的学生来说是**最坏的一种错**。
class HomeworkMistakesPage extends StatefulWidget {
  const HomeworkMistakesPage({
    super.key,
    required this.homeworkId,
    required this.homeworkTitle,
  });

  final String homeworkId;
  final String homeworkTitle;

  @override
  State<HomeworkMistakesPage> createState() => _HomeworkMistakesPageState();
}

class _HomeworkMistakesPageState extends State<HomeworkMistakesPage> {
  final ReviewController controller = Get.find<ReviewController>();
  late Future<List<ReviewMistake>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<ReviewMistake>> _load() {
    if (widget.homeworkId.isEmpty) return Future.value(const []);
    return homeworkMistakesLoader(widget.homeworkId);
  }

  void _reload() {
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('本次作业的错题'),
        backgroundColor: AppColors.card,
        surfaceTintColor: Colors.transparent,
      ),
      body: FutureBuilder<List<ReviewMistake>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            // 不吞异常：读不出来就是读不出来，给一条能重试的路，
            // 而不是显示「没有错题」（那是把故障伪装成正常结果）。
            return _StateCard(
              icon: Icons.cloud_off_outlined,
              title: '错题没能读出来',
              hint: '${snapshot.error}',
              action: TextButton(
                onPressed: _reload,
                child: const Text('重试'),
              ),
            );
          }

          final mistakes = snapshot.data ?? const <ReviewMistake>[];
          if (mistakes.isEmpty) {
            return const _StateCard(
              icon: Icons.check_circle_outline,
              title: '这次作业没有错题',
              hint: '如果界面上显示错过了题，请下拉重试或回到作业页重新检查',
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              Text(
                widget.homeworkTitle.isEmpty
                    ? '共 ${mistakes.length} 道错题'
                    : '《${widget.homeworkTitle}》· 共 ${mistakes.length} 道错题',
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(height: 10),
              ...mistakes.map(
                (mistake) => MistakeCard(
                  mistake: mistake,
                  onExplain: () =>
                      Get.to(() => MistakeDetailPage(mistakeId: mistake.id)),
                  onPractice: () async {
                    final result = await controller.generatePractice(
                      mistake.id,
                    );
                    Get.snackbar(result.ok ? '已出题' : '未能出题', result.message);
                    if (result.ok) {
                      Get.to(() => MistakeDetailPage(mistakeId: mistake.id));
                    }
                  },
                  onMarkMastered: () async {
                    final result = await controller.markMasteredBySelf(
                      mistake.id,
                    );
                    Get.snackbar(result.ok ? '已标记' : '未标记', result.message);
                    if (result.ok) _reload();
                  },
                  onEdit: () async {
                    await Get.to(() => MistakeEditPage(mistakeId: mistake.id));
                    if (mounted) _reload();
                  },
                  onDelete: () async {
                    final result = await controller.removeMistake(mistake.id);
                    Get.snackbar(result.ok ? '已删除' : '未能删除', result.message);
                    if (result.ok) _reload();
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.icon,
    required this.title,
    required this.hint,
    this.action,
  });

  final IconData icon;
  final String title;
  final String hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.textMuted),
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
            if (action != null) ...[const SizedBox(height: 8), action!],
          ],
        ),
      ),
    );
  }
}
