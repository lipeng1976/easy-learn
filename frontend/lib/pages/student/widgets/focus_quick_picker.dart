import 'package:flutter/material.dart';

import '../../../constants/app_colors.dart';
import '../../../models/focus_session_model.dart';

/// 临时打卡：选一个标签，然后开闹钟。
///
/// ## 为什么要有它
///
/// 「今天想读会儿书」这种事不属于任何作业、也不在计划里。
/// 没有入口的话，学生只有两个选择：不记，或者去建一个计划再打卡 ——
/// 而**为一个 15 分钟的念头建计划**，是这个界面能给出的最劝退的答案。
///
/// ## 为什么是几个固定选项 + 一个「其它」
///
/// 自由输入会得到「看书」「阅读」「读课外书」三个标签，
/// 于是「今天读了多久」在统计里被劈成三份，而每份看起来都不多。
/// 选项收在一处定义（`FocusQuickLabels`），统计才对得上。
Future<String?> showFocusQuickPicker(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => SafeArea(
      // ⚠️ 必须能滚：底部面板的高度上限是屏幕的 9/16，而这里是「标题 + 说明
      // + 6 个选项」。在矮屏（横屏、小屏、分屏）上固定高度会溢出 ——
      // 溢出的那一截**不会报错，只是点不到**，表现为「最下面那几个选项没反应」。
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Text(
                '临时打卡 · 记一段时间',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '不属于任何作业或计划也没关系，记下来就算数。',
                style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
              ),
            ),
            for (final label in FocusQuickLabels.values)
              ListTile(
                leading: const Icon(
                  Icons.play_circle_outline,
                  color: AppColors.primary,
                ),
                title: Text(label, style: const TextStyle(fontSize: 15)),
                onTap: () => Navigator.of(sheetContext).pop(label),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}
