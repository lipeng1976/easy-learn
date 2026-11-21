import 'dart:io';
import 'dart:typed_data';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/review_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/homework_image_model.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/services/ai_data_source.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';
import 'helpers/fake_exporter.dart';

/// 错题录入闭环（P1）：**照片进来、题目入库、按年级学期归档**。
///
/// 这一组判据盯的是三类会静默出错的地方：
/// 1. 提取结果被当成事实 —— 本地兜底/低把握没有可见信号；
/// 2. 图片与题目分成两次写 —— 图在、行没了，或者反过来；
/// 3. 归档筛选默认值写错 —— 学生打开复习页看到的是上个学期的题。
///
/// 共同的失败形态都是「不报错」：库里有数据、界面也正常，
/// 只是内容不对。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  group('提取结果的可信度口径', () {
    test('本地兜底即使带了候选也不能当识别结果', () {
      // 本地实现现在回的是空候选，但即便将来它填了内容，`source` 才是
      // 「这份结果能不能当真」的判据。方向必须偏保守：把模板内容
      // 当成模型识别，学生会按一段编造的题干去核对。
      const extraction = MistakeExtraction(
        candidates: [ExtractedMistake(questionBody: 'x', confidence: 0.99)],
        source: AiAnswerSource.local,
      );
      expect(extraction.isUsable, isFalse);
      expect(extraction.needsReview, isTrue);
    });

    test('云端 + 有候选才算可用；空候选是「没识别到题目」，不是错误', () {
      const empty = MistakeExtraction(source: AiAnswerSource.cloud);
      expect(empty.isUsable, isFalse);
      // 但它的 needsReview 是 true —— 界面要提示「请手动填写」，
      // 而不是显示一片空白让人以为没拍到。
      expect(empty.needsReview, isTrue);

      const usable = MistakeExtraction(
        candidates: [ExtractedMistake(questionBody: '1+1=?', confidence: 0.9)],
        confidence: 0.9,
        source: AiAnswerSource.cloud,
      );
      expect(usable.isUsable, isTrue);
      expect(usable.needsReview, isFalse);
    });

    test('单条候选低于 0.6 才提示核对；缺 confidence 按 0 算', () {
      expect(
        const ExtractedMistake(questionBody: 'x', confidence: 0.59).needsReview,
        isTrue,
      );
      // 边界值本身不算「要核对」：阈值是「低于」，不是「不高于」。
      expect(
        const ExtractedMistake(questionBody: 'x', confidence: 0.6).needsReview,
        isFalse,
      );
      // 模型没给把握时给 0 而不是 1 —— 一个「没把握」被当成
      // 「很有把握」，学生就会跳过核对，而题干是要落库的。
      expect(const ExtractedMistake(questionBody: 'x').needsReview, isTrue);
    });
  });

  group('错题归档字段', () {
    test('年级/学期/来源/题干能完整往返', () {
      final at = DateTime(2026, 10, 19, 8, 30);
      final mistake = ReviewMistake(
        id: 'rm_1',
        subject: '数学',
        title: '一元一次方程 · 第 3 题',
        questionBody: r'解方程：$\frac{x-1}{2}=3$',
        answerKey: 'x=7',
        sourceType: MistakeSource.scan,
        grade: '初一',
        term: '上',
        imageCount: 2,
        originalAnswer: 'x=5',
        wrongReason: '移项没有变号',
        createdAt: at,
        state: ReviewState.pending,
        studentId: 'stu_001',
        knowledgePoint: '一元一次方程',
      );

      final restored = ReviewMistake.fromMap(mistake.toMap());
      expect(restored.questionBody, mistake.questionBody);
      expect(restored.answerKey, 'x=7');
      expect(restored.sourceType, MistakeSource.scan);
      expect(restored.grade, '初一');
      expect(restored.term, '上');
      expect(restored.imageCount, 2);
      // 标题与题干必须是两个字段：把它们合成一个，讲解就又会拿
      // 一句标签当题目讲。
      expect(restored.title, isNot(restored.questionBody));
    });

    test('老数据没有来源列时按 homeworkId 推断，不默认成作业批改', () {
      expect(
        mistakeSourceOf(null, homeworkId: 'hw_1'),
        MistakeSource.homework,
      );
      expect(mistakeSourceOf(null), MistakeSource.manual);
      // 有值就按值走：一条拍照录入的题不该因为带了作业 id 被改写。
      expect(
        mistakeSourceOf('scan', homeworkId: 'hw_1'),
        MistakeSource.scan,
      );
    });
  });

  group('本地库的真实行为', () {
    late Directory dir;
    late AuthController auth;

    setUp(() async {
      dir = await setUpTestDatabase();
      auth = Get.put(AuthController());
      auth.currentUser.value = UserModel(
        id: 'stu_001',
        name: '林小宇',
        phone: '13800000001',
        role: 'student',
        avatar: '👦',
        grade: '初一',
        term: '上',
      );
    });

    tearDown(() async {
      Get.reset();
      await tearDownTestDatabase(dir);
    });

    Future<ReviewController> buildController({
      ImageStorageService? imageStorage,
    }) async {
      final student = StudentController(
        aiCheckDelay: Duration.zero,
        imageStorage: imageStorage ?? LocalImageStorageService(useMemory: true),
      );
      await student.loadData();
      final controller = ReviewController(
        student: student,
        exporter: FakeExporter(),
        imageStorage: imageStorage ?? LocalImageStorageService(useMemory: true),
      );
      await controller.loadReviewData();
      return controller;
    }

    MistakeIntakePhoto photo(String name) => MistakeIntakePhoto(
      fileName: name,
      bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0x01, 0x02]),
      mimeType: 'image/jpeg',
    );

    test('写题 + 写图落同一个事务：两表都能查回，计数对得上', () async {
      final controller = await buildController();
      final result = await controller.addMistakeManually(
        subject: '数学',
        questionBody: r'计算：$\frac{1}{2}+\frac{1}{3}$',
        answerKey: r'$\frac{5}{6}$',
        sourceType: MistakeSource.scan,
        grade: '初一',
        term: '上',
        photos: [photo('a.jpg'), photo('b.jpg')],
      );

      expect(result.ok, isTrue, reason: result.message);

      final all = await DatabaseService.instance.queryReviewMistakes();
      final saved = all.firstWhere(
        (m) => m.questionBody.contains(r'\frac{1}{2}'),
      );
      expect(saved.sourceType, MistakeSource.scan);
      expect(saved.grade, '初一');
      expect(saved.term, '上');
      expect(saved.imageCount, 2);

      final images = await DatabaseService.instance.queryMistakeImages(saved.id);
      expect(images.length, 2, reason: '两张照片都要有对应的行');
      expect(images.map((i) => i.sortOrder).toList(), [0, 1]);
    });

    test('没填错因就留空，不要拿「拍照录入」顶上', () async {
      final controller = await buildController();
      await controller.addMistakeManually(
        subject: '数学',
        questionBody: '某商品原价 80 元，打八折后卖多少元？',
        originalAnswer: '70',
        photos: [photo('a.jpg')],
        sourceType: MistakeSource.scan,
      );

      final saved = (await DatabaseService.instance.queryReviewMistakes())
          .firstWhere((m) => m.questionBody.contains('打八折'));

      // 以前错因为空时会填 `sourceType.label`，于是**卷面上**印出
      // 「上次的错误原因：拍照录入」—— 一句废话，还占着一行位置。
      expect(
        saved.wrongReason,
        isEmpty,
        reason: '把来源当成错因写进卷面了',
      );
    });

    test('同一道题 5 分钟内录两次，只留一条（防重复提交）', () async {
      // 2026-10-21 实测事故：同一个编辑页被提交了 4 次，一条错题变成 4 条
      // （题干 md5 完全相同、引用同一张照片）。界面每次都提示「已保存」。
      final controller = await buildController();
      const body = '果园里有桃树和梨树共 180 棵，桃树的棵数是梨树的 3 倍，梨树有多少棵？';

      final first = await controller.addMistakeManually(
        subject: '数学',
        questionBody: body,
        originalAnswer: '45',
        wrongReason: '把倍数关系搞反了',
        sourceType: MistakeSource.manual,
      );
      final second = await controller.addMistakeManually(
        subject: '数学',
        questionBody: body,
        originalAnswer: '45',
        wrongReason: '把倍数关系搞反了',
        sourceType: MistakeSource.manual,
      );

      expect(first.ok, isTrue, reason: first.message);
      expect(
        second.ok,
        isTrue,
        reason: '重复提交要报成功 —— 报失败会让人以为没存上，然后再点一次',
      );
      expect(second.message, contains('已经加过'));

      final all = await DatabaseService.instance.queryReviewMistakes();
      expect(
        all.where((m) => m.questionBody == body).length,
        1,
        reason: '同一道题被存了两遍 —— 组卷时会印出两道一模一样的题',
      );
    });

    test('题干不同就是两道题，判重不能误拦', () async {
      final controller = await buildController();

      await controller.addMistakeManually(
        subject: '数学',
        questionBody: '甲数是乙数的 3 倍，两数和是 48，求乙数。',
        originalAnswer: '16',
        wrongReason: '设错了未知数',
      );
      await controller.addMistakeManually(
        subject: '数学',
        questionBody: '甲数是乙数的 5 倍，两数和是 36，求乙数。',
        originalAnswer: '6',
        wrongReason: '设错了未知数',
      );

      final all = await DatabaseService.instance.queryReviewMistakes();
      expect(
        all.where((m) => m.questionBody.contains('两数和是 48')).length,
        1,
      );
      expect(
        all.where((m) => m.questionBody.contains('两数和是 36')).length,
        1,
      );
    });

    test('5 分钟之前录的同一道题，允许再录一次（真的是又错了）', () async {
      final controller = await buildController();
      const body = '一个长方形周长 24 厘米，长比宽多 2 厘米，求面积。';

      // 直接造一条 10 分钟前的记录：窗口之外，不该被当成重复提交。
      await DatabaseService.instance.insertReviewMistake(
        ReviewMistake(
          id: 'rm_old_same_body',
          subject: '数学',
          title: '长方形面积',
          questionBody: body,
          originalAnswer: '32',
          wrongReason: '周长当面积',
          createdAt: DateTime.now().subtract(const Duration(minutes: 10)),
          state: ReviewState.pending,
          studentId: 'stu_001',
        ),
      );
      await controller.loadReviewData();

      final result = await controller.addMistakeManually(
        subject: '数学',
        questionBody: body,
        originalAnswer: '32',
        wrongReason: '周长当面积',
      );

      expect(result.ok, isTrue, reason: result.message);
      expect(
        result.message,
        isNot(contains('已经加过')),
        reason: '十天后再错一次是正常业务，不能被判重挡掉',
      );
      final all = await DatabaseService.instance.queryReviewMistakes();
      expect(all.where((m) => m.questionBody == body).length, 2);
    });

    test('照片上传失败时整条中止：库里 0 条题、0 张图', () async {
      // 这是「断网拍照录入」的等价场景：照片存不进去。
      // 允许它写行的话，学生会得到一条点开没有原图的错题 ——
      // 而他以为照片已经存好了。
      final controller = await buildController(
        imageStorage: _FailingStorage(),
      );

      final before = (await DatabaseService.instance.queryReviewMistakes()).length;
      final result = await controller.addMistakeManually(
        subject: '数学',
        questionBody: '断网时录的题',
        photos: [photo('a.jpg')],
      );

      expect(result.ok, isFalse);
      final after = await DatabaseService.instance.queryReviewMistakes();
      expect(after.length, before, reason: '上传失败不能留下半条记录');
      final withBody = after.where((m) => m.questionBody == '断网时录的题');
      expect(withBody, isEmpty);
    });

    test('已经上传过的照片键会被复用，不再重复上传', () async {
      // 识别过一次的照片已经在存储里。保存时再传一遍的代价是
      // 六张手机照片几十 MB 传两次 —— 学生看到的是保存按钮转很久。
      final storage = _CountingStorage();
      final controller = await buildController(imageStorage: storage);
      final bytes = photo('a.jpg').bytes;

      final stored = await storage.saveHomeworkImage(
        studentId: 'stu_001',
        fileName: 'a.jpg',
        bytes: bytes,
        mimeType: 'image/jpeg',
      );
      expect(storage.uploads, 1);

      final result = await controller.addMistakeManually(
        subject: '数学',
        questionBody: '复用已上传照片的题',
        photos: [photo('a.jpg')],
        preparedStorageKeys: [stored.storageKey],
      );

      expect(result.ok, isTrue, reason: result.message);
      expect(storage.uploads, 1, reason: '带回来的键不该触发第二次上传');
    });

    test('学期筛选：默认只显示当前学期 + 未归档', () async {
      final controller = await buildController();
      controller.mistakes.assignAll([
        _mistake('m_cur', grade: '初一', term: '上'),
        _mistake('m_old', grade: '六年级', term: '下'),
        _mistake('m_none'),
      ]);

      controller.ensureTermFilter();
      expect(controller.termFilterAll.value, isFalse);
      expect(
        controller.filterByTerm(controller.mistakes.toList()).map((m) => m.id),
        containsAll(<String>['m_cur', 'm_none']),
      );
      expect(
        controller.filterByTerm(controller.mistakes.toList()).map((m) => m.id),
        isNot(contains('m_old')),
      );

      // 「全部」把上个学期的题也放回来 —— 它是学生主动切过去的。
      controller.showAllTerms();
      expect(controller.filterByTerm(controller.mistakes.toList()).length, 3);

      // 再切回当前学期，不能停留在「全部」。
      controller.showCurrentTerm();
      expect(controller.filterByTerm(controller.mistakes.toList()).length, 2);
    });

    test('学期筛选：手工选几个学期就只显示那几个', () async {
      final controller = await buildController();
      controller.mistakes.assignAll([
        _mistake('m_a', grade: '初一', term: '上'),
        _mistake('m_b', grade: '初一', term: '下'),
        _mistake('m_c', grade: '六年级', term: '下'),
        _mistake('m_none'),
      ]);

      controller.selectTermKeys({'初一::下'});
      final shown = controller.filterByTerm(controller.mistakes.toList());
      expect(shown.map((m) => m.id), ['m_b']);
      // 未归档的题只在被显式选中时出现 —— 它不属于任何年级学期，
      // 默认混进结果会让「这次看的是初一上学期」变得不准。
      expect(controller.matchesTerm(_mistake('m_x')), isFalse);
    });

    test('termOptions 只列实际有数据的组合，并带数量', () async {
      final controller = await buildController();
      controller.mistakes.assignAll([
        _mistake('m_a', grade: '初一', term: '上'),
        _mistake('m_b', grade: '初一', term: '上'),
        _mistake('m_c', grade: '六年级', term: '下'),
        _mistake('m_d'),
      ]);

      final options = controller.termOptions;
      final byKey = {for (final option in options) option.key: option};
      expect(byKey['初一::上']?.count, 2);
      expect(byKey['六年级::下']?.count, 1);
      expect(byKey[ReviewController.unarchivedTermKey]?.count, 1);
      // 没有数据的组合不该出现：下拉里列一堆空选项，学生筛了才发现是空的。
      expect(byKey.containsKey('初三::上'), isFalse);
    });
  });
}

ReviewMistake _mistake(String id, {String grade = '', String term = ''}) {
  final at = DateTime(2026, 10, 19);
  return ReviewMistake(
    id: id,
    subject: '数学',
    title: id,
    originalAnswer: '',
    wrongReason: '',
    createdAt: at,
    state: ReviewState.pending,
    studentId: 'stu_001',
    grade: grade,
    term: term,
    knowledgePoint: '分数',
  );
}

/// 存不进去的存储：模拟断网 / 服务端拒收。
class _FailingStorage implements ImageStorageService {
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
  }) async => throw StateError('上传失败（测试替身）');

  @override
  Uint8List? readImage(String storageKey) => null;

  @override
  void deleteImage(String storageKey) {}
}

/// 数上传次数的存储：用来证明「识别过的照片不会被传第二遍」。
class _CountingStorage extends LocalImageStorageService {
  _CountingStorage() : super(useMemory: true);

  int uploads = 0;

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
  }) {
    uploads++;
    return super.saveHomeworkImage(
      studentId: studentId,
      fileName: fileName,
      bytes: bytes,
      homeworkId: homeworkId,
      mimeType: mimeType,
      ocrStatus: ocrStatus,
      ocrText: ocrText,
      batchId: batchId,
      sortOrder: sortOrder,
    );
  }
}
