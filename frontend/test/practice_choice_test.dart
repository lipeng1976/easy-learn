import 'dart:io';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/review_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/services/ai_data_source.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/services/simulated_ai_data_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';
import 'helpers/fake_exporter.dart';

/// 选择题/判断题走**本地判定**。
///
/// 这一组的核心判据只有一句：**提交三道选择题，模型一次都不该被调用**。
///
/// 值得单独守的原因是它很容易「看起来实现了、其实没生效」：
/// 判定入口在 `checkPractice` 与 `submitAllPractice` 两个地方，
/// 只要有一处还留着 `ai.judgeAnswer`，那条路就仍然是模型判的 ——
/// 而界面上看不出任何区别，只有账单和判定波动能发现。
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

  Future<void> seedMistake(String id, {int wrongCount = 1}) async {
    await DatabaseService.instance.insertReviewMistake(
      ReviewMistake(
        id: id,
        subject: '数学',
        title: '方程题',
        questionBody: r'下列方程中，解为 $x=2$ 的是（ ）',
        originalAnswer: 'B',
        wrongReason: '移项没变号',
        knowledgePoint: '一元一次方程',
        wrongCount: wrongCount,
        lastWrongAt: DateTime.now(),
        studentId: 'stu_001',
        createdAt: DateTime.now(),
        state: ReviewState.pending,
      ),
    );
  }

  Future<ReviewController> withChoiceQuestions(
    String mistakeId, {
    required _ChoiceAi ai,
    int wrongCount = 1,
  }) async {
    final student = StudentController(
      aiCheckDelay: Duration.zero,
      imageStorage: LocalImageStorageService(useMemory: true),
    );
    await student.loadData();
    await seedMistake(mistakeId, wrongCount: wrongCount);
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

  group('选择题的本地判定', () {
    test('三道选择题提交，模型判定一次都没被调用', () async {
      final ai = _ChoiceAi();
      final controller = await withChoiceQuestions('rm_choice', ai: ai);

      // 前提：题目真的是选择题。否则这条断言会在「全是解答题」上假绿。
      final questions = controller.questionsOf('rm_choice');
      expect(questions.every((q) => q.isChoice), isTrue);
      expect(questions.every((q) => q.options.length == 4), isTrue);

      for (final question in questions) {
        controller.answerPractice(question.id, question.answer);
      }
      final result = await controller.submitAllPractice('rm_choice');

      expect(result.ok, isTrue, reason: result.message);
      expect(ai.judgeCalls, 0, reason: '选择题答案集合封闭，不该花一次模型调用');
      expect(
        controller.questionsOf('rm_choice').every(
          (q) => q.state == PracticeState.correct,
        ),
        isTrue,
      );
    });

    test('选错选项：题目置为 wrong，并写一行 review_attempt', () async {
      final ai = _ChoiceAi();
      final controller = await withChoiceQuestions('rm_choice_wrong', ai: ai);
      final questions = controller.questionsOf('rm_choice_wrong');
      final before = controller.attemptsOf('rm_choice_wrong').length;

      // 第一题故意选错（正确答案是 A），另外两题答对。
      controller.answerPractice(questions[0].id, 'B');
      controller.answerPractice(questions[1].id, questions[1].answer);
      controller.answerPractice(questions[2].id, questions[2].answer);

      final result = await controller.submitAllPractice('rm_choice_wrong');

      expect(result.ok, isFalse, reason: '有一道错了就不算通过');
      expect(ai.judgeCalls, 0, reason: '答错也是本地判的，不该问模型');
      final after = controller.questionsOf('rm_choice_wrong');
      expect(after[0].state, PracticeState.wrong);
      expect(after[1].state, PracticeState.correct);
      expect(
        controller.attemptsOf('rm_choice_wrong').length,
        before + 1,
        reason: '每一轮提交都要留下证据',
      );
    });

    test('全部答对也不得绕过毕业规则（反复错的题要连续两轮）', () async {
      // wrongCount >= 3 → `ReviewService` 要求连续两轮通过。
      final ai = _ChoiceAi();
      final controller = await withChoiceQuestions(
        'rm_choice_streak',
        ai: ai,
        wrongCount: 3,
      );
      for (final question in controller.questionsOf('rm_choice_streak')) {
        controller.answerPractice(question.id, question.answer);
      }

      await controller.submitAllPractice('rm_choice_streak');

      final mistake = controller.mistakeById('rm_choice_streak')!;
      expect(
        mistake.state,
        isNot(ReviewState.mastered),
        reason: '只通过一轮就毕业，等于把「蒙对一次」当成掌握',
      );
    });

    test('判断题提交同样不调模型', () async {
      final ai = _ChoiceAi(judgeQuestions: true);
      final controller = await withChoiceQuestions('rm_judge', ai: ai);
      final questions = controller.questionsOf('rm_judge');
      expect(questions.every((q) => q.isJudge), isTrue);

      for (final question in questions) {
        controller.answerPractice(question.id, question.answer);
      }
      final result = await controller.submitAllPractice('rm_judge');

      expect(result.ok, isTrue, reason: result.message);
      expect(ai.judgeCalls, 0);
    });

    test('填空 / 解答仍然交给模型判定', () async {
      // 对照：同样走 `submitAllPractice`，只是题型不同 ——
      // 如果本地判定把路走宽了（连填空也自己比对），这条会立刻变成 0。
      final ai = _ChoiceAi(judgeQuestions: false, types: const [
        PracticeQuestionType.fill,
        PracticeQuestionType.solution,
        PracticeQuestionType.solution,
      ]);
      final controller = await withChoiceQuestions('rm_text', ai: ai);
      for (final question in controller.questionsOf('rm_text')) {
        controller.answerPractice(question.id, question.answer);
      }

      await controller.submitAllPractice('rm_text');

      expect(ai.judgeCalls, 3, reason: '三道非封闭答案的题都要模型判');
    });
  });
}

/// 可控的练习用 AI。
///
/// 默认出三道单选题（答案都是 A），可以把 `judgeQuestions` 打开改成判断题，
/// 或者用 `types` 指定任意题型组合。
class _ChoiceAi extends SimulatedAiDataSource {
  _ChoiceAi({
    this.judgeQuestions = false,
    List<PracticeQuestionType>? types,
  }) : types = types ??
            (judgeQuestions
                ? const [
                    PracticeQuestionType.judge,
                    PracticeQuestionType.judge,
                    PracticeQuestionType.judge,
                  ]
                : const [
                    PracticeQuestionType.choice,
                    PracticeQuestionType.choice,
                    PracticeQuestionType.choice,
                  ]);

  final bool judgeQuestions;
  final List<PracticeQuestionType> types;

  int judgeCalls = 0;

  @override
  Future<List<GeneratedQuestion>> generatePractice({
    required String subject,
    required String knowledgePoint,
    String difficulty = '基础',
    int round = 1,
    int count = 3,
    List<AiSourceImage> images = const [],
  }) async {
    return List.generate(types.length, (index) {
      final type = types[index];
      final base = (
        title: '变式 ${index + 1}',
        content: r'计算 $\frac{1}{2}+\frac{1}{3}$ 的值。',
        difficulty: difficulty,
      );
      switch (type) {
        case PracticeQuestionType.choice:
          return GeneratedQuestion(
            title: base.title,
            content: '下列方程中，解为 x=2 的是（ ）',
            answer: 'A',
            difficulty: base.difficulty,
            questionType: type,
            options: const ['2x+1=5', '3x-1=4', 'x/2=2', '4x=6'],
          );
        case PracticeQuestionType.judge:
          return GeneratedQuestion(
            title: base.title,
            content: r'$\frac{1}{2}+\frac{1}{3}=\frac{5}{6}$',
            answer: '正确',
            difficulty: base.difficulty,
            questionType: type,
          );
        case PracticeQuestionType.fill:
        case PracticeQuestionType.solution:
          return GeneratedQuestion(
            title: base.title,
            content: base.content,
            answer: '5/6',
            difficulty: base.difficulty,
            questionType: type,
          );
      }
    });
  }

  @override
  Future<AnswerJudgement> judgeAnswer({
    required String studentAnswer,
    required String referenceAnswer,
    String subject = '',
    String knowledgePoint = '',
    String questionContent = '',
  }) async {
    judgeCalls++;
    return const AnswerJudgement(
      verdict: AnswerVerdict.correct,
      score: 100,
      comment: '模型判的',
      source: AiAnswerSource.cloud,
    );
  }
}
