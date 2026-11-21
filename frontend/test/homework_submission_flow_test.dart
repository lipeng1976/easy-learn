import 'dart:io';
import 'dart:typed_data';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/notification_controller.dart';
import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/models/homework_photo_draft.dart';
import 'package:easy_learn_app/models/point_model.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/services/ai_data_source.dart';
// 这里要直连**本地库**跑原生 SQL（造数据 / 断言存储层），
// 而上云门面 `DatabaseService` 不承诺「`.database` 就是当前数据源」——
// 云端模式下它是服务端。所以显式指名本地实现。
import 'package:easy_learn_app/services/local_database_service.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/services/simulated_ai_data_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';

/// 批改桩：记录**有没有真的去调批改**，并返回一个确定的结果。
///
/// 断言「没去调批改」比断言「结果字段是空的」硬得多 —— 后者在
/// 「调了模型、但把结果丢掉了」时同样会通过，而那是完全不同的一件事。
///
/// 结果固定成「一道错题」（而不是转发给模拟数据源）：模拟批改的错题数
/// 来自标题哈希，换个标题就从「待更正」变成「已完成」，导致依赖
/// 具体状态的用例时好时坏。固定一道错题保证了「提交后是待更正」。
/// （补交放开后，"已完成不再能提交"的前握已经不存在 ——
/// finished 也能再交；这条注释只说明为什么要固定结果。）
class _SpyAi extends SimulatedAiDataSource {
  int checkCalls = 0;

  @override
  Future<HomeworkCheckOutcome> checkHomework({
    required String subject,
    required String title,
    List<String> imagePaths = const [],
  }) async {
    checkCalls++;
    return const HomeworkCheckOutcome(
      score: 70,
      summary: '有一处需要更正',
      items: <HomeworkCheckItem>[
        HomeworkCheckItem(
          question: r'计算 $\frac{3}{4}+\frac{1}{2}$。',
          knowledgePoint: '分数计算',
          originalAnswer: '3/4',
          wrongReason: '分母处理错误',
          // 原卷面题号：模型现在会照抄卷面上的编号。
          questionNo: '20(4)',
          // 学生写出来的过程：讲解靠它指出「哪一步就错了」。
          studentProcess: r'$\frac{3}{4}=\frac{9}{12}$，'
              r'$\frac{1}{2}=\frac{6}{12}$，得 $\frac{15}{12}$',
          standardAnswer: r'$\frac{5}{4}$',
        ),
      ],
    );
  }
}

/// 批改结果可以中途换掉的桩。
///
/// 要验的正是「**第二次**批改读不出东西时，第一次批出来的错题不能被抹掉」，
/// 所以同一个控制器必须先拿到一份正常结果、再拿到一份不可读结果。
/// `_SpyAi` 的结果是常量，换不了 —— 而「换一个控制器」会把库一起重置，
/// 第一次的错题就没了，判据也就变成空转的。
class _SwitchableAi extends SimulatedAiDataSource {
  HomeworkCheckOutcome next = const HomeworkCheckOutcome(
    score: 70,
    summary: '有一处需要更正',
    items: <HomeworkCheckItem>[
      HomeworkCheckItem(
        question: r'计算 $\frac{3}{4}+\frac{1}{2}$。',
        knowledgePoint: '分数计算',
        originalAnswer: '3/4',
        wrongReason: '分母处理错误',
      ),
    ],
  );

  int checkCalls = 0;

  @override
  Future<HomeworkCheckOutcome> checkHomework({
    required String subject,
    required String title,
    List<String> imagePaths = const [],
  }) async {
    checkCalls++;
    return next;
  }
}

/// 作业链路：提交 → 批改 → 家长可见。
///
/// 这是一期最核心的闭环，也是改动最多的一段代码，因此断言写得比较细：
/// 不只看状态，还看「照片有没有绑对作业」「错题有没有挂到这份作业上」
/// 「家长拿到的照片能不能真的读出来」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  Directory? tempDir;
  late AuthController auth;
  late NotificationController notifications;

  setUp(() async {
    tempDir = await setUpTestDatabase();
    auth = Get.put(AuthController());
    notifications = Get.put(NotificationController());
  });

  tearDown(() async {
    Get.reset();
    final dir = tempDir;
    if (dir != null) await tearDownTestDatabase(dir);
  });

  void loginAs(
    String id,
    String role, {
    String name = '',
    String phone = '',
    String grade = '',
    String term = '',
  }) {
    auth.currentUser.value = UserModel(
      id: id,
      name: name.isEmpty ? id : name,
      phone: phone.isEmpty ? '13800000000' : phone,
      role: role,
      avatar: role == 'student' ? '👦' : 'parent',
      grade: grade,
      term: term,
    );
  }

  /// 学生控制器：批改延时归零 + 照片走内存存储，
  /// 否则每个用例都会白等 700ms、并且依赖平台文件系统。
  Future<StudentController> buildStudent({
    AiDataSource? ai,
    String grade = '',
    String term = '',
  }) async {
    loginAs(
      'stu_001',
      'student',
      name: '林小宇',
      phone: '13800000001',
      grade: grade,
      term: term,
    );
    final controller = StudentController(
      aiCheckDelay: Duration.zero,
      imageStorage: LocalImageStorageService(useMemory: true),
      ai: ai,
    );
    await controller.loadData();
    return controller;
  }

  HomeworkPhotoDraft photo(String fileName, [int size = 8]) =>
      HomeworkPhotoDraft(
        fileName: fileName,
        bytes: Uint8List.fromList(List<int>.filled(size, 7)),
      );

  group('作业提交流程', () {
    test('提交带照片：照片绑定作业与学生，批改结果自洽', () async {
      final student = await buildStudent();
      final expected = await const SimulatedAiDataSource().checkHomework(
        subject: '数学',
        title: '数学作业A',
      );

      expect(student.homeworkById('hw_001')!.hasSubmission, isFalse);

      final result = await student.submitHomework(
        homeworkId: 'hw_001',
        photos: [photo('math-1.jpg', 4), photo('math-2.jpg', 9)],
      );
      expect(result.ok, isTrue, reason: result.message);

      final after = student.homeworkById('hw_001')!;
      expect(after.submittedAt, isNotNull);
      expect(after.imageCount, 2);
      expect(after.submitBatchId, startsWith('batch_'));

      // 照片必须绑到这份作业和这个学生上，家长端才查得到。
      final images = student.imagesOfHomework('hw_001');
      expect(images.length, 2);
      expect(images.every((e) => e.studentId == 'stu_001'), isTrue);
      expect(images.every((e) => e.homeworkId == 'hw_001'), isTrue);
      expect(images.every((e) => e.batchId == after.submitBatchId), isTrue);
      expect(images.map((e) => e.sortOrder).toList(), [0, 1]);
      expect(after.imageUrl, images.first.storageKey);

      // 状态 ↔ 分数 ↔ 错题本条目必须互相对得上，这是「闭环」的关键。
      expect(after.score, expected.score);
      expect(after.wrongCount, expected.wrongCount);
      expect(after.summary, isNotEmpty);
      expect(
        after.status,
        expected.wrongCount == 0
            ? HomeworkStatus.finished
            : HomeworkStatus.needFix,
      );
      expect(
        student.mistakes.where((m) => m.homeworkId == 'hw_001').length,
        expected.wrongCount,
      );
    });

    test('批改出的题号跟着错题一起落库', () async {
      // 用固定返回一条错题的桩子：模拟数据源的错题数来自标题哈希，
      // 一旦它返回 0 条，这条断言就会静默跳过（第一版就栽在这里 ——
      // 删掉落库代码、测试仍然是绿的）。
      final ai = _SpyAi();
      final student = await buildStudent(ai: ai);

      final result = await student.submitHomework(homeworkId: 'hw_001');
      expect(result.ok, isTrue, reason: result.message);
      expect(ai.checkCalls, 1);

      final mistake = student.mistakes.firstWhere(
        (m) => m.homeworkId == 'hw_001',
        orElse: () => throw StateError('批改没有产出错题'),
      );
      // 家长拿着这条错题要能翻到作业本上的「第 20 题 (4)」。
      // 只存知识点的话，他只能从头翻。
      expect(
        mistake.questionNo,
        '20(4)',
        reason: '模型给的题号在落库这一段丢了',
      );
      expect(mistake.questionBody, isNotEmpty, reason: '题干也不该丢');
      // 过程与标准答案：讲解靠它们说清「错在哪一步」、告诉学生正确答案。
      expect(
        mistake.studentProcess,
        contains('15}{12'),
        reason: '学生写的过程没跟着落库 —— 讲解只能说「答案不对」',
      );
      expect(
        mistake.answerKey,
        contains('5}{4'),
        reason: '批改时给的标准答案没落库',
      );
    });

    test('没交的作业可以随时补交，提交后不再允许重复提交', () async {
      final student = await buildStudent();
      final before = student.homeworkById('hw_003')!;
      // hw_003 的 dueAt 是 2 小时前。**它现在仍然是「待完成」** ——
      // 系统不再拿 dueAt 判断任何事（那天之后「已超时」这个概念就没了，
      // 见 `doc/open-items.md` B26）。这条断言同时是那个决定的判据。
      expect(before.status, HomeworkStatus.pending);
      expect(before.canSubmit, isTrue, reason: '还没交的作业随时能交，不是「封盘」');

      // 不带照片也能提交：提交不强制拍照（界面会提示，但不拦）。
      // hw_003 是那条「要批改，但这台环境没开 AI」的演示数据。
      final first = await student.submitHomework(homeworkId: 'hw_003');
      expect(first.ok, isTrue, reason: first.message);

      final after = student.homeworkById('hw_003')!;
      expect(after.status, HomeworkStatus.finished);
      expect(after.submittedAt, isNotNull);
      expect(after.wrongCount, 0);
      // hw_003 是「未开启 AI 批改」的作业：提交后直接完成，
      // **不产生批改结果**。旧实现在这里往 summary 里写一句
      //「该作业未开启 AI 批改」，于是 `hasResult` 变成真 ——
      // 家长端就会出现一个标题写着「AI 批改结果」、内容却是
      //「没有批改」的区块。现在「为什么没批」由 gradingMode 现推。
      expect(after.gradingMode, HomeworkGradingMode.unavailable);
      expect(after.hasResult, isFalse);
      expect(after.summary, isEmpty);

      // 回归保护：提交后超时扫描不能把刚写好的状态打回 timeout。
      await student.loadData();
      expect(student.homeworkById('hw_003')!.status, HomeworkStatus.finished);

      final second = await student.submitHomework(homeworkId: 'hw_003');
      // 2026-10-06 补交放开：已完成的作业可以追加漏交的附件。
      // 旧断言在这里拦（"已完成，无需重复提交"），拦的正是这次要开的门。
      expect(second.ok, isTrue, reason: second.message);
    });

    test('不能提交别的学生的作业', () async {
      final student = await buildStudent();

      final result = await student.submitHomework(
        homeworkId: 'hw_101',
        photos: [photo('other.jpg')],
      );
      expect(result.ok, isFalse);
      expect(student.homeworkById('hw_101'), isNull);
      expect(student.imagesOfHomework('hw_101'), isEmpty);
    });

    test('重复提交不会在错题本堆重复条目', () async {
      final student = await buildStudent();
      final expected = await const SimulatedAiDataSource().checkHomework(
        subject: '语文',
        title: '语文阅读理解',
      );

      await student.submitHomework(
        homeworkId: 'hw_002',
        photos: [photo('first.jpg')],
      );
      await student.submitHomework(
        homeworkId: 'hw_002',
        photos: [photo('second.jpg')],
      );

      // 无论批改结果有没有错题，挂在这份作业上的错题数都不该翻倍。
      expect(
        student.mistakes.where((m) => m.homeworkId == 'hw_002').length,
        expected.wrongCount,
      );
      // 第一次提交的照片必须留着，家长要能对比改正前后。
      expect(student.imagesOfHomework('hw_002'), isNotEmpty);
    });

    test('已完成的作业可以补充提交：重新批改，旧结果被新结果覆盖', () async {
      final ai = _SwitchableAi();
      final student = await buildStudent(ai: ai);
      const hw = 'hw_001';

      // 第一次批改「全对」→ finished（有结果的终态，canSupplement 的前提）。
      ai.next = const HomeworkCheckOutcome(
        score: 100,
        summary: '全部正确',
        items: <HomeworkCheckItem>[],
      );
      final first = await student.submitHomework(
        homeworkId: hw,
        photos: [photo('p1.jpg', 4)],
      );
      expect(first.ok, isTrue, reason: first.message);

      final afterFirst = student.homeworkById(hw)!;
      expect(afterFirst.status, HomeworkStatus.finished);
      // 这两条**必须一起断**：防的是有人图省事把 canSubmit 直接放行
      // finished —— 那样「待办列表」（submittableHomework）会把已完成的
      // 作业也列进去，而补交的入口只在作业卡片上。
      expect(afterFirst.canSubmit, isFalse);
      expect(afterFirst.canSupplement, isTrue);

      // 补交：这次批出 1 道错题 → 状态、分数、错题全部被新结果覆盖。
      ai.next = const HomeworkCheckOutcome(
        score: 70,
        summary: '有一处需要更正',
        items: <HomeworkCheckItem>[
          HomeworkCheckItem(
            question: r'计算 $\frac{3}{4}+\frac{1}{2}$。',
            knowledgePoint: '分数计算',
            originalAnswer: '3/4',
            wrongReason: '分母处理错误',
          ),
        ],
      );
      final second = await student.submitHomework(
        homeworkId: hw,
        photos: [photo('p2.jpg', 4)],
      );
      expect(second.ok, isTrue, reason: second.message);

      final after = student.homeworkById(hw)!;
      expect(after.status, HomeworkStatus.needFix);
      expect(after.score, 70);
      expect(ai.checkCalls, 2, reason: '补交要真的重新批改，不能只换附件');
      expect(
        after.submitBatchId,
        isNot(equals(afterFirst.submitBatchId)),
        reason: '补交是一次新提交（积分与家长通知都按新 batch 记）',
      );
      // 两次的照片都在 —— 补交是追加，不是替换。
      expect(student.imagesOfHomework(hw).length, 2);
      expect(
        student.mistakes.where((m) => m.homeworkId == hw).length,
        1,
        reason: '旧结果被替换，新错题恰好 1 条，不堆重复',
      );
    });
  });

  group('家长端可见性（真实 SQLite）', () {
    test('学生提交后家长能看到提交时间、照片与批改结果，并收到定向通知', () async {
      final student = await buildStudent();
      final submit = await student.submitHomework(
        homeworkId: 'hw_001',
        photos: [photo('p1.jpg', 4), photo('p2.jpg', 8), photo('p3.jpg', 16)],
      );
      expect(submit.ok, isTrue, reason: submit.message);

      // 换家长登录，重新加载。
      loginAs('par_001', 'parent', name: '林爸爸', phone: '13800000002');
      final parent = ParentController();
      await parent.loadData();

      final visible = parent.homeworkById('hw_001');
      expect(visible, isNotNull, reason: '结伴孩子的作业必须可见');
      expect(visible!.hasSubmission, isTrue);
      expect(visible.imageCount, 3);
      expect(visible.submittedAt, isNotNull);
      expect(visible.score, isNotNull);
      expect(visible.summary, isNotEmpty);

      // 照片不只是「有记录」，详情页要能真的把字节读出来渲染。
      final parentImages = parent.imagesOfHomework('hw_001');
      expect(parentImages.length, 3);
      expect(parent.photoCountOfHomework('hw_001'), 3);
      final reader = LocalImageStorageService(useMemory: true);
      for (final image in parentImages) {
        expect(reader.readImage(image.storageKey), isNotNull);
      }

      // 首页「最近提交」按提交时间倒序，刚提交的应该排第一。
      expect(parent.submittedHomeworks.first.id, 'hw_001');

      // 通知必须投给家长，而不是广播给学生。
      await notifications.loadNotifications();
      final notices = notifications.notifications
          .where((n) => n.relatedBizId == 'hw_001')
          .toList();
      expect(notices, isNotEmpty);
      expect(notices.every((n) => n.targetUserId == 'par_001'), isTrue);
      // 提交时一条、批改完成后一条，两条都要能到家长手里。
      expect(
        notices.any((n) => n.title.contains('提交')),
        isTrue,
        reason: '家长要能收到「孩子交作业了」',
      );
      expect(
        notices.any((n) => n.title.contains('完成') || n.title.contains('更正')),
        isTrue,
        reason: '家长要能收到批改结果',
      );
    });

    test('学生自己看不到「发给家长」的提交通知', () async {
      final student = await buildStudent();
      await student.submitHomework(
        homeworkId: 'hw_001',
        photos: [photo('p1.jpg')],
      );

      await notifications.loadNotifications();
      final leaked = notifications.notifications.where(
        (n) => n.body.contains('已提交') && n.targetUserId == 'par_001',
      );
      expect(leaked, isEmpty, reason: '家长的通知不该出现在学生的消息中心');
    });

    test('家长只能看到已结伴孩子的作业与照片', () async {
      final student = await buildStudent();
      await student.submitHomework(
        homeworkId: 'hw_001',
        photos: [photo('p1.jpg')],
      );

      loginAs('par_001', 'parent', name: '林爸爸', phone: '13800000002');
      final parent = ParentController();
      await parent.loadData();

      // par_001 只和 stu_001 结伴。
      expect(parent.boundStudents.map((c) => c.id), ['stu_001']);
      expect(parent.homeworkById('hw_001'), isNotNull);

      // hw_101 / hw_102 属于 stu_002，不该出现在这位家长的列表里，
      // 更不该把照片一起带出来。
      expect(parent.homeworkById('hw_101'), isNull);
      expect(parent.homeworkById('hw_102'), isNull);
      expect(parent.imagesOfHomework('hw_102'), isEmpty);
    });
  });

  group('无需批改的作业（朗读、背诵、默写、抄写这类）', () {
    test('照老师原话录一条「默写单词」，默认就是不批 —— 学生不必自己关', () async {
      final spy = _SpyAi();
      final student = await buildStudent(ai: spy);

      // 走**真实录入路径**（界面调的就是 addHomeworks），并且**不显式带**
      // needsGrading —— 看系统自己怎么判。这条盯的是「默认值」，不是
      // 「开关能不能用」：默写、字帖这类如果默认还是「要批改」，
      // 学生每次都得自己关一次，那这个需求就等于没做。
      await student.addHomeworks([
        {
          'subject': '英语',
          'title': '默写英语单词Unit3',
          'dueAt': DateTime.now(),
          'estimatedMinutes': 15,
        },
      ]);
      final created = student.homeworkList.firstWhere(
        (e) => e.title == '默写英语单词Unit3',
      );
      expect(created.needsGrading, isFalse);
      expect(created.gradingMode, HomeworkGradingMode.notRequired);

      final result = await student.submitHomework(
        homeworkId: created.id,
        photos: [photo('dictation-1.jpg')],
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(spy.checkCalls, 0, reason: '默认不批，就不该去调批改');

      final after = student.homeworkById(created.id)!;
      expect(after.status, HomeworkStatus.finished);
      expect(after.hasResult, isFalse);
      // 照片必须留着：对这类作业来说它就是「我做过了」的凭证，
      // 也正是用户说的「直接上传图片就行」。
      expect(after.imageCount, 1);
    });

    test('提交后直接完成：压根不去调批改，也没有分数与错题', () async {
      final spy = _SpyAi();
      final student = await buildStudent(ai: spy);
      expect(student.homeworkById('hw_001')!.needsGrading, isTrue);

      final result = await student.submitHomework(
        homeworkId: 'hw_001',
        photos: [photo('read-1.jpg')],
        needsGrading: false,
      );
      expect(result.ok, isTrue, reason: result.message);

      expect(spy.checkCalls, 0, reason: '不需要批改就不该去调批改');
      final after = student.homeworkById('hw_001')!;
      expect(after.needsGrading, isFalse);
      expect(after.status, HomeworkStatus.finished);
      // 不批改的作业不该有「批改结果」—— 没有 checkedAt、没有分数、
      // 没有总结，`hasResult` 才会是 false，家长端也就不会出现一个
      // 标题写着「AI 批改结果」、内容却是「本次未批改」的区块。
      expect(after.hasResult, isFalse);
      expect(after.checkedAt, isNull);
      expect(after.score, isNull);
      expect(after.summary, isEmpty);
      expect(after.wrongCount, 0);
      expect(student.mistakes.where((m) => m.homeworkId == 'hw_001'), isEmpty);

      // 但「交过了」这件事必须成立，照片也得留着 —— 家长那边是靠它
      // 判断孩子到底交没交的。
      expect(after.submittedAt, isNotNull);
      expect(after.imageCount, 1);
      expect(student.imagesOfHomework('hw_001').length, 1);
    });

    test('提交时改的口径要落库，否则下次进来又变回「需要批改」', () async {
      final student = await buildStudent();
      await student.submitHomework(homeworkId: 'hw_001', needsGrading: false);

      // 直接查库，绕过内存态：只测 controller 的话，
      // 「有没有写进去」和「内存里碰巧是对的」分不开。
      final db = await LocalDatabaseService.instance.database;
      final rows = await db.query(
        'homework',
        where: 'id = ?',
        whereArgs: ['hw_001'],
      );
      expect(rows.single['needsGrading'], 0);
      expect(rows.single['status'], 'finished');
    });

    test('要批改的作业照旧走批改（回归）', () async {
      final spy = _SpyAi();
      final student = await buildStudent(ai: spy);

      final result = await student.submitHomework(
        homeworkId: 'hw_001',
        photos: [photo('a.jpg')],
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(spy.checkCalls, 1);

      final after = student.homeworkById('hw_001')!;
      expect(after.needsGrading, isTrue);
      expect(after.hasResult, isTrue);
      expect(after.score, 70);
      expect(after.status, HomeworkStatus.needFix);
    });

    test('从「要批改」改成「不批改」重交：上一次的分数必须清掉，错题保留', () async {
      final spy = _SpyAi();
      final student = await buildStudent(ai: spy);

      // 第一次：正常批改，出一道错题 → 待更正，于是还能再交一次。
      await student.submitHomework(
        homeworkId: 'hw_001',
        photos: [photo('a.jpg')],
      );
      final graded = student.homeworkById('hw_001')!;
      expect(graded.status, HomeworkStatus.needFix);
      expect(graded.score, 70);
      expect(student.mistakes.where((m) => m.homeworkId == 'hw_001').length, 1);

      // 订正后重交，这次学生选了「不需要批改」。
      final again = await student.submitHomework(
        homeworkId: 'hw_001',
        photos: [photo('b.jpg')],
        needsGrading: false,
      );
      expect(again.ok, isTrue, reason: again.message);

      final after = student.homeworkById('hw_001')!;
      expect(after.status, HomeworkStatus.finished);
      expect(spy.checkCalls, 1, reason: '重交时没有再去调批改');
      // 上一次的分数不能还挂着：一份「已完成、无需批改」的作业顶着
      // 一个旧分数，看上去就像这次的结果。
      expect(after.hasResult, isFalse);
      expect(after.score, isNull);
      expect(after.summary, isEmpty);

      // 但上一次批出来的错题**留着**。这是刻意的取舍：
      // 错题是学生的复习资产（有独立的复习进度），而「这次不批改」
      // 这个动作不该有「顺手删掉历史错题」的副作用 ——
      // 那会给学生一条「关掉开关就能把错题从本子里抹掉」的捷径。
      expect(student.mistakes.where((m) => m.homeworkId == 'hw_001').length, 1);
    });

    test('不用批改的作业，家长收到的通知不说「正在批改」', () async {
      final student = await buildStudent();
      await student.submitHomework(homeworkId: 'hw_001', needsGrading: false);

      // 换家长登录再看：通知是按收件人过滤的，
      // 学生这边本来就看不到发给家长的那条（下一条用例钉的就是这件事）。
      loginAs('par_001', 'parent', name: '林爸爸', phone: '13800000002');
      await notifications.loadNotifications();
      final toParent = notifications.notifications.where(
        (n) => n.relatedBizId == 'hw_001' && n.title.contains('提交'),
      );
      expect(toParent, isNotEmpty, reason: '提交了还是得告诉家长');
      expect(
        toParent.every((n) => n.body.contains('不需要批改')),
        isTrue,
        reason: '报「正在批改」会让家长去等一个不会来的结果',
      );
    });
  });

  /// 批改结果「自己站不住」时的处置（`doc/open-items.md` B29 的独立缺陷）。
  ///
  /// 这一段守的是**代价最大的一条**：`items` 空 + `score` 100 正是
  /// 「一次批改把错题库清空」的**正常路径**，而现网视觉档对纯白页面
  /// 6 次里有 3 次就是这个返回值 ⇒ 拍一张空白的照片，能清空错题库、
  /// 把作业置成「已完成」、还白拿一次「全对」加分。
  group('批改结果站不住时', () {
    test('照片不可读：不清错题、不置完成、不发「全对」加分', () async {
      final ai = _SwitchableAi();
      final student = await buildStudent(ai: ai);
      const hw = 'hw_001';
      int mine() => student.mistakes.where((m) => m.homeworkId == hw).length;
      final db = await LocalDatabaseService.instance.database;
      Future<List<Map<String, Object?>>> awards() => db.query(
        'point_ledger',
        where: 'studentId = ? and action = ? and refId = ?',
        whereArgs: ['stu_001', PointAction.homeworkAllCorrect.code, hw],
      );

      // 前置：这份作业本来没有错题。不先钉住这一条，下面「错题还在」
      // 就可能是在数种子数据，判据变成空转的绿。
      expect(mine(), 0);

      // 第一次：正常批改，出一道错题。
      await student.submitHomework(homeworkId: hw, photos: [photo('normal.jpg')]);
      expect(mine(), 1);
      expect(student.homeworkById(hw)!.status, HomeworkStatus.needFix);
      expect(await awards(), isEmpty, reason: '有错题本来就不该发「全对」加分');

      // 第二次：换了一张空白照片。现网视觉档 6 次里 3 次会回
      // `score:100 / items:[]`，summary 里写着「照片是空白的……无法批改」。
      ai.next = const HomeworkCheckOutcome(
        score: 100,
        summary: '照片是空白的，没有可批改的内容，无法批改。',
        items: <HomeworkCheckItem>[],
      );
      final again = await student.submitHomework(
        homeworkId: hw,
        photos: [photo('blank.jpg')],
      );
      final after = student.homeworkById(hw)!;

      // ① 提交本身是成功的：照片传上去了、家长也收到了「已提交」这个事实。
      //    报 fail 会让提交面板留在原地，学生以为没交上、再点一次 ——
      //    第二点会把同一批照片重复入库。
      expect(again.ok, isTrue, reason: again.message);
      expect(again.message, contains('重拍'));
      // ② 状态回「待完成」。留在「批改中」是更糟的选择 —— 那是干等一个不会来的结果。
      expect(after.status, HomeworkStatus.pending);
      expect(after.hasResult, isFalse, reason: '不能把「得分 100」写进这份作业');
      // ③ 第一次批出来的错题必须还在 —— 这就是「不能清空错题库」的判据本身。
      expect(mine(), 1);
      expect(after.wrongCount, 1, reason: '内存里的错题数要与错题本一致');
      // ④ 拍张空照片不能拿分。
      expect(await awards(), isEmpty, reason: '照片读不出来却发「全对」加分');

      // 直接查库，绕过内存态：只测控制器的话，「有没有写进去」与
      // 「内存里碰巧是对的」分不开。
      final rows = await db.query('homework', where: 'id = ?', whereArgs: [hw]);
      expect(rows.single['status'], 'pending');
      expect(rows.single['wrongCount'], 1);
    });

    test('错因里已经反悔的条目不入错题库，同批的其它错题照常入', () async {
      final ai = _SwitchableAi();
      final student = await buildStudent(ai: ai);
      const hw = 'hw_001';

      // 一批两条：**一条模型自己反悔了、一条没有**。
      // 这样这个用例自带正反面 —— 只放一条反悔的，就分不清
      // 「过滤生效」和「压根什么都没插」。
      ai.next = const HomeworkCheckOutcome(
        score: 70,
        summary: '共发现 2 处需要更正。',
        items: <HomeworkCheckItem>[
          HomeworkCheckItem(
            question: r'计算 $-\frac{7}{4}+\frac{1}{2}$。',
            knowledgePoint: '符号',
            originalAnswer: '-29/4',
            wrongReason: '符号处理错误。（复核：学生算的是对的，此条为误判，请以「无错题」处理）',
          ),
          HomeworkCheckItem(
            question: r'计算 $\frac{3}{4}+\frac{1}{2}$。',
            knowledgePoint: '分数计算',
            originalAnswer: '3/4',
            wrongReason: '通分时分母没有统一',
          ),
        ],
      );
      final result = await student.submitHomework(
        homeworkId: hw,
        photos: [photo('x.jpg')],
      );

      final kept = student.mistakes.where((m) => m.homeworkId == hw).toList();
      expect(kept.length, 1, reason: '反悔那条要丢掉、另一条要留下');
      expect(kept.single.knowledgePoint, '分数计算');
      // 题干要跟着**留下来的那条**走，不是随便取一条、也不是一段标签。
      // 两条题的题干刻意不同：一条是符号题、一条是分数题，取错了立刻能看见。
      expect(kept.single.questionBody, r'计算 $\frac{3}{4}+\frac{1}{2}$。');
      expect(
        kept.single.questionBody,
        isNot(contains('符号')),
        reason: '被收回的那条题的题干不能串过来',
      );
      // 还有条目留下 ⇒ **不能**把分数归一成 100（归一那条只在「全被过滤掉」时生效）。
      expect(student.homeworkById(hw)!.score, 70);
      // 丢掉过东西就要说出来，否则「说加了 2 道、本子里只多 1 道」再也说不清。
      expect(result.message, contains('收回'));
    });
  });

  /// 批改是**唯一**同时看到「题目 + 作答」的时机，题干必须在这里抄下来。
  ///
  /// 这一条守的是整条复习闭环的上游：错题没有题干，讲解就只能对着
  /// 「作业标题 · 知识点」讲，重做与变式题更无从谈起。
  group('批改产出的错题', () {
    test('题干、来源、年级学期一起入库，标签与题干分开存', () async {
      final ai = _SwitchableAi();
      final student = await buildStudent(ai: ai, grade: '初一', term: '上');
      await student.submitHomework(
        homeworkId: 'hw_001',
        photos: [photo('a.jpg')],
      );

      final mistake = student.mistakes
          .where((m) => m.homeworkId == 'hw_001')
          .single;
      expect(mistake.questionBody, r'计算 $\frac{3}{4}+\frac{1}{2}$。');
      expect(mistake.sourceType, MistakeSource.homework);
      expect(mistake.grade, '初一');
      expect(mistake.term, '上');
      // 展示标签仍然要留着（列表一行装不下整道题），但不能拿它冒充题干。
      expect(mistake.title, contains('分数计算'));
      expect(mistake.title, isNot(mistake.questionBody));

      // ⚠️ 上面读的是内存列表（`insertAll` 之后的对象）。**内存里有不等于落库了** ——
      // 少一列、字段名对不上，界面上都看不出来，重开 App 才会发现题干全没了。
      // 所以再从库里读一遍。
      final db = await LocalDatabaseService.instance.database;
      final rows = await db.query(
        'review_mistake',
        where: 'homeworkId = ?',
        whereArgs: ['hw_001'],
      );
      expect(rows.length, 1);
      expect(rows.single['questionBody'], r'计算 $\frac{3}{4}+\frac{1}{2}$。');
      expect(rows.single['sourceType'], 'homework');
      expect(rows.single['grade'], '初一');
      expect(rows.single['term'], '上');
    });
  });
}
