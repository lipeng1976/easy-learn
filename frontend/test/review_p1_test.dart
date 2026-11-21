import 'dart:io';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/review_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/services/review_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';
import 'helpers/fake_exporter.dart';

/// P1 能力：**周报月报聚合、错题手工录入、作答渠道可视化**。
///
/// 这三件事的共同点是：它们都在回答「这个闭环到底有没有真的在推进」。
/// 所以断言重点不是界面，而是三个容易被做假的量：
/// 1. 周期窗口的边界（周日晚上做的题算哪一周）；
/// 2. 通过率的分母（反复错的题做 3 轮，是记 3 次还是 1 道）；
/// 3. 渠道（自评「做对了」不能和 AI 判定混成同一个数字）。

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  Directory? tempDir;
  late AuthController auth;

  setUp(() async {
    tempDir = await setUpTestDatabase();
    auth = Get.put(AuthController());
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

  Future<ReviewController> buildController() async {
    final student = StudentController(
      aiCheckDelay: Duration.zero,
      imageStorage: LocalImageStorageService(useMemory: true),
    );
    await student.loadData();
    final controller = ReviewController(student: student, exporter: FakeExporter());
    await controller.loadReviewData();
    return controller;
  }

  Future<ReviewMistake> seedMistake({
    required String id,
    String subject = '数学',
    String knowledgePoint = '分数比较',
    String title = '分数比较题',
    int wrongCount = 1,
    ReviewState state = ReviewState.pending,
    bool masteredBySelf = false,
    DateTime? masteredAt,
  }) async {
    final mistake = ReviewMistake(
      id: id,
      subject: subject,
      title: title,
      originalAnswer: '3/4 > 2/3',
      wrongReason: '分母处理错误',
      knowledgePoint: knowledgePoint,
      wrongCount: wrongCount,
      lastWrongAt: DateTime.now(),
      studentId: 'stu_001',
      createdAt: DateTime.now(),
      state: state,
      masteredAt: masteredAt,
      masteredBySelf: masteredBySelf,
    );
    await DatabaseService.instance.insertReviewMistake(mistake);
    return mistake;
  }

  ReviewAttempt attempt({
    required String id,
    required String mistakeId,
    required bool correct,
    required DateTime at,
    AttemptChannel channel = AttemptChannel.paper,
    int round = 1,
  }) => ReviewAttempt(
    id: id,
    studentId: 'stu_001',
    mistakeId: mistakeId,
    channel: channel,
    round: round,
    correct: correct,
    score: correct ? 100 : 0,
    createdAt: at,
  );

  ReviewMistake mistake({
    required String id,
    ReviewState state = ReviewState.pending,
    int wrongCount = 1,
    String knowledgePoint = '分数比较',
    String subject = '数学',
    bool masteredBySelf = false,
    DateTime? masteredAt,
  }) => ReviewMistake(
    id: id,
    subject: subject,
    title: '$knowledgePoint 题',
    originalAnswer: '',
    wrongReason: '',
    knowledgePoint: knowledgePoint,
    wrongCount: wrongCount,
    studentId: 'stu_001',
    createdAt: DateTime(2026, 9, 1),
    state: state,
    masteredBySelf: masteredBySelf,
    masteredAt: masteredAt,
  );

  group('周期窗口', () {
    test('周窗口从周一 00:00 起，月窗口从 1 号 00:00 起', () {
      final wednesday = DateTime(2026, 9, 16, 15, 30);
      expect(
        ReviewService.periodStart(SummaryScope.week, wednesday),
        DateTime(2026, 9, 14),
      );
      expect(
        ReviewService.periodStart(SummaryScope.month, wednesday),
        DateTime(2026, 9, 1),
      );
    });

    test('周窗口在周日仍指向本周一，不会漏掉周日晚上做的题', () {
      // 周日 22:00 —— 这是一周里最容易做题的时间，滚动 7 天窗口会把它算错。
      final sunday = DateTime(2026, 9, 20, 22, 0);
      expect(
        ReviewService.periodStart(SummaryScope.week, sunday),
        DateTime(2026, 9, 14),
      );
    });

    test('周期键用 ISO 周号，跨年周归入含首个周四的那一年', () {
      expect(
        ReviewService.periodKey(SummaryScope.week, DateTime(2026, 9, 16)),
        '2026-W38',
      );
      // 2025-12-31 是周三，属于 2026 年的第 1 周。
      expect(
        ReviewService.periodKey(SummaryScope.week, DateTime(2025, 12, 31)),
        '2026-W1',
      );
      expect(
        ReviewService.periodKey(SummaryScope.month, DateTime(2026, 9, 16)),
        '2026-09',
      );
    });

    test('窗口外的作答不进统计', () {
      final now = DateTime(2026, 9, 16, 12);
      final report = ReviewService.buildPeriodReport(
        scope: SummaryScope.week,
        now: now,
        pool: [mistake(id: 'm1')],
        papers: const [],
        attempts: [
          // 上周日 23:00：差一小时就跨进了本周，必须排除。
          attempt(
            id: 'a_out',
            mistakeId: 'm1',
            correct: true,
            at: DateTime(2026, 9, 13, 23),
          ),
          attempt(
            id: 'a_in',
            mistakeId: 'm1',
            correct: false,
            at: DateTime(2026, 9, 14, 0, 30),
          ),
        ],
        explanations: const [],
      );

      expect(report.attemptCount, 1);
      expect(report.passCount, 0);
      expect(report.failCount, 1);
    });
  });

  group('周期报告口径', () {
    test('通过率按作答次数算，反复错的题做几轮就记几次', () {
      final now = DateTime(2026, 9, 16, 12);
      final report = ReviewService.buildPeriodReport(
        scope: SummaryScope.week,
        now: now,
        pool: [mistake(id: 'm1', wrongCount: 3)],
        papers: const [],
        attempts: [
          attempt(
            id: 'a1',
            mistakeId: 'm1',
            correct: true,
            at: DateTime(2026, 9, 14, 9),
          ),
          attempt(
            id: 'a2',
            mistakeId: 'm1',
            correct: true,
            at: DateTime(2026, 9, 15, 9),
            round: 2,
          ),
          attempt(
            id: 'a3',
            mistakeId: 'm1',
            correct: false,
            at: DateTime(2026, 9, 16, 9),
            round: 3,
          ),
        ],
        explanations: const [],
      );

      expect(report.attemptCount, 3);
      expect(report.passCount, 2);
      expect(report.failCount, 1);
      expect((report.passRate * 100).round(), 67);
      expect(
        report.bestStreak,
        2,
        reason: '第 3 轮断了，最长连续通过是 2',
      );
    });

    test('自评掌握单独计数，既不进毕业数也不进通过率', () {
      final now = DateTime(2026, 9, 16, 12);
      final report = ReviewService.buildPeriodReport(
        scope: SummaryScope.week,
        now: now,
        pool: [
          mistake(
            id: 'm_self',
            state: ReviewState.mastered,
            masteredBySelf: true,
            masteredAt: DateTime(2026, 9, 15),
          ),
          mistake(
            id: 'm_verified',
            state: ReviewState.mastered,
            masteredAt: DateTime(2026, 9, 15),
          ),
          mistake(id: 'm_pool'),
        ],
        papers: const [],
        attempts: [
          attempt(
            id: 'a1',
            mistakeId: 'm_verified',
            correct: true,
            at: DateTime(2026, 9, 15),
          ),
        ],
        explanations: const [],
      );

      expect(report.graduatedCount, 1);
      expect(report.selfMasteredCount, 1);
      expect(report.poolRemain, 1);
      // 自评那 1 道没有作答记录，所以通过率的分子只有作答里的那 1 次。
      expect(report.attemptCount, 1);
      expect(report.selfMasteredRatio, 0.5);
      expect(report.body, contains('自评掌握'));
    });

    test('薄弱知识点按错题的知识点归集并降序', () {
      final now = DateTime(2026, 9, 16, 12);
      final report = ReviewService.buildPeriodReport(
        scope: SummaryScope.week,
        now: now,
        pool: [
          mistake(id: 'm1', knowledgePoint: '分数比较'),
          mistake(id: 'm2', knowledgePoint: '分数计算'),
        ],
        papers: const [],
        attempts: [
          attempt(
            id: 'a1',
            mistakeId: 'm1',
            correct: false,
            at: DateTime(2026, 9, 14),
          ),
          attempt(
            id: 'a2',
            mistakeId: 'm1',
            correct: false,
            at: DateTime(2026, 9, 15),
          ),
          attempt(
            id: 'a3',
            mistakeId: 'm2',
            correct: false,
            at: DateTime(2026, 9, 15),
          ),
        ],
        explanations: const [],
      );

      expect(report.weakPoints.first.name, '分数比较');
      expect(report.weakPoints.first.wrongCount, 2);
      expect(
        report.suggestions.any((s) => s.contains('分数比较')),
        isTrue,
        reason: '建议要指名道姓，不能只说「加强薄弱环节」',
      );
    });

    test('没有作答时给出可执行的第一步，而不是空报告', () {
      final report = ReviewService.buildPeriodReport(
        scope: SummaryScope.week,
        now: DateTime(2026, 9, 16, 12),
        pool: [mistake(id: 'm1'), mistake(id: 'm2')],
        papers: const [],
        attempts: const [],
        explanations: const [],
      );

      expect(report.attemptCount, 0);
      expect(report.passRate, 0);
      expect(report.highlights, isEmpty);
      expect(report.suggestions.first, contains('2 道'));
      expect(report.body, contains('还没有复习记录'));
    });

    test('分科统计按科目分开累计', () {
      final report = ReviewService.buildPeriodReport(
        scope: SummaryScope.week,
        now: DateTime(2026, 9, 16, 12),
        pool: [
          mistake(id: 'm_math', subject: '数学'),
          mistake(id: 'm_cn', subject: '语文'),
        ],
        papers: const [],
        attempts: [
          attempt(
            id: 'a1',
            mistakeId: 'm_math',
            correct: true,
            at: DateTime(2026, 9, 14),
          ),
          attempt(
            id: 'a2',
            mistakeId: 'm_cn',
            correct: false,
            at: DateTime(2026, 9, 14),
          ),
        ],
        explanations: const [],
      );

      expect(report.subjectAttempts['数学'], 1);
      expect(report.subjectPasses['数学'], 1);
      expect(report.subjectAttempts['语文'], 1);
      expect(report.subjectPasses.containsKey('语文'), isFalse);
    });
  });

  group('渠道判定', () {
    test('录了答案算 AI 判定，没录答案算自评', () {
      expect(ReviewService.channelForAnswer(' 11/12 '), AttemptChannel.paper);
      expect(ReviewService.channelForAnswer(''), AttemptChannel.paperSelf);
      expect(ReviewService.channelForAnswer('   '), AttemptChannel.paperSelf);
    });

    test('回传时不录答案的题记为自评，并且不构成可核对的证据', () async {
      await seedMistake(id: 'rm_self_channel');
      final controller = await buildController();

      final compose = await controller.composeAndPrintPaper(
        mistakeIds: ['rm_self_channel'],
      );
      expect(compose.ok, isTrue, reason: compose.message);
      final paperId = controller.activePaper.value!.id;
      final items = await controller.openPaper(paperId);

      // 只勾「做对了」，一个答案都不录。
      final graded = await controller.submitPaper(
        paperId: paperId,
        results: {items.first.id: PaperItemResult.correct},
      );
      expect(graded.op.ok, isTrue, reason: graded.op.message);
      expect(graded.graduatedCount, 1, reason: '自评也允许毕业，但会留下渠道标记');

      final recorded = controller.attemptsOf('rm_self_channel');
      expect(recorded.length, 1);
      expect(recorded.first.channel, AttemptChannel.paperSelf);

      // 时间线要能看出这是自评，而不是「AI 判定通过」。
      final timeline = await controller.timelineOf('rm_self_channel');
      final passed = timeline.firstWhere(
        (entry) => entry.kind == TimelineKind.practiced,
      );
      expect(passed.channel, AttemptChannel.paperSelf);
    });

    test('录了答案的题走 AI 判定渠道', () async {
      await seedMistake(id: 'rm_ai_channel');
      final controller = await buildController();

      final compose = await controller.composeAndPrintPaper(
        mistakeIds: ['rm_ai_channel'],
      );
      expect(compose.ok, isTrue, reason: compose.message);
      final paperId = controller.activePaper.value!.id;
      final items = await controller.openPaper(paperId);

      final graded = await controller.submitPaper(
        paperId: paperId,
        results: {items.first.id: PaperItemResult.correct},
        answers: {items.first.id: items.first.answerKey},
      );
      expect(graded.op.ok, isTrue, reason: graded.op.message);

      final recorded = controller.attemptsOf('rm_ai_channel');
      expect(recorded.single.channel, AttemptChannel.paper);
    });
  });

  group('错题手工录入', () {
    test('录入后进池、落库，并带上「手工录入」来源', () async {
      final controller = await buildController();

      final result = await controller.addMistakeManually(
        subject: '数学',
        title: '一道历史错题',
        knowledgePoint: '分数计算',
        originalAnswer: '2/5',
        wrongReason: '看错分母',
      );
      expect(result.ok, isTrue, reason: result.message);

      final created = controller.mistakes.firstWhere(
        (m) => m.title == '一道历史错题',
      );
      expect(created.state, ReviewState.pending);
      expect(created.wrongCount, 1);
      expect(created.lastWrongAt, isNotNull);
      expect(created.homeworkId, isEmpty);
      expect(created.sourceHomeworkTitle, '手工录入');
      expect(controller.poolMistakes.any((m) => m.id == created.id), isTrue);

      final rows = await DatabaseService.instance.queryReviewMistakes();
      expect(rows.any((m) => m.id == created.id), isTrue, reason: '必须真的落库');
    });

    test('题目内容为空时拒绝录入', () async {
      final controller = await buildController();
      final result = await controller.addMistakeManually(
        subject: '数学',
        title: '   ',
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('题目内容'));
    });

    test('编辑能改知识点，且改动能落库', () async {
      final controller = await buildController();
      await controller.addMistakeManually(
        subject: '数学',
        title: '知识点填错的题',
        knowledgePoint: '随手写的',
      );
      final created = controller.mistakes.firstWhere(
        (m) => m.title == '知识点填错的题',
      );

      final result = await controller.updateMistake(
        mistakeId: created.id,
        subject: '数学',
        title: '知识点填错的题',
        knowledgePoint: '同分母分数加减',
        originalAnswer: '2/5',
        wrongReason: '看错分母',
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(
        controller.mistakeById(created.id)!.knowledgePoint,
        '同分母分数加减',
      );

      final rows = await DatabaseService.instance.queryReviewMistakes();
      final stored = rows.firstWhere((m) => m.id == created.id);
      expect(stored.knowledgePoint, '同分母分数加减');
      expect(stored.originalAnswer, '2/5');
    });

    test('在卷的题不允许删除，避免卷内快照指向不存在的题', () async {
      await seedMistake(id: 'rm_in_paper');
      final controller = await buildController();

      final compose = await controller.composeAndPrintPaper(
        mistakeIds: ['rm_in_paper'],
      );
      expect(compose.ok, isTrue, reason: compose.message);
      expect(controller.mistakeById('rm_in_paper')!.state, ReviewState.reviewing);

      final result = await controller.removeMistake('rm_in_paper');
      expect(result.ok, isFalse);
      expect(result.message, contains('复习中'));
      expect(controller.mistakeById('rm_in_paper'), isNotNull);
    });

    test('删除错题会连带清掉它的作答证据', () async {
      await seedMistake(id: 'rm_to_delete');
      final controller = await buildController();

      final evidence = attempt(
        id: 'at_to_delete',
        mistakeId: 'rm_to_delete',
        correct: false,
        at: DateTime.now(),
        channel: AttemptChannel.practice,
      );
      await DatabaseService.instance.insertReviewAttempt(evidence);
      controller.attempts.add(evidence);

      final result = await controller.removeMistake('rm_to_delete');
      expect(result.ok, isTrue, reason: result.message);
      expect(controller.mistakeById('rm_to_delete'), isNull);

      final orphans = await DatabaseService.instance.queryReviewAttempts(
        mistakeId: 'rm_to_delete',
      );
      expect(
        orphans,
        isEmpty,
        reason: '孤儿证据会让「按错题聚合的通过率」多出查不到题目的分母',
      );
    });
  });

  group('报告归档', () {
    test('同一周期反复保存只留一份，不产生副本', () async {
      final controller = await buildController();

      final first = await controller.saveReport(SummaryScope.week);
      final second = await controller.saveReport(SummaryScope.week);
      expect(first.scopeKey, second.scopeKey);

      final inMemory = controller.summaries
          .where((s) => s.scope == SummaryScope.week)
          .toList();
      expect(inMemory.length, 1);

      final stored = await DatabaseService.instance.queryReviewSummaries();
      final weekly = stored
          .where(
            (s) =>
                s.scope == SummaryScope.week && s.scopeKey == first.scopeKey,
          )
          .toList();
      expect(weekly.length, 1);
    });

    test('导出的纯文本包含分科情况与下一步建议', () async {
      await seedMistake(id: 'rm_text', knowledgePoint: '分数比较');
      final controller = await buildController();

      final compose = await controller.composeAndPrintPaper(
        mistakeIds: ['rm_text'],
      );
      expect(compose.ok, isTrue, reason: compose.message);
      final paperId = controller.activePaper.value!.id;
      final items = await controller.openPaper(paperId);
      await controller.submitPaper(
        paperId: paperId,
        results: {items.first.id: PaperItemResult.wrong},
      );

      final report = controller.buildReport(SummaryScope.week);
      final text = controller.reportPlainText(report);
      expect(text, contains('分科情况'));
      expect(text, contains('分数比较'));
    });
  });

  group('卷名', () {
    test('卷名带日期、不带「第几轮」', () async {
      await seedMistake(id: 'rm_title');
      final controller = await buildController();

      final compose = await controller.composeAndPrintPaper(
        mistakeIds: ['rm_title'],
      );
      expect(compose.ok, isTrue, reason: compose.message);

      final title = controller.activePaper.value!.title;
      final now = DateTime.now();
      expect(title, contains('${now.month}月${now.day}日'),
          reason: '卷名没有生成日期 —— 学生分不清是哪天的卷子');
      expect(title, isNot(contains('轮')),
          reason: '「第几轮」对学生是黑话，已经改成日期了');
    });

    test('同一天生成第二份同科目卷子时自动加「（二）」，不撞名', () async {
      await seedMistake(id: 'rm_dup_1', title: '第一道');
      await seedMistake(id: 'rm_dup_2', title: '第二道');
      final controller = await buildController();

      final first = await controller.composeAndPrintPaper(
        mistakeIds: ['rm_dup_1'],
      );
      expect(first.ok, isTrue, reason: first.message);
      final firstTitle = controller.activePaper.value!.title;

      final second = await controller.composeAndPrintPaper(
        mistakeIds: ['rm_dup_2'],
      );
      expect(second.ok, isTrue, reason: second.message);
      final secondTitle = controller.activePaper.value!.title;

      expect(secondTitle, isNot(equals(firstTitle)),
          reason: '两份卷子同名，学生在列表里选不出要做哪一份');
      expect(secondTitle, equals('$firstTitle（二）'));
    });
  });
}
