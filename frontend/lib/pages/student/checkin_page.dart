import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../constants/subject_colors.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/checkin_controller.dart';
import '../../models/checkin_models.dart';
import '../../repositories/checkin_repository.dart';
import '../../services/checkin_question_parser.dart';
import '../../utils/checkin_label.dart';
import '../../widgets/checkin_preview_card.dart';
import '../../widgets/checkin_question_card.dart';
import '../../widgets/checkin_result_paper_card.dart';

/// 每日概念打卡页。
///
/// ## 一天可以有多份试卷（不按科目排他）
///
/// 家长每出一次题就是**一份独立试卷**：同一天、同一科目也可以有好几套
/// （2026-10-27 起，不再"一天一科目只许一份"）。每份的题、作答、成绩
/// 互不干扰；家长点「再出一组」只会**新增**一份，绝不动作已有的那几份。
///
/// ## 两层：任务清单 → 单套作答（2026-10-27 用户要求）
///
/// 只有一个任务时**直接展开**，孩子进来就能答，不用多点一次；
/// 有两个及以上时先给一张**任务清单**（一套一行：科目、难度、题量、
/// 待完成/得分），点哪一套才展开哪一套。
///
/// 为什么必须分层：多份平铺时「第一节 5 道题 + 第二节 5 道题」一路排下来，
/// 孩子滑到中间根本分不清自己在答哪一套，交卷按钮也不知道属于谁 ——
/// 用户原话是"看起来很不舒服"。
class CheckinPage extends StatefulWidget {
  const CheckinPage({super.key, this.repository, this.clock});

  /// 只在测试里传。线上走 [DatabaseService.checkin]（云模式是 HTTP 实现，
  /// 本地库模式是 `Unavailable`）。留这个口子而不是给控制器加全局开关：
  /// 「答题点了有没有反应」必须能真点一次验，而真跑要靠一份现成的题。
  final CheckinRepository? repository;

  /// 只在测试里传：把「今天」钉住，「今天完成」的分组才能定性验证。
  final DateTime Function()? clock;

  @override
  State<CheckinPage> createState() => _CheckinPageState();
}

class _CheckinPageState extends State<CheckinPage> {
  late final CheckinController controller;

  /// 清单态里被点开的那一份（`null` = 还在清单上）。
  ///
  /// 存 **id 而不是 [CheckinRun] 对象**：交卷失败走 404 时控制器会
  /// `load()` 重建整个 `runs`，旧对象就成了一份没人认领的残骸。
  /// 存 id 时重建后仍能找回那一份（找不到就自动退回清单）。
  ///
  /// 只有一份时不看这个字段 —— 一份直接展开，见 [build]。
  String? _openQuizId;

  void _openRun(String quizId) => setState(() => _openQuizId = quizId);

  void _backToList() => setState(() => _openQuizId = null);

  @override
  void initState() {
    super.initState();
    controller = Get.put(
      // 出题在服务端（`POST /data/checkin/generate`），页面不需要注入 AI 数据源。
      //
      // ⚠️ 题目里**有答案**（含 `analysis`），交卷时本机立刻判对错要用它。
      // 所以下面答题分支的渲染必须只碰 stem / options / knowledge ——
      // 任何把 `question.answer` 或 `question.analysis` 画进界面的改动，
      // 都等于把答案摆在孩子眼前。`test/checkin_question_card_test.dart` 守着这条。
      CheckinController(repository: widget.repository, clock: widget.clock),
    );
    controller.load(studentId: _targetStudentId());
  }

  @override
  void dispose() {
    Get.delete<CheckinController>(force: true);
    super.dispose();
  }

  /// 这份打卡挂在谁名下 —— 规则收在 `CheckinController.targetStudentId()`
  /// 单点里（入口卡 `CheckinEntryState` 用的必须是同一条，否则会出现
  /// 「卡查的是 A、题记在 B 名下」）。多孩子切换 UI 落地时只改那一处。
  String? _targetStudentId() => CheckinController.targetStudentId();

  bool _isParent() => Get.find<AuthController>().currentUser.value?.role == 'parent';

  /// 学生自发起：不指定知识点，由服务端按**教材章节 / 家长配的范围**挑。
  ///
  /// ⚠️ 不是错题本。错题本属于「复习」那条线：拿错题出计划题会让两条线
  /// 的来源混在一起，而界面上完全看不出来。
  Future<void> _startAuto() => controller.start(studentId: _targetStudentId());

  /// 家长发起：先去设置页选范围，再走**同一个** `start()`。
  ///
  /// 设置页只收集参数、不发起。分两处发起的话，「出题失败怎么提示」
  /// 要写两遍，而两边一定会长得不一样。
  Future<void> _openSetup() async {
    // ⚠️ 这里**不能**写 `Get.toNamed<CheckinSetup>`。
    //
    // GetX 4.7.3 的 `toNamed<T>` 最后一步是 `Navigator.pushNamed<T?>`
    // （`extension_navigation.dart:596`），而 `getPages` 造出来的路由恒为
    // `GetPageRoute<dynamic>` —— `Route<dynamic> as Route<CheckinSetup?>` 必抛
    // `_TypeError: type 'GetPageRoute<dynamic>' is not a subtype of ...`。
    //
    // 抛在手势回调里，界面表现就是「点了没反应」：没有红屏、没有日志浮层、
    // 页面也不动。2026-10-27 线上就是这么丢的（家长点「设置今天的题」）。
    // `test/checkin_page_test.dart` 守着这条：它真去点一次、再看设置页在不在。
    //
    // 结论：跳转别带类型参数，返回值在外面自己判类型。
    final result = await Get.toNamed(
      '/checkin-setup',
      arguments: _targetStudentId(),
    );
    final setup = result is CheckinSetup ? result : null;
    if (setup == null || !mounted) return;
    await controller.start(
      studentId: _targetStudentId(),
      subject: setup.subject,
      count: setup.count,
      knowledgePoints: setup.knowledgePoints,
      difficulty: setup.difficulty,
    );
  }

  @override
  Widget build(BuildContext context) {
    // ⚠️ 只用**一层** `Obx` 包住整个 `Scaffold`：清单态和详情态都要读
    // `pendingRuns` / `doneRuns` / `loading` / `error`，AppBar 标题也依赖
    // "在详情还是在清单"。拆成两层的话，AppBar 那个读就落在追踪区外面了。
    return Obx(() {
      final pending = controller.pendingRuns;
      final done = controller.doneRuns;
      final doneTotal = controller.doneTotal.value;
      final total = pending.length + doneTotal;
      // `.toList()` 而不是直接拿 RxList：读一次就把「汇总变了」登记进这个
      // Obx 的追踪区（直接持有对象引用是不记账的，交卷后色块数字不会变）。
      final summaries = controller.subjectSummaries.toList();
      final isParent = _isParent();

      // 「今天完成」按**交卷日**分组。已完成列表按交卷时间倒序，
      // 今天的那几份天然连在顶部；这里仍逐条判，不依赖排序性质——
      // 刚交卷插到头部的那一份、以及翻页追加的旧记录都不会分错。
      final todayKey = controller.today;
      final todayRuns = <CheckinRun>[];
      final olderRuns = <CheckinRun>[];
      for (final run in done) {
        final result = run.result.value;
        final key = result == null
            ? run.quiz.value.quizDate
            : checkinDoneDateKey(run.quiz.value, result);
        (key == todayKey ? todayRuns : olderRuns).add(run);
      }

      // `runFor` 找不到（那一份被 404 重拉冲掉了）就自动退回列表，
      // 不会卡在一个空白详情页上。
      final openRun = _openQuizId == null ? null : controller.runFor(_openQuizId!);
      final inDetail = openRun != null;

      return PopScope<Object?>(
        // 系统返回键先回列表，而不是一脚踢出打卡页 ——
        // 「退出去才发现还有一套没做」是多任务页最恼人的地方。
        canPop: !inDetail,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _backToList();
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(inDetail ? '${checkinSubjectLabel(openRun.quiz.value)}打卡' : '概念打卡'),
            leading: inDetail
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: _backToList,
                    tooltip: '返回列表',
                  )
                : null,
          ),
          body: controller.loading.value
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
                    _Header(date: controller.today),
                    if (controller.error.value != null) ...[
                      const SizedBox(height: 12),
                      _ErrorBanner(text: controller.error.value!),
                    ],
                    const SizedBox(height: 16),
                    // 三态：一份都没有 / 某一套的详情 / 列表（未完成 + 已完成）。
                    if (inDetail) ...[
                      _BackToListRow(onTap: _backToList, total: total),
                      // 状态读取在 `_RunSection` 自己的 Obx 里 —— 外层这个
                      // Obx 只负责构建组件对象，子组件 build 不在追踪区
                      // （B21 / 10-27 两课）。
                      _RunSection(
                        run: openRun,
                        controller: controller,
                        isParent: _isParent(),
                        // 「再出一组」= 再走一遍设置页，出一份**新的独立试卷**。
                        onAddAnother: _openSetup,
                        onOpenSetup: _openSetup,
                        onStartAuto: _startAuto,
                      ),
                    ] else if (total == 0) ...[
                      _EmptyCard(
                        // `busy` 必须在这里读、当参数传下去：外层 Obx 记账的
                        // 是**这一行**的读取。让 `_EmptyCard` 自己在 build 里读
                        // `controller.busy.value` 是不被追踪的 —— 点了「出 5 道题」
                        // 之后那几秒转圈不会出现，看起来还是「点了没反应」。
                        busy: controller.busy.value,
                        isParent: _isParent(),
                        onStart: _isParent() ? _openSetup : _startAuto,
                      ),
                    ] else ...[
                      // 未完成在上：孩子进门先看「还有什么要做」。
                      _SectionHeader(
                        title: '未完成',
                        count: pending.length,
                        color: AppColors.success,
                      ),
                      if (pending.isEmpty)
                        const _AllDoneRow()
                      else
                        for (final run in pending)
                          _TaskTile(
                            run: run,
                            isParent: _isParent(),
                            // 科目显示在标题上，点进去的是**这一份**。
                            onOpen: () => _openRun(run.quiz.value.id),
                          ),
                      if (done.isNotEmpty || doneTotal > 0) ...[
                        const SizedBox(height: 10),
                        _SectionHeader(
                          title: '已完成',
                          count: doneTotal,
                          color: AppColors.textMuted,
                        ),
                        // 学生：按科目分组的大色块（点进去才是明细）。
                        // 家长：保持时间倒序的平铺列表 —— 他要看的是「最近
                        // 孩子做了什么」，按科目分组反而多一次点击。
                        //
                        // 汇总拿不到（老服务端 404 / 断网）时退回平铺列表：
                        // 显示「已完成 12 份」却一块色块都没有，比旧版更糟。
                        if (!isParent && summaries.isNotEmpty)
                          _DoneSubjectTiles(
                            summaries: summaries,
                            // 走命名路由：页面自己不去猜「这一科是谁的」，
                            // 科目由这里传；测试也能用假仓库挂同一条路由。
                            onOpen: (one) => Get.toNamed(
                              '/checkin-subject',
                              arguments: one.subject,
                            ),
                          )
                        else ...[
                          if (todayRuns.isNotEmpty)
                            _TodayDoneBox(
                              count: todayRuns.length,
                              exact: olderRuns.isNotEmpty ||
                                  !controller.doneHasMore.value,
                              tiles: [
                                for (final run in todayRuns)
                                  _TaskTile(
                                    run: run,
                                    isParent: isParent,
                                    onOpen: () => _openRun(run.quiz.value.id),
                                  ),
                              ],
                            ),
                          for (final run in olderRuns)
                            _TaskTile(
                              run: run,
                              isParent: isParent,
                              onOpen: () => _openRun(run.quiz.value.id),
                            ),
                          // 「加载更多」只在真还有下一页时出现 —— 一直挂着的按钮
                          // 会让人以为还能翻，点下去没反应（静默失败的老套路）。
                          if (controller.doneHasMore.value)
                            _LoadMoreButton(
                              loading: controller.loadingMore.value,
                              onTap: () =>
                                  controller.loadMoreDone(studentId: _targetStudentId()),
                            ),
                        ],
                      ],
                      const SizedBox(height: 10),
                      if (_isParent())
                        // 已有打卡时家长「再出一组」的入口。
                        _AddAnotherCard(
                          busy: controller.busy.value,
                          onStart: _openSetup,
                        ),
                    ],
                  ],
                ),
        ),
      );
    });
  }
}

/// 一份打卡的一节：头部（科目 · 难度 · 题量）+ 三态之一。
///
/// ## ⚠️ 三态分支必须包在自己的 Obx 里
///
/// `run.submitted`、`run.quiz.value` 这些读取如果写在外层页面的 Obx 里，
/// 外层只会在**构造这个组件对象**时读一次；组件自己的 Element 重建时
/// 读到的值没人记账 —— 结果就是「交了卷界面还停在答题态」。
class _RunSection extends StatelessWidget {
  const _RunSection({
    required this.run,
    required this.controller,
    required this.isParent,
    required this.onAddAnother,
    required this.onOpenSetup,
    required this.onStartAuto,
  });

  final CheckinRun run;
  final CheckinController controller;
  final bool isParent;

  /// 「再出一组」：再出一份新卷，旧卷与旧成绩原样保留。
  final Future<void> Function() onAddAnother;
  final Future<void> Function() onOpenSetup;
  final Future<void> Function() onStartAuto;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final quiz = run.quiz.value;
      final subject = checkinSubjectLabel(quiz);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.fact_check_outlined,
                  size: 18, color: AppColors.primary),
              const SizedBox(width: 6),
              Text(
                subject,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
              const Spacer(),
              Text(
                run.submitted ? '已完成' : '待完成',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: run.submitted ? AppColors.textMuted : AppColors.success,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (run.submitted)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ResultCard(
                  result: run.result.value!,
                  questions: quiz.questions,
                  syncError: run.syncError.value,
                  onRetry: () => controller.retrySync(run),
                ),
                // 🔴 「再出一组」必须出现在交卷之后。
                // 只有一份卷时页面直接展开这一份、不进清单；原先出题入口只在
                // 「未交卷（_ParentPreview）」和「多份清单（_AddAnotherCard）」
                // 两处，于是**今天唯一那份交了卷，整页就再没有出题按钮**——
                // 而这恰恰是最想再练一套的时刻（看到 3/8 才想再来一套）。
                // 2026-10-28 用户报「出题功能不见了」就是这条。
                if (isParent) ...[
                  const SizedBox(height: 16),
                  _AddAnotherCard(
                    busy: controller.busy.value,
                    onStart: onOpenSetup,
                  ),
                ],
              ],
            )
          else if (isParent)
            // 家长看到的是**预览**（题干 + 正确答案 + 解析），不是答题卡：
            // 题要孩子自己做，但家长得知道今天考了什么、答案是什么，
            // 否则「辅导」这件事无从下手。学生端走下面的 _QuizBody，
            // 那边绝不渲染答案。
            _ParentPreview(
              quiz: quiz,
              busy: run.busy.value,
              onAddAnother: onAddAnother,
            )
          else if (quiz.total > 0)
            _QuizBody(run: run, controller: controller)
          else
            _EmptyCard(
              busy: controller.busy.value,
              isParent: isParent,
              onStart: isParent ? onOpenSetup : onStartAuto,
            ),
          const SizedBox(height: 20),
        ],
      );
    });
  }
}

/// 分区标题：`未完成 2 份` / `已完成 12 份`。
///
/// 数字由页面在自己的 `Obx` 里数好传进来 —— 这里只负责画。
///
/// 为什么要把两半分开写标题：跨天之后列表会越滚越长（家长出过的题一直
/// 留着），不分区的结果就是「做过的」把「要做的」压到屏幕外面 ——
/// 孩子根本找不到今天该做哪一份。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.count,
    required this.color,
  });

  final String title;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(width: 3, height: 14, color: color),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(width: 6),
          Text(
            '$count 份',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「今天完成」的方框：把交卷日在今天的几份整体框起来。
///
/// 份数只在**确定到底**时写 `N 份`：已完成是服务端分页的，第一页全是今天
/// 且还有下一页时，后面可能仍有今天的份，写成 `N 份` 就是「数学 12 份被
/// 显示成 7 份」那类静默错误。这时写 `N+ 份`（至少 N 份）。
class _TodayDoneBox extends StatelessWidget {
  const _TodayDoneBox({
    required this.count,
    required this.exact,
    required this.tiles,
  });

  final int count;
  final bool exact;
  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('checkin_today_done_box'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.035),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.55),
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                const Icon(Icons.today, size: 16, color: AppColors.primary),
                const SizedBox(width: 6),
                const Text(
                  '今天完成',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primaryDark,
                  ),
                ),
                const Spacer(),
                Text(
                  exact ? '$count 份' : '$count+ 份',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          ...tiles,
        ],
      ),
    );
  }
}

/// 未完成区为空时的占位（已完成那边还有东西）。
///
/// 不能整块不画：那样「未完成」标题下面直接接「已完成」，看起来像标题
/// 属于下面那一区。写完这一行，孩子一眼知道「今天没作业」。
class _AllDoneRow extends StatelessWidget {
  const _AllDoneRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 2),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline, size: 16, color: AppColors.success),
          const SizedBox(width: 6),
          Text(
            '没有要做的题，都完成了',
            style: TextStyle(fontSize: 13, color: AppColors.textMuted.withValues(alpha: 1)),
          ),
        ],
      ),
    );
  }
}

/// 「加载更多」—— 已完成列表翻页。
///
/// 只在 `doneHasMore` 为真时出现。加载中要禁用并转圈：不然连点几下会
/// 用同一个 offset 发好几次请求，回来插一批重复项（列表会跳）。
class _LoadMoreButton extends StatelessWidget {
  const _LoadMoreButton({required this.loading, required this.onTap});

  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: loading ? null : onTap,
          child: loading
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
}

/// 任务清单里的一条 —— **一套试卷一行**。
///
/// ## 为什么清单里不铺题目
///
/// 多份平铺时「第一节 5 道题 + 第二节 5 道题」一路排下去，孩子滑到中间
/// 分不清自己在答哪一套，交卷按钮也不知道属于谁。清单只放挑卷要用的
/// 骨感信息（科目 / 难度 / 题量 / 待完成或得分），点哪一套才展开哪一套 ——
/// **一次只答一套**，题和交卷按钮永远在同一屏里。
class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.run,
    required this.isParent,
    required this.onOpen,
  });

  final CheckinRun run;
  final bool isParent;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    // ⚠️ `result` / `quiz` 是**内层** Rx，必须在这个组件自己的 Obx 里读。
    // 写在外层页面的 Obx 里只会记账一次，交卷后清单上的状态不会变（B21）。
    return Obx(() {
      final quiz = run.quiz.value;
      final result = run.result.value;
      final submitted = result != null;
      // 日期必须有：跨天之后列表里可能同时躺着上周和这周的卷子，
      // 只写「数学 · 共 5 题」的话，孩子分不清哪份是新的。
      // 已完成这一行显示**交卷日**，未完成显示出题日。框按交卷日分组，
      // 已完成行若仍写出题日，就会出现「今天完成的框里标着 11-14」。
      final dateKey = result == null
          ? quiz.quizDate
          : checkinDoneDateKey(quiz, result);
      final meta = [
        checkinShortDate(dateKey),
        if (quiz.difficulty.isNotEmpty) quiz.difficulty,
        '共 ${quiz.total} 题',
      ].join(' · ');
      final subject = checkinSubjectLabel(quiz);
      // 科目色：与家长端「今天练什么」的色块、与配置页同一套配色。
      // 未完成区仍是**一行一份**（孩子要一眼看出还有几份要做），
      // 但每行带上本科目的颜色 —— 同一科的两份一眼认得出是一科。
      final color = subjectColor(subject);
      // 家长点进去看的是**带答案的预览**（要辅导），措辞别写成「去做」。
      final action = submitted ? '看成绩' : (isParent ? '看题目' : '去做');
      final badge = submitted
          ? '${result.score}/${result.total}'
          : '待完成';
      final badgeColor = submitted ? AppColors.primary : AppColors.success;

      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onOpen,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  // 科目色块：一份一行时，靠颜色比靠读字更快认出来。
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      // 0.12 → 0.18：淡蓝灰的页面底色上，12% 的科目色
                      // 几乎看不出色相（数学那块最明显）。
                      color: color.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      subject.substring(0, 1),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: color,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                subject,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _Tag(text: badge, color: badgeColor),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          meta,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    action,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 18,
                      color: AppColors.textMuted),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}

/// 「已完成」按科目分组的色块（学生端）。
///
/// ## 为什么这里是色块，未完成那边是一行一份
///
/// 未完成回答的是「今天还有几件事」，一行一份才能一眼数清；已完成回答的是
/// 「我在哪科练了多少」，同一科的十几份堆成十几行只会把页面拉长，而没有
/// 任何新信息。所以这里聚合到科目，**点进去**才是每份的日期、得分与逐题回放。
///
/// ## 数字必须是真的
///
/// 份数来自服务端 `group by`（见 `CheckinSubjectSummary`），不是数已加载的
/// 那一页 —— 后者在分页 10 条时会把「数学 12 份」显示成「数学 7 份」，
/// 而且不报错。
class _DoneSubjectTiles extends StatelessWidget {
  const _DoneSubjectTiles({required this.summaries, required this.onOpen});

  final List<CheckinSubjectSummary> summaries;
  final void Function(CheckinSubjectSummary summary) onOpen;

  @override
  Widget build(BuildContext context) {
    // 两列配对。写成 [[a,b],[c,d]] 而不是用 GridView：外层已经是 ListView，
    // 嵌套一个可滚动网格要么拿到无限高、要么得 shrinkWrap（性能与嵌套滚动都埋坑）。
    final rows = <List<CheckinSubjectSummary>>[];
    for (var i = 0; i < summaries.length; i += 2) {
      rows.add(summaries.sublist(
        i,
        i + 2 > summaries.length ? summaries.length : i + 2,
      ));
    }

    return Column(
      children: [
        for (var r = 0; r < rows.length; r++) ...[
          // IntrinsicHeight：同一行两块等高（内容长短不一），同时给出确定高度
          // —— 直接 `stretch` 在 ListView 里会拿到无限高约束，整页抛
          // `BoxConstraints forces an infinite height`（11-12 家长端踩过）。
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var c = 0; c < rows[r].length; c++) ...[
                  if (c > 0) const SizedBox(width: 10),
                  Expanded(child: _tile(rows[r][c])),
                ],
                // 落单的那一块占半行，不要拉满：拉满会让人以为它是「重点科目」。
                if (rows[r].length == 1) const Expanded(child: SizedBox()),
              ],
            ),
          ),
          if (r != rows.length - 1) const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _tile(CheckinSubjectSummary summary) {
    final color = subjectColor(summary.subject);
    final last = summary.lastScoreLabel;
    final when = summary.lastSubmittedAt == null
        ? null
        : checkinShortDate(_dateKey(summary.lastSubmittedAt!));
    // 最近一次成绩 / 日期都可能缺（老数据没有成绩行的时间戳）。
    final detail = [last, when].whereType<String>().join(' · ');

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => onOpen(summary),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                // 科目名必须写着：只靠底色区分，色弱的人分不出哪块是哪科。
                Expanded(
                  child: Text(
                    summary.subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                ),
                Text(
                  '${summary.done} 份',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              detail.isEmpty ? '点开看每一套' : detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            const SizedBox(height: 8),
            Text(
              '看记录 ›',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// `DateTime` → `yyyy-MM-dd`（与 `checkinShortDate` 的入参同一个形状）。
  static String _dateKey(DateTime at) {
    final local = at.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }
}

/// 小圆角标签（「待完成」/「3/5」）。
class _Tag extends StatelessWidget {  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// 详情页顶部那条「返回任务列表」。
///
/// AppBar 的返回箭头只管系统返回键那一层（它也会先回清单），但孩子
/// 从很长的题里往回滑时，顶部这个入口更好找 —— 两个入口都指同一个
/// [_CheckinPageState._backToList]，行为一致。
class _BackToListRow extends StatelessWidget {
  const _BackToListRow({required this.onTap, required this.total});

  final VoidCallback onTap;

  /// 一共几份：让「回去」这件事有个明确的落点，而不是含糊的"上一层"。
  final int total;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Row(
            children: [
              const Icon(Icons.list_alt, size: 16, color: AppColors.textMuted),
              const SizedBox(width: 6),
              Text(
                '任务列表（共 $total 套）',
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
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.date});

  final String date;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.event_available, color: AppColors.primary, size: 20),
        const SizedBox(width: 8),
        Text('今天：$date', style: const TextStyle(color: AppColors.textMuted)),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: AppColors.danger, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(color: AppColors.danger, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

/// 今天还没有（这个科目的）题。
class _EmptyCard extends StatelessWidget {
  const _EmptyCard({
    required this.busy,
    required this.isParent,
    required this.onStart,
  });

  /// 出题进行中。由调用方在 `Obx` 里读出来传进来 —— 理由见调用处。
  final bool busy;

  /// 家长走「设范围 → 出题」，学生只有一键自动出题。
  /// 文案必须分开：用同一句会让学生以为自己也能选知识点。
  final bool isParent;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final title = isParent ? '还没有给今天的打卡出题' : '今天还没有打卡';
    final desc = isParent
        ? '选学科、知识点、题量和难度，出好后孩子打开就能做。'
            '可以分科目出多份，做对做错都会记下来，你能看到今天练了什么。'
        : '打卡会按教材章节或家长选的知识点，出 5 道选择/判断题，一分钟能做完。'
            '做错的题会自动进错题本，复习时可以重做。';
    final action = isParent ? '设置今天的题' : '出 5 道题';
    final footnote = isParent
        ? '题目由模型现场生成，要几秒。生成不了会如实告诉你，不会拿旧题凑数。'
        : '题目由模型按教材或家长范围现场生成；生成不了会如实告诉你，不会拿旧题凑数。';

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              desc,
              style: const TextStyle(color: AppColors.textMuted, height: 1.5),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: busy ? null : onStart,
                child: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(action),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              footnote,
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// 家长已有打卡时「再出一组」的入口。
///
/// 家长每出一次题就是一份独立试卷：出完数学想再来一套英语、甚至再来一套
/// 数学都行（2026-10-27 起同科目也不再排他），所以这个入口必须常驻 ——
/// 没有它，出完一套就只剩"等明天"。
class _AddAnotherCard extends StatelessWidget {
  const _AddAnotherCard({required this.busy, required this.onStart});

  final bool busy;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: busy ? null : onStart,
        child: const Text('再出一组新的试卷'),
      ),
    );
  }
}

/// 家长视角：题已经出好了，等孩子做。
///
/// 上半是状态（含「再出一组」），下半是**带答案的预览** —— 家长要知道
/// 今天考了什么、答案是什么才能辅导。孩子那边走的是 [_QuizBody]，
/// 那边一行的答案都不渲染。
class _ParentPreview extends StatelessWidget {
  const _ParentPreview({
    required this.quiz,
    required this.busy,
    required this.onAddAnother,
  });

  final CheckinQuiz quiz;
  final bool busy;
  final Future<void> Function() onAddAnother;

  @override
  Widget build(BuildContext context) {
    final meta = [
      if (quiz.difficulty.isNotEmpty) quiz.difficulty,
      '共 ${quiz.total} 题',
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.hourglass_bottom, color: AppColors.warning, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        '题已经出好了，等孩子做',
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                      ),
                    ),
                    TextButton(
                      onPressed: busy ? null : () => onAddAnother(),
                      child: const Text('再出一组'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  meta,
                  style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
                ),
                const SizedBox(height: 8),
                const Text(
                  '等孩子在自己的账号里做完，你就能看到分数。'
                  '答题留给学生本人，家长端不代答 —— 练的是孩子的脑子。',
                  style: TextStyle(color: AppColors.textMuted, height: 1.5),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          '下面是这份题的全部内容（含答案，供你辅导）',
          style: TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < quiz.questions.length; i++)
          CheckinPreviewCard(index: i, question: quiz.questions[i]),
      ],
    );
  }
}

/// 答题区。
///
/// ## ⚠️ 这里必须自带一个 `Obx`，不能只靠分节那个
///
/// 分节 `_RunSection` 的 Obx 只负责**构造** `_QuizBody` 这个组件对象；
/// 这个组件的 `build` 是在它自己的 Element 里跑的，**不在**那个 Obx 的
/// 追踪区内。也就是说 `run.picked[i]`、`answeredCount`、`allAnswered`
/// 这些读取一个都不会被记账 —— `picked` 改了也没人知道要重建。
///
/// 表现（2026-10-27 真机）：孩子点选项，状态确实写进去了，但界面上
/// **不变色、不标记、「已答 0/8」不动**，交卷按钮一直说「还有 8 题没选」。
/// 看着像按钮没绑事件，其实是改了 Rx 没人看。
///
/// 判据：`test/checkin_answer_test.dart` 真点一次，断言计数与选中底色都变。
class _QuizBody extends StatelessWidget {
  const _QuizBody({required this.run, required this.controller});

  final CheckinRun run;
  final CheckinController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final quiz = run.quiz.value;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  [
                    // 科目已经在节头显示过了，这里只补难度与题量。
                    if (quiz.difficulty.isNotEmpty) quiz.difficulty,
                    '共 ${quiz.total} 题',
                  ].join(' · '),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '已答 ${run.answeredCount}/${quiz.total}',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < quiz.questions.length; i++)
            CheckinQuestionCard(
              index: i,
              question: quiz.questions[i],
              picked: run.picked[i],
              onPick: (value) => controller.pick(run, i, value),
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: run.busy.value || !run.allAnswered
                  ? null
                  : () => controller.submit(run),
              child: Text(
                run.allAnswered
                    ? '交卷'
                    : '还有 ${quiz.total - run.answeredCount} 题没选',
              ),
            ),
          ),
        ],
      );
    });
  }
}

/// 交卷后的结果。
///
/// 分数可能是两种来源：本机刚算出来的（[CheckinSubmitResult.synced] = false）
/// 或服务端复算回来的。前者要如实说明「还没存到云端」，否则孩子关机走人，
/// 家长那边什么都没有，而孩子以为自己已经打完了。
class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.result,
    required this.questions,
    required this.onRetry,
    this.syncError,
  });

  final CheckinSubmitResult result;

  /// 题目快照：逐题明细行要显示题干 —— 光有「第 3 题错了」孩子翻不回
  /// 原题（2026-10-27 用户报的就是这个）。
  final List<CheckinQuestion> questions;
  final String? syncError;
  final Future<bool> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    // 用分数判断「全对」，**不要用 items**：历史成绩、或旧服务端返回的
    // result 里 items 可能是空的，按 items 判断会给出「4/5 · 全对，厉害」
    // 这种自相矛盾的话。
    final missed = result.total - result.score;
    final allCorrect = result.total > 0 && missed <= 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                  allCorrect ? '全对，厉害' : '有 $missed 题要再看看',
                  style: TextStyle(
                    color: allCorrect ? AppColors.success : AppColors.warning,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!result.synced) _SyncHint(error: syncError, onRetry: onRetry),
        if (result.imaSynced)
          const Padding(
            padding: EdgeInsets.only(top: 8, left: 4),
            child: Text(
              '已同步到 ima 知识库',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
        // 计划 → 复习的交接点：说清「错题去哪儿了」。
        // 不说的话，「打卡做错了」和「复习里多了一道题」在孩子眼里是两件
        // 互不相关的事，而它们其实是同一条链。归档失败要单独说 ——
        // 成绩已经保存，不能让他以为复习里会自己出现。
        if (result.mistakesFailed)
          const Padding(
            padding: EdgeInsets.only(top: 8, left: 4),
            child: Text(
              '做错的题没能记进错题本（成绩已保存），下次交卷会再试。',
              style: TextStyle(fontSize: 12, color: AppColors.warning),
            ),
          )
        else if (result.mistakesAdded > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4),
            child: Text(
              '做错的 ${result.mistakesAdded} 题已进错题本，去「复习」可以重做。',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
        const SizedBox(height: 12),
        // 逐题回放（试卷排版）：每题一题卡，标出学生答案、正确答案绿色、
        // 选错的浅红。重开页面也能看（服务端从存档派生回传），不只交卷那一瞬。
        for (final item in result.items)
          if (item.index >= 0 && item.index < questions.length)
            CheckinResultPaperCard(
              index: item.index,
              question: questions[item.index],
              picked: item.picked,
              correct: item.correct,
            ),
      ],
    );
  }
}

/// 「成绩已算出，但还没存到云端」。
///
/// 存档在后台进行：返回前显示「正在保存」，失败后给原因 + 重试。
/// 不用 Snackbar —— 它不是一次性提示，而是一个**持续存在的状态**
/// （关掉应用这份成绩就没了）。浮层一消失，用户就再也看不到它。
class _SyncHint extends StatelessWidget {
  const _SyncHint({required this.onRetry, this.error});

  final String? error;
  final Future<bool> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = error != null;
    return Padding(
      padding: const EdgeInsets.only(top: 10, left: 4, right: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              failed ? Icons.cloud_off : Icons.cloud_upload_outlined,
              size: 16,
              color: failed ? AppColors.warning : AppColors.textMuted,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              failed ? '成绩已算出，但还没存到云端：$error' : '成绩已算出，正在保存…',
              style: TextStyle(
                fontSize: 12,
                color: failed ? AppColors.warning : AppColors.textMuted,
              ),
            ),
          ),
          if (failed)
            TextButton(
              onPressed: () => onRetry(),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('重试'),
            ),
        ],
      ),
    );
  }
}
