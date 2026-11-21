import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../constants/app_colors.dart';
import '../../../controllers/student_controller.dart';
import '../../../models/workout_model.dart';
import '../../../services/calendar_summary_service.dart';
import '../../../services/database_service.dart';
import '../../../widgets/day_calendar.dart';

class WorkoutTab extends StatefulWidget {
  const WorkoutTab({super.key});

  @override
  State<WorkoutTab> createState() => _WorkoutTabState();
}

class _WorkoutTabState extends State<WorkoutTab> {
  final _recordFormKey = GlobalKey<FormState>();
  final _planFormKey = GlobalKey<FormState>();
  final _projectController = TextEditingController();
  final _minutesController = TextEditingController();
  final _feedbackController = TextEditingController();
  final _planTitleController = TextEditingController();
  final _planProjectController = TextEditingController();
  final _planMinutesController = TextEditingController();

  DateTime _selectedDate = DateTime.now();
  DateTime _recordDate = DateTime.now();
  TimeOfDay _recordStartTime = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _recordEndTime = const TimeOfDay(hour: 9, minute: 0);

  DateTime? _planStartDate;
  DateTime? _planEndDate;
  TimeOfDay _planStartTime = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _planEndTime = const TimeOfDay(hour: 9, minute: 0);
  WorkoutCycleType _planCycleType = WorkoutCycleType.weekly;
  final List<String> _planWeekdays = ['一', '三', '五'];
  static const List<String> _allWeekdays = ['一', '二', '三', '四', '五', '六', '日'];

  /// 学生控制器。在 [initState] 里取一次 —— 摘要相关的回调
  /// （`MonthPickerLauncher` 里的翻月取数）在 `build` 之外也要用它，
  /// 所以不能像本文件别处那样放在 `build` 里当局部量。
  late final StudentController controller;

  /// 摘要服务（含按月缓存）。**实例字段、只建一次**
  /// （写成 getter 会让缓存永远命中不了，且不报错）。
  late final CalendarSummaryService _summary;

  @override
  void initState() {
    super.initState();
    controller = Get.find<StudentController>();
    // 本地模式下 `api` 为 null → 摘要服务直接回空 Map，日历只是不打点。
    _summary = CalendarSummaryService(api: DatabaseService.cloud?.api);
  }

  @override
  void dispose() {
    _projectController.dispose();
    _minutesController.dispose();
    _feedbackController.dispose();
    _planTitleController.dispose();
    _planProjectController.dispose();
    _planMinutesController.dispose();
    super.dispose();
  }

  static bool _isSameDay(DateTime first, DateTime second) {
    return first.year == second.year &&
        first.month == second.month &&
        first.day == second.day;
  }

  String _formatTime(TimeOfDay time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  TimeOfDay _parseTimeOfDay(String value) {
    final parts = value.split(':');
    return TimeOfDay(
      hour: int.tryParse(parts[0]) ?? 8,
      minute: int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0,
    );
  }

  DateTime _combine(DateTime date, TimeOfDay time) {
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  void _showAddRecordDialog({WorkoutPlan? plan}) {
    final controller = Get.find<StudentController>();
    _projectController.text = plan?.project ?? '';
    _minutesController.text = plan != null ? '${plan.targetMinutes}' : '';
    _feedbackController.clear();
    _recordDate = DateTime.now();
    _recordStartTime = plan != null
        ? _parseTimeOfDay(plan.startTime)
        : TimeOfDay.now();
    _recordEndTime = plan != null
        ? _parseTimeOfDay(plan.endTime)
        : TimeOfDay.now();

    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(plan != null ? '运动打卡' : '新增运动记录'),
          content: Form(
            key: _recordFormKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: _projectController,
                    decoration: const InputDecoration(labelText: '运动项目'),
                    validator: (value) =>
                        (value == null || value.trim().isEmpty)
                        ? '请输入运动项目'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  const Text('日期：'),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: _recordDate,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2035),
                        );
                        if (date == null) return;
                        setDialogState(() => _recordDate = date);
                      },
                      child: Text(_formatDate(_recordDate)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final time = await showTimePicker(
                              context: context,
                              initialTime: _recordStartTime,
                            );
                            if (time == null) return;
                            setDialogState(() {
                              _recordStartTime = time;
                              if (_recordEndTime.hour < time.hour ||
                                  (_recordEndTime.hour == time.hour &&
                                      _recordEndTime.minute <= time.minute)) {
                                _recordEndTime = TimeOfDay(
                                  hour: (time.hour + 1) % 24,
                                  minute: time.minute,
                                );
                              }
                            });
                          },
                          child: Text('开始：${_formatTime(_recordStartTime)}'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final time = await showTimePicker(
                              context: context,
                              initialTime: _recordEndTime,
                            );
                            if (time == null) return;
                            setDialogState(() => _recordEndTime = time);
                          },
                          child: Text('结束：${_formatTime(_recordEndTime)}'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _minutesController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '运动时长（分钟）'),
                    validator: (value) => (int.tryParse(value ?? '') ?? 0) <= 0
                        ? '请输入有效时长'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _feedbackController,
                    decoration: const InputDecoration(labelText: '运动反馈'),
                    maxLines: 2,
                  ),
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
                if (_recordFormKey.currentState!.validate()) {
                  controller.addWorkoutRecord(
                    project: _projectController.text.trim(),
                    start: _combine(_recordDate, _recordStartTime),
                    end: _combine(_recordDate, _recordEndTime),
                    minutes: int.parse(_minutesController.text.trim()),
                    feedback: _feedbackController.text.trim(),
                    planId: plan?.id ?? '',
                  );
                  Navigator.pop(context);
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  void _resetPlanForm() {
    _planTitleController.clear();
    _planProjectController.clear();
    _planMinutesController.text = '30';
    _planWeekdays
      ..clear()
      ..addAll(['一', '三', '五']);
    _planStartDate = null;
    _planEndDate = null;
    _planStartTime = const TimeOfDay(hour: 8, minute: 0);
    _planEndTime = const TimeOfDay(hour: 9, minute: 0);
    _planCycleType = WorkoutCycleType.weekly;
  }

  void _showAddPlanDialog() {
    final controller = Get.find<StudentController>();
    setState(_resetPlanForm);
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
                    controller: _planTitleController,
                    decoration: const InputDecoration(labelText: '计划标题'),
                    validator: (value) =>
                        (value == null || value.trim().isEmpty)
                        ? '请输入计划标题'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _planProjectController,
                    decoration: const InputDecoration(labelText: '运动项目'),
                    validator: (value) =>
                        (value == null || value.trim().isEmpty)
                        ? '请输入运动项目'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _planMinutesController,
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
                      onPressed: () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: _planStartDate ?? DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2035),
                        );
                        if (date == null) return;
                        setDialogState(() {
                          _planStartDate = date;
                          if (_planEndDate != null &&
                              _planEndDate!.isBefore(date)) {
                            _planEndDate = date;
                          }
                        });
                      },
                      child: Text(
                        _planStartDate == null
                            ? '选择开始日期'
                            : _formatDate(_planStartDate!),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('结束日期：'),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: _planEndDate ?? DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2035),
                        );
                        if (date == null) return;
                        setDialogState(() {
                          _planEndDate = date;
                          if (_planStartDate != null &&
                              _planStartDate!.isAfter(date)) {
                            _planStartDate = date;
                          }
                        });
                      },
                      child: Text(
                        _planEndDate == null
                            ? '选择结束日期'
                            : _formatDate(_planEndDate!),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final time = await showTimePicker(
                              context: context,
                              initialTime: _planStartTime,
                            );
                            if (time == null) return;
                            setDialogState(() {
                              _planStartTime = time;
                              if (_planEndTime.hour < time.hour ||
                                  (_planEndTime.hour == time.hour &&
                                      _planEndTime.minute <= time.minute)) {
                                _planEndTime = TimeOfDay(
                                  hour: (time.hour + 1) % 24,
                                  minute: time.minute,
                                );
                              }
                            });
                          },
                          child: Text('开始：${_formatTime(_planStartTime)}'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final time = await showTimePicker(
                              context: context,
                              initialTime: _planEndTime,
                            );
                            if (time == null) return;
                            setDialogState(() => _planEndTime = time);
                          },
                          child: Text('结束：${_formatTime(_planEndTime)}'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('运动周期：'),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<WorkoutCycleType>(
                    initialValue: _planCycleType,
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
                        setDialogState(() => _planCycleType = value);
                      }
                    },
                  ),
                  if (_planCycleType == WorkoutCycleType.weekly) ...[
                    const SizedBox(height: 12),
                    const Text('执行日：'),
                    Wrap(
                      spacing: 8,
                      children: _allWeekdays.map((day) {
                        final selected = _planWeekdays.contains(day);
                        return FilterChip(
                          label: Text(day),
                          selected: selected,
                          onSelected: (value) {
                            setDialogState(() {
                              if (value) {
                                _planWeekdays.add(day);
                              } else {
                                _planWeekdays.remove(day);
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
                if (_planCycleType == WorkoutCycleType.weekly &&
                    _planWeekdays.isEmpty) {
                  Get.snackbar('提示', '请至少选择一个执行日');
                  return;
                }
                if (_planStartDate != null &&
                    _planEndDate != null &&
                    _planEndDate!.isBefore(_planStartDate!)) {
                  Get.snackbar('提示', '结束日期不能早于开始日期');
                  return;
                }
                controller.addWorkoutPlan(
                  title: _planTitleController.text.trim(),
                  project: _planProjectController.text.trim(),
                  weekdays: List<String>.from(_planWeekdays),
                  targetMinutes: int.parse(_planMinutesController.text.trim()),
                  startDate: _planStartDate,
                  endDate: _planEndDate,
                  startTime: _formatTime(_planStartTime),
                  endTime: _formatTime(_planEndTime),
                  cycleType: _planCycleType,
                  customWeekdays: List<String>.from(_planWeekdays),
                );
                Navigator.pop(context);
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<StudentController>();

    return Scaffold(
      body: Obx(() {
        final today = DateTime.now();
        final selectedDate = _selectedDate;
        final dayPlans = controller.workoutPlans
            .where((plan) => plan.appliesToDate(selectedDate))
            .toList();
        final dayRecords = controller.workoutRecords
            .where((r) => _isSameDay(r.start, selectedDate))
            .toList();

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              '运动日历',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            WeekStrip(
              selectedDate: selectedDate,
              today: today,
              onDateSelected: (date) => setState(() => _selectedDate = date),
              onPickMonth: () => _openMonthPicker(selectedDate),
              // 周历上的小圆点用**本地算的**打点：这一页手上就那一批数据，
              // 为七个格子发一次请求不值得（月历那边才需要，因为它要覆盖整月）。
              marks: _localMarksFor(selectedDate),
            ),
            const SizedBox(height: 18),
            Text(
              _isSameDay(selectedDate, today)
                  ? '今天的运动计划'
                  : '${selectedDate.month}月${selectedDate.day}日的运动计划',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            if (dayPlans.isEmpty)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  children: [
                    const Icon(
                      Icons.fitness_center_outlined,
                      size: 40,
                      color: AppColors.primary,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '暂无运动计划',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _isSameDay(selectedDate, today)
                          ? '今天还没有安排运动计划'
                          : '这一天暂无运动计划',
                    ),
                  ],
                ),
              )
            else
              ...dayPlans.map((plan) {
                final checkedIn = controller.isWorkoutPlanCheckedIn(
                  plan.id,
                  selectedDate,
                );
                final record = controller.workoutRecordForPlan(
                  plan.id,
                  selectedDate,
                );
                return _PlanCard(
                  plan: plan,
                  checkedIn: checkedIn,
                  record: record,
                  onCheckIn: () => _showAddRecordDialog(plan: plan),
                );
              }),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _showAddPlanDialog(),
                    icon: const Icon(Icons.event_available),
                    label: const Text('新增运动计划'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _showAddRecordDialog(),
                    icon: const Icon(Icons.add),
                    label: const Text('新增运动记录'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Text(
              '运动记录',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            if (dayRecords.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  '当天暂无运动记录',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textMuted),
                ),
              )
            else
              ...dayRecords.map(
                (record) => Container(
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
                      Text(
                        record.project,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text('时长：${record.minutes} 分钟'),
                      Text(
                        '时间：${record.start.toLocal().toString().substring(0, 16)} - ${record.end.toLocal().toString().substring(0, 16)}',
                      ),
                      if (record.feedback.isNotEmpty)
                        Text('反馈：${record.feedback}'),
                    ],
                  ),
                ),
              ),
          ],
        );
      }),
    );
  }
  /// 打开月历弹层（历史数据方案的入口）。
  ///
  /// 与 `homework_tab` 的同名方法**共用同一份实现**（`MonthPickerLauncher`）——
  /// 上一版这里是「逐字相同的拷贝」，而拷贝迟早会漂
  /// （抽 `WeekStrip` 时才发现三份里有一份把选中日期写成了 `static`）。
  /// 差异只有「本页先给什么打点」：运动页只按 `start` 打点。
  Future<void> _openMonthPicker(DateTime selectedDate) async {
    final picked = await MonthPickerLauncher.open(
      context,
      selectedDate: selectedDate,
      fetchSummary: (month) => _summary.summaryFor(month),
      localMarks: _localMarksFor(selectedDate),
    );
    if (picked == null) return;
    if (!mounted) return;
    setState(() => _selectedDate = picked);
  }

  /// 本地先算的打点：只用运动记录（这一页的主题就是运动）。
  ///
  /// 与作业页同理：它只覆盖**已加载的那些行**，所以是「先显示点什么」，
  /// 真相由服务端摘要给出。
  Map<String, DayMarks> _localMarksFor(DateTime month) {
    // ⚠️ 学生端这里叫 `workoutRecords`（`visibleWorkoutRecords` 是**家长端**
    // `ParentController` 上的名字，那边多一层「按选中孩子收窄」）。
    // 两个名字相像但属于不同控制器 —— 写错是编译错误，而这个错误信息
    // （「getter 未定义」）不会告诉你「你可能想要另一个控制器上的那个」。
    final records = controller.workoutRecords;
    if (records.isEmpty) return const {};
    final key = DayUtil.monthKey(month);
    return LocalDayMarks.build(
      homework: const [],
      workoutRecords: records.where((r) => DayUtil.monthKey(r.start) == key),
      checkins: const [],
    );
  }
}

class _PlanCard extends StatelessWidget {
  final WorkoutPlan plan;
  final bool checkedIn;
  final WorkoutRecord? record;
  final VoidCallback onCheckIn;

  const _PlanCard({
    required this.plan,
    required this.checkedIn,
    required this.record,
    required this.onCheckIn,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
                  plan.title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: checkedIn
                      ? AppColors.success.withValues(alpha: 0.15)
                      : AppColors.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  checkedIn ? '已打卡' : '待打卡',
                  style: TextStyle(
                    color: checkedIn ? AppColors.success : AppColors.warning,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('项目：${plan.project}'),
          Text('时间段：${plan.startTime} ~ ${plan.endTime}'),
          Text('目标时长：${plan.targetMinutes} 分钟'),
          Text('周期：${plan.cycleType.label}'),
          if (checkedIn && record != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: const [
                      Icon(
                        Icons.check_circle,
                        size: 16,
                        color: AppColors.success,
                      ),
                      SizedBox(width: 6),
                      Text(
                        '打卡记录',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.success,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('实际时长：${record!.minutes} 分钟'),
                  Text(
                    '运动时间：${record!.start.toLocal().toString().substring(0, 16)} - ${record!.end.toLocal().toString().substring(0, 16)}',
                  ),
                  if (record!.feedback.isNotEmpty)
                    Text('反馈：${record!.feedback}'),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: checkedIn
                    ? OutlinedButton.icon(
                        onPressed: onCheckIn,
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('修改打卡'),
                      )
                    : ElevatedButton.icon(
                        onPressed: onCheckIn,
                        icon: const Icon(Icons.fitness_center),
                        label: const Text('打卡'),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
