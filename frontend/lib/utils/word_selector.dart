import 'dart:math';

import '../models/word_checkin.dart';
import 'drill_selector.dart' show drillSeedFor;

/// 单词打卡的「今天练哪些词」：范围过滤 + 掌握度加权 + 日期种子抽样。
///
/// 种子直接复用 `DrillSelector` 导出的 `drillSeedFor`（同一个 FNV-1a 实现），
/// 不再抄一份哈希 —— 抄一份的话，「同一天同学生同组」这条纪律会有两个版本。
/// 权重公式与 `doc/word-checkin-design.md` §5.4.4 一一对应。
class WordSelector {
  WordSelector._();

  static const int freshnessDays = 3;
  static const int weightWindowDays = 30;

  static String dateKeyOf(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static int seedFor(String studentId, DateTime date) =>
      drillSeedFor(studentId, dateKeyOf(date));

  /// 四种单元模式。单元顺序取 `scope.units`（MD 里 `##` 出现顺序），不按文本排序。
  ///
  /// ⚠️ `learned` 只取第 1 → `currentUnit`；`currentUnit` 不在单元列表里时
  /// 返回空集（配置与词表不一致），**不放行整本** —— 静默扩到未学的单元，
  /// 家长要过很久才会发现孩子在做 Unit 12 的词。
  static List<WordEntry> filterByScope(
    List<WordEntry> entries,
    WordScope scope,
  ) {
    if (!scope.hasBook) return const <WordEntry>[];
    final inBook = entries
        .where((e) => e.bookId == scope.bookId)
        .where((e) => e.distractorPool.length >= 3)
        .toList();
    final units = scope.units.isNotEmpty
        ? scope.units
        : _unitsFromEntries(inBook);
    final currentIndex = units.indexOf(scope.currentUnit);

    bool allowed(String unit) {
      switch (scope.unitMode) {
        case 'current':
          return currentIndex >= 0 && unit == scope.currentUnit;
        case 'learned':
          if (currentIndex < 0) return false;
          final index = units.indexOf(unit);
          return index >= 0 && index <= currentIndex;
        case 'selected':
          return scope.selectedUnits.contains(unit);
        case 'all':
          return true;
        default:
          return false;
      }
    }

    return inBook.where((e) => allowed(e.unit)).toList();
  }

  static List<String> _unitsFromEntries(List<WordEntry> entries) {
    final seen = <String>{};
    final result = <String>[];
    final sorted = [...entries]
      ..sort((a, b) => a.unitOrder != b.unitOrder
          ? a.unitOrder.compareTo(b.unitOrder)
          : a.sortNo.compareTo(b.sortNo));
    for (final e in sorted) {
      if (seen.add(e.unit)) result.add(e.unit);
    }
    return result;
  }

  /// 从 `word_answer` 派生每个词的掌握度（近 30 天）。不建 word_miss 表。
  static Map<String, WordWeight> weightsFromAnswers(
    List<WordQuestion> answers,
    DateTime now,
  ) {
    final today = DateTime(now.year, now.month, now.day);
    final cutoff = today.subtract(const Duration(days: weightWindowDays));
    final freshCutoff = today.subtract(const Duration(days: freshnessDays));
    final byWord = <String, List<WordQuestion>>{};
    for (final a in answers) {
      final day = DateTime.tryParse(a.date);
      if (day == null || day.isBefore(cutoff)) continue;
      (byWord[a.wordId] ??= <WordQuestion>[]).add(a);
    }
    final weights = <String, WordWeight>{};
    byWord.forEach((wordId, list) {
      list.sort((a, b) => b.date.compareTo(a.date));
      var wrongCount = 0;
      for (final a in list) {
        if (!a.correct) wrongCount += 1;
      }
      var consecutiveCorrect = 0;
      for (final a in list) {
        if (a.correct) {
          consecutiveCorrect += 1;
        } else {
          break;
        }
      }
      final lastDay = DateTime.tryParse(list.first.date);
      final seenRecently = lastDay != null && !lastDay.isBefore(freshCutoff);
      weights[wordId] = WordWeight(
        wrongCount: wrongCount,
        consecutiveCorrect: consecutiveCorrect,
        seenRecently: seenRecently,
      );
    });
    return weights;
  }

  static double weightOf(WordWeight? weight) {
    if (weight == null) return 1.5; // 从没做过：新词优先
    var w = 1.0;
    w *= 1 + 0.6 * min(weight.wrongCount, 5);
    if (weight.consecutiveCorrect >= 2) w *= 0.25;
    if (weight.seenRecently) w *= 0.2;
    return w;
  }

  /// 同一天同学生 → 同一组；换天 / 切学生 → 不同组。
  /// 种子**不带 bookId**：同一天、同一范围下重进拿到的是同一组题
  /// （已作答 / 已交卷的组由控制器直接还原，不重选；见 §5.4.3）。
  static List<WordEntry> pick({
    required String studentId,
    required DateTime date,
    required List<WordEntry> candidates,
    required List<WordQuestion> history,
    required int size,
  }) {
    if (size <= 0 || candidates.isEmpty) return const <WordEntry>[];
    final rng = Random(seedFor(studentId, date));
    final weights = weightsFromAnswers(history, date);
    final scored = <MapEntry<WordEntry, double>>[];
    for (final entry in candidates) {
      final w = weightOf(weights[entry.id]);
      final key = pow(rng.nextDouble(), 1 / max(w, 1e-9)).toDouble();
      scored.add(MapEntry(entry, key));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(min(size, scored.length)).map((e) => e.key).toList();
  }

  /// 连续打卡天数（含今天）。与 `DrillController._refreshStreak` 同口径。
  static int streakOf(List<WordQuestion> answers, String dateKey) {
    final dates = answers.map((a) => a.date).toSet();
    if (!dates.contains(dateKey)) return 0;
    var count = 0;
    final start = DateTime.tryParse(dateKey);
    if (start == null) return 0;
    DateTime cursor = start;
    while (dates.contains(dateKeyOf(cursor))) {
      count += 1;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return count;
  }
}

class WordWeight {
  const WordWeight({
    required this.wrongCount,
    required this.consecutiveCorrect,
    required this.seenRecently,
  });

  final int wrongCount;
  final int consecutiveCorrect;
  final bool seenRecently;
}
