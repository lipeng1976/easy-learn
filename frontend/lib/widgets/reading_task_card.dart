import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../constants/app_colors.dart';
import '../controllers/reading_controller.dart';
import '../models/reading_models.dart';
import '../services/database_service.dart';

/// 阅读任务的入口卡片（学生端 / 家长端各一处，都在**计划标签页**）。
///
/// ## 为什么和「每日概念打卡」并列，而不是合成一张「今日任务」
///
/// 两者语义差得远：概念打卡是**按天**出的一份短题，做完就没了；阅读是
/// **一本书的长期任务**，断更三天再回来还是那一份。合成一张卡之后，
/// 「今天还有几件事没做」这个数字会一半按天算、一半按书算 ——
/// 那是用户最先发现、但最难解释的一类错误。
///
/// ## 三态必须分开写
///
///   ① 有进行中的任务 → 浅绿底 + 进度条 + 「读第 N 篇」；
///   ② 任务读完了（书读完了，等家长布置下一本）→ 白卡 + 「已读完」；
///   ③ 一本书都没有 → 家长看到「布置阅读任务」，学生看到「还没布置」。
///
/// ② 和 ③ 都是「现在没东西读」，但含义完全相反：一个是刚完成任务，
/// 一个是从来没开始过。写成同一句「暂无阅读任务」会让读完的孩子以为
/// 自己的成绩没了。
class ReadingTaskCard extends StatefulWidget {
  const ReadingTaskCard({super.key, this.isParent = false});

  final bool isParent;

  @override
  State<ReadingTaskCard> createState() => _ReadingTaskCardState();
}

class _ReadingTaskCardState extends State<ReadingTaskCard> {
  late final ReadingController controller;

  @override
  void initState() {
    super.initState();
    controller = Get.isRegistered<ReadingController>()
        ? Get.find<ReadingController>()
        : Get.put(ReadingController());
    // 跨天 / 别处改了数据，回到计划页要重查一次。失败不挡入口
    // （`load` 内部只写 error，不抛）。
    controller.load();
    // 「今天读了没有」只能查 `reading_log`，任务进度里没有日期。
    // 少了这一句，孩子打完卡回来卡上仍写着「今天还没读」。
    controller.loadTodayLogs();
  }

  @override
  Widget build(BuildContext context) {
    if (!DatabaseService.isCloud) return const SizedBox.shrink();

    return Obx(() {
      // ⚠️ 先整体订阅再取值：不订阅的话，打卡成功后卡片不会刷新
      // （计划页 tab 常驻，不会因为返回而重建）。
      // ignore: invalid_use_of_protected_member —— 在 Obx 闭包里读 RxList.value 是 GetX 标准写法。
      final list = controller.tasks.value;
      // ignore: invalid_use_of_protected_member
      final todayLogs = controller.todayLogs.value;
      ReadingTask? active;
      ReadingTask? finished;
      for (final task in list) {
        if (task.isActive && active == null) active = task;
        if (task.finished && finished == null) finished = task;
      }

      final title = widget.isParent ? '英文阅读' : '阅读打卡';
      final highlight = active != null;
      final accent = highlight ? AppColors.success : AppColors.textMuted;

      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        color: highlight
            ? Color.alphaBlend(AppColors.success.withValues(alpha: 0.14), AppColors.card)
            : AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: highlight
              ? BorderSide(color: AppColors.success.withValues(alpha: 0.45))
              : const BorderSide(color: AppColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_stories_outlined, size: 20, color: accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                    ),
                  ),
                  _StatusPill(active: active, finished: finished),
                ],
              ),
              const SizedBox(height: 8),
              if (active != null) ...[
                Text(
                  '《${active.bookTitle}》',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          // 总篇数为 0 时 progress 返回 0（不是 NaN —— 那会让
                          // 进度条直接抛异常，而整张卡消失得莫名其妙）。
                          value: active.progress,
                          minHeight: 6,
                          backgroundColor: AppColors.border,
                          valueColor: const AlwaysStoppedAnimation(AppColors.success),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${active.doneLessons}/${active.totalLessons} 篇',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _TodayLogRow(logs: todayLogs, loading: controller.todayLogsLoading.value),
                const SizedBox(height: 4),
                Text(
                  widget.isParent
                      ? '孩子每读一篇打卡一次，读到最后一篇这份任务就结束，'
                          '到时再安排下一本。'
                      : '每天一篇，没读完明天接着读，读完整本书才算完成。',
                  style: const TextStyle(color: AppColors.textMuted, height: 1.5, fontSize: 13),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonal(
                    onPressed: () => Get.toNamed(
                      widget.isParent ? '/reading-setup' : '/reading',
                      arguments: active!.id,
                    ),
                    child: Text(
                      widget.isParent
                          ? '查看任务'
                          : '读第 ${active.nextLessonNo ?? active.totalLessons} 篇',
                    ),
                  ),
                ),
              ] else if (finished != null) ...[
                Text(
                  '《${finished.bookTitle}》已读完，共 ${finished.totalLessons} 篇。',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.isParent
                      ? '可以再安排下一本书了。'
                      : '等家长安排下一本书。',
                  style: const TextStyle(color: AppColors.textMuted, height: 1.5, fontSize: 13),
                ),
                // 读完不等于没记录：这恰恰是「看不到打卡记录」最常被发现的时候。
                _TodayLogRow(logs: todayLogs, loading: controller.todayLogsLoading.value),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonal(
                    onPressed: () => Get.toNamed(
                      widget.isParent ? '/reading-setup' : '/reading',
                      arguments: finished!.id,
                    ),
                    child: Text(widget.isParent ? '再安排一本书' : '看看读过的书'),
                  ),
                ),
              ] else ...[
                Text(
                  widget.isParent
                      ? '从 ima 知识库的「教学资料/English」里选一本书，孩子每天读一篇，'
                          '读完整本任务就结束。'
                      : '家长还没给你布置阅读任务。',
                  style: const TextStyle(color: AppColors.textMuted, height: 1.5),
                ),
                // 没有进行中的任务、但今天确实读过（任务刚被家长取消），
                // 或者历史上布置过任务（取消的记录还在）：记录要能点开，
                // 否则那些卡就再也找不到了。
                if (todayLogs.isNotEmpty || list.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  _TodayLogRow(logs: todayLogs, loading: controller.todayLogsLoading.value),
                ],
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: widget.isParent
                      ? FilledButton.tonal(
                          onPressed: () => Get.toNamed('/reading-setup'),
                          child: const Text('布置阅读任务'),
                        )
                      // 学生端不放按钮：布置是家长的动作，放一个灰按钮只会
                      // 让孩子点进去看到「只有家长可以布置」。
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      );
    });
  }
}

/// 「今天读了什么」+ 进入全部记录的入口。
///
/// 这一行是**学生与家长两边最需要的东西**：进度条只说「读到第几篇」，
/// 而「今天打卡了没有」只能来自 `reading_log`。没有它，孩子打完卡回到
/// 计划页看到的东西和打卡前一模一样（只是数字 +1），家长那边更是完全
/// 看不出今天读没读。
class _TodayLogRow extends StatelessWidget {
  const _TodayLogRow({required this.logs, required this.loading});

  /// 今天的记录，**最新的在前**（服务端按 read_at 倒序）。
  final List<ReadingLogEntry> logs;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final hasLogs = logs.isNotEmpty;
    final header = hasLogs
        ? '今天已读 ${logs.length} 篇'
        : (loading ? '正在读取今天的打卡…' : '今天还没打卡');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              hasLogs ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 15,
              color: hasLogs ? AppColors.success : AppColors.textMuted,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                header,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: hasLogs ? FontWeight.w700 : FontWeight.w400,
                  color: hasLogs ? AppColors.text : AppColors.textMuted,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Get.toNamed('/reading-logs'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('全部记录', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        // 只给一个数字，家长还得点进记录页才知道「读的是哪一篇」。
        // 今天最多几条，直接摊在这里；超过 3 条折叠成一句。
        if (hasLogs)
          for (final entry in logs.take(3))
            Padding(
              padding: const EdgeInsets.only(left: 21, bottom: 2),
              child: Row(
                children: [
                  Text(
                    '第 ${entry.lessonNo} 篇',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      entry.displayTitle.isEmpty ? '（标题不可用）' : entry.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                    ),
                  ),
                  if (entry.readAt != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      '${entry.readAt!.hour.toString().padLeft(2, '0')}:'
                      '${entry.readAt!.minute.toString().padLeft(2, '0')}',
                      style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                    ),
                  ],
                ],
              ),
            ),
        if (logs.length > 3)
          Padding(
            padding: const EdgeInsets.only(left: 21),
            child: Text(
              '今天还有 ${logs.length - 3} 篇，见「全部记录」',
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
          ),
      ],
    );
  }
}

/// 状态小标：`待读 12 篇` / `已读完` / `未布置`。
class _StatusPill extends StatelessWidget {
  const _StatusPill({this.active, this.finished});

  final ReadingTask? active;
  final ReadingTask? finished;

  @override
  Widget build(BuildContext context) {
    final String label;
    if (active != null) {
      label = '还剩 ${active!.totalLessons - active!.doneLessons} 篇';
    } else if (finished != null) {
      label = '已读完';
    } else {
      label = '未布置';
    }
    final color = active != null ? AppColors.success : AppColors.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color),
      ),
    );
  }
}
