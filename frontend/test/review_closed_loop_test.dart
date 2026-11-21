import 'dart:convert';
import 'dart:io';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/review_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/services/database_service.dart';
// 这里要直连**本地库**跑原生 SQL（造数据 / 断言存储层），
// 而上云门面 `DatabaseService` 不承诺「`.database` 就是当前数据源」——
// 云端模式下它是服务端。所以显式指名本地实现。
import 'package:easy_learn_app/services/local_database_service.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/services/review_exporter.dart';
import 'package:easy_learn_app/services/review_paper_html.dart';
import 'package:easy_learn_app/services/review_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/db_test_helper.dart';
import 'helpers/fake_exporter.dart';

/// 复习闭环：**组卷 → 打印 → 回传 → 批改分流 → 讲解 / 举一反三 → 报告**。
///
/// 这一整套断言存在的理由：闭环最容易出错的地方不是界面，而是**判定规则**
/// ——「做对了到底算不算毕业」。所以这里重点压三件事：
/// 1. 状态机走完一圈后，卷子、错题、证据三者必须互相对得上；
/// 2. 反复错的题必须连续两轮通过，不能蒙对一次就毕业；
/// 3. 没有证据的「自评掌握」不能污染掌握率。

/// 1×1 的 JPEG。判据只需要「这是一张能被解码的图」，不需要它好看。
const String _tinyJpegBase64 =
    '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRof'
    'Hh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAAB'
    'AAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==';

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

  Future<StudentController> buildStudent() async {
    final student = StudentController(
      aiCheckDelay: Duration.zero,
      imageStorage: LocalImageStorageService(useMemory: true),
    );
    await student.loadData();
    return student;
  }

  Future<void> seedMistake({
    required String id,
    String subject = '数学',
    String knowledgePoint = '分数比较',
    String title = '分数比较题',
    // 真实链路里 AI 批改一定带题干（`questionBody: item.question`），
    // 所以造数据也带上 —— 不带的话组卷会走「没有原题」的兜底分支，
    // 那条分支不是学生日常会遇到的形态。
    String questionBody = '比较 3/4 和 2/3 的大小，写出比较过程。',
    int wrongCount = 1,
    ReviewState state = ReviewState.pending,
    bool masteredBySelf = false,
  }) async {
    await DatabaseService.instance.insertReviewMistake(
      ReviewMistake(
        id: id,
        subject: subject,
        title: title,
        questionBody: questionBody,
        originalAnswer: '3/4 > 2/3',
        wrongReason: '分母处理错误',
        knowledgePoint: knowledgePoint,
        wrongCount: wrongCount,
        lastWrongAt: DateTime.now(),
        studentId: 'stu_001',
        createdAt: DateTime.now(),
        state: state,
        masteredAt: state == ReviewState.mastered ? DateTime.now() : null,
        masteredBySelf: masteredBySelf,
      ),
    );
  }

  /// 组一份只含指定错题的卷子，并返回卷内快照。
  ///
  /// [exportAfterCompose] 默认 false，与产品行为一致：组卷只把卷子生成出来，
  /// 「怎么取走」（打印 / 下载 / 转发）由学生选。要覆盖「组卷即导出」
  /// 这条自动化路径时才传 true。
  Future<({String paperId, ReviewPaperItem item})> composeFor(
    ReviewController controller,
    StudentController student,
    String mistakeId, {
    bool exportAfterCompose = false,
  }) async {
    final compose = await controller.composeAndPrintPaper(
      mistakeIds: [mistakeId],
      exportAfterCompose: exportAfterCompose,
    );
    expect(compose.ok, isTrue, reason: compose.message);
    final paperId = controller.activePaper.value!.id;
    final items = await controller.openPaper(paperId);
    expect(items.length, 1);
    return (paperId: paperId, item: items.first);
  }

  group('复习闭环主链路', () {
    test('组卷 → 打印 → 回传 → 批改通过：错题毕业并留下证据与报告', () async {
      final student = await buildStudent();
      await seedMistake(id: 'rm_loop_1');
      await student.loadData();

      final exporter = FakeExporter();
      final controller = ReviewController(student: student, exporter: exporter);
      await controller.loadReviewData();

      // 1. 组卷 + 导出（显式要求导出，走「打印」这条默认去向）
      final composed = await composeFor(
        controller,
        student,
        'rm_loop_1',
        exportAfterCompose: true,
      );
      expect(exporter.printCalls, 1, reason: '显式要求导出时应走打印');
      expect(exporter.lastName, contains(composed.paperId));
      expect(
        exporter.lastHtml,
        contains('分数比较'),
        reason: '卷面要能看到知识点',
      );
      // ⭐ 卷面必须印**原题**：2026-10-21 之前这里只有一句
      // 「重新独立完成这道题」，学生拿着卷子不知道自己要做哪道题。
      expect(
        exporter.lastHtml,
        contains('比较 3/4 和 2/3 的大小'),
        reason: '卷面没有原题正文',
      );
      expect(
        exporter.lastHtml,
        isNot(contains('重新独立完成这道题')),
        reason: '还在印那句没有题目的占位提示',
      );

      final paper = controller.paperById(composed.paperId)!;
      expect(paper.itemCount, 1);
      expect(paper.status, PaperStatus.printed, reason: '导出成功后应进入待作答');
      expect(paper.exportedAt, isNotNull);
      // 入卷的题离开待复习池，避免被下一份卷子重复收录。
      expect(controller.mistakeById('rm_loop_1')!.state, ReviewState.reviewing);
      expect(
        controller.poolMistakes.any((m) => m.id == 'rm_loop_1'),
        isFalse,
      );

      // 2. 回传
      final submitted = await controller.markPaperSubmitted(composed.paperId);
      expect(submitted.ok, isTrue, reason: submitted.message);
      expect(
        controller.paperById(composed.paperId)!.status,
        PaperStatus.submitted,
      );
      expect(controller.mistakeById('rm_loop_1')!.state, ReviewState.verifying);

      // 3. 批改：录入与参考答案一致的答案 → 走 AI 判定
      final graded = await controller.submitPaper(
        paperId: composed.paperId,
        results: {composed.item.id: PaperItemResult.correct},
        answers: {composed.item.id: composed.item.answerKey},
      );
      expect(graded.op.ok, isTrue, reason: graded.op.message);
      expect(graded.passCount, 1);
      expect(graded.failCount, 0);
      expect(graded.graduatedCount, 1);

      final gradedPaper = controller.paperById(composed.paperId)!;
      expect(gradedPaper.status, PaperStatus.graded);
      expect(gradedPaper.gradedAt, isNotNull);
      expect(gradedPaper.passRate, 1.0);

      // 4. 毕业：移出错题库，且不是自评
      final mistake = controller.mistakeById('rm_loop_1')!;
      expect(mistake.state, ReviewState.mastered);
      expect(mistake.masteredBySelf, isFalse);
      expect(mistake.masteredAt, isNotNull);
      expect(controller.poolMistakes.any((m) => m.id == 'rm_loop_1'), isFalse);
      expect(controller.masteredMistakes.any((m) => m.id == 'rm_loop_1'), isTrue);

      // 5. 证据：渠道是「纸质卷 · AI 判定」，挂在这次卷子上
      final attempts = controller.attemptsOf('rm_loop_1');
      expect(attempts.length, 1);
      expect(attempts.first.channel, AttemptChannel.paper);
      expect(attempts.first.paperId, composed.paperId);
      expect(attempts.first.correct, isTrue);

      // 6. 报告：数字自洽（题量 = 通过 + 未通过）
      final summary = controller.summaryOfPaper(composed.paperId);
      expect(summary, isNotNull);
      expect(summary!.totalCount, 1);
      expect(summary.passCount, 1);
      expect(summary.remainCount, 0);
      expect(
        summary.totalCount,
        summary.passCount + summary.remainCount,
        reason: '报告数字必须自洽，否则家长看到的通过率不可信',
      );

      // 7. 时间线：从入池到毕业的「过程」留痕
      final timeline = await controller.timelineOf('rm_loop_1');
      expect(timeline.first.kind, TimelineKind.created);
      expect(timeline.last.kind, TimelineKind.mastered);
      expect(timeline.any((e) => e.kind == TimelineKind.practiced), isTrue);

      // 8. 掌握率把「通过检查」算进分子。
      // 只对这道题取样：演示数据里还有别的错题，拿整池算出来的比例说明不了本用例。
      expect(
        ReviewService.masteryRate(
          controller.mistakes.where((m) => m.id == 'rm_loop_1').toList(),
        ),
        1.0,
      );
    });

    test('做错 → 错误次数 +1 并回炉，卷子记未通过', () async {
      final student = await buildStudent();
      await seedMistake(id: 'rm_loop_2');
      await student.loadData();

      final controller = ReviewController(
        student: student,
        exporter: FakeExporter(),
      );
      await controller.loadReviewData();

      final composed = await composeFor(controller, student, 'rm_loop_2');
      final graded = await controller.submitPaper(
        paperId: composed.paperId,
        results: {composed.item.id: PaperItemResult.wrong},
      );

      expect(graded.op.ok, isTrue, reason: graded.op.message);
      expect(graded.passCount, 0);
      expect(graded.failCount, 1);
      expect(graded.graduatedCount, 0);
      expect(graded.backToPoolCount, 1);

      final mistake = controller.mistakeById('rm_loop_2')!;
      expect(mistake.state, ReviewState.pending, reason: '没通过必须回待复习池');
      expect(mistake.wrongCount, 2, reason: '回炉的唯一后果就是错误次数 +1');
      expect(mistake.lastWrongAt, isNotNull);
      expect(mistake.reviewRound, 1);
      // 第一次为什么错不能被覆盖 —— 那是最有价值的信息。
      expect(mistake.wrongReason, '分母处理错误');

      final attempt = controller.attemptsOf('rm_loop_2').single;
      expect(attempt.correct, isFalse);
      expect(
        attempt.channel,
        AttemptChannel.paperSelf,
        reason: '没填答案时按自评通道记录，渠道要能和 AI 判定区分开',
      );

      expect(controller.summaryOfPaper(composed.paperId)!.passRate, 0);
    });

    test('反复错的题（错 ≥3 次）需连续两轮通过才毕业', () async {
      final student = await buildStudent();
      await seedMistake(id: 'rm_repeat', wrongCount: 3);
      await student.loadData();

      final controller = ReviewController(
        student: student,
        exporter: FakeExporter(),
      );
      await controller.loadReviewData();

      // 第一轮通过：不能毕业
      final first = await composeFor(controller, student, 'rm_repeat');
      final firstResult = await controller.submitPaper(
        paperId: first.paperId,
        results: {first.item.id: PaperItemResult.correct},
        answers: {first.item.id: first.item.answerKey},
      );
      expect(firstResult.op.ok, isTrue, reason: firstResult.op.message);
      expect(firstResult.passCount, 1);
      expect(firstResult.graduatedCount, 0, reason: '反复错的题不该一轮就放过');
      expect(
        controller.mistakeById('rm_repeat')!.state,
        ReviewState.pending,
        reason: '通过了但没到毕业门槛，回池等下一轮',
      );

      // 第二轮再通过：连续两轮 → 毕业
      final second = await composeFor(controller, student, 'rm_repeat');
      final secondResult = await controller.submitPaper(
        paperId: second.paperId,
        results: {second.item.id: PaperItemResult.correct},
        answers: {second.item.id: second.item.answerKey},
      );
      expect(secondResult.graduatedCount, 1);
      expect(
        controller.mistakeById('rm_repeat')!.state,
        ReviewState.mastered,
        reason: '连续两轮通过才确认掌握',
      );
      expect(controller.attemptsOf('rm_repeat').length, 2);
    });

    test('已掌握的题不会被自动组卷再次收录', () async {
      final student = await buildStudent();
      await seedMistake(id: 'rm_keep_pending');
      await seedMistake(
        id: 'rm_already_mastered',
        state: ReviewState.mastered,
      );
      await student.loadData();

      final controller = ReviewController(
        student: student,
        exporter: FakeExporter(),
      );
      await controller.loadReviewData();

      final compose = await controller.composeAndPrintPaper();
      expect(compose.ok, isTrue, reason: compose.message);
      final items = await controller.openPaper(
        controller.activePaper.value!.id,
      );
      expect(items.any((item) => item.mistakeId == 'rm_already_mastered'), isFalse);
      expect(items.any((item) => item.mistakeId == 'rm_keep_pending'), isTrue);
    });
  });

  group('讲解与举一反三', () {
    test('讲解只是过程留痕，不构成毕业', () async {
      final student = await buildStudent();
      await seedMistake(id: 'rm_explain');
      await student.loadData();

      final controller = ReviewController(
        student: student,
        exporter: FakeExporter(),
      );
      await controller.loadReviewData();

      final explanation = await controller.explainMistake('rm_explain');
      expect(explanation, isNotNull);
      expect(explanation!.knowledgePoint, isNotEmpty);
      expect(explanation.steps, isNotEmpty);
      expect(explanation.pitfalls, isNotEmpty);
      expect(explanation.mnemonic, isNotEmpty);

      expect(
        controller.mistakeById('rm_explain')!.state,
        ReviewState.pending,
        reason: '看懂 ≠ 会做，讲解不能把人送出错题库',
      );

      final timeline = await controller.timelineOf('rm_explain');
      expect(timeline.any((e) => e.kind == TimelineKind.explained), isTrue);
    });

    test('举一反三 3 道全对才算通过，证据渠道记为练习', () async {
      final student = await buildStudent();
      await seedMistake(id: 'rm_practice');
      await student.loadData();

      final controller = ReviewController(
        student: student,
        exporter: FakeExporter(),
      );
      await controller.loadReviewData();

      final generated = await controller.generatePractice('rm_practice');
      expect(generated.ok, isTrue, reason: generated.message);

      final questions = controller.questionsOf('rm_practice');
      expect(questions.length, 3, reason: '默认出 3 道变式题');
      expect(
        questions.every((q) => q.knowledgePoint == '分数比较'),
        isTrue,
        reason: '出题要围绕这次错的知识点，而不是随便三道同科目题',
      );

      // 先答对 2 道就提交：不算通过
      controller.answerPractice(questions[0].id, questions[0].answer);
      controller.answerPractice(questions[1].id, questions[1].answer);
      controller.answerPractice(questions[2].id, '随便写的错误答案');
      final partial = await controller.submitAllPractice('rm_practice');
      expect(partial.ok, isFalse);
      expect(partial.message, contains('2/3'));
      expect(
        controller.mistakeById('rm_practice')!.state,
        ReviewState.pending,
      );

      // 改对最后一道：全对 → 毕业
      final refreshed = controller.questionsOf('rm_practice');
      controller.answerPractice(refreshed[2].id, refreshed[2].answer);
      final all = await controller.submitAllPractice('rm_practice');
      expect(all.ok, isTrue, reason: all.message);
      expect(controller.mistakeById('rm_practice')!.state, ReviewState.mastered);

      final last = controller.attemptsOf('rm_practice').last;
      expect(last.channel, AttemptChannel.practice);
      expect(last.correct, isTrue);
    });
  });

  group('掌握率的口径', () {
    test('自评掌握不计入掌握率', () {
      ReviewMistake make(String id, ReviewState state, {bool self = false}) =>
          ReviewMistake(
            id: id,
            subject: '数学',
            title: '题 $id',
            originalAnswer: '',
            wrongReason: '',
            createdAt: DateTime.now(),
            state: state,
            masteredBySelf: self,
          );

      final pool = [
        make('a', ReviewState.mastered), // 通过检查毕业 → 计入分子
        make('b', ReviewState.mastered, self: true), // 自评 → 完全排除
        make('c', ReviewState.pending), // 待复习 → 计入分母
      ];

      // 通过检查 1 道、待复习 1 道 → 1/2。自评那道被排除在外，
      // 否则「点一下标记掌握」就能把掌握率做漂亮。
      expect(ReviewService.masteryRate(pool), 0.5);
    });

    test('自评掌握会被标记来源，且不再被回卷子降级', () async {
      final student = await buildStudent();
      await seedMistake(id: 'rm_self');
      await student.loadData();

      final controller = ReviewController(
        student: student,
        exporter: FakeExporter(),
      );
      await controller.loadReviewData();

      final result = await controller.markMasteredBySelf('rm_self');
      expect(result.ok, isTrue, reason: result.message);
      final mistake = controller.mistakeById('rm_self')!;
      expect(mistake.state, ReviewState.mastered);
      expect(mistake.masteredBySelf, isTrue);
      expect(controller.poolMistakes.any((m) => m.id == 'rm_self'), isFalse);
    });
  });

  group('数据库迁移 v18 → v20', () {
    test('老库补列建表，旧复习轮次迁入资料表且不参与当前闭环', () async {
      final dir = await createIsolatedTestDir('easy_learn_v18_');
      pointPathProviderTo(dir);
      await DatabaseService.resetForTesting();

      // 造一个 v18 的库：旧版 review_mistake / review_cycle，
      // 外加一张 v18 状态的 homework。
      //
      // homework 必须建：真实 v18 库里它一定存在（v1 的基础表），
      // 而 v20 的迁移要给它补列 —— 夹具省掉它，测的就不是迁移而是夹具。
      final legacy = await databaseFactory.openDatabase(
        testDatabasePath(dir),
        options: OpenDatabaseOptions(
          version: 18,
          onCreate: (db, version) async {
            await db.execute('''
              CREATE TABLE review_mistake (
                id TEXT PRIMARY KEY,
                subject TEXT,
                title TEXT,
                originalAnswer TEXT,
                wrongReason TEXT,
                createdAt TEXT,
                state TEXT,
                studentId TEXT NOT NULL DEFAULT '',
                homeworkId TEXT NOT NULL DEFAULT ''
              )
            ''');
            await db.execute('''
              CREATE TABLE review_cycle (
                id TEXT PRIMARY KEY,
                studentId TEXT NOT NULL DEFAULT '',
                title TEXT,
                totalMistakes INTEGER NOT NULL DEFAULT 0,
                masteredCount INTEGER NOT NULL DEFAULT 0,
                generatedAt TEXT,
                pdfUrl TEXT NOT NULL DEFAULT ''
              )
            ''');
            await db.execute('''
              CREATE TABLE homework (
                id TEXT PRIMARY KEY,
                title TEXT,
                subject TEXT,
                imageUrl TEXT,
                dueAt TEXT,
                estimatedMinutes REAL,
                status TEXT,
                wrongCount INTEGER,
                aiEnabled INTEGER,
                userRole TEXT,
                studentId TEXT NOT NULL DEFAULT '',
                submittedAt TEXT,
                checkedAt TEXT,
                score INTEGER,
                summary TEXT NOT NULL DEFAULT '',
                imageCount INTEGER NOT NULL DEFAULT 0,
                submitBatchId TEXT NOT NULL DEFAULT ''
              )
            ''');
            // wish 同样必须建：它是 v1 就有的基础表，而且后续版本（v22）
            // 会给它补积分兑换的列。夹具省掉它，红的是夹具，不是被测的迁移。
            await db.execute('''
              CREATE TABLE wish (
                id TEXT PRIMARY KEY,
                title TEXT,
                description TEXT,
                isPublic INTEGER,
                parentConfirmed INTEGER,
                studentConfirmed INTEGER,
                isArchived INTEGER,
                userRole TEXT,
                studentId TEXT NOT NULL DEFAULT '',
                expectedDate TEXT
              )
            ''');
            // app_user 同理：v23 的迁移要给它补 passwordUpdatedAt，
            // 夹具省掉它，报错会写成「no such table: app_user」。
            // 用 v3 时代的形状，好让那一步真的有列可加。
            await db.execute('''
              CREATE TABLE app_user (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                phone TEXT UNIQUE,
                role TEXT NOT NULL,
                avatar TEXT NOT NULL,
                password TEXT,
                wechatOpenId TEXT UNIQUE,
                gender TEXT DEFAULT '',
                grade TEXT DEFAULT '',
                hobbies TEXT DEFAULT '',
                bio TEXT DEFAULT ''
              )
            ''');
            await db.insert('review_mistake', {
              'id': 'rm_legacy',
              'subject': '数学',
              'title': '旧版错题',
              'originalAnswer': '3/4 > 2/3',
              'wrongReason': '分母处理错误',
              'createdAt': DateTime.now().toIso8601String(),
              'state': 'pending',
              'studentId': 'stu_001',
              'homeworkId': 'hw_001',
            });
            await db.insert('review_cycle', {
              'id': 'rc_legacy',
              'studentId': 'stu_001',
              'title': '旧版复习轮次',
              'totalMistakes': 4,
              'masteredCount': 3,
              'generatedAt': DateTime.now().toIso8601String(),
              'pdfUrl': 'review_old.pdf',
            });
            // 一条批改过的、一条没批改过的作业。
            await db.insert('homework', {
              'id': 'hw_graded',
              'title': '旧版已批改作业',
              'subject': '数学',
              'status': 'finished',
              'wrongCount': 0,
              'aiEnabled': 1,
              'userRole': 'student',
              'studentId': 'stu_001',
              'checkedAt': DateTime.now().toIso8601String(),
              'score': 90,
              'summary': '旧版批改结论',
            });
            await db.insert('homework', {
              'id': 'hw_pending',
              'title': '旧版未提交作业',
              'subject': '语文',
              'status': 'pending',
              'wrongCount': 0,
              'aiEnabled': 1,
              'userRole': 'student',
              'studentId': 'stu_001',
            });
          },
        ),
      );
      await legacy.close();

      // 用当前版本打开 → 触发 _onUpgrade。
      final db = await LocalDatabaseService.instance.database;

      final columns = (await db.rawQuery('PRAGMA table_info(review_mistake)'))
          .map((row) => row['name'] as String)
          .toSet();
      expect(
        columns,
        containsAll(<String>[
          'knowledgePoint',
          'wrongCount',
          'lastWrongAt',
          'sourceHomeworkTitle',
          'masteredAt',
          'masteredBySelf',
          'reviewRound',
          'lastReviewedAt',
        ]),
        reason: '_onUpgrade 加了列，_onCreate 也必须同步补，两个入口要一起改',
      );

      final tables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      )).map((row) => row['name'] as String).toSet();
      expect(
        tables,
        containsAll(<String>[
          'review_paper',
          'review_paper_item',
          'review_attempt',
          'ai_practice_question',
          'explain_record',
          'review_summary',
        ]),
      );

      // 老数据读得出来，新增列拿到默认值而不是 null 崩掉。
      final mistakes = await DatabaseService.instance.queryReviewMistakes();
      final legacyMistake = mistakes.firstWhere((m) => m.id == 'rm_legacy');
      expect(legacyMistake.wrongCount, 1);
      expect(legacyMistake.knowledgePoint, '');
      expect(
        legacyMistake.lastWrongAt,
        isNotNull,
        reason: '回填 createdAt，否则薄弱度衰减拿不到基准时间',
      );

      // 旧轮次迁成「已归档」：能说明历史，但不该混进待作答列表。
      final papers = await DatabaseService.instance.queryReviewPapers();
      final migrated = papers.firstWhere((p) => p.id == 'rc_legacy');
      expect(migrated.status, PaperStatus.closed);
      expect(migrated.itemCount, 4);
      expect(migrated.failCount, 1);
      expect(migrated.filePath, 'review_old.pdf');

      // v20：批改来源。
      final homeworkColumns = (await db.rawQuery('PRAGMA table_info(homework)'))
          .map((row) => row['name'] as String)
          .toSet();
      expect(
        homeworkColumns,
        contains('gradingSource'),
        reason: '_onUpgrade 加列时 _onCreate 必须同步补，否则全新安装直接炸',
      );

      final items = await DatabaseService.instance.queryHomework('student');
      final graded = items.firstWhere((item) => item.id == 'hw_graded');
      expect(
        graded.gradedLocally,
        isTrue,
        reason: '这个版本之前没有云端路径，历史批改结果全是本地实现产出的；'
            '不回填的话它们会被当成模型输出',
      );
      final pending = items.firstWhere((item) => item.id == 'hw_pending');
      expect(
        pending.gradingSource,
        GradingSource.none,
        reason: '没批改过的作业不该有来源，否则界面会显示一个没有结果的「离线」标记',
      );

      await tearDownTestDatabase(dir);
    });
  });

  // ===== 导出：打印 / 下载 / 转发 =====
  //
  // 三个去向的能力边界完全不同（有没有打印机、浏览器支不支持分享），
  // 所以这一组压的不是界面，而是**有没有把学生送到正确的通道**，
  // 以及失败时会不会谎报成功。
  group('导出：打印 / 下载 / 转发', () {
    test('组卷默认不自动导出 —— 取走方式由学生选', () async {
      final student = await buildStudent();
      await seedMistake(id: 'rm_export_1');
      await student.loadData();

      final exporter = FakeExporter();
      final controller = ReviewController(student: student, exporter: exporter);
      await controller.loadReviewData();

      final composed = await composeFor(controller, student, 'rm_export_1');

      expect(
        exporter.printCalls,
        0,
        reason: '不能替学生决定取走方式：直接唤起打印会让没有打印机的人卡住',
      );
      expect(exporter.saveCalls, 0);
      expect(exporter.shareCalls, 0);

      final paper = controller.paperById(composed.paperId)!;
      expect(paper.status, PaperStatus.draft, reason: '还没导出就还是草稿');
      expect(paper.exportedAt, isNull);
    });

    test('下载与转发各走各的通道，成功后记导出时间', () async {
      final student = await buildStudent();
      await seedMistake(id: 'rm_export_2');
      await student.loadData();

      final exporter = FakeExporter();
      final controller = ReviewController(student: student, exporter: exporter);
      await controller.loadReviewData();
      final composed = await composeFor(controller, student, 'rm_export_2');

      final download = await controller.exportPaper(
        composed.paperId,
        target: ExportTarget.download,
      );
      expect(download.ok, isTrue);
      expect(exporter.saveCalls, 1);
      expect(exporter.printCalls, 0, reason: '选了下载就只该下载');
      // 交出去的东西必须是真 PDF：之前这里给的是一串 HTML 路径，
      // 学生既看不到文件也打不开 —— 那等于没导出。
      expect(exporter.lastPdf, isNotNull);
      expect(
        String.fromCharCodes(exporter.lastPdf!.take(5)),
        '%PDF-',
        reason: '交给系统保存的不是 PDF 文件',
      );
      var paper = controller.paperById(composed.paperId)!;
      expect(paper.status, PaperStatus.printed, reason: '导出成功应进入待作答');
      expect(paper.exportedAt, isNotNull);

      final share = await controller.exportPaper(
        composed.paperId,
        target: ExportTarget.share,
        includeAnswerPage: false,
      );
      expect(share.ok, isTrue);
      expect(exporter.shareCalls, 1);
      expect(exporter.lastText, contains('分数比较'));
      expect(
        exporter.lastText,
        isNot(contains('参考答案')),
        reason: '关掉答案页时，转发文本里也不该有答案',
      );
      expect(
        exporter.lastPdf,
        isNotNull,
        reason: '转发时要带上真正生成好的 PDF，而不是只发一段文字',
      );
      paper = controller.paperById(composed.paperId)!;
      expect(paper.exportedAt, isNotNull);
    });

    test('导出会去「取」原题照片，而不是只看本会话刚上传的缓存', () async {
      // 2026-10-23 用户报：「导出 PDF 时图形题的原题（原图）没有」。
      //
      // 真因不是老数据缺图，而是取图走错了口：`imageStorage.readImage` 是
      // **同步**接口，远端实现只认得本进程刚上传、还在 6 张内存缓存里的字节
      // （`RemoteImageStorageService.recentUpload`）。隔天拍的照片一律 null，
      // 于是卷面上图形题只剩一行文字 —— 而导出**成功**，一声不响。
      //
      // 这条判据把「取图」换成一个可观测的加载器：只要它没被调用，
      // 照片就只可能在「刚上传」那一小段窗口里出现，其余时候必然是空的。
      final student = await buildStudent();
      // 图形题的真实形态：题干没有文字，信息全在图里。
      await seedMistake(id: 'rm_img_1', questionBody: '');
      await DatabaseService.instance.insertMistakeImages([
        ReviewMistakeImage(
          id: 'img_1',
          studentId: 'stu_001',
          mistakeId: 'rm_img_1',
          // 服务端键（不是 `memory://`）—— 本地盘上根本没有这个文件。
          storageKey: '20261023/stu_001/figure.jpg',
          fileSize: 100,
        ),
      ]);
      await student.loadData();

      final asked = <String>[];
      final exporter = FakeExporter();
      final controller = ReviewController(
        student: student,
        exporter: exporter,
        imageLoader: (image, {String endpoint = ''}) async {
          asked.add('${image.storageKey}@$endpoint');
          return base64Decode(_tinyJpegBase64);
        },
      );
      await controller.loadReviewData();
      final composed = await composeFor(controller, student, 'rm_img_1');

      final result = await controller.exportPaper(
        composed.paperId,
        target: ExportTarget.download,
      );

      expect(result.ok, isTrue, reason: result.message);
      expect(
        asked.any((k) => k.startsWith('20261023/stu_001/figure.jpg@')),
        isTrue,
        reason: '导出没去取原题照片 —— 只有「本会话刚拍的」那张才印得出来，'
            '隔天/换设备导出就是空白卷',
      );
      expect(
        asked.first,
        contains('/data/review/mistake-images/file'),
        reason: '错题照片与作业照片是两张表，端点走错会取到别人的图或取不到',
      );
      expect(exporter.lastPdf, isNotNull);
    });

    test('转发被取消时不算导出成功：卷子不能显示成「已导出」', () async {
      final student = await buildStudent();
      await seedMistake(id: 'rm_export_3');
      await student.loadData();

      final exporter = FakeExporter()
        ..nextResult = const ExportResult(ok: false, message: '已取消转发。');
      final controller = ReviewController(student: student, exporter: exporter);
      await controller.loadReviewData();
      final composed = await composeFor(controller, student, 'rm_export_3');

      final result = await controller.exportPaper(
        composed.paperId,
        target: ExportTarget.share,
      );
      expect(result.ok, isFalse);
      final paper = controller.paperById(composed.paperId)!;
      expect(
        paper.status,
        PaperStatus.draft,
        reason: '取消转发却标成「已导出」，学生手上会什么都没有',
      );
      expect(paper.exportedAt, isNull);
    });

    test('资料不存在时如实报错，不去调导出通道', () async {
      final student = await buildStudent();
      await student.loadData();
      final exporter = FakeExporter();
      final controller = ReviewController(student: student, exporter: exporter);
      await controller.loadReviewData();

      final result = await controller.exportPaper('rp_not_exist');

      expect(result.ok, isFalse);
      expect(result.message, contains('资料不存在'));
      expect(exporter.printCalls, 0);
    });

    test('原题照片跟着卷子一起导出（题干里的图文字表达不了）', () async {
      final student = await buildStudent();
      await student.loadData();

      final storage = LocalImageStorageService(useMemory: true);
      final stored = await storage.saveHomeworkImage(
        studentId: 'stu_001',
        fileName: 'q.jpg',
        bytes: base64Decode(_tinyJpegBase64),
      );
      await DatabaseService.instance.insertReviewMistakeWithImages(
        ReviewMistake(
          id: 'rm_img',
          subject: '数学',
          title: '看图列式',
          questionBody: '看图列式，求这个月的水费。',
          originalAnswer: '2x',
          wrongReason: '漏了基础水费',
          knowledgePoint: '列代数式',
          createdAt: DateTime.now(),
          state: ReviewState.pending,
          studentId: 'stu_001',
        ),
        [
          ReviewMistakeImage(
            id: 'rmi_1',
            studentId: 'stu_001',
            mistakeId: 'rm_img',
            storageKey: stored.storageKey,
            mimeType: stored.mimeType,
          ),
        ],
      );

      final exporter = FakeExporter();
      // 先确认「这条链路的前半段」是通的：行确实落库了、字节确实读得回来。
      // 不先断这个的话，后面的红分不清是「没取到图」还是「没画上去」。
      final rows = await DatabaseService.instance.queryMistakeImages('rm_img');
      expect(rows, hasLength(1));
      expect(storage.readImage(rows.first.storageKey), isNotNull);

      // 生产装配里也传了同一份 imageStorage（见 `student_home_page.dart`）——
      // 不传的话导出时根本读不到图，而界面不会有任何提示。
      final controller = ReviewController(
        student: student,
        exporter: exporter,
        imageStorage: storage,
      );
      await controller.loadReviewData();
      // 错题是在 `student.loadData()` 之后插进去的，得再读一次，
      // 否则控制器的错题池里没有它 —— 组卷会直接报「没有可组卷的错题」。
      await student.loadData();
      final composed = await composeFor(controller, student, 'rm_img');
      expect(
        composed.item.mistakeId,
        'rm_img',
        reason: '卷内题没记住来自哪道错题 —— 图片就查不到',
      );

      await controller.exportPaper(
        composed.paperId,
        target: ExportTarget.print,
      );

      expect(
        exporter.lastHtml,
        contains('data:image/jpeg;base64,'),
        reason: '原题照片没进卷子 —— 学生只能看到文字题干',
      );
      expect(exporter.lastPdf, isNotNull);
    });

    test('转发文本：无 HTML 标签、题干与提示分行、答案在末尾', () {
      final paper = ReviewPaper(
        id: 'rp_text',
        studentId: 'stu_001',
        title: '数学错题重做卷 · 第1轮',
        subject: '数学',
        knowledgePoints: const ['分数比较'],
        itemCount: 2,
        createdAt: DateTime(2026, 9, 15, 20, 10),
      );
      final items = [
        ReviewPaperItem(
          id: 'rpi_1',
          paperId: 'rp_text',
          mistakeId: 'rm_1',
          questionTitle: '分数比较题',
          questionBody: '重新独立完成这道题，写出完整过程。\n上次的答案：3/4 > 2/3',
          answerKey: '2/3 更大',
        ),
        ReviewPaperItem(
          id: 'rpi_2',
          paperId: 'rp_text',
          mistakeId: 'rm_2',
          questionTitle: '通分题',
          questionBody: '重新独立完成这道题，写出完整过程。',
          answerKey: '11/12',
          sortOrder: 1,
        ),
      ];

      final text = ReviewPaperHtml.buildText(
        paper: paper,
        items: items,
        studentName: '林小宇',
        includeAnswers: true,
      );

      expect(text, contains('数学错题重做卷 · 第1轮'));
      expect(text, contains('学生：林小宇'));
      expect(text, contains('1. 重新独立完成这道题，写出完整过程。'));
      expect(text, contains('2. 重新独立完成这道题，写出完整过程。'));
      expect(
        text,
        contains('（上次的答案：3/4 > 2/3）'),
        reason: '提示行要跟题干区分开，不然读起来像题目的一部分',
      );
      expect(
        text,
        isNot(contains('<')),
        reason: '微信不渲染 HTML，标签发出去只会变成一堆乱码字符',
      );
      expect(
        text.indexOf('—— 参考答案 ——'),
        greaterThan(text.indexOf('2. ')),
        reason: '答案必须排在题目后面，否则转发出去等于直接给答案',
      );

      final noAnswer = ReviewPaperHtml.buildText(
        paper: paper,
        items: items,
        studentName: '林小宇',
      );
      expect(noAnswer, isNot(contains('参考答案')));
      expect(noAnswer.indexOf('1. '), greaterThan(-1));
    });
  });
}
