import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../constants/app_colors.dart';
import '../../../controllers/parent_controller.dart';
import '../../../models/plan_archive.dart';
import '../../../models/study_plan_model.dart';
import '../../../models/workout_model.dart';
import '../../../widgets/plan_card.dart';
import '../../../widgets/reading_task_card.dart';
import '../../../widgets/subject_board.dart';
import '../../shared/study_plan_execution.dart';
import '../plans_archive_page.dart';

class PlansTab extends StatefulWidget {
  const PlansTab({super.key});

  @override
  State<PlansTab> createState() => _PlansTabState();
}

class _PlansTabState extends State<PlansTab> {
  final _planFormKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _projectController = TextEditingController();
  final _minutesController = TextEditingController(text: '30');
  final List<String> _weekdays = ['一', '三', '五'];
  static const _allWeekdays = ['一', '二', '三', '四', '五', '六', '日'];

  // 学习计划表单
  final _studyPlanFormKey = GlobalKey<FormState>();
  final _planTitleCtrl = TextEditingController();
  final _planContentCtrl = TextEditingController();
  final _planTypeCtrl = TextEditingController(text: '综合');
  DateTime _planStart = DateTime.now();
  DateTime _planEnd = DateTime.now().add(const Duration(days: 7));
  WorkoutCycleType _studyCycleType = WorkoutCycleType.daily;
  final List<String> _studyWeekdays = ['一', '三', '五'];

  DateTime? _startDate;
  DateTime? _endDate;
  TimeOfDay _startTime = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _endTime = const TimeOfDay(hour: 9, minute: 0);
  WorkoutCycleType _cycleType = WorkoutCycleType.weekly;

  @override
  void dispose() {
    _titleController.dispose();
    _projectController.dispose();
    _minutesController.dispose();
    _planTitleCtrl.dispose();
    _planContentCtrl.dispose();
    _planTypeCtrl.dispose();
    super.dispose();
  }

  String _formatTime(TimeOfDay time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Future<void> _pickDate(BuildContext context, bool isStart) async {
    final initial = isStart
        ? (_startDate ?? DateTime.now())
        : (_endDate ?? DateTime.now());
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (date == null) return;
    setState(() {
      if (isStart) {
        _startDate = date;
        if (_endDate != null && _endDate!.isBefore(date)) {
          _endDate = date;
        }
      } else {
        _endDate = date;
        if (_startDate != null && _startDate!.isAfter(date)) {
          _startDate = date;
        }
      }
    });
  }

  Future<void> _pickTime(BuildContext context, bool isStart) async {
    final initial = isStart ? _startTime : _endTime;
    final time = await showTimePicker(context: context, initialTime: initial);
    if (time == null) return;
    setState(() {
      if (isStart) {
        _startTime = time;
        if (_endTime.hour < time.hour ||
            (_endTime.hour == time.hour && _endTime.minute <= time.minute)) {
          _endTime = TimeOfDay(hour: (time.hour + 1) % 24, minute: time.minute);
        }
      } else {
        _endTime = time;
      }
    });
  }

  void _resetForm() {
    _titleController.clear();
    _projectController.clear();
    _minutesController.text = '30';
    _weekdays
      ..clear()
      ..addAll(['一', '三', '五']);
    _startDate = null;
    _endDate = null;
    _startTime = const TimeOfDay(hour: 8, minute: 0);
    _endTime = const TimeOfDay(hour: 9, minute: 0);
    _cycleType = WorkoutCycleType.weekly;
  }

  void _showAddWorkoutPlanDialog() {
    final controller = Get.find<ParentController>();
    setState(_resetForm);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('新建运动计划'),
          content: Form(
            key: _planFormKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: _titleController,
                    decoration: const InputDecoration(labelText: '计划标题'),
                    validator: (value) =>
                        (value == null || value.trim().isEmpty)
                        ? '请输入计划标题'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _projectController,
                    decoration: const InputDecoration(labelText: '运动项目'),
                    validator: (value) =>
                        (value == null || value.trim().isEmpty)
                        ? '请输入运动项目'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _minutesController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '目标时长（分钟）'),
                    validator: (value) => (int.tryParse(value ?? '') ?? 0) <= 0
                        ? '请输入有效时长'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  const Text('开始日期：'),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => _pickDate(context, true),
                      child: Text(
                        _startDate == null
                            ? '选择开始日期'
                            : _formatDate(_startDate!),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('结束日期：'),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => _pickDate(context, false),
                      child: Text(
                        _endDate == null ? '选择结束日期' : _formatDate(_endDate!),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _pickTime(context, true),
                          child: Text('开始：${_formatTime(_startTime)}'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _pickTime(context, false),
                          child: Text('结束：${_formatTime(_endTime)}'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('运动周期：'),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<WorkoutCycleType>(
                    initialValue: _cycleType,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    items: WorkoutCycleType.values
                        .map(
                          (c) =>
                              DropdownMenuItem(value: c, child: Text(c.label)),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => _cycleType = value);
                      }
                    },
                  ),
                  if (_cycleType == WorkoutCycleType.weekly) ...[
                    const SizedBox(height: 12),
                    const Text('执行日：'),
                    Wrap(
                      spacing: 8,
                      children: _allWeekdays.map((day) {
                        final selected = _weekdays.contains(day);
                        return FilterChip(
                          label: Text(day),
                          selected: selected,
                          onSelected: (value) {
                            setDialogState(() {
                              if (value) {
                                _weekdays.add(day);
                              } else {
                                _weekdays.remove(day);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                if (!_planFormKey.currentState!.validate()) return;
                if (_cycleType == WorkoutCycleType.weekly &&
                    _weekdays.isEmpty) {
                  Get.snackbar('提示', '请至少选择一个执行日');
                  return;
                }
                if (_startDate != null &&
                    _endDate != null &&
                    _endDate!.isBefore(_startDate!)) {
                  Get.snackbar('提示', '结束日期不能早于开始日期');
                  return;
                }
                controller.addWorkoutPlan(
                  title: _titleController.text.trim(),
                  project: _projectController.text.trim(),
                  weekdays: List<String>.from(_weekdays),
                  targetMinutes: int.parse(_minutesController.text.trim()),
                  startDate: _startDate,
                  endDate: _endDate,
                  startTime: _formatTime(_startTime),
                  endTime: _formatTime(_endTime),
                  cycleType: _cycleType,
                  customWeekdays: List<String>.from(_weekdays),
                );
                Navigator.pop(context);
              },
              child: const Text('发布'),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddStudyPlanDialog() {
    final controller = Get.find<ParentController>();
    _planTitleCtrl.clear();
    _planContentCtrl.clear();
    _planTypeCtrl.text = '综合';
    _planStart = DateTime.now();
    _planEnd = DateTime.now().add(const Duration(days: 7));
    _studyCycleType = WorkoutCycleType.daily;
    _studyWeekdays
      ..clear()
      ..addAll(['一', '三', '五']);

    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('新建学习计划'),
          content: Form(
            key: _studyPlanFormKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: _planTitleCtrl,
                    decoration: const InputDecoration(labelText: '计划标题'),
                    validator: (value) =>
                        (value == null || value.trim().isEmpty)
                        ? '请输入计划标题'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _planTypeCtrl,
                    decoration: const InputDecoration(
                      labelText: '计划类型',
                      hintText: '如：阅读、写作、背诵、练习、综合',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _planContentCtrl,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: '计划内容',
                      hintText: '详细描述计划要求和目标',
                    ),
                    validator: (value) =>
                        (value == null || value.trim().isEmpty)
                        ? '请输入计划内容'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  const Text('开始日期：'),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: _planStart,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2035),
                        );
                        if (date == null) return;
                        setDialogState(() {
                          _planStart = date;
                          if (_planEnd.isBefore(date)) {
                            _planEnd = date;
                          }
                        });
                      },
                      child: Text(_formatDate(_planStart)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('结束日期：'),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: _planEnd,
                          firstDate: _planStart,
                          lastDate: DateTime(2035),
                        );
                        if (date == null) return;
                        setDialogState(() => _planEnd = date);
                      },
                      child: Text(_formatDate(_planEnd)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('执行周期：'),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<WorkoutCycleType>(
                    initialValue: _studyCycleType,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    items: WorkoutCycleType.values
                        .map(
                          (c) =>
                              DropdownMenuItem(value: c, child: Text(c.label)),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => _studyCycleType = value);
                      }
                    },
                  ),
                  if (_studyCycleType == WorkoutCycleType.weekly) ...[
                    const SizedBox(height: 12),
                    const Text('执行日：'),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      children: _allWeekdays.map((day) {
                        final selected = _studyWeekdays.contains(day);
                        return FilterChip(
                          label: Text(day),
                          selected: selected,
                          onSelected: (value) {
                            setDialogState(() {
                              if (value) {
                                _studyWeekdays.add(day);
                              } else {
                                _studyWeekdays.remove(day);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                if (!_studyPlanFormKey.currentState!.validate()) return;
                if (_studyCycleType == WorkoutCycleType.weekly &&
                    _studyWeekdays.isEmpty) {
                  Get.snackbar('提示', '请至少选择一个执行日');
                  return;
                }
                if (_planEnd.isBefore(_planStart)) {
                  Get.snackbar('提示', '结束日期不能早于开始日期');
                  return;
                }
                final plan = StudyPlanModel(
                  id: 'sp_${DateTime.now().millisecondsSinceEpoch}',
                  title: _planTitleCtrl.text.trim(),
                  content: _planContentCtrl.text.trim(),
                  startAt: _planStart,
                  endAt: _planEnd,
                  type: _planTypeCtrl.text.trim(),
                  status: StudyPlanStatus.pendingStudentConfirm,
                  cycleType: _studyCycleType,
                  customWeekdays: List<String>.from(_studyWeekdays),
                );
                controller.createStudyPlan(plan);
                Navigator.pop(context);
              },
              child: const Text('发布'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ParentController>();

    return Obx(() {
      // ⚠️ 必须在这里读（Obx 内），否则「孩子换了 / 计划增删了」不会重建。
      final studyPlans = controller.visibleStudyPlans;
      final workoutPlans = controller.visibleWorkoutPlans;
      // 主列表只放还会产生新任务的计划；完成 / 暂停 / 拒绝 / 撤回收进底部小框
      // （判据在 `plan_archive.dart`，别在这里另写一遍 status 判断）。
      final activeStudy = activeStudyPlans(studyPlans);
      final activeWorkout = activeWorkoutPlans(workoutPlans);
      final activeTotal = activeStudy.length + activeWorkout.length;
      final ended = EndedPlanCounts.of(
        studyPlans: studyPlans,
        workoutPlans: workoutPlans,
      );

      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '计划',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),

          // ① 出题区 —— 这一页最上面。
          //
          // 顺序是刻意的：家长打开「计划」想知道的第一件事是「今天练什么」，
          // 其次才是「我排了哪些计划」。把出题压到新建按钮下面，
          // 等于让他先看一堆自己排过的表，再决定今天要不要加一项。
          const SizedBox(height: 16),
          _sectionLabel('今天练什么', trailing: '学科范围 · 出题'),
          // 两段式（2026-11-12）：上「学科范围」配一次长期有效，
          // 下「今天出什么」点色块直接出。之前是三张平级卡（概念打卡 /
          // 阅读 / 单词），「配一次的事」和「每天做的事」长得一模一样。
          const SubjectBoard(),
          const SizedBox(height: 14),
          const ReadingTaskCard(isParent: true),

          // ② 新建区 —— 两类计划各一个按钮，并排、不同颜色。
          //
          // 之前是「学习计划」一大段 + 「运动计划」一大段，每段自带标题和
          // 一个按钮，同一个动作在同一屏出现两次、长得还不一样。现在
          // 合并成一行两个按钮：颜色和图标区分类型，落库仍是两张表。
          const SizedBox(height: 8),
          _sectionLabel('新建计划'),
          Row(
            children: [
              Expanded(
                child: _NewPlanButton(
                  label: '学习计划',
                  icon: Icons.menu_book_outlined,
                  color: AppColors.primary,
                  onPressed: _showAddStudyPlanDialog,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _NewPlanButton(
                  label: '运动计划',
                  icon: Icons.directions_run_outlined,
                  color: AppColors.warning,
                  onPressed: _showAddWorkoutPlanDialog,
                ),
              ),
            ],
          ),

          // ③ 列表 —— 两类合在一个列表里，靠底色 + 左上角徽标区分。
          //
          // 只列**进行中**的计划：已结束的（完成 / 暂停 / 拒绝 / 撤回）收到
          // 下面那个小框里。否则每完成一次，主列表就多一张永远不用再看的大卡。
          const SizedBox(height: 20),
          _sectionLabel('进行中的计划', trailing: '$activeTotal 项'),
          if (activeTotal == 0 && ended.isEmpty) _emptyPlans(),
          if (activeTotal == 0 && !ended.isEmpty) _noActivePlans(),
          ...activeStudy.map(
            (plan) => PlanTile(
              kind: PlanKind.study,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StudyPlanInfo(plan: plan),
                  const SizedBox(height: 12),
                  if (plan.status == StudyPlanStatus.pendingStudentConfirm)
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: () => controller.updateStudyPlanStatus(
                            plan.id,
                            StudyPlanStatus.withdrawn,
                          ),
                          child: const Text('撤回计划'),
                        ),
                      ],
                    )
                  else if (plan.status == StudyPlanStatus.active) ...[
                    PlanExecutionSection(
                      plan: plan,
                      checkinKeys: controller.childCheckinDateKeys(plan.id),
                      interactive: false,
                      checkedToday: controller.isChildCheckedInToday(plan.id),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: () => controller.updateStudyPlanStatus(
                            plan.id,
                            StudyPlanStatus.completed,
                          ),
                          child: const Text('标记完成'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          ...activeWorkout.map(
            (plan) => PlanTile(
              kind: PlanKind.workout,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  WorkoutPlanInfo(plan: plan),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => controller.toggleWorkoutPlan(plan.id),
                    child: const Text('暂停计划'),
                  ),
                ],
              ),
            ),
          ),
          // 已结束的计划只留一行入口：主列表到此为止，不再被历史卡片撑长。
          if (!ended.isEmpty) ...[
            const SizedBox(height: 4),
            _EndedPlansEntry(
              counts: ended,
              onTap: () => PlansArchivePage.open(context),
            ),
          ],
        ],
      );
    });
  }
}

/// 区块小标题。「出题 / 新建 / 列表」三段靠它分节。
///
/// 不用三个 22px 大标题：这一页真正的重点是卡片内容，三行大字会把
/// 「出题」挤下去，也把「学习计划 / 运动计划」又变回两页。
Widget _sectionLabel(String title, {String? trailing}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 10, top: 4),
    child: Row(
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
        const Spacer(),
        if (trailing != null)
          Text(
            trailing,
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
      ],
    ),
  );
}

/// 已结束计划的唯一入口 —— 一行小框，不占版面。
///
/// 只写「已完成 2 · 已暂停 1」这种**非零项**：全列出来（含 0）会变成
/// 「已完成 2 · 已暂停 0 · 已拒绝 0 · 已撤回 0」，一行放不下还得换行，
/// 反而不像一个小框。
class _EndedPlansEntry extends StatelessWidget {
  const _EndedPlansEntry({required this.counts, required this.onTap});

  final EndedPlanCounts counts;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.inventory_2_outlined,
                size: 16,
                color: AppColors.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '已结束 · ${counts.breakdown}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${counts.total} 项',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
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
      ),
    );
  }
}

/// 进行中的计划为零、但历史里还有已结束的。
///
/// 不能复用 `_emptyPlans()`：那句写的是「还没有任何计划」，而这时候
/// 下面明明刚列了「已结束 5 项」，两句摆在一起自相矛盾。
Widget _noActivePlans() {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border),
    ),
    child: const Text(
      '没有进行中的计划。已结束的都收在下面，点开就能看到。',
      style: TextStyle(color: AppColors.textMuted, height: 1.6),
    ),
  );
}

/// 新建入口：并排两个，颜色 + 图标 + 文字三重区分。
class _NewPlanButton extends StatelessWidget {
  const _NewPlanButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18, color: color),
      label: Text(
        '新建$label',
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
      style: FilledButton.styleFrom(
        backgroundColor: color.withValues(alpha: 0.12),
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}

/// 一个计划都没有。
///
/// 这条必须有：列表区上面刚拆掉了两个大段标题，空着会让人以为
/// 「加载失败」—— 说一句「先在上面选一个」正好把两个按钮指出来。
Widget _emptyPlans() {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border),
    ),
    child: const Text(
      '还没有任何计划。先在上面选一个：\n'
      '学习计划按天安排读写背练，运动计划按周安排项目与时长。',
      style: TextStyle(color: AppColors.textMuted, height: 1.6),
    ),
  );
}
