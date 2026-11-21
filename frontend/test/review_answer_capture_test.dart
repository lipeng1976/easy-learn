import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/review_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/checkin_models.dart';
import 'package:easy_learn_app/models/homework_image_model.dart';
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

/// 举一反三**拍照作答**。
///
/// 这条链路的设计边界只有一句话：**拍照是输入方式，不是判定方式**。
/// 识别出来的文字要填进作答框、学生改得了，然后走原来那条判定。
/// 下面每一组断言都在守这条边界的不同侧面 —— 越界的形式有很多种，
/// 而它们有一个共同后果：同一份作答会因为「怎么输入的」得到不同结论，
/// 或者更糟，系统替学生写了一份他从没写过的答案。
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

  final photo = PracticeAnswerPhoto(
    fileName: 'answer.jpg',
    bytes: Uint8List.fromList(List<int>.filled(64, 7)),
  );

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

  Future<ReviewController> withQuestions(
    String mistakeId, {
    AiDataSource? ai,
    ImageStorageService? storage,
  }) async {
    final student = await buildStudent();
    await seedMistake(mistakeId);
    await student.loadData();

    final controller = ReviewController(
      student: student,
      exporter: FakeExporter(),
      ai: ai,
      imageStorage: storage ?? LocalImageStorageService(useMemory: true),
    );
    await controller.loadReviewData();

    final generated = await controller.generatePractice(mistakeId);
    expect(generated.ok, isTrue, reason: generated.message);
    expect(controller.questionsOf(mistakeId).length, 3);

    return controller;
  }

  group('拍照作答：识别结果进作答框', () {
    test('识别成功后文字落进作答框，且能继续走判定', () async {
      final controller = await withQuestions('rm_cap_ok', ai: _CloudOcr());
      final question = controller.questionsOf('rm_cap_ok').first;

      final result = await controller.captureAnswers(
        questionId: question.id,
        photos: [photo],
      );

      expect(result.ok, isTrue, reason: result.message);
      final updated = controller
          .questionsOf('rm_cap_ok')
          .firstWhere((q) => q.id == question.id);
      expect(
        updated.studentAnswer,
        '0.75',
        reason: '识别结果必须进作答框 —— 否则拍照等于什么都没做',
      );

      // 关键：它进的是**同一条**判定路径。判定能拿着这段文字跑起来，
      // 说明拍照没有另开一条旁路（那会让同一份作答因输入方式而结论不同）。
      final checked = await controller.checkPractice(question.id);
      expect(checked.ok, isTrue, reason: checked.message);
    });

    test('拍照作答与手动输入走同一条回写路径', () async {
      final controller = await withQuestions('rm_cap_same', ai: _CloudOcr());
      final question = controller.questionsOf('rm_cap_same').first;

      // 手动输入。
      controller.answerPractice(question.id, '0.75');
      final viaTyping = controller
          .questionsOf('rm_cap_same')
          .firstWhere((q) => q.id == question.id)
          .studentAnswer;

      // 清掉再走拍照。
      controller.answerPractice(question.id, '');
      await controller.captureAnswers(
        questionId: question.id,
        photos: [photo],
      );
      final viaPhoto = controller
          .questionsOf('rm_cap_same')
          .firstWhere((q) => q.id == question.id)
          .studentAnswer;

      expect(
        viaPhoto,
        viaTyping,
        reason: '两条输入路径必须落到同一个字段上；各写各的会得到两份互相看不见的作答',
      );
    });
  });

  group('拍照作答：不替学生编答案', () {
    test('本地兜底的编造文字**不许**落进作答框', () async {
      // 本地实现的 text 是一段占位说明、source 是 local。
      // 把它填进作答框 = 替学生写了一份他从没写过的答案，
      // 而他会以为那是系统认出来的。
      final controller = await withQuestions('rm_cap_local');
      final question = controller.questionsOf('rm_cap_local').first;

      final result = await controller.captureAnswers(
        questionId: question.id,
        photos: [photo],
      );

      expect(result.ok, isFalse);
      expect(
        controller
            .questionsOf('rm_cap_local')
            .firstWhere((q) => q.id == question.id)
            .studentAnswer,
        '',
        reason: '本地兜底给的是编造文字，绝不能当成学生的作答',
      );
    });

    test('识别失败时给的是「无法识别」，而不是「你没作答」', () async {
      final controller = await withQuestions('rm_cap_msg');
      final question = controller.questionsOf('rm_cap_msg').first;

      final result = await controller.captureAnswers(
        questionId: question.id,
        photos: [photo],
      );

      expect(result.ok, isFalse);
      // 两句话的处置完全相反：一个是「重拍/自己敲」，另一个是「你得写点什么」。
      // 说成「没作答」会让学生一直重拍一个已经拍好的东西。
      expect(result.message, contains('识别'));
      expect(result.message, isNot(contains('没有作答')));
    });

    test('照片为空时明确拒绝，且不产生任何作答', () async {
      final controller = await withQuestions('rm_cap_empty', ai: _CloudOcr());
      final question = controller.questionsOf('rm_cap_empty').first;

      final result = await controller.captureAnswers(
        questionId: question.id,
        photos: const [],
      );

      expect(result.ok, isFalse);
      expect(
        controller
            .questionsOf('rm_cap_empty')
            .firstWhere((q) => q.id == question.id)
            .studentAnswer,
        '',
      );
    });
  });

  group('拍照作答：照片要落盘', () {
    test('识别成功后照片被存下来（家长端要能看到孩子写了什么）', () async {
      final storage = LocalImageStorageService(useMemory: true);
      final controller = await withQuestions(
        'rm_cap_save',
        ai: _CloudOcr(),
        storage: storage,
      );
      final question = controller.questionsOf('rm_cap_save').first;

      await controller.captureAnswers(
        questionId: question.id,
        photos: [photo],
      );

      // 只传字节给模型、不存下来，会得到一条「有判定、没有证据」的记录，
      // 而这个缺口事后补不回来 —— 字节已经没了。
      final saved = await DatabaseService.instance.queryHomeworkImages(
        'stu_001',
      );
      expect(
        saved.where((img) => img.batchId == question.id).length,
        1,
        reason: '照片必须落到库里，挂在题目上以便家长端回看',
      );
    });

    test('存储报错时如实说出来，而不是当作「识别失败」', () async {
      final controller = await withQuestions(
        'rm_cap_storefail',
        ai: _CloudOcr(),
        storage: _BrokenStorage(),
      );
      final question = controller.questionsOf('rm_cap_storefail').first;

      final result = await controller.captureAnswers(
        questionId: question.id,
        photos: [photo],
      );

      expect(result.ok, isFalse);
      // 「存不进去」和「认不出」是两条完全不同的排查方向。
      // 混成一句会让运维去查模型，而真相是磁盘/配额。
      expect(result.message, contains('保存'));
    });
  });

  group('拍照作答：识别期间的状态', () {
    test('识别进行中时，提交不会说「你没作答」', () async {
      final gate = _GatedOcr();
      final controller = await withQuestions('rm_cap_busy', ai: gate);
      final question = controller.questionsOf('rm_cap_busy').first;

      // 不 await：让识别停在半路。
      final pending = controller.captureAnswers(
        questionId: question.id,
        photos: [photo],
      );
      await gate.started;

      expect(controller.capturingAnswer.value, isTrue);

      final submitted = await controller.submitAllPractice('rm_cap_busy');
      expect(submitted.ok, isFalse);
      // 这时作答文字确实是空的，但学生的照片已经拍了。
      // 报「还有 3 道没作答」会让他回头去改几道其实已经拍了的题。
      expect(
        submitted.message,
        contains('识别'),
        reason: '要指出是在识别，不能报成「没作答」',
      );

      gate.release();
      await pending;
      expect(controller.capturingAnswer.value, isFalse);
    });

    test('识别失败后状态必须复位，不能把按钮永久卡住', () async {
      final controller = await withQuestions('rm_cap_reset');
      final question = controller.questionsOf('rm_cap_reset').first;

      await controller.captureAnswers(
        questionId: question.id,
        photos: [photo],
      );

      // 没有 finally 的话，失败那一次会把 capturingAnswer 永久置 true，
      // 表现是「拍照按钮从此点不动」，而且没有任何报错。
      expect(controller.capturingAnswer.value, isFalse);
    });
  });

  group('AnswerRecognition 的口径', () {
    test('本地兜底的 confidence 是 0，且 isUsable 为假', () {
      const local = AnswerRecognition(
        text: '（当前无法识别手写，请直接输入你的答案）',
        confidence: 0,
        source: AiAnswerSource.local,
      );
      expect(local.isUsable, isFalse);
      expect(local.needsReview, isTrue);
    });

    test('云端低置信度仍然可用，但要提醒核对', () {
      const low = AnswerRecognition(
        text: '0.75',
        confidence: 0.5,
        source: AiAnswerSource.cloud,
      );
      // 0.5 的置信度是「认出了一些但没把握」。把它当作不可用会让
      // 学生每次都得自己重敲一遍，那就没必要做这个功能了。
      expect(low.isUsable, isTrue);
      expect(
        low.needsReview,
        isTrue,
        reason: '认错一个字就可能把对的判成错的，必须提醒学生核一眼',
      );
    });

    test('云端高置信度不需要额外提醒', () {
      const high = AnswerRecognition(
        text: '0.75',
        confidence: 0.95,
        source: AiAnswerSource.cloud,
      );
      expect(high.isUsable, isTrue);
      expect(high.needsReview, isFalse);
    });

    test('空文本即使来自云端也不算可用', () {
      const empty = AnswerRecognition(
        text: '   ',
        confidence: 0.9,
        source: AiAnswerSource.cloud,
      );
      expect(
        empty.isUsable,
        isFalse,
        reason: '空文本填进作答框等于什么都没发生，学生看不出来发生了什么',
      );
    });
  });
}

/// 假装是云端视觉模型：稳定回一个正确的作答。
class _CloudOcr implements AiDataSource {
  @override
  Future<List<MistakeTipDraft>> summarizeMistakeTips({
    required String subject,
    required List<MistakeTipSeed> items,
  }) async => const <MistakeTipDraft>[];

  // 打卡出题与本题判据无关；接口新增方法后必须实现。
  @override
  Future<List<CheckinQuestion>> generateCheckinQuestions({
    required String subject,
    required List<CheckinSeed> items,
    int count = 5,
  }) async => const <CheckinQuestion>[];

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
  Future<AnswerRecognition> recognizeAnswer({
    required List<String> imagePaths,
    String questionContent = '',
    String knowledgePoint = '',
  }) async => const AnswerRecognition(
    text: '0.75',
    confidence: 0.95,
    source: AiAnswerSource.cloud,
  );

  @override
  Future<AnswerJudgement> judgeAnswer({
    required String studentAnswer,
    required String referenceAnswer,
    String subject = '',
    String knowledgePoint = '',
    String questionContent = '',
  }) async => AnswerJudgement(
    verdict: studentAnswer.trim() == referenceAnswer.trim()
        ? AnswerVerdict.correct
        : AnswerVerdict.wrong,
    score: studentAnswer.trim() == referenceAnswer.trim() ? 100 : 0,
    comment: '来自假云端的判定',
    source: AiAnswerSource.cloud,
  );

  @override
  Future<HomeworkCheckOutcome> checkHomework({
    required String subject,
    required String title,
    List<String> imagePaths = const [],
  }) async => const HomeworkCheckOutcome(score: 0, summary: '', items: []);

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
  }) => const SimulatedAiDataSource().generatePractice(
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
  }) async => const SimulatedAiDataSource().referenceAnswerFor(
    subject: subject,
    knowledgePoint: knowledgePoint,
  );

  @override
  Future<Map<String, String>> referenceAnswersFor(
    List<ReferenceQuery> queries,
  ) => referenceAnswersByLoop(this, queries);
}

/// 可以卡在半路的识别 —— 用来观察「识别进行中」这一瞬间的状态。
class _GatedOcr extends _CloudOcr {
  final _started = Completer<void>();
  final _gate = Completer<void>();

  Future<void> get started => _started.future;

  void release() => _gate.complete();

  @override
  Future<AnswerRecognition> recognizeAnswer({
    required List<String> imagePaths,
    String questionContent = '',
    String knowledgePoint = '',
  }) async {
    _started.complete();
    await _gate.future;
    return super.recognizeAnswer(
      imagePaths: imagePaths,
      questionContent: questionContent,
      knowledgePoint: knowledgePoint,
    );
  }
}

/// 写不进去的存储 —— 复现 Web 端配额满 / 磁盘满。
class _BrokenStorage implements ImageStorageService {
  @override
  Future<HomeworkImageModel> saveHomeworkImage({
    required String studentId,
    required String fileName,
    required Uint8List bytes,
    String? homeworkId,
    String? mimeType,
    String ocrStatus = 'pending',
    String ocrText = '',
    String batchId = '',
    int sortOrder = 0,
  }) async => throw StateError('存储配额已满');

  @override
  Uint8List? readImage(String storageKey) => null;

  @override
  void deleteImage(String storageKey) {}
}
