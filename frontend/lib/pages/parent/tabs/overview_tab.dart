import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../constants/app_colors.dart';
import '../../../controllers/parent_controller.dart';
import '../../../models/homework_model.dart';
import '../../../models/workout_model.dart';
import '../../../utils/attachment_summary.dart';
import '../../../services/calendar_summary_service.dart';
import '../../../services/database_service.dart';
import '../../../widgets/day_calendar.dart';
import '../../../widgets/homework_status.dart';
import '../homework_detail_page.dart';
import '../widgets/child_selector.dart';

class OverviewTab extends StatefulWidget {
  const OverviewTab({super.key});

  @override
  State<OverviewTab> createState() => _OverviewTabState();

  static bool _isSameDay(DateTime first, DateTime second) {
    return first.year == second.year &&
        first.month == second.month &&
        first.day == second.day;
  }
}

class _OverviewTabState extends State<OverviewTab> {
  final Rx<DateTime> _selectedDate = DateTime.now().obs;

  /// 家长控制器。在 [initState] 里取一次 —— 摘要回调（翻月取数）
  /// 在 `build` 之外也要用它，所以不能是本文件别处那种 `build` 里的局部量。
  late final ParentController controller;

  /// 摘要服务（含按「学生 + 月」缓存）。**实例字段、只建一次**。
  late final CalendarSummaryService _summary;

  @override
  void initState() {
    super.initState();
    controller = Get.find<ParentController>();
    _summary = CalendarSummaryService(api: DatabaseService.cloud?.api);
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final today = DateTime.now();
      final selectedDate = _selectedDate.value;
      final homework = controller.visibleHomework
          .where((item) => OverviewTab._isSameDay(item.dueAt, selectedDate))
          .toList();
      final workoutPlans = controller.visibleWorkoutPlans
          .where((plan) => plan.appliesToDate(selectedDate))
          .toList();
      final workoutRecords = controller.visibleWorkoutRecords
          .where((r) => OverviewTab._isSameDay(r.start, selectedDate))
          .toList();

      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (controller.boundStudents.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Row(
                children: [
                  Icon(Icons.link_off, size: 18, color: AppColors.warning),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '尚未与任何学生结伴，结伴后即可查看孩子的作业信息',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          if (controller.boundStudents.length > 1) ...[
            ChildSelectorCard(
              students: controller.boundStudents.toList(),
              selectedId: controller.selectedStudentId.value,
              onSelect: (id) => controller.selectedStudentId.value = id,
            ),
            const SizedBox(height: 18),
          ],
          const _ObserveEntry(),
          const SizedBox(height: 18),
          if (controller.latestSubmittedHomework != null) ...[
            _LatestSubmissionCard(
              homework: controller.latestSubmittedHomework!,
              // 传「2 张照片 · 1 个视频」这样的摘要，不传行数：
              // 行数配「张照片」的量词，孩子交视频时会说成「1 张照片」。
              attachmentText: attachmentSummary(
                controller.imagesOfHomework(
                  controller.latestSubmittedHomework!.id,
                ),
              ),
              needFixCount: controller.needFixCount,
              todaySubmittedCount: controller.todaySubmittedCount,
              onTap: () => HomeworkDetailPage.open(
                controller.latestSubmittedHomework!.id,
              ),
            ),
            const SizedBox(height: 18),
          ],
          WeekStrip(
            selectedDate: selectedDate,
            today: today,
            onDateSelected: (date) => _selectedDate.value = date,
            onPickMonth: () => _openMonthPicker(selectedDate),
            // 家长端的小圆点算**两类**（作业 + 运动）：这一页是总览，
            // 「孩子这天有没有动静」比「有没有交作业」更贴合它要回答的问题。
            marks: _localMarksFor(selectedDate),
          ),
          const SizedBox(height: 18),
          _HomeworkProgressSection(
            homework: homework,
            selectedDate: selectedDate,
            today: today,
          ),
          const SizedBox(height: 18),
          _AiSummarySection(homework: homework),
          const SizedBox(height: 18),
          _WorkoutSection(
            plans: workoutPlans,
            records: workoutRecords,
            selectedDate: selectedDate,
            today: today,
          ),
        ],
      );
    });
  }

  /// 打开月历弹层（家长端查孩子历史的入口）。
  ///
  /// ⚠️ 家长端比学生端多一层：**要看的是「当前选中的那个孩子」的历史**。
  /// `controller.visibleHomework` 已经是按 `selectedStudentId` 收窄过的
  /// （多孩子切换的既有机制），所以这里选日期**不需要**额外传学生 ——
  /// 选中日期之后，`build` 里那三个 `.where(...)` 会自然按新日期重筛。
  ///
  /// ## 但**摘要**必须显式传 `studentId`（两个方向的错都在这里）
  ///
  /// 列表是按 `selectedStudentId` 收窄的，那是**本地已有数据**的筛法；
  /// 而摘要是**向服务端要**的数据，它不知道客户端「当前选的是哪个孩子」。
  /// 不传的话，服务端会按 token 推出的**全部**可见学生聚合，
  /// 于是日历上的小圆点是「两个孩子合起来」的 —— 切换孩子之后点不变，
  /// 而它**看起来是有效信息**（比没有点更坏）。
  ///
  /// 反过来，`studentId` 也**只能收窄**：服务端会用 `requireVisibleStudent`
  /// 挡住不在可见集合里的 id（403），所以这里传当前选中的那个是安全的。
  Future<void> _openMonthPicker(DateTime selectedDate) async {
    final picked = await MonthPickerLauncher.open(
      context,
      selectedDate: selectedDate,
      fetchSummary: (month) => _summary.summaryFor(
        month,
        studentId: controller.selectedStudentId.value,
      ),
      localMarks: _localMarksFor(selectedDate),
    );
    if (picked == null) return;
    if (!mounted) return;
    _selectedDate.value = picked;
  }

  /// 本地先算的打点（家长端：作业 + 运动都算上）。
  ///
  /// 家长看的是「孩子这一天的整体情况」，所以两类都点 —— 与学生端那两个页面
  /// 「只点本页主题」是**刻意不同**的：那两页各自是一件事，家长端是总览。
  Map<String, DayMarks> _localMarksFor(DateTime month) {
    final key = DayUtil.monthKey(month);
    final homework = controller.visibleHomework
        .where((h) => DayUtil.monthKey(h.dueAt) == key);
    final records = controller.visibleWorkoutRecords
        .where((r) => DayUtil.monthKey(r.start) == key);
    if (homework.isEmpty && records.isEmpty) return const {};
    return LocalDayMarks.build(
      homework: homework,
      workoutRecords: records,
      // 家长端拿不到打卡列表（那是学生端的模型 + 端点的可见性口径不同），
      // 所以打卡点只可能来自**服务端摘要**。这是刻意的缺口，
      // 而不是「忘了传」—— 摘要回来之后打卡点就齐了。
      checkins: const [],
    );
  }
}

// ─── 最近一次提交 ───────────────────────────────────────────────────
/// 家长打开首页第一眼要看到的东西：孩子最近一次交了什么、什么时候交的。
class _LatestSubmissionCard extends StatelessWidget {
  const _LatestSubmissionCard({
    required this.homework,
    required this.attachmentText,
    required this.needFixCount,
    required this.todaySubmittedCount,
    required this.onTap,
  });

  final HomeworkItem homework;

  /// 附件摘要（「2 张照片 · 1 个视频」），空串表示没有附件。
  final String attachmentText;
  final int needFixCount;
  final int todaySubmittedCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasMistakes = homework.wrongCount > 0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF6C8FE8), AppColors.primary],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.assignment_turned_in_outlined,
                    size: 18,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '最近一次提交',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '今天已交 $todaySubmittedCount 份',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                homework.title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${_formatDateTime(homework.submittedAt!)} 提交'
                '${attachmentText.isEmpty ? ' · 未上传附件' : ' · $attachmentText'}',
                style: TextStyle(
                  fontSize: 12.5,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
              if (homework.score != null) ...[
                const SizedBox(height: 6),
                Text(
                  hasMistakes
                      ? 'AI 得分 ${homework.score} · 错题 ${homework.wrongCount} 道'
                      : 'AI 得分 ${homework.score} · 全部正确',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withValues(alpha: 0.95),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      needFixCount > 0
                          ? '还有 $needFixCount 份作业等待孩子更正'
                          : '孩子没有待更正的作业',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right,
                    color: Colors.white,
                    size: 20,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── 作业完成情况 ───────────────────────────────────────────────────
class _HomeworkProgressSection extends StatelessWidget {
  final List<HomeworkItem> homework;
  final DateTime selectedDate;
  final DateTime today;

  const _HomeworkProgressSection({
    required this.homework,
    required this.selectedDate,
    required this.today,
  });

  void _showHomeworkDetail(BuildContext context, HomeworkItem item) {
    HomeworkDetailPage.open(item.id);
  }

  @override
  Widget build(BuildContext context) {
    final total = homework.length;
    final finished = homework
        .where((h) => h.status == HomeworkStatus.finished)
        .length;
    final needFix = homework
        .where((h) => h.status == HomeworkStatus.needFix)
        .length;
    final pending = homework
        .where((h) => h.status == HomeworkStatus.pending)
        .length;
    final checking = homework
        .where((h) => h.status == HomeworkStatus.checking)
        .length;
    // 这里原来还有一档「已超时」，已随 `HomeworkStatus.timeout` 一起删掉
    // （2026-09-28）：那个状态表达的是「还没做」，不是「没按时做」。
    // 家长要看的是「交了没有 / 什么时候交的」—— 列表每行都写着。见 B26。
    //
    // 「已提交」与状态分布不是互斥关系（已提交的作业可能同时是待更正），
    // 所以单独用一行展示，不混进状态分段的堆叠条里，避免数字对不上。
    final submittedCount = homework.where((h) => h.hasSubmission).length;

    final isToday = OverviewTab._isSameDay(selectedDate, today);

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
          Text(
            isToday
                ? '今日作业完成情况'
                : '${selectedDate.month}月${selectedDate.day}日作业情况',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          if (total > 0) ...[
            const SizedBox(height: 6),
            Text(
              '孩子已提交 $submittedCount / $total 份',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: submittedCount == 0
                    ? AppColors.warning
                    : AppColors.success,
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (total == 0)
            const _EmptyHint(icon: Icons.task_alt, text: '当天暂无作业记录')
          else ...[
            // 进度条
            _ProgressBar(
              total: total,
              segments: [
                _Segment(finished, AppColors.success, '完成'),
                _Segment(needFix, AppColors.danger, '待更正'),
                _Segment(checking, AppColors.accent, '批改中'),
                _Segment(pending, AppColors.warning, '待完成'),
              ],
            ),
            const SizedBox(height: 14),
            // 数字统计
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                _StatChip('已完成', finished, AppColors.success),
                _StatChip('待更正', needFix, AppColors.danger),
                _StatChip('批改中', checking, AppColors.accent),
                _StatChip('待完成', pending, AppColors.warning),
                _StatChip('合计', total, AppColors.text),
              ],
            ),
            const SizedBox(height: 14),
            // 作业列表
            ...homework.map(
              (item) => _HomeworkRow(
                item: item,
                attachmentText: attachmentSummary(
                  Get.find<ParentController>().imagesOfHomework(item.id),
                ),
                onTap: () => _showHomeworkDetail(context, item),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final int total;
  final List<_Segment> segments;

  const _ProgressBar({required this.total, required this.segments});

  @override
  Widget build(BuildContext context) {
    if (total == 0) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 12,
        child: Row(
          children: segments.where((s) => s.count > 0).map((s) {
            final flex = (s.count / total * 100).round();
            return Expanded(
              flex: flex > 0 ? flex : 1,
              child: Container(color: s.color),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _Segment {
  final int count;
  final Color color;
  final String label;
  _Segment(this.count, this.color, this.label);
}

class _StatChip extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _StatChip(this.label, this.count, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            '$label $count',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeworkRow extends StatelessWidget {
  final HomeworkItem item;

  /// 附件摘要（「2 张照片 · 1 个视频」），空串表示没有附件。
  final String attachmentText;
  final VoidCallback? onTap;

  const _HomeworkRow({
    required this.item,
    required this.attachmentText,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // 家长最关心的是「交了没有」，所以提交时间优先于预计耗时展示。
    final subtitle = item.hasSubmission
        ? '${item.subject.isEmpty ? '未填科目' : item.subject} · '
              '${_formatDateTime(item.submittedAt!)}提交'
              '${attachmentText.isEmpty ? '' : ' · $attachmentText'}'
        : '${item.subject.isEmpty ? '未填科目' : item.subject} · 尚未提交';

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            if (attachmentText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(
                  Icons.attach_file,
                  size: 16,
                  color: AppColors.success,
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: item.hasSubmission
                          ? AppColors.success
                          : AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            if (item.wrongCount > 0)
              Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '错${item.wrongCount}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.danger,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            HomeworkStatusChip(status: item.status, dense: true),
            if (onTap != null) ...[
              const SizedBox(width: 6),
              const Icon(
                Icons.chevron_right,
                size: 18,
                color: AppColors.textMuted,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${local.month}月${local.day}日 ${two(local.hour)}:${two(local.minute)}';
}

// ─── AI 总结区 ──────────────────────────────────────────────────────
class _AiSummarySection extends StatelessWidget {
  final List<HomeworkItem> homework;

  const _AiSummarySection({required this.homework});

  @override
  Widget build(BuildContext context) {
    final summary = _generateSummary(homework);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF6C8FE8), AppColors.primary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, size: 20, color: Colors.white),
              const SizedBox(width: 8),
              const Text(
                'AI 批改总结',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  'AI',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            summary,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.white,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  String _generateSummary(List<HomeworkItem> homework) {
    if (homework.isEmpty) return '当天暂无作业数据，无法生成总结。';

    final total = homework.length;
    final finished = homework
        .where((h) => h.status == HomeworkStatus.finished)
        .length;
    final needFix = homework
        .where((h) => h.status == HomeworkStatus.needFix)
        .length;
    final pending = homework
        .where((h) => h.status == HomeworkStatus.pending)
        .length;
    final notSubmitted = homework.where((h) => !h.hasSubmission).length;
    final totalWrong = homework.fold(0, (sum, h) => sum + h.wrongCount);
    final totalEstimated = homework.fold(
      0.0,
      (sum, h) => sum + h.estimatedMinutes,
    );

    final subjects = homework.map((h) => h.subject).toSet().join('、');

    final buffer = StringBuffer();
    buffer.write('今日共 $total 项作业（$subjects），');
    buffer.write('孩子已提交 ${total - notSubmitted} 项');
    if (finished == total) {
      buffer.write('，全部完成，表现优秀！');
    } else {
      buffer.write('，已完成 $finished 项');
      if (needFix > 0) buffer.write('，待更正 $needFix 项');
      if (pending > 0) buffer.write('，待完成 $pending 项');
      buffer.write('。');
    }

    if (totalWrong > 0) {
      buffer.write(' 共产生 $totalWrong 个错题，建议针对薄弱科目加强复习。');
    } else if (finished > 0) {
      buffer.write(' 作业正确率很高，继续保持！');
    }

    if (totalEstimated > 0) {
      buffer.write(' 预计总耗时 ${totalEstimated.toInt()} 分钟。');
    }

    return buffer.toString();
  }
}

// ─── 运动情况 ──────────────────────────────────────────────────────
class _WorkoutSection extends StatelessWidget {
  final List<WorkoutPlan> plans;
  final List<WorkoutRecord> records;
  final DateTime selectedDate;
  final DateTime today;

  const _WorkoutSection({
    required this.plans,
    required this.records,
    required this.selectedDate,
    required this.today,
  });

  @override
  Widget build(BuildContext context) {
    final isToday = OverviewTab._isSameDay(selectedDate, today);
    final completedPlanIds = <String>{};
    for (final r in records) {
      if (r.planId.isNotEmpty) completedPlanIds.add(r.planId);
    }

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
          Row(
            children: [
              const Icon(
                Icons.sports_basketball,
                size: 20,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Text(
                isToday
                    ? '今日运动情况'
                    : '${selectedDate.month}月${selectedDate.day}日运动情况',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (plans.isEmpty && records.isEmpty)
            const _EmptyHint(icon: Icons.sports, text: '当天暂无运动计划和记录')
          else ...[
            // 统计条
            if (plans.isNotEmpty)
              _WorkoutStatBar(
                total: plans.length,
                completed: plans
                    .where((p) => completedPlanIds.contains(p.id))
                    .length,
              ),
            const SizedBox(height: 12),
            // 计划列表
            ...plans.map((plan) {
              final record = records.where((r) => r.planId == plan.id).toList();
              final isDone = record.isNotEmpty;
              return _WorkoutPlanRow(
                plan: plan,
                isDone: isDone,
                record: record.isNotEmpty ? record.first : null,
              );
            }),
            // 无计划但有记录的运动
            ...records
                .where((r) => r.planId.isEmpty)
                .map((r) => _WorkoutRecordRow(record: r)),
          ],
        ],
      ),
    );
  }
}

class _WorkoutStatBar extends StatelessWidget {
  final int total;
  final int completed;

  const _WorkoutStatBar({required this.total, required this.completed});

  @override
  Widget build(BuildContext context) {
    final rate = total > 0 ? completed / total : 0.0;
    return Row(
      children: [
        Text(
          '完成 $completed/$total',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 8,
              child: LinearProgressIndicator(
                value: rate,
                backgroundColor: AppColors.border,
                valueColor: const AlwaysStoppedAnimation(AppColors.success),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          '${(rate * 100).toInt()}%',
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: AppColors.success,
          ),
        ),
      ],
    );
  }
}

class _WorkoutPlanRow extends StatelessWidget {
  final WorkoutPlan plan;
  final bool isDone;
  final WorkoutRecord? record;

  const _WorkoutPlanRow({
    required this.plan,
    required this.isDone,
    this.record,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDone
            ? AppColors.success.withValues(alpha: 0.06)
            : AppColors.background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            isDone ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 20,
            color: isDone ? AppColors.success : AppColors.textMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plan.title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  '${plan.project} · ${plan.startTime}-${plan.endTime} · 目标${plan.targetMinutes}分钟',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
                if (record != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '实际${record!.minutes}分钟 · ${record!.feedback}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.success,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: (isDone ? AppColors.success : AppColors.warning)
                  .withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              isDone ? '已完成' : '未完成',
              style: TextStyle(
                color: isDone ? AppColors.success : AppColors.warning,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkoutRecordRow extends StatelessWidget {
  final WorkoutRecord record;

  const _WorkoutRecordRow({required this.record});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle, size: 20, color: AppColors.success),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.project,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  '${record.minutes}分钟 · ${record.feedback}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 「运行观察」入口。
///
/// 放在概览页而不是 AppBar：那里已经挂了 5 个图标，再加一个只会让它们
/// 都变得不好找 —— 而这一项是**低频的诊断入口**，不该和消息、绑定这些
/// 高频动作抢位置。
class _ObserveEntry extends StatelessWidget {
  const _ObserveEntry();

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Get.toNamed('/ai-observe'),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: const Row(
          children: [
            Icon(Icons.monitor_heart_outlined, size: 18, color: AppColors.primary),
            SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '运行观察',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  SizedBox(height: 2),
                  Text(
                    '云端用量与成本、判定一致率、降级记录',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}

// ─── 通用空状态 ─────────────────────────────────────────────────────
class _EmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;

  const _EmptyHint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Column(
          children: [
            Icon(icon, size: 36, color: AppColors.textMuted),
            const SizedBox(height: 10),
            Text(text, style: const TextStyle(color: AppColors.textMuted)),
          ],
        ),
      ),
    );
  }
}
