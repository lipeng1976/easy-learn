import 'dart:io';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/notification_controller.dart';
import 'package:easy_learn_app/controllers/point_controller.dart';
import 'package:easy_learn_app/controllers/review_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/point_model.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/models/study_plan_model.dart';
import 'package:easy_learn_app/models/study_plan_checkin_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/models/workout_model.dart';
import 'package:easy_learn_app/services/ai_data_source.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/services/simulated_ai_data_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';
import 'helpers/fake_exporter.dart';

/// 可配置的批改桩：想让它报几道错题就报几道。
///
/// 用桩而不是真实的模拟数据源，是因为模拟结果的错题数来自标题哈希 ——
/// 改个标题就从「全对」变成「有待更正」，而这两条路的分值不一样，
/// 用例会莫名其妙地时好时坏。
class _StubAi extends SimulatedAiDataSource {
  _StubAi({this.wrongItems = 0});

  final int wrongItems;

  @override
  Future<HomeworkCheckOutcome> checkHomework({
    required String subject,
    required String title,
    List<String> imagePaths = const [],
  }) async {
    return HomeworkCheckOutcome(
      score: wrongItems == 0 ? 100 : 70,
      summary: wrongItems == 0 ? '全部正确' : '有一处需要更正',
      items: List<HomeworkCheckItem>.generate(
        wrongItems,
        (index) => HomeworkCheckItem(
          question: '第 ${index + 1} 题：计算 \$\\frac{1}{2}+\\frac{1}{3}\$。',
          knowledgePoint: '知识点$index',
          originalAnswer: '3/4',
          wrongReason: '算错了',
        ),
      ),
    );
  }
}

/// 动作挂牌：每个能赚分的动作都要真的记上一笔，且**只记一笔**。
///
/// 这一层测的是「控制器有没有把账交给积分」以及防重键定得对不对。
/// 键定错的典型症状是安静地吞分：第二天打卡不给分、或者反复提交同一份
/// 作业能刷分 —— 两者都不会报错，只能靠这里的断言抓。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  Directory? tempDir;
  late AuthController auth;


  setUp(() async {
    tempDir = await setUpTestDatabase();
    auth = Get.put(AuthController());
    Get.put(NotificationController());
  });

  tearDown(() async {
    Get.reset();
    final dir = tempDir;
    if (dir != null) await tearDownTestDatabase(dir);
  });

  void loginAsStudent() {
    auth.currentUser.value = UserModel(
      id: 'stu_001',
      name: '林小宇',
      phone: '13800000001',
      role: 'student',
      avatar: '',
    );
  }

  StudentController buildStudent({int wrongItems = 0}) => StudentController(
    aiCheckDelay: Duration.zero,
    imageStorage: LocalImageStorageService(),
    ai: _StubAi(wrongItems: wrongItems),
  );

  Future<int> balanceOf(String studentId) async {
    // 必须用 `PointController.to`：控制器只有这一个实例，裸建一个
    // 会拿到一份空的规则缓存，看到的分值全是默认值。
    final points = PointController.to;
    await points.loadFor(studentId, force: true);
    return points.account.value.balance;
  }

  group('交作业', () {
    test('需批改的作业：提交记一笔，全对再记一笔', () async {
      loginAsStudent();
      final student = buildStudent(wrongItems: 0);
      await student.loadData();

      final result = await student.submitHomework(homeworkId: 'hw_001');
      expect(result.ok, isTrue);

      // 提交 5 + 全对 5
      expect(await balanceOf('stu_001'), 10);
    });

    test('有错题时只记提交分，不给全对分', () async {
      loginAsStudent();
      final student = buildStudent(wrongItems: 2);
      await student.loadData();

      await student.submitHomework(homeworkId: 'hw_001');
      expect(await balanceOf('stu_001'), 5);
    });

    test('免批改的作业按「无需批改」的分值算', () async {
      loginAsStudent();
      final student = buildStudent();
      await student.loadData();

      // 在提交这一刻把口径改成「不必批改」—— 面板上就是这个动作
      final result = await student.submitHomework(
        homeworkId: 'hw_001',
        needsGrading: false,
      );
      expect(result.ok, isTrue);
      // 3 分，而不是需批改的 5 分
      expect(await balanceOf('stu_001'), 3);
    });

    test('已完成的作业补交：按一次新提交重新记分（防重键是 batchId）', () async {
      loginAsStudent();
      final student = buildStudent(wrongItems: 0);
      await student.loadData();

      await student.submitHomework(homeworkId: 'hw_001');
      // 2026-10-06 补交放开（HomeworkItem.canSupplement）：finished 可以再交。
      // 旧断言在这里拦（「已完成，无需重复提交」），拦的正是这次要开的门。
      // 补交与「家长打回后重交」同口径：一次新提交按新 batchId 再记 ——
      // 防重防的是**同一个 batch**写两遍（连点、重放），不是「再交一次」。
      final again = await student.submitHomework(homeworkId: 'hw_001');
      expect(again.ok, isTrue, reason: again.message);

      // 第一次：提交 5 + 全对 5；补交再来一遍 ⇒ 20。
      expect(await balanceOf('stu_001'), 20);
    });
  });

  group('计划打卡', () {
    test('打卡 → 撤销 → 再打卡，净得分只有一次', () async {
      loginAsStudent();
      final student = buildStudent();
      await student.loadData();

      final plan = StudyPlanModel(
        id: 'sp_point_1',
        title: '背诵古诗',
        content: '',
        startAt: DateTime.now().subtract(const Duration(days: 1)),
        endAt: DateTime.now().add(const Duration(days: 30)),
        type: 'study',
        status: StudyPlanStatus.active,
        studentId: 'stu_001',
        cycleType: WorkoutCycleType.daily,
      );

      await student.toggleTodayCheckin(plan);
      expect(await balanceOf('stu_001'), 5);

      // 学生误点第二下 → 撤销。分要跟着退，且账本留痕。
      await student.toggleTodayCheckin(plan);
      expect(await balanceOf('stu_001'), 0);

      // 再点回来 → 只给一次分
      await student.toggleTodayCheckin(plan);
      expect(await balanceOf('stu_001'), 5);

      // 反复开关也不累积
      await student.toggleTodayCheckin(plan);
      await student.toggleTodayCheckin(plan);
      expect(await balanceOf('stu_001'), 5);
    });

    test('家长关掉计划打卡的积分后，打卡本身照样成功', () async {
      loginAsStudent();
      final student = buildStudent();
      await student.loadData();

      final points = PointController.to;
      await points.loadFor('stu_001');
      await points.setRule(
        studentId: 'stu_001',
        action: PointAction.planCheckin,
        enabled: false,
      );

      final plan = StudyPlanModel(
        id: 'sp_point_2',
        title: '阅读',
        content: '',
        startAt: DateTime.now(),
        endAt: DateTime.now().add(const Duration(days: 7)),
        type: 'study',
        status: StudyPlanStatus.active,
        studentId: 'stu_001',
        cycleType: WorkoutCycleType.daily,
      );
      await student.toggleTodayCheckin(plan);

      // 打卡记录本身要留下 —— 积分只是奖励，不能反过来决定事情做没做
      expect(
        student.studyPlanCheckins.any(
          (c) => c.planId == plan.id && c.date == studyPlanDateKey(DateTime.now()),
        ),
        isTrue,
      );
      expect(await balanceOf('stu_001'), 0);
    });
  });

  group('运动打卡', () {
    test('同一项目同一天只记一次分', () async {
      loginAsStudent();
      final student = buildStudent();
      await student.loadData();

      // ⚠️ 起点**钉在当天 10:00**，不用 `DateTime.now()`。
      //
      // 防重键是 `PointController.workoutKey(scope, studyPlanDateKey(start))`
      // —— 按**记录的开始时间**算「哪一天」。用 `now()` 的话，这条用例
      // 在每天 23:00 之后必然失败：下面那条「同一项目再记一次」用的是
      // `start + 1 小时`，它会跨到第二天 → 「同一天只记一次」的前提
      // 当场不成立，而报出来的却是「防重坏了」（Expected 5 / Actual 10）。
      //
      // 那是用例把**墙钟**当成了输入，不是被测代码的问题。
      // 2026-09-20 23:05 实测撞上，单独跑也一样红。
      final today = DateTime.now();
      final start = DateTime(today.year, today.month, today.day, 10);
      await student.addWorkoutRecord(
        project: '跳绳',
        start: start,
        end: start.add(const Duration(minutes: 20)),
      );
      expect(await balanceOf('stu_001'), 5);

      // 再记一条同项目的（比如补记一次）—— 分数不重复给
      await student.addWorkoutRecord(
        project: '跳绳',
        start: start.add(const Duration(hours: 1)),
        end: start.add(const Duration(hours: 1, minutes: 15)),
      );
      expect(await balanceOf('stu_001'), 5);

      // 换个项目是新的一件事，正常记分
      await student.addWorkoutRecord(
        project: '跑步',
        start: start.add(const Duration(hours: 2)),
        end: start.add(const Duration(hours: 2, minutes: 20)),
      );
      expect(await balanceOf('stu_001'), 10);
    });
  });

  group('家长改分值与奖励', () {
    test('改过分值之后，下一次动作按新的算', () async {
      loginAsStudent();
      final points = PointController.to;
      await points.loadFor('stu_001');
      await points.setRule(
        studentId: 'stu_001',
        action: PointAction.workoutCheckin,
        points: 12,
      );

      final student = buildStudent();
      await student.loadData();
      final start = DateTime.now();
      await student.addWorkoutRecord(
        project: '游泳',
        start: start,
        end: start.add(const Duration(minutes: 30)),
      );

      expect(await balanceOf('stu_001'), 12);
    });

    test('家长手动奖励进账，理由留在账本上', () async {
      loginAsStudent();
      final points = PointController.to;
      await points.loadFor('stu_001');

      final outcome = await points.grantReward(
        studentId: 'stu_001',
        points: 20,
        reason: '这周主动收拾了房间',
        createdBy: 'par_001',
      );

      expect(outcome, PointGrantOutcome.granted);
      final ledger = await DatabaseService.instance.queryPointLedger('stu_001');
      expect(ledger.single.reason, '这周主动收拾了房间');
      expect(ledger.single.points, 20);
      expect(ledger.single.createdBy, 'par_001');
    });
  });

  group('复习', () {
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

    /// 组一份只含指定错题的卷子，返回卷子与卷内快照。
    Future<({String paperId, ReviewPaperItem item})> composeFor(
      ReviewController controller,
      String mistakeId,
    ) async {
      final compose = await controller.composeAndPrintPaper(
        mistakeIds: [mistakeId],
        exportAfterCompose: false,
      );
      expect(compose.ok, isTrue, reason: compose.message);
      final paperId = controller.activePaper.value!.id;
      final items = await controller.openPaper(paperId);
      return (paperId: paperId, item: items.first);
    }

    test('完成一轮复习记一笔，每道毕业的题再各记一笔', () async {
      loginAsStudent();
      final student = buildStudent();
      await seedMistake('rm_pt_1');
      await student.loadData();

      final controller = ReviewController(
        student: student,
        exporter: FakeExporter(),
      );
      await controller.loadReviewData();

      final composed = await composeFor(controller, 'rm_pt_1');
      final graded = await controller.submitPaper(
        paperId: composed.paperId,
        results: {composed.item.id: PaperItemResult.correct},
        // 录了答案才算真的做过 —— 毕业分与这一轮的分都以此为前提
        answers: {composed.item.id: composed.item.answerKey},
      );

      expect(graded.op.ok, isTrue, reason: graded.op.message);
      expect(graded.graduatedCount, 1);
      // 一轮 10 + 毕业 10
      expect(await balanceOf('stu_001'), 20);
    });

    test('整轮只标对错、没写答案的不记分', () async {
      loginAsStudent();
      final student = buildStudent();
      await seedMistake('rm_pt_2');
      await student.loadData();

      final controller = ReviewController(
        student: student,
        exporter: FakeExporter(),
      );
      await controller.loadReviewData();

      final composed = await composeFor(controller, 'rm_pt_2');
      await controller.submitPaper(
        paperId: composed.paperId,
        results: {composed.item.id: PaperItemResult.correct},
      );

      // 自评能标出「对了」，但拿它换分等于把积分变成点两下的事。
      // 项目里掌握率本来就不认自评，这里口径一致。
      expect(await balanceOf('stu_001'), 0);
    });

    test('同一份资料不会重复记分', () async {
      loginAsStudent();
      final student = buildStudent();
      await seedMistake('rm_pt_3');
      await student.loadData();

      final controller = ReviewController(
        student: student,
        exporter: FakeExporter(),
      );
      await controller.loadReviewData();

      final composed = await composeFor(controller, 'rm_pt_3');
      await controller.submitPaper(
        paperId: composed.paperId,
        results: {composed.item.id: PaperItemResult.correct},
        answers: {composed.item.id: composed.item.answerKey},
      );
      final before = await balanceOf('stu_001');

      final again = await controller.submitPaper(
        paperId: composed.paperId,
        results: {composed.item.id: PaperItemResult.correct},
        answers: {composed.item.id: composed.item.answerKey},
      );

      expect(again.op.ok, isFalse, reason: '已批改的资料不能重复提交');
      expect(await balanceOf('stu_001'), before);
    });
  });
}
