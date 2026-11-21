import 'dart:math';

import '../models/word_checkin.dart';

/// 本地规则出双项选择题（零 AI、零配额、断网可用）。
///
/// ## 为什么是「池固定、每日抽选项」而不是导入时把题定死
///
/// 同一词永远是同一组选项，孩子会背「C 是答案」而不是背单词。
/// 池在导入时建一次（同单元优先、相邻单元兜底），每天按日期种子从池里
/// 抽 3 个干扰项并打乱 —— 答案依然确定、依然零 AI，但每天题目不同。
class WordQuestionGenerator {
  WordQuestionGenerator._();

  /// 给每词条建干扰项候选池。**只在当前这一本书内**，不跨书（§5.4.2）。
  ///
  /// 排除三样：① normalizeWord 相同（跨单元重复词）；② primaryMeaning 相同
  /// （会造出两个正确答案）；③ primaryMeaning 为空。
  /// 同单元不够 3 个 → 按 unitOrder 距离扩到相邻单元；仍不够 → 空池，
  /// 该词不出题（宁可少一题，不造错题）。
  static List<WordEntry> buildPools(List<WordEntry> entries) {
    final byBook = <String, List<WordEntry>>{};
    for (final e in entries) {
      (byBook[e.bookId] ??= <WordEntry>[]).add(e);
    }
    final result = <WordEntry>[];
    for (final book in byBook.values) {
      final sorted = [...book]
        ..sort((a, b) => a.unitOrder != b.unitOrder
            ? a.unitOrder.compareTo(b.unitOrder)
            : a.sortNo.compareTo(b.sortNo));
      for (final entry in sorted) {
        final candidates = <WordEntry>[];
        for (final other in sorted) {
          if (other.id == entry.id) continue;
          if (other.normalizedWord.isEmpty ||
              other.normalizedWord == entry.normalizedWord) {
            continue;
          }
          if (other.primaryMeaning.isEmpty ||
              other.primaryMeaning == entry.primaryMeaning) {
            continue;
          }
          candidates.add(other);
        }
        // 同单元优先、相邻单元兜底：按「单元距离 → 单元内顺序」排一次。
        candidates.sort((a, b) {
          final da = (a.unitOrder - entry.unitOrder).abs();
          final db = (b.unitOrder - entry.unitOrder).abs();
          if (da != db) return da.compareTo(db);
          return a.sortNo.compareTo(b.sortNo);
        });
        result.add(
          entry.withPool(
            candidates.length >= 3
                ? candidates.map((e) => e.id).toList()
                : const <String>[],
          ),
        );
      }
    }
    return result;
  }

  /// 把选中的词变成今日题组。
  ///
  /// 方向大致各半；选项按 `seed ^ wordIdHash` 打乱后**重算答案字母**。
  /// 题干里不带答案，答案随题一起落 `word_answer`（渲染层不看它）。
  static List<WordQuestion> makeQuestions({
    required List<WordEntry> selected,
    required List<WordEntry> allEntries,
    required int seed,
    required String date,
    required WordScope scope,
    required String studentId,
  }) {
    final byId = <String, WordEntry>{for (final e in allEntries) e.id: e};
    final questions = <WordQuestion>[];
    for (var index = 0; index < selected.length; index += 1) {
      final entry = selected[index];
      final rng = Random(seed ^ _hash('${entry.id}|$date'));
      final pool = [...entry.distractorPool]..shuffle(rng);
      final distractors = <WordEntry>[];
      for (final id in pool) {
        final one = byId[id];
        if (one == null) continue;
        if (one.normalizedWord == entry.normalizedWord) continue;
        if (one.primaryMeaning == entry.primaryMeaning) continue;
        distractors.add(one);
        if (distractors.length == 3) break;
      }
      if (distractors.length < 3) continue;

      final direction = ((index + seed) % 2 == 0)
          ? WordDirection.en2zh
          : WordDirection.zh2en;
      final correctText = direction == WordDirection.en2zh
          ? entry.primaryMeaning
          : entry.word;
      final options = <String>[
        correctText,
        ...distractors.map(
          (d) => direction == WordDirection.en2zh ? d.primaryMeaning : d.word,
        ),
      ];
      // 再兜一次重复文本：不同词恰好同义 / 同名时，选项里不能有两个正解。
      final unique = <String>{};
      final deduped = options.where((o) => unique.add(o.trim())).toList();
      if (deduped.length != 4) continue;
      deduped.shuffle(rng);
      final answerIndex = deduped.indexOf(correctText);
      if (answerIndex < 0) continue;

      final stem = direction == WordDirection.en2zh
          ? '「${entry.word}」的意思是？'
          : '「${entry.primaryMeaning}」对应的单词是？';
      questions.add(
        WordQuestion(
          id: '${date}_${entry.id}_${directionName(direction)}',
          wordId: entry.id,
          word: entry.word,
          primaryMeaning: entry.primaryMeaning,
          direction: direction,
          stem: stem,
          options: deduped,
          answerIndex: answerIndex,
          bookId: scope.bookId,
          bookTitle: scope.bookTitle,
          unitMode: scope.unitMode,
          currentUnit: scope.currentUnit,
          studentId: studentId,
          date: date,
        ),
      );
    }
    return questions;
  }

  static int _hash(String text) {
    var h = 2166136261;
    for (final code in text.codeUnits) {
      h ^= code;
      h = (h * 16777619) & 0x7FFFFFFF;
    }
    return h;
  }
}
