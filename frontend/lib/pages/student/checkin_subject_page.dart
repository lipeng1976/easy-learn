import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../constants/subject_colors.dart';
import '../../controllers/checkin_controller.dart';
import '../../models/checkin_models.dart';
import '../../repositories/checkin_repository.dart';
import '../../services/database_service.dart';
import '../../utils/checkin_label.dart';
import '../../widgets/checkin_result_paper_card.dart';

/// 某一科的**已完成打卡记录**（学生端「已完成」色块点进来的页面）。
///
/// ## 为什么单独一页，而不是在首页展开
///
/// 首页要回答的是「今天还有几件事」，不是「这一科我做过多少套」。把记录
/// 铺在首页，等于让历史成绩把今天要做的事推到屏幕外 —— 这正是 10-29 分区
/// 要解决的老问题。所以首页只放**科目 + 份数 + 最近一次成绩**，
/// 明细（每份的日期、题量、得分、逐题回放）放在这里。
///
/// ## 分页是服务端做的
///
/// `subject` 参数直接下到 SQL（见 `GET /data/checkin/quiz`）。不要在客户端
/// 拉全量再 filter：几十份卷子每份都带题干与解析，弱网下就是一个大响应，
/// 而这条链路已经被「大响应卡死」坑过一次。
///
/// ## 详情在页内展开，不再跳第三层
///
/// 点一份 → 页内切成「成绩单 + 逐题回放」，顶部给「返回记录列表」。
/// 再 push 一个页面的下场是返回路径变成三层，而孩子只是想看一眼那套错在哪。
class CheckinSubjectPage extends StatefulWidget {
  const CheckinSubjectPage({
    super.key,
    required this.subject,
    this.repository,
  });

  final String subject;

  /// 只在测试里传。线上走 [DatabaseService.checkin]。
  final CheckinRepository? repository;

  @override
  State<CheckinSubjectPage> createState() => _CheckinSubjectPageState();
}

class _CheckinSubjectPageState extends State<CheckinSubjectPage> {
  static const int _pageSize = 10;

  late final CheckinRepository _repo =
      widget.repository ?? DatabaseService.checkin;

  final List<CheckinQuiz> _items = <CheckinQuiz>[];
  int _total = 0;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  /// 展开的那一份（`null` = 记录列表）。
  String? _openId;

  /// 列表滚动位置：从详情返回时不要跳回顶部。
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String? get _studentId => CheckinController.targetStudentId();

  Future<void> _load({required bool reset}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      if (_loadingMore || !_hasMore) return;
      setState(() => _loadingMore = true);
    }
    try {
      final page = await _repo.getQuizzes(
        studentId: _studentId,
        status: CheckinQuizStatus.done,
        subject: widget.subject,
        limit: _pageSize,
        offset: reset ? 0 : _items.length,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _items.clear();
        // 去重：翻页期间可能有一份被别处改过（交卷/重出），同 id 插两次
        // 会让列表在滚动时跳一下，而且没人说得清为什么。
        final seen = {for (final one in _items) one.id};
        _items.addAll(page.items.where((one) => !seen.contains(one.id)));
        _total = page.total;
        _hasMore = page.hasMore;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _describe(e));
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  /// 失败原因说人话。管理员看到英文错误码没用，孩子看到更没用。
  static String _describe(Object e) {
    final text = e.toString();
    if (text.contains('unavailable')) return '当前是本地模式，打卡记录需要联网。';
    if (text.contains('timeout')) return '网络有点慢，下拉重进一次试试。';
    return text.length > 80 ? '${text.substring(0, 80)}…' : text;
  }

  @override
  Widget build(BuildContext context) {
    final color = subjectColor(widget.subject);
    // 手写循环而不是 `firstOrNull`：那是 package:collection 的扩展，
    // 为一个查找引一个包不划算（而且这里 `_items` 最多几十条）。
    CheckinQuiz? open;
    if (_openId != null) {
      for (final one in _items) {
        if (one.id == _openId) {
          open = one;
          break;
        }
      }
    }

    return PopScope<Object?>(
      // 系统返回键先回记录列表，而不是一脚退出这一科 —— 与打卡页同一条理由。
      canPop: open == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() => _openId = null);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('${widget.subject} · 打卡记录'),
          leading: open == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '返回记录列表',
                  onPressed: () => setState(() => _openId = null),
                ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : open != null
                ? _detail(open, color)
                : _list(color),
      ),
    );
  }

  // ===== 记录列表 =====

  Widget _list(Color color) {
    return RefreshIndicator(
      // 下拉刷新：家长重出一份、或孩子刚交卷，回到这一页时数字该更新。
      onRefresh: () => _load(reset: true),
      child: ListView(
        controller: _scroll,
        // 内容不满一屏时也要能下拉：`RefreshIndicator` 在没有可滚动区域时
        // 不会触发，家长会以为「下拉没反应」。
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _header(color),
          if (_error != null) ...[
            const SizedBox(height: 10),
            _errorBanner(),
          ],
          const SizedBox(height: 12),
          if (_items.isEmpty && _error == null)
            _empty(color)
          else
            for (final one in _items) _row(one, color),
          if (_hasMore) _loadMore(),
        ],
      ),
    );
  }

  Widget _header(Color color) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(
          widget.subject,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color),
        ),
        const SizedBox(width: 8),
        Text(
          '共 $_total 份',
          style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
        ),
      ],
    );
  }

  Widget _row(CheckinQuiz quiz, Color color) {
    final result = quiz.submittedResult;
    final score = result == null ? '—' : '${result.score}/${result.total}';
    final meta = [
      checkinShortDate(quiz.quizDate),
      if (quiz.difficulty.isNotEmpty) quiz.difficulty,
      '共 ${quiz.total} 题',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => _openId = quiz.id),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
            decoration: BoxDecoration(
              border: Border.all(color: color.withValues(alpha: 0.28)),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        meta,
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        result == null ? '没有成绩存档' : '做完 ${result.total} 题',
                        style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    score,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right, size: 18, color: AppColors.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _empty(Color color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Icon(Icons.inbox_outlined, size: 34, color: color.withValues(alpha: 0.6)),
          const SizedBox(height: 10),
          Text(
            '还没有做完的${widget.subject}打卡',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text(
            '交卷之后会出现在这里，可以回来翻每一套的答案',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _loadMore() {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: _loadingMore ? null : () => _load(reset: false),
          child: _loadingMore
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('加载更多'),
        ),
      ),
    );
  }

  Widget _errorBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Text(
        _error!,
        style: const TextStyle(fontSize: 12.5, color: AppColors.warning),
      ),
    );
  }

  // ===== 单套详情 =====

  Widget _detail(CheckinQuiz quiz, Color color) {
    final result = quiz.submittedResult;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        // 「返回记录列表」——AppBar 的返回箭头也指这里，两个入口同一行为。
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _openId = null),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Row(
                children: [
                  const Icon(Icons.list_alt, size: 16, color: AppColors.textMuted),
                  const SizedBox(width: 6),
                  Text(
                    '记录列表（共 $_total 套）',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (result == null)
          const Text('这一套没有成绩存档')
        else ...[
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Text(
                    '${result.score}',
                    style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(width: 4),
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text(
                      '/ ${result.total}',
                      style: const TextStyle(fontSize: 18, color: AppColors.textMuted),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    checkinShortDate(quiz.quizDate),
                    style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          for (final item in result.items)
            if (item.index >= 0 && item.index < quiz.questions.length)
              CheckinResultPaperCard(
                index: item.index,
                question: quiz.questions[item.index],
                picked: item.picked,
                correct: item.correct,
              ),
        ],
      ],
    );
  }
}
