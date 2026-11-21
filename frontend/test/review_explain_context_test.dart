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

/// 错题讲解的**输入**。
///
/// 2026-10-23 的真实故障：一道图形题在库里 `answerKey`、`studentProcess`、
/// `wrongReason` 全空，讲解只收到一句「用不同的方法表示下图的面积」，
/// 回来的是「横向切 / 竖向切 / 补形」这一套通用流程 —— 学生看完还是不会。
///
/// 后来把照片、参考答案、孩子写的过程都接上了。这几条判据盯的就是
/// 「库里有这些东西时，它们**真的被读出来并送进模型**」——
/// 只改接口不改调用点，表现和没改完全一样。
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

  Future<ReviewController> buildController(String mistakeId, _CapturingAi ai) async {
    final student = StudentController(
      aiCheckDelay: Duration.zero,
      imageStorage: LocalImageStorageService(useMemory: true),
    );
    await student.loadData();
    await DatabaseService.instance.insertReviewMistake(
      ReviewMistake(
        id: mistakeId,
        subject: '数学',
        title: '第三章 代数式 学法 P51',
        questionBody: '用不同的方法表示下图的面积（至少写出两种）。',
        // 这两样是这道题真正缺的东西。括号里的取值按 a=4,b=7,c=2,d=3 算。
        answerKey: 'ad + c(b-d)',
        studentProcess: 'S = ad + (b-a)c',
        originalAnswer: 'S = bc - (b-a)(d-c)',
        wrongReason: '',
        knowledgePoint: '组合图形面积计算',
        wrongCount: 1,
        lastWrongAt: DateTime.now(),
        studentId: 'stu_001',
        createdAt: DateTime.now(),
        state: ReviewState.pending,
      ),
    );
    await student.loadData();

    final controller = ReviewController(
      student: student,
      exporter: FakeExporter(),
      ai: ai,
    );
    await controller.loadReviewData();
    return controller;
  }

  test('讲解把参考答案与孩子当时写的过程一起送出去', () async {
    final ai = _CapturingAi();
    final controller = await buildController('rm_explain_ctx', ai);

    await controller.explainMistake('rm_explain_ctx');

    expect(
      ai.referenceAnswer,
      'ad + c(b-d)',
      reason: '库里有参考答案却没送出去 —— 讲解只能泛泛而谈',
    );
    expect(
      ai.studentProcess,
      'S = ad + (b-a)c',
      reason: '不知道孩子写了什么，就指不出「你哪一步错了」',
    );
    expect(ai.questionBody, '用不同的方法表示下图的面积（至少写出两种）。');
  });

  test('题目没有参考答案时传空串，不编一个占位答案', () async {
    final ai = _CapturingAi();
    final student = StudentController(
      aiCheckDelay: Duration.zero,
      imageStorage: LocalImageStorageService(useMemory: true),
    );
    await student.loadData();
    await DatabaseService.instance.insertReviewMistake(
      ReviewMistake(
        id: 'rm_no_answer',
        subject: '数学',
        title: '分数比较',
        questionBody: '比较 3/4 与 2/3 的大小。',
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
    await student.loadData();

    final controller = ReviewController(
      student: student,
      exporter: FakeExporter(),
      ai: ai,
    );
    await controller.loadReviewData();
    await controller.explainMistake('rm_no_answer');

    expect(ai.referenceAnswer, '', reason: '空串是合法值；编一个答案会骗到学生');
    expect(ai.studentProcess, '');
  });
}

/// 只做一件事：把 [explainMistake] 收到的参数留下来，其余照常走模拟实现。
///
/// 继承而不是 `implements AiDataSource`：接口有十几个方法，
/// 全实现一遍会产生一堆 `throw UnimplementedError` —— 那些噪音里
/// 很容易漏掉「这个方法到底测没测」。
class _CapturingAi extends SimulatedAiDataSource {
  _CapturingAi();

  String? referenceAnswer;
  String? studentProcess;
  String? questionBody;
  List<AiSourceImage> images = const [];

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
  }) {
    this.referenceAnswer = referenceAnswer;
    this.studentProcess = studentProcess;
    this.questionBody = questionBody;
    this.images = images;
    return super.explainMistake(
      subject: subject,
      knowledgePoint: knowledgePoint,
      title: title,
      wrongReason: wrongReason,
      questionBody: questionBody,
      images: images,
      referenceAnswer: referenceAnswer,
      studentProcess: studentProcess,
    );
  }
}
