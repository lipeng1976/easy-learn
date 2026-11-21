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
import 'package:easy_learn_app/services/simulated_ai_data_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';
import 'helpers/fake_exporter.dart';

/// 举一反三**作答**的保存语义。
///
/// 这一组断言存在的理由：变式题的作答刻意**只存内存、不落库**（提交检查时
/// 才写证据）。这个设计本身没问题，但它带来两条极容易被忽略的破坏路径：
///
/// 1. 任何一次重新载入复习数据，都会用库里的旧值把内存中还没提交的作答**盖掉**；
/// 2. 三道题是**串行**送模型的（实测整轮十几秒）。这十几秒里界面若没有反馈，
///    学生会以为点空了，顺手回去改题 —— 而提交逻辑如果拿「进循环时的快照」
///    回写，就会把那段修改一并抹掉。
///
/// 两者的现场表现完全一样：**某个输入框突然空了**。所以必须分开盯着。
/// 相关实现见 `ReviewController.answerPractice` / `loadReviewData` /
/// `submitAllPractice`。
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

  Future<void> seedMistake(String id) async {
    await DatabaseService.instance.insertReviewMistake(
      ReviewMistake(
        id: id,
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
      ),
    );
  }

  /// 建一个已经出好 3 道变式题的控制器。
  Future<ReviewController> withQuestions(
    String mistakeId, {
    AiDataSource? ai,
  }) async {
    final student = await buildStudent();
    await seedMistake(mistakeId);
    await student.loadData();

    final controller = ReviewController(
      student: student,
      exporter: FakeExporter(),
      ai: ai,
    );
    await controller.loadReviewData();

    final generated = await controller.generatePractice(mistakeId);
    expect(generated.ok, isTrue, reason: generated.message);
    expect(controller.questionsOf(mistakeId).length, 3);

    return controller;
  }

  group('变式题作答的保存语义', () {
    test('重新载入复习数据，不会抹掉还没提交的作答', () async {
      final controller = await withQuestions('rm_keep');

      final first = controller.questionsOf('rm_keep').first;
      controller.answerPractice(first.id, '我算出来是 0.75');
      // 此刻库里仍是空的 —— answerPractice 刻意不落库。
      final stored = await DatabaseService.instance.queryPracticeQuestions();
      expect(
        stored.firstWhere((q) => q.id == first.id).studentAnswer,
        '',
        reason: '前提：未提交的作答不进库',
      );

      // 学生切走再回来、或页面重建 —— 与进入详情页时同一条路径。
      await controller.loadReviewData();

      expect(
        controller.questionsOf('rm_keep').first.studentAnswer,
        '我算出来是 0.75',
        reason: '还没提交的作答没有副本，重新载入必须把它带回来，不能静默丢弃',
      );
    });

    test('重新载入不会把已落库的作答搞丢', () async {
      final controller = await withQuestions('rm_keep2');
      final questions = controller.questionsOf('rm_keep2');
      for (final question in questions) {
        controller.answerPractice(question.id, question.answer);
      }
      // 提交一次：作答随证据一起落库。
      await controller.submitAllPractice('rm_keep2');

      await controller.loadReviewData();

      for (final question in controller.questionsOf('rm_keep2')) {
        expect(
          question.studentAnswer.trim(),
          isNotEmpty,
          reason: '已提交的作答在库里，重新载入后必须还在',
        );
      }
    });

    test('提交期间改的答案，不会被这次提交的快照覆盖', () async {
      late ReviewController controller;
      var hooked = false;

      // 复刻真机时序：第 1 题正在判定（十几秒没有反馈）时，
      // 学生以为点空了，顺手回去改了第 3 题。
      final hook = _HookAi(
        const SimulatedAiDataSource(),
        onJudge: () {
          if (hooked) return;
          hooked = true;
          final third = controller.questionsOf('rm_edit')[2];
          controller.answerPractice(
            third.id,
            '${third.studentAnswer}（等的时候又补了一句）',
          );
        },
      );

      controller = await withQuestions('rm_edit', ai: hook);
      final questions = controller.questionsOf('rm_edit');
      for (final question in questions) {
        controller.answerPractice(question.id, question.answer);
      }

      final result = await controller.submitAllPractice('rm_edit');
      expect(result.ok, isTrue, reason: result.message);
      expect(hooked, isTrue, reason: '前提：判定确实发生过，钩子才有机会跑');

      final third = controller.questionsOf('rm_edit')[2];
      expect(
        third.studentAnswer,
        contains('等的时候又补了一句'),
        reason: '判定等待期间学生补的内容必须留着 —— '
            '用进循环时的快照回写就会把它抹掉，现象正是「提交后输入没了」',
      );
    });
  });

  group('提交态的进出', () {
    test('提交期间处于「正在检查」，结束后复位', () async {
      final controller = await withQuestions('rm_busy');
      final questions = controller.questionsOf('rm_busy');
      for (final question in questions) {
        controller.answerPractice(question.id, question.answer);
      }

      final pending = controller.submitAllPractice('rm_busy');
      expect(
        controller.submittingPractice.value,
        isTrue,
        reason: '没有这个状态，界面就不会禁用按钮、也不会显示「正在检查…」，'
            '学生只会看到点了没反应',
      );

      await pending;
      expect(controller.submittingPractice.value, isFalse);
    });

    test('早退（题目不存在）也必须复位，否则按钮永久变灰', () async {
      final controller = await withQuestions('rm_busy2');

      final missing = await controller.submitAllPractice('rm_不存在');
      expect(missing.ok, isFalse);
      expect(
        controller.submittingPractice.value,
        isFalse,
        reason: '这类早退分支最容易漏复位，一旦漏掉，按钮就再也点不动了',
      );
    });

    test('提交进行中重复调用会被挡下，而不是排队跑第二遍', () async {
      final controller = await withQuestions('rm_busy3');
      final questions = controller.questionsOf('rm_busy3');
      for (final question in questions) {
        controller.answerPractice(question.id, question.answer);
      }

      final first = controller.submitAllPractice('rm_busy3');
      final second = await controller.submitAllPractice('rm_busy3');
      await first;

      expect(
        second.ok,
        isFalse,
        reason: '重复提交会给同一道题记两次判定证据，判定分母就脏了',
      );
    });
  });
}

/// 在每次单题判定**开始前**插一个动作，其余方法原样透传。
///
/// 存在的意义是复刻真实时序 —— 判定要等模型，而等待期间发生的事
/// （学生继续改答案）才是这条链路上真正难测的部分。
class _HookAi implements AiDataSource {
  const _HookAi(this._inner, {required this.onJudge});

  final AiDataSource _inner;
  final void Function() onJudge;

  @override
  Future<List<MistakeTipDraft>> summarizeMistakeTips({
    required String subject,
    required List<MistakeTipSeed> items,
  }) => _inner.summarizeMistakeTips(subject: subject, items: items);

  // 打卡出题直通内层：这个 hook 只关心判分调用，不该在这里造第二套行为。
  @override
  Future<List<CheckinQuestion>> generateCheckinQuestions({
    required String subject,
    required List<CheckinSeed> items,
    int count = 5,
  }) => _inner.generateCheckinQuestions(subject: subject, items: items, count: count);

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
  }) => _inner.generateFigure(
    subject: subject,
    knowledgePoint: knowledgePoint,
    title: title,
    questionBody: questionBody,
    wrongReason: wrongReason,
    referenceAnswer: referenceAnswer,
    studentProcess: studentProcess,
    images: images,
  );


  @override
  Future<AnswerJudgement> judgeAnswer({
    required String studentAnswer,
    required String referenceAnswer,
    String subject = '',
    String knowledgePoint = '',
    String questionContent = '',
  }) async {
    onJudge();
    return _inner.judgeAnswer(
      studentAnswer: studentAnswer,
      referenceAnswer: referenceAnswer,
      subject: subject,
      knowledgePoint: knowledgePoint,
      questionContent: questionContent,
    );
  }

  @override
  Future<HomeworkCheckOutcome> checkHomework({
    required String subject,
    required String title,
    List<String> imagePaths = const [],
  }) => _inner.checkHomework(
    subject: subject,
    title: title,
    imagePaths: imagePaths,
  );

  @override
  Future<MistakeExtraction> extractMistakes({
    required List<String> imagePaths,
    String hint = '',
  }) => _inner.extractMistakes(imagePaths: imagePaths, hint: hint);

  @override
  Future<AnswerRecognition> recognizeAnswer({
    required List<String> imagePaths,
    String questionContent = '',
    String knowledgePoint = '',
  }) => _inner.recognizeAnswer(
    imagePaths: imagePaths,
    questionContent: questionContent,
    knowledgePoint: knowledgePoint,
  );

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
  }) => _inner.explainMistake(
    subject: subject,
    knowledgePoint: knowledgePoint,
    title: title,
    wrongReason: wrongReason,
    questionBody: questionBody,
    images: images,
    referenceAnswer: referenceAnswer,
    studentProcess: studentProcess,
  );

  @override
  Future<List<GeneratedQuestion>> generatePractice({
    required String subject,
    required String knowledgePoint,
    String difficulty = '基础',
    int round = 1,
    int count = 3,
    List<AiSourceImage> images = const [],
  }) => _inner.generatePractice(
    subject: subject,
    knowledgePoint: knowledgePoint,
    difficulty: difficulty,
    round: round,
    count: count,
  );

  @override
  Future<String> referenceAnswerFor({
    required String subject,
    required String knowledgePoint,
  }) => _inner.referenceAnswerFor(
    subject: subject,
    knowledgePoint: knowledgePoint,
  );

  @override
  Future<Map<String, String>> referenceAnswersFor(
    List<ReferenceQuery> queries,
  ) => _inner.referenceAnswersFor(queries);
}
