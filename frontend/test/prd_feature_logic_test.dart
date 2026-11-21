import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/daily_comment_model.dart';
import 'package:easy_learn_app/models/notification_model.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/models/study_plan_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/models/wish_model.dart';
import 'package:easy_learn_app/repositories/notification_repository.dart';
import 'package:easy_learn_app/services/review_service.dart';
import 'package:easy_learn_app/services/simulated_ai_data_source.dart';
import 'package:get/get.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只记「点评有没有真的写进去」的通知仓库。
///
/// 点评的判据是「存上了没有」，不是「列表里有没有」—— 用真库/HTTP 都会被
/// 测试环境的装配牵着走，所以这里只留 insertDailyComment 一条。
class _NotificationStub implements NotificationRepository {
  _NotificationStub({this.failInsert = false});

  /// true = 模拟存储失败（断网、服务端 500）。
  final bool failInsert;

  final List<DailyCommentModel> inserted = [];

  @override
  Future<void> insertDailyComment(DailyCommentModel comment) async {
    if (failInsert) throw StateError('network down');
    inserted.add(comment);
  }

  @override
  Future<void> insertNotification(AppNotificationModel notification) async {}

  @override
  Future<void> markNotificationRead(String id) async {}

  /// 只做接口完整性：这一组测的是点评，批量已读不在范围内。
  @override
  Future<int> markAllNotificationsRead({String? userId}) async => 0;

  @override
  Future<List<AppNotificationModel>> queryNotifications({String? userId}) async =>
      const [];

  @override
  Future<List<DailyCommentModel>> queryDailyComments() async => inserted;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  group('PRD feature logic', () {
    test('parent daily comment creates an auditable student-facing record', () async {
      final repo = _NotificationStub();
      final controller = ParentController(notifications: repo);

      final ok = await controller.publishDailyComment('非常优秀', '今天独立完成 2 道难题，专注度很好。');

      expect(ok, isTrue, reason: '存上了才算发布成功');
      expect(repo.inserted.length, 1, reason: '必须真的写进存储，不能只留在内存列表里');
      expect(controller.dailyComments.length, 1);
      expect(controller.dailyComments.first.rating, '非常优秀');
      expect(controller.dailyComments.first.content, contains('专注度很好'));
    });

    test('点评存不上：不许留在列表里假装已保存（2026-10-27 的静默失败）', () async {
      final repo = _NotificationStub(failInsert: true);
      final controller = ParentController(notifications: repo);

      final ok = await controller.publishDailyComment('非常优秀', '这条会写失败');

      expect(ok, isFalse, reason: '写失败必须如实返回 false，页面据此提示用户');
      expect(
        controller.dailyComments,
        isEmpty,
        reason: '写失败的「幽灵点评」必须撤回：留着的话重启后又消失，'
            '家长看到的就是「今天的点评变成了几天前那条」',
      );
    });

    test('student can confirm a study plan and parent can confirm a wish', () {
      final student = StudentController();
      final parent = ParentController();

      final plan = StudyPlanModel(
        id: 'sp_test',
        title: '阅读训练',
        content: '每天阅读 20 分钟',
        startAt: DateTime.now(),
        endAt: DateTime.now().add(const Duration(days: 2)),
        type: '阅读',
        status: StudyPlanStatus.pendingStudentConfirm,
      );

      student.studyPlans.add(plan);
      student.updateStudyPlanStatus('sp_test', StudyPlanStatus.active);

      final wish = WishModel(
        id: 'w_test',
        title: '作业奖励',
        description: '完成本周任务后获得一次家长陪练。',
        isPublic: true,
        parentConfirmed: false,
        studentConfirmed: true,
        isArchived: false,
      );

      parent.wishes.add(wish);
      parent.confirmWish('w_test');

      expect(
        student.studyPlans.firstWhere((item) => item.id == 'sp_test').status,
        StudyPlanStatus.active,
      );
      expect(
        parent.wishes.firstWhere((item) => item.id == 'w_test').parentConfirmed,
        isTrue,
      );
    });

    test('新增错题可以从待复习池被组卷选中', () async {
      final student = StudentController();
      student.mistakes.add(
        ReviewMistake(
          id: 'rm_ai_001',
          subject: '数学',
          title: '分数比较题',
          originalAnswer: '3/4 > 2/3',
          wrongReason: '分母处理错误',
          knowledgePoint: '分数比较',
          createdAt: DateTime.now(),
          state: ReviewState.pending,
        ),
      );

      // 组卷是纯函数（ReviewService），不需要数据库也不需要 UI。
      final composed = await ReviewService.compose(
        pool: student.mistakes,
        studentId: 'stu_001',
        paperId: 'rp_test',
        now: DateTime.now(),
        ai: const SimulatedAiDataSource(),
      );

      expect(composed.items.length, 1);
      expect(composed.items.first.mistakeId, 'rm_ai_001');
      // 题目内容被冻结成快照：印出去之后就不再跟随原错题变化。
      expect(composed.items.first.questionTitle, '分数比较题');
      expect(composed.paper.status, PaperStatus.draft);
      // 组卷本身不改错题状态，状态推进由控制器负责，纯函数保持无副作用。
      expect(
        student.mistakes.firstWhere((item) => item.id == 'rm_ai_001').state,
        ReviewState.pending,
      );
    });

    test('student receives parent daily comments in real time', () async {
      // 学生端只接收「写给自己的」点评（数据隔离），所以这条用例必须先有登录态。
      // 没有登录态时 _currentStudentId 为空，任何点评都会被判定为「不是我的」
      // 而被过滤掉——这里补上身份，走的才是真实链路。
      final auth = Get.put(AuthController());
      auth.currentUser.value = UserModel(
        id: 'stu_001',
        name: '陈小星',
        phone: '13800000001',
        role: 'student',
        avatar: '👦',
      );

      final student = StudentController();
      final parent = ParentController(notifications: _NotificationStub());

      // 必须 await：`publishDailyComment` 现在是「存上了才算发布成功」，
      // 不等它的话列表里那条是尚未确认的乐观插入。
      final ok = await parent.publishDailyComment('非常优秀', '今天阅读完成得很好');
      expect(ok, isTrue);
      student.syncDailyComments(parent.dailyComments);

      expect(student.dailyComments.length, 1);
      expect(student.dailyComments.first.rating, '非常优秀');
      expect(student.dailyComments.first.content, contains('阅读完成得很好'));

      Get.reset();
    });
  });
}
