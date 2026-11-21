import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

/// 「需要批改」开关。
///
/// 录入核对和提交面板两处都要用。抽出来不是为了省几行，是因为**两处的
/// 措辞必须一致**：学生在录入时看到的是「不检查对错」，到提交时变成另一套
/// 说法，他会怀疑自己点错了地方，然后去问家长 —— 而这个开关本来要回答的
/// 就是他自己能判断的事。
///
/// 默认状态由调用方给（现在按作业标题的类型推：朗读、背诵、预习没有
/// 对错可判）。这里只负责把它画出来、让整行可点。
class NeedsGradingSwitch extends StatelessWidget {
  const NeedsGradingSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.note,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  /// 开关下面那行解释。不同场景要说清「为什么默认是这样」——
  /// 一个没有理由的默认值，学生会先去把它改掉，然后再去想要不要改。
  final String? note;

  @override
  Widget build(BuildContext context) {
    // 包一层**透明 Material**，因为这个开关要放进两个 Material 环境不同的宿主：
    // 录入对话框在 `AlertDialog` 里（自带 Material），而提交面板在一个带背景色的
    // `Container` 里。后者会让 ListTile 的水波纹画到被遮住的那一层上 ——
    // debug 下直接断言失败（"ListTile background color or ink splashes may be
    // invisible"），release 下不崩、但点下去没有任何反馈。
    //
    // 让组件自己兜住这件事，而不是要求每个宿主记得垫一层 Material：
    // 要求宿主配合的约定，第二个宿主就会忘。
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            value: value,
            onChanged: onChanged,
            contentPadding: EdgeInsets.zero,
            dense: true,
            visualDensity: VisualDensity.compact,
            title: const Text(
              '需要批改',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              value ? '提交后由 AI 检查对错，错了进错题本' : '只上传照片留档，不检查对错',
              style: const TextStyle(
                fontSize: 11.5,
                color: AppColors.textMuted,
              ),
            ),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(left: 2, top: 2),
              child: Text(
                note!,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textMuted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
