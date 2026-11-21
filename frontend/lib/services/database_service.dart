import 'package:flutter/foundation.dart';

import '../models/daily_comment_model.dart';
import '../models/drill_question.dart';
import '../models/homework_image_model.dart';
import '../models/homework_model.dart';
import '../models/chat_message_model.dart';
import '../models/focus_session_model.dart';
import '../models/knowledge_tip.dart';
import '../models/notification_model.dart';
import '../models/point_model.dart';
import '../models/relationship_model.dart';
import '../models/review_model.dart';
import '../models/study_plan_checkin_model.dart';
import '../models/study_plan_model.dart';
import '../models/user_profile_model.dart';
import '../models/wish_model.dart';
import '../models/workout_model.dart';
import '../repositories/drill_repository.dart';
import '../repositories/checkin_repository.dart';
import '../repositories/focus_repository.dart';
import '../repositories/homework_repository.dart';
import '../repositories/ima_repository.dart';
import '../repositories/reading_repository.dart';
import '../repositories/notification_repository.dart';
import '../repositories/point_repository.dart';
import '../repositories/relationship_repository.dart';
import '../repositories/review_repository.dart';
import '../repositories/study_plan_repository.dart';
import '../repositories/user_repository.dart';
import '../repositories/wish_repository.dart';
import '../repositories/workout_repository.dart';
import 'auth_data_source.dart';
import 'cloud_runtime.dart';
import 'http_checkin_repository.dart';
import 'http_ima_repository.dart';
import 'http_reading_repository.dart';
import 'knowledge_tip_store.dart';
import 'demo_seed.dart';
import 'judgement_ab.dart';
import 'local_database_service.dart';
import '../models/word_checkin.dart';
import 'word_api.dart';
import 'subject_api.dart';
import 'textbook_api.dart';

/// 数据访问的**唯一入口**（门面）。
///
/// ## 它只做一件事：决定这一次读走哪条路
///
/// ```
/// 控制器 ──▶ DatabaseService（本文件）──┬─▶ LocalDatabaseService   （本地 SQLite / Web 内存）
///                                     └─▶ CloudRuntime 里的 HTTP 实现（服务端）
/// ```
///
/// 本地那份实现在 `local_database_service.dart`，一行没改；服务端那份是
/// `http_*_repository.dart`。**两边实现的是同一组契约**（`lib/repositories/`），
/// 所以控制器、页面、325 个测试都不知道数据换了地方 —— 这正是当初抽 L2 的目的。
///
/// ## 为什么是门面，而不是在每个页面里注入
///
/// 控制器的构造器早就支持注入（`HomeworkRepository? homework`），但那**只覆盖了
/// 一处**：每个 `?? DatabaseService.instance` 默认值都是一个独立的开关点，
/// 三十来个开关点意味着「切到云端」要改三十个文件，而且漏掉一个的症状是
/// **一部分数据在云上、一部分在本地**——不报错，只是有些页面看不到刚写的东西。
///
/// 合成一个门面之后，「走哪条路」在这一个文件里回答。
///
/// ## 默认是本地，且这一点是刻意的
///
/// 没配 `DATA_API_BASE_URL` 时（见 `data_config.dart`），[_cloud] 是 null，
/// 每一个转发都落在本地实现上 —— 行为与上云之前**逐字相同**。
/// 漏配一个环境变量的后果是「回到本地」，不是「把数据写到谁都没管的服务器上」。
class DatabaseService
    implements
        AuthDataSource,
        HomeworkRepository,
        NotificationRepository,
        PointRepository,
        RelationshipRepository,
        ReviewRepository,
        StudyPlanRepository,
        UserRepository,
        WishRepository,
        WorkoutRepository,
        KnowledgeTipStore,
        FocusRepository,
        DrillRepository {
  DatabaseService._();
  static final DatabaseService instance = DatabaseService._();

  static LocalDatabaseService get _local => LocalDatabaseService.instance;

  static CloudRuntime? _cloud;

  /// 云端运行环境。null = 纯本地。
  ///
  /// ⚠️ **「当前用的是哪一个」只能有这一处答案。**
  ///
  /// 这里曾经在 `cloud_runtime.dart` 里另挂了一个可变全局
  /// `currentCloudRuntime`，两份各存一次、必须一起改。漏改一处不报错，
  /// 而且症状很有欺骗性：数据那半边读到了（请求走服务端），
  /// 认证那半边没读到（登录留在本地）—— 于是「用本地账号登进首页，
  /// 然后每个列表都是空的」（读云端时手里没 token），
  /// 而登录页一切正常、控制台干干净净。一次真实的浏览器走查就是这么撞上的。
  ///
  /// 所以：[AuthService] 与首屏路由都读**这里**，装配点只有
  /// [useCloudRuntime] 一个。
  static CloudRuntime? get cloud => _cloud;

  /// 由 `main()` 在启动时装配（见 `cloud_runtime.dart`）。
  ///
  /// 显式一个装配点而不是在字段初始化时读环境：装配要 `await` 一次会话读取
  /// （`SessionStore.initialize`），而静态初始化里做异步只会得到一个
  /// 「有时还没读完」的凭证 —— 症状是冷启动后第一次请求 401，第二次又好了。
  static void useCloudRuntime(CloudRuntime? runtime) {
    _cloud = runtime;
  }

  /// 当前数据在哪。界面与排障都用它，不要自己去猜环境变量。
  static bool get isCloud => _cloud != null;

  // ===== 每一组一个出口 =====
  //
  // ⚠️ 逐个 getter 而不是「一个 if 判断整个门面」：某一组上了云、另一组还没上，
  // 是这个改造过程中的**正常状态**（S4 的计划就是「按接口逐个切换」）。
  // 用一个总开关的话，就会出现「要么全本地、要么全云端」，
  // 而那意味着在最后一组做完之前，任何一组都不能先切。

  static HomeworkRepository get _homework => _cloud?.homework ?? _local;
  static NotificationRepository get _notifications => _cloud?.notifications ?? _local;
  static PointRepository get _points => _cloud?.points ?? _local;
  static RelationshipRepository get _relationships => _cloud?.relationships ?? _local;
  static ReviewRepository get _review => _cloud?.review ?? _local;
  static StudyPlanRepository get _studyPlans => _cloud?.studyPlans ?? _local;
  static UserRepository get _users => _cloud?.users ?? _local;
  static WishRepository get _wishes => _cloud?.wishes ?? _local;
  static WorkoutRepository get _workouts => _cloud?.workouts ?? _local;

  /// 仅供测试：关闭连接并清空内存缓存（本地实现的那一份）。
  ///
  /// 转发的理由：测试里用的一直是这个入口，而它在云端模式下**仍然必须有效** ——
  /// 「数据在云端」不代表本地那份连接不需要清理（它还在，只是没人读）。
  @visibleForTesting
  static Future<void> resetForTesting() =>
      // ignore: invalid_use_of_visible_for_testing_member
      LocalDatabaseService.resetForTesting();

  /// **本地**种子数据。
  ///
  /// 上云之后它是空操作：服务端的演示数据由 `scripts/seed-demo.mjs` 灌
  /// （计划 §9「不动 `local_seed_service`」—— 那份数据整体废弃）。
  /// 不置空的话，云端模式下启动会往**本机**库里塞一批没人看的演示数据，
  /// 而它们会与云端数据长得几乎一样 —— 排查时最容易被这份「影子数据」带偏。
  ///
  /// `LocalSeedService` 的十几个 `xxxOrSeed()` 都经过它：那些方法在云端模式下
  /// 就退化成「读云端」，调用点一行不用改。
  ///
  /// [demoData] 默认取**编译期开关** `DemoSeed.enabled`（默认关）—— 真实用户
  /// 不该在新库首次打开时看到「别人的孩子」，理由与更细的取舍见 `demo_seed.dart`。
  /// 只有测试要演示数据时才**显式**传 `true`（`test/helpers/db_test_helper.dart`）。
  Future<void> seedIfEmpty({bool demoData = DemoSeed.enabled}) async {
    if (isCloud) return;
    await _local.seedIfEmpty(demoData: demoData);
  }

  // ===== AuthDataSource =====
  //
  // ⚠️ 这一组**永远走本地**，而且这是对的，不是遗漏。
  //
  // 这个接口的形状是本地库的形状：`findUserByPhone` 返回含**明文口令**的行，
  // `AuthService` 拿它和用户输入逐个字符比。服务端没有等价物 ——
  // 口令在那儿是 scrypt 哈希、登录要签发会话，两者不是同一个动作。
  //
  // 云端模式下 `AuthService` 走 `HttpAuthApi`（登录/注册/登出/改密四条），
  // 根本不碰这几个方法。留着它们是给**纯本地模式**用的。

  @override
  Future<Map<String, dynamic>?> findUserByPhone(String phone) =>
      _local.findUserByPhone(phone);

  @override
  Future<Map<String, dynamic>?> findUserByWechat(String openId) =>
      _local.findUserByWechat(openId);

  @override
  Future<void> saveUser(Map<String, dynamic> user) => _local.saveUser(user);

  @override
  Future<void> updatePassword({
    required String userId,
    required String newPassword,
    required String updatedAt,
  }) =>
      _local.updatePassword(
        userId: userId,
        newPassword: newPassword,
        updatedAt: updatedAt,
      );

  // ===== HomeworkRepository =====

  @override
  Future<List<HomeworkItem>> queryHomework(String userRole) =>
      _homework.queryHomework(userRole);

  @override
  Future<List<HomeworkItem>> queryHomeworkByStudentIds(List<String> studentIds) =>
      _homework.queryHomeworkByStudentIds(studentIds);

  /// 透传，**返回值也一起透传**：云端实现会带回服务端生成的新 id，
  /// 门面在这里把它丢掉的话，上层就再也拿不到了（见 `HomeworkRepository.insertHomework`）。
  @override
  Future<HomeworkItem> insertHomework(HomeworkItem item, String userRole) =>
      _homework.insertHomework(item, userRole);

  @override
  Future<void> updateHomework(HomeworkPatch patch) => _homework.updateHomework(patch);

  @override
  Future<List<HomeworkImageModel>> saveHomeworkImage(HomeworkImageModel image) =>
      _homework.saveHomeworkImage(image);

  @override
  Future<SavedHomeworkImages> saveHomeworkImages(
    List<HomeworkImageModel> images,
  ) => _homework.saveHomeworkImages(images);

  @override
  Future<List<HomeworkImageModel>> queryHomeworkImages(String studentId) =>
      _homework.queryHomeworkImages(studentId);

  @override
  Future<List<HomeworkImageModel>> queryHomeworkImagesByHomeworkId(String homeworkId) =>
      _homework.queryHomeworkImagesByHomeworkId(homeworkId);

  @override
  Future<void> deleteHomework(String id) => _homework.deleteHomework(id);

  @override
  Future<void> deleteHomeworkImagesByHomeworkId(String homeworkId) =>
      _homework.deleteHomeworkImagesByHomeworkId(homeworkId);

  @override
  Future<int> countHomeworkImages(String homeworkId) =>
      _homework.countHomeworkImages(homeworkId);

  // ===== NotificationRepository =====

  @override
  Future<void> insertNotification(AppNotificationModel notification) =>
      _notifications.insertNotification(notification);

  @override
  Future<void> markNotificationRead(String id) => _notifications.markNotificationRead(id);

  @override
  Future<int> markAllNotificationsRead({String? userId}) =>
      _notifications.markAllNotificationsRead(userId: userId);

  @override
  Future<List<AppNotificationModel>> queryNotifications({String? userId}) =>
      _notifications.queryNotifications(userId: userId);

  @override
  Future<void> insertDailyComment(DailyCommentModel comment) =>
      _notifications.insertDailyComment(comment);

  @override
  Future<List<DailyCommentModel>> queryDailyComments() => _notifications.queryDailyComments();

  // ===== PointRepository =====

  @override
  Future<List<PointLedgerEntry>> queryPointLedger(String studentId) =>
      _points.queryPointLedger(studentId);

  @override
  Future<List<PointRule>> queryPointRules(String studentId) =>
      _points.queryPointRules(studentId);

  @override
  Future<void> upsertPointRule(PointRule rule) => _points.upsertPointRule(rule);

  @override
  Future<PointLedgerEntry?> findActivePointEntry({
    required String studentId,
    required String idempotencyKey,
  }) =>
      _points.findActivePointEntry(studentId: studentId, idempotencyKey: idempotencyKey);

  @override
  Future<bool> insertPointLedger(PointLedgerEntry entry) => _points.insertPointLedger(entry);

  @override
  Future<void> markPointEntryReversed(String id, DateTime reversedAt) =>
      _points.markPointEntryReversed(id, reversedAt);

  // ===== RelationshipRepository =====

  @override
  Future<List<RelationshipModel>> queryRelationships(String userId) =>
      _relationships.queryRelationships(userId);

  @override
  Future<RelationshipModel> createRelationshipInvitation({
    required String senderId,
    required String targetPhone,
  }) =>
      _relationships.createRelationshipInvitation(
        senderId: senderId,
        targetPhone: targetPhone,
      );

  @override
  Future<void> updateRelationshipStatus({
    required String id,
    required RelationshipStatus status,
  }) =>
      _relationships.updateRelationshipStatus(id: id, status: status);

  @override
  Future<void> revokeRelationship({required String id}) =>
      _relationships.revokeRelationship(id: id);

  @override
  Future<List<ChatMessageModel>> queryChatMessages({
    required String relationshipId,
    required String requesterId,
  }) =>
      _relationships.queryChatMessages(
        relationshipId: relationshipId,
        requesterId: requesterId,
      );

  @override
  Future<ChatMessageModel> sendChatMessage({
    required String relationshipId,
    required String senderId,
    required String content,
  }) =>
      _relationships.sendChatMessage(
        relationshipId: relationshipId,
        senderId: senderId,
        content: content,
      );

  // ===== ReviewRepository =====

  @override
  Future<List<ReviewMistake>> queryReviewMistakes() => _review.queryReviewMistakes();

  @override
  Future<List<ReviewMistake>> queryReviewMistakesByHomeworkId(String homeworkId) =>
      _review.queryReviewMistakesByHomeworkId(homeworkId);

  @override
  Future<void> insertReviewMistake(ReviewMistake mistake) =>
      _review.insertReviewMistake(mistake);

  @override
  Future<void> insertReviewMistakes(List<ReviewMistake> mistakes) =>
      _review.insertReviewMistakes(mistakes);

  @override
  Future<void> updateReviewMistake(ReviewMistake mistake) =>
      _review.updateReviewMistake(mistake);

  @override
  Future<void> deleteReviewMistake(String id) => _review.deleteReviewMistake(id);

  @override
  Future<void> deleteReviewMistakesByHomeworkId(String homeworkId) =>
      _review.deleteReviewMistakesByHomeworkId(homeworkId);

  /// 写题 + 写图要在**同一个事务**里：分开调两个方法时，
  /// 图上传成功而写行失败就会留下一批没有主人的图片字节。
  /// 本地实现开 sqflite 事务、云端实现靠服务端每请求一个事务，
  /// 两者对调用方是同一个语义。
  @override
  Future<void> insertReviewMistakeWithImages(
    ReviewMistake mistake,
    List<ReviewMistakeImage> images,
  ) =>
      _review.insertReviewMistakeWithImages(mistake, images);

  @override
  Future<List<ReviewMistakeImage>> queryMistakeImages(String mistakeId) =>
      _review.queryMistakeImages(mistakeId);

  @override
  Future<void> insertMistakeImages(List<ReviewMistakeImage> images) =>
      _review.insertMistakeImages(images);

  @override
  Future<void> deleteMistakeImage(String id) => _review.deleteMistakeImage(id);

  @override
  Future<void> updateReviewMistakeState(
    String id,
    ReviewState state, {
    int? wrongCount,
    DateTime? lastWrongAt,
    int? reviewRound,
    DateTime? lastReviewedAt,
    DateTime? masteredAt,
    bool? masteredBySelf,
    String? knowledgePoint,
    String? wrongReason,
  }) =>
      _review.updateReviewMistakeState(
        id,
        state,
        wrongCount: wrongCount,
        lastWrongAt: lastWrongAt,
        reviewRound: reviewRound,
        lastReviewedAt: lastReviewedAt,
        masteredAt: masteredAt,
        masteredBySelf: masteredBySelf,
        knowledgePoint: knowledgePoint,
        wrongReason: wrongReason,
      );

  @override
  Future<List<ReviewPaper>> queryReviewPapers() => _review.queryReviewPapers();

  @override
  Future<List<ReviewPaperItem>> queryReviewPaperItems(String paperId) =>
      _review.queryReviewPaperItems(paperId);

  @override
  Future<void> insertReviewPaper(ReviewPaper paper) => _review.insertReviewPaper(paper);

  @override
  Future<SavedPaper> insertReviewPaperWithItems(
    ReviewPaper paper,
    List<ReviewPaperItem> items,
  ) =>
      _review.insertReviewPaperWithItems(paper, items);

  @override
  Future<void> updateReviewPaper(ReviewPaper paper) => _review.updateReviewPaper(paper);

  @override
  Future<void> updateReviewPaperItem(ReviewPaperItem item) =>
      _review.updateReviewPaperItem(item);

  @override
  Future<List<ReviewAttempt>> queryReviewAttempts({String? mistakeId}) =>
      _review.queryReviewAttempts(mistakeId: mistakeId);

  @override
  Future<void> insertReviewAttempt(ReviewAttempt attempt) =>
      _review.insertReviewAttempt(attempt);

  @override
  Future<void> insertReviewAttempts(List<ReviewAttempt> attempts) =>
      _review.insertReviewAttempts(attempts);

  @override
  Future<List<AiPracticeQuestion>> queryPracticeQuestions({String? sourceMistakeId}) =>
      _review.queryPracticeQuestions(sourceMistakeId: sourceMistakeId);

  @override
  Future<void> replacePracticeQuestions(
    String sourceMistakeId,
    List<AiPracticeQuestion> questions,
  ) =>
      _review.replacePracticeQuestions(sourceMistakeId, questions);

  @override
  Future<void> updatePracticeQuestion(AiPracticeQuestion question) =>
      _review.updatePracticeQuestion(question);

  @override
  Future<List<ExplainRecord>> queryExplainRecords({String? mistakeId}) =>
      _review.queryExplainRecords(mistakeId: mistakeId);

  @override
  Future<void> insertExplainRecord(ExplainRecord record) =>
      _review.insertExplainRecord(record);

  @override
  Future<List<ReviewSummary>> queryReviewSummaries() => _review.queryReviewSummaries();

  @override
  Future<void> insertReviewSummary(ReviewSummary summary) =>
      _review.insertReviewSummary(summary);

  @override
  Future<List<JudgementABRecord>> queryJudgementAB({
    String? studentId,
    String? mistakeId,
  }) =>
      _review.queryJudgementAB(studentId: studentId, mistakeId: mistakeId);

  @override
  Future<void> insertJudgementABRecords(List<JudgementABRecord> records) =>
      _review.insertJudgementABRecords(records);

  // ===== StudyPlanRepository =====

  @override
  Future<List<StudyPlanModel>> queryStudyPlans(String userRole) =>
      _studyPlans.queryStudyPlans(userRole);

  @override
  Future<void> insertStudyPlan(StudyPlanModel plan, String userRole) =>
      _studyPlans.insertStudyPlan(plan, userRole);

  @override
  Future<void> updateStudyPlanStatus(
    String id,
    StudyPlanStatus status, {
    String? rejectReason,
  }) =>
      _studyPlans.updateStudyPlanStatus(id, status, rejectReason: rejectReason);

  @override
  Future<List<StudyPlanCheckin>> queryStudyPlanCheckins() =>
      _studyPlans.queryStudyPlanCheckins();

  @override
  Future<void> insertStudyPlanCheckin(StudyPlanCheckin checkin) =>
      _studyPlans.insertStudyPlanCheckin(checkin);

  @override
  Future<void> deleteStudyPlanCheckin(String planId, String date) =>
      _studyPlans.deleteStudyPlanCheckin(planId, date);

  // ===== UserRepository =====

  @override
  Future<UserProfileModel?> queryUserProfile(String userId) =>
      _users.queryUserProfile(userId);

  @override
  Future<void> updateUserProfile(UserProfileModel profile) =>
      _users.updateUserProfile(profile);

  @override
  Future<List<Map<String, dynamic>>> queryUsersByIds(List<String> ids) =>
      _users.queryUsersByIds(ids);

  // ===== WishRepository =====

  @override
  Future<List<WishModel>> queryWishes(String userRole) => _wishes.queryWishes(userRole);

  @override
  Future<List<WishModel>> queryPublicWishes() => _wishes.queryPublicWishes();

  @override
  Future<List<WishModel>> queryPublicWishesByStudent(String studentId) =>
      _wishes.queryPublicWishesByStudent(studentId);

  @override
  Future<List<WishModel>> queryUnfulfilledWishes() => _wishes.queryUnfulfilledWishes();

  @override
  Future<void> insertWish(WishModel wish, String userRole) =>
      _wishes.insertWish(wish, userRole);

  @override
  Future<void> updateWishConfirmation({
    required String id,
    bool? parentConfirmed,
    bool? studentConfirmed,
  }) =>
      _wishes.updateWishConfirmation(
        id: id,
        parentConfirmed: parentConfirmed,
        studentConfirmed: studentConfirmed,
      );

  @override
  Future<void> updateWishArchived(String id, bool isArchived) =>
      _wishes.updateWishArchived(id, isArchived);

  @override
  Future<void> updateWishRedeemState({
    required String id,
    int? pointCost,
    DateTime? redeemRequestedAt,
    DateTime? redeemedAt,
    DateTime? redeemRejectedAt,
    bool clearRedeemRequest = false,
    bool clearRedeemRejected = false,
  }) =>
      _wishes.updateWishRedeemState(
        id: id,
        pointCost: pointCost,
        redeemRequestedAt: redeemRequestedAt,
        redeemedAt: redeemedAt,
        redeemRejectedAt: redeemRejectedAt,
        clearRedeemRequest: clearRedeemRequest,
        clearRedeemRejected: clearRedeemRejected,
      );

  // ===== WorkoutRepository =====

  @override
  Future<List<WorkoutPlan>> queryWorkoutPlans() => _workouts.queryWorkoutPlans();

  @override
  Future<List<WorkoutRecord>> queryWorkoutRecords() => _workouts.queryWorkoutRecords();

  @override
  Future<void> insertWorkoutRecord(WorkoutRecord record) =>
      _workouts.insertWorkoutRecord(record);

  @override
  Future<void> insertWorkoutPlan(WorkoutPlan plan) => _workouts.insertWorkoutPlan(plan);

  @override
  Future<void> updateWorkoutPlanActive(String id, bool isActive) =>
      _workouts.updateWorkoutPlanActive(id, isActive);

  // ===== 本机缓存 / 本机设置 =====

  /// 下面四个方法**永远走本地**，不经过 [_cloud]。
  ///
  /// 这不是「还没上云」，而是**语义上就该在本地**：
  /// · 知识点提示是从这台设备上这份错题池归纳出来的快照，跟着设备走；
  /// · 休息提醒阈值是「这台手机上的节奏」，换设备本来就该重新设。
  ///
  /// 把它们接到云端还有一个具体后果：A 学生生成的提示会按 (studentId, subject)
  /// 落到共享库里，B 学生同一科目就会读到别人的提示 —— 而界面看起来完全正常。
  @override
  Future<List<KnowledgeTip>> queryKnowledgeTips({
    required String studentId,
    required String subject,
  }) => _local.queryKnowledgeTips(studentId: studentId, subject: subject);

  @override
  Future<void> replaceKnowledgeTips({
    required String studentId,
    required String subject,
    required List<KnowledgeTip> tips,
  }) => _local.replaceKnowledgeTips(
    studentId: studentId,
    subject: subject,
    tips: tips,
  );

  // ===== 每日概念训练流水（只在本机，同知识点提示） =====

  @override
  Future<List<DrillAnswer>> queryDrillAnswers({
    required String studentId,
    int limit = 300,
  }) => _local.queryDrillAnswers(studentId: studentId, limit: limit);

  @override
  Future<void> insertDrillAnswers(List<DrillAnswer> answers) =>
      _local.insertDrillAnswers(answers);

  Future<String?> readLocalSetting(String key) => _local.readLocalSetting(key);

  Future<void> writeLocalSetting(String key, String value) =>
      _local.writeLocalSetting(key, value);

  // ===== 专注计时流水 =====
  //
  // 与知识点提示不同，这份**要上云**：「今天读了多久」换设备也得答得出来。
  static FocusRepository get _focus => _cloud?.focus ?? _local;

  // ===== ima 知识库同步 =====
  //
  // ima 是「云专属」功能：它本身就是把数据推到家长自己的 ima 云端知识库。
  // 没有云端时（纯本地模式）用 [UnconfiguredImaRepository]：状态恒未连接、
  // 连接会明确提示「本地模式不可用」，而不是静默吞掉。
  //
  // 不走 `?? _local`：本地实现里根本没有 ima 这一层（也不该有——它依赖 ima
  // OpenAPI 密钥）。这与其它仓库「本地 / 云端二选一」的范式不同，是刻意的分叉。
  static ImaRepository get ima => _cloud?.ima ?? const UnconfiguredImaRepository();

  /// 每日概念打卡。
  ///
  /// 与 [ima] 同一条理由：题目快照必须存在云端（家长与孩子是两个账号，
  /// 本地库各存一份就永远对不上）。本地模式下明确提示不可用，不伪造数据。
  static CheckinRepository get checkin =>
      _cloud?.checkin ?? const UnavailableCheckinRepository();

  /// 英文阅读。
  ///
  /// 与 [checkin] / [ima] 同一条理由：书、任务、进度必须存在云端 ——
  /// 家长与孩子是两个账号，本地库各存一份就永远对不上。
  static ReadingRepository get reading =>
      _cloud?.reading ?? const UnavailableReadingRepository();

  /// 英语单词打卡的云端部分（词表 / 范围 / 摘要）。
  /// 没连云端时返回全空的仓库而不是抛错：已缓存词表照样能打卡（可选能力规矩）。
  static WordRepository get word {
    final api = _cloud?.api;
    return api != null
        ? HttpWordRepository(api)
        : const UnavailableWordRepository();
  }

  /// 学科范围（家长配一次、出题直接用）。
  ///
  /// 与 [word] 同一口径：没连云端时返回空仓库，页面按「每科未配」渲染；
  /// 写入失败不伪装成功（配置是家长主动点的按钮，正在等结果）。
  static SubjectScopeRepository get subject {
    final api = _cloud?.api;
    return api != null
        ? HttpSubjectScopeRepository(api)
        : const UnavailableSubjectScopeRepository();
  }

  /// 教材（ima 骨架 MD 导入 → 章节 → 出题范围）。
  ///
  /// 与 [subject] 同一口径：没连云端返回空仓库（配置页少一块「教材」），
  /// 导入失败要响亮（家长点了按钮在等结果）。
  static TextbookRepository get textbook {
    final api = _cloud?.api;
    return api != null
        ? HttpTextbookRepository(api)
        : const UnavailableTextbookRepository();
  }

  // ===== 单词打卡的**本机**部分（v32 两表，永不走云端） =====

  Future<void> replaceWordEntries({
    required String studentId,
    required String bookId,
    required List<WordEntry> entries,
  }) =>
      _local.replaceWordEntries(
        studentId: studentId,
        bookId: bookId,
        entries: entries,
      );

  Future<List<WordEntry>> queryWordEntries({
    required String studentId,
    required String bookId,
  }) =>
      _local.queryWordEntries(studentId: studentId, bookId: bookId);

  Future<List<WordQuestion>> queryWordAnswers({
    required String studentId,
    int limit = 300,
  }) =>
      _local.queryWordAnswers(studentId: studentId, limit: limit);

  Future<void> insertWordAnswers(List<WordQuestion> answers) =>
      _local.insertWordAnswers(answers);

  @override
  Future<void> saveFocusSession(FocusSession session) =>
      _focus.saveFocusSession(session);

  @override
  Future<List<FocusSession>> queryFocusSessions({
    required String studentId,
    required String from,
    required String to,
  }) => _focus.queryFocusSessions(studentId: studentId, from: from, to: to);
}
