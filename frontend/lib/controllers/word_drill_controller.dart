import 'dart:async';
import 'dart:convert';

import 'package:get/get.dart';

import '../models/word_checkin.dart';
import '../services/database_service.dart';
import '../services/word_api.dart';
import '../utils/word_question_generator.dart';
import '../utils/word_selector.dart';
import 'auth_controller.dart';

/// 单词打卡的本地存取契约（抽成接口是为了让「断网可打卡 / 摘要失败不回退」
/// 这两条判据能不依赖真 sqflite 就跑）。
abstract class WordLocalStore {
  Future<void> replaceWordEntries({
    required String studentId,
    required String bookId,
    required List<WordEntry> entries,
  });

  Future<List<WordEntry>> queryWordEntries({
    required String studentId,
    required String bookId,
  });

  Future<List<WordQuestion>> queryWordAnswers({required String studentId});

  Future<void> insertWordAnswers(List<WordQuestion> answers);

  Future<String?> readSetting(String key);

  Future<void> writeSetting(String key, String value);
}

class _DatabaseWordLocalStore implements WordLocalStore {
  const _DatabaseWordLocalStore();

  @override
  Future<void> replaceWordEntries({
    required String studentId,
    required String bookId,
    required List<WordEntry> entries,
  }) =>
      DatabaseService.instance.replaceWordEntries(
        studentId: studentId,
        bookId: bookId,
        entries: entries,
      );

  @override
  Future<List<WordEntry>> queryWordEntries({
    required String studentId,
    required String bookId,
  }) =>
      DatabaseService.instance.queryWordEntries(
        studentId: studentId,
        bookId: bookId,
      );

  @override
  Future<List<WordQuestion>> queryWordAnswers({required String studentId}) =>
      DatabaseService.instance.queryWordAnswers(studentId: studentId);

  @override
  Future<void> insertWordAnswers(List<WordQuestion> answers) =>
      DatabaseService.instance.insertWordAnswers(answers);

  @override
  Future<String?> readSetting(String key) =>
      DatabaseService.instance.readLocalSetting(key);

  @override
  Future<void> writeSetting(String key, String value) =>
      DatabaseService.instance.writeLocalSetting(key, value);
}

/// 每日单词打卡：**本地为主，云上只是摘要**。
///
/// 出题、判分、错词权重、连续天数全在本机；服务端只有词表真值、练习范围
/// 与一份成绩摘要。断网时用已缓存词表照常出题，摘要失败只留 pending 标记，
/// **绝不回退「已完成」、绝不抛红错**（11-07 硬规矩）。
class WordDrillController extends GetxController {
  WordDrillController({
    WordRepository? repository,
    WordLocalStore? local,
    DateTime Function()? now,
    String? studentId,
  })  : _repository = repository ?? DatabaseService.word,
        _local = local ?? const _DatabaseWordLocalStore(),
        _now = now ?? DateTime.now,
        _injectedStudentId = studentId;

  final WordRepository _repository;
  final WordLocalStore _local;
  final DateTime Function() _now;
  final String? _injectedStudentId;

  static const String pendingSyncKey = 'word.pendingSync';

  /// 范围的**只读缓存快照**（不是真值）。真值永远在服务端 `word_scope`。
  /// 值与 `studentId` 绑在一起，切孩子读不到别人的范围；断网时才有东西可用。
  static const String scopeCacheKey = 'word.scopeCache';

  final RxList<WordQuestion> questions = <WordQuestion>[].obs;
  final RxMap<String, String> chosen = <String, String>{}.obs;
  final RxBool isLoading = false.obs;
  final RxBool submitted = false.obs;
  final RxInt streak = 0.obs;
  final RxnString hint = RxnString();
  final RxString scopeLabel = ''.obs;

  /// 每次加载代号 +1：快速切学生 / 刷新时，迟到的旧响应不能覆盖新题组。
  int _generation = 0;

  String? get _studentId =>
      _injectedStudentId ??
      (Get.isRegistered<AuthController>()
          ? Get.find<AuthController>().currentUser.value?.id
          : null);

  bool get hasQuestions => questions.isNotEmpty;
  bool get isDoneToday => submitted.value && questions.isNotEmpty;
  int get correctCount => questions.where((q) => q.correct).length;

  int get answeredCount => chosen.values.where((v) => v.trim().isNotEmpty).length;

  /// 加载（或还原）今天的一组题。三态与 `DrillController.loadToday` 同构。
  Future<void> loadToday() async {
    final generation = ++_generation;
    final studentId = _studentId;
    if (studentId == null || studentId.isEmpty) {
      hint.value = '未登录，无法加载单词打卡';
      return;
    }
    isLoading.value = true;
    hint.value = null;
    try {
      unawaited(_retryPendingSync());
      final dateKey = WordSelector.dateKeyOf(_now());
      final history = await _local.queryWordAnswers(studentId: studentId);
      if (generation != _generation) return;

      final todays = history.where((a) => a.date == dateKey).toList();
      if (todays.isNotEmpty) {
        questions.assignAll(todays);
        chosen.clear();
        for (final a in todays) {
          chosen[a.id] = a.picked;
        }
        submitted.value = true;
        streak.value = WordSelector.streakOf(history, dateKey);
        scopeLabel.value = _snapshotLabel(todays.first);
        return;
      }

      // 进行中不重选：切 tab 回来时，已作答的几题不能被新题冲掉。
      if (questions.isNotEmpty &&
          !submitted.value &&
          chosen.isNotEmpty &&
          questions.first.date == dateKey) {
        return;
      }

      WordScope scope;
      try {
        scope = await _repository.getScope(studentId);
        await _local.writeSetting(
          scopeCacheKey,
          jsonEncode(<String, dynamic>{
            'studentId': studentId,
            'bookId': scope.bookId,
            'bookTitle': scope.bookTitle,
            'unitMode': scope.unitMode,
            'currentUnit': scope.currentUnit,
            'selectedUnits': scope.selectedUnits,
            'units': scope.units,
            'dailyCount': scope.dailyCount,
            'configured': scope.configured,
          }),
        );
      } catch (_) {
        // 断网 / 服务端没部署：用上次的只读快照（带 studentId，不会串孩子）。
        scope = await _cachedScope(studentId) ?? WordScope(studentId: studentId);
        hint.value = '暂时读不到练习范围，用的是本机缓存的词表。';
      }
      if (generation != _generation) return;

      var entries = <WordEntry>[];
      if (scope.hasBook) {
        try {
          final fresh = await _repository.listEntries(
            studentId: studentId,
            bookId: scope.bookId,
          );
          if (fresh.isNotEmpty) {
            final pooled = WordQuestionGenerator.buildPools(fresh);
            await _local.replaceWordEntries(
              studentId: studentId,
              bookId: scope.bookId,
              entries: pooled,
            );
            entries = pooled;
          }
        } catch (_) {
          // 断网 / 服务端没部署：不报错，用缓存。
        }
        if (entries.isEmpty) {
          entries = await _local.queryWordEntries(
            studentId: studentId,
            bookId: scope.bookId,
          );
        }
      }
      if (generation != _generation) return;

      final candidates = WordSelector.filterByScope(entries, scope);
      final picked = WordSelector.pick(
        studentId: studentId,
        date: _now(),
        candidates: candidates,
        history: history,
        size: scope.dailyCount,
      );
      final built = WordQuestionGenerator.makeQuestions(
        selected: picked,
        allEntries: entries,
        seed: WordSelector.seedFor(studentId, _now()),
        date: dateKey,
        scope: scope,
        studentId: studentId,
      );
      questions.assignAll(built);
      chosen.clear();
      submitted.value = false;
      streak.value = WordSelector.streakOf(history, dateKey);
      scopeLabel.value = _scopeLabel(scope);
      if (built.isEmpty) {
        hint.value = scope.hasBook
            ? '当前范围内可练的词还不够，请家长检查一下单元范围或词表。'
            : '还没有导入教材词表，请家长在计划页里配置。';
      } else if (built.length < scope.dailyCount) {
        hint.value = '今日可练 ${built.length} 题（选项不足的词不出题）。';
      }
    } catch (_) {
      if (generation != _generation) return;
      hint.value = '暂时读不到词表，已缓存的内容仍可打卡。';
    } finally {
      if (generation == _generation) isLoading.value = false;
    }
  }

  Future<WordScope?> _cachedScope(String studentId) async {
    try {
      final raw = await _local.readSetting(scopeCacheKey);
      if (raw == null || raw.trim().isEmpty) return null;
      final json = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (json['studentId'] != studentId) return null;
      return WordScope.fromJson(json, studentId: studentId);
    } catch (_) {
      return null;
    }
  }

  String _scopeLabel(WordScope scope) {
    const names = <String, String>{
      'current': '仅当前单元',
      'learned': '已学区间',
      'selected': '指定单元',
      'all': '整本',
    };
    return '${scope.bookTitle.isEmpty ? '当前词表' : scope.bookTitle} · '
        '${names[scope.unitMode] ?? scope.unitMode} · 每天 ${scope.dailyCount} 题';
  }

  String _snapshotLabel(WordQuestion question) =>
      '${question.bookTitle.isEmpty ? '当时用的词表' : question.bookTitle} · '
      '${question.unitMode} · ${question.currentUnit}';

  void select(String questionId, String letter) {
    if (submitted.value) return;
    chosen[questionId] = letter;
  }

  /// 提交：本机立即判分 → 整组事务落 `word_answer` → 三态切「已完成」。
  Future<void> submit() async {
    final studentId = _studentId;
    if (studentId == null || studentId.isEmpty || questions.isEmpty) return;
    if (submitted.value) return;
    final dateKey = WordSelector.dateKeyOf(_now());
    final createdAt = _now().toIso8601String();
    final records = <WordQuestion>[];
    for (final q in questions) {
      final picked = (chosen[q.id] ?? '').trim();
      records.add(
        q.copyWith(
          studentId: studentId,
          date: dateKey,
          picked: picked,
          correct: q.judge(picked),
          createdAt: createdAt,
        ),
      );
    }
    try {
      await _local.insertWordAnswers(records);
      questions.assignAll(records);
      submitted.value = true;
      final history = await _local.queryWordAnswers(studentId: studentId);
      streak.value = WordSelector.streakOf(history, dateKey);
      unawaited(_syncDaily(records));
    } catch (_) {
      // 本机写入失败是**真失败**：不能假装已完成（那会让成绩静默丢掉）。
      hint.value = '本机记录没写上，请再交一次；题目和答案还在。';
    }
  }

  Future<void> _syncDaily(List<WordQuestion> records) async {
    if (records.isEmpty) return;
    final first = records.first;
    final wrong = <String, int>{};
    for (final r in records) {
      if (!r.correct) wrong[r.word] = (wrong[r.word] ?? 0) + 1;
    }
    final sorted = wrong.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final payload = <String, dynamic>{
      'studentId': first.studentId,
      'day': first.date,
      'total': records.length,
      'correct': records.where((r) => r.correct).length,
      'streak': streak.value,
      'wrongWords': sorted
          .take(5)
          .map((e) => <String, dynamic>{'word': e.key, 'count': e.value})
          .toList(),
    };
    try {
      await _repository.postDaily(
        studentId: first.studentId,
        day: first.date,
        total: payload['total'] as int,
        correct: payload['correct'] as int,
        streak: streak.value,
        wrongWords: (payload['wrongWords'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      );
      await _local.writeSetting(pendingSyncKey, '');
    } catch (_) {
      // 摘要失败：留 pending，下次进页面重试。不回退「已完成」、不弹红条。
      await _local.writeSetting(pendingSyncKey, jsonEncode(payload));
    }
  }

  Future<void> _retryPendingSync() async {
    try {
      final raw = await _local.readSetting(pendingSyncKey);
      if (raw == null || raw.trim().isEmpty) return;
      final payload = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      await _repository.postDaily(
        studentId: (payload['studentId'] ?? '').toString(),
        day: (payload['day'] ?? '').toString(),
        total: payload['total'] as int? ?? 0,
        correct: payload['correct'] as int? ?? 0,
        streak: payload['streak'] as int? ?? 0,
        wrongWords: (payload['wrongWords'] as List<dynamic>? ?? const <dynamic>[])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      );
      await _local.writeSetting(pendingSyncKey, '');
    } catch (_) {
      // 留着下次再试；可选同步永不拖垮主流程。
    }
  }

  Future<void> retry() => loadToday();
}
