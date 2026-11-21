import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../constants/app_colors.dart';
import '../utils/pop_route.dart';

/// 一个「改一个整数」的弹窗：标题 + 一句说明 + 数字输入框 + 取消/保存。
///
/// 家长端有两处要改数字 ——「心愿定价」和「积分规则分值」—— 最初各写了一份，
/// 两份都踩了同一个坑（见 [_IntInputDialogState] 上面那段）。做成一份，
/// 这个坑只需要修一次。
///
/// ## 返回值
///
/// - `null`：用户取消，或者点了遮罩/返回键关掉。**调用方应当把 `null` 读成
///   「什么都不做」**，而不是「填了 0」。
/// - 整数：用户确认的值，已按 [min]/[max] 夹紧。
///
/// 输入框被**清空**后点保存怎么算，由 [emptyValue] 决定：给了值（例如 `0`）
/// 就当成那个值返回；不给就留在弹窗里，什么都不改。
/// 这个差别值得显式写出来 —— 「空」和「0」在业务上常常不是一回事
/// （「没填」≠「不消耗积分」），让调用方自己说清楚。
Future<int?> showIntInputDialog({
  required String title,
  required int initial,
  String hint = '',
  String label = '分值',
  String suffixText = '分',
  int min = 0,
  int? max,
  int? emptyValue,
}) {
  return Get.dialog<int>(
    _IntInputDialog(
      title: title,
      initial: initial,
      hint: hint,
      label: label,
      suffixText: suffixText,
      min: min,
      max: max,
      emptyValue: emptyValue,
    ),
  );
}

class _IntInputDialog extends StatefulWidget {
  const _IntInputDialog({
    required this.title,
    required this.initial,
    required this.hint,
    required this.label,
    required this.suffixText,
    required this.min,
    required this.max,
    required this.emptyValue,
  });

  final String title;
  final int initial;
  final String hint;
  final String label;
  final String suffixText;
  final int min;
  final int? max;
  final int? emptyValue;

  @override
  State<_IntInputDialog> createState() => _IntInputDialogState();
}

class _IntInputDialogState extends State<_IntInputDialog> {
  /// 输入框控制器由 **State 持有**，并在 `State.dispose()` 里销毁 ——
  /// 这是这个组件存在的全部理由。
  ///
  /// ## 踩过的坑：`await Get.dialog(...)` 之后马上 `dispose()`
  ///
  /// 原先两处都是「拿到弹窗返回值 → `controller.dispose()`」，看着完全等价，
  /// 其实是错的。`Get.dialog` 返回的是 `Navigator.push` 的 Future，而它在
  /// `pop()` **被调用的那一瞬间**就完成了（`Route.didComplete` 完成
  /// `_popCompleter`），**不等退场动画**：弹窗还要再走约 150ms 的淡出，
  /// 期间还会再重建一次 `TextField`。于是控制器在「弹窗还在树上」的时候就被
  /// 销毁了，debug 下当场抛：
  ///
  /// ```
  /// A TextEditingController was used after being disposed.
  ///   #4 _AnimatedState.didUpdateWidget (transitions.dart)
  /// ```
  ///
  /// 后面还跟着一串框架树被带崩的**连带**断言（`RenderFlex overflowed by 99645
  /// pixels`、`'_dependents.isEmpty': is not true`），全是噪声，别去追它们。
  ///
  /// ## 症状为什么容易被读错
  ///
  /// **取消和保存都会报错** —— 看起来像两个按钮各坏了一个，其实是两条路径
  /// 唯一的共同步骤「关掉弹窗」坏的。所以判据要打在**取消**这条路径上：
  /// 它没有任何业务逻辑，还能出错就说明问题在弹窗自身。见
  /// `test/wish_cost_dialog_test.dart`。
  late final TextEditingController _input = TextEditingController(
    text: '${widget.initial}',
  );

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  int _clamp(int value) {
    var result = value;
    if (result < widget.min) result = widget.min;
    final max = widget.max;
    if (max != null && result > max) result = max;
    return result;
  }

  void _submit(BuildContext context) {
    final raw = int.tryParse(_input.text.trim());
    if (raw == null) {
      final fallback = widget.emptyValue;
      // 没给兜底值 = 「空」不是一种有效输入，留在弹窗里让用户自己改。
      if (fallback == null) return;
      popRoute<int>(context, fallback);
      return;
    }
    popRoute<int>(context, _clamp(raw));
  }

  @override
  Widget build(BuildContext context) {
    final max = widget.max;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.hint.isNotEmpty) ...[
            Text(
              widget.hint,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _input,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: widget.label,
              border: const OutlineInputBorder(),
              suffixText: widget.suffixText,
            ),
          ),
          // 只有调用方给了上限才显示这一行。心愿定价没有上限，
          // 硬显示一个「范围 0 – 999 分」只会让家长以为自己填错了。
          if (max != null) ...[
            const SizedBox(height: 8),
            Text(
              '范围 ${widget.min} – $max ${widget.suffixText}',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => popRoute<int>(context),
          child: const Text('取消'),
        ),
        ElevatedButton(onPressed: () => _submit(context), child: const Text('保存')),
      ],
    );
  }
}
