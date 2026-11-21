import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/checkin_question_parser.dart';
import 'math_text.dart';

/// 学生端「已交卷」时，按**试卷排版**逐题回放。
///
/// 排版与家长端预览卡 [CheckinPreviewCard] 一致（题干 + 选项 + 解析），
/// 但多了一层「学生作答」的标注：
///   · 正确答案永远绿色高亮（和推送给家长的试卷一样，让孩子看得到标准答案）；
///   · 学生**选错**的那一项，额外用浅红标出（一眼看出自己选了哪个错的）；
///   · 学生选对的项正好是正确答案，所以天然就是绿色。
///
/// 安全边界：答题卡 [CheckinQuestionCard] 绝不渲染答案；本组件只用于
/// 「已交卷」这一态 —— 卷都交了，题目和答案一起出现是设计允许的。
/// 它绝不出现在 `_QuizBody`（答题中）那条路上。
class CheckinResultPaperCard extends StatelessWidget {
  const CheckinResultPaperCard({
    super.key,
    required this.index,
    required this.question,
    required this.picked,
    required this.correct,
  });

  /// 题号（从 0 开始，界面显示 +1）。
  final int index;

  /// 题目快照：题干 / 选项 / 正确答案 / 解析都来自它。
  final CheckinQuestion question;

  /// 学生这一题选的值（选择题是字母 A/B…，判断题是 T/F）。
  final String picked;

  /// 学生这一题是否选对（与 [picked] 同源，避免再判一次分）。
  final bool correct;

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
              _ResultOption(
                label: isJudge ? options[i] : String.fromCharCode(65 + i),
                text: isJudge ? '' : options[i],
                isAnswer: _isAnswer(i, isJudge),
                isPick: _isPick(i, isJudge),
              ),
            const SizedBox(height: 4),
            // 作答标注：先写「你的答案」，错了再补「正确答案」。
            // 颜色跟着对错走 —— 家长试卷上正确答案是绿，这里保持一致。
            Row(
              children: [
                Icon(
                  correct ? Icons.check_circle_outline : Icons.cancel_outlined,
                  size: 16,
                  color: correct ? AppColors.success : AppColors.danger,
                ),
                const SizedBox(width: 6),
                Text(
                  '你的答案：${_label(picked)}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: correct ? AppColors.success : AppColors.danger,
                  ),
                ),
                if (!correct) ...[
                  const SizedBox(width: 12),
                  Text(
                    '正确答案：${_label(question.answer)}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.success,
                    ),
                  ),
                ],
              ],
            ),
            if (question.knowledge.isNotEmpty) ...[
              const SizedBox(height: 8),
              MathText(
                question.knowledge,
                style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ],
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

  /// 第 [i] 个选项是不是正确答案（与 [CheckinPreviewCard] 口径一致）。
  bool _isAnswer(int i, bool isJudge) {
    final answer = question.answer.trim().toUpperCase();
    if (isJudge) return answer == (i == 0 ? 'T' : 'F');
    return answer == String.fromCharCode(65 + i);
  }

  /// 第 [i] 个选项是不是学生选的那个。
  bool _isPick(int i, bool isJudge) {
    final p = picked.trim().toUpperCase();
    if (isJudge) return p == (i == 0 ? 'T' : 'F');
    return p == String.fromCharCode(65 + i);
  }

  /// T/F → 正确/错误；其它原样返回（字母选项）。
  String _label(String value) {
    final v = value.trim().toUpperCase();
    if (v == 'T') return '正确';
    if (v == 'F') return '错误';
    return value;
  }
}

/// 试卷排版下的一行选项。
///
/// 三态配色：
///   · 正确答案 → 绿（背景 10% + 绿边 + 绿勾）；
///   · 学生选错的那项 → 浅红（背景 10% + 红边 + 红叉）；
///   · 其它 → 默认灰边。
/// 选对时「学生选中的项」就是正确答案，所以只走绿色分支。
class _ResultOption extends StatelessWidget {
  const _ResultOption({
    required this.label,
    required this.text,
    required this.isAnswer,
    required this.isPick,
  });

  final String label;
  final String text;
  final bool isAnswer;
  final bool isPick;

  @override
  Widget build(BuildContext context) {
    final wrongPick = isPick && !isAnswer;
    final color = isAnswer
        ? AppColors.success
        : (wrongPick ? AppColors.danger : AppColors.border);
    final bg = isAnswer
        ? AppColors.success.withValues(alpha: 0.10)
        : (wrongPick
            ? AppColors.danger.withValues(alpha: 0.10)
            : Colors.transparent);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: isAnswer
                  ? AppColors.success
                  : (wrongPick ? AppColors.danger : AppColors.textMuted),
            ),
          ),
          const SizedBox(width: 10),
          if (text.isNotEmpty) Expanded(child: MathText(text)),
          if (isAnswer)
            const Icon(Icons.check, size: 16, color: AppColors.success)
          else if (wrongPick)
            const Icon(Icons.close, size: 16, color: AppColors.danger),
        ],
      ),
    );
  }
}
