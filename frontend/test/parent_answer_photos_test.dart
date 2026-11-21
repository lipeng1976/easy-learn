import 'dart:io';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/models/homework_image_model.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/parent/review_subject_page.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/widgets/homework_image_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';

/// 家长端能看到孩子的**作答照片**（B20）。
///
/// ── 这一条盯的是什么 ────────────────────────────────────────────────────
///
/// 举一反三里「拍照作答」的照片，写入时有两件刻意的设计：
///   ① `homeworkId` 为 **null**（它属于「这道题的这次作答」，不属于某次作业）；
///   ② `batchId` 存的是**题目 id**。
///
/// 而家长端原先每个取照片的方法都按 `homeworkId` 过滤 —— null 匹配不到任何作业，
/// 于是这条链路在界面上**完全不可达**：行写进了库、字节也在，家长就是看不到。
/// （B19 修的是「行没写」，B20 修的是「写了没人读」。两个缺陷叠在一起，
///   任何一个单独看都像是「功能已经做完了」。）
///
/// 所以这组用例要盯住三件事：
///   · 挂对了 —— 照片出现在**它那道题所属的错题**下；
///   · 不串门 —— 别的错题、别的批次、不存在的题目 id 都进不来；
///   · 界面上真的画出来了 —— 只测控制器等于默许「数据通了、界面没接」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  Directory? tempDir;
  late AuthController auth;

  setUp(() async {
    // `HomeworkImageReader` 是**静态单例**，缓存跨用例存活；其中「失败已固定
    // 30 秒」会让下一条用例看起来像功能坏了 —— 而那种失败表现为
    // 「单独跑能过、一起跑就挂」。约定见 `photo_visible_after_submit_test.dart`。
    // 界面那两条会真的渲染缩略图，所以按约定清干净。
    HomeworkImageReader.resetForTest();
    tempDir = await setUpTestDatabase();
    auth = Get.put(AuthController());
  });

  tearDown(() async {
    Get.reset();
    HomeworkImageReader.resetForTest();
    final dir = tempDir;
    if (dir != null) await tearDownTestDatabase(dir);
  });

  /// 以家长 `par_001` 的身份登录 —— 演示种子里他只与 `stu_001` 结伴。
  void signInParent() {
    auth.currentUser.value = UserModel(
      id: 'par_001',
      name: '家长',
      phone: '13900000000',
      role: 'parent',
      avatar: 'parent',
    );
  }

  /// 控制器用例走这里：普通 `test()` 跑在**真时钟**上，直说「读库」即可。
  /// 界面那两条不能这么写 —— 理由见 `openReviewTab`。
  Future<ParentController> buildParent({String studentId = 'stu_001'}) async {
    signInParent();
    final controller = ParentController();
    controller.selectedStudentId.value = studentId;
    await controller.loadData();
    return controller;
  }

  Future<void> seedMistake(
    String id, {
    String studentId = 'stu_001',
    String title = '38 + 47 = ?',
  }) async {
    await DatabaseService.instance.insertReviewMistake(
      ReviewMistake(
        id: id,
        subject: '数学',
        title: title,
        originalAnswer: '75',
        wrongReason: '忘了进位',
        createdAt: DateTime.now(),
        state: ReviewState.pending,
        studentId: studentId,
        knowledgePoint: '进位加法',
      ),
    );
  }

  /// 造一道变式题（挂在这道错题下），返回它的 id —— 也就是照片的 `batchId`。
  Future<String> seedQuestion({
    required String questionId,
    required String mistakeId,
    String studentId = 'stu_001',
  }) async {
    await DatabaseService.instance.replacePracticeQuestions(mistakeId, [
      AiPracticeQuestion(
        id: questionId,
        studentId: studentId,
        sourceMistakeId: mistakeId,
        knowledgePoint: '进位加法',
        subject: '数学',
        title: '变式题',
        content: '27 + 48 = ?',
        answer: '75',
        createdAt: DateTime.now(),
      ),
    ]);
    return questionId;
  }

  /// 写一行照片记录。`homeworkId` 传 null 才是「作答照片」的真实形态。
  Future<void> seedImage({
    required String id,
    required String batchId,
    String? homeworkId,
    String studentId = 'stu_001',
    int sortOrder = 0,
    int minuteOffset = 0,
  }) async {
    await DatabaseService.instance.saveHomeworkImage(
      HomeworkImageModel(
        id: id,
        studentId: studentId,
        homeworkId: homeworkId,
        storageKey: '20260925/$studentId/$id.jpg',
        fileName: '$id.jpg',
        fileSize: 1024,
        mimeType: 'image/jpeg',
        ocrStatus: 'pending',
        ocrText: '',
        createdAt: DateTime(2026, 9, 25, 10, minuteOffset),
        batchId: batchId,
        sortOrder: sortOrder,
      ),
    );
  }

  group('家长端作答照片的归属', () {
    test('挂在这道题上的照片，出现在它所属的错题下', () async {
      await seedMistake('m_photo_1');
      final q1 = await seedQuestion(questionId: 'pq_1', mistakeId: 'm_photo_1');
      await seedImage(id: 'img_a', batchId: q1);

      final parent = await buildParent();
      expect(
        parent.boundStudents.map((c) => c.id),
        contains('stu_001'),
        reason: '前置条件：演示种子里家长 par_001 已与 stu_001 结伴',
      );

      final photos = parent.answerPhotosOfMistake('m_photo_1');
      expect(photos.map((e) => e.id).toList(), ['img_a']);
    });

    test('别的错题的题目照片不会串过来', () async {
      await seedMistake('m_photo_1');
      await seedMistake('m_photo_2');
      final q1 = await seedQuestion(questionId: 'pq_1', mistakeId: 'm_photo_1');
      final q2 = await seedQuestion(questionId: 'pq_2', mistakeId: 'm_photo_2');
      await seedImage(id: 'img_a', batchId: q1);
      await seedImage(id: 'img_b', batchId: q2);

      final parent = await buildParent();

      expect(
        parent.answerPhotosOfMistake('m_photo_1').map((e) => e.id).toList(),
        ['img_a'],
        reason: 'm_photo_1 只该拿到挂 pq_1 的那张',
      );
      expect(
        parent.answerPhotosOfMistake('m_photo_2').map((e) => e.id).toList(),
        ['img_b'],
      );
    });

    test('batchId 指向不存在的题目 —— 不进任何错题', () async {
      await seedMistake('m_photo_1');
      await seedQuestion(questionId: 'pq_1', mistakeId: 'm_photo_1');
      // 题目 id 不在表里（例如题目被整组替换掉了）。
      // 这条盯的是「只要 batchId 非空就算作答证据」那种偷懒实现 ——
      // 那样写会让所有作业照片的批次号一起混进来。
      await seedImage(id: 'img_orphan', batchId: 'pq_gone');

      final parent = await buildParent();
      expect(parent.answerPhotosOfMistake('m_photo_1'), isEmpty);
    });

    test('作业照片（挂在某次作业上）不会被当成本题的作答照片', () async {
      await seedMistake('m_photo_1');
      final q1 = await seedQuestion(questionId: 'pq_1', mistakeId: 'm_photo_1');
      await seedImage(id: 'img_answer', batchId: q1);
      // 一次「提交作业」写下的照片：batchId 形如 batch_<微秒>，且挂 homeworkId。
      await seedImage(
        id: 'img_homework',
        batchId: 'batch_179031',
        homeworkId: 'hw_demo_1',
      );

      final parent = await buildParent();
      expect(
        parent.answerPhotosOfMistake('m_photo_1').map((e) => e.id).toList(),
        ['img_answer'],
        reason: '作业照片的 batchId 不是题目 id，不该混进作答证据',
      );
    });

    test('同一道题拍了多张 —— 按拍摄时间排，不按写入顺序', () async {
      await seedMistake('m_photo_1');
      final q1 = await seedQuestion(questionId: 'pq_1', mistakeId: 'm_photo_1');
      // 故意让「写入顺序」与「拍摄时间」相反：后写的反而更早拍的。
      await seedImage(id: 'img_late', batchId: q1, sortOrder: 0, minuteOffset: 5);
      await seedImage(id: 'img_early', batchId: q1, sortOrder: 1, minuteOffset: 0);

      final parent = await buildParent();
      expect(
        parent.answerPhotosOfMistake('m_photo_1').map((e) => e.id).toList(),
        ['img_early', 'img_late'],
      );
    });

    test('这道错题没有变式题 —— 返回空，不抛', () async {
      await seedMistake('m_no_question');
      await seedImage(id: 'img_x', batchId: 'pq_anything');

      final parent = await buildParent();
      expect(parent.answerPhotosOfMistake('m_no_question'), isEmpty);
    });
  });

  group('家长端界面（数据通了不等于界面接了）', () {
    /// 装载「某一科错题」页 —— 种数据与读库都在**真时钟**里跑完。
    ///
    /// 11-15 复习页重排后，错题卡不再平铺在复习页上：家长先看到学科色块，
    /// 点进去才是这一页。这组用例要验证的「照片真的画在它那道题下面」
    /// 没有变，所以直接装载学科详情页 —— 不是把断言删掉了事。
    ///
    /// ## 为什么不能写成 `Get.put(await buildParent())`
    ///
    /// `testWidgets` 的函数体跑在**假时钟**里，而 `loadData()` 是一长串真实
    /// SQLite 查询 —— 在假时钟里走不完。仓库里已有两条独立记录：
    ///   · `ai_observe_test.dart`：「直接 `await controller.load()` 会**挂死整个文件**」；
    ///   · `logout_entry_test.dart`：断言可能全过，收尾却冒出
    ///     「A Timer is still pending」+ 一条「数据库已关闭」的迟到异常。
    /// 所以这里做两件事：
    ///   ① 种数据 + `loadData()` 一起放进 `tester.runAsync`（那一段是真时钟）；
    ///   ② 注册一个**不自动加载**的子类 —— 否则 `Get.put` 的 `onInit`
    ///      会在假时钟里再触发一次 `loadData`，等于白规避一遍。
    Future<ParentController> openMistakeList(
      WidgetTester tester,
      Future<void> Function() seed,
    ) async {
      signInParent();
      final ParentController controller = _NoAutoLoadParentController();
      controller.selectedStudentId.value = 'stu_001';
      await tester.runAsync(() async {
        await seed();
        await controller.loadData();
      });

      Get.put(controller);
      expect(
        identical(Get.find<ParentController>(), controller),
        isTrue,
        reason: '页面必须用注入进来的这一份；若哪天变成覆盖注册，'
            '失败的会是这句，而不是某条看不出因果的超时',
      );

      // 视口仍然放大：详情页是 `ListView`（懒构建），多张错题卡里
      // 「有照片的那张」可能不在 800×600 的默认视口内 —— 那会让
      // 「找得到照片」假红、「找不到照片」假绿（卡片根本没进树）。
      // （措辞避开「默认 + 数字」：那会被 `quota-positions.mjs` 当成
      //  图片配额的默认值来比对，而这里说的是测试视口，与配额无关。）
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1000, 3200);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(home: ReviewSubjectPage(subject: '数学')),
      );
      await tester.pump();
      return controller;
    }

    testWidgets('错题卡片上真的画出了作答照片', (tester) async {
      await openMistakeList(tester, () async {
        await seedMistake('m_photo_1', title: '38 + 47 = ?');
        final q1 = await seedQuestion(questionId: 'pq_1', mistakeId: 'm_photo_1');
        await seedImage(id: 'img_a', batchId: q1);
        // 另一道错题：有变式题、但孩子没拍照片 —— 用来确认这一段只长在
        // 「有照片的那张」卡片上，而不是整页出现一次。
        await seedMistake('m_photo_2', title: '56 - 18 = ?');
        await seedQuestion(questionId: 'pq_2', mistakeId: 'm_photo_2');
      });

      expect(find.text('38 + 47 = ?'), findsOneWidget);
      expect(find.text('56 - 18 = ?'), findsOneWidget);
      expect(find.text('孩子的作答照片（1 张）'), findsOneWidget);
      expect(find.byType(HomeworkImageGrid), findsWidgets);
    });

    testWidgets('没有作答照片的错题不显示这一段（不拿占位骗人）', (tester) async {
      await openMistakeList(tester, () async {
        // 两道都建了变式题，但一张照片都没有。
        await seedMistake('m_photo_1', title: '38 + 47 = ?');
        await seedQuestion(questionId: 'pq_1', mistakeId: 'm_photo_1');
        await seedMistake('m_photo_2', title: '56 - 18 = ?');
        await seedQuestion(questionId: 'pq_2', mistakeId: 'm_photo_2');
      });

      // 关键前置：两张卡片都必须在树上。否则 `findsNothing` 是**空转的绿** ——
      // 卡片没被 build 时它也「找不到」，却什么都不能证明。
      expect(find.text('38 + 47 = ?'), findsOneWidget);
      expect(find.text('56 - 18 = ?'), findsOneWidget);
      expect(find.textContaining('孩子的作答照片'), findsNothing);
    });
  });
}

/// `onInit` 里那句 `loadData()` 是给真机用的。widget 测试跑在假时钟上，
/// 不能让它在 `Get.put` 时自动再跑一遍 —— 读库由测试自己在 `runAsync`
/// 的真时钟里显式调一次（见 `openReviewTab`）。
class _NoAutoLoadParentController extends ParentController {
  // ⚠️ 这里**刻意不调** `super.onInit()`。
  //
  // analyzer 报 `must_call_super` 是有道理的（漏调会丢掉生命周期），
  // 但在这个子类上不适用：`ParentController.onInit` 的全部作用就是
  // 「注册 `ever(selectedStudentId)` + 调一次 `loadData()`」，
  // 而 `loadData()` 正是要在假时钟里躲开的那一次（它读真 SQLite）。
  // 调用 super 就等于让本条用例重新踩回要躲的坑。
  //
  // 因此显式取消这条检查，而不是让警告留在 analyze 输出里 ——
  // 一旦允许「有一条已知警告」，下一条真警告就会被淹掉。
  //
  // ⚠️ 位置有讲究：`// ignore:` 只作用于**紧接的下一行**，而这条诊断报在
  // `void onInit() {` 这一行（不是 `@override` 那行）⇒ 注释必须夹在
  // `@override` 与它之间，放进 `@override` 上面是压不住的。
  @override
  // ignore: must_call_super
  void onInit() {
    // 刻意留空。
  }
}
