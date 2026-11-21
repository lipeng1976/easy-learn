import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:easy_learn_app/models/word_checkin.dart';
import 'package:easy_learn_app/utils/word_normalizer.dart';
import 'package:easy_learn_app/utils/word_question_generator.dart';
import 'package:easy_learn_app/utils/word_selector.dart';

WordEntry entry(
  String id,
  String word,
  String meaning, {
  String unit = 'Unit 1',
  int unitOrder = 1,
  int sortNo = 1,
  String bookId = 'b1',
  List<String> pool = const <String>[],
}) =>
    WordEntry(
      id: id,
      studentId: 's1',
      bookId: bookId,
      unit: unit,
      unitOrder: unitOrder,
      word: word,
      phonetic: '',
      primaryMeaning: meaning,
      normalizedWord: normalizeWord(word),
      sortNo: sortNo,
      distractorPool: pool,
    );

List<WordEntry> unit(List<List<String>> words, int unitOrder) => [
      for (var i = 0; i < words.length; i += 1)
        entry(
          'u${unitOrder}_$i',
          words[i][0],
          words[i][1],
          unit: 'Unit $unitOrder',
          unitOrder: unitOrder,
          sortNo: i + 1,
        ),
    ];

WordScope scope({
  String bookId = 'b1',
  String mode = 'learned',
  String currentUnit = 'Unit 1',
  List<String> selected = const <String>[],
  List<String> units = const <String>['Unit 1', 'Unit 2', 'Unit 3'],
  int dailyCount = 10,
}) =>
    WordScope(
      studentId: 's1',
      bookId: bookId,
      bookTitle: '七上',
      unitMode: mode,
      currentUnit: currentUnit,
      selectedUnits: selected,
      units: units,
      dailyCount: dailyCount,
      configured: true,
    );

void main() {
  final date = DateTime(2026, 11, 11);

  test('干扰项池：同单元、排除同词与同义项、只在同一本书内', () {
    final entries = [
      ...unit([
        ['hello', '你好'],
        ['name', '名字'],
        ['nice', '好的'],
        ['meet', '遇见'],
        ['book', '书'],
        ['hi', '你好'], // 与 hello 同义项，必须被排除
      ], 1),
      entry('other_book', 'desk', '书桌', bookId: 'b2', unitOrder: 2),
    ];
    final pooled = WordQuestionGenerator.buildPools(entries);
    final hello = pooled.firstWhere((e) => e.id == 'u1_0');
    expect(hello.distractorPool.length, 4, reason: 'hi 与 hello 同义项，不能进池');
    expect(hello.distractorPool, isNot(contains('u1_5')));
    expect(hello.distractorPool, isNot(contains('other_book')), reason: '跨书的词不能进池');
  });

  test('池不足扩到相邻单元；整本仍不足的单元不出题', () {
    final sparse = [
      ...unit([
        ['a', '甲'],
        ['b', '乙'],
        ['c', '丙'],
      ], 1),
      ...unit([
        ['d', '丁'],
        ['e', '戊'],
        ['f', '己'],
      ], 2),
    ];
    final pooled = WordQuestionGenerator.buildPools(sparse);
    expect(pooled.first.distractorPool.length, 5, reason: '同单元 2 个 + 相邻单元 3 个');

    final alone = WordQuestionGenerator.buildPools(sparse.take(3).toList());
    expect(alone.every((e) => e.distractorPool.isEmpty), isTrue);
    expect(
      WordSelector.filterByScope(alone, scope()),
      isEmpty,
      reason: '池 < 3 的词不能出题，宁可少一题',
    );
  });

  test('成题：4 个不重复选项、答案字母与正确项一致、双向都有', () {
    final entries = WordQuestionGenerator.buildPools(
      unit([
        ['hello', '你好'],
        ['name', '名字'],
        ['nice', '好的'],
        ['meet', '遇见'],
        ['book', '书'],
        ['pen', '钢笔'],
      ], 1),
    );
    final selected = entries.take(6).toList();
    final questions = WordQuestionGenerator.makeQuestions(
      selected: selected,
      allEntries: entries,
      seed: WordSelector.seedFor('s1', date),
      date: WordSelector.dateKeyOf(date),
      scope: scope(),
      studentId: 's1',
    );
    expect(questions.length, 6);
    expect(questions.map((q) => q.direction).toSet().length, 2, reason: '英→中 / 中→英都要有');
    for (final q in questions) {
      expect(q.options.length, 4);
      expect(q.options.toSet().length, 4, reason: '不能有重复选项 = 两个正确答案');
      final correctText = q.direction == WordDirection.en2zh
          ? q.primaryMeaning
          : q.word;
      expect(q.options[q.answerIndex], correctText, reason: '打乱后答案字母必须重算');
      expect(q.answer, String.fromCharCode(65 + q.answerIndex));
    }
  });

  test('判分：trim + 大写 + 字符串相等，空作答恒错', () {
    final q = WordQuestion(
      id: 'q1',
      wordId: 'w1',
      word: 'hello',
      primaryMeaning: '你好',
      direction: WordDirection.en2zh,
      stem: '「hello」的意思是？',
      options: ['名字', '你好', '书', '钢笔'],
      answerIndex: 1,
      bookId: 'b1',
      bookTitle: '七上',
      unitMode: 'learned',
      currentUnit: 'Unit 1',
    );
    expect(q.judge(' b '), isTrue);
    expect(q.judge('B'), isTrue);
    expect(q.judge(''), isFalse, reason: '空作答不能算对');
    expect(q.judge(null), isFalse);
    expect(q.judge('A'), isFalse);
  });

  test('日期种子：同学生同日同组、换天不同组、切学生不同组', () {
    final entries = WordQuestionGenerator.buildPools(
      unit([
        ['hello', '你好'],
        ['name', '名字'],
        ['nice', '好的'],
        ['meet', '遇见'],
        ['book', '书'],
        ['pen', '钢笔'],
        ['desk', '书桌'],
        ['chair', '椅子'],
      ], 1),
    );
    List<String> idsFor(String student, DateTime day) => WordSelector.pick(
          studentId: student,
          date: day,
          candidates: entries,
          history: const <WordQuestion>[],
          size: 4,
        ).map((e) => e.id).toList();
    expect(idsFor('s1', date), idsFor('s1', date), reason: '同一天重进必须是同一组');
    expect(idsFor('s1', date), isNot(idsFor('s1', DateTime(2026, 11, 12))));
    expect(idsFor('s1', date), isNot(idsFor('s2', date)), reason: '切学生必须是另一组');
  });

  test('四种单元模式：learned 只取第 1→当前单元；只从当前一本', () {
    final entries = <WordEntry>[
      ...unit([
        ['a', '甲'], ['b', '乙'], ['c', '丙'], ['d', '丁'],
      ], 1).map((e) => e.withPool(['x', 'y', 'z'])),
      ...unit([
        ['e', '戊'], ['f', '己'], ['g', '庚'], ['h', '辛'],
      ], 2).map((e) => e.withPool(['x', 'y', 'z'])),
      ...unit([
        ['i', '壬'], ['j', '癸'], ['k', '子'], ['l', '丑'],
      ], 3).map((e) => e.withPool(['x', 'y', 'z'])),
      entry('other', 'desk', '书桌', bookId: 'b2').withPool(['x', 'y', 'z']),
    ];
    List<String> unitsOf(WordScope s) => WordSelector.filterByScope(entries, s)
        .map((e) => e.unit)
        .toSet()
        .toList();

    expect(unitsOf(scope(mode: 'current', currentUnit: 'Unit 2')), ['Unit 2']);
    expect(
      unitsOf(scope(mode: 'learned', currentUnit: 'Unit 2')).toSet(),
      {'Unit 1', 'Unit 2'},
      reason: 'Unit 3 不能跑到已学区间里',
    );
    expect(
      unitsOf(scope(mode: 'selected', selected: ['Unit 3'])),
      ['Unit 3'],
    );
    expect(unitsOf(scope(mode: 'all')).toSet(), {'Unit 1', 'Unit 2', 'Unit 3'});
    expect(
      WordSelector.filterByScope(entries, scope(bookId: 'b2')).every((e) => e.bookId == 'b2'),
      isTrue,
      reason: '当前书以外的词不能进候选集',
    );
    expect(
      unitsOf(scope(currentUnit: '不存在的单元')),
      isEmpty,
      reason: '配置与词表不一致时不能静默扩到整本',
    );
  });

  test('错词权重：答错 boost、连对 2 次降权、近 3 天降新鲜度、新词优先', () {
    WordQuestion answer(String wordId, String day, bool correct) => WordQuestion(
          id: '${day}_$wordId',
          wordId: wordId,
          word: wordId,
          primaryMeaning: '义',
          direction: WordDirection.en2zh,
          stem: '?',
          options: const ['A', 'B', 'C', 'D'],
          answerIndex: 1,
          bookId: 'b1',
          bookTitle: '',
          unitMode: 'learned',
          currentUnit: 'Unit 1',
          date: day,
          correct: correct,
          createdAt: day,
        );
    final history = <WordQuestion>[
      // 错词放在 4 天前：仍在 30 天权重窗口内，但已过 3 天新鲜度窗口 ——
      // 否则「错题 boost」会被新鲜度因子盖住，测的就不是 boost 了。
      answer('w1', '2026-11-05', false),
      answer('w1', '2026-11-04', false),
      answer('w2', '2026-11-10', true),
      answer('w2', '2026-11-09', true),
      answer('w3', '2026-11-10', true),
    ];
    final weights = WordSelector.weightsFromAnswers(history, date);
    expect(WordSelector.weightOf(weights['w1']), greaterThan(1.5), reason: '错词要 boost');
    expect(WordSelector.weightOf(weights['w2']), lessThan(1.0), reason: '连对 2 次降权');
    expect(
      WordSelector.weightOf(weights['w3']),
      lessThan(WordSelector.weightOf(null)),
      reason: '近 3 天出过的词要降新鲜度，且低于「从没做过」',
    );
    expect(WordSelector.weightOf(null), 1.5);
  });

  test('池固定但每日抽选项：同一个词跨天选项顺序不能一模一样', () {
    final entries = WordQuestionGenerator.buildPools(
      unit([
        ['hello', '你好'],
        ['name', '名字'],
        ['nice', '好的'],
        ['meet', '遇见'],
        ['book', '书'],
        ['pen', '钢笔'],
        ['desk', '书桌'],
        ['chair', '椅子'],
      ], 1),
    );
    final selected = entries.take(1).toList();

    // seed 故意固定：方向由 `(index + seed) % 2` 决定，锁住它才能只观察
    // 「同一天/同一词」的选项排列；否则方向一换，题干和选项全变，
    // 固定顺序的假实现也能靠方向变化蒙混过关。
    List<String> optionsOn(DateTime day) => WordQuestionGenerator.makeQuestions(
          selected: selected,
          allEntries: entries,
          seed: 12345,
          date: WordSelector.dateKeyOf(day),
          scope: scope(),
          studentId: 's1',
        ).single.options;

    final orders = <String>{};
    for (var i = 0; i < 8; i += 1) {
      orders.add(optionsOn(DateTime(2026, 11, 11 + i)).join('|'));
    }
    expect(orders.length, greaterThan(1),
        reason: '8 天全同一种排列 ⇒ 孩子会背 C 是答案，而不是背单词');
  });

  test('源码契约：答题卡片不看答案；范围不写裸 app_setting key', () {
    final page = File('lib/pages/student/word_drill_page.dart').readAsStringSync();
    final card = page.substring(page.indexOf('class _QuestionCard'), page.indexOf('class _OptionTile'));
    expect(card.contains('question.answer'), isFalse);
    expect(card.contains('answerIndex'), isFalse);

    // 只看控制器本体：文件顶部的 _DatabaseWordLocalStore 是存储适配层，
    // 它当然要调用 sqflite 的 writeLocalSetting；判据关心的是控制器有没有
    // 把「练习范围」当成裸 app_setting key 直接写。
    final controller =
        File('lib/controllers/word_drill_controller.dart').readAsStringSync();
    final body = controller.substring(controller.indexOf('class WordDrillController'));
    expect(body.contains('app_setting'), isFalse);
    expect(body.contains('word.currentUnit'), isFalse,
        reason: '范围不落本地裸 key（切孩子会串）');
    expect(body.contains("_local.writeSetting("), isTrue,
        reason: 'pendingSync / 只读快照都走 WordLocalStore 抽象');
    expect(body.contains("'studentId': studentId"), isTrue,
        reason: '范围只读快照必须绑 studentId，断网回退时不能串孩子');
  });
}
