import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/parent_controller.dart';
import '../../models/homework_image_batch.dart';
import '../../models/homework_model.dart';
import '../../models/review_model.dart';
import '../../utils/attachment_summary.dart';
import '../../utils/duration_text.dart';
import '../../widgets/grading_source_chip.dart';
import '../../widgets/homework_image_viewer.dart';
import '../../widgets/math_text.dart';
import '../../widgets/homework_status.dart';

/// 家长端作业详情页。
///
/// 为什么是独立页面而不是弹窗：家长要在这里做三件事 ——
/// 确认孩子交了没有、逐张看清照片上的字、看 AI 判出的错题。
/// 弹窗高度有限，照片放大后和列表挤在一起，体验很差。
class HomeworkDetailPage extends StatelessWidget {
  const HomeworkDetailPage({super.key, required this.homeworkId});

  final String homeworkId;

  static void open(String homeworkId) {
    Get.to(() => HomeworkDetailPage(homeworkId: homeworkId));
  }

  @override
  Widget build(BuildContext context) {
    final parent = Get.find<ParentController>();

    return Obx(() {
      final homework = parent.homeworkById(homeworkId);
      if (homework == null) {
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(title: const Text('作业详情')),
          body: const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                '该作业已不在结伴孩子的记录中，可能已被删除。',
                style: TextStyle(color: AppColors.textMuted),
              ),
            ),
          ),
        );
      }

      final batches = parent.imageBatchesOfHomework(homeworkId);
      final mistakes = parent.mistakesOfHomework(homeworkId);
      final childName = parent.boundStudents
          .where((c) => c.id == homework.studentId)
          .map((c) => c.name)
          .firstOrNull;

      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                homework.title,
                style: const TextStyle(fontSize: 16),
                overflow: TextOverflow.ellipsis,
              ),
              if (childName != null)
                Text(
                  childName,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textMuted,
                  ),
                ),
            ],
          ),
          actions: [HomeworkStatusChip(status: homework.status)],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          children: [
            _SubmissionBanner(homework: homework, batches: batches),
            const SizedBox(height: 14),
            _InfoCard(homework: homework),
            const SizedBox(height: 14),
            _PhotoSection(batches: batches),
            if (homework.hasResult) ...[
              const SizedBox(height: 14),
              _AiResultSection(homework: homework),
            ],
            const SizedBox(height: 14),
            _MistakeSection(mistakes: mistakes),
            const SizedBox(height: 18),
            const _ReadOnlyNote(),
          ],
        ),
      );
    });
  }
}

/// 提交情况横幅 —— 家长打开页面第一眼要看的就是这一块。
class _SubmissionBanner extends StatelessWidget {
  const _SubmissionBanner({required this.homework, required this.batches});

  final HomeworkItem homework;
  final List<HomeworkImageBatch> batches;

  @override
  Widget build(BuildContext context) {
    final submitted = homework.hasSubmission;
    // ⚠️ 这里算的是**附件**，不是照片：一次提交可以是 1 个视频。
    // 以前用 `batches.fold(count)` 直接说「N 张作业照片」，孩子交视频时
    // 家长会看到「共 1 张作业照片」——量词和事实都对不上。
    final summary = attachmentSummary(batches.expand((b) => b.images));
    final accent = submitted ? AppColors.success : AppColors.warning;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                submitted ? Icons.check_circle : Icons.schedule,
                color: accent,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  submitted ? '孩子已提交' : '孩子尚未提交',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            submitted
                ? '提交时间：${_formatDateTime(homework.submittedAt!)}'
                // 未提交时**刻意不显示 dueAt**。那个取值是学生打开作业页那一刻，
                // 不是任何人定下的期限；摆在家长眼前，他必然会当成期限来读。
                // 家长需要的是「交了没有 / 什么时候交的」，而这行上面已经答了。
                // 见 `doc/open-items.md` B26。
                : '孩子提交后，这里会显示提交时间',
            style: const TextStyle(fontSize: 13, color: AppColors.text),
          ),
          const SizedBox(height: 4),
          Text(
            summary.isEmpty
                ? (submitted ? '本次未上传作业附件' : '暂无作业附件')
                : '共 $summary'
                      '${batches.length > 1 ? '，分 ${batches.length} 次提交' : ''}',
            style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
          ),
          // 没有批改结果时，家长第一眼就会想「怎么没批」。
          // 答案必须出现在他看的第一块里，而不是折叠在下面那张信息表里 ——
          // 他要是没找到，下一步就是去问孩子，而孩子也不知道。
          if (submitted && !homework.gradingMode.willGrade) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline,
                  size: 14,
                  color: AppColors.textMuted,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    switch (homework.gradingMode) {
                      HomeworkGradingMode.notRequired =>
                        '这类作业交上来就算完成，不需要批改'
                            '（朗读、背诵、预习、默写、抄写这类没有可判的产出）。',
                      HomeworkGradingMode.unavailable =>
                        '本次没有批改：当前未开启 AI 批改。',
                      HomeworkGradingMode.auto => '',
                    },
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.homework});

  final HomeworkItem homework;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: '作业信息',
      child: Column(
        children: [
          _InfoRow(label: '科目', value: homework.subject.isEmpty ? '未填写' : homework.subject),
          // 「截止时间」这一行删掉了（2026-09-28）：它的取值是学生打开作业页
          // 那一刻，不是任何人定下的期限 —— 摆在家长眼前必然被当成期限读。
          // 家长要的信息是「交了没有 / 什么时候交的」，那两句在上面那块
          // 「孩子已提交 / 尚未提交」里。见 `doc/open-items.md` B26。
          _InfoRow(
            label: '预计耗时',
            value: '${homework.estimatedMinutes.toInt()} 分钟',
          ),
          // ⭐ 这个数**不是系统自动统计的**：它只在孩子做这份作业时
          // 打开了「专注计时」才会有 —— 孩子按下结束的那一刻，
          // 计时器把总时长写进这份作业。
          //
          // 所以「没有这个数」是常态，不是故障，界面上必须把它说成
          // 「孩子未开启计时」，**不能**显示成「0 分钟」：后者在家长眼里
          // 是一句断言（「孩子一秒没做」），而它实际表达的是「不知道」。
          // 这两者的区别正是「静默失败」最容易藏身的地方 —— 见学生端
          // 同一行的处理（`homework_tab.dart` 的 `if (item.hasActualTime)`）。
          _InfoRow(
            label: '实际用时',
            value: homework.hasActualTime
                ? formatStudyTime(homework.actualSeconds)
                : '孩子未开启计时',
            muted: !homework.hasActualTime,
          ),
          _InfoRow(
            label: '批改方式',
            // 一行说清「这份作业系统会不会批」。原来这里是
            //「AI 批改：已开启/未开启」，只回答了能力，没回答家长真正
            // 在问的那句「这次批了没有」—— 朗读作业的 AI 批改是开着的，
            // 但它本来就不需要批。
            value: homework.gradingMode.label,
          ),
          _InfoRow(
            label: '批改时间',
            value: homework.checkedAt == null
                // 「尚未批改」会让家长一直等一个不会来的结果；
                // 不批改的作业该说的是「—」。
                ? (homework.gradingMode.willGrade ? '尚未批改' : '—')
                : _formatDateTime(homework.checkedAt!),
          ),
        ],
      ),
    );
  }
}

/// 照片区：按提交批次分组。孩子更正后重交时，家长能对比改正前后。
class _PhotoSection extends StatelessWidget {
  const _PhotoSection({required this.batches});

  final List<HomeworkImageBatch> batches;

  @override
  Widget build(BuildContext context) {
    if (batches.isEmpty) {
      return const _SectionCard(
        title: '作业附件',
        child: HomeworkImageGrid(images: [], emptyHint: '孩子本次提交没有上传附件'),
      );
    }

    return _SectionCard(
      title: '作业附件',
      trailing: Text(
        '点开可查看或播放',
        style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < batches.length; i++) ...[
            if (batches.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        i == 0 ? '最近一次提交' : '第 ${batches.length - i} 次提交',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_formatDateTime(batches[i].submittedAt)} · '
                      '${attachmentSummary(batches[i].images)}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            HomeworkImageGrid(images: batches[i].images),
            if (i != batches.length - 1) const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}

class _AiResultSection extends StatelessWidget {
  const _AiResultSection({required this.homework});

  final HomeworkItem homework;

  @override
  Widget build(BuildContext context) {
    final hasMistakes = homework.wrongCount > 0;
    return _SectionCard(
      title: 'AI 批改结果',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 家长是「离开了这次调用的上下文」看结果的：他不知道孩子那边
          // 网络怎么样、模型开没开。不标出来的话，一份本地模板会被
          // 当成 AI 批改结论 —— 那是这套机制最不该漏掉的一头。
          if (homework.gradedLocally) ...[
            const LocalGradingChip(showNote: true),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              if (homework.score != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${homework.score} 分',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  hasMistakes
                      ? '发现 ${homework.wrongCount} 道错题，已进入孩子的错题本'
                      : '未发现错题',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: hasMistakes
                        ? AppColors.danger
                        : AppColors.success,
                  ),
                ),
              ),
            ],
          ),
          if (homework.summary.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                homework.summary,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.text,
                  height: 1.6,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MistakeSection extends StatelessWidget {
  const _MistakeSection({required this.mistakes});

  final List<ReviewMistake> mistakes;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: '本次产生的错题',
      trailing: mistakes.isEmpty
          ? null
          : Text(
              '${mistakes.length} 道',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.danger,
              ),
            ),
      child: mistakes.isEmpty
          ? const Text(
              '这份作业没有产生错题记录。',
              style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
            )
          : Column(
              children: [
                for (final mistake in mistakes) _MistakeRow(mistake: mistake),
              ],
            ),
    );
  }
}

class _MistakeRow extends StatelessWidget {
  const _MistakeRow({required this.mistake});

  final ReviewMistake mistake;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  mistake.title,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: (mistake.state == ReviewState.mastered
                          ? AppColors.success
                          : AppColors.warning)
                      .withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  mistake.state == ReviewState.mastered ? '已掌握' : '待复习',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: mistake.state == ReviewState.mastered
                        ? AppColors.success
                        : AppColors.warning,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // ⚠️ 这两行原来是纯 `Text`：模型给的 `$2x$`、`$20 \times 2+…$`
          // 会原样显示成美元符号加反斜杠。家长看到的「孩子的作答」和
          // 「错因」恰恰全是算式 —— 不渲染等于让这一块读不懂。
          MathText(
            '孩子的作答：${mistake.originalAnswer}',
            style: const TextStyle(fontSize: 12.5, height: 1.5, color: AppColors.text),
          ),
          const SizedBox(height: 4),
          MathText(
            '错因：${mistake.wrongReason}',
            style: const TextStyle(
              fontSize: 12.5,
              color: AppColors.textMuted,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadOnlyNote extends StatelessWidget {
  const _ReadOnlyNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Row(
        children: [
          Icon(Icons.visibility_outlined, size: 16, color: AppColors.primary),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '家长端为只读视图：你可以查看提交记录、附件与批改结果，'
              '但不能代替孩子提交或修改作业内容。',
              style: TextStyle(fontSize: 11.5, color: AppColors.text),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  /// [muted] 用来区分「有值」与「这项没有值」。
  ///
  /// ⚠️ 不能靠 value 的字面来判断：写成「未开启计时」和「32 分」在界面上
  /// 都是一行字，没有视觉差别时，家长会把「没有数据」读成一个事实。
  const _InfoRow({required this.label, required this.value, this.muted = false});

  final String label;
  final String value;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                // 没值的那一行**连字重一起降**：只改颜色的话，加粗的灰字
                // 看着仍像一个被强调的结论。
                fontWeight: muted ? FontWeight.w400 : FontWeight.w600,
                color: muted ? AppColors.textMuted : AppColors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${local.month}月${local.day}日 ${two(local.hour)}:${two(local.minute)}';
}
