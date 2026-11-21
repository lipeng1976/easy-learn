import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../constants/grades.dart';

/// 教材 / 词表的「年级学期与当前学生不匹配」提醒。
///
/// 只在**确实不匹配**且**两边都有值**时才显示（见 [gradeTermMismatch]）：
/// 书没标年级（老数据）或学生档案没设年级，都不报警 —— 那种情况报「不匹配」
/// 只会逼家长去改一个他不知道该填什么的值。
class GradeTermMismatchNotice extends StatelessWidget {
  const GradeTermMismatchNotice({
    super.key,
    required this.bookGrade,
    required this.bookTerm,
    required this.profileGrade,
    required this.profileTerm,
    this.onTapFix,
  });

  final String bookGrade;
  final String bookTerm;
  final String profileGrade;
  final String profileTerm;
  final VoidCallback? onTapFix;

  @override
  Widget build(BuildContext context) {
    if (!gradeTermMismatch(
      bookGrade: bookGrade,
      bookTerm: bookTerm,
      profileGrade: profileGrade,
      profileTerm: profileTerm,
    )) {
      return const SizedBox.shrink();
    }
    final book = gradeTermLabel(bookGrade, bookTerm);
    final profile = gradeTermLabel(profileGrade, profileTerm);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.softWarning,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.warning),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: AppColors.warning, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '这本是「$book」，但当前年级是「$profile」。'
              '年级对不上会一直做错年级的题，建议换一本或先更新年级。',
              style: const TextStyle(fontSize: 12.5, height: 1.45),
            ),
          ),
          if (onTapFix != null)
            TextButton(onPressed: onTapFix, child: const Text('去换书')),
        ],
      ),
    );
  }
}

/// 导入教材 / 词表时的年级 + 学期选择弹窗。
///
/// 默认填当前学生的年级学期（导入大概率就是当前年级的），家长改了才变。
/// 预填走 [pickerInitialGrade] 归一：档案写「初一」就命中「初一」，
/// 不会因为它不在选项里而悄悄退成「一年级」。
/// 返回 `(规范年级, 学期)` 供落库；取消返回 `null`。
Future<(String grade, String term)?> pickGradeTerm(
  BuildContext context, {
  String initialGrade = '',
  String initialTerm = '',
}) async {
  var grade = pickerInitialGrade(initialGrade);
  var term = kTermOptions.contains(initialTerm.trim())
      ? initialTerm.trim()
      : kTermOptions.first;
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (builderContext, setInner) => AlertDialog(
        title: const Text('这本属于哪个年级'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: grade,
              decoration: const InputDecoration(labelText: '年级'),
              items: [
                for (final one in kGradeOptions)
                  DropdownMenuItem(value: one, child: Text(one)),
              ],
              onChanged: (value) => setInner(() => grade = value ?? grade),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: kTermOptions.contains(term) ? term : kTermOptions.first,
              decoration: const InputDecoration(labelText: '学期'),
              items: [
                for (final one in kTermOptions)
                  DropdownMenuItem(value: one, child: Text(termFull(one))),
              ],
              onChanged: (value) => setInner(() => term = value ?? term),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
  if (result != true) return null;
  // 落库只写规范值：以后不会再产生「七年级」和「初一」两套真值。
  return (canonicalGrade(grade), term);
}
