import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:easy_learn_app/controllers/word_drill_controller.dart';
import 'package:easy_learn_app/models/word_checkin.dart';
import 'package:easy_learn_app/services/word_api.dart';
import 'package:easy_learn_app/utils/word_normalizer.dart';

/// 假本地库：内存 map，不碰 sqflite（这些判据要能在纯 Dart 环境跑）。
class _FakeLocal implements WordLocalStore {
  final Map<String, List<WordEntry>> entries = {};
  final List<WordQuestion> answers = [];
  final Map<String, String> settings = {};

  @override
  Future<void> replaceWordEntries({
    required String studentId,
    required String bookId,
    required List<WordEntry> entries,
  }) async =>
      this.entries['$studentId|$bookId'] = entries;

  @override
  Future<List<WordEntry>> queryWordEntries({
    required String studentId,
    required String bookId,
  }) async =>
      entries['$studentId|$bookId'] ?? const <WordEntry>[];

  @override
  Future<List<WordQuestion>> queryWordAnswers({required String studentId}) async =>
      answers.where((a) => a.studentId == studentId).toList();

  @override
  Future<void> insertWordAnswers(List<WordQuestion> rows) async {
    final dates = rows.map((r) => r.date).toSet();
    answers.removeWhere(
      (a) => a.studentId == rows.first.studentId && dates.contains(a.date),
    );
    answers.addAll(rows);
  }

  @override
  Future<String?> readSetting(String key) async => settings[key];

  @override
  Future<void> writeSetting(String key, String value) async =>
      settings[key] = value;
}

class _FakeRepo implements WordRepository {
  _FakeRepo({this.entries = const <WordEntry>[], this.scope});

  List<WordEntry> entries;
  WordScope? scope;
  bool offline = false;
  bool failDaily = false;
  int dailyCalls = 0;
  Map<String, dynamic>? lastDaily;
  List<WordDailyResult> dailyResults = const <WordDailyResult>[];

  @override
  Future<WordBookList> listBooks(String studentId) async => const WordBookList(
        connected: false,
        reason: 'ima_unavailable',
      );

  @override
  Future<Map<String, dynamic>> importBook({
    required String studentId,
    required String mediaId,
    String? fileName,
    String? title,
    String grade = '',
    String term = '',
  }) async =>
      <String, dynamic>{'imported': false, 'connected': false};

  @override
  Future<List<WordEntry>> listEntries({
    required String studentId,
    required String bookId,
  }) async {
    if (offline) throw Exception('offline');
    return entries;
  }

  @override
  Future<WordScope> getScope(String studentId) async {
    if (offline) throw Exception('offline');
    return scope ?? WordScope(studentId: studentId);
  }

  @override
  Future<WordScope> putScope(WordScope scope) async => scope;

  @override
  Future<void> postDaily({
    required String studentId,
    required String day,
    required int total,
    required int correct,
    required int streak,
    required List<Map<String, dynamic>> wrongWords,
  }) async {
    dailyCalls += 1;
    if (failDaily) throw Exception('offline');
    lastDaily = <String, dynamic>{
      'studentId': studentId,
      'day': day,
      'total': total,
      'correct': correct,
      'streak': streak,
      'wrongWords': wrongWords,
    };
  }

  @override
  Future<List<WordDailyResult>> listDaily({
    required String studentId,
    String? from,
    String? to,
    int limit = 30,
    int offset = 0,
  }) async =>
      dailyResults;
}

List<WordEntry> words(int count, {String bookId = 'b1'}) => List.generate(
      count,
      (i) => WordEntry(
        id: 'w$i',
        studentId: 's1',
        bookId: bookId,
        unit: 'Unit 1',
        unitOrder: 1,
        word: 'word$i',
        phonetic: '',
        primaryMeaning: '释义$i',
        normalizedWord: normalizeWord('word$i'),
        sortNo: i + 1,
      ),
    );

WordScope scopeOf({int dailyCount = 6}) => WordScope(
      studentId: 's1',
      bookId: 'b1',
      bookTitle: '七上',
      unitMode: 'all',
      currentUnit: 'Unit 1',
      units: const <String>['Unit 1'],
      dailyCount: dailyCount,
      configured: true,
    );

void main() {
  final now = DateTime(2026, 11, 11, 9);

  WordDrillController build(_FakeRepo repo, _FakeLocal local, {String student = 's1'}) =>
      WordDrillController(
        repository: repo,
        local: local,
        now: () => now,
        studentId: student,
      );

  test('有词表：出题 → 作答 → 本机立即出分 → 摘要上云', () async {
    final repo = _FakeRepo(entries: words(12), scope: scopeOf());
    final local = _FakeLocal();
    final c = build(repo, local);
    await c.loadToday();
    expect(c.questions.length, 6);
    expect(c.submitted.value, isFalse);
    expect(c.hasQuestions, isTrue);

    for (final q in c.questions) {
      c.select(q.id, q.answer); // 测试里可以读答案，渲染层不能
    }
    await c.submit();
    expect(c.isDoneToday, isTrue);
    expect(c.correctCount, 6);
    expect(local.answers.length, 6, reason: '整组一个事务落库');
    // 摘要是异步的，等一拍再断言。
    await Future<void>.delayed(Duration.zero);
    expect(repo.lastDaily?['total'], 6);
    expect(repo.lastDaily?['correct'], 6);
    expect(repo.lastDaily?['streak'], 1);
  });

  test('断网：getScope / listEntries 全失败，已缓存词表照常打卡、不抛错', () async {
    final repo = _FakeRepo(entries: words(12), scope: scopeOf());
    final local = _FakeLocal();
    final first = build(repo, local);
    await first.loadToday();
    expect(local.entries['s1|b1'], isNotEmpty, reason: '首次在线时已缓存词表');

    repo.offline = true;
    final offline = build(repo, local);
    await offline.loadToday();
    expect(offline.questions.length, 6, reason: '断网也要能出题');
    expect(offline.hint.value, isNotNull, reason: '灰字提示，不是页面级 error');
    await offline.submit();
    expect(offline.isDoneToday, isTrue, reason: '断网照样能交卷');
  });

  test('摘要失败：留 pendingSync，不回退已完成；恢复后幂等补传并清标记', () async {
    final repo = _FakeRepo(entries: words(12), scope: scopeOf())..failDaily = true;
    final local = _FakeLocal();
    final c = build(repo, local);
    await c.loadToday();
    await c.submit();
    await Future<void>.delayed(Duration.zero);
    expect(c.isDoneToday, isTrue, reason: '摘要失败绝不能把已完成改回去');
    final pending = local.settings[WordDrillController.pendingSyncKey] ?? '';
    expect(pending, isNotEmpty);
    expect(jsonDecode(pending)['total'], 6);

    repo.failDaily = false;
    final again = build(repo, local);
    await again.loadToday();
    await Future<void>.delayed(Duration.zero);
    expect(repo.lastDaily?['total'], 6, reason: '下次进页面自动补传');
    expect(local.settings[WordDrillController.pendingSyncKey], '', reason: '成功后清标记');
  });

  test('没导入词表：不抛错、不弹红条，只给灰字 hint', () async {
    final repo = _FakeRepo(entries: const <WordEntry>[], scope: WordScope(studentId: 's1'));
    final local = _FakeLocal();
    final c = build(repo, local);
    await c.loadToday();
    expect(c.questions, isEmpty);
    expect(c.hint.value, isNotNull);
    expect(c.hint.value, isNot(contains('Exception')));
  });

  test('空作答恒错；没答完也能交卷，不会卡住孩子', () async {
    final repo = _FakeRepo(entries: words(12), scope: scopeOf());
    final local = _FakeLocal();
    final c = build(repo, local);
    await c.loadToday();
    c.select(c.questions.first.id, c.questions.first.answer);
    await c.submit();
    expect(c.correctCount, 1);
    expect(c.questions.where((q) => q.picked.isEmpty).length, 5);
    expect(c.questions.where((q) => q.correct).length, 1);
  });

  test('同一天重进：还原那组题和作答，不重选、不丢进度', () async {
    final repo = _FakeRepo(entries: words(12), scope: scopeOf());
    final local = _FakeLocal();
    final first = build(repo, local);
    await first.loadToday();
    final ids = first.questions.map((q) => q.id).toList();
    first.select(ids.first, 'A');
    final reused = build(repo, local);
    await reused.loadToday();
    expect(reused.questions.map((q) => q.id).toList(), ids);
    // 进行中（没提交）不清已选；提交后重进是「已完成」回放。
    final submitted = build(repo, local);
    await submitted.loadToday();
    await submitted.submit();
    final replay = build(repo, local);
    await replay.loadToday();
    expect(replay.isDoneToday, isTrue);
    expect(replay.questions.map((q) => q.id).toList(), ids);
  });

  test('家长改范围：已作答未交卷的那组不被冲掉；还没作答则按新范围重出', () async {
    final repo = _FakeRepo(entries: words(12), scope: scopeOf());
    final local = _FakeLocal();

    // ① 孩子已经选了几题（进行中），家长这时改范围 —— 这组题不能换，
    //    否则「改一半的答案」会落到一套完全不同的题上。
    final started = build(repo, local);
    await started.loadToday();
    final ids = started.questions.map((q) => q.id).toList();
    expect(ids.length, 6);
    started.select(ids.first, 'A');

    repo.scope = scopeOf(dailyCount: 4);
    repo.entries = words(12).reversed.toList();
    await started.loadToday();

    expect(started.questions.map((q) => q.id).toList(), ids,
        reason: '进行中的一组题按「当天锁定」处理，改范围不重算');
    expect(started.chosen[ids.first], 'A', reason: '已选的答案不能被冲掉');

    // ② 今天还没作答：题不落盘，所以下一次进页面就是新范围 ——
    //    这是真实行为，文案必须照实说（旧文案写「次日生效」，与这里不符）。
    final fresh = build(repo, local);
    await fresh.loadToday();
    expect(fresh.questions.length, 4, reason: '未作答时按新范围出题');
  });

  test('切学生：不同学生不同组，且本地缓存按 studentId 隔离', () async {
    final repo = _FakeRepo(entries: words(12), scope: scopeOf());
    final local = _FakeLocal();
    final a = build(repo, local, student: 's1');
    final b = build(repo, local, student: 's2');
    await a.loadToday();
    await b.loadToday();
    expect(a.questions.map((q) => q.id).toList(),
        isNot(b.questions.map((q) => q.id).toList()));
    expect(local.entries.containsKey('s2|b1'), isTrue);
  });

  test('错词 Top5 进摘要，且只报答错的词', () async {
    final repo = _FakeRepo(entries: words(12), scope: scopeOf());
    final local = _FakeLocal();
    final c = build(repo, local);
    await c.loadToday();
    // 全部不作答：6 题全错 → wrongWords 应有 5 条（Top5 截断由服务端也做一份）。
    await c.submit();
    await Future<void>.delayed(Duration.zero);
    final wrong = repo.lastDaily?['wrongWords'] as List<dynamic>? ?? const [];
    expect(wrong.length, 5);
    expect(wrong.every((one) => (one['count'] as int) >= 1), isTrue);
  });
}
