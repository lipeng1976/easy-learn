import 'package:get/get.dart';

import 'student_controller.dart';
import 'notification_controller.dart';
import 'auth_controller.dart';
import 'point_controller.dart';
import '../models/daily_comment_model.dart';
import '../models/homework_image_batch.dart';
import '../models/homework_image_model.dart';
import '../models/homework_model.dart';
import '../models/notification_model.dart';
import '../models/op_result.dart';
import '../models/point_model.dart';
import '../models/relationship_model.dart';
import '../models/review_model.dart';
import '../models/study_plan_model.dart';
import '../models/study_plan_checkin_model.dart';
import '../models/wish_model.dart';
import '../models/workout_model.dart';
import '../repositories/homework_repository.dart';
import '../repositories/notification_repository.dart';
import '../repositories/point_repository.dart';
import '../repositories/relationship_repository.dart';
import '../repositories/study_plan_repository.dart';
import '../repositories/user_repository.dart';
import '../repositories/wish_repository.dart';
import '../repositories/workout_repository.dart';
import '../services/database_service.dart';
import '../services/local_seed_service.dart';
import '../services/review_service.dart';

class ParentController extends GetxController {
  /// 数据源。默认走本地库 —— **换云端实现时只改这一处默认值**。
  ParentController({
    HomeworkRepository? homework,
    RelationshipRepository? relationships,
    UserRepository? users,
    PointRepository? points,
    WishRepository? wishes,
    StudyPlanRepository? studyPlans,
    WorkoutRepository? workouts,
    NotificationRepository? notifications,
  }) : _homework = homework ?? DatabaseService.instance,
       _relationships = relationships ?? DatabaseService.instance,
       _users = users ?? DatabaseService.instance,
       _points = points ?? DatabaseService.instance,
       _wishes = wishes ?? DatabaseService.instance,
       _studyPlans = studyPlans ?? DatabaseService.instance,
       _workouts = workouts ?? DatabaseService.instance,
       _notifications = notifications ?? DatabaseService.instance;

  final HomeworkRepository _homework;
  final RelationshipRepository _relationships;
  final UserRepository _users;
  final PointRepository _points;
  final WishRepository _wishes;
  final StudyPlanRepository _studyPlans;
  final WorkoutRepository _workouts;
  final NotificationRepository _notifications;

  final RxList<HomeworkItem> homeworkList = <HomeworkItem>[].obs;

  /// 结伴孩子已提交的作业照片。家长端全程只读，不提供上传/删除入口。
  final RxList<HomeworkImageModel> homeworkImages = <HomeworkImageModel>[].obs;
  final RxList<WorkoutPlan> workoutPlans = <WorkoutPlan>[].obs;
  final RxList<WorkoutRecord> workoutRecords = <WorkoutRecord>[].obs;
  final RxList<ReviewMistake> mistakes = <ReviewMistake>[].obs;

  /// 孩子的 AI 变式练习题。
  ///
  /// 家长端**不展示题目内容**，加载它只为一件事：把作答照片关联回错题。
  /// 照片行里的 `batchId` 存的是**题目 id**（见 `ReviewController.captureAnswers`），
  /// 而题目挂在错题下（`sourceMistakeId`）—— 没有这张映射表，
  /// 一张 `homeworkId` 为空的照片就是**无法归属的孤儿**，谁都认不出来它属于哪道题。
  final RxList<AiPracticeQuestion> practiceQuestions = <AiPracticeQuestion>[].obs;

  /// 孩子的复习资料（试卷）与作答证据。
  /// 家长要判断的不是「错了几道」，而是「这一周复习有没有真的推进」，
  /// 所以卷和作答记录都要拉过来。
  final RxList<ReviewPaper> reviewPapers = <ReviewPaper>[].obs;
  final RxList<ReviewAttempt> reviewAttempts = <ReviewAttempt>[].obs;
  final RxList<WishModel> wishes = <WishModel>[].obs;
  final RxList<StudyPlanModel> studyPlans = <StudyPlanModel>[].obs;
  final RxList<StudyPlanCheckin> studyPlanCheckins = <StudyPlanCheckin>[].obs;
  final RxList<DailyCommentModel> dailyComments = <DailyCommentModel>[].obs;

  /// 已结伴的孩子（数据隔离：家长只能查看结伴孩子的信息）
  final RxList<ParentChild> boundStudents = <ParentChild>[].obs;
  final RxString selectedStudentId = ''.obs;

  /// 底部导航当前所在页。
  ///
  /// 提到控制器里而不是留在页面的 `setState` 里，是为了让「通知直达」有落点：
  /// 家长点一条「孩子申请兑换心愿」的通知，要能**直接切到心愿页并重拉一次**，
  /// 而不是只把通知标成已读却停在原地 —— 那正是用户报的「还停在上一页」。
  /// 页面自己拿着 index 的话，通知那条路根本够不到它。
  final Rx<ParentTab> currentTab = Rx<ParentTab>(ParentTab.overview);

  @override
  void onInit() {
    super.onInit();
    // 切孩子就重新拉那个孩子的账本。
    //
    // 注册在这里而不是积分页里：家长可能停在**心愿页**直接切孩子，
    // 而定价旁边显示的余额、以及「够不够扣」的判断都依赖它。
    // 只靠积分页自己加载的话，切完孩子余额还是上一个的 ——
    // 而那种数字出错，家长只会以为孩子把分花了。
    ever<String>(selectedStudentId, (id) {
      if (id.isNotEmpty) points.loadFor(id, force: true);
    });
    loadData();
  }

  Future<void> loadData() async {
    await _loadBoundStudentHomework();
    await _loadBoundStudentImages();
    final ids = boundStudents.map((c) => c.id).toSet();

    final allWorkoutPlans = await LocalSeedService.parentWorkoutPlans();
    workoutPlans.value = allWorkoutPlans
        .where((p) => _belongsToBound(ids, p.studentId))
        .toList();

    final allRecords = await LocalSeedService.studentWorkoutRecords();
    workoutRecords.value = allRecords
        .where((r) => _belongsToBound(ids, r.studentId))
        .toList();

    final allMistakes = await LocalSeedService.parentMistakes();
    mistakes.value = allMistakes
        .where((m) => _belongsToBound(ids, m.studentId))
        .toList();

    // 练习题：只为「把作答照片挂回它所属的那道错题」（见字段注释）。
    // 单独 try 且失败只清空自己 —— 它拿不到最多是错题卡里少一组照片，
    // 不该把整页的错题/试卷/积分一起带走。
    try {
      final allQuestions = await LocalSeedService.practiceQuestions();
      practiceQuestions.value = allQuestions
          .where((q) => _belongsToBound(ids, q.studentId))
          .toList();
    } catch (_) {
      practiceQuestions.clear();
    }

    final allPapers = await LocalSeedService.studentReviewPapers();
    reviewPapers.value = allPapers
        .where((p) => _belongsToBound(ids, p.studentId))
        .toList();

    try {
      final allAttempts = await LocalSeedService.reviewAttempts();
      reviewAttempts.value = allAttempts
          .where((a) => _belongsToBound(ids, a.studentId))
          .toList();
    } catch (_) {
      reviewAttempts.clear();
    }

    final allPlans = await LocalSeedService.parentStudyPlans();
    studyPlans.value = allPlans
        .where((p) => _belongsToBound(ids, p.studentId))
        .toList();

    try {
      final allCheckins = await _studyPlans
          .queryStudyPlanCheckins();
      studyPlanCheckins.value = allCheckins
          .where((c) => _belongsToBound(ids, c.studentId))
          .toList();
    } catch (_) {
      studyPlanCheckins.clear();
    }

    try {
      final allComments = await _notifications.queryDailyComments();
      dailyComments.value = allComments
          .where((c) => _belongsToBound(ids, c.studentId))
          .toList();
    } catch (_) {
      dailyComments.clear();
    }

    wishes.value = await _loadPairedStudentPublicWishes();
    // 兜底再拉一次账本：`ever` 只在 selectedStudentId **变化**时触发，
    // 而这个孩子恰好就是上一次选的那个时它不会响 —— 重进家长端
    // 仍要从库里取一遍。
    try {
      await loadPointsForSelected();
    } catch (_) {
      // 账本读不出来不该拦住整个家长端
    }
    _checkWishReminders();
  }

  /// 数据是否归属于任一结伴孩子；历史空 studentId 兜底归属于 stu_001
  bool _belongsToBound(Set<String> boundIds, String studentId) =>
      boundIds.contains(studentId) ||
      (studentId.isEmpty && boundIds.contains('stu_001'));

  /// 数据是否归属于当前选中的孩子（含历史空 studentId 兜底）
  bool _isSelectedChild(String studentId) =>
      studentId == selectedStudentId.value ||
      (studentId.isEmpty && selectedStudentId.value == 'stu_001');

  /// 加载结伴孩子及其作业（只看已结伴孩子的信息）
  Future<void> _loadBoundStudentHomework() async {
    final parentId = Get.isRegistered<AuthController>()
        ? Get.find<AuthController>().currentUser.value?.id
        : null;
    if (parentId == null) {
      boundStudents.clear();
      homeworkList.clear();
      return;
    }
    try {
      final relationships = await _relationships.queryRelationships(
        parentId,
      );
      final studentIds = relationships
          .where((r) => r.status == RelationshipStatus.active)
          .map((r) => r.studentId)
          .toSet();
      if (studentIds.isEmpty) {
        boundStudents.clear();
        homeworkList.clear();
        // ⚠️ 这一行是「解除结伴」（2026-09-26）引出来的：
        // 在此之前关系**只增不减**，所以「一个孩子都没有」只会出现在
        // 全新账号上 —— 那时 `selectedStudentId` 本来就是空的，清不清一样。
        // 现在家长解除掉唯一的孩子会走到这里：不清空的话它会**停在那个
        // 已经解除的孩子 id 上**，而它仍被「写点评 / 布置计划」当作目标
        // （本文件 849 / 876 / 917 行等处），症状是那些操作报 403，
        // 而家长完全看不出为什么 —— 界面上他已经「没有孩子」了。
        selectedStudentId.value = '';
        return;
      }
      final users = await _users.queryUsersByIds(
        studentIds.toList(),
      );
      boundStudents.assignAll(
        users.map(
          (user) => ParentChild(
            id: user['id'] as String,
            name: (user['name'] as String?) ?? '学生',
          ),
        ),
      );
      if (boundStudents.isEmpty ||
          !boundStudents.any((child) => child.id == selectedStudentId.value)) {
        selectedStudentId.value = boundStudents.first.id;
      }
      homeworkList.value = await _homework
          .queryHomeworkByStudentIds(studentIds.toList());
    } catch (_) {
      boundStudents.clear();
      homeworkList.clear();
    }
  }

  /// 加载结伴孩子提交的作业照片。
  Future<void> _loadBoundStudentImages() async {
    if (boundStudents.isEmpty) {
      homeworkImages.clear();
      return;
    }
    try {
      final all = <HomeworkImageModel>[];
      for (final child in boundStudents) {
        all.addAll(await _homework.queryHomeworkImages(child.id));
      }
      homeworkImages.value = all;
    } catch (_) {
      homeworkImages.clear();
    }
  }

  /// 当前选中孩子的作业，按截止时间排序。
  HomeworkItem? homeworkById(String id) {
    for (final item in homeworkList) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// 当前选中孩子已提交的作业，最近提交的在前。
  ///
  /// 家长打开作业页最想先确认的是「孩子今天交了没有」，
  /// 所以这里按提交时间倒序，而不是按录入顺序。
  List<HomeworkItem> get submittedHomeworks {
    final list = visibleHomework.where((h) => h.hasSubmission).toList()
      ..sort((a, b) => b.submittedAt!.compareTo(a.submittedAt!));
    return list;
  }

  /// 当前选中孩子最近一次提交的作业（首页「最近提交」卡片）。
  HomeworkItem? get latestSubmittedHomework =>
      submittedHomeworks.isEmpty ? null : submittedHomeworks.first;

  /// 某作业已提交的照片，按批次与批内顺序排列。
  List<HomeworkImageModel> imagesOfHomework(String homeworkId) {
    final list = homeworkImages.where((e) => e.homeworkId == homeworkId).toList()
      ..sort((a, b) {
        final byBatch = a.batchId.compareTo(b.batchId);
        if (byBatch != 0) return byBatch;
        return a.sortOrder.compareTo(b.sortOrder);
      });
    return list;
  }

  /// 某作业按提交批次分组，最近的批次在前。
  List<HomeworkImageBatch> imageBatchesOfHomework(String homeworkId) {
    final grouped = <String, List<HomeworkImageModel>>{};
    for (final image in imagesOfHomework(homeworkId)) {
      final key = image.batchId.isEmpty ? image.id : image.batchId;
      grouped.putIfAbsent(key, () => <HomeworkImageModel>[]).add(image);
    }
    return grouped.entries
        .map(
          (entry) => HomeworkImageBatch(
            batchId: entry.key,
            submittedAt: entry.value.first.createdAt,
            images: entry.value,
          ),
        )
        .toList()
      ..sort((a, b) => b.submittedAt.compareTo(a.submittedAt));
  }

  int photoCountOfHomework(String homeworkId) =>
      imagesOfHomework(homeworkId).length;

  /// 某道错题下，**孩子在复习时拍的作答照片**。
  ///
  /// ## 关联链路（三跳，缺一跳就什么都看不到）
  ///
  ///   照片行 `homework_image`
  ///     └─ `batchId`  ← 写入时存的是**题目 id**（`ReviewController.captureAnswers`）
  ///         └─ `ai_practice_question.id`
  ///             └─ `sourceMistakeId` → 这道错题
  ///
  /// ## ⚠️ 为什么不能复用 `imagesOfHomework`
  ///
  /// 作答照片的 `homeworkId` 是 **null** —— 它属于「这道题的这次作答」，
  /// 不属于某次作业（写入处有注释说明这是刻意的）。而
  /// `imagesOfHomework` / `photoCountOfHomework` 全都按 `homeworkId` 过滤，
  /// **null 匹配不到任何作业** ⇒ 这条链路曾经在界面**完全不可达**：
  /// 行写进了库、字节也在，家长端却没有任何入口能看见它。
  /// 所以这个方法**只认 `batchId`**，不看 `homeworkId`。
  List<HomeworkImageModel> answerPhotosOfMistake(String mistakeId) {
    final questionIds = practiceQuestions
        .where((q) => q.sourceMistakeId == mistakeId)
        .map((q) => q.id)
        .where((id) => id.isNotEmpty)
        .toSet();
    if (questionIds.isEmpty) return const <HomeworkImageModel>[];
    final list = homeworkImages
        .where((img) => img.batchId.isNotEmpty && questionIds.contains(img.batchId))
        .toList()
      ..sort((a, b) {
        // 同一道题可以拍多张（一页解答分两张拍是常见情况），
        // 按拍的时间先后排，再按写入时的 sortOrder 兜底。
        final byTime = a.createdAt.compareTo(b.createdAt);
        return byTime != 0 ? byTime : a.sortOrder.compareTo(b.sortOrder);
      });
    return list;
  }

  /// 某作业产生的错题（作业详情页用）。
  List<ReviewMistake> mistakesOfHomework(String homeworkId) => visibleMistakes
      .where((m) => m.homeworkId == homeworkId)
      .toList();

  /// 当前选中孩子今天提交的作业数量。
  int get todaySubmittedCount => visibleHomework
      .where((h) => h.hasSubmission && _isSameDay(h.submittedAt, DateTime.now()))
      .length;

  /// 当前选中孩子待更正的作业数量。
  int get needFixCount =>
      visibleHomework.where((h) => h.status == HomeworkStatus.needFix).length;

  static bool _isSameDay(DateTime? value, DateTime other) {
    if (value == null) return false;
    return value.year == other.year &&
        value.month == other.month &&
        value.day == other.day;
  }

  /// 当前选中孩子的作业
  List<HomeworkItem> get visibleHomework =>
      homeworkList.where((item) => _isSelectedChild(item.studentId)).toList();

  /// 当前选中孩子的运动计划
  List<WorkoutPlan> get visibleWorkoutPlans =>
      workoutPlans.where((p) => _isSelectedChild(p.studentId)).toList();

  /// 当前选中孩子的运动记录
  List<WorkoutRecord> get visibleWorkoutRecords =>
      workoutRecords.where((r) => _isSelectedChild(r.studentId)).toList();

  /// 当前选中孩子的错题
  List<ReviewMistake> get visibleMistakes =>
      mistakes.where((m) => _isSelectedChild(m.studentId)).toList();

  /// 当前选中孩子的复习资料（试卷）
  List<ReviewPaper> get visibleReviewPapers =>
      reviewPapers.where((p) => _isSelectedChild(p.studentId)).toList();

  /// 待复习池中的错题（未毕业）
  List<ReviewMistake> get visiblePoolMistakes =>
      visibleMistakes.where((m) => m.state.inPool).toList();

  /// 已毕业的错题
  List<ReviewMistake> get visibleMasteredMistakes => visibleMistakes
      .where((m) => m.state == ReviewState.mastered)
      .toList();

  /// 最近 7 天通过的作答次数——家长关心的「这周有没有真的在复习」。
  /// 本周起点（周一 00:00）。
  ///
  /// 这里从「最近 7 天」改成自然周，是为了和孩子的周报对齐：
  /// 家长端显示「本周通过 7 次」、孩子的周报却说「本周通过 5 次」，
  /// 两边都没算错却对不上，家长只会认为数据不可信。
  DateTime get _weekStart =>
      ReviewService.periodStart(SummaryScope.week, DateTime.now());

  int get visibleWeekPassCount {
    final since = _weekStart;
    return reviewAttempts
        .where(
          (a) =>
              _isSelectedChild(a.studentId) &&
              a.correct &&
              !a.createdAt.isBefore(since),
        )
        .length;
  }

  /// 最近 7 天回传的复习卷数
  int get visibleWeekSubmittedPapers {
    final since = _weekStart;
    return visibleReviewPapers
        .where((p) => !(p.submittedAt ?? p.createdAt).isBefore(since))
        .length;
  }

  /// 本周的作答记录（用于渠道分布展示）。
  List<ReviewAttempt> get visibleWeekAttempts {
    final since = _weekStart;
    final list = reviewAttempts
        .where(
          (a) => _isSelectedChild(a.studentId) && !a.createdAt.isBefore(since),
        )
        .toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  /// 本周作答的渠道分布。
  ///
  /// 家长端最该看清的就是这个：孩子把卷子做完了，到底是**录入答案让 AI 判的**，
  /// 还是**自己勾了个「做对了」**。后者同样会让错题从池子里消失，
  /// 但没有任何作答证据，掌握率也不认它。
  Map<AttemptChannel, int> get visibleWeekChannelTally {
    final tally = <AttemptChannel, int>{};
    for (final attempt in visibleWeekAttempts) {
      tally[attempt.channel] = (tally[attempt.channel] ?? 0) + 1;
    }
    return tally;
  }

  /// 本周通过检查毕业的题数（自评掌握不计）。
  int get visibleWeekGraduated {
    final since = _weekStart;
    return visibleMistakes
        .where(
          (m) =>
              m.state == ReviewState.mastered &&
              !m.masteredBySelf &&
              m.masteredAt != null &&
              !m.masteredAt!.isBefore(since),
        )
        .length;
  }

  /// 掌握率：已毕业 /（已毕业 + 待复习）。
  /// 自评掌握不算，避免「点一下标记掌握」把家长看到的数字做漂亮。
  double get visibleMasteryRate {
    final verified = visibleMistakes
        .where((m) => m.state == ReviewState.mastered && !m.masteredBySelf)
        .length;
    final pool = visiblePoolMistakes.length;
    final total = verified + pool;
    return total == 0 ? 0 : verified / total;
  }

  /// 薄弱知识点排行：按累计错误次数排序，只保留还在池中的知识点。
  List<MapEntry<String, int>> visibleWeakPoints({int limit = 3}) {
    final tally = <String, int>{};
    for (final mistake in visiblePoolMistakes) {
      final key = mistake.knowledgePoint.isEmpty
          ? '${mistake.subject}·未标注知识点'
          : mistake.knowledgePoint;
      tally[key] = (tally[key] ?? 0) + mistake.wrongCount;
    }
    final entries = tally.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(limit).toList();
  }

  /// 当前选中孩子的学习计划
  List<StudyPlanModel> get visibleStudyPlans =>
      studyPlans.where((p) => _isSelectedChild(p.studentId)).toList();

  /// 当前选中孩子的计划打卡记录
  List<StudyPlanCheckin> get visibleCheckins =>
      studyPlanCheckins.where((c) => _isSelectedChild(c.studentId)).toList();

  /// 所选孩子今天是否已打卡该计划
  bool isChildCheckedInToday(String planId) {
    final key = studyPlanDateKey(DateTime.now());
    return visibleCheckins.any((c) => c.planId == planId && c.date == key);
  }

  /// 所选孩子某计划的已打卡日期集合
  Set<String> childCheckinDateKeys(String planId) => visibleCheckins
      .where((c) => c.planId == planId)
      .map((c) => c.date)
      .toSet();

  /// 所选孩子今日计划执行情况：总数 / 已打卡数
  ({int total, int done}) get todayCheckinSummary {
    final today = DateTime.now();
    final todays = visibleStudyPlans
        .where(
          (p) => p.status == StudyPlanStatus.active && p.appliesToDate(today),
        )
        .toList();
    final done = todays.where((p) => isChildCheckedInToday(p.id)).length;
    return (total: todays.length, done: done);
  }

  /// 当前选中孩子的每日点评
  List<DailyCommentModel> get visibleDailyComments =>
      dailyComments.where((c) => _isSelectedChild(c.studentId)).toList();

  /// 当前选中孩子的公开心愿
  List<WishModel> get visibleWishes =>
      wishes.where((w) => _isSelectedChild(w.studentId)).toList();

  /// 检查结伴学生的公开心愿预期时间，发送提醒通知
  Future<void> _checkWishReminders() async {
    try {
      final parentId = Get.isRegistered<AuthController>()
          ? Get.find<AuthController>().currentUser.value?.id
          : null;
      if (parentId == null) return;

      final relationships = await _relationships.queryRelationships(
        parentId,
      );
      final studentIds = <String>{};
      for (final r in relationships) {
        if (r.status == RelationshipStatus.active) {
          studentIds.add(r.studentId);
        }
      }
      if (studentIds.isEmpty) return;

      final unfulfilled = await _wishes
          .queryUnfulfilledWishes();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final notificationController = Get.find<NotificationController>();

      for (final wish in unfulfilled) {
        if (!wish.isPublic) continue;
        if (!studentIds.contains(wish.studentId)) continue;
        if (wish.expectedDate == null) continue;

        final expected = DateTime(
          wish.expectedDate!.year,
          wish.expectedDate!.month,
          wish.expectedDate!.day,
        );
        final diff = expected.difference(today).inDays;

        if (diff == 1) {
          await notificationController.addNotification(
            title: '心愿提醒',
            body: '学生的心愿「${wish.title}」明天到预期时间，还没实现，可以鼓励一下！',
            targetUserId: wish.studentId,
            type: NotificationType.wish,
            relatedBizId: wish.id,
          );
        } else if (diff == 0) {
          await notificationController.addNotification(
            title: '心愿问候',
            body: '学生的心愿「${wish.title}」今天到预期时间了，实现了吗？',
            targetUserId: wish.studentId,
            type: NotificationType.wish,
            relatedBizId: wish.id,
          );
        }
      }
    } catch (_) {}
  }

  Future<List<WishModel>> _loadPairedStudentPublicWishes() async {
    try {
      final parentId = Get.isRegistered<AuthController>()
          ? Get.find<AuthController>().currentUser.value?.id
          : null;
      if (parentId == null) {
        return await LocalSeedService.publicWishes();
      }
      final relationships = await _relationships.queryRelationships(
        parentId,
      );
      final studentIds = relationships
          .where((r) => r.status == RelationshipStatus.active)
          .map((r) => r.studentId)
          .toSet();
      if (studentIds.isEmpty) {
        return <WishModel>[];
      }
      final result = <WishModel>[];
      for (final id in studentIds) {
        result.addAll(
          await _wishes.queryPublicWishesByStudent(id),
        );
      }
      return result;
    } catch (_) {
      return <WishModel>[];
    }
  }

  void _safeSnackbar(String title, String message) {
    if (Get.overlayContext == null) return;
    try {
      Get.snackbar(title, message);
    } catch (_) {}
  }

  Future<void> _safePersist(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {}
  }

  /// 发布一条每日点评。
  ///
  /// 返回 `true` = **真的存上了**；`false` = 存储失败（已把乐观插入的那条撤掉）。
  ///
  /// ## 为什么必须等存储结果（2026-10-27 用户报的「今天的点评变成几天前那条」）
  ///
  /// 原实现是「先插进内存列表 → `_safePersist` 静默吞掉异常 → 界面立刻弹
  /// 「已保存，学生端可以实时查看」」。写失败时：
  /// 家长端**看着**保存成功了（列表里就有），学生端永远看不到，
  /// 下次重进家长端列表又退回旧的那几条 —— 用户看到的就是
  /// 「今天的点评，看到的却是几天前那条信息」。而整个过程一句报错都没有。
  ///
  /// 所以现在：存不上就把那条从列表里撤掉并返回 `false`，
  /// 由调用方如实告诉用户「没保存上」。界面宁可难看一次，也不能骗人。
  Future<bool> publishDailyComment(String rating, String content) async {
    final item = DailyCommentModel(
      id: 'dc_${DateTime.now().millisecondsSinceEpoch}',
      rating: rating,
      content: content,
      createdAt: DateTime.now(),
      studentId: selectedStudentId.value,
    );
    dailyComments.insert(0, item);

    try {
      await _notifications.insertDailyComment(item);
    } catch (_) {
      // 撤回乐观插入：留下来的话，这条「幽灵点评」会一直显示到重启，
      // 而它根本不在任何库里 —— 正是这次要修的那类静默失败。
      dailyComments.removeWhere((c) => c.id == item.id);
      return false;
    }

    if (Get.isRegistered<StudentController>()) {
      final studentController = Get.find<StudentController>();
      studentController.syncDailyComments(dailyComments);
    }

    if (Get.isRegistered<NotificationController>()) {
      Get.find<NotificationController>().addNotification(
        title: '家长点评',
        body: '家长发布了新的每日点评：$rating',
        // 点评是写给具体某个孩子的，不能广播给所有学生
        targetUserId: selectedStudentId.value,
        type: NotificationType.dailyComment,
      );
    }
    return true;
  }

  Future<void> confirmWish(String id) async {
    final index = wishes.indexWhere((item) => item.id == id);
    if (index >= 0) {
      final current = wishes[index];
      wishes[index] = current.copyWith(parentConfirmed: true);
      await _safePersist(
        () => _wishes.updateWishConfirmation(
          id: id,
          parentConfirmed: true,
        ),
      );

      if (Get.isRegistered<NotificationController>()) {
        Get.find<NotificationController>().addNotification(
          title: '心愿互动',
          body: '家长已确认心愿：${current.title}',
          targetUserId: current.studentId,
          type: NotificationType.wish,
          relatedBizId: current.id,
        );
      }
    }
  }

  // ===== 积分 =====

  /// 积分账本，与学生端是同一个实例。
  PointController get points => PointController.to;

  /// 当前操作者（家长）的 id。
  String get operatorId => Get.isRegistered<AuthController>()
      ? Get.find<AuthController>().currentUser.value?.id ?? ''
      : '';

  /// 给心愿定价：兑现这个心愿要花多少积分。**0 表示不消耗积分**。
  ///
  /// 允许在孩子申请兑换之前反复改 —— 定价是家长的单方决定，
  /// 孩子还没申请时改价不该有任何副作用。申请之后就不该再动了
  /// （界面上会隐藏入口），否则会出现「按 30 分攒够了，家长改成 50」。
  Future<void> setWishPointCost(String wishId, int cost) async {
    final index = wishes.indexWhere((item) => item.id == wishId);
    if (index < 0) return;
    final safe = cost < 0 ? 0 : cost;
    wishes[index] = wishes[index].copyWith(pointCost: safe);
    await _safePersist(
      () => _wishes.updateWishRedeemState(
        id: wishId,
        pointCost: safe,
      ),
    );
    _safeSnackbar(
      '已设置',
      safe == 0 ? '这个心愿不消耗积分' : '兑现需要 $safe 积分',
    );
  }

  /// 同意孩子的兑换申请 —— **扣分就发生在这一刻**。
  ///
  /// 扣分放在「家长确认兑现」而不是「孩子申请」，是因为不可逆的损失
  /// 应该由掌握兑现权的一方触发：孩子申请时扣了分、家长又没兑现，
  /// 就成了「分没了、愿望也没实现」，这种账最难扯清。
  Future<OpResult> approveWishRedeem(String wishId) async {
    final index = wishes.indexWhere((item) => item.id == wishId);
    if (index < 0) return const OpResult.fail('心愿不存在');
    final wish = wishes[index];
    if (wish.isRedeemed) return const OpResult.fail('这个心愿已经兑现过了');

    final studentId = wish.studentId;
    if (studentId.isEmpty) return const OpResult.fail('这个心愿没有关联到孩子');

    final now = DateTime.now();
    final key = PointController.wishRedeemKey(wishId);

    // 分是否已经扣过？
    //
    // 会走到「已扣过」有两种情况：孩子重复申请、或上次扣完分却在标记兑现
    // 前中断了（本地库极少见，但真要发生就是「分没了、愿望还挂着」）。
    // 无论哪种，这里都只补上兑现标记，绝不再扣一次。
    final paidBefore = await _points.findActivePointEntry(
      studentId: studentId,
      idempotencyKey: key,
    );

    if (paidBefore == null && wish.pointCost > 0) {
      final balance = await points.balanceOf(studentId);
      if (balance < wish.pointCost) {
        return OpResult.fail(
          '积分不足：需要 ${wish.pointCost}，当前 $balance，还差 ${wish.pointCost - balance}',
        );
      }
      final spent = await points.spend(
        action: PointAction.wishRedeem,
        studentId: studentId,
        points: wish.pointCost,
        reason: '兑现心愿：${wish.title}',
        idempotencyKey: key,
        refType: 'wish',
        refId: wishId,
        createdBy: operatorId,
      );
      if (!spent.isGranted) {
        return OpResult.fail('扣分失败：${spent.note}');
      }
    }

    // 兑现 = 家长已经认可这个心愿实现了，所以这一笔**同时**把
    // `parentConfirmed` 置 true。
    //
    // 原实现只写 `redeemedAt`，而家长端在「孩子已申请」「已兑现」两个分支里
    // 都不再显示「确认已实现」按钮 —— 于是 `parentConfirmed` 永远停在 false，
    // `bothConfirmed` 不成立，卡片上的「已逾期 N 天」永远消不掉。
    // 真机形态（2026-10-31）：10-01 到期、10-06 已兑现、孩子已确认的心愿，
    // 两端口径打架：家长端「已兑现 + 已逾期 30 天」，学生端「等待家长确认 + 已逾期 30 天」。
    wishes[index] = wish.copyWith(
      parentConfirmed: true,
      redeemedAt: now,
      clearRedeemRequest: true,
      clearRedeemRejected: true,
    );
    await _safePersist(
      () => _wishes.updateWishRedeemState(
        id: wishId,
        redeemedAt: now,
        clearRedeemRequest: true,
        clearRedeemRejected: true,
      ),
    );
    await _safePersist(
      () => _wishes.updateWishConfirmation(
        id: wishId,
        parentConfirmed: true,
      ),
    );

    if (Get.isRegistered<NotificationController>()) {
      Get.find<NotificationController>().addNotification(
        title: '心愿已兑现',
        body: wish.pointCost > 0
            ? '「${wish.title}」已兑现，扣除 ${wish.pointCost} 积分。'
            : '「${wish.title}」已兑现，不消耗积分。',
        targetUserId: studentId,
        type: NotificationType.wish,
        relatedBizId: wishId,
      );
    }
    return OpResult.success(
      wish.pointCost > 0
          ? '已兑现，扣除 ${wish.pointCost} 积分'
          : '已兑现，未消耗积分',
    );
  }

  /// 拒绝这次兑换申请。**一分都不动**，孩子可以再申请。
  Future<void> rejectWishRedeem(String wishId, {String reason = ''}) async {
    final index = wishes.indexWhere((item) => item.id == wishId);
    if (index < 0) return;
    final wish = wishes[index];
    final now = DateTime.now();
    wishes[index] = wish.copyWith(
      redeemRejectedAt: now,
      clearRedeemRequest: true,
    );
    await _safePersist(
      () => _wishes.updateWishRedeemState(
        id: wishId,
        redeemRejectedAt: now,
        clearRedeemRequest: true,
      ),
    );

    if (Get.isRegistered<NotificationController>()) {
      Get.find<NotificationController>().addNotification(
        title: '心愿兑换未通过',
        body: reason.isEmpty
            ? '这次「${wish.title}」的兑换申请没有被同意，积分没有扣除。'
            : '这次「${wish.title}」的兑换申请没有被同意：$reason。积分没有扣除。',
        targetUserId: wish.studentId,
        type: NotificationType.wish,
        relatedBizId: wishId,
      );
    }
    _safeSnackbar('已拒绝', '积分没有扣除');
  }

  /// 家长额外奖励积分。
  ///
  /// 分值由家长当次填，不走分值表 —— 临时奖励本来就没有「固定多少分」
  /// 这回事，硬塞进设置表只会让人以为改了设置就能改奖励。
  Future<OpResult> grantPoints({
    required int points,
    required String reason,
    String? studentId,
  }) async {
    final target = studentId ?? selectedStudentId.value;
    if (target.isEmpty) return const OpResult.fail('请先选择孩子');
    if (points <= 0) return const OpResult.fail('奖励积分要大于 0');

    final outcome = await this.points.grantReward(
      studentId: target,
      points: points,
      reason: reason.trim().isEmpty ? '家长奖励' : reason.trim(),
      createdBy: operatorId,
    );
    if (!outcome.isGranted) return OpResult.fail('发放失败：${outcome.note}');

    if (Get.isRegistered<NotificationController>()) {
      Get.find<NotificationController>().addNotification(
        title: '获得奖励积分',
        body: reason.trim().isEmpty
            ? '家长奖励了你 $points 积分。'
            : '家长奖励了你 $points 积分：${reason.trim()}',
        targetUserId: target,
        type: NotificationType.wish,
      );
    }
    return OpResult.success('已奖励 $points 积分');
  }

  /// 切到某个孩子看账本。
  Future<void> loadPointsForSelected() async {
    final target = selectedStudentId.value;
    if (target.isEmpty) return;
    await points.loadFor(target, force: true);
  }

  /// 重新拉一次心愿与账本 —— 家长端的「此刻」入口。
  ///
  /// 为什么必须有它（真机反馈的根因）：`loadData()` 只在 `onInit` 里跑一次，
  /// 也就是说家长端拿到的是一份**登录那一刻的快照**。而心愿兑换是
  /// 这个应用里唯一一处「孩子在另一台设备上先动手、家长在这里等确认」的流程：
  /// 孩子点下「申请兑换」之后，家长端那份旧快照里 `redeemRequestedAt` 仍是空，
  /// 于是界面照旧显示「等待学生确认」——
  /// 家长被告知了（还收到通知），却看不到「同意 / 拒绝」两个按钮。
  /// 功能其实一直在，只是这条拿新数据的路没修。
  ///
  /// 只拉心愿 + 账本这两样，不整包 `loadData()`：后者是一串串行查询，
  /// 挂在切页/通知跳转这种要当场看到结果的路径上，迟滞会很明显。
  Future<void> refreshWishes() async {
    try {
      wishes.value = await _loadPairedStudentPublicWishes();
    } catch (_) {
      // 心愿读不出来不该把账本一起带崩
    }
    try {
      await loadPointsForSelected();
    } catch (_) {
      // 账本同理
    }
  }

  Future<void> createStudyPlan(StudyPlanModel plan) async {
    final attributed = plan.copyWith(studentId: selectedStudentId.value);
    studyPlans.insert(0, attributed);
    await _safePersist(
      () => _studyPlans.insertStudyPlan(attributed, 'parent'),
    );

    if (Get.isRegistered<NotificationController>()) {
      Get.find<NotificationController>().addNotification(
        title: '学习计划',
        body: '家长发布了新的学习计划，等待确认：${plan.title}',
        targetUserId: selectedStudentId.value,
        type: NotificationType.studyPlan,
        relatedBizId: attributed.id,
      );
    }
  }

  Future<void> updateStudyPlanStatus(String id, StudyPlanStatus status) async {
    final index = studyPlans.indexWhere((item) => item.id == id);
    if (index >= 0) {
      studyPlans[index] = studyPlans[index].copyWith(status: status);
      await _safePersist(
        () => _studyPlans.updateStudyPlanStatus(id, status),
      );
    }
  }

  Future<void> addWorkoutPlan({
    required String title,
    required String project,
    required List<String> weekdays,
    required int targetMinutes,
    DateTime? startDate,
    DateTime? endDate,
    String startTime = '08:00',
    String endTime = '09:00',
    WorkoutCycleType cycleType = WorkoutCycleType.weekly,
    List<String> customWeekdays = const <String>[],
  }) async {
    final plan = WorkoutPlan(
      id: 'wp_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      project: project,
      weekdays: weekdays,
      targetMinutes: targetMinutes,
      isActive: true,
      startDate: startDate,
      endDate: endDate,
      startTime: startTime,
      endTime: endTime,
      cycleType: cycleType,
      customWeekdays: customWeekdays,
      studentId: selectedStudentId.value,
    );
    workoutPlans.insert(0, plan);
    await _safePersist(() => _workouts.insertWorkoutPlan(plan));
    _safeSnackbar('计划已发布', '$title 运动计划已发布');
  }

  Future<void> toggleWorkoutPlan(String id) async {
    final index = workoutPlans.indexWhere((item) => item.id == id);
    if (index >= 0) {
      final current = workoutPlans[index];
      final newActive = !current.isActive;
      workoutPlans[index] = current.copyWith(isActive: newActive);
      await _safePersist(
        () => _workouts.updateWorkoutPlanActive(id, newActive),
      );
    }
  }
}

/// 家长端孩子信息（结伴学生）
class ParentChild {
  const ParentChild({required this.id, required this.name});

  final String id;
  final String name;
}

/// 家长端底部导航页签。
///
/// 顺序必须与 `ParentHomePage` 里 `pages` 列表、`BottomNavigationBar.items`
/// **逐一对应** —— 三处靠下标对齐，插一项就要三处一起改。
enum ParentTab { overview, plans, review, wishes, points }
