import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../constants/app_colors.dart';
import '../models/point_model.dart';
import '../utils/pop_route.dart';
import 'int_input_dialog.dart';

/// 行为扣分的小组件与弹窗。
///
/// 弹窗里的 `TextEditingController` 一律由 **State 持有并在 dispose 里销毁**，
/// 不能用 `await Get.dialog(...)` 之后立刻 dispose —— 弹窗退场动画期间还会
/// rebuild，那时控制器已经死了（同 `int_input_dialog.dart` 里记过的坑）。

/// 记一次扣分前的确认。**`null` = 取消，`''` = 确认但不写备注。**
Future<String?> showBehaviorDeductDialog({
  required String behaviorName,
  required int points,
}) {
  return Get.dialog<String>(
    _BehaviorNoteDialog(behaviorName: behaviorName, points: points),
  );
}

class _BehaviorNoteDialog extends StatefulWidget {
  const _BehaviorNoteDialog({required this.behaviorName, required this.points});

  final String behaviorName;
  final int points;

  @override
  State<_BehaviorNoteDialog> createState() => _BehaviorNoteDialogState();
}

class _BehaviorNoteDialogState extends State<_BehaviorNoteDialog> {
  final note = TextEditingController();

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('记录${widget.behaviorName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '将扣除 ${widget.points} 分。扣分会和原来一样记进积分流水，随时可查。',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: note,
            decoration: const InputDecoration(
              labelText: '备注（可不填）',
              hintText: '例如：第三节课迟到 10 分钟',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => popRoute<String>(context),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: () => popRoute<String>(context, note.text.trim()),
          child: const Text('确认扣分'),
        ),
      ],
    );
  }
}

/// 新增自定义行为：只问名字，分值随后用统一的整数弹窗配。
Future<String?> showBehaviorNameDialog() {
  return Get.dialog<String>(const _BehaviorNameDialog());
}

class _BehaviorNameDialog extends StatefulWidget {
  const _BehaviorNameDialog();

  @override
  State<_BehaviorNameDialog> createState() => _BehaviorNameDialogState();
}

class _BehaviorNameDialogState extends State<_BehaviorNameDialog> {
  final name = TextEditingController();

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新增扣分行为'),
      content: TextField(
        controller: name,
        autofocus: true,
        inputFormatters: [LengthLimitingTextInputFormatter(20)],
        decoration: const InputDecoration(
          labelText: '行为名称',
          hintText: '例如：忘带作业、上课讲话',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => popRoute<String>(context),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: () {
            final value = name.text.trim();
            if (value.isEmpty) return;
            popRoute<String>(context, value);
          },
          child: const Text('添加'),
        ),
      ],
    );
  }
}

/// 一行行为配置：点分值改分，点「扣分」记一笔。
class PointBehaviorTile extends StatelessWidget {
  const PointBehaviorTile({
    super.key,
    required this.behavior,
    required this.onDeduct,
    required this.onPoints,
    required this.onEnabled,
    required this.onDelete,
  });

  final PointBehavior behavior;
  final VoidCallback onDeduct;
  final Future<void> Function(int points) onPoints;
  final ValueChanged<bool> onEnabled;
  final VoidCallback onDelete;

  Future<void> _editPoints(BuildContext context) async {
    final value = await showIntInputDialog(
      title: behavior.name,
      hint: '每次发生这种行为的扣分值。只影响之后记录，已有流水不重算。',
      initial: behavior.points,
      min: 1,
      max: 200,
    );
    if (value == null) return;
    await onPoints(value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = behavior.enabled;
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
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        behavior.name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: enabled ? AppColors.text : AppColors.textMuted,
                        ),
                      ),
                    ),
                    if (behavior.builtin) ...[
                      const SizedBox(width: 6),
                      const _Tag(text: '内置'),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  enabled ? '每次扣 ${behavior.points} 分' : '已关闭，不会扣分',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: enabled ? () => _editPoints(context) : null,
            child: Text(
              '-${behavior.points} 分',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: enabled ? AppColors.danger : AppColors.textMuted,
              ),
            ),
          ),
          Switch(value: enabled, onChanged: onEnabled),
          IconButton(
            tooltip: '扣分',
            onPressed: enabled ? onDeduct : null,
            icon: const Icon(Icons.remove_circle_outline, size: 20),
          ),
          if (!behavior.builtin)
            IconButton(
              tooltip: '删除',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, size: 20),
            ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.textMuted.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(color: AppColors.textMuted, fontSize: 10),
      ),
    );
  }
}
