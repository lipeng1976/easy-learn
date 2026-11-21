import 'dart:io';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/review_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/checkin_models.dart';
import 'package:easy_learn_app/models/knowledge_tip.dart';
import 'package:easy_learn_app/models/mistake_figure.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/services/ai_data_source.dart';
import 'package:easy_learn_app/services/checkin_question_parser.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/services/judgement_ab.dart';
import 'package:easy_learn_app/services/simulated_ai_data_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';
import 'helpers/fake_exporter.dart';

/// 判定规则与模型的 A/B 影子比对。
///
/// 这一套断言的重点**不是「一致率算得对不对」**，而是三个容易做假的地方：
/// 1. 弃权（规则说「判不了」）不能被算成分歧 —— 那是在惩罚诚实；
/// 2. 没有可比样本时一致率必须是「无」，不能是 0 或 100%；
/// 3. 比对只观察，**不能反向改写学生看到的判定结论**。
///
/// 前两条决定了这个数字可不可信，第三条决定了它会不会反过来伤人。

/// 假装是云端：结论标成 [AiAnswerSource.cloud]，且可以指定一个固定判定，
/// 用来构造「模型与规则结论不同」的场景。
class _FakeCloudAi implements AiDataSource {
  _FakeCloudAi({required this.verdict});

  final AnswerVerdict verdict;
  int judgeCalls = 0;

  @override
  Future<List<MistakeTipDraft>> summarizeMistakeTips({
    required String subject,
    required List<MistakeTipSeed> items,
  }) async => const <MistakeTipDraft>[];

  // 打卡出题与这条判据无关，但接口新增方法后必须实现 —— 返回空表，
  // 让任何误用它的用例立刻在断言上暴露，而不是抛 UnimplementedError。
  @override
  Future<List<CheckinQuestion>> generateCheckinQuestions({
    required String subject,
    required List<CheckinSeed> items,
    int count = 5,
  }) async => const <CheckinQuestion>[];

  // 同理：讲解配图与判定无关，返回「不画」。
  @override
  Future<MistakeFigure> generateFigure({
    required String subject,
    required String knowledgePoint,
    String title = '',
    String questionBody = '',
    String wrongReason = '',
    String referenceAnswer = '',
    String studentProcess = '',
    List<AiSourceImage> images = const [],
  }) async => const MistakeFigure(reason: '测试用例不画图');


  @override
  Future<AnswerJudgement> judgeAnswer({
    required String studentAnswer,
    required String referenceAnswer,
    String subject = '',
    String knowledgePoint = '',
    String questionContent = '',
  }) async {
    judgeCalls++;
    return AnswerJudgement(
      verdict: verdict,
      score: verdict == AnswerVerdict.correct ? 100 : 0,
      comment: '模型给的结论（测试替身）',
      source: AiAnswerSource.cloud,
    );
  }

  @override
  Future<HomeworkCheckOutcome> checkHomework({
    required String subject,
    required String title,
    List<String> imagePaths = const [],
  }) async => const HomeworkCheckOutcome(score: 0, summary: '', items: []);

  @override
  Future<AnswerRecognition> recognizeAnswer({
    required List<String> imagePaths,
    String questionContent = '',
    String knowledgePoint = '',
  }) async => throw UnimplementedError();

  @override
  Future<MistakeExtraction> extractMistakes({
    required List<String> imagePaths,
    String hint = '',
  }) async => throw UnimplementedError();

  @override
  Future<MistakeExplanation> explainMistake({
    required String subject,
    required String knowledgePoint,
    required String title,
    required String wrongReason,
    String questionBody = '',
    List<AiSourceImage> images = const [],
    String referenceAnswer = '',
    String studentProcess = '',
  }) async => throw UnimplementedError();

  @override
  Future<List<GeneratedQuestion>> generatePractice({
    required String subject,
    required String knowledgePoint,
    String difficulty = '基础',
    int round = 1,
    int count = 3,
    List<AiSourceImage> images = const [],
  }) async => throw UnimplementedError();

  @override
  Future<String> referenceAnswerFor({
    required String subject,
    required String knowledgePoint,
  }) async => const SimulatedAiDataSource().referenceAnswerFor(
    subject: subject,
    knowledgePoint: knowledgePoint,
  );

  @override
  Future<Map<String, String>> referenceAnswersFor(
    List<ReferenceQuery> queries,
  ) => referenceAnswersByLoop(this, queries);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  // ===== 纯口径 =====

  group('比对口径', () {
    test('两侧都定了且相同 → 一致', () {
      const ab = JudgementAB(
        modelVerdict: AnswerVerdict.correct,
        ruleVerdict: AnswerVerdict.correct,
      );
      expect(ab.agreement, JudgementAgreement.agree);
      expect(ab.comparable, isTrue);
    });

    test('两侧都定了但不同 → 分歧（这才是模型值钱的地方）', () {
      const ab = JudgementAB(
        modelVerdict: AnswerVerdict.correct,
        ruleVerdict: AnswerVerdict.wrong,
      );
      expect(ab.agreement, JudgementAgreement.disagree);
    });

    test('规则弃权**不算**分歧：它是判不了，不是判错', () {
      const ab = JudgementAB(
        modelVerdict: AnswerVerdict.correct,
        ruleVerdict: AnswerVerdict.inconclusive,
      );
      expect(ab.agreement, JudgementAgreement.abstained);
      expect(ab.comparable, isFalse);
      expect(
        ab.agreement,
        isNot(JudgementAgreement.disagree),
        reason: '把弃权并进分歧会得出「规则很差劲」的假象，'
            '进而把本来能零成本判定的题继续推给模型',
      );
    });
  });

  group('一致率', () {
    JudgementABRecord record(AnswerVerdict model, AnswerVerdict rule) =>
        JudgementABRecord(
          id: 'ab_${model.name}_${rule.name}_${DateTime.now().microsecondsSinceEpoch}',
          studentId: 'stu_001',
          mistakeId: 'rm_1',
          channel: AttemptChannel.paper,
          subject: '数学',
          knowledgePoint: '分数比较',
          modelVerdict: model,
          ruleVerdict: rule,
          createdAt: DateTime.now(),
        );

    test('分母是可比样本，弃权不参与', () {
      final summary = JudgementABSummary.of([
        record(AnswerVerdict.correct, AnswerVerdict.correct),
        record(AnswerVerdict.wrong, AnswerVerdict.wrong),
        record(AnswerVerdict.correct, AnswerVerdict.wrong),
        // 6 条规则弃权：规则越谨慎，越不该拉低一致率
        ...List.generate(
          6,
          (_) => record(AnswerVerdict.correct, AnswerVerdict.inconclusive),
        ),
      ]);

      expect(summary.total, 9);
      expect(summary.compared, 3);
      expect(summary.abstained, 6);
      expect(summary.ruleAbstained, 6);
      expect(summary.consistencyRate, closeTo(2 / 3, 1e-9));
      expect(
        summary.total,
        summary.compared + summary.abstained,
        reason: '总账必须对得上，否则分母口径改了也没人发现',
      );
    });

    test('没有可比样本时一致率是 null，不是 0 也不是 100%', () {
      final allAbstained = JudgementABSummary.of([
        record(AnswerVerdict.correct, AnswerVerdict.inconclusive),
        record(AnswerVerdict.wrong, AnswerVerdict.inconclusive),
      ]);
      expect(allAbstained.compared, 0);
      expect(
        allAbstained.consistencyRate,
        isNull,
        reason: '没有样本时说「一致率 100%」会让人以为规则可以替代模型，'
            '说 0% 会让人以为模型全错 —— 两个都是编的',
      );

      expect(JudgementABSummary.empty.consistencyRate, isNull);
      expect(JudgementABSummary.empty.ruleAbstainRate, isNull);
    });

    test('模型弃权单独计数，且与规则弃权可能重叠', () {
      final summary = JudgementABSummary.of([
        record(AnswerVerdict.inconclusive, AnswerVerdict.inconclusive),
        record(AnswerVerdict.inconclusive, AnswerVerdict.correct),
      ]);
      expect(summary.total, 2);
      expect(summary.compared, 0);
      expect(summary.modelAbstained, 2);
      expect(summary.ruleAbstained, 1);
      expect(
        summary.abstained,
        2,
        reason: 'abstained 是并集；两个分项相加大于总数是正常的，'
            '断言总账要用 abstained',
      );
    });
  });

  // ===== 影子跑不跑 =====

  group('影子触发条件', () {
    test('结论不是模型给的时候不记 —— 否则比的是「规则 vs 规则」', () async {
      const shadow = JudgementShadow();

      final offline = await shadow.compare(
        judgement: const AnswerJudgement(
          verdict: AnswerVerdict.correct,
          score: 100,
          comment: '本地兜底',
        ),
        studentAnswer: '5/8',
        referenceAnswer: '5/8',
      );

      expect(
        offline,
        isNull,
        reason: '离线时两侧是同一个实现，一致率会恒等于 100%，'
            '一个看起来完美、实际毫无信息量的数字',
      );
    });

    test('模型结论会跑一次规则并留档', () async {
      const shadow = JudgementShadow();

      final compared = await shadow.compare(
        judgement: const AnswerJudgement(
          verdict: AnswerVerdict.correct,
          score: 100,
          comment: '模型给的',
          source: AiAnswerSource.cloud,
        ),
        // 规则侧会判对（与参考答案一致）
        studentAnswer: '5/8（0.625 = 625/1000）',
        referenceAnswer: '5/8（0.625 = 625/1000）',
      );

      expect(compared, isNotNull);
      expect(compared!.modelVerdict, AnswerVerdict.correct);
      expect(compared.ruleVerdict, AnswerVerdict.correct);
      expect(compared.agreement, JudgementAgreement.agree);
    });
  });

  // ===== 落库 =====

  group('落库', () {
    Directory? tempDir;

    setUp(() async {
      tempDir = await setUpTestDatabase();
      final auth = Get.put(AuthController());
      auth.currentUser.value = UserModel(
        id: 'stu_001',
        name: '林小宇',
        phone: '13800000001',
        role: 'student',
        avatar: '👦',
      );
    });

    tearDown(() async {
      Get.reset();
      final dir = tempDir;
      if (dir != null) await tearDownTestDatabase(dir);
    });

    test('存取往返后两侧结论不变', () async {
      final record = JudgementABRecord(
        id: 'ab_roundtrip',
        studentId: 'stu_001',
        mistakeId: 'rm_1',
        channel: AttemptChannel.practice,
        subject: '数学',
        knowledgePoint: '分数比较',
        modelVerdict: AnswerVerdict.correct,
        ruleVerdict: AnswerVerdict.inconclusive,
        createdAt: DateTime.parse('2026-09-15T10:00:00.000'),
      );
      await DatabaseService.instance.insertJudgementABRecords([record]);

      final rows = await DatabaseService.instance.queryJudgementAB(
        studentId: 'stu_001',
      );
      final restored = rows.single;
      expect(restored.id, 'ab_roundtrip');
      expect(restored.channel, AttemptChannel.practice);
      expect(restored.modelVerdict, AnswerVerdict.correct);
      expect(restored.ruleVerdict, AnswerVerdict.inconclusive);
      expect(restored.agreement, JudgementAgreement.abstained);
    });

    test('读不懂的行被丢弃，而不是被当成弃权混进分母', () async {
      // 直接塞一行坏数据：结论字段是空的（模拟字段改名 / 写入被截断）。
      final judge = JudgementABRecord.parseVerdict('');
      expect(judge, isNull);

      final restored = JudgementABRecord.fromMap({
        'id': 'ab_bad',
        'studentId': 'stu_001',
        'mistakeId': 'rm_1',
        'channel': 'paper',
        'modelVerdict': '',
        'ruleVerdict': 'correct',
        'createdAt': '2026-09-15T10:00:00.000',
      });
      expect(
        restored,
        isNull,
        reason: '把读不懂的结论默认成 inconclusive 会让数据损坏伪装成一条统计口径，'
            '而口径是一致率的分母 —— 脏在这里就再也查不出来了',
      );
    });

    test('按学生过滤：A 的样本不会算进 B 的一致率', () async {
      await DatabaseService.instance.insertJudgementABRecords([
        JudgementABRecord(
          id: 'ab_a',
          studentId: 'stu_001',
          mistakeId: 'rm_1',
          channel: AttemptChannel.paper,
          subject: '数学',
          knowledgePoint: '分数比较',
          modelVerdict: AnswerVerdict.correct,
          ruleVerdict: AnswerVerdict.wrong,
          createdAt: DateTime.now(),
        ),
        JudgementABRecord(
          id: 'ab_b',
          studentId: 'stu_002',
          mistakeId: 'rm_2',
          channel: AttemptChannel.paper,
          subject: '数学',
          knowledgePoint: '分数比较',
          modelVerdict: AnswerVerdict.correct,
          ruleVerdict: AnswerVerdict.correct,
          createdAt: DateTime.now(),
        ),
      ]);

      final forA = await DatabaseService.instance.queryJudgementAB(
        studentId: 'stu_001',
      );
      expect(forA.map((r) => r.id), ['ab_a']);
      expect(JudgementABSummary.of(forA).consistencyRate, 0);
    });
  });

  // ===== 不改判定 =====

  group('比对不劫持业务', () {
    Directory? tempDir;

    setUp(() async {
      tempDir = await setUpTestDatabase();
      final auth = Get.put(AuthController());
      auth.currentUser.value = UserModel(
        id: 'stu_001',
        name: '林小宇',
        phone: '13800000001',
        role: 'student',
        avatar: '👦',
      );
    });

    tearDown(() async {
      Get.reset();
      final dir = tempDir;
      if (dir != null) await tearDownTestDatabase(dir);
    });

    test('模型判「对」而规则判「错」时，学生仍然通过', () async {
      // 这是整个影子机制最关键的断言：观测出 bug 的代价必须是
      // 「统计不准」，而不是「学生被改判」。
      final student = StudentController(
        aiCheckDelay: Duration.zero,
        imageStorage: LocalImageStorageService(useMemory: true),
      );
      await student.loadData();

      final mistake = ReviewMistake(
        id: 'rm_ab_1',
        subject: '数学',
        title: '分数比较题',
        originalAnswer: '3/4 > 2/3',
        wrongReason: '分母处理错误',
        knowledgePoint: '分数比较',
        wrongCount: 1,
        lastWrongAt: DateTime.now(),
        studentId: 'stu_001',
        createdAt: DateTime.now(),
        state: ReviewState.pending,
      );
      await DatabaseService.instance.insertReviewMistake(mistake);
      student.mistakes.add(mistake);

      final ai = _FakeCloudAi(verdict: AnswerVerdict.correct);
      final controller = ReviewController(
        student: student,
        ai: ai,
        exporter: FakeExporter(),
      );

      final compose = await controller.composeAndPrintPaper(
        mistakeIds: ['rm_ab_1'],
      );
      expect(compose.ok, isTrue, reason: compose.message);
      final paperId = controller.activePaper.value!.id;
      final item = (await controller.openPaper(paperId)).first;

      // 学生写的答案与参考答案不一致 —— 本地规则一定判错。
      const studentAnswer = '我算出来是 3/4 比较大';
      expect(
        (await const SimulatedAiDataSource().judgeAnswer(
          studentAnswer: studentAnswer,
          referenceAnswer: item.answerKey,
        )).verdict,
        isNot(AnswerVerdict.correct),
        reason: '前提：规则侧确实与模型结论相反，否则这条断言等于没测',
      );

      final graded = await controller.submitPaper(
        paperId: paperId,
        results: {item.id: PaperItemResult.correct},
        answers: {item.id: studentAnswer},
      );

      expect(graded.op.ok, isTrue, reason: graded.op.message);
      expect(graded.passCount, 1, reason: '判定必须听模型的');
      expect(graded.failCount, 0);

      // 同时，比对已经留档，且如实记下两侧不一致。
      final ab = await DatabaseService.instance.queryJudgementAB(
        studentId: 'stu_001',
      );
      expect(ab.length, 1);
      expect(ab.single.channel, AttemptChannel.paper);
      expect(ab.single.mistakeId, 'rm_ab_1');
      expect(ab.single.modelVerdict, AnswerVerdict.correct);
      expect(ab.single.ruleVerdict, isNot(AnswerVerdict.correct));
      expect(ab.single.agreement, JudgementAgreement.disagree);
    });

    test('纯本地运行时不留比对记录（没有模型侧可比）', () async {
      final student = StudentController(
        aiCheckDelay: Duration.zero,
        imageStorage: LocalImageStorageService(useMemory: true),
      );
      await student.loadData();

      final mistake = ReviewMistake(
        id: 'rm_ab_2',
        subject: '数学',
        title: '分数比较题',
        originalAnswer: '3/4 > 2/3',
        wrongReason: '分母处理错误',
        knowledgePoint: '分数比较',
        wrongCount: 1,
        lastWrongAt: DateTime.now(),
        studentId: 'stu_001',
        createdAt: DateTime.now(),
        state: ReviewState.pending,
      );
      await DatabaseService.instance.insertReviewMistake(mistake);
      student.mistakes.add(mistake);

      // 不注入模型：走本地兜底，与接入云端之前的行为一致。
      final controller = ReviewController(
        student: student,
        exporter: FakeExporter(),
      );
      final compose = await controller.composeAndPrintPaper(
        mistakeIds: ['rm_ab_2'],
      );
      expect(compose.ok, isTrue, reason: compose.message);
      final paperId = controller.activePaper.value!.id;
      final item = (await controller.openPaper(paperId)).first;

      await controller.submitPaper(
        paperId: paperId,
        results: {item.id: PaperItemResult.correct},
        answers: {item.id: item.answerKey},
      );

      final ab = await DatabaseService.instance.queryJudgementAB(
        studentId: 'stu_001',
      );
      expect(
        ab,
        isEmpty,
        reason: '离线时两侧是同一个实现，记下来只会得到 100% 的假一致率',
      );
    });
  });
}
