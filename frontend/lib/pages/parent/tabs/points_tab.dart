import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../../constants/app_colors.dart';
import '../../../controllers/auth_controller.dart';
import '../../../controllers/parent_controller.dart';
import '../../../controllers/point_controller.dart';
import '../../../models/point_model.dart';
import '../../../widgets/point_behavior_widgets.dart';
import '../../shared/point_ledger_page.dart';
// 改分值的数字弹窗。原先这里是本地一份 `_promptInt`，与心愿定价那份是复制品，
// 两份都踩了同一个「弹窗还没关就 dispose 掉输入框控制器」的坑 —— 现在共用一份。
import '../../../widgets/int_input_dialog.dart';
import '../../../widgets/point_widgets.dart';

/// 家长端的积分：设分值、发奖励、看记录。
///
/// 三件事放在同一个 tab 里而不是拆成三页，是因为它们共用同一个前提 ——
/// **当前选中的是哪个孩子**。拆开之后家长要在三个页面之间反复确认
/// 「我现在设的是谁的」，而那正是最容易设错的地方。
class PointsTab extends StatefulWidget {
  const PointsTab({super.key});

  @override
  State<PointsTab> createState() => _PointsTabState();
}

enum _Panel { rules, reward, behavior, ledger }

class _PointsTabState extends State<PointsTab> {
  final controller = Get.find<ParentController>();
  _Panel panel = _Panel.rules;

  @override
  void initState() {
    super.initState();
    // 账本的加载与「切孩子跟着切账本」由 `ParentController` 统一负责
    // （心愿页也依赖那份余额），这里只是兜底拉一次。
    controller.loadPointsForSelected();
  }

  String get _studentName {
    final id = controller.selectedStudentId.value;
    for (final child in controller.boundStudents) {
      if (child.id == id) return child.name;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final points = controller.points;

    return Obx(() {
      final account = points.account.value;
      final studentId = controller.selectedStudentId.value;

      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '积分',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          PointBalanceCard(
            account: account,
            title: _studentName.isEmpty ? '孩子积分' : '$_studentName 的积分',
            subtitle: '余额由流水累加得来',
            onOpenLedger: studentId.isEmpty
                ? null
                : () => Get.to(
                    () => PointLedgerPage(
                      studentId: studentId,
                      title: '积分明细',
                      subjectName: _studentName,
                    ),
                  ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<_Panel>(
            segments: const [
              ButtonSegment(value: _Panel.rules, label: Text('分值设置')),
              ButtonSegment(value: _Panel.reward, label: Text('奖励积分')),
              ButtonSegment(value: _Panel.behavior, label: Text('行为扣分')),
              ButtonSegment(value: _Panel.ledger, label: Text('积分记录')),
            ],
            selected: {panel},
            onSelectionChanged: (value) => setState(() => panel = value.first),
          ),
          const SizedBox(height: 16),
          if (studentId.isEmpty)
            const PointEmptyHint(text: '还没有绑定孩子，先完成伴学绑定。')
          else ...[
            if (panel == _Panel.rules) _buildRules(studentId),
            if (panel == _Panel.reward) _buildReward(studentId),
            if (panel == _Panel.behavior) _buildBehavior(studentId),
            if (panel == _Panel.ledger) _buildLedger(),
          ],
        ],
      );
    });
  }

  /// 分值设置。
  Widget _buildRules(String studentId) {
    final points = controller.points;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '每个动作值多少分',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        const Text(
          '只影响之后发生的动作，已经记过的分不会重算。',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        ...kConfigurablePointActions.map((action) {
          final enabled = points.isEnabled(action);
          final value = points.pointsFor(action);
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        action.label,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: enabled
                              ? AppColors.text
                              : AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        action.hint,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: !enabled
                      ? null
                      : () => _editPoints(studentId, action, value),
                  child: Text(
                    '$value 分',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: enabled ? AppColors.primary : AppColors.textMuted,
                      fontSize: 15,
                    ),
                  ),
                ),
                Switch(
                  value: enabled,
                  onChanged: (on) => points.setRule(
                    studentId: studentId,
                    action: action,
                    enabled: on,
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Future<void> _editPoints(
    String studentId,
    PointAction action,
    int current,
  ) async {
    final value = await showIntInputDialog(
      title: action.label,
      hint: action.hint,
      initial: current,
      // 分值上限 200：这是家长端规则配置的口径，不是通用数字弹窗的默认值。
      max: 200,
    );
    if (value == null) return;
    await controller.points.setRule(
      studentId: studentId,
      action: action,
      points: value,
    );
  }

  /// 行为扣分：内置迟到/旷课/违纪，家长也能加自己的行为。
  Widget _buildBehavior(String studentId) {
    final points = controller.points;
    final behaviors = points.behaviors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '行为扣分${_studentName.isEmpty ? '' : '（$_studentName）'}',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        const Text(
          '每种行为单独定分值；扣分后可在「积分记录」里按行为查到。',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        ...behaviors.map(
          (behavior) => PointBehaviorTile(
            behavior: behavior,
            onDeduct: () => _deduct(studentId, behavior),
            onPoints: (value) => points.setBehavior(
              studentId: studentId,
              id: behavior.id,
              name: behavior.name,
              points: value,
              enabled: behavior.enabled,
              builtin: behavior.builtin,
            ),
            onEnabled: (on) => points.setBehavior(
              studentId: studentId,
              id: behavior.id,
              name: behavior.name,
              points: behavior.points,
              enabled: on,
              builtin: behavior.builtin,
            ),
            onDelete: () async {
              final ok = await points.deleteBehavior(
                studentId: studentId,
                id: behavior.id,
              );
              Get.snackbar(ok ? '已删除' : '未删除', ok ? '' : '内置行为只能关闭');
            },
          ),
        ),
        if (behaviors.isEmpty)
          const PointEmptyHint(text: '还没有行为配置，点下面按钮添加。'),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _addBehavior(studentId),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('新增扣分行为'),
        ),
      ],
    );
  }

  Future<void> _deduct(String studentId, PointBehavior behavior) async {
    final note = await showBehaviorDeductDialog(
      behaviorName: behavior.name,
      points: behavior.points,
    );
    if (note == null) return;
    final parentId = Get.find<AuthController>().currentUser.value?.id ?? '';
    final result = await controller.points.deductBehavior(
      studentId: studentId,
      behaviorId: behavior.id,
      createdBy: parentId,
      note: note,
    );
    if (!Get.isSnackbarOpen) {
      Get.snackbar(
        result == PointGrantOutcome.granted ? '已扣分' : '未扣分',
        result == PointGrantOutcome.granted
            ? '${behavior.name} -${behavior.points} 分，已记入积分流水'
            : '这次没有记上（${result.name}）',
      );
    }
  }

  Future<void> _addBehavior(String studentId) async {
    final name = await showBehaviorNameDialog();
    if (name == null || name.isEmpty) return;
    await controller.points.setBehavior(
      studentId: studentId,
      id: 'custom_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      points: 3,
      enabled: true,
    );
  }

  /// 手动奖励。
  Widget _buildReward(String studentId) {
    return _RewardForm(
      studentName: _studentName,
      onSubmit: (points, reason) =>
          controller.grantPoints(points: points, reason: reason),
    );
  }

  /// 记录。
  Widget _buildLedger() {
    final entries = controller.points.ledger;
    if (entries.isEmpty) {
      return const PointEmptyHint(
        text: '这个孩子还没有积分记录。\n交作业、运动、打卡、每日练习、复习都能赚积分。',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '最近的记录',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        ...entries.take(30).map((entry) => PointLedgerTile(entry: entry)),
        if (entries.length > 30)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '只显示最近 30 条，全部记录请在明细页查看。',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ),
      ],
    );
  }
}

/// 奖励表单。
///
/// 单独一个 StatefulWidget，是为了让输入框的 controller 跟着表单走 ——
/// 挂在 tab 的 State 上会让「切到别的 panel 再切回来」时输入内容还留着，
/// 家长会以为刚才发出去了。
class _RewardForm extends StatefulWidget {
  const _RewardForm({required this.studentName, required this.onSubmit});

  final String studentName;
  final Future<dynamic> Function(int points, String reason) onSubmit;

  @override
  State<_RewardForm> createState() => _RewardFormState();
}

class _RewardFormState extends State<_RewardForm> {
  final pointsController = TextEditingController(text: '5');
  final reasonController = TextEditingController();
  bool submitting = false;

  @override
  void dispose() {
    pointsController.dispose();
    reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '额外奖励',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          '临时给孩子加分的场合：主动做家务、帮了忙、说到做到。'
          '${widget.studentName.isEmpty ? '' : '（记在${widget.studentName}名下）'}',
          style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: pointsController,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: '奖励积分',
            border: OutlineInputBorder(),
            suffixText: '分',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: reasonController,
          decoration: const InputDecoration(
            labelText: '奖励理由',
            hintText: '例如：这周主动收拾了房间',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: submitting
                ? null
                : () async {
                    final points = int.tryParse(pointsController.text.trim());
                    if (points == null || points <= 0) {
                      Get.snackbar('提示', '奖励积分要大于 0');
                      return;
                    }
                    setState(() => submitting = true);
                    final result = await widget.onSubmit(
                      points,
                      reasonController.text.trim(),
                    );
                    if (!mounted) return;
                    setState(() => submitting = false);
                    final ok = result?.ok == true;
                    Get.snackbar(
                      ok ? '奖励成功' : '发放失败',
                      '${result?.message ?? ''}',
                    );
                    if (ok) {
                      reasonController.clear();
                    }
                  },
            icon: const Icon(Icons.card_giftcard, size: 18),
            label: const Text('发放奖励'),
          ),
        ),
      ],
    );
  }
}
