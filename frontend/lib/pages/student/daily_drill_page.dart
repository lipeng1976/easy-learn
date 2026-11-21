import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/drill_controller.dart';
import '../../models/drill_question.dart';
import '../../utils/drill_selector.dart';
import '../../widgets/math_text.dart';

/// 学生端「每日概念训练」页。
///
/// 一页三态：**答题中 / 已提交（看结果与解析）/ 加载中**。
/// 三态用 [DrillController.submitted] 一个开关切，而不是三个页面 ——
/// 同一组题从「做」到「对答案」不该让人跳出再进来。
class DailyDrillPage extends StatefulWidget {
  const DailyDrillPage({super.key});

  @override
  State<DailyDrillPage> createState() => _DailyDrillPageState();
}

class _DailyDrillPageState extends State<DailyDrillPage> {
  late final DrillController _controller;

  @override
  void initState() {
    super.initState();
    _controller = Get.find<DrillController>();
    // 深链进来（入口卡直接开本页）时题组可能还没加载。
    // 重复调用是安全的：控制器对「已在答题中」有守卫，不会清掉已选的选项。
    _controller.loadToday();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('今日概念训练'),
        actions: [
          // 连续天数放这里而不是页头卡片里：它是状态不是操作，
          // 放 AppBar 不占正文空间，也不会和「已答 x/6」抢注意力。
          Obx(
            () => controller.streak.value > 0
                ? Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Center(
                      child: Text(
                        '连续 ${controller.streak.value} 天',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
      body: Obx(() {
        if (controller.isLoading.value && controller.today.value == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final failure = controller.failure.value;
        if (controller.today.value == null) {
          return _EmptyState(
            message: failure ?? '今天还没有题组',
            onRetry: controller.retry,
          );
        }
        final drill = controller.today.value!;
        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  _HeaderCard(drill: drill, controller: controller),
                  const SizedBox(height: 12),
                  ...drill.questions.map(
                    (q) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: controller.submitted.value
                          ? _ResultCard(
                              question: q,
                              controller: controller,
                            )
                          : _QuestionCard(
                              question: q,
                              controller: controller,
                            ),
                    ),
                  ),
                ],
              ),
            ),
            if (!controller.submitted.value)
              _SubmitBar(controller: controller),
          ],
        );
      }),
    );
  }
}

/// 页头：日期 + 训练目标 + 进度。
class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.drill, required this.controller});

  final DailyDrill drill;
  final DrillController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.translate,
                size: 17,
                color: AppColors.primary,
              ),
              const SizedBox(width: 7),
              Text(
                '${drill.date} · 把文字翻译成数学式子',
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            controller.submitted.value
                ? '已提交：答对 ${controller.correctCount}/${drill.questions.length}。往下翻可以看每题的思路。'
                : '先读懂文字，再选式子 —— 不会算没关系，选对「哪句话该写成什么」。',
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: AppColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// 答题中的一道题：题干 + 四个可选项。
class _QuestionCard extends StatelessWidget {
  const _QuestionCard({required this.question, required this.controller});

  final DrillQuestion question;
  final DrillController controller;

  @override
  Widget build(BuildContext context) {
    final index = controller.today.value!.questions.indexOf(question);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '第 ${index + 1} 题',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _TierTag(tier: question.tier),
            ],
          ),
          const SizedBox(height: 10),
          MathText(
            question.stem,
            style: const TextStyle(
              fontSize: 14.5,
              height: 1.55,
              color: AppColors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          ...List.generate(4, (i) {
            final selected = controller.chosen[question.id] == i;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => controller.select(question.id, i),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? AppColors.primary.withValues(alpha: 0.08)
                        : AppColors.background,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected
                          ? AppColors.primary
                          : AppColors.border,
                      width: selected ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 22,
                        height: 22,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: selected
                              ? AppColors.primary
                              : AppColors.border,
                        ),
                        child: Text(
                          String.fromCharCode(65 + i),
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: selected
                                ? Colors.white
                                : AppColors.textMuted,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: MathText(
                          question.options[i],
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.4,
                            color: selected
                                ? AppColors.primaryDark
                                : AppColors.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

/// 已提交的一道题：对错 + 正确答案 + 四步法解析。
class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.question, required this.controller});

  final DrillQuestion question;
  final DrillController controller;

  @override
  Widget build(BuildContext context) {
    final result = controller.resultOf(question.id);
    final ok = result?.correct ?? false;
    final picked = result?.chosenIndex ?? -1;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: ok ? AppColors.success.withValues(alpha: 0.5) : AppColors.danger.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                ok ? Icons.check_circle : Icons.cancel,
                size: 18,
                color: ok ? AppColors.success : AppColors.danger,
              ),
              const SizedBox(width: 6),
              Text(
                ok ? '答对了' : '答错了',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: ok ? AppColors.success : AppColors.danger,
                ),
              ),
              const Spacer(),
              _TierTag(tier: question.tier),
            ],
          ),
          const SizedBox(height: 8),
          MathText(
            question.stem,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 8),
          if (!ok && picked >= 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  const Text(
                    '你选的：',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                  Expanded(
                    child: MathText(
                      question.options[picked],
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              Text(
                ok ? '你选的：' : '正确答案：',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text,
                ),
              ),
              Expanded(
                child: MathText(
                  question.options[question.answerIndex],
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: ok ? AppColors.success : AppColors.primaryDark,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _ExplainBlock(explain: question.explain),
        ],
      ),
    );
  }
}

/// 四步法解析块。
class _ExplainBlock extends StatelessWidget {
  const _ExplainBlock({required this.explain});

  final DrillExplain explain;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _step('① 找主体', explain.subject),
          _step('② 找数值', explain.numbers),
          _step('③ 找关系', explain.relation),
          _step('④ 找目标', explain.goal),
          const Divider(height: 14, color: AppColors.border),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.lightbulb_outline,
                size: 15,
                color: AppColors.warning,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: MathText(
                  explain.pitfall,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: AppColors.text,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _step(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 62,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.primary,
            ),
          ),
        ),
        Expanded(
          child: MathText(
            value,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: AppColors.text,
            ),
          ),
        ),
      ],
    ),
  );
}

/// 底部提交条：进度 + 提交按钮。
class _SubmitBar extends StatelessWidget {
  const _SubmitBar({required this.controller});

  final DrillController controller;

  @override
  Widget build(BuildContext context) {
    final total = controller.today.value?.questions.length ?? 0;
    final done = controller.answeredCount;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: const BoxDecoration(
          color: AppColors.card,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: total == 0 ? 0 : done / total,
                      minHeight: 7,
                      backgroundColor: AppColors.border,
                      valueColor: AlwaysStoppedAnimation(
                        done == total ? AppColors.success : AppColors.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '已答 $done/$total',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: done == total ? () => _submit(context) : null,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('提交，看解析'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit(BuildContext context) async {
    final result = await controller.submit();
    if (!context.mounted) return;
    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message)),
      );
    }
  }
}

class _TierTag extends StatelessWidget {
  const _TierTag({required this.tier});

  final DrillTier tier;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (tier) {
      DrillTier.basic => ('基础', AppColors.accent),
      DrillTier.advanced => ('进阶', AppColors.primary),
      DrillTier.composite => ('综合', AppColors.warning),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.quiz_outlined,
              size: 44,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13.5,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
