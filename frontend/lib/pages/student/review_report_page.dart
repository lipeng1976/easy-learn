import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/review_controller.dart';
import '../../models/review_model.dart';
import '../../services/review_service.dart';
import 'widgets/review_badges.dart';

/// 学习报告页（周报 / 月报）。
///
/// 为什么单开一页而不是塞进复习页顶部：
/// 单卷报告回答的是「这一份卷子做得怎么样」，几分钟就看完；
/// 周期报告回答的是「这一段时间到底有没有在推进」——它需要横向对比
/// 分科表现、纵向看薄弱点的累积，信息量和单卷报告不是一个量级。
/// 塞在一起的结果是复习页越滚越长，两个问题都答不清。
class ReviewReportPage extends StatefulWidget {
  const ReviewReportPage({super.key});

  @override
  State<ReviewReportPage> createState() => _ReviewReportPageState();
}

class _ReviewReportPageState extends State<ReviewReportPage> {
  final ReviewController controller = Get.find<ReviewController>();

  @override
  void initState() {
    super.initState();
    // 报告依赖作答与讲解记录，进页面先确保是最新的。
    controller.loadReviewData();
  }

  Future<void> _save() async {
    final summary = await controller.saveReport(controller.reportScope.value);
    Get.snackbar('报告已保存', '已归档到 ${summary.scopeKey}');
  }

  Future<void> _copy(PeriodReport report) async {
    await Clipboard.setData(
      ClipboardData(text: controller.reportPlainText(report)),
    );
    Get.snackbar('已复制', '报告文字已复制到剪贴板，可直接发给家长');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('学习报告')),
      body: Obx(() {
        final scope = controller.reportScope.value;
        final report = controller.buildReport(scope);
        final stored = controller.storedReport(scope);
        final papers = _papersInWindow(report);

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            _scopeSwitch(scope),
            const SizedBox(height: 16),
            _SummaryCard(report: report),
            if (report.highlights.isNotEmpty) ...[
              const SizedBox(height: 16),
              _Section(
                title: '这段时间做成了什么',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: report.highlights
                      .map(
                        (text) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                padding: EdgeInsets.only(top: 2),
                                child: Icon(
                                  Icons.check_circle,
                                  size: 15,
                                  color: AppColors.success,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  text,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
            const SizedBox(height: 16),
            _Section(
              title: '分科情况',
              child: _subjectBreakdown(report),
            ),
            if (report.weakPoints.isNotEmpty) ...[
              const SizedBox(height: 16),
              _Section(
                title: '薄弱知识点',
                subtitle: '按这周期错得最多的知识点排序',
                child: _weakPoints(report),
              ),
            ],
            if (report.suggestions.isNotEmpty) ...[
              const SizedBox(height: 16),
              _Section(
                title: '下一步建议',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: report.suggestions
                      .map(
                        (text) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                padding: EdgeInsets.only(top: 2),
                                child: Icon(
                                  Icons.arrow_right_alt,
                                  size: 16,
                                  color: AppColors.primary,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  text,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
            if (papers.isNotEmpty) ...[
              const SizedBox(height: 16),
              _Section(
                title: '本周期资料',
                child: Column(
                  children: papers
                      .map((paper) => _PaperRow(paper: paper))
                      .toList(),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _copy(report),
                    icon: const Icon(Icons.copy_all_outlined, size: 17),
                    label: const Text('复制报告'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.archive_outlined, size: 17),
                    label: Text(stored == null ? '保存归档' : '更新归档'),
                  ),
                ),
              ],
            ),
            if (stored != null) ...[
              const SizedBox(height: 10),
              Text(
                '上次归档：${_formatDateTime(stored.generatedAt)}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ],
        );
      }),
    );
  }

  /// 报告窗口内发生的资料，按批改时间/生成时间归入。
  List<ReviewPaper> _papersInWindow(PeriodReport report) {
    final list = controller.papers.where((paper) {
      final at = paper.gradedAt ?? paper.exportedAt ?? paper.createdAt;
      return !at.isBefore(report.start) && !at.isAfter(report.end);
    }).toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Widget _scopeSwitch(SummaryScope scope) {
    final options = [
      (SummaryScope.week, '本周'),
      (SummaryScope.month, '本月'),
    ];
    return Row(
      children: options.map((option) {
        final active = scope == option.$1;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: option.$1 == SummaryScope.month ? 0 : 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => controller.setReportScope(option.$1),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  color: active
                      ? AppColors.primary.withValues(alpha: 0.1)
                      : AppColors.card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: active ? AppColors.primary : AppColors.border,
                  ),
                ),
                child: Text(
                  option.$2,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: active ? AppColors.primary : AppColors.textMuted,
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _subjectBreakdown(PeriodReport report) {
    if (report.subjectAttempts.isEmpty) {
      return const Text(
        '本周期还没有作答记录。',
        style: TextStyle(fontSize: 13, color: AppColors.textMuted),
      );
    }
    final subjects = report.subjectAttempts.keys.toList()..sort();
    return Column(
      children: subjects.map((subject) {
        final attempts = report.subjectAttempts[subject] ?? 0;
        final passes = report.subjectPasses[subject] ?? 0;
        final rate = attempts == 0 ? 0.0 : passes / attempts;
        final color = performanceColor(rate);
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      subject.isEmpty ? '未标注科目' : subject,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '通过 $passes / 作答 $attempts',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: rate,
                  minHeight: 7,
                  backgroundColor: AppColors.border,
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _weakPoints(PeriodReport report) {
    return Column(
      children: report.weakPoints.map((point) {
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.danger.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.danger.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      point.name,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '涉及 ${point.mistakeCount} 道题 · 共错 ${point.wrongCount} 次',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              ReviewTag(
                text: point.subject.isEmpty ? '未标注' : point.subject,
                color: AppColors.textMuted,
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.report});

  final PeriodReport report;

  @override
  Widget build(BuildContext context) {
    final color = performanceColor(report.passRate);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${report.title} · ${_formatRange(report.start, report.end)}',
            style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${(report.passRate * 100).round()}',
                style: TextStyle(
                  fontSize: 40,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(left: 2, bottom: 4),
                child: Text(
                  '%',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text(
                  '通过率',
                  style: TextStyle(fontSize: 13, color: AppColors.textMuted),
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '作答 ${report.passCount}/${report.attemptCount}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '通过率按「作答次数」计算：反复错的题做几轮，分母就记几次',
            style: TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _metric('毕业', report.graduatedCount, AppColors.success),
              _metric('自评掌握', report.selfMasteredCount, AppColors.textMuted),
              _metric('在池', report.poolRemain, AppColors.warning),
              _metric('复习天数', report.activeDays, AppColors.primary),
            ],
          ),
          if (report.selfMasteredRatio > 0.5) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                '自评掌握占了掌握总数的一半以上。自评没有作答证据，'
                '不计入通过率 —— 挑两道补一次实际作答，掌握率才站得住。',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _metric(String label, int value, Color color) => Expanded(
    child: Column(
      children: [
        Text(
          '$value',
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
        ),
      ],
    ),
  );
}

class _PaperRow extends StatelessWidget {
  const _PaperRow({required this.paper});

  final ReviewPaper paper;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  paper.title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              PaperStatusBadge(status: paper.status),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            paper.status == PaperStatus.graded
                ? '${paper.itemCount} 道题 · 通过 ${paper.passCount} / 未通过 ${paper.failCount}'
                : '${paper.itemCount} 道题 · 尚未批改',
            style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, this.subtitle, required this.child});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

String _formatRange(DateTime start, DateTime end) {
  final s = start.toLocal();
  final e = end.toLocal();
  return '${s.month}月${s.day}日 - ${e.month}月${e.day}日';
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${local.month}月${local.day}日 ${two(local.hour)}:${two(local.minute)}';
}
