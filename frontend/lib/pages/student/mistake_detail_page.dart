import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

import '../../constants/app_colors.dart';
import '../../controllers/review_controller.dart';
import '../../models/homework_image_model.dart';
import '../../models/review_model.dart';
import '../../services/tts_service.dart';
import '../../utils/pop_route.dart';
import '../../utils/practice_question_rules.dart';
import '../../utils/speech_text.dart';
import '../../widgets/homework_image_viewer.dart';
import '../../widgets/math_text.dart';
import 'widgets/explain_figure_card.dart';
import 'widgets/practice_figure_view.dart';
import 'widgets/review_badges.dart';

/// 单题复习详情：**讲解 → 举一反三 → 过程时间线**。
///
/// 三个 Tab 的顺序不是随便排的，它就是学生真实的复习动作顺序：
/// 先看懂为什么错（讲解），再换道题验证会不会（举一反三），
/// 最后回看自己这道题走过的全过程（时间线）。
class MistakeDetailPage extends StatefulWidget {
  const MistakeDetailPage({super.key, required this.mistakeId});

  final String mistakeId;

  @override
  State<MistakeDetailPage> createState() => _MistakeDetailPageState();
}

class _MistakeDetailPageState extends State<MistakeDetailPage>
    with SingleTickerProviderStateMixin {
  final ReviewController controller = Get.find<ReviewController>();
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void initState() {
    super.initState();
    controller.explainMistake(widget.mistakeId);
  }

  Future<void> _generatePractice() async {
    final result = await controller.generatePractice(widget.mistakeId);
    Get.snackbar(result.ok ? '已出题' : '未能出题', result.message);
    if (result.ok && mounted) _tabs.animateTo(1);
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final mistake = controller.mistakeById(widget.mistakeId);
      if (mistake == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('错题详情')),
          body: const Center(child: Text('这道错题已不在错题库中')),
        );
      }
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: const Text('错题详情'),
          bottom: TabBar(
            controller: _tabs,
            labelColor: AppColors.primary,
            unselectedLabelColor: AppColors.textMuted,
            indicatorColor: AppColors.primary,
            tabs: const [
              Tab(text: '讲解'),
              Tab(text: '举一反三'),
              Tab(text: '过程'),
            ],
          ),
        ),
        body: Column(
          children: [
            _MistakeHeader(mistake: mistake, controller: controller),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _ExplainTab(
                    controller: controller,
                    mistakeId: widget.mistakeId,
                    onPractice: _generatePractice,
                  ),
                  _PracticeTab(
                    controller: controller,
                    mistakeId: widget.mistakeId,
                  ),
                  _TimelineTab(
                    controller: controller,
                    mistakeId: widget.mistakeId,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }

  @override
  void dispose() {
    // 朗读说的是「这道题」，离开详情页就该停 —— 否则学生会带着别人的讲解去下一个页面。
    unawaited(TtsService.stop());
    _tabs.dispose();
    super.dispose();
  }
}

class _MistakeHeader extends StatefulWidget {
  const _MistakeHeader({required this.mistake, required this.controller});

  final ReviewMistake mistake;
  final ReviewController controller;

  @override
  State<_MistakeHeader> createState() => _MistakeHeaderState();
}

class _MistakeHeaderState extends State<_MistakeHeader> {
  /// 默认收起。
  ///
  /// 这一块原来把「标题 + 题干全文 + 6 个标签 + 原题照片 + 当时的答案 +
  /// 当时的过程 + 错因」**全铺在固定区里**，而且它是 `Column` 的固定子项、
  /// 不参与滚动 —— 一道应用题加上一段两百字的错因，能占掉大半屏，
  /// 下面的讲解 / 举一反三只剩一条缝（实测反馈「举一反三只能看到小部分」）。
  ///
  /// 收起后常驻的只有：标题、两行题干、标签行。其余要点开才看。
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final mistake = widget.mistake;
    final controller = widget.controller;
    final hasMore =
        mistake.questionBody.length > 60 ||
        mistake.imageCount > 0 ||
        mistake.originalAnswer.isNotEmpty ||
        mistake.studentProcess.isNotEmpty ||
        mistake.wrongReason.isNotEmpty;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  mistake.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (hasMore)
                GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8, top: 2),
                    child: Row(
                      children: [
                        Text(
                          _expanded ? '收起' : '展开',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Icon(
                          _expanded
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          size: 18,
                          color: AppColors.primary,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (mistake.questionBody.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: MathText(
                mistake.questionBody,
                // 收起态两行 + 省略号：题干全文在展开区里，跑不掉。
                maxLines: _expanded ? null : 2,
                style: const TextStyle(fontSize: 13.5, height: 1.6),
              ),
            ),
          ] else ...[
            const SizedBox(height: 6),
            const Text(
              '这条错题没有题干。补全后讲解会具体得多（点右上角编辑）。',
              style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (mistake.knowledgePoint.isNotEmpty)
                _Chip(text: mistake.knowledgePoint, color: AppColors.primary),
              _Chip(text: mistake.subject, color: AppColors.textMuted),
              _Chip(
                text: mistake.wrongCount > 1
                    ? '错 ${mistake.wrongCount} 次'
                    : '错 1 次',
                color: AppColors.danger,
              ),
              _Chip(text: mistake.state.label, color: AppColors.warning),
              if (_expanded) ...[
                _Chip(
                  text: mistake.sourceType.label,
                  color: AppColors.textMuted,
                ),
                if (mistake.grade.isNotEmpty)
                  _Chip(
                    text: '${mistake.grade}${_termLabel(mistake.term)}',
                    color: AppColors.textMuted,
                  ),
              ],
            ],
          ),
          if (_expanded) ...[
            _MistakePhotos(controller: controller, mistakeId: mistake.id),
            // ⚠️ 这两行原来是纯 `Text`，于是 `$2x$`、`$20 \times 2+…$`
            // 一字不差地显示成美元符号加反斜杠 —— 而**同一页的题目和讲解
            // 都是用 `MathText` 渲染的**。同一个模型产的同一段文本，
            // 在上面是公式、在这里是源码，用户当然会说「还是不支持公式」。
            //
            // 这两行恰恰是最该渲染的：错题卡上最常被引用的就是
            // 「孩子当时写了什么」和「错在哪」，而它们几乎全是算式。
            if (mistake.originalAnswer.isNotEmpty) ...[
              const SizedBox(height: 10),
              MathText(
                '当时的答案：${mistake.originalAnswer}',
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  color: AppColors.textMuted,
                ),
              ),
            ],
            // 学生当时写的过程。它比「最终答案」有用得多：讲解要能指出
            // 「你就是这一步错的」，而不是只说「答案不对」。
            // 空串是常态（选择题、填空题本来就没有过程），这时整段不显示。
            if (mistake.studentProcess.isNotEmpty) ...[
              const SizedBox(height: 6),
              MathText(
                '当时的过程：\n${mistake.studentProcess}',
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: AppColors.textMuted,
                ),
              ),
            ],
            if (mistake.wrongReason.isNotEmpty) ...[
              const SizedBox(height: 4),
              MathText(
                '错因：${mistake.wrongReason}',
                style: const TextStyle(fontSize: 12.5, height: 1.5),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _ExplainTab extends StatefulWidget {
  const _ExplainTab({
    required this.controller,
    required this.mistakeId,
    required this.onPractice,
  });

  final ReviewController controller;
  final String mistakeId;
  final Future<void> Function() onPractice;

  @override
  State<_ExplainTab> createState() => _ExplainTabState();
}

class _ExplainTabState extends State<_ExplainTab> {
  ReviewController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    TtsService.error.addListener(_onTtsError);
  }

  @override
  void dispose() {
    TtsService.error.removeListener(_onTtsError);
    super.dispose();
  }

  void _onTtsError() {
    final message = TtsService.error.value;
    if (message == null || !mounted) return;
    // 读走就清空：同一条原因不该在下次重建时又弹一遍。
    TtsService.error.value = null;
    Get.snackbar('朗读中断', message);
  }

  Future<void> _toggleSpeech() async {
    if (TtsService.speaking.value) {
      await TtsService.stop();
      return;
    }
    final explanation = controller.activeExplanation.value;
    if (explanation == null) return;

    final script = explanationSpeechText(
      knowledgePoint: explanation.knowledgePoint,
      position: explanation.position,
      whyWrong: explanation.whyWrong,
      steps: explanation.steps,
      pitfalls: explanation.pitfalls,
      mnemonic: explanation.mnemonic,
    );
    try {
      await TtsService.speak(script);
    } on TtsException catch (e) {
      if (!mounted) return;
      Get.snackbar('无法朗读', e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    // `activeExplanation` 与父级 Obx 追踪的 `mistakes` 是两个 Rx：
    // 讲解到货时父级不会重建 —— 这里必须自己 Obx，否则页面一直停在转圈。
    return Obx(() => _buildExplain(context));
  }

  Widget _buildExplain(BuildContext context) {
    final explanation = controller.activeExplanation.value;
    if (explanation == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SpeechBar(onTap: _toggleSpeech),
        const SizedBox(height: 8),
        // 紧跟在「朗读讲解」下面：听完一遍、还没想明白的学生，
        // 这时候最需要的是一张图，而不是再往下的五段文字。
        _FigureCard(controller: controller, mistakeId: widget.mistakeId),
        const SizedBox(height: 8),
        _Block(
          icon: Icons.my_location_outlined,
          title: '考点定位',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                explanation.knowledgePoint,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                explanation.position,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
        _Block(
          icon: Icons.error_outline,
          title: '为什么会错',
          child: MathText(
            explanation.whyWrong,
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
        ),
        _Block(
          icon: Icons.format_list_numbered,
          title: '正确解法',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < explanation.steps.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 20,
                        height: 20,
                        margin: const EdgeInsets.only(top: 1, right: 8),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            '${i + 1}',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: MathText(
                          explanation.steps[i],
                          style: const TextStyle(fontSize: 13, height: 1.6),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        _Block(
          icon: Icons.warning_amber_outlined,
          title: '易错提醒',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: explanation.pitfalls
                .map(
                  (item) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('· ', style: TextStyle(fontSize: 13)),
                        Expanded(
                          child: MathText(
                            item,
                            style: const TextStyle(fontSize: 13, height: 1.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        _Block(
          icon: Icons.tips_and_updates_outlined,
          title: '一句话记住',
          child: MathText(
            explanation.mnemonic,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.6,
              fontWeight: FontWeight.w600,
              color: AppColors.primaryDark,
            ),
          ),
        ),
        const SizedBox(height: 6),
        ElevatedButton.icon(
          onPressed: widget.onPractice,
          icon: const Icon(Icons.auto_awesome),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          label: const Text('看完了，出 3 道同类题练一练'),
        ),
        const SizedBox(height: 8),
        const Text(
          '讲解只记录过程，不代表掌握 —— 做对并通过检查才会移出错题库。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
        ),
      ],
    );
  }
}

/// 朗读条：一行按钮 + 一句说明。
///
/// 状态必须**看得见**：念到一半按钮变成「正在朗读，点这里停止」，学生知道能停；
/// 引擎起不来时按钮不会装成正在播的样子，而是弹一条明确的原因。
class _SpeechBar extends StatelessWidget {
  const _SpeechBar({required this.onTap});

  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: TtsService.speaking,
      builder: (context, speaking, _) {
        return Material(
          color: speaking
              ? AppColors.primary.withValues(alpha: 0.08)
              : AppColors.card,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              onTap();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    speaking
                        ? Icons.stop_circle_outlined
                        : Icons.volume_up_outlined,
                    size: 20,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          speaking ? '正在朗读，点这里停止' : '朗读讲解',
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          speaking ? '可以边听边看下面的步骤' : '跟着听一遍，再自己推一次',
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (speaking)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 讲解页的「理解图」：读 controller 的三个 Rx，交给纯展示的
/// [ExplainFigureCard]。
///
/// ⚠️ 三个 Rx 必须**都**在这里读一遍。外层 `Obx` 只追踪本次 build 真正读到的值：
/// 少读 `loadingFigureId`，点了按钮不会变成转圈（学生以为点空了）；
/// 少读 `_figures`，图到了页面还停在转圈上，而且永远不会自己好。
class _FigureCard extends StatelessWidget {
  const _FigureCard({required this.controller, required this.mistakeId});

  final ReviewController controller;
  final String mistakeId;

  @override
  Widget build(BuildContext context) {
    return ExplainFigureCard(
      figure: controller.figureOf(mistakeId),
      failure: controller.figureFailureOf(mistakeId),
      loading: controller.loadingFigureId.value == mistakeId,
      onGenerate: () => controller.loadFigure(mistakeId),
    );
  }
}

class _PracticeTab extends StatelessWidget {
  const _PracticeTab({required this.controller, required this.mistakeId});

  final ReviewController controller;
  final String mistakeId;

  /// ⚠️ 整段必须走 [Obx]，**不能**在 build 里直接读 `.value`。
  ///
  /// 本类是 StatelessWidget：直接读 `controller.submittingPractice.value`
  /// 只在「自己恰好被重建」时才有意义。而这里**没人会重建它** ——
  /// 父级那个 Obx 读的是 `mistakeById()`（依赖 `mistakes`），
  /// 而 `submittingPractice` / `capturingAnswer` 是另外两个 Rx，
  /// 它俩变化时父级 Obx 一动不动。
  ///
  /// 后果是**点了没反应**，而且是一串连锁的：
  /// · 按钮不变灰、文案不换成「正在检查…」、图标不转圈 ⇒ 学生以为点空了；
  /// · 判定写回 `practiceQuestions` 之后页面照样不重建
  ///   ⇒ 对错标记与「已作答 N/3」的计数也不更新，看起来像没生效。
  ///
  /// 把整段搬进 `Obx` 而不是内联闭包，是为了让 `_buildContent` 的缩进保持原样 ——
  /// 这次改动的实质只是「换个地方读 Rx」，不该顺带重排 150 行。
  @override
  Widget build(BuildContext context) => Obx(() => _buildContent(context));

  /// ⚠️ `context` 必须由 [build] 传进来。
  ///
  /// `Obx` 的 builder 不带参数，而这段内容里「换一组」要先弹一个确认框
  /// （`_confirmReplace`）—— 弹框需要一个**还挂在树上**的 BuildContext。
  /// 当初把这段从 `build` 搬进来时忘了把 `context` 一起带进来，代价是
  /// `Undefined name 'context'`：**lib 编不过 ⇒ `flutter build apk` 直接失败**，
  /// 而且 `app.dart` 下游的所有测试文件会一起「加载失败」（不是断言红）。
  Widget _buildContent(BuildContext context) {
    final questions = controller.questionsOf(mistakeId);
    if (questions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.auto_awesome_outlined,
                size: 40,
                color: AppColors.textMuted,
              ),
              const SizedBox(height: 12),
              const Text(
                '还没有生成同类题',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              const Text(
                'AI 会围绕这道题的知识点出 3 道变式题',
                style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () async {
                  final result = await controller.generatePractice(mistakeId);
                  Get.snackbar(result.ok ? '已出题' : '未能出题', result.message);
                },
                icon: const Icon(Icons.auto_awesome),
                label: const Text('生成 3 道变式题'),
              ),
            ],
          ),
        ),
      );
    }

    final submitting = controller.submittingPractice.value;
    // ⚠️ 这里的 answered 只看**文字**。拍照作答的结果最终也会变成文字，
    // 所以它算得上 —— 但识别**还在路上**的那几秒里，文字是空的，
    // 而学生的照片其实已经拍了。这时按 0 显示会让他以为白拍了，
    // 于是再去拍一张；而下面那个「提交全部」按钮又会拦他说
    // 「还有 N 道没作答」——两个信号互相矛盾，他会不知道信哪个。
    // 所以识别期间如实说明，而不是把它算成「没作答」。
    final capturing = controller.capturingAnswer.value;
    final answered = questions
        .where((q) => q.studentAnswer.trim().isNotEmpty)
        .length;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ...questions.map(
                (question) => _PracticeCard(
                  // 必须带 key：这个列表会随判定结果重建，也会因滚动
                  // 回收视口外的项。没有 key 时 State 按**位置**复用，
                  // 顺序一变，同一个输入框就会接着显示上一道题的内容 ——
                  // 看上去就像「某道题的答案被清掉了」。
                  key: ValueKey(question.id),
                  question: question,
                  controller: controller,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '3 道全部做对，这道错题才算练习通过（反复错的题仍需连续两轮）。',
                style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    // 「换一组」会把整组题换掉，已填的答案没有地方可留 ——
                    // 所以只要填过，就先问一句，不能让它静默清空。
                    onPressed: submitting
                        ? null
                        : () async {
                            if (answered > 0) {
                              final ok = await _confirmReplace(
                                context,
                                answered,
                              );
                              if (!ok) return;
                            }
                            final result = await controller.generatePractice(
                              mistakeId,
                            );
                            Get.snackbar(
                              result.ok ? '已换一组' : '未能出题',
                              result.message,
                            );
                          },
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('换一组', style: TextStyle(fontSize: 12.5)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    // 判定要串行过三次模型，实测十几秒。禁用 + 换文案是必须的：
                    // 没有它，学生以为点空了 —— 于是重复点、顺手再去改输入框，
                    // 而重复提交与等待期间的编辑，正是这份作答被弄乱的原因。
                    onPressed: (submitting || capturing)
                        ? null
                        : () async {
                            final result = await controller.submitAllPractice(
                              mistakeId,
                            );
                            Get.snackbar(
                              result.ok ? '练习通过' : '暂未通过',
                              result.message,
                              duration: const Duration(seconds: 4),
                            );
                          },
                    icon: submitting
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.fact_check_outlined, size: 16),
                    label: Text(
                      // 识别中禁用并说明原因：此时点提交必然被拦
                      // （那几道题的作答还是空的），先点一次再被拒
                      // 会比直接告诉他「在识别」多绕一圈。
                      capturing
                          ? '正在识别照片…'
                          : submitting
                          ? '正在检查…'
                          : '提交全部（$answered/${questions.length}）',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PracticeCard extends StatefulWidget {
  const _PracticeCard({
    super.key,
    required this.question,
    required this.controller,
  });

  final AiPracticeQuestion question;
  final ReviewController controller;

  @override
  State<_PracticeCard> createState() => _PracticeCardState();
}

class _PracticeCardState extends State<_PracticeCard> {
  late final TextEditingController _answer = TextEditingController(
    text: widget.question.studentAnswer,
  );
  bool _showAnswer = false;

  @override
  void didUpdateWidget(covariant _PracticeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 这个 controller 只在 State 创建时取过一次初始值，之后不会自己更新。
    // 同一张卡片被换到另一道题上时（换了一组、列表重排），输入框里留着的
    // 仍是上一道题的作答 —— 学生看到的就是「答案串题了」或「某个框空了」。
    // 只在**换题**时同步：同一道题内的作答以内存为准，不要打断正在敲的字。
    if (oldWidget.question.id != widget.question.id) {
      _answer.text = widget.question.studentAnswer;
      _showAnswer = false;
    }
  }

  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  Color get _stateColor => switch (widget.question.state) {
    PracticeState.correct => AppColors.success,
    PracticeState.wrong => AppColors.danger,
    PracticeState.pending => AppColors.textMuted,
  };

  String get _stateLabel => switch (widget.question.state) {
    PracticeState.correct => '正确',
    PracticeState.wrong => '有误',
    PracticeState.pending => '待作答',
  };

  /// 作答区：**由题型决定交互方式**。
  ///
  /// 选择题点选项、判断题点对错、填空与解答才需要打字或拍照。
  /// 这不是「界面好看一点」—— 选择题如果也要求打字，学生得先想清楚
  /// 「A 还是 A. 还是选项原文」，而判定的第一步就成了猜格式。
  Widget _answerArea(AiPracticeQuestion question) {
    switch (question.questionType) {
      case PracticeQuestionType.choice:
        return _choiceArea(question);
      case PracticeQuestionType.judge:
        return _judgeArea(question);
      case PracticeQuestionType.fill:
      case PracticeQuestionType.solution:
        return TextField(
          controller: _answer,
          maxLines: question.questionType == PracticeQuestionType.fill ? 1 : 2,
          decoration: const InputDecoration(
            labelText: '你的答案',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (value) =>
              widget.controller.answerPractice(question.id, value),
        );
    }
  }

  Widget _choiceArea(AiPracticeQuestion question) {
    // 解析层已经丢弃了选项不合格的题，但**老数据与坏数据仍可能走到这里**。
    // 没有四个选项的选择题点不了任何东西；与其给一排空按钮，
    // 不如明说这道题有问题 —— 静默的空界面会被当成「App 卡了」。
    if (!isUsableOptions(question.options)) {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text(
          '这道题的选项不完整，暂时不能作答。可以换一组题，或先看讲解。',
          style: TextStyle(fontSize: 12.5, height: 1.5),
        ),
      );
    }
    final picked = normalizeChoiceAnswer(
      question.studentAnswer,
      question.options,
    );
    return Column(
      children: [
        for (var i = 0; i < question.options.length; i++)
          Padding(
            padding: EdgeInsets.only(
              bottom: i == question.options.length - 1 ? 0 : 8,
            ),
            child: _ChoiceTile(
              letter: optionLetter(i),
              text: question.options[i],
              selected: picked == optionLetter(i),
              onTap: () => widget.controller.answerPractice(
                question.id,
                optionLetter(i),
              ),
            ),
          ),
      ],
    );
  }

  Widget _judgeArea(AiPracticeQuestion question) {
    final picked = normalizeJudgeAnswer(question.studentAnswer);
    return Row(
      children: [
        for (final value in const ['正确', '错误'])
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: value == '正确' ? 8 : 0),
              child: _JudgeTile(
                label: value,
                selected: picked == value,
                onTap: () =>
                    widget.controller.answerPractice(question.id, value),
              ),
            ),
          ),
      ],
    );
  }

  /// 参考答案的展示文本。
  ///
  /// 选择题的答案在存储里是字母 `A`，但学生要看的是「A 对应哪一项」。
  /// 只把展示拼上选项内容，存储与判定用的仍然是那个字母 ——
  /// 一旦在这里把答案改成整段文本，判定就会开始比字符串。
  String _answerLabel(AiPracticeQuestion question) {
    if (!question.isChoice || !isUsableOptions(question.options)) {
      return question.answer;
    }
    final letter = normalizeChoiceAnswer(question.answer, question.options);
    if (letter == null) return question.answer;
    final index = letter.codeUnitAt(0) - 0x41;
    if (index < 0 || index >= question.options.length) return question.answer;
    return '$letter. ${question.options[index]}';
  }

  /// 拍照 / 相册选图作答。
  ///
  /// ## 为什么选完图要先把 `recognizedText` 同步回输入框
  ///
  /// 这个 `TextEditingController` 只在 State 创建时取过一次初始值
  /// （见 [didUpdateWidget] 的注释）。识别结果是由 controller 写进
  /// `practiceQuestions` 的，而 **`onChanged` 不会被触发** ——
  /// 那是「用户敲键盘」的回调。所以这里必须手动同步，
  /// 否则学生会看到一个「系统说识别成功、输入框还是空的」的界面。
  Future<void> _capture(ImageSource source) async {
    final question = widget.question;
    final controller = widget.controller;
    try {
      final picker = ImagePicker();
      final List<XFile> files;
      if (source == ImageSource.gallery) {
        files = await picker.pickMultiImage(imageQuality: 85, maxWidth: 2048);
      } else {
        // 相机一次只能调一次 pickImage：调两次会让相机弹两次，
        // 第二次取消时强解包会直接崩掉（作业提交那边踩过同一个坑）。
        final shot = await picker.pickImage(
          source: source,
          imageQuality: 85,
          maxWidth: 2048,
        );
        files = shot == null ? const <XFile>[] : <XFile>[shot];
      }
      if (files.isEmpty) return;

      final photos = <PracticeAnswerPhoto>[];
      for (final file in files) {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;
        photos.add(PracticeAnswerPhoto(fileName: file.name, bytes: bytes));
      }
      if (photos.isEmpty) return;

      final result = await controller.captureAnswers(
        questionId: question.id,
        photos: photos,
      );

      if (!mounted) return;
      // 识别成功后把文字拉回输入框。**必须在这里做**，见上面的注释。
      // 仍然用 controller 里的那份（而不是 result 里的）——
      // 那是唯一"当前"的副本，识别期间学生可能又改过。
      final latest = controller
          .questionsOf(question.sourceMistakeId)
          .firstWhere((q) => q.id == question.id, orElse: () => question);
      if (result.ok) {
        _answer.text = latest.studentAnswer;
      }
      Get.snackbar(
        result.ok ? '识别完成' : '未能识别',
        result.message,
        duration: const Duration(seconds: 4),
      );
    } catch (error) {
      Get.snackbar('拍照失败', '无法读取图片：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final question = widget.question;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  question.difficulty,
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  question.title,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                _stateLabel,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: _stateColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          MathText(
            question.content,
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
          // 配图紧跟在题干下面：题干里写着「如图」的题，图就是题目的一半。
          // 没有图就不占位 —— 留一块空白会让学生以为图加载失败了。
          if (question.figure != null) ...[
            const SizedBox(height: 8),
            PracticeFigureView(figure: question.figure!),
          ],
          const SizedBox(height: 10),
          _answerArea(question),
          if (_showAnswer) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              child: MathText(
                // 选择题的 answer 存的是**字母**（判定要的是这个），
                // 但学生看不懂「参考答案：A」—— 他要知道 A 是哪一项。
                // 这里只影响展示，不动存储。
                '参考答案：${_answerLabel(question)}',
                style: const TextStyle(fontSize: 12.5, height: 1.5),
              ),
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              TextButton.icon(
                onPressed: () => setState(() => _showAnswer = !_showAnswer),
                icon: Icon(
                  _showAnswer ? Icons.visibility_off : Icons.visibility,
                  size: 16,
                ),
                label: Text(
                  _showAnswer ? '隐藏答案' : '查看答案',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              const Spacer(),
              // 拍照作答：识别出来的文字会填进上面的输入框，学生可以改。
              //
              // 按钮在识别期间变灰并换成转圈 —— 视觉模型实测要十几秒，
              // 没有这个反馈时学生会以为点空了，于是重复点、或者干脆
              // 自己敲一遍，两条路一起走的结果是输入框内容互相打架。
              // 选择题与判断题**不需要拍照**：答案就是点一下。
              // 留着这个按钮只会让学生以为还要写点什么才能提交。
              if (!question.isChoice && !question.isJudge)
                Obx(() {
                  final capturing = widget.controller.capturingAnswer.value;
                  return TextButton.icon(
                    onPressed: capturing
                        ? null
                        : () => _capture(ImageSource.camera),
                    icon: capturing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.photo_camera_outlined, size: 16),
                    label: Text(
                      capturing ? '识别中…' : '拍照作答',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  );
                }),
              Obx(() {
                // 判定要过一次模型，几秒钟没有反馈就会被当成「点空了」。
                // 与上面的「拍照作答」同样三件套：禁用 + 换文案 + 转圈。
                // ⚠️ 这里必须自己包 Obx，不能只靠父级重建 ——
                //    父级（`_PracticeTab`）确实会因 `submittingPractice` 变化而重建，
                //    但卡片列表由 ListView 懒构建，视口外的卡片不参与那一轮重建。
                final checking = widget.controller.submittingPractice.value;
                return TextButton.icon(
                  onPressed: checking
                      ? null
                      : () async {
                          final result = await widget.controller.checkPractice(
                            question.id,
                          );
                          Get.snackbar(
                            result.ok ? '检查完成' : '检查失败',
                            result.message,
                          );
                        },
                  icon: checking
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check, size: 16),
                  label: Text(
                    checking ? '检查中…' : '单独检查',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                );
              }),
            ],
          ),
        ],
      ),
    );
  }
}

class _TimelineTab extends StatelessWidget {
  const _TimelineTab({required this.controller, required this.mistakeId});

  final ReviewController controller;
  final String mistakeId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<MistakeTimelineEntry>>(
      future: controller.timelineOf(mistakeId),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final entries = snapshot.data!;
        if (entries.isEmpty) {
          return const Center(
            child: Text(
              '还没有过程记录',
              style: TextStyle(color: AppColors.textMuted),
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            // 渠道优先于 kind 上色：kind 只区分通过/未通过，
            // 若按 kind 上色，「自评通过」也会是绿色，和学生真正做对看起来一样。
            final color =
                entry.kind == TimelineKind.practiced && entry.channel != null
                ? attemptChannelColor(entry.channel!)
                : _kindColor(entry.kind);
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        margin: const EdgeInsets.only(top: 5),
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      if (index != entries.length - 1)
                        Expanded(
                          child: Container(
                            width: 1.5,
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            color: AppColors.border,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  entry.title,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    color: color,
                                  ),
                                ),
                              ),
                              Text(
                                _formatDateTime(entry.at),
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ],
                          ),
                          if (entry.channel != null) ...[
                            const SizedBox(height: 4),
                            ReviewChannelBadge(
                              channel: entry.channel!,
                              compact: true,
                            ),
                          ],
                          if (entry.detail.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              entry.detail,
                              style: const TextStyle(
                                fontSize: 12.5,
                                color: AppColors.textMuted,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Color _kindColor(TimelineKind kind) => switch (kind) {
    TimelineKind.created => AppColors.warning,
    TimelineKind.explained => AppColors.primary,
    TimelineKind.paperIssued => AppColors.accent,
    TimelineKind.practiced => AppColors.success,
    TimelineKind.failed => AppColors.danger,
    TimelineKind.mastered => AppColors.success,
  };
}

class _Block extends StatelessWidget {
  const _Block({required this.icon, required this.title, required this.child});

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: AppColors.primary),
              const SizedBox(width: 7),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// 换一组之前问一句。
///
/// 之所以不是「换完再提示」：换一组会把这一组题整组替换，内存里还没提交的
/// 作答跟着消失 —— 而它**刻意不落库**（见 `answerPractice`），没有副本可恢复。
/// 对着一张填了一半的练习卷说「已换一组」，等于把半个小时的输入悄悄扔掉。
Future<bool> _confirmReplace(BuildContext context, int answered) async {
  final confirmed = await Get.dialog<bool>(
    AlertDialog(
      title: const Text('换一组会清掉已填的答案'),
      content: Text('你已经填了 $answered 道题，换一组题目后这些答案不会保留。'),
      actions: [
        TextButton(
          onPressed: () => popRoute(context, false),
          child: const Text('先不换'),
        ),
        FilledButton(
          onPressed: () => popRoute(context, true),
          child: const Text('换一组'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}';
}

String _termLabel(String term) => switch (term) {
  '上' => ' · 上学期',
  '下' => ' · 下学期',
  _ => '',
};

/// 原题照片。
///
/// 独立于 `HomeworkImageReader` 的调用点，但复用同一个读取器（带 endpoint）：
/// 两套缓存逻辑只会让「一张图在作业里能看、在错题里看不到」这类问题
/// 变成需要查两处代码的难题。
class _MistakePhotos extends StatefulWidget {
  const _MistakePhotos({required this.controller, required this.mistakeId});

  final ReviewController controller;
  final String mistakeId;

  @override
  State<_MistakePhotos> createState() => _MistakePhotosState();
}

class _MistakePhotosState extends State<_MistakePhotos> {
  static const String _endpoint = '/data/review/mistake-images/file';
  late final Future<List<ReviewMistakeImage>> _future = _load();

  Future<List<ReviewMistakeImage>> _load() {
    return widget.controller.loadMistakeImages(widget.mistakeId);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ReviewMistakeImage>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.only(top: 10),
            child: SizedBox(
              height: 60,
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          );
        }
        if (snapshot.hasError) {
          return const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              '原题照片暂时读不到（不影响讲解与练习）',
              style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
          );
        }
        final images = snapshot.data ?? const <ReviewMistakeImage>[];
        if (images.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: SizedBox(
            height: 82,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: images.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) =>
                  _PhotoTile(image: images[index], endpoint: _endpoint),
            ),
          ),
        );
      },
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({required this.image, required this.endpoint});

  final ReviewMistakeImage image;
  final String endpoint;

  @override
  Widget build(BuildContext context) {
    final model = HomeworkImageModel(
      id: image.id,
      studentId: image.studentId,
      homeworkId: null,
      storageKey: image.storageKey,
      fileName: '',
      fileSize: image.fileSize,
      mimeType: image.mimeType,
      ocrStatus: '',
      ocrText: '',
      createdAt: image.createdAt ?? DateTime.now(),
      sortOrder: image.sortOrder,
    );
    return FutureBuilder<Uint8List?>(
      future: HomeworkImageReader.load(model, endpoint: endpoint),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) {
          // 读不到时给一个**有文字的占位**，而不是空白框：
          // 空白框看起来像「这张图本来就没有内容」。
          return Container(
            width: 74,
            height: 74,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: const Text(
              '读不到',
              style: TextStyle(fontSize: 10.5, color: AppColors.textMuted),
            ),
          );
        }
        return GestureDetector(
          onTap: () => showDialog<void>(
            context: context,
            builder: (context) => Dialog(
              backgroundColor: Colors.black,
              insetPadding: const EdgeInsets.all(10),
              child: InteractiveViewer(
                maxScale: 4,
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              bytes,
              width: 74,
              height: 74,
              fit: BoxFit.cover,
            ),
          ),
        );
      },
    );
  }
}

/// 选择题的一个选项。
///
/// 用整块可点区域而不是 `Radio`：中学生在地铁上单手做题时，
/// 靠右的小圆点很难命中。整行可点也顺带让「选中的是哪一项」更明显。
class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.letter,
    required this.text,
    required this.selected,
    required this.onTap,
  });

  final String letter;
  final String text;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.08)
                : AppColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.border,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? AppColors.primary : Colors.transparent,
                  border: Border.all(
                    color: selected ? AppColors.primary : AppColors.border,
                  ),
                ),
                child: Text(
                  letter,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : AppColors.textMuted,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: MathText(
                  text,
                  style: const TextStyle(fontSize: 13, height: 1.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 判断题的「正确 / 错误」按钮。
class _JudgeTile extends StatelessWidget {
  const _JudgeTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = label == '正确' ? AppColors.success : AppColors.danger;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.1) : AppColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? accent : AppColors.border,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: selected ? accent : AppColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}
