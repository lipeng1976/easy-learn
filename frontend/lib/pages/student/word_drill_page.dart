import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/word_drill_controller.dart';
import '../../models/word_checkin.dart';
import '../../services/word_tts.dart';

/// 学生端「英语单词打卡」：一天一组、断网可答、本机立即出分。
///
/// 渲染纪律：答题卡只读 `stem / options / chosen`，**不读 answer**，
/// 与 `CheckinQuestionCard` 同一条 —— 「答题时看不到答案」靠渲染层不看，
/// 不靠答案还没从服务端回来（答案本来就随题在本地）。
class WordDrillPage extends StatefulWidget {
  const WordDrillPage({super.key});

  @override
  State<WordDrillPage> createState() => _WordDrillPageState();
}

class _WordDrillPageState extends State<WordDrillPage> {
  late final WordDrillController controller;

  @override
  void initState() {
    super.initState();
    controller = Get.isRegistered<WordDrillController>()
        ? Get.find<WordDrillController>()
        : Get.put(WordDrillController());
    controller.loadToday();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('英语单词打卡')),
        body: Obx(() {
          if (controller.isLoading.value) {
            return const Center(child: CircularProgressIndicator());
          }
          if (controller.questions.isEmpty) {
            return _EmptyState(
              message: controller.hint.value ?? '还没有可练的单词。',
              onRetry: controller.retry,
            );
          }
          if (controller.submitted.value) return _buildResult(context);
          return _buildQuiz(context);
        }),
      );

  Widget _buildQuiz(BuildContext context) => Column(
        children: [
          _Header(
            label: controller.scopeLabel.value,
            progress: '${controller.answeredCount}/${controller.questions.length}',
            hint: controller.hint.value,
          ),
          // 一条灰字提示搁在页级，不是每张题卡都挂一份：WordTts.error 是
          // 全局 ValueNotifier，十张卡同时弹同一句会变成噪音。
          ValueListenableBuilder<String?>(
            valueListenable: WordTts.error,
            builder: (context, message, _) => message == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                    child: Text(
                      message,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: controller.questions.length,
              itemBuilder: (context, index) => _QuestionCard(
                index: index,
                question: controller.questions[index],
                picked: controller.chosen[controller.questions[index].id],
                onPick: (letter) => controller.select(
                  controller.questions[index].id,
                  letter,
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => controller.submit(),
                  child: const Text('交卷，看结果'),
                ),
              ),
            ),
          ),
        ],
      );

  Widget _buildResult(BuildContext context) {
    final questions = controller.questions;
    return Column(
      children: [
        _Header(
          label: controller.scopeLabel.value,
          progress: '答对 ${controller.correctCount}/${questions.length}',
          hint: '连续打卡 ${controller.streak.value} 天',
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: questions.length,
            itemBuilder: (context, index) => _ResultCard(
              index: index,
              question: questions[index],
            ),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.label, required this.progress, this.hint});

  final String label;
  final String progress;
  final String? hint;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        color: Theme.of(context).colorScheme.primaryContainer,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label.isEmpty ? '今日单词' : label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(progress, style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
            if (hint != null && hint!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  hint!,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
          ],
        ),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.menu_book_outlined, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onRetry, child: const Text('再试一次')),
            ],
          ),
        ),
      );
}

/// 答题卡。**这里绝不出现 `question.answer` / `answerIndex`。**
class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.index,
    required this.question,
    required this.picked,
    required this.onPick,
  });

  final int index;
  final WordQuestion question;
  final String? picked;
  final void Function(String letter) onPick;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '${index + 1}. ${question.stem}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  // 发音是可选能力：设备不支持 / 正在合成时喇叭置灰，
                  // 不给「点了没反应」，也不抛异常（doc/word-checkin-design.md §8/§9）。
                  ValueListenableBuilder<bool>(
                    valueListenable: WordTts.busy,
                    builder: (context, busy, _) {
                      final enabled = WordTts.isSupported && !busy;
                      return IconButton(
                        tooltip: enabled ? '读这个单词' : '这台设备暂时不能朗读单词',
                        onPressed: enabled
                            ? () => WordTts.speak(question.word)
                            : null,
                        icon: Icon(
                          Icons.volume_up_outlined,
                          size: 20,
                          color: enabled ? null : Colors.grey,
                        ),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < question.options.length; i += 1)
                _OptionTile(
                  letter: String.fromCharCode(65 + i),
                  text: question.options[i],
                  selected: picked == String.fromCharCode(65 + i),
                  onTap: () => onPick(String.fromCharCode(65 + i)),
                ),
            ],
          ),
        ),
      );
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
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
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Colors.transparent,
              border: Border.all(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey.shade300,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Text('$letter.', style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                Expanded(child: Text(text)),
              ],
            ),
          ),
        ),
      );
}

/// 已完成回放：正确答案**永远绿**，选错的那项浅红，底部「你的答案」对绿错红。
/// 与 `CheckinResultPaperCard` 同一套配色口径。
class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.index, required this.question});

  final int index;
  final WordQuestion question;

  @override
  Widget build(BuildContext context) {
    final correctIndex = question.answerIndex;
    final pickedIndex = question.picked.trim().isEmpty
        ? -1
        : question.picked.trim().toUpperCase().codeUnitAt(0) - 65;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${index + 1}. ${question.stem}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < question.options.length; i += 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${String.fromCharCode(65 + i)}. ${question.options[i]}',
                  style: TextStyle(
                    color: i == correctIndex
                        ? Colors.green.shade800
                        : (i == pickedIndex ? Colors.red.shade300 : null),
                    fontWeight:
                        i == correctIndex ? FontWeight.w700 : FontWeight.normal,
                  ),
                ),
              ),
            const SizedBox(height: 6),
            Text(
              '你的答案：${question.picked.trim().isEmpty ? '未作答' : question.picked} · '
              '正确答案：${question.answer}（${question.word} = ${question.primaryMeaning}）',
              style: TextStyle(
                fontSize: 12,
                color: question.correct ? Colors.green.shade800 : Colors.red.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
