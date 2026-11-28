import 'package:easy_learn_app/controllers/checkin_controller.dart';
import 'package:easy_learn_app/controllers/point_controller.dart';
import 'package:easy_learn_app/models/checkin_models.dart';
import 'package:easy_learn_app/models/point_model.dart';
import 'package:easy_learn_app/repositories/checkin_repository.dart';
import 'package:easy_learn_app/repositories/point_repository.dart';
import 'package:easy_learn_app/services/checkin_question_parser.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 每日练习（「今天练什么」）交卷后的积分口径。
///
/// 这里守的四条，每一条错了都不会报错，只会让「分不对」：
///
///  1. 完成就有分 —— 与对错无关；
///  2. 全对**再**加一笔，不是把完成那笔抬高；
///  3. 家长把某一项关掉，那一项就不发（另一项照发）；
///  4. 重试存档 / 重复交卷**不重复记账** —— 幂等键是 quizId。
///
/// 另外还守一条降级：记账失败不能把「已经存好的卷」变成一次失败。

class _FakeCheckinRepo implements CheckinRepository {
  _FakeCheckinRepo();

  /// 每组固定两题：第一题答案 B、第二题 C。
  static const int questions = 2;
  int submitCalls = 0;
  CheckinQuiz? lastQuiz;

  /// 非空 = 交卷接口抛这个错（模拟断网 / 服务端 500）。
  Object? submitError;

  @override
  Future<List<CheckinSubjectSummary>> subjectSummaries({String? studentId}) async =>
      const <CheckinSubjectSummary>[];

  @override
  Future<CheckinQuizPage> getQuizzes({
    String? studentId,
    CheckinQuizStatus status = CheckinQuizStatus.all,
    String subject = '',
    int limit = 0,
    int offset = 0,
  }) async => const CheckinQuizPage(items: [], total: 0, hasMore: false);

  @override
  Future<List<CheckinSeed>> loadSeeds({String? studentId, String? subject}) async =>
      const <CheckinSeed>[];

  @override
  Future<CheckinQuiz> generate({
    String? studentId,
    required String quizDate,
    String subject = '数学',
    int count = 5,
    List<String> knowledgePoints = const [],
    String difficulty = '',
  }) async {
    final quiz = CheckinQuiz(
      id: 'ck_test',
      studentId: studentId ?? 'stu_1',
      quizDate: quizDate,
      subject: subject,
      questions: [
        for (var i = 0; i < questions; i++)
          CheckinQuestion(
            stem: '第 ${i + 1} 题',
            options: const ['1', '2', '3', '4'],
            answer: i == 0 ? 'B' : 'C',
            knowledge: '有理数',
            type: CheckinQuestionType.choice,
          ),
      ],
    );
    lastQuiz = quiz;
    return quiz;
  }

  /// 与真服务端同口径：按作答判分（服务端复算）。
  @override
  Future<CheckinSubmitResult> submit({
    required String quizId,
    required Map<int, String> picked,
  }) async {
    submitCalls += 1;
    final failure = submitError;
    if (failure != null) throw failure;
    final quiz = lastQuiz!;
    var score = 0;
    final items = <CheckinItemResult>[];
    for (var i = 0; i < quiz.questions.length; i++) {
      final answer = quiz.questions[i].answer;
      final got = (picked[i] ?? '').toUpperCase();
      final ok = got == answer.toUpperCase();
      if (ok) score += 1;
      items.add(
        CheckinItemResult(index: i, picked: got, answer: answer, correct: ok),
      );
    }
    return CheckinSubmitResult(
      quizId: quizId,
      score: score,
      total: quiz.questions.length,
      items: items,
    );
  }
}

class _FakePointRepo implements PointRepository {
  _FakePointRepo({this.rules = const <PointRule>[], this.failInsert = false});

  final List<PointRule> rules;
  final bool failInsert;

  final List<PointLedgerEntry> entries = [];

  @override
  Future<List<PointLedgerEntry>> queryPointLedger(String studentId) async =>
      List.unmodifiable(entries.reversed);

  @override
  Future<List<PointRule>> queryPointRules(String studentId) async => rules;

  @override
  Future<void> upsertPointRule(PointRule rule) async {}

  // 本文件只测打卡发分，用不到行为配置；返回空表等价于「没配过行为」。
  @override
  Future<List<PointBehavior>> queryPointBehaviors(String studentId) async =>
      const [];

  @override
  Future<void> upsertPointBehavior(PointBehavior behavior) async {}

  @override
  Future<void> deletePointBehavior(String studentId, String id) async {}

  @override
  Future<PointLedgerEntry?> findActivePointEntry({
    required String studentId,
    required String idempotencyKey,
  }) async {
    for (final entry in entries) {
      if (entry.studentId == studentId &&
          entry.idempotencyKey == idempotencyKey &&
          entry.reversedAt == null) {
        return entry;
      }
    }
    return null;
  }

  @override
  Future<bool> insertPointLedger(PointLedgerEntry entry) async {
    if (failInsert) throw StateError('积分仓库挂了');
    // 真实现的原子保证由唯一索引给；这里只复刻「同一个键只有一条活记录」。
    if (await findActivePointEntry(
          studentId: entry.studentId,
          idempotencyKey: entry.idempotencyKey,
        ) !=
        null) {
      return false;
    }
    entries.add(entry);
    return true;
  }

  @override
  Future<void> markPointEntryReversed(String id, DateTime reversedAt) async {}
}

class _Harness {
  _Harness({List<PointRule> rules = const <PointRule>[], bool failInsert = false})
      : checkin = _FakeCheckinRepo(),
        pointRepo = _FakePointRepo(rules: rules, failInsert: failInsert) {
    points = PointController(repository: pointRepo);
    controller = CheckinController(
      repository: checkin,
      clock: () => DateTime(2026, 11, 16, 20),
      points: points,
    );
  }

  final _FakeCheckinRepo checkin;
  final _FakePointRepo pointRepo;
  late final PointController points;
  late final CheckinController controller;

  /// 发起一组两题，然后按 [correct] 决定答对几题。
  Future<CheckinRun> submitWith({int correct = 2}) async {
    await controller.start(studentId: 'stu_1', count: 2);
    final run = controller.pendingRuns.single;
    for (var i = 0; i < 2; i++) {
      // 正确答案是 B / C。
      if (i < correct) {
        controller.pick(run, i, i == 0 ? 'B' : 'C');
      } else {
        controller.pick(run, i, i == 0 ? 'A' : 'D');
      }
    }
    await controller.submit(run);
    return run;
  }

  List<String> get codes => pointRepo.entries.map((e) => e.action).toList();
}

void main() {
  test('完成就记一笔，与对错无关', () async {
    final harness = _Harness();
    await harness.submitWith(correct: 1);

    expect(harness.codes, [PointAction.checkinCompleted.code]);
    expect(harness.pointRepo.entries.single.points, 5);
    expect(harness.pointRepo.entries.single.refId, 'ck_test');
  });

  test('全对再加一笔，不是把完成那笔抬高', () async {
    final harness = _Harness();
    await harness.submitWith(correct: 2);

    expect(harness.codes, [
      PointAction.checkinCompleted.code,
      PointAction.checkinAllCorrect.code,
    ]);
    // 两笔各自 5 分，合计 10 —— 不是「一笔 10 分」。
    expect(harness.pointRepo.entries.map((e) => e.points).toList(), [5, 5]);
  });

  test('全对的两笔用不同的幂等键，不会互相撞掉', () async {
    final harness = _Harness();
    await harness.submitWith(correct: 2);

    final keys = harness.pointRepo.entries.map((e) => e.idempotencyKey).toSet();
    expect(keys.length, 2);
    expect(keys, containsAll(<String>[
      PointController.checkinKey('ck_test'),
      PointController.checkinCorrectKey('ck_test'),
    ]));
  });

  test('家长把「完成」关掉：完成那笔不发，全对那笔照发', () async {
    final harness = _Harness(
      rules: [
        PointRule(
          studentId: 'stu_1',
          action: PointAction.checkinCompleted,
          points: 5,
          enabled: false,
          updatedAt: DateTime(2026, 11, 16),
        ),
      ],
    );
    await harness.submitWith(correct: 2);

    expect(harness.codes, [PointAction.checkinAllCorrect.code]);
  });

  test('分值按家长设置走，不用默认值', () async {
    final harness = _Harness(
      rules: [
        PointRule(
          studentId: 'stu_1',
          action: PointAction.checkinCompleted,
          points: 8,
          updatedAt: DateTime(2026, 11, 16),
        ),
        PointRule(
          studentId: 'stu_1',
          action: PointAction.checkinAllCorrect,
          points: 12,
          updatedAt: DateTime(2026, 11, 16),
        ),
      ],
    );
    await harness.submitWith(correct: 2);

    expect(harness.pointRepo.entries.map((e) => e.points).toList(), [8, 12]);
  });

  test('重试存档不会重复记账（同一个 quizId 只有一个键）', () async {
    final harness = _Harness();
    final run = await harness.submitWith(correct: 2);
    expect(harness.pointRepo.entries.length, 2);

    // 模拟「交卷其实成功了但响应丢了」→ 用户点重试。
    await harness.controller.retrySync(run);

    expect(harness.pointRepo.entries.length, 2);
    expect(harness.checkin.submitCalls, 2);
  });

  test('记账失败不影响交卷结果 —— 卷已经存好了，分是奖励不是账目真相', () async {
    final harness = _Harness(failInsert: true);
    final run = await harness.submitWith(correct: 2);

    expect(run.result.value, isNotNull);
    expect(run.result.value!.score, 2);
    expect(harness.pointRepo.entries, isEmpty);
  });

  test('交卷失败（未存到服务端）不发分', () async {
    final harness = _Harness();
    await harness.controller.start(studentId: 'stu_1', count: 2);
    final run = harness.controller.pendingRuns.single;
    // 一题都不选 → 交卷被前端拦住，不进 _store。
    await harness.controller.submit(run);

    expect(harness.pointRepo.entries, isEmpty);
    expect(harness.checkin.submitCalls, 0);
  });

  test('存档请求失败时不发分 —— 分和卷必须成套', () async {
    final harness = _Harness();
    harness.checkin.submitError = const DataApiException(
      code: 'network',
      message: '连不上',
      retryable: true,
    );
    await harness.controller.start(studentId: 'stu_1', count: 2);
    final run = harness.controller.pendingRuns.single;
    harness.controller.pick(run, 0, 'B');
    harness.controller.pick(run, 1, 'C');

    final ok = await harness.controller.submit(run);

    expect(ok, isFalse);
    expect(run.syncError.value, isNotNull);
    // 卷没存上却发了分的话，家长端会看到「打卡 +5」而找不到那份卷。
    expect(harness.pointRepo.entries, isEmpty);
  });

  group('分值设置表', () {
    test('两个新动作都出现在家长可配置清单里', () {
      expect(kConfigurablePointActions, contains(PointAction.checkinCompleted));
      expect(kConfigurablePointActions, contains(PointAction.checkinAllCorrect));
    });

    test('默认分值与说明文案都在，且不是空串', () {
      for (final action in [
        PointAction.checkinCompleted,
        PointAction.checkinAllCorrect,
      ]) {
        expect(action.defaultPoints, 5);
        expect(action.label, isNotEmpty);
        expect(action.hint, isNotEmpty);
        expect(action.isDeduction, isFalse);
        expect(action.configurable, isTrue);
      }
    });

    test('落库标识稳定（改名等于数据迁移，这里钉一下）', () {
      expect(PointAction.checkinCompleted.code, 'checkinCompleted');
      expect(PointAction.checkinAllCorrect.code, 'checkinAllCorrect');
    });
  });
}
