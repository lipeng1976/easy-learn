import 'dart:async';

import 'package:easy_learn_app/controllers/checkin_controller.dart';
import 'package:easy_learn_app/models/checkin_models.dart';
import 'package:easy_learn_app/repositories/checkin_repository.dart';
import 'package:easy_learn_app/services/checkin_question_parser.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 打卡控制器的状态机判据。
///
/// 这里的重点已经不是「分数对不对」（那是 [CheckinSubmitResult.judge] 的事），
/// 而是**判分与落盘是两件事**：
///
///  1. 交卷那一瞬就有结果，不等网络（弱网下这是唯一能接受的体验）；
///  2. 落盘失败**不撤销**已经显示的结果，但要如实标「未同步」；
///  3. 服务端回来后换成服务端那份；两边分数不一致时
///     [CheckinRun.syncConflict] 必须亮。
///
/// 第 3 条是两处判分漂移的**唯一信号**。如果只是静默采用服务端，分数看着正常、
/// 家长端也正常，只有孩子当场看到的那个数不一样 —— 永远不会有人发现。
///
/// 另外 2026-10-27 起**每出一份就是一份独立试卷**（不再「一天一科目只许
/// 一份」）：同一天同科目出三次就是三份，旧的题与成绩一律保留。
class _FakeRepo implements CheckinRepository {
  // 字段都用级联赋值（`..quizzes = ...`），所以不需要构造参数 ——
  // 给了也没人传，徒增「这个参数到底是谁在用」的疑问。
  List<CheckinQuiz> quizzes = const [];
  int generateCalls = 0;
  int submitCalls = 0;
  int seedCalls = 0;
  String? lastGenerateDate;
  int? lastGenerateCount;
  String? lastDifficulty;
  String? lastSubject;
  List<String> lastKnowledgePoints = const [];
  Map<int, String> lastPicked = {};
  List<CheckinSeed> seeds = const [];
  Object? loadError;
  Object? generateError;
  Object? seedError;

  /// 交卷接口的实现（默认回一份和本地判定一致的分数，带 ima 标记）。
  Future<CheckinSubmitResult> Function()? onSubmit;

  @override
  @override
  Future<List<CheckinSubjectSummary>> subjectSummaries({String? studentId}) async =>
      // 假仓库不做分组：需要汇总数字的用例自己给一份（见
      // `checkin_subject_summary_test.dart`）。默认空 = 页面退回平铺列表。
      const <CheckinSubjectSummary>[];

  @override
  Future<CheckinQuizPage> getQuizzes({
    String? studentId,
    CheckinQuizStatus status = CheckinQuizStatus.all,
    // 按科目过滤由真仓库下到 SQL；假仓库不实现（用例只关心分区与分页）。
    String subject = '',
    int limit = 0,
    int offset = 0,
  }) async {
    final failure = loadError;
    if (failure != null) throw failure;
    // 与真仓库同口径：按「成绩行在不在」分未完成 / 已完成，再翻页。
    // 不在这里复刻这个过滤的话，`status` 传错、或者把 done 那份塞进
    // 未完成列表，用例都会绿 —— 那正是这次要守的东西。
    final List<CheckinQuiz> filtered;
    if (status == CheckinQuizStatus.pending) {
      filtered = quizzes.where((q) => q.submittedResult == null).toList();
    } else if (status == CheckinQuizStatus.done) {
      filtered = quizzes.where((q) => q.submittedResult != null).toList();
    } else {
      filtered = quizzes;
    }
    final page = limit > 0
        ? filtered.skip(offset).take(limit).toList()
        : filtered.skip(offset).toList();
    return CheckinQuizPage(
      items: page,
      total: filtered.length,
      hasMore: limit > 0 && offset + page.length < filtered.length,
    );
  }

  @override
  Future<List<CheckinSeed>> loadSeeds({String? studentId, String? subject}) async {
    seedCalls += 1;
    final failure = seedError;
    if (failure != null) throw failure;
    return seeds;
  }

  @override
  Future<CheckinQuiz> generate({
    String? studentId,
    required String quizDate,
    String subject = '数学',
    int count = 5,
    List<String> knowledgePoints = const [],
    String difficulty = '',
  }) async {
    generateCalls += 1;
    lastGenerateDate = quizDate;
    lastGenerateCount = count;
    lastSubject = subject;
    // 原样记下来，包括顺序：家长勾的顺序就是「先考哪个」。
    lastKnowledgePoints = List.of(knowledgePoints);
    lastDifficulty = difficulty;
    final failure = generateError;
    if (failure != null) throw failure;
    return CheckinQuiz(
      // id 带上科目与次数，重出数学时能断言「真的是换了新卷」。
      id: 'server_id_${subject}_$generateCalls',
      studentId: studentId ?? 'stu_1',
      quizDate: quizDate,
      subject: subject,
      difficulty: difficulty,
      // 真实响应**带答案**：交卷时本机立刻判对错要用它。
      // 前两题答案是 B / C，其余题给 D。
      questions: [
        for (var i = 0; i < count; i++)
          CheckinQuestion(
            stem: '第 ${i + 1} 题',
            options: const ['1', '2', '3', '4'],
            answer: switch (i) { 0 => 'B', 1 => 'C', _ => 'D' },
            knowledge: '有理数混合运算',
            type: CheckinQuestionType.choice,
          ),
      ],
    );
  }

  @override
  Future<CheckinSubmitResult> submit({
    required String quizId,
    required Map<int, String> picked,
  }) async {
    submitCalls += 1;
    lastPicked = Map.of(picked);
    final custom = onSubmit;
    if (custom != null) return custom();
    return _serverResult(quizId: quizId, score: 2);
  }

  /// 服务端那份：分数由调用方指定，`imaSynced` 置 true 用来区分
  /// 「已经换成服务端结果了」还是「还停在本机算的那份」。
  CheckinSubmitResult _serverResult({required String quizId, required int score}) {
    return CheckinSubmitResult(
      quizId: quizId,
      score: score,
      total: 2,
      items: const [
        CheckinItemResult(index: 0, picked: 'B', answer: 'B', correct: true),
        CheckinItemResult(index: 1, picked: 'C', answer: 'C', correct: true),
      ],
      imaSynced: true,
    );
  }

  CheckinSubmitResult serverWithScore(int score) =>
      _serverResult(quizId: 'server_id', score: score);
}

CheckinController _build({required _FakeRepo repo, DateTime? now}) {
  return CheckinController(
    repository: repo,
    clock: () => now ?? DateTime(2026, 10, 27, 9),
  );
}

/// 发起一组两题的打卡，并把两题都选对（B / C）。
Future<(CheckinController, CheckinRun)> _ready(_FakeRepo repo) async {
  final controller = _build(repo: repo);
  await controller.start(count: 2);
  final run = controller.runs.single;
  controller.pick(run, 0, 'B');
  controller.pick(run, 1, 'C');
  return (controller, run);
}

void main() {
  test('日期用本地日，且补零（服务端按字符串比较选「今天」）', () {
    expect(CheckinController.formatDate(DateTime(2026, 10, 7, 23, 30)), '2026-10-07');
    expect(CheckinController.formatDate(DateTime(2026, 1, 1)), '2026-01-01');
  });

  test('读取失败要显示成错误，不能伪装成「今天没题」', () async {
    final repo = _FakeRepo()
      ..loadError = const DataApiException(code: 'network', message: 'boom', retryable: true);
    final controller = _build(repo: repo);

    await controller.load();

    expect(controller.runs, isEmpty);
    // network 走 userMessage 的专用文案，不是底层异常的原文
    expect(controller.error.value, contains('网络'));
  });

  test('今天没题是正常状态：runs 为空且没有错误', () async {
    final controller = _build(repo: _FakeRepo());

    await controller.load();

    expect(controller.runs, isEmpty);
    expect(controller.error.value, isNull);
  });

  test('已交过卷的打卡：load 之后直接进结果态（家长打开就能看到分数）', () async {
    final repo = _FakeRepo()
      ..quizzes = [
        const CheckinQuiz(
          id: 'q_done',
          studentId: 'stu_1',
          quizDate: '2026-10-27',
          questions: <CheckinQuestion>[],
          status: 'done',
          submittedResult: CheckinSubmitResult(
            quizId: 'q_done',
            score: 4,
            total: 5,
            items: <CheckinItemResult>[],
          ),
        ),
      ];
    final controller = _build(repo: repo);

    await controller.load();

    final run = controller.runs.single;
    expect(run.submitted, isTrue);
    expect(run.result.value!.score, 4);
    expect(run.result.value!.total, 5);
    // 不能再让家长/学生进答题态：重答会覆盖掉已有的成绩。
    expect(run.allAnswered, isFalse);
  });

  test('一天多份打卡：load 原样恢复每一份，各自独立状态', () async {
    final repo = _FakeRepo()
      ..quizzes = [
        const CheckinQuiz(
          id: 'q_math',
          studentId: 'stu_1',
          quizDate: '2026-10-27',
          subject: '数学',
          status: 'done',
          submittedResult: CheckinSubmitResult(
            quizId: 'q_math',
            score: 3,
            total: 3,
            items: <CheckinItemResult>[],
          ),
          questions: <CheckinQuestion>[],
        ),
        const CheckinQuiz(
          id: 'q_eng',
          studentId: 'stu_1',
          quizDate: '2026-10-27',
          subject: '英语',
          status: 'pending',
          questions: <CheckinQuestion>[],
        ),
      ];
    final controller = _build(repo: repo);

    await controller.load();

    // 2026-10-29 起分成两个列表，`runs` 只是「未完成 + 已完成」的拼合视图，
    // **顺序不再是服务端顺序**（未完成在前）。所以这里按 id 找，不按下标 ——
    // 按下标断言的写法在分区规则一调整时就会红，而那种红指向的是"顺序变了"
    // 而不是"数据错了"。
    expect(controller.runs.length, 2);
    expect(controller.pendingRuns.map((r) => r.quiz.value.subject), ['英语'],
        reason: '已交卷的那份不该留在未完成里');
    expect(controller.doneRuns.map((r) => r.quiz.value.subject), ['数学']);
    final math = controller.runFor('q_math');
    expect(math?.submitted, isTrue);
    expect(controller.doneTotal.value, 1, reason: '总份数里已完成 1 份，入口卡据此算还剩几份');
  });

  test('错题本是空的时候不编题：服务端那句原因要原样显示', () async {
    final repo = _FakeRepo()
      ..generateError = const DataApiException(
        code: 'bad_request',
        message: '错题本还是空的，先录几道错题再来发起打卡吧。',
      );
    final controller = _build(repo: repo);

    final ok = await controller.start();

    expect(ok, isFalse);
    expect(repo.generateCalls, 1, reason: '要问过服务端才知道错题本空不空');
    expect(controller.error.value, contains('错题本'));
    expect(controller.runs, isEmpty);
  });

  test('发起成功：只调一次 generate，日期是本地日，采纳服务端返回的 id', () async {
    final repo = _FakeRepo();
    final controller = _build(repo: repo);

    final ok = await controller.start(count: 2);

    expect(ok, isTrue);
    expect(repo.generateCalls, 1);
    expect(repo.lastGenerateDate, '2026-10-27', reason: '日期必须是本地日，不是 UTC');
    expect(repo.lastGenerateCount, 2);
    expect(controller.runs.single.quiz.value.questions.length, 2);
    expect(
      controller.runs.single.quiz.value.id,
      contains('server_id'),
      reason: '必须采纳服务端返回的 id（R2：客户端不自己定主键）',
    );
    expect(controller.error.value, isNull);
  });

  test('一天多份：不同科目各自一份，互不覆盖', () async {
    final repo = _FakeRepo();
    final controller = _build(repo: repo);

    await controller.start(subject: '数学', count: 2);
    await controller.start(subject: '英语', count: 2);

    expect(controller.runs.length, 2);
    expect(
      controller.runs.map((r) => r.quiz.value.subject),
      containsAll(['数学', '英语']),
    );
  });

  test('同科目重复出题 = 多份并存，旧卷与其它科目都不受影响', () async {
    final repo = _FakeRepo();
    final controller = _build(repo: repo);

    await controller.start(subject: '数学', count: 2);
    await controller.start(subject: '英语', count: 2);
    final englishBefore = controller.runs
        .firstWhere((r) => r.quiz.value.subject == '英语')
        .quiz
        .value
        .id;
    final mathBefore = controller.runs
        .firstWhere((r) => r.quiz.value.subject == '数学')
        .quiz
        .value
        .id;

    await controller.start(subject: '数学', count: 3);

    // 家长随便出几套：三份都在（数学×2 + 英语×1）。
    expect(controller.runs.length, 3, reason: '每出一次就是一份新试卷，不能替换旧的');
    final maths = controller.runs.where((r) => r.quiz.value.subject == '数学').toList();
    expect(maths.length, 2, reason: '同科目两份并存');
    expect(
      maths.map((r) => r.quiz.value.id),
      contains(mathBefore),
      reason: '先前那套数学必须原样留着（旧卷不许被删）',
    );
    expect(maths.last.quiz.value.id, isNot(mathBefore), reason: '新卷有自己的新 id');
    expect(maths.last.quiz.value.questions.length, 3);
    expect(
      controller.runs
          .firstWhere((r) => r.quiz.value.subject == '英语')
          .quiz
          .value
          .id,
      englishBefore,
      reason: '英语那份必须原封不动',
    );
  });

  test('家长选的范围原样交给服务端，顺序就是优先级', () async {
    final repo = _FakeRepo();
    final controller = _build(repo: repo);

    final ok = await controller.start(
      count: 3,
      subject: '数学',
      knowledgePoints: const ['有理数混合运算', '解一元一次方程'],
      difficulty: '提高',
    );

    expect(ok, isTrue);
    // 顺序不能被打乱：家长把「一元一次方程」放前面，就是要先考它。
    expect(repo.lastKnowledgePoints, ['有理数混合运算', '解一元一次方程']);
    expect(repo.lastDifficulty, '提高');
    // 难度要回到模型上，学生端标题栏才能显示「提高」。
    expect(controller.runs.single.quiz.value.difficulty, '提高');
  });

  test('没指定范围时传空，不替用户编一个默认难度', () async {
    final repo = _FakeRepo();
    final controller = _build(repo: repo);

    await controller.start(count: 2);

    expect(repo.lastKnowledgePoints, isEmpty, reason: '空 = 让服务端按错题本自动挑');
    expect(
      repo.lastDifficulty,
      '',
      reason: '空串表示「没要求」。塞个「基础」会让统计里多出一批没人选过的题',
    );
  });

  test('读知识点候选失败：只写错误，不抛（家长还能手输）', () async {
    final repo = _FakeRepo()
      ..seedError = const DataApiException(code: 'network', message: 'boom', retryable: true);
    final controller = _build(repo: repo);

    await controller.loadSeeds();

    expect(controller.seeds, isEmpty);
    expect(controller.error.value, contains('网络'));
    expect(controller.seedsLoading.value, isFalse, reason: '转圈必须停，否则配置页永远在加载');
  });

  test('读知识点候选成功：带错次，家长靠它判断先练哪个', () async {
    final repo = _FakeRepo()
      ..seeds = const [
        CheckinSeed(knowledge: '幂的运算', wrongCount: 3),
        CheckinSeed(knowledge: '图形想象', wrongCount: 1),
      ];
    final controller = _build(repo: repo);

    await controller.loadSeeds();

    expect(repo.seedCalls, 1);
    expect(controller.seeds.length, 2);
    expect(controller.seeds.first.knowledge, '幂的运算');
    expect(controller.seeds.first.wrongCount, 3);
  });

  test('出题失败：把服务端的原因说给用户（不是笼统的「失败了」）', () async {
    final repo = _FakeRepo()
      ..generateError = const DataApiException(
        code: 'model_unavailable',
        message: 'AI 网关暂时不可用，请稍后重试',
        retryable: true,
      );
    final controller = _build(repo: repo);

    final ok = await controller.start();

    expect(ok, isFalse);
    expect(controller.error.value, contains('稍后重试'));
    // 失败后 busy 必须复位，否则「发起」按钮会永远转圈
    expect(controller.busy.value, isFalse);
  });

  test('正在发起时再点一次不会重复出题（busy 防重入）', () async {
    final repo = _FakeRepo();
    final controller = _build(repo: repo);

    final first = controller.start(count: 2);
    final second = controller.start(count: 2);
    expect(await second, isFalse, reason: '第二次点击必须被挡掉');
    expect(await first, isTrue);
    expect(repo.generateCalls, 1);
  });

  group('本地判分', () {
    CheckinQuestion q(String answer, {CheckinQuestionType type = CheckinQuestionType.choice}) {
      return CheckinQuestion(
        stem: '题',
        options: const ['1', '2', '3', '4'],
        answer: answer,
        knowledge: '知识点',
        analysis: '解析里也写着答案',
        type: type,
      );
    }

    test('全对', () {
      final result = CheckinSubmitResult.judge(
        quizId: 'q',
        questions: [q('B'), q('C')],
        picked: {0: 'B', 1: 'C'},
      );
      expect(result.score, 2);
      expect(result.total, 2);
      expect(result.items.every((item) => item.correct), isTrue);
      // 本机算出来的那份，必须自报「还没存档」。
      expect(result.synced, isFalse);
    });

    test('没选的题恒为错（不给「漏答算对」留口子）', () {
      final result = CheckinSubmitResult.judge(
        quizId: 'q',
        questions: [q('B'), q('C')],
        picked: {0: 'B'},
      );
      expect(result.score, 1);
      expect(result.items[1].picked, '');
      expect(result.items[1].correct, isFalse);
    });

    test('题目里没有答案时判错，不是判对', () {
      final result = CheckinSubmitResult.judge(
        quizId: 'q',
        questions: [q(''), q('C')],
        picked: {0: 'B', 1: 'C'},
      );
      expect(result.items[0].correct, isFalse);
      expect(result.score, 1);
    });

    test('大小写与空格归一（与服务端同口径）', () {
      final result = CheckinSubmitResult.judge(
        quizId: 'q',
        questions: [q('b'), q('T', type: CheckinQuestionType.judge)],
        picked: {0: ' b ', 1: 't'},
      );
      expect(result.score, 2, reason: '两边都 trim+大写后再比，服务端就是这么写的');
    });

    test('计入结果的是题目数量，不是作答条数', () {
      final result = CheckinSubmitResult.judge(
        quizId: 'q',
        questions: [q('B'), q('C'), q('D')],
        picked: {0: 'B'},
      );
      expect(result.total, 3, reason: '漏答的题也要出现在结果里，否则家长看不到漏了哪题');
      expect(result.items.length, 3);
    });
  });

  group('交卷', () {
    test('没答完不许交卷，且提示还差几题', () async {
      final repo = _FakeRepo();
      final controller = _build(repo: repo);
      await controller.start(count: 2);
      final run = controller.runs.single;
      controller.pick(run, 0, 'B');

      final ok = await controller.submit(run);

      expect(ok, isFalse);
      expect(repo.submitCalls, 0);
      expect(controller.error.value, contains('还有 1 题'));
    });

    test('交卷那一瞬就出结果，不等网络', () async {
      final gate = Completer<CheckinSubmitResult>();
      final repo = _FakeRepo()..onSubmit = (() => gate.future);
      final (controller, run) = await _ready(repo);

      final pending = controller.submit(run); // 故意不 await：模拟网络还挂着

      expect(run.submitted, isTrue, reason: '结果必须在请求返回前就显示');
      expect(run.result.value!.score, 2);
      expect(run.result.value!.synced, isFalse, reason: '此时还没存档');
      expect(run.busy.value, isTrue);

      gate.complete(repo.serverWithScore(2));
      expect(await pending, isTrue);
      expect(run.result.value!.synced, isTrue, reason: '存好后换成服务端那份');
      expect(run.syncError.value, isNull);
      expect(run.busy.value, isFalse);
    });

    test('存档成功后用服务端那份（带 ima 状态）', () async {
      final repo = _FakeRepo();
      final (controller, run) = await _ready(repo);

      final ok = await controller.submit(run);

      expect(ok, isTrue);
      expect(repo.submitCalls, 1);
      expect(repo.lastPicked, {0: 'B', 1: 'C'});
      expect(run.result.value!.imaSynced, isTrue);
    });

    test('存档失败：保留已算出的分数，标「未同步」，选择也不清空', () async {
      final repo = _FakeRepo()
        ..onSubmit = (() async => throw const DataApiException(
              code: 'network',
              message: 'boom',
              retryable: true,
            ));
      final (controller, run) = await _ready(repo);

      final ok = await controller.submit(run);

      expect(ok, isFalse, reason: '返回值说的是「没存上」，不是「没判分」');
      expect(run.submitted, isTrue, reason: '分数已经算出来了，不能撤回去');
      expect(run.result.value!.score, 2);
      expect(run.result.value!.synced, isFalse);
      expect(run.syncError.value, contains('网络'));
      expect(run.picked, {0: 'B', 1: 'C'});
      expect(run.busy.value, isFalse);
    });

    test('重试存档：不重新判分，成功后就变成已同步', () async {
      var failFirst = true;
      final repo = _FakeRepo();
      repo.onSubmit = () async {
        if (failFirst) {
          failFirst = false;
          throw const DataApiException(code: 'network', message: 'boom', retryable: true);
        }
        return repo.serverWithScore(2);
      };
      final (controller, run) = await _ready(repo);
      await controller.submit(run);
      expect(run.syncError.value, isNotNull);

      final ok = await controller.retrySync(run);

      expect(ok, isTrue);
      expect(repo.submitCalls, 2);
      expect(run.result.value!.synced, isTrue);
      expect(run.syncError.value, isNull);
    });

    test('两处判分不一致时 syncConflict 要亮（这是漂移的唯一信号）', () async {
      final repo = _FakeRepo();
      repo.onSubmit = () async => repo.serverWithScore(1); // 故意少给 1 分
      final (controller, run) = await _ready(repo);

      await controller.submit(run);

      expect(run.syncConflict.value, isTrue);
      // 最终显示仍以服务端为准（它是存档真值）。
      expect(run.result.value!.score, 1);
    });

    test('一致时 syncConflict 保持 false（负对照的另一半）', () async {
      final (controller, run) = await _ready(_FakeRepo());

      await controller.submit(run);

      expect(run.syncConflict.value, isFalse);
    });
  });

  /// 跨天 + 分区 + 分页（2026-10-29）。
  ///
  /// 用户原话：「昨天出的题目，学生端今天能看到有未完成的，但点进去又没有」。
  /// 根因是 `load()` 只查 `quizDate = 今天`；同时计划页入口卡也按「今天」算，
  /// 两处一起把「昨天那份没做的事」变成了看不见。
  group('跨天与分页', () {
    CheckinQuiz quizOf(String id, String date, {bool done = false}) => CheckinQuiz(
          id: id,
          studentId: 'stu_1',
          quizDate: date,
          subject: '数学',
          status: done ? 'done' : 'pending',
          submittedResult: done
              ? CheckinSubmitResult(quizId: id, score: 1, total: 1, items: const [])
              : null,
          // 至少一题：`submit()` 对空卷直接返回 false（那是「还没出题」的兜底），
          // 用它测「交完卷会不会挪列表」会一直走不到落盘那一步。
          questions: const [
            CheckinQuestion(
              stem: '1+1=?',
              options: ['1', '2'],
              answer: 'B',
              knowledge: '',
              type: CheckinQuestionType.choice,
            ),
          ],
        );

    test('昨天出的题今天还在「未完成」里（不再按天过滤）', () async {
      final repo = _FakeRepo()
        ..quizzes = [
          quizOf('q_yesterday', '2026-10-28'),
          quizOf('q_today', '2026-10-29'),
        ];
      // 时钟拨到 10-29：昨天的卷子仍必须出现。
      final controller = _build(repo: repo, now: DateTime(2026, 10, 29, 8));
      await controller.load();

      expect(
        controller.pendingRuns.map((r) => r.quiz.value.id),
        ['q_yesterday', 'q_today'],
        reason: '按天过滤的话，昨天那份今天点进去根本不存在 —— 用户报的就是这条',
      );
    });

    test('交完一份：它从「未完成」挪到「已完成」最前面', () async {
      final repo = _FakeRepo()
        ..quizzes = [quizOf('q_a', '2026-10-28'), quizOf('q_b', '2026-10-29')]
        ..onSubmit = () async => const CheckinSubmitResult(
              quizId: 'q_b',
              score: 0,
              total: 0,
              items: [],
            );
      final controller = _build(repo: repo);
      await controller.load();

      final run = controller.pendingRuns.first; // q_a
      controller.pick(run, 0, 'B');
      await controller.submit(run);

      expect(controller.pendingRuns.map((r) => r.quiz.value.id), ['q_b'],
          reason: '交完的那份不能还留在待做里');
      expect(controller.doneRuns.first.quiz.value.id, 'q_a',
          reason: '已完成按交卷时间倒序，刚交的排最前');
      expect(controller.doneTotal.value, 1);
    });

    test('加载更多：按 offset 追加，不重复、不丢', () async {
      final repo = _FakeRepo()
        ..quizzes = [
          for (var i = 0; i < 15; i++) quizOf('q_$i', '2026-10-2$i', done: true),
        ];
      final controller = _build(repo: repo);
      await controller.load();

      expect(controller.doneRuns.length, CheckinController.donePageSize,
          reason: '第一页只该拿一页的量');
      expect(controller.doneTotal.value, 15);
      expect(controller.doneHasMore.value, isTrue);

      await controller.loadMoreDone();

      expect(controller.doneRuns.length, 15);
      expect(controller.doneHasMore.value, isFalse, reason: '没有下一页了就别再挂按钮');
      final ids = controller.doneRuns.map((r) => r.quiz.value.id).toList();
      expect(ids.toSet().length, ids.length, reason: '翻页不能插出重复项');
    });
  });
}
