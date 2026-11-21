import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/checkin_question_parser.dart';
import 'math_text.dart';

/// 家长预览一份打卡：题干 + 选项 + **正确答案** + 解析。
///
/// ## 为什么不复用 [CheckinQuestionCard]、也不给它加开关
///
/// 那个组件的安全边界是「绝不渲染 `answer` / `analysis`」——孩子答题时
/// 答案就在他手机里，界面上不能出现。一旦给它加一个 `showAnswer` 参数，
/// 学生端某个调用点传错一个 bool，答案就摆到孩子眼前，而这种错误
/// 在界面上看起来**完全正常**（多了一行字而已）。
///
/// 所以是两个组件、两套测试：预览卡可以画答案，答题卡不可以。
/// `test/checkin_question_card_test.dart` 与 `test/checkin_preview_card_test.dart`
/// 分别盯着这两条相反的要求。
///
/// 家长看到答案是对的 —— 他要辅导，不知道答案就没法讲。
class CheckinPreviewCard extends StatelessWidget {
  const CheckinPreviewCard({
    super.key,
    required this.index,
    required this.question,
  });

  final int index;
  final CheckinQuestion question;

  @override
  Widget build(BuildContext context) {
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
              _PreviewOption(
                label: isJudge ? options[i] : String.fromCharCode(65 + i),
                text: isJudge ? '' : options[i],
                correct: _isCorrect(i, isJudge),
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.check_circle_outline, size: 16, color: AppColors.success),
                const SizedBox(width: 6),
                Text(
                  '答案：${_answerLabel(isJudge)}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.success,
                  ),
                ),
                if (question.knowledge.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: MathText(
                      question.knowledge,
                      style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                    ),
                  ),
                ],
              ],
            ),
            if ((question.analysis ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '解析',
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 4),
                    MathText(question.analysis!),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 第 [i] 个选项是不是正确答案。
  ///
  /// 判断题的答案归一成 `T` / `F`（选项固定是「正确 / 错误」），
  /// 选择题的答案是字母。这两套映射与服务端 `normalizeQuestions`
  /// 的口径一致，改一处就要改另一处。
  bool _isCorrect(int i, bool isJudge) {
    final answer = question.answer.trim().toUpperCase();
    if (isJudge) return answer == (i == 0 ? 'T' : 'F');
    return answer == String.fromCharCode(65 + i);
  }

  String _answerLabel(bool isJudge) {
    final answer = question.answer.trim().toUpperCase();
    if (isJudge) return answer == 'F' ? '错误' : '正确';
    return answer;
  }
}

class _PreviewOption extends StatelessWidget {
  const _PreviewOption({
    required this.label,
    required this.text,
    required this.correct,
  });

  final String label;
  final String text;
  final bool correct;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: correct ? AppColors.success.withValues(alpha: 0.10) : Colors.transparent,
        border: Border.all(color: correct ? AppColors.success : AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: correct ? AppColors.success : AppColors.textMuted,
            ),
          ),
          const SizedBox(width: 10),
          if (text.isNotEmpty) Expanded(child: MathText(text)),
          if (correct)
            const Icon(Icons.check, size: 16, color: AppColors.success),
        ],
      ),
    );
  }
}
