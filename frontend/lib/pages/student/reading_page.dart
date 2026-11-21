import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/reading_controller.dart';
import '../../models/reading_models.dart';
import '../../services/server_tts.dart';
import '../../services/speech_rate.dart';
import '../../services/tts_voice.dart';
import '../../utils/vocabulary_highlight.dart';

/// 学生阅读页：读一篇英文，读完打卡。
///
/// ## 页面只显示「下一篇」，没有课目录
///
/// 任务要求按顺序读（服务端拒跳读）。放一个可点的目录，等于把
/// 「跳到第 80 课」做成一个按钮 —— 学生点一下就能把进度刷到 80/96，
/// 而整本书没读。所以这里不给选择，只给「现在这一篇」。
///
/// ## 打卡后**不自动翻页**
///
/// 自动跳下一篇看起来顺滑，但孩子会不知道「刚才那篇算上没有了」——
/// 尤其弱网下打卡请求还在飞。所以打完卡停在原地，按钮变成
/// 「读下一篇」，让他自己按。
///
/// ## 译文与生词默认收起
///
/// 一进来就摊开中文，孩子会先读中文再「读」英文。收起之后至少让他
/// 先看到英文；看不懂再点开。
class ReadingPage extends StatefulWidget {
  const ReadingPage({super.key});

  @override
  State<ReadingPage> createState() => _ReadingPageState();
}

class _ReadingPageState extends State<ReadingPage> {
  late final ReadingController controller;

  /// 当前显示这一篇的课号。
  int? _lessonNo;

  /// 这一篇是否**已经打过卡**（打卡后停在原地时用）。
  bool _justMarked = false;

  String? _taskId;

  @override
  void initState() {
    super.initState();
    controller = Get.isRegistered<ReadingController>()
        ? Get.find<ReadingController>()
        : Get.put(ReadingController());
    // 伴读**中途**的失败没有 await 可以 catch —— 播放器那条流只能这么听。
    ServerTts.error.addListener(_onTtsError);
    // 语速是本机偏好，异步读；`SpeechRateSettings.load()` 自己会避开
    // 「孩子手快先点了慢速、DB 读完又覆盖回去」的竞态。
    unawaited(SpeechRateSettings.load());
    _taskId = Get.arguments as String?;
    _bootstrap();
  }

  /// 伴读中途失败（不是 `speak()` 抛出来的那种，比如播放器被系统打断）。
  void _onTtsError() {
    final message = ServerTts.error.value;
    if (message == null || message.isEmpty) return;
    // 读完就清：这个 notifier 是全局的，留着会让下一个页面一进来就弹旧错。
    ServerTts.error.value = null;
    if (!mounted) return;
    // 这里不只装「读不了」，也装「语速没切成」这类非致命提示，
    // 所以标题用中性的「伴读提示」。
    Get.snackbar('伴读提示', message, snackPosition: SnackPosition.BOTTOM);
  }

  /// 首屏：确保任务在手里，然后把「下一篇」打开。
  ///
  /// 冷启动直接进这个页面（例如从通知点进来）时 `tasks` 是空的，
  /// 所以先 load 一次；已经有数据时不重复请求。
  Future<void> _bootstrap() async {
    if (controller.tasks.isEmpty) {
      await controller.load();
    }
    if (!mounted) return;

    final task = _task;
    if (task == null) return;
    final target = task.nextLessonNo
        // 读完了：停留在**最后一篇已读**，让页面有东西可看。
        ?? (task.readLessonNos.isEmpty ? null : task.readLessonNos.last);
    if (target == null) return;
    setState(() => _lessonNo = target);
    await controller.openLesson(task: task, lessonNo: target);
  }

  ReadingTask? get _task {
    final id = _taskId;
    if (id != null) {
      final hit = controller.taskById(id);
      if (hit != null) return hit;
    }
    return controller.activeTask ?? controller.lastFinished;
  }

  /// 打卡。
  Future<void> _mark() async {
    final task = _task;
    if (task == null) return;
    final result = await controller.markRead(task);
    if (!mounted) return;
    if (result == null) {
      // 失败原因已经在 `controller.error` 里，用 SnackBar 只是让它更显眼。
      // 页面**不跳走**：跳走的话孩子不知道这次到底算没算。
      final message = controller.error.value;
      if (message != null && message.isNotEmpty) {
        Get.snackbar('打卡没成功', message, snackPosition: SnackPosition.BOTTOM);
      }
      return;
    }
    setState(() => _justMarked = true);
    if (result.taskDone) {
      Get.snackbar(
        '整本书读完啦',
        '《${result.task.bookTitle}》${result.task.totalLessons} 篇全部读完，'
        '等家长安排下一本。',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 4),
      );
    }
  }

  /// 读下一篇。
  Future<void> _next() async {
    final task = _task;
    final target = task?.nextLessonNo;
    if (task == null || target == null) return;
    // 上一篇的伴读还在放的话，翻页之后它会接着念旧课文 ——
    // 学生看着新文章，耳朵里是上一篇，会以为自己串页了。
    unawaited(ServerTts.stop());
    setState(() {
      _lessonNo = target;
      _justMarked = false;
    });
    await controller.openLesson(task: task, lessonNo: target);
  }

  /// 伴读：念一遍当前这篇英文。
  ///
  /// 走的是**服务端合成**，不是系统 TTS：学生那台鸿蒙手机通过卓易通跑安卓应用，
  /// 容器里没有安卓的语音合成服务，端上 `TextToSpeech` 根本发不出声
  /// （真机实测：卡十几秒后超时）。这里把文字发到网关合成 mp3，客户端只负责播。
  ///
  /// 只念**英文正文**，不念生词和译文 —— 译文默认是收起的，收起的部分
  /// 却被念出来，孩子会莫名其妙听到一串中文。
  Future<void> _toggleListen() async {
    if (ServerTts.isBusy) {
      await ServerTts.stop();
      return;
    }
    final lesson = controller.lesson.value;
    if (lesson == null) return;
    final text = lesson.paragraphs.join('\n\n').trim();
    if (text.isEmpty) {
      Get.snackbar('无法朗读', '这一篇还没有可朗读的正文', snackPosition: SnackPosition.BOTTOM);
      return;
    }
    try {
      // language: en —— 断句与语音数据都按英文走。
      // 不能靠「文本里有没有中文」自动判断：课文里常夹着中文人名或注释，
      // 猜错的后果是整篇用中文腔念英文。
      await ServerTts.speak(text, language: 'en');
    } on ServerTtsException catch (e) {
      if (!mounted) return;
      Get.snackbar('无法伴读', e.message, snackPosition: SnackPosition.BOTTOM);
    }
  }

  @override
  void dispose() {
    ServerTts.error.removeListener(_onTtsError);
    // 页面没了声音还在放：学生退出后声音跟着去别的页面，是这一整类功能
    // 最常见的尴尬（讲解朗读那边也是这么处理的）。
    unawaited(ServerTts.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Obx(() {
          final task = _task;
          if (task == null) return const Text('阅读');
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(task.bookTitle, style: const TextStyle(fontSize: 16)),
              Text(
                '${task.doneLessons}/${task.totalLessons} 篇',
                style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ],
          );
        }),
      ),
      body: Obx(() {
        final task = _task;
        if (task == null) {
          return _CenterHint(
            text: controller.loading.value ? '正在读取任务…' : '没有找到这份阅读任务。',
            action: controller.loading.value ? null : ('重新加载', () => controller.load()),
          );
        }
        if (task.isCancelled) {
          return const _CenterHint(text: '这份阅读任务已经被家长取消了。');
        }
        if (task.finished) {
          return _FinishedView(task: task);
        }
        if (controller.lessonLoading.value) {
          return const Center(child: CircularProgressIndicator());
        }
        final error = controller.error.value;
        final lesson = controller.lesson.value;
        if (lesson == null) {
          return _CenterHint(
            text: error ?? '没有读到课文内容。',
            action: ('重试', () {
              final target = _lessonNo ?? task.nextLessonNo;
              if (target != null) controller.openLesson(task: task, lessonNo: target);
            }),
          );
        }

        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  _LessonHeader(lesson: lesson, task: task),
                  const SizedBox(height: 16),
                  for (final paragraph in lesson.paragraphs) ...[
                    _ParagraphText(
                      paragraph: paragraph,
                      vocabulary: lesson.vocabulary,
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (lesson.vocabulary.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    _FoldSection(
                      icon: Icons.menu_book_outlined,
                      title: '生词 ${lesson.vocabulary.length} 个',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final word in lesson.vocabulary)
                            _VocabularyRow(word: word),
                        ],
                      ),
                    ),
                  ],
                  if (lesson.translation.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _FoldSection(
                      icon: Icons.translate_outlined,
                      title: '中文译文',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final paragraph in lesson.translationParagraphs) ...[
                            Text(
                              paragraph,
                              style: const TextStyle(
                                fontSize: 15,
                                height: 1.8,
                                color: AppColors.textMuted,
                              ),
                            ),
                            const SizedBox(height: 10),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            _BottomBar(
              task: task,
              lessonNo: lesson.lessonNo,
              justMarked: _justMarked,
              busy: controller.busy.value,
              onMark: _mark,
              onNext: _next,
              onListen: _toggleListen,
            ),
          ],
        );
      }),
    );
  }
}

/// 课文头部：`第 4 篇 / 共 96 篇` + 英文标题 + 中文标题。
class _LessonHeader extends StatelessWidget {
  const _LessonHeader({required this.lesson, required this.task});

  final ReadingLesson lesson;
  final ReadingTask task;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '第 ${lesson.lessonNo} 篇 / 共 ${task.totalLessons} 篇',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ),
            if (task.hasRead(lesson.lessonNo)) ...[
              const SizedBox(width: 8),
              const Icon(Icons.check_circle, size: 15, color: AppColors.success),
              const SizedBox(width: 3),
              const Text(
                '已读',
                style: TextStyle(fontSize: 11, color: AppColors.success, fontWeight: FontWeight.w700),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Text(
          lesson.title,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.3),
        ),
        if (lesson.titleZh.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            lesson.titleZh,
            style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
          ),
        ],
      ],
    );
  }
}

/// 可折叠区块（生词 / 译文）。
/// 正文的一段：这一课的生词在文中用**粗体蓝色**标出来。
///
/// 生词表给的是原形，正文常常是 spent / stopped / studies 这类变形，
/// 匹配逻辑在 `utils/vocabulary_highlight.dart` 里做词形还原 —— 否则
/// 两成多的生词明明在文中出现却不标，学生会以为没出现过。
class _ParagraphText extends StatelessWidget {
  const _ParagraphText({required this.paragraph, required this.vocabulary});

  final String paragraph;
  final List<ReadingVocabulary> vocabulary;

  static const _baseStyle = TextStyle(
    fontSize: 17,
    height: 1.9,
    color: AppColors.text,
  );

  static const _wordStyle = TextStyle(
    fontWeight: FontWeight.w700,
    color: AppColors.primary,
  );

  @override
  Widget build(BuildContext context) {
    final pieces = splitVocabulary(
      paragraph,
      vocabulary.map((item) => item.word),
    );
    // 这一段没有生词：保持原来的纯文本渲染（可选中，不建多余 span）。
    if (!pieces.any((piece) => piece.isVocabulary)) {
      return SelectableText(paragraph, style: _baseStyle);
    }
    return SelectableText.rich(
      TextSpan(
        style: _baseStyle,
        children: [
          for (final piece in pieces)
            TextSpan(
              text: piece.text,
              style: piece.isVocabulary ? _wordStyle : null,
            ),
        ],
      ),
    );
  }
}

class _FoldSection extends StatelessWidget {
  const _FoldSection({required this.icon, required this.title, required this.child});

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Theme(
      // 去掉 ExpansionTile 展开时的分隔线 —— 在浅灰背景上那条线很像
      // 内容被截断了。
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        backgroundColor: AppColors.card,
        collapsedBackgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.border),
        ),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.border),
        ),
        leading: Icon(icon, size: 18, color: AppColors.primary),
        title: Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        children: [child],
      ),
    );
  }
}

/// 一条生词：`young [jʌŋ]` + 释义（例句折叠在下面）。
class _VocabularyRow extends StatelessWidget {
  const _VocabularyRow({required this.word});

  final ReadingVocabulary word;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                word.word,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
              if (word.phonetic.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  word.phonetic,
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                ),
              ],
            ],
          ),
          if (word.meaning.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(word.meaning, style: const TextStyle(fontSize: 13, height: 1.6)),
          ],
          if (word.detail.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              word.detail,
              style: const TextStyle(fontSize: 12, height: 1.7, color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// 底部那一条：伴读 / 读完了。
///
/// ## 为什么伴读和打卡挤在同一行
///
/// 它们服务于同一个动作：把这一篇**读完**。伴读在上面一行、打卡在下一行，
/// 孩子会以为它们属于两件事，读完点完卡就找不到听的了。
///
/// ## 伴读按钮的状态必须看得见
///
/// 念到一半时按钮要变成「停止」。只给一次性按钮的话，孩子想停也停不下来
/// （而那正是他在旁边有人说话、或者想自己读的时候最需要的）。
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.task,
    required this.lessonNo,
    required this.justMarked,
    required this.busy,
    required this.onMark,
    required this.onNext,
    required this.onListen,
  });

  final ReadingTask task;

  /// 当前显示这一篇的课号。
  ///
  /// ⚠️ 不用 `task.nextLessonNo` 反推：打完卡之后 `nextLessonNo` 已经指向
  /// **下一篇**了，用它判断「这一篇读过没有」会得出「没读过」，
  /// 于是按钮又变回「我读完了，打卡」—— 孩子会以为没记上，再点一次。
  final int lessonNo;
  final bool justMarked;
  final bool busy;
  final Future<void> Function() onMark;
  final Future<void> Function() onNext;
  final Future<void> Function() onListen;

  @override
  Widget build(BuildContext context) {
    // 翻回来重看一篇读过的课文时，同样不再给「打卡」按钮 —— 点了只会得到
    // 一次幂等返回，那种「按了没反应」最让人困惑。
    final alreadyRead = justMarked || task.hasRead(lessonNo);
    final canNext = task.nextLessonNo != null;

    final Widget? primary = alreadyRead
        ? (canNext
              ? FilledButton(onPressed: busy ? null : onNext, child: const Text('读下一篇'))
              : null)
        : FilledButton(
            onPressed: busy ? null : onMark,
            child: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('我读完了，打卡'),
          );

    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(
        color: AppColors.card,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  alreadyRead
                      ? (canNext ? '这一篇已打卡' : '全本读完了')
                      : '读完后点右边的按钮打卡',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                ),
              ),
              const SizedBox(width: 8),
              // 和「伴读」按钮同一块：选完马上能点来听，不必去设置页找。
              const SpeechRateSelector(),
            ],
          ),
          // 只有真的在念时才出现，不占平时的空间。
          const SpeechSourceBadge(),
          const SizedBox(height: 8),
          Row(
            children: [
              ListenButton(onPressed: onListen),
              if (primary != null) ...[
                const SizedBox(width: 10),
                Expanded(child: primary),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 这次朗读从哪儿出声。
///
/// 音色（男/女）是「一听就知道」的主判据，这行小字是**文字备份**：
/// 外放听不出男女、或家长在旁边看屏幕时，也能立刻确认有没有走到云端。
/// 只在 [speechSource] 非 null（正在念）时占一行，平时完全不出现。
class SpeechSourceBadge extends StatelessWidget {
  const SpeechSourceBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TtsAudioSource?>(
      valueListenable: speechSource,
      builder: (context, source, _) {
        if (source == null) return const SizedBox.shrink();
        return Padding(
          key: const Key('speech_source_badge'),
          padding: const EdgeInsets.only(top: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                source.isMale ? Icons.male : Icons.female,
                size: 13,
                color: source.isMale ? AppColors.primary : AppColors.textMuted,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  source.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 朗读语速：正常 / 慢速。
///
/// 放在伴读按钮上方而不是塞进设置页，是因为**只有要听的时候才会想调**；
/// 放远了孩子根本不会发现。档位由 [SpeechRateSettings] 单点持有，
/// 这里只负责显示与写入；播放器自己监听，念到一半切也立刻生效。
class SpeechRateSelector extends StatelessWidget {
  const SpeechRateSelector({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SpeechRate>(
      valueListenable: SpeechRateSettings.current,
      builder: (context, rate, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Tooltip(
            message: '慢速是正常速度的 0.8 倍，声音不会变粗；设一次就记住',
            child: Text(
              '语速',
              style: TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
          ),
          const SizedBox(width: 6),
          for (final option in SpeechRate.values) ...[
            _RateChip(
              option: option,
              selected: rate == option,
            ),
            if (option != SpeechRate.values.last) const SizedBox(width: 5),
          ],
        ],
      ),
    );
  }
}

class _RateChip extends StatelessWidget {
  const _RateChip({required this.option, required this.selected});

  final SpeechRate option;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '朗读${option.label}语速',
      child: GestureDetector(
        key: Key('speech_rate_${option.storageValue}'),
        onTap: () => unawaited(SpeechRateSettings.select(option)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.12)
                : Colors.transparent,
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.border,
            ),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            option.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? AppColors.primary : AppColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// 伴读按钮：没在念时「伴读」，准备音频时「准备中…」，在念时「停止」。
///
/// 单独抽出来是为了能被测试直接盯住 —— 状态没跟着 `ServerTts.state`
/// 走的话，界面上会一直显示「伴读」，学生按下去毫无反应（因为它其实在放，
/// 但按钮骗了他），这类静默错最难被发现。
class ListenButton extends StatelessWidget {
  const ListenButton({super.key, required this.onPressed});

  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ServerSpeechState>(
      valueListenable: ServerTts.state,
      builder: (context, state, _) {
        final busy = state != ServerSpeechState.idle;
        // 为什么需要这个中间态：一篇 2000 字的课文要合成 5 段音频，
        // 那几秒里既没声音、也没到「播放中」。不多这一态，按钮会一直是
        // 「伴读」，孩子以为没点上，会连着点好几次 —— 每次都重新合成一遍。
        final preparing = state == ServerSpeechState.preparing;
        return OutlinedButton.icon(
          onPressed: () => onPressed(),
          icon: preparing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  busy ? Icons.stop_circle_outlined : Icons.headphones_outlined,
                  size: 18,
                ),
          label: Text(preparing ? '准备中…' : (busy ? '停止' : '伴读')),
          style: OutlinedButton.styleFrom(
            foregroundColor: busy ? AppColors.warning : AppColors.primary,
            side: BorderSide(
              color: busy
                  ? AppColors.warning.withValues(alpha: 0.5)
                  : AppColors.primary.withValues(alpha: 0.4),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14),
          ),
        );
      },
    );
  }
}

/// 整本读完的落地页。
class _FinishedView extends StatelessWidget {
  const _FinishedView({required this.task});

  final ReadingTask task;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.emoji_events_outlined, size: 56, color: AppColors.warning),
            const SizedBox(height: 16),
            Text(
              '《${task.bookTitle}》读完了',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              '一共 ${task.totalLessons} 篇。等家长安排下一本书。',
              style: const TextStyle(color: AppColors.textMuted, height: 1.6),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _CenterHint extends StatelessWidget {
  const _CenterHint({required this.text, this.action});

  final String text;

  /// `(按钮文案, 点击回调)`。null = 不给按钮。
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              style: const TextStyle(color: AppColors.textMuted, height: 1.6),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: action!.$2, child: Text(action!.$1)),
            ],
          ],
        ),
      ),
    );
  }
}
