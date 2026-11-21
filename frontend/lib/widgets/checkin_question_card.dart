import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/checkin_question_parser.dart';
import 'math_text.dart';

/// 打卡里的一道题（答题态）。
///
/// ## 这个组件是「答案看不见」的唯一一道闸
///
/// 题目从服务端下来时**带答案**（`answer`、`analysis`），因为交卷那一刻
/// 要在本机判对错、不等网络。所以「孩子看不到答案」不靠接口，靠这里：
///
///   ⚠️ build 里只许用 `stem` / `options` / `knowledge`。
///      出现 `question.answer` 或 `question.analysis` 就是把答案摆在孩子眼前。
///
/// `test/checkin_question_card_test.dart` 直接拿带答案的题渲染一遍，
/// 断言界面上找不到答案与解析 —— 谁往这里加了字段，那条会红。
///
/// 单独抽成公共组件也是为了这条判据：页面里带 GetX 与数据库初始化，
/// 为了验一个渲染约束去搭整套环境，最后多半会「懒得测」。
class CheckinQuestionCard extends StatelessWidget {
  const CheckinQuestionCard({
    super.key,
    required this.index,
    required this.question,
    required this.picked,
    required this.onPick,
  });

  final int index;
  final CheckinQuestion question;

  /// `A`–`F`（选择题）或 `T` / `F`（判断题）。
  final String? picked;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    // 判断题的选项由服务端固定成 ["正确","错误"]，答案归一成 T/F；
    // 渲染时才把 T/F 映射回显示文字。
    final isJudge = question.isJudge;
    final options = isJudge ? const ['正确', '错误'] : question.options;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${index + 1}.',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(child: MathText(question.stem)),
              ],
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < options.length; i++)
              _OptionTile(
                // 判据用：`test/checkin_answer_test.dart` 靠它拿到选项那层
                // Container，断言「选中之后底色变了」。没有 key 就只能按
                // 文字找祖先容器，选项一多、题干里又出现 A/B 时找不到唯一的那个。
                key: ValueKey('checkin-option-$index-$i'),
                label: isJudge ? options[i] : String.fromCharCode(65 + i),
                text: isJudge ? '' : options[i],
                selected: isJudge
                    ? picked == (i == 0 ? 'T' : 'F')
                    : picked == String.fromCharCode(65 + i),
                onTap: () => onPick(
                  isJudge ? (i == 0 ? 'T' : 'F') : String.fromCharCode(65 + i),
                ),
              ),
            if (question.knowledge.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: MathText(
                  '知识点：${question.knowledge}',
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    super.key,
    required this.label,
    required this.text,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String text;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.10)
              : Colors.transparent,
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: selected ? AppColors.primary : AppColors.textMuted,
              ),
            ),
            const SizedBox(width: 10),
            if (text.isNotEmpty) Expanded(child: MathText(text)),
          ],
        ),
      ),
    );
  }
}
