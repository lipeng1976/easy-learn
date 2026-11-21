import 'package:get/get.dart';

import '../constants/attachment_limits.dart';
import 'notification_controller.dart';
import 'auth_controller.dart';
import 'point_controller.dart';
import '../models/focus_session_model.dart';
import '../models/daily_comment_model.dart';
import '../models/homework_image_batch.dart';
import '../models/homework_image_model.dart';
import '../models/homework_kind.dart';
import '../models/homework_model.dart';
import '../models/homework_photo_draft.dart';
import '../models/notification_model.dart';
import '../models/op_result.dart';
import '../models/photo_usage.dart';
import '../models/point_model.dart';
import '../models/relationship_model.dart';
import '../models/review_model.dart';
import '../models/study_plan_model.dart';
import '../models/study_plan_checkin_model.dart';
import '../models/wish_model.dart';
import '../models/workout_model.dart';
import '../repositories/focus_repository.dart';
import '../repositories/homework_repository.dart';
import '../repositories/notification_repository.dart';
import '../repositories/relationship_repository.dart';
import '../repositories/review_repository.dart';
import '../repositories/study_plan_repository.dart';
import '../repositories/wish_repository.dart';
import '../repositories/workout_repository.dart';
import '../services/ai_data_source.dart';
import '../services/data_api_client.dart';
import '../utils/attachment_summary.dart';
import '../utils/grading_sanity.dart';
import '../utils/homework_feedback_text.dart';
import '../services/database_service.dart';
import '../services/image_storage_service.dart';
import '../services/local_seed_service.dart';
import '../services/simulated_ai_data_source.dart';

class StudentController extends GetxController {
  StudentController({
    this.aiCheckDelay = const Duration(milliseconds: 700),
    ImageStorageService? imageStorage,
    AiDataSource? ai,
    HomeworkRepository? homework,
    ReviewRepository? review,
    RelationshipRepository? relationships,
    WishRepository? wishes,
    StudyPlanRepository? studyPlans,
    WorkoutRepository? workouts,
    NotificationRepository? notifications,
    FocusRepository? focus,
    DateTime Function()? clock,
  }) : imageStorage = imageStorage ?? createImageStorage(),
       ai = ai ?? const SimulatedAiDataSource(),
       _homework = homework ?? DatabaseService.instance,
       _review = review ?? DatabaseService.instance,
       _relationships = relationships ?? DatabaseService.instance,
       _wishes = wishes ?? DatabaseService.instance,
       _studyPlans = studyPlans ?? DatabaseService.instance,
       _workouts = workouts ?? DatabaseService.instance,
       _notifications = notifications ?? DatabaseService.instance,
       _focus = focus ?? DatabaseService.instance,
       _clock = clock ?? DateTime.now;

  /// AI 批改的模拟耗时。测试注入 [Duration.zero] 以免每个用例白等 700ms。
  final Duration aiCheckDelay;

  /// 作业照片的存取。测试注入内存实现，避免依赖平台文件系统。
  final ImageStorageService imageStorage;

  /// AI 能力（一期只用到批改）。
  ///
  /// 默认是本地实现 —— 离线、模型故障、单元测试三种场景都靠它兜底。
  /// 接入云端后换成走自建 Serverless 函数的实现，调用方代码不用动。
  final AiDataSource ai;

  /// 作业与作业照片的存取。**换云端实现时只改构造里那处默认值**，本文件其余不动。
  final HomeworkRepository _homework;

  /// 专注计时流水。
  final FocusRepository _focus;

  /// 注入时钟：判据要能断言「跨天的那一段记在哪一天」。
  final DateTime Function() _clock;

  /// 复习闭环的持久化（错题池 / 组卷 / 作答 / 影子比对）。
  final ReviewRepository _review;

  /// 关系链读取。学生端多处用它解析「当前用户关联的孩子是谁」。
  final RelationshipRepository _relationships;

  /// 心愿：公开墙、确认、归档、积分兑换状态。
  final WishRepository _wishes;

  /// 学习计划与每日打卡。
  final StudyPlanRepository _studyPlans;

  /// 运动计划与运动记录。
  final WorkoutRepository _workouts;

  /// 通知读取（本控制器只用到每日点评那半边）。
  final NotificationRepository _notifications;

  final RxList<HomeworkItem> homeworkList = <HomeworkItem>[].obs;

  /// 当前学生已提交的作业照片（仅本人的，按提交时间排序）。
  final RxList<HomeworkImageModel> homeworkImages = <HomeworkImageModel>[].obs;
  final RxList<WorkoutPlan> workoutPlans = <WorkoutPlan>[].obs;
  final RxList<WorkoutRecord> workoutRecords = <WorkoutRecord>[].obs;
  final RxList<ReviewMistake> mistakes = <ReviewMistake>[].obs;
  final RxList<WishModel> wishes = <WishModel>[].obs;
  final RxList<StudyPlanModel> studyPlans = <StudyPlanModel>[].obs;
  final RxList<StudyPlanCheckin> studyPlanCheckins = <StudyPlanCheckin>[].obs;

  /// 专注计时流水（最近两周）。
  ///
  /// 只留两周：它是「今天 / 本周投入多少」的数据源，再久的记录
  /// 没有任何界面在问，拉多了只是让每次加载多传一批用不上的行。
  final RxList<FocusSession> focusSessions = <FocusSession>[].obs;
  final RxList<DailyCommentModel> dailyComments = <DailyCommentModel>[].obs;

  final RxBool isUploading = false.obs;
  final RxDouble uploadProgress = 0.0.obs;

  /// 学生端底部导航当前页（供首页提示条跳转到计划页）
  final RxInt currentTabIndex = 0.obs;

  @override
  void onInit() {
    super.onInit();
    loadData();
  }

  /// 归属判定：这条数据是不是「当前学生」的。
  ///
  /// **单点**：原来 `loadData` 里一个闭包、`_checkWishReminders` 里又一份
  /// 手写副本（open-items B7 指出的「再复制就是第三份」）。两处规则看似一样，
  /// 但只要有一处后来改了（比如 `stu_001` 空兜底被收紧），另一处就静默地
  /// 筛出不一样的数据集 —— 这种漂移不会报错，只会「某页少了东西」。
  /// 新的按学生过滤的需求一律走这里，不许再复制。
  bool ownsStudent(String studentId) {
    final myId = _currentStudentId;
    return myId.isNotEmpty &&
        (studentId == myId || (myId == 'stu_001' && studentId.isEmpty));
  }

  Future<void> loadData() async {
    // 数据隔离：学生只能看到本人的数据。历史空 studentId 数据兜底归属于 stu_001。
    final isOwn = ownsStudent;
    final myId = _currentStudentId;

    homeworkList.value = (await LocalSeedService.studentHomework())
        .where((item) => isOwn(item.studentId))
        .toList();
    await _loadHomeworkImages(myId);
    workoutPlans.value = (await LocalSeedService.studentWorkoutPlans())
        .where((plan) => isOwn(plan.studentId))
        .toList();
    workoutRecords.value = (await LocalSeedService.studentWorkoutRecords())
        .where((record) => isOwn(record.studentId))
        .toList();
    mistakes.value = (await LocalSeedService.studentMistakes())
        .where((mistake) => isOwn(mistake.studentId))
        .toList();
    wishes.value = (await LocalSeedService.studentWishes())
        .where((wish) => isOwn(wish.studentId))
        .toList();
    studyPlans.value = (await LocalSeedService.studentStudyPlans())
        .where((plan) => isOwn(plan.studentId))
        .toList();
    try {
      studyPlanCheckins.value =
          (await _studyPlans.queryStudyPlanCheckins())
              .where((c) => isOwn(c.studentId))
              .toList();
    } catch (_) {
      studyPlanCheckins.clear();
    }
    try {
      dailyComments.value =
          (await _notifications.queryDailyComments())
              .where((comment) => isOwn(comment.studentId))
              .toList();
    } catch (_) {
      dailyComments.clear();
    }
    await _loadFocusSessions(myId);
    // 积分账本：学生端要在个人信息页和心愿页显示余额，
    // 所以进首页就把它拉好，而不是等用户点进积分页才加载。
    try {
      await _points.loadFor(myId);
    } catch (_) {
      // 账本读不出来不该拦住整个首页 —— 余额显示 0，其余功能照常。
    }
    _checkWishReminders();
  }

  /// 检查心愿预期时间，发送提醒通知
  Future<void> _checkWishReminders() async {
    try {
      final unfulfilled = await _wishes
          .queryUnfulfilledWishes();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final notificationController = Get.find<NotificationController>();

      for (final wish in unfulfilled) {
        if (!ownsStudent(wish.studentId)) continue;
        if (wish.expectedDate == null) continue;
        final expected = DateTime(
          wish.expectedDate!.year,
          wish.expectedDate!.month,
          wish.expectedDate!.day,
        );
        final diff = expected.difference(today).inDays;

        if (diff == 1) {
          // 前一天提醒
          await notificationController.addNotification(
            title: '心愿提醒',
            body: '心愿「${wish.title}」明天就到预期时间了，还没实现哦，加油！',
          );
        } else if (diff == 0) {
          // 当天询问
          await notificationController.addNotification(
            title: '心愿问候',
            body: '心愿「${wish.title}」今天到预期时间了，实现了吗？',
          );
        }
      }
    } catch (_) {}
  }

  void syncDailyComments(List<DailyCommentModel> comments) {
    final uniqueComments = <DailyCommentModel>[];
    final seenIds = <String>{};

    for (final comment in comments) {
      // 归属判定走 [ownsStudent] 单点 —— 这里曾是第三份手写副本。
      if (ownsStudent(comment.studentId) && seenIds.add(comment.id)) {
        uniqueComments.add(comment);
      }
    }

    dailyComments.assignAll(uniqueComments);
  }

  void _safeSnackbar(String title, String message, {Duration? duration}) {
    if (Get.overlayContext == null) return;
    try {
      Get.snackbar(
        title,
        message,
        duration: duration ?? const Duration(seconds: 3),
      );
    } catch (_) {}
  }

  Future<void> _safePersist(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {}
  }

  /// 照片没存上时，追加在那句「提交成功」后面的提示。**必须带原因。**
  ///
  /// 两种失败分开说，因为处置不同：
  /// · `rowsNotRecorded` —— 字节在服务端，但没记进这次作业。学生**本次会话里
  ///   仍看得见**（字节本进程有缓存），但家长看不到、换台设备也看不到。
  ///   不说清楚，它会以「我明明交了照片」的形式回来。
  /// · 其余的按张数报。
  /// 提交结果里跟照片有关的那句「尾巴」。
  ///
  /// 它承载**两件互相独立**的事，所以各自成句：
  ///
  ///   ① **这一次没存下**（失败张数 / 字节上去了但行没记上）—— 要说原因；
  ///   ② **快满了**（`nearLimit`）—— 这次成功了，但下一次很可能就存不下。
  ///
  /// ⚠️ 原来那版是 `if (failures == 0 && !rowsNotRecorded) return '';` ——
  /// 这种「没失败就直接收尾」的写法会让 ② 永远没机会说话。
  /// 这是给这个函数加第二件事时最容易踩的坑：功能看着加了，实际不生效。
  static String _photoNoteText({
    required int failures,
    required bool rowsNotRecorded,
    required String reason,
    required PhotoUsage? usage,
  }) {
    final parts = <String>[];

    if (failures > 0 || rowsNotRecorded) {
      // ⚠️ 两支都必须自带括号。这个尾巴是直接拼在「作业已提交」后面的
      // （`OpResult.success('作业已提交$photoNote')`），缺了括号会读成
      // 「作业已提交照片没能记进这次作业」—— 两句话糊成一句。
      final head = rowsNotRecorded
          ? '（照片没能记进这次作业，其他人暂时看不到）'
          : '（$failures 张照片保存失败）';
      parts.add(reason.isEmpty ? head : '$head：$reason');
    }

    // 「快满了」只在写行**成功**时说：失败时用量压根没变，
    // 这时再加一句关于上限的话，会把「这次为什么失败」绕进去。
    final u = usage;
    if (u != null && u.nearLimit && !rowsNotRecorded) {
      parts.add(
        '（照片已存 ${u.used} / ${u.quota} 张，只剩 ${u.remaining} 张，'
        '删掉一些旧照片可以腾出名额）',
      );
    }

    return parts.join();
  }

  /// 从异常里取「能直接给人看的一句话」。
  ///
  /// 服务端的 `message` 本来就是写给人看的中文 —— 比如照片配额满了那条
  /// 「该学生的照片数量已达上限（已用 N / 上限 N 张，本次还要再加 3 张）。
  /// 删掉一些旧照片再试…」。它比客户端自己编一句「保存失败」有用得多：
  /// **它指了下一步该做什么**。
  ///
  /// ⚠️ **走 `userMessage` 而不是 `message`**（2026-10-06）：上面那段理由只对
  /// **服务端回的文案**成立。`network` / `timeout` 是客户端自己拼的，`message`
  /// 里是 `连不上数据服务（https://…）：ClientException: …` —— 学生的照片存不上
  /// 时看到的就是这串英文。`userMessage` 对服务端文案原样回落，只换这两个 code。
  ///
  /// 取不到就退回空串 —— 提示会少一个原因，但不会因此变成一句假话。
  /// 刻意不用 `toString()`：那个会带上 `[code]` 前缀（见 data_api_client.dart），
  /// 拼进给学生的提示里不合适。
  static String _photoErrorText(Object error) {
    if (error is DataApiException) return error.userMessage.trim();
    // ⚠️ **本地构建**那条路抛的是 `StateError`，不是 `DataApiException`
    // （`local_database_service.dart` 是全仓唯一抛 `StateError` 的地方，
    // 那 16 处的 message 全是写好的中文）。原先只有上面一个分支
    // ⇒ 本地构建下**每一个原因都会被吞掉**，退回调用方的通用文案
    // （「删除失败，请稍后重试」这种）。而它指错方向：人会以为「等一会儿
    // 重试就好」，真实原因却是「这条已经不存在了，该做的是刷新列表」。
    // 2026-09-28 由 `test/homework_delete_test.dart` 的一条用例证伪出来。
    if (error is StateError) return error.message.trim();
    return '';
  }

  // ===== 作业提交与批改链路（需求 5.1） =====

  /// 当前学生可提交的作业（待完成 / 待更正；已完成的补交入口在
  /// 作业卡片上，不走这个列表 —— 它是「待办」语义）。
  List<HomeworkItem> get submittableHomework =>
      homeworkList.where((item) => item.canSubmit).toList();

  /// 今天提交的作业数量。
  int get todaySubmittedCount => homeworkList
      .where((item) => _isSameDay(item.submittedAt, DateTime.now()))
      .length;

  /// 今天提交的作业累计产生的错题数。
  int get todayMistakeCount => homeworkList
      .where((item) => _isSameDay(item.submittedAt, DateTime.now()))
      .fold(0, (sum, item) => sum + item.wrongCount);

  static bool _isSameDay(DateTime? value, DateTime other) {
    if (value == null) return false;
    return value.year == other.year &&
        value.month == other.month &&
        value.day == other.day;
  }

  HomeworkItem? homeworkById(String id) {
    for (final item in homeworkList) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// 某份作业已提交的照片，按批次与批内顺序排列。
  List<HomeworkImageModel> imagesOfHomework(String homeworkId) {
    final list = homeworkImages.where((e) => e.homeworkId == homeworkId).toList()
      ..sort((a, b) {
        final byBatch = a.batchId.compareTo(b.batchId);
        if (byBatch != 0) return byBatch;
        return a.sortOrder.compareTo(b.sortOrder);
      });
    return list;
  }

  /// 某份作业按提交批次分组，最近的批次在前。
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

  Future<void> _loadHomeworkImages(String studentId) async {
    if (studentId.isEmpty) {
      homeworkImages.clear();
      return;
    }
    try {
      homeworkImages.value = await _homework
          .queryHomeworkImages(studentId);
    } catch (_) {
      homeworkImages.clear();
    }
  }

  /// 提交作业（需求 5.1.3）。
  ///
  /// 执行顺序是刻意的：**先落照片 → 再改状态 → 最后跑批改**。
  /// 照片是「孩子确实交了材料」的凭证。哪怕后续批改环节出任何问题，
  /// 家长端也应该能看到这次提交与照片，而不是整条记录回滚成「没交」。
  ///
  /// [needsGrading] 允许在提交这一刻改口径：朗读、背诵这类作业交上来
  /// 就算完成，硬走一遍批改只会得到一份编出来的评语。传 null 表示
  /// 沿用作业上存的那份（学生在录入时定的）。
  Future<OpResult> submitHomework({
    required String homeworkId,
    List<HomeworkPhotoDraft> photos = const <HomeworkPhotoDraft>[],
    bool? needsGrading,
  }) async {
    final index = homeworkList.indexWhere((item) => item.id == homeworkId);
    if (index < 0) return const OpResult.fail('作业不存在，或不属于当前学生');

    final current = homeworkList[index];
    if (current.status == HomeworkStatus.checking) {
      return const OpResult.fail('正在批改中，请稍候再提交');
    }
    // 已完成（finished）**不再拦截** —— 那是补充提交的入口：
    // 多页作业漏了一页，把已完成当成绝对终态，学生就只剩「删掉重录」。
    // 补交与首交同走一条链：旧附件全保留、旧错题清掉、重新批改覆盖旧结果
    // （口径见 HomeworkItem.canSupplement）。并发守卫只挡 checking。

    final studentId = _currentStudentId;
    if (studentId.isEmpty) {
      return const OpResult.fail('未获取到学生身份，请重新登录');
    }

    // 这次到底批不批。三种口径（要批 / 这类不必批 / 批不了）都在这里定死，
    // 后面所有分支只读 [mode]，不再各自组合两个 bool —— 那种写法抄到第三遍
    // 就会有一处漏掉 `aiEnabled`，表现为「点了提交，界面卡在批改中」。
    final grading = needsGrading ?? current.needsGrading;
    final mode = HomeworkGradingMode.of(
      needsGrading: grading,
      aiEnabled: current.aiEnabled,
    );
    final willGrade = mode.willGrade;

    final now = DateTime.now();
    final batchId = 'batch_${now.microsecondsSinceEpoch}';

    // 1. 照片入库
    //
    // 单张存不下不应该毁掉整次提交：能读出来的照片尽量留下，
    // 失败张数如实告诉学生。旧实现里这一步没有任何保护，
    // 存储一报错就整条链路中断，学生点完提交只会看到一个卡住的按钮。
    final saved = <HomeworkImageModel>[];
    var photoFailures = 0;
    // 这次提交里**照片相关的第一句原因**（服务端写好的中文，直接可展示）。
    // 只留第一条：一批照片失败通常是同一个原因，逐条拼起来会长到没人读。
    var photoError = '';
    // 「字节传上去了、但行没记上」—— 它与「传都没传上去」是两件事，
    // 提示语完全不同，所以分开记。
    var rowsNotRecorded = false;
    // 这次写行之后服务端给的用量（**只有写行成功才有**）。
    // 「照片快满了」那句提示用它，见 [_photoNoteText]。
    PhotoUsage? photoUsage;
    if (photos.any((photo) => !photo.isEmpty)) {
      LocalImageStorageService.resetWebPersistFlag();
      var order = 0;
      for (final photo in photos) {
        if (photo.isEmpty) continue;
        // 类型推不出来的附件**在调存储之前**就挡掉，并给一句中文。
        //
        // 放进去再让存储层抛的话，提示会退化成 `$_photoErrorText` 认不出的
        // 形状，学生只看到「保存失败」而不知道是哪个文件、为什么。
        // ⚠️ 图片**不会**走到这里：两个选择器都给照片打上了确定的 MIME
        // （相机与相册出来的就是 JPEG），没有后缀的 blob 名也兜住了。
        final mime = photo.mimeType;
        if (mime == null) {
          photoFailures++;
          if (photoError.isEmpty) {
            photoError = '认不出「${photo.fileName}」是什么文件，已跳过';
          }
          continue;
        }
        try {
          saved.add(
            await imageStorage.saveHomeworkImage(
              studentId: studentId,
              fileName: photo.fileName,
              bytes: photo.bytes,
              homeworkId: homeworkId,
              mimeType: mime,
              batchId: batchId,
              sortOrder: order,
            ),
          );
          order++;
        } catch (e) {
          photoFailures++;
          // ⚠️ 旧实现是 `catch (_) { photoFailures++; }` —— **原因被整段丢掉**：
          // 学生只看到「（3 张照片保存失败）」，不知道是网络、是额度、
          // 还是照片太大。而配额满了是**换一次提交也不会好**的失败，
          // 不给原因，人就只会反复点提交。
          if (photoError.isEmpty) photoError = _photoErrorText(e);
        }
      }
      if (saved.isNotEmpty) {
        // ⚠️ **先落库、拿回服务端那一行，再进内存。**
        //
        // 与 [_insertAndAdopt] 同一条口径，理由也一样：照片行的 `id` 是
        // **唯一的读图键**（`GET /data/homework/images/file?id=`），而服务端
        // `imageRow()` 里写死 `id: newId()` —— 上传时那个 `img_…` 只是本地占位。
        //
        // 沿用占位 id 的症状**没有报错**：字节已经在服务端、行也写进去了，
        // 按那个 id 却查不到这一行 → 缩略图位置一片空白。而且换页签、返回上一页
        // 都不会重拉 `homeworkImages`，只有重登（重走 `queryHomeworkImages`、
        // 那时拿到的才是真 id）才看得见 —— 真机反馈的
        // 「看不到提交的图片，退出登录再进来就可以」正是它。
        //
        // 落库失败就沿用 [saved]：`_safePersist` 的语义是「存不下也别毁掉这次操作」，
        // 而这里比作业那条多一层兜底 —— 字节还留在本进程
        // （`RemoteImageStorageService._recentUploads` 按 `storageKey` 存着，
        // `HomeworkImageReader` 会先命中它），所以本会话内照片仍然看得见。
        var stored = saved;
        // ⚠️ 这一处**刻意不用 `_safePersist`** —— 它 `catch (_) {}`，会把失败整段吞掉。
        //
        // 照片配额上线之前，这里失败基本是网络抖动，吞掉还能辩称
        // 「存不下也别毁掉这次操作」；现在它有了一条**再试也不会好**的失败：
        // 整批超出配额时服务端回 409。
        //
        // 只靠上传那一步的预检挡不住它：预检是**逐张**判的，所以
        // 「每张单看都有额度、合起来超了」这种情况只有到这里才暴露 ——
        // 库里 9999 张、一次交 3 张时，三次上传全都过，写行时才越界。
        // 而吞掉的后果是**「提交成功」+ 照片一张都不在**，
        // 连那句「（n 张照片保存失败）」都不会出现。
        try {
          final result = await _homework.saveHomeworkImages(saved);
          stored = result.images;
          // 用量只有**服务端**说了算（它按这个学生名下的行数判）。
          // 客户端自己数的是「这台设备见过什么」，两者会不同步 ——
          // 拿本地的数去比配额，提示会在不该出现的时候出现。
          //
          // 写行失败时不赋值：那时行没写进去，用量本来就没变，
          // 而 [_photoNoteText] 也只在成功那一侧说「快满了」。
          photoUsage = result.photoUsage;
        } catch (e) {
          rowsNotRecorded = true;
          if (photoError.isEmpty) photoError = _photoErrorText(e);
        }
        homeworkImages.addAll(stored);
        homeworkImages.refresh();
      }
    }
    final photoNote = _photoNoteText(
      failures: photoFailures,
      rowsNotRecorded: rowsNotRecorded,
      reason: photoError,
      usage: photoUsage,
    );

    final allImages = imagesOfHomework(homeworkId);
    // 封面**只认图片**：附件列表里第一个可能是一段录音，拿它当封面会让
    // 家长端渲染一张破图 —— 而破图不报错，只表现为「封面莫名其妙没了」。
    final firstPhotoKeys = allImages
        .where(
          (image) =>
              AttachmentKind.ofMime(image.mimeType) == AttachmentKind.image,
        )
        .map((image) => image.storageKey);
    final firstKey = firstPhotoKeys.isEmpty
        ? current.imageUrl
        : firstPhotoKeys.first;

    // 2. 记录提交时间、确定这次的口径，并清掉上一次的批改结果
    //
    // 不批改的作业**一步到位进「已完成」，不经过「批改中」**：
    // 那个状态会让界面显示「批改中」，而根本没有批改任务在跑 ——
    // 学生只能干等一个不会来的结果。这里的状态就是这次提交的真实终态。
    final working = current.copyWith(
      status: willGrade ? HomeworkStatus.checking : HomeworkStatus.finished,
      needsGrading: grading,
      submittedAt: now,
      submitBatchId: batchId,
      imageCount: allImages.length,
      imageUrl: firstKey,
      wrongCount: 0,
      // 内存侧也要清上一次的结果。不传这个的话，一份刚改完重交、
      // 还在批改中的作业会继续挂着上次的分数（`hasResult` 仍为真）。
      clearResult: true,
      // 来源与结果同生共死：不清的话，重新提交后、批改完成前，
      // 这道题会顶着一个上次留下的「离线参考结果」标记。
      gradingSource: GradingSource.none,
    );
    homeworkList[index] = working;
    homeworkList.refresh();
    await _safePersist(
      () => _homework.updateHomework(
        HomeworkPatch(id: homeworkId)
          ..status = working.status
          ..submittedAt = now
          ..submitBatchId = batchId
          ..imageCount = allImages.length
          ..imageUrl = firstKey
          // 学生这次在提交面板上改过的口径要落库，否则他下次进来
          // 会看到系统把「不批改」又改回了「批改」。
          ..needsGrading = grading
          ..clearResult(),
      ),
    );

    // 2.5 记分：交了就算完成，不等批改结果。
    //
    // 两种口径分值不同，所以按 [willGrade] 选动作 —— 朗读、字帖这类
    // 「交照片即完成」的作业如果和数学卷子给一样的分，等于在告诉孩子
    // 「随便交点东西就行」。
    //
    // 防重键带上 batchId：家长打回、孩子订正后重交是一次新的提交，
    // 应该再记一次分；而同一个 batch 被写两遍（连点、重放）只算一次。
    await _points.award(
      action: willGrade
          ? PointAction.homeworkGraded
          : PointAction.homeworkNoGrading,
      studentId: studentId,
      reason: '提交《${current.title}》',
      idempotencyKey: PointController.homeworkKey(homeworkId, batchId),
      refType: 'homework',
      refId: homeworkId,
      createdBy: studentId,
    );

    // 3. 通知结伴家长：孩子交作业了（家长端「已提交」的来源）
    await _notifyParentsOfSubmission(
      homework: current,
      batchAttachments: saved,
      totalAttachments: allImages,
      mode: mode,
    );

    if (!willGrade) {
      // 两种「不批改」在这里合流，但**文案必须分开**：
      // 「这类作业不必批」是正常的，「AI 没开通」是能力缺失，
      // 家长看到同一句话就再也分不出该不该多问一句。
      //
      // 刻意**不写 checkedAt / score / summary**：这三个共同构成
      // `hasResult`，而「完成了但没批改」与「批改完了」在界面上必须
      // 是两件事。往 summary 里塞一句「本次未批改」会让 hasResult
      // 变成真 —— 家长端的「AI 批改结果」标题下就会出现一句「没有结果」。
      // 「为什么没有批改」由 `gradingMode` 现推，说在它该在的位置。
      final note = mode == HomeworkGradingMode.notRequired
          ? '这类作业交上来就算完成，不需要批改'
          : '当前未开启 AI 批改';
      homeworkList[index] = working.copyWith(wrongCount: 0);
      homeworkList.refresh();
      await _safePersist(
        () => _homework.updateHomework(
          HomeworkPatch(id: homeworkId)..wrongCount = 0,
        ),
      );
      _safeSnackbar('提交成功', '作业已提交，$note$photoNote');
      return OpResult.success('作业已提交$photoNote');
    }

    // 4. AI 批改
    if (aiCheckDelay > Duration.zero) {
      await Future<void>.delayed(aiCheckDelay);
    }
    final result = await ai.checkHomework(
      subject: current.subject,
      title: current.title,
      // 本地实现忽略图片（一期批改是模拟的），云端实现要靠它把照片交给视觉模型。
      //
      // ⚠️ **必须只送图片**。这里原来送的是该作业的**全部**附件 —— 在只有
      // 照片的时候那两件事等价，加上音频/视频之后就不再等价：视觉模型对
      // 不认识的输入是**静默丢弃**的（见 `doc/open-items.md` B29），
      // 结果是「批改结果里那个附件凭空消失」，而不是任何报错。
      //
      // 过滤要发生在**收集**这一步，不能等到上传时再挑：上传器只认
      // storageKey，那时类型信息已经没了。
      imagePaths: allImages
          .where(
            (image) =>
                AttachmentKind.ofMime(image.mimeType) == AttachmentKind.image,
          )
          .map((image) => image.storageKey)
          .toList(),
    );

    // 4.0 照片根本没批成 —— 必须在这里停住，绝不能让这份结果继续往下走。
    //
    // ⚠️ 为什么是「提前返回」而不是「把分数改小」：下面那一整段全部挂在
    // `newMistakes.isEmpty` 上，一条错题都没有时它会连着做四件事 ——
    //   ① 删掉这份作业已有的全部错题（同一份作业重复提交时先清后插）；
    //   ② 把作业置为「已完成」；
    //   ③ 把 `score` 写进作业行；
    //   ④ 发一笔「全对」加分，并通知家长「《X》全对」。
    // 这四件事都建立在「模型看懂了、确认没有错题」这个前提上，而**照片不可读时
    // 这个前提是假的**。实测现网视觉档对纯白页面 6 次里 3 次回
    // `score:100 / items:[]` ⇒ **一张拍空的照片能清空错题库，还能白拿一次「全对」加分**。
    // 只改分数治不了 ①②④，所以只能在入口拦。
    if (GradingSanity.isUnreadable(result)) {
      // 状态回「待完成」：非终态，界面会一直提示他这件事还没做完。
      //
      // ⚠️ **绝不能留在「批改中」** —— 那是「干等一个不会来的结果」，
      // 而这里根本没有批改任务在跑了。
      //
      // `wrongCount` 要显式写回**仍然活着的错题数**：提交那一步在内存里
      // 把它清成了 0（`working`），而库里的行没动过。批改中那种状态只持续
      // 几秒，这个状态可能一直持续到他重拍为止 —— 内存与库长期不一致，
      // 就是「错题本里有、作业上写着 0 道」那类再也说不清的事。
      final surviving = mistakes
          .where((m) => m.homeworkId == homeworkId)
          .length;
      homeworkList[index] = working.copyWith(
        status: HomeworkStatus.pending,
        wrongCount: surviving,
      );
      homeworkList.refresh();
      await _safePersist(
        () => _homework.updateHomework(
          HomeworkPatch(id: homeworkId)
            ..status = HomeworkStatus.pending
            ..wrongCount = surviving,
        ),
      );
      // ⚠️ 返回 `success` 而不是 `fail`：**提交本身是成功的** ——
      // 照片已经传上去了、提交时间已经记了、家长也已经收到「已提交」。
      // 报 fail 会让提交面板留在原地（见 `homework_submit_sheet.dart`），
      // 学生以为没交上、再点一次「确认提交」—— 那会把同一批照片**重复入库**。
      // 文案由调用方那条 snackbar 带出去，这里不再单独弹一次，免得叠成两条。
      return OpResult.success(GradingSanity.unreadableMessage);
    }

    // ⚠️ `var` 而不是 `final`：下面把反悔条目过滤掉之后可能要归一它
    // （见过滤循环之后那一段）。改这一处就够 —— 后面的落库、通知、文案
    // 全都读这一个变量，不必逐个去改，也就不会有漏改的地方。
    var score = result.score;
    final summary = result.summary;

    final newMistakes = <ReviewMistake>[];
    // 模型在错因里当场反悔的那几条，不能进错题库。
    //
    // 实测原话（`doc/open-items.md` B29 的 E 第三条）：错因结尾自己写着
    // 「此条实际不构成错误，请勿计入错题库」、「此条为误判，请以「无错题」处理」、
    // 「等等，让我重新算一下。哎呀，学生算的是对的！」—— **这些字符串照样入库**，
    // 就变成了一道要重做的「错题」。一条一次性输出、没有反省通道的链路里，
    // 模型唯一能收回自己的方式就是在文字里说，所以我们得听得懂。
    //
    // ⚠️ 过滤放在**这个收集点**，而不是入库之前：这里是模型产出的唯一出口，
    // 手工录入（`review_controller`）走的是另一条路，不该被这条判据碰到。
    var retracted = 0;
    for (var i = 0; i < result.items.length; i++) {
      final item = result.items[i];
      if (GradingSanity.isRetracted(item.wrongReason)) {
        retracted++;
        continue;
      }
      // item.knowledgePoint 本身就是知识点名（如「分数计算」），
      // 「作业标题 · 知识点」是展示用的题目名。两者要分开存：
      // 知识点是组卷、讲解、举一反三的驱动键，混进作业标题就再也分不出来了。
      final knowledgePoint = item.knowledgePoint;
      newMistakes.add(
        ReviewMistake(
          // ⚠️ `i` 用的是**原始**下标，不是过滤后的个数：这样 id 只由
          // 「哪一份作业、第几条」决定，与这次过滤掉了几条无关。
          // 用过滤后的下标会让同一条错题在两次批改里拿到不同的 id。
          id: 'rm_${homeworkId}_$i',
          subject: current.subject.isEmpty ? '待确认' : current.subject,
          // `title` 仍然是**展示标签**（列表里一行装不下整道题），
          // 题干单独存 `questionBody`。以前没有这个字段，讲解只好把
          // 标签当题目发出去 —— 模型只能对着「十月月考 · 分数计算」
          // 讲分数计算，讲得笼统是必然的。
          title: '${current.title} · $knowledgePoint',
          questionBody: item.question,
          // 原卷面上的题号：家长要对着作业本找出这道题，只靠知识点找不到。
          // 模型没给就留空，卷面上退化成只显示知识点。
          questionNo: item.questionNo.trim(),
          // 学生写的过程：讲解靠它指出「哪一步就错了」。
          // 空串是常态（选择/填空题），不要为此编造。
          studentProcess: item.studentProcess.trim(),
          // 批改时模型给的标准答案。**只作参考**：实测它会算错，
          // 所以重做卷的答案页仍然走 `referenceAnswersFor` 单独问一次。
          answerKey: item.standardAnswer.trim(),
          originalAnswer: item.originalAnswer,
          wrongReason: item.wrongReason,
          createdAt: now,
          state: ReviewState.pending,
          studentId: studentId,
          homeworkId: homeworkId,
          knowledgePoint: knowledgePoint,
          wrongCount: 1,
          lastWrongAt: now,
          sourceHomeworkTitle: current.title,
          // 来源与归档显式写：`mistakeSourceOf` 的回退能推出 homework，
          // 但推不出「这是几年级的错题」。不写的话，批改来的错题永远
          // 躺在默认筛选里的「未归档」，学生升了学期也翻不出来。
          sourceType: MistakeSource.homework,
          grade: _currentGrade,
          term: _currentTerm,
        ),
      );
    }

    // 过滤掉的是**全部**条目 ⇒ 模型自己复核后说「这些都不是错误」。
    // 那就按契约把它归一成 100：`items` 空就是没有错题，没有错题就不该扣分。
    // 不归一的话会得到「得分 80，全部正确」—— 一句自相矛盾的话，
    // 而这句话是我上面那道过滤新造出来的，所以得在这里收掉。
    //
    // ⚠️ 只在**真的过滤掉过东西**时才归一。不能顺手把「空的错题列表」
    // 一律改成 100 —— 本地兜底（`simulated_ai_data_source`）在无错题时
    // 给的是 96-100，那是模拟实现的有意选择，不在「模型契约」这条线里。
    if (retracted > 0 && newMistakes.isEmpty) score = 100;

    // 同一份作业重复提交时先清掉上一次的错题，避免错题本堆重复条目
    mistakes.removeWhere((m) => m.homeworkId == homeworkId);
    mistakes.refresh();
    await _safePersist(
      () =>
          _review.deleteReviewMistakesByHomeworkId(homeworkId),
    );
    if (newMistakes.isNotEmpty) {
      await _safePersist(
        () => _review.insertReviewMistakes(newMistakes),
      );
      mistakes.insertAll(0, newMistakes);
      mistakes.refresh();
    }

    final status = newMistakes.isEmpty
        ? HomeworkStatus.finished
        : HomeworkStatus.needFix;
    // 来源跟着结果一起落库。
    //
    // 不能在界面上靠 `ai is RemoteAiDataSource` 之类的判断现场推导：
    // 家长看到的是**另一个会话**读出来的这条记录，那边没有这次调用的任何上下文。
    // 来源不落库的话，一份本地模板就会在家长端冒充模型批改结果。
    final gradingSource = result.source.isCloud
        ? GradingSource.cloud
        : GradingSource.local;
    homeworkList[index] = working.copyWith(
      status: status,
      checkedAt: now,
      score: score,
      summary: summary,
      wrongCount: newMistakes.length,
      gradingSource: gradingSource,
    );
    homeworkList.refresh();
    await _safePersist(
      () => _homework.updateHomework(
        HomeworkPatch(id: homeworkId)
          ..status = status
          ..checkedAt = now
          ..score = score
          ..summary = summary
          ..wrongCount = newMistakes.length
          ..gradingSource = gradingSource,
      ),
    );

    // 4.5 全对再加一笔。
    //
    // 口径就是「这次批改没有错题」—— 订正后重交、最终全对走的也是这条路
    // （新的 batchId 就是新的一次），所以不必再单独定义一个「订正完成」，
    // 那需要「原错题都改对了」这种跨批次比对，判不准就会误发分。
    if (newMistakes.isEmpty) {
      await _points.award(
        action: PointAction.homeworkAllCorrect,
        studentId: studentId,
        reason: '《${current.title}》全对',
        idempotencyKey: PointController.homeworkCorrectKey(
          homeworkId,
          batchId,
        ),
        refType: 'homework',
        refId: homeworkId,
        createdBy: studentId,
      );
    }

    await _notifyParentsOfResult(
      homework: current,
      score: score,
      wrongCount: newMistakes.length,
    );
    await _notifySelf(
      title: newMistakes.isEmpty ? '作业已完成' : '作业待更正',
      body: '《${current.title}》得分 $score，错题 ${newMistakes.length} 道。',
      relatedBizId: homeworkId,
    );

    // 规范问题单独说，并且**明确它不计入错题** ——
    // 否则学生看到「有 3 处问题」会以为错题本里多了 3 道题，
    // 而错题本里其实一道都没多，两边对不上以后就再也说不清了。
    //
    // ⚠️ 只报条数等于没提醒：模型给的 `detail` 写着「第 4 题算对了但没写单位 元」，
    // 这才是学生能照着改的东西，所以它要进文案（见 HomeworkFeedbackText）。
    final formatNote = HomeworkFeedbackText.formatIssueNote(result.formatIssues);
    // 丢掉过反悔条目就要说出来：不说的话，学生看到「有 3 道错题已加入错题本」，
    // 打开错题本却只多了 2 道 —— 第一反应是「系统坏了」，而其实是批改写错了。
    final droppedNote =
        retracted > 0 ? GradingSanity.retractedNote(retracted) : '';
    _safeSnackbar(
      newMistakes.isEmpty ? '批改完成' : '需要更正',
      newMistakes.isEmpty
          ? '得分 $score，全部正确。$formatNote$droppedNote$photoNote'
          : '得分 $score，有 ${newMistakes.length} 道错题已加入错题本。'
                '$formatNote$droppedNote$photoNote',
      // 有明细时给足读完的时间：这些提醒一闪而过就白提醒了。
      duration: result.formatIssues.isEmpty && droppedNote.isEmpty
          ? null
          : const Duration(seconds: 8),
    );
    return OpResult.success(
      newMistakes.isEmpty
          ? '批改完成，得分 $score$droppedNote$photoNote'
          : '已批改，得分 $score，待更正 ${newMistakes.length} 道'
                '$droppedNote$photoNote',
    );
  }

  /// 删除某作业已上传的全部附件。
  ///
  /// 只清理附件，不撤销「已提交」这个事实——提交通知已经发给家长了，
  /// 悄悄撤回提交会让家长看到的状态与孩子的操作不一致。
  Future<OpResult> removeHomeworkPhotos(String homeworkId) async {
    final images = imagesOfHomework(homeworkId);
    if (images.isEmpty) return const OpResult.fail('该作业没有已上传的附件');

    for (final image in images) {
      imageStorage.deleteImage(image.storageKey);
    }
    await _safePersist(
      () =>
          _homework.deleteHomeworkImagesByHomeworkId(homeworkId),
    );
    homeworkImages.removeWhere((e) => e.homeworkId == homeworkId);
    homeworkImages.refresh();

    final index = homeworkList.indexWhere((item) => item.id == homeworkId);
    if (index >= 0) {
      homeworkList[index] = homeworkList[index].copyWith(
        imageCount: 0,
        imageUrl: '',
      );
      homeworkList.refresh();
      await _safePersist(
        () => _homework.updateHomework(
          HomeworkPatch(id: homeworkId)
            ..imageCount = 0
            ..imageUrl = '',
        ),
      );
    }
    return const OpResult.success('已删除该作业的全部附件');
  }

  /// 删除一份作业 —— 连同它的照片与它带出来的错题。
  ///
  /// ## 为什么不被「已提交就不能删」挡住
  ///
  /// 触发它的真实场景都在**识别环节**：认错了字（这条作业的内容本身就是错的），
  /// 或者同一份作业被识别了两遍（「今天的数学」录成了两条）。
  /// 后者常常是**提交之后**才发现的 —— 学生看到家长端冒出两条一样的作业，
  /// 而那时手里除了「删照片」没有任何动作可用。
  ///
  /// 代价如实写在确认框里（照片和错题一起消失、已发的积分不追回、
  /// 家长端这条记录也会没），由学生在点之前自己判断，而不是由这里替他拦着。
  ///
  /// ## 为什么先落库、后动内存
  ///
  /// 与 [_insertAndAdopt] 同一条口径（R2：id 只有服务端说了算）。
  /// 反过来（先清内存、再尽力同步）的表现是「界面上没了、刷新之后又回来」——
  /// 而那是最难被当成 bug 报上来的形态：用户会以为自己看错了。
  ///
  /// ⚠️ 服务端删不到（本就不存在、或不在可见集合里）会回 403，这里**如实失败**、
  /// 内存一个字都不动。静默当成功的话，界面显示「已删除」而列表里那条还在。
  Future<OpResult> deleteHomework(String homeworkId) async {
    final index = homeworkList.indexWhere((item) => item.id == homeworkId);
    if (index < 0) return const OpResult.fail('作业不存在，或不属于当前学生');

    final title = homeworkList[index].title;
    final images = imagesOfHomework(homeworkId);
    final mistakeCount =
        mistakes.where((m) => m.homeworkId == homeworkId).length;

    try {
      await _homework.deleteHomework(homeworkId);
    } catch (error) {
      // 复用取原因的那一处：服务端的 message 本来就是写给人看的中文，
      // 比这里自己编一句「删除失败」有用得多（它往往顺带指了下一步）。
      final reason = _photoErrorText(error);
      return OpResult.fail(reason.isEmpty ? '删除失败，请稍后重试' : reason);
    }

    // 落库成功之后才动内存与本机文件 —— 这一步没有回头路，
    // 所以它必须排在「服务端那一行已经删掉了」之后。
    for (final image in images) {
      // ⚠️ 云端模式下这里是空实现（`RemoteImageStorageService.deleteImage`）：
      // 桶里的字节按设计不删（见服务端 `deleteHomework` 的说明），
      // 只有本地模式那份缓存文件会在这里被清掉。
      imageStorage.deleteImage(image.storageKey);
    }
    homeworkList.removeAt(index);
    homeworkList.refresh();
    homeworkImages.removeWhere((e) => e.homeworkId == homeworkId);
    homeworkImages.refresh();
    mistakes.removeWhere((m) => m.homeworkId == homeworkId);
    mistakes.refresh();

    // 提示里带上「连带删掉了什么」：错题是这份作业带出来的，
    // 但学生在错题本里认识的是那些题，不点明他会以为它们还在。
    final tail = mistakeCount > 0 ? '，连同它的 $mistakeCount 道错题' : '';
    return OpResult.success('已删除《$title》$tail');
  }

  /// 改一份作业的**科目 / 内容 / 要不要批改**。
  ///
  /// ## 为什么要有它
  ///
  /// 拍照识别会认错字，而且不是偶发：`练字一张` 被读成 `练习一张`，同一张图
  /// 25 次里错 19 次，语义还通顺到人核对时都会滑过去
  /// （见 `doc/open-items.md` B27）。识别后那张核对表单本来就能改，但学生
  /// 一旦点了「确认保存全部」，之前就**再没有任何补救手段** —— 只能删了重录。
  ///
  /// ## 只写真正改过的字段
  ///
  /// 掩码语义见 [HomeworkPatch]。把「表单里当前的值」整份发上去也能用，
  /// 但那正是服务端要防的整行覆盖：界面手上这份值来自更早的一次读取，
  /// 中途家长端或另一台设备可能改过它 —— 整份上行会把那些改动一起抹掉，
  /// **且不报错**。
  ///
  /// ## 不提供改「预计耗时」
  ///
  /// 服务端的可更新字段表（`PATCH_SPEC`）里**没有 `estimatedMinutes`**
  /// （只有 `needsGrading`），发过去就是 400。宁可界面上先不给这个输入框，
  /// 也不要造一个「改了、看着成功、其实没写」的静默失败。
  /// 补它要先在服务端放行，与标题/科目是同一件事，但会牵出
  /// 「分钟能不能是小数」这条口径（`toInt` 拒小数，而录入路径存的是 `double`）。
  Future<OpResult> updateHomeworkFields({
    required String homeworkId,
    required String title,
    required String subject,
    required bool needsGrading,
  }) async {
    final index = homeworkList.indexWhere((item) => item.id == homeworkId);
    if (index < 0) return const OpResult.fail('作业不存在，或不属于当前学生');

    final item = homeworkList[index];
    final patch = HomeworkPatch(id: homeworkId);
    if (title != item.title) patch.title = title;
    if (subject != item.subject) patch.subject = subject;
    if (needsGrading != item.needsGrading) patch.needsGrading = needsGrading;

    // 一个字都没改就不往返。服务端容忍空掩码（返回空结果），
    // 但仓库契约要求调用方跳过（见 `HomeworkRepository.updateHomework`）。
    if (patch.isEmpty) return const OpResult.success('没有需要保存的改动');

    try {
      await _homework.updateHomework(patch);
    } catch (error) {
      // 与删除同源：服务端的 message 本来就是写给人看的中文，比自编一句
      // 「保存失败」有用。⚠️ 若看到「这些字段不能通过本端点写：title」，
      // 那说明**服务端还没部署这一版** —— 客户端放行了、服务端的老白名单还在拒。
      final reason = _photoErrorText(error);
      return OpResult.fail(reason.isEmpty ? '保存失败，请稍后重试' : reason);
    }

    // 落库成功**之后**才动内存。反过来（先改内存再落库）在服务端拒绝时，
    // 界面会显示一个库里并不存在的「已修改」，而下次刷新它又会变回去 ——
    // 那正是「刚提交的看不到、重登就好」那一族的形态。
    homeworkList[index] = item.copyWith(
      title: title,
      subject: subject,
      needsGrading: needsGrading,
    );
    homeworkList.refresh();
    return OpResult.success('已更新《$title》');
  }

  /// 保存一份作业的**实际用时**（秒）。
  ///
  /// 调用方是专注计时页：暂停、结束、离开页面时各调用一次，写的都是
  /// 「此前记录 + 本次会话」的**总量**（不是增量）。理由见
  /// [HomeworkPatch.actualSeconds] —— 增量在重试下会重复累加，
  /// 而那种错误在界面上只表现为「时间莫名变多了」，没有任何报错。
  ///
  /// ## 为什么先落库、后改内存
  ///
  /// 与 [updateHomeworkFields] 同一条规矩：反过来的话，保存失败（离线、
  /// 服务端还没部署这一版）时界面已经显示了一个库里并不存在的时间，
  /// 刷新之后又变回去 —— 学生只会觉得「计时白做了」。
  ///
  /// ## 失败时保留会话
  ///
  /// 这里**不**清空计时会话，也不吞掉失败：页面拿到 `fail` 会把原因显示出来，
  /// 学生可以再点一次「结束并保存」。静默丢弃是最坏的结果 ——
  /// 一小时的计时会消失得无影无踪。
  Future<OpResult> saveHomeworkActualSeconds({
    required String homeworkId,
    required int seconds,
  }) async {
    final index = homeworkList.indexWhere((item) => item.id == homeworkId);
    if (index < 0) return const OpResult.fail('作业不存在，或不属于当前学生');

    final item = homeworkList[index];
    final value = seconds < 0 ? 0 : seconds;
    if (value == item.actualSeconds) {
      // 什么都没变就不往返。服务端容忍这种空写，但仓库契约要求调用方跳过。
      return const OpResult.success('用时没有变化');
    }

    final patch = HomeworkPatch(id: homeworkId)..actualSeconds = value;
    try {
      await _homework.updateHomework(patch);
    } catch (error) {
      // 服务端的 message 本来就是给人看的中文（「这些字段不能通过本端点写」
      // 这类），比自编一句「保存失败」有用。
      final reason = _photoErrorText(error);
      return OpResult.fail(reason.isEmpty ? '用时没能保存，请稍后重试' : reason);
    }

    homeworkList[index] = item.copyWith(actualSeconds: value);
    homeworkList.refresh();
    return const OpResult.success('用时已记录');
  }

  // ===== 专注计时 =====

  /// 拉最近两周的专注流水。
  ///
  /// 读不出来就**留空**，不拦住首页：专注记录是「今天投入多少」的数据源，
  /// 它缺失时该发生的事是「统计条不显示」，而不是整个学生端起不来。
  Future<void> _loadFocusSessions(String studentId) async {
    if (studentId.isEmpty) {
      focusSessions.clear();
      return;
    }
    final now = _clock();
    final to = focusDateKey(now);
    final from = focusDateKey(now.subtract(const Duration(days: 13)));
    try {
      focusSessions.value = (await _focus.queryFocusSessions(
        studentId: studentId,
        from: from,
        to: to,
      )).where((s) => ownsStudent(s.studentId)).toList();
    } catch (_) {
      focusSessions.clear();
    }
  }

  /// 今天（本地日）的全部流水。
  List<FocusSession> get todayFocusSessions {
    final key = focusDateKey(_clock());
    return focusSessions.where((s) => s.date == key).toList();
  }

  /// 今天一共投入了多少秒。
  int get todayFocusSeconds =>
      todayFocusSessions.fold(0, (sum, s) => sum + s.seconds);

  /// 今天在某个**学习计划**上投入的秒数。
  ///
  /// 计划是按天重复的，所以这里只算今天 —— 拿全部历史去当基数的话，
  /// 「今天读了 20 分钟」会显示成「已投入 8 小时」，而那个数没有意义。
  int todaySecondsForPlan(String planId) => todayFocusSessions
      .where((s) => s.kind == FocusTargetKind.plan && s.sourceId == planId)
      .fold(0, (sum, s) => sum + s.seconds);

  /// 今天的投入按目标分组（标题 → 秒数），按时长从多到少。
  List<({String title, int seconds})> get todayFocusByTitle {
    final buckets = <String, int>{};
    for (final session in todayFocusSessions) {
      buckets[session.title] = (buckets[session.title] ?? 0) + session.seconds;
    }
    final rows = buckets.entries
        .map((e) => (title: e.key, seconds: e.value))
        .toList();
    rows.sort((a, b) => b.seconds.compareTo(a.seconds));
    return rows;
  }

  /// 保存一段专注（检查点 / 暂停 / 结束都走这里）。
  ///
  /// ## 写两处，各答一个问题
  ///
  /// - **作业**：`homework.actualSeconds` 是这份作业的**总数**（幂等覆盖）。
  ///   它回答「这一份一共花了多久」；
  /// - **所有目标**：写一条流水，回答「今天在某个事上花了多久」。
  ///
  /// 两者不冲突：流水的 `seconds` 是**本次会话**的秒数，
  /// 而作业总数 = 历史会话之和 + 本次。
  ///
  /// ## 失败时保留会话
  ///
  /// 与 `saveHomeworkActualSeconds` 同一条规矩：不清会话、不吞失败。
  Future<OpResult> saveFocusProgress({
    required FocusTarget target,
    required String sessionId,
    required int sessionSeconds,
    required int totalSeconds,
    DateTime? startedAt,
  }) async {
    final studentId = _currentStudentId;
    if (studentId.isEmpty) {
      return const OpResult.fail('还没有登录学生身份，用时无法记录');
    }

    // ① 作业：镜像总数（幂等）。
    if (target.kind == FocusTargetKind.homework) {
      final index = homeworkList.indexWhere((item) => item.id == target.id);
      if (index < 0) return const OpResult.fail('作业不存在，或不属于当前学生');

      final item = homeworkList[index];
      final value = totalSeconds < 0 ? 0 : totalSeconds;
      if (value != item.actualSeconds) {
        final patch = HomeworkPatch(id: target.id)..actualSeconds = value;
        try {
          await _homework.updateHomework(patch);
        } catch (error) {
          final reason = _photoErrorText(error);
          return OpResult.fail(
            reason.isEmpty ? '用时没能保存，请稍后重试' : reason,
          );
        }
        homeworkList[index] = item.copyWith(actualSeconds: value);
        homeworkList.refresh();
      }
    }

    // ② 流水：一次会话一行，重复写 = 更新。
    //
    // 会话秒数为 0 时**不写**：那一行只会让「今天读了 0 分钟」出现在统计里，
    // 而学生其实只是进去看了一眼。
    if (sessionSeconds <= 0) return const OpResult.success('还没有可记录的时间');

    final now = _clock();
    final session = FocusSession(
      id: sessionId,
      studentId: studentId,
      kind: target.kind,
      // 临时打卡没有归属对象，`sourceId` 留空而不是拿标签凑：
      // 标签会变（「其它」改叫「阅读」），而 id 是要拿来汇总的。
      sourceId: target.kind == FocusTargetKind.free ? '' : target.id,
      title: target.title,
      date: focusDateKey(now),
      seconds: sessionSeconds,
      startedAt: startedAt ?? now,
      updatedAt: now,
    );
    try {
      await _focus.saveFocusSession(session);
    } catch (error) {
      final reason = _photoErrorText(error);
      return OpResult.fail(reason.isEmpty ? '用时没能保存，请稍后重试' : reason);
    }

    final index = focusSessions.indexWhere((s) => s.id == session.id);
    if (index >= 0) {
      focusSessions[index] = session;
    } else {
      focusSessions.add(session);
    }
    focusSessions.refresh();
    return const OpResult.success('用时已记录');
  }

  Future<void> _notifyParentsOfSubmission({
    required HomeworkItem homework,
    required List<HomeworkImageModel> batchAttachments,
    required List<HomeworkImageModel> totalAttachments,
    required HomeworkGradingMode mode,
  }) async {
    // ⚠️ 这里以前传的是 `saved.length`，配「N 张照片」的量词 ——
    // 孩子只交一个视频时，家长收到的通知是「本次上传 1 张照片」。
    final summary = attachmentSummary(batchAttachments);
    final totalSummary = attachmentSummary(totalAttachments);
    final photoText = summary.isEmpty
        ? '（本次未上传附件）'
        : '，本次上传 $summary'
              '${totalSummary != summary ? '（累计 $totalSummary）' : ''}';
    // 不批改的作业**不能报「正在批改」**：家长会去等一个永远不来的结果，
    // 或者过一会儿问孩子「为什么没有分数」。这行文案是他判断
    // 「要不要等」的唯一依据，所以按口径分开说。
    final tail = switch (mode) {
      HomeworkGradingMode.auto => '正在批改。',
      HomeworkGradingMode.notRequired => '这类作业不需要批改。',
      HomeworkGradingMode.unavailable => '当前未开启 AI 批改。',
    };
    await _notifyParents(
      title: '孩子已提交作业',
      body: '《${homework.title}》已提交$photoText，$tail',
      homeworkId: homework.id,
      studentId: homework.studentId.isEmpty
          ? _currentStudentId
          : homework.studentId,
    );
  }

  Future<void> _notifyParentsOfResult({
    required HomeworkItem homework,
    required int score,
    required int wrongCount,
  }) async {
    await _notifyParents(
      title: wrongCount == 0 ? '作业已完成' : '作业需要更正',
      body: wrongCount == 0
          ? '《${homework.title}》批改完成，得分 $score，全部正确。'
          : '《${homework.title}》批改完成，得分 $score，有 $wrongCount 道错题待更正。',
      homeworkId: homework.id,
      studentId: homework.studentId.isEmpty
          ? _currentStudentId
          : homework.studentId,
    );
  }

  /// 向孩子所有结伴家长定向投递通知。
  ///
  /// 通知必须带 targetUserId。旧实现的通知是全局列表，
  /// 家长端和学生端看到同一份数据，孩子会收到「你的孩子提交了作业」。
  Future<void> _notifyParents({
    required String title,
    required String body,
    required String homeworkId,
    required String studentId,
  }) async {
    if (studentId.isEmpty) return;
    if (!Get.isRegistered<NotificationController>()) return;
    try {
      final relationships = await _relationships.queryRelationships(
        studentId,
      );
      final parentIds = relationships
          .where((r) => r.status == RelationshipStatus.active)
          .map((r) => r.parentId)
          .toSet();
      final controller = Get.find<NotificationController>();
      for (final parentId in parentIds) {
        await controller.addNotification(
          title: title,
          body: body,
          targetUserId: parentId,
          type: NotificationType.homework,
          relatedBizId: homeworkId,
        );
      }
    } catch (_) {
      // 通知投递失败不应影响提交主流程
    }
  }

  Future<void> _notifySelf({
    required String title,
    required String body,
    String relatedBizId = '',
  }) async {
    if (!Get.isRegistered<NotificationController>()) return;
    try {
      await Get.find<NotificationController>().addNotification(
        title: title,
        body: body,
        targetUserId: _currentStudentId,
        type: NotificationType.homework,
        relatedBizId: relatedBizId,
      );
    } catch (_) {}
  }

  /// 当前学生的 id。计时页写流水时要知道记在谁名下。
  String get studentId => _currentStudentId;

  String get _currentStudentId => Get.isRegistered<AuthController>()
      ? Get.find<AuthController>().currentUser.value?.id ?? ''
      : '';

  /// 当前学生的年级 / 学期，写进错题做归档快照。
  ///
  /// 取的是 `currentUser` 上那份**已经加载好**的档案，不再单独发一次查询：
  /// 批改发生在提交作业的同一条路径上，多一次往返只会让「交完作业等半天」。
  /// 取不到就留空（显示为「未归档」）—— 猜一个年级比空着更糟，
  /// 历史错题会被归到错误的学期里，而且再也分辨不出来。
  String get _currentGrade => Get.isRegistered<AuthController>()
      ? Get.find<AuthController>().currentUser.value?.grade ?? ''
      : '';

  String get _currentTerm => Get.isRegistered<AuthController>()
      ? Get.find<AuthController>().currentUser.value?.term ?? ''
      : '';

  /// 积分账本。
  ///
  /// 用 `PointController.to` 而不是 `Get.find` —— 家长端与学生端的动作
  /// 都可能先于积分页发生，取不到实例就把这条分悄悄丢掉，是这里最不能接受的
  /// 失败方式。拿不到就现建一个（`permanent` 的，之后一直是同一个）。
  PointController get _points => PointController.to;

  Future<void> addHomework({
    required String title,
    required String subject,
    required DateTime dueAt,
    double estimatedMinutes = 30,
    // 不给就按类型推（和 [addHomeworks] 同口径）。
    // 这里原来是 `bool needsGrading = true` —— 一个不查类型的写死默认值：
    // 界面走的虽然是 addHomeworks，但谁一调这个方法来加「默写单词」，
    // 就会得到一份「需要批改」的作业，而学生在录入时看到的开关是关的。
    bool? needsGrading,
  }) async {
    final item = HomeworkItem(
      id: 'hw_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      subject: subject,
      imageUrl: '',
      dueAt: dueAt,
      estimatedMinutes: estimatedMinutes,
      status: HomeworkStatus.pending,
      wrongCount: 0,
      aiEnabled: true,
      needsGrading: needsGrading ?? HomeworkKind.of(title).needsGrading,
      userRole: 'student',
      studentId: _currentStudentId,
    );
    // 和 [addHomeworks] 同一个口径：**先拿到最终 id，再进列表**。
    // 先插入的话，列表上会短暂出现一条 id 还没定下来的作业，而在这段窗口里
    // 点进去提交，照片会挂到服务端不认的键上（见 [_insertAndAdopt]）。
    final stored = await _insertAndAdopt(item);
    homeworkList.insert(0, stored);
    homeworkList.refresh();
  }

  /// 落库一条作业，**返回服务端存下来的那一行**（id 可能已被换掉）。
  ///
  /// ## 为什么必须回来取这一行
  ///
  /// 服务端忽略客户端送的 id 并自己生成一个（迁移规则 R2），而作业 id 是
  /// **照片 / 提交 / 批改 / 错题明细**四处共同的关联键。沿用本地 id 的表现
  /// 不是报错，是一串**静默失败**，每一段单独看都「成功」：
  ///
  /// - 拍照上传时 `homeworkId` 用的是这个本地 id → 照片在服务端挂在一份
  ///   **不存在的作业**上，按作业查照片永远是空的（用户看到的就是「照片看不到」）；
  /// - 提交时 `updateHomework` 打到这个本地 id 上 → 服务端 403
  ///   「找不到这份作业」，而 `_safePersist` 把它吞掉 → 界面显示已提交、
  ///   刷新之后回到未提交。
  ///
  /// 只有**真跑一次云端提交**才看得出来 —— 本地模式（id 本来由客户端拼）
  /// 完全正常，单元测试也全绿。这是它一直没被发现的原因。
  ///
  /// ## 调用方的义务
  ///
  /// **先调它、再把返回值放进 `homeworkList`**。反过来的话，列表上会短暂
  /// 出现一条 id 还没定下来的作业，用户在这段窗口里点进去提交，照片就会挂到
  /// 服务端不认的键上 —— 窗口只有一次往返那么宽，但它造成的失败正是上面
  /// 那种最难查的静默失败。判据见 `test/homework_id_adoption_test.dart`。
  ///
  /// 插入失败时如实沿用本地那个 id：`_safePersist` 的语义是「存不下也别毁掉
  /// 这次操作」，这里同理 —— 拿不到服务端的行，本次会话里至少是自洽的。
  Future<HomeworkItem> _insertAndAdopt(HomeworkItem item) async {
    var stored = item;
    await _safePersist(() async {
      stored = await _homework.insertHomework(item, 'student');
    });
    return stored;
  }

  Future<void> addHomeworks(List<Map<String, dynamic>> drafts) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final items = drafts.asMap().entries.map((entry) {
      final draft = entry.value;
      final title = draft['title'] as String;
      return HomeworkItem(
        id: 'hw_${timestamp}_${entry.key}',
        title: title,
        subject: draft['subject'] as String,
        imageUrl: '',
        dueAt: draft['dueAt'] as DateTime,
        estimatedMinutes: (draft['estimatedMinutes'] as num).toDouble(),
        status: HomeworkStatus.pending,
        wrongCount: 0,
        aiEnabled: true,
        // 没显式给就按类型推导，而不是一律「需要批改」：
        // 录入表单里这个开关的初值本来就是这么来的，但**手工录入路径
        // 不经过识别对话框**，那条路上没有开关可点，只能在这里兜。
        needsGrading:
            draft['needsGrading'] as bool? ?? HomeworkKind.of(title).needsGrading,
        userRole: 'student',
        studentId: _currentStudentId,
      );
    }).toList();

    // ⚠️ 顺序是「先落库拿到最终 id，再放进列表」，不能反。
    //
    // 反过来（先进列表、再逐条落库）会留下一段窗口：列表上已经能看见这批作业，
    // 而它们的 id 还是本地拼的。作业 id 是**照片 / 提交 / 批改 / 错题明细**
    // 的共同关联键（见 [_insertAndAdopt]），用户在这段窗口里点进去提交，
    // 照片就挂到了服务端不认的键上 —— 那正是「照片看不到」的成因，
    // 只是窗口比原来更窄、更难查。
    //
    // 代价是保存按钮要多按一次往返，由调用方负责把按钮按住并说明在保存什么
    // （见 `homework_tab.dart` 的 `_saveAll`）。这里不做并发：识别对话框一次
    // 通常只给 1–3 条，而并发会让「列表里哪一条对应服务端哪一行」不可追。
    final stored = <HomeworkItem>[];
    for (final item in items) {
      stored.add(await _insertAndAdopt(item));
    }
    homeworkList.insertAll(0, stored.reversed);
    homeworkList.refresh();
  }

  // 错题的复习闭环（组卷 / 打印 / 回传批改 / 讲解 / 举一反三 / 报告）
  // 全部由 ReviewController 负责，这里只保留「错题池」本身。
  // 池子留在这里是因为它由作业提交流程写入，而复习动作是池子的下游消费者。

  Future<void> addWorkoutRecord({
    required String project,
    required DateTime start,
    required DateTime end,
    int minutes = 0,
    String feedback = '',
    String planId = '',
  }) async {
    final duration = end.difference(start).inMinutes;
    final record = WorkoutRecord(
      id: 'wr_${DateTime.now().millisecondsSinceEpoch}',
      project: project,
      start: start,
      end: end,
      minutes: minutes > 0 ? minutes : duration,
      feedback: feedback,
      planId: planId,
      studentId: _currentStudentId,
    );
    workoutRecords.insert(0, record);
    await _safePersist(
      () => _workouts.insertWorkoutRecord(record),
    );

    // 运动打卡记分。防重键按「同一个计划（或同一个项目）+ 同一天」算 ——
    // 用 recordId 当键等于每次新增都记一次分，孩子连点几下就能刷满。
    // 判定键和 [isWorkoutPlanCheckedIn] 用的是同一套概念（计划 + 当天），
    // 两边不一致的话会出现「界面显示今天已打卡、积分又发了一次」。
    final scope = planId.isEmpty ? project : planId;
    await _points.award(
      action: PointAction.workoutCheckin,
      studentId: record.studentId,
      reason: '运动打卡：$project',
      idempotencyKey: PointController.workoutKey(
        scope,
        studyPlanDateKey(start),
      ),
      refType: 'workout',
      refId: record.id,
      createdBy: record.studentId,
    );

    _safeSnackbar('记录成功', '已新增 $project 运动记录');
  }

  bool isWorkoutPlanCheckedIn(String planId, DateTime day) {
    return workoutRecords.any((r) => r.isSamePlanAndDay(planId, day));
  }

  WorkoutRecord? workoutRecordForPlan(String planId, DateTime day) {
    for (final r in workoutRecords) {
      if (r.isSamePlanAndDay(planId, day)) return r;
    }
    return null;
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
      studentId: _currentStudentId,
    );
    workoutPlans.insert(0, plan);
    await _safePersist(() => _workouts.insertWorkoutPlan(plan));
    _safeSnackbar('计划已创建', '$title 运动计划已添加');
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

  Future<void> confirmWish(String id) async {
    final index = wishes.indexWhere((item) => item.id == id);
    if (index >= 0) {
      wishes[index] = wishes[index].copyWith(studentConfirmed: true);
      await _safePersist(
        () => _wishes.updateWishConfirmation(
          id: id,
          studentConfirmed: true,
        ),
      );

      if (Get.isRegistered<NotificationController>()) {
        Get.find<NotificationController>().addNotification(
          title: '心愿互动',
          body: '学生已确认心愿：${wishes[index].title}',
        );
      }
    }
  }

  Future<void> addWish({
    required String title,
    required String description,
    required bool isPublic,
    DateTime? expectedDate,
  }) async {
    final studentId = Get.isRegistered<AuthController>()
        ? Get.find<AuthController>().currentUser.value?.id ?? ''
        : '';
    final wish = WishModel(
      id: 'w_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      description: description,
      isPublic: isPublic,
      parentConfirmed: false,
      studentConfirmed: false,
      isArchived: false,
      studentId: studentId,
      expectedDate: expectedDate,
    );
    wishes.insert(0, wish);
    await _safePersist(
      () => _wishes.insertWish(wish, 'student'),
    );
    _safeSnackbar('心愿已创建', '心愿「$title」已添加');
  }

  Future<void> archiveWish(String id) async {
    final index = wishes.indexWhere((item) => item.id == id);
    if (index >= 0) {
      final current = wishes[index];
      wishes[index] = current.copyWith(isArchived: true);
      await _safePersist(
        () => _wishes.updateWishArchived(id, true),
      );
      _safeSnackbar('已归档', '心愿「${current.title}」已归档');
    }
  }

  /// 申请用积分兑换心愿。
  ///
  /// **只是登记意向，一分都不扣** —— 扣分发生在家长确认兑现的那一刻。
  /// 先扣再等确认的话，家长一拒绝就成了「分没了、愿望也没实现」，
  /// 这种账孩子记一辈子。
  Future<void> requestWishRedeem(String wishId) async {
    final index = wishes.indexWhere((w) => w.id == wishId);
    if (index < 0) return;
    final wish = wishes[index];
    if (wish.isRedeemed) {
      _safeSnackbar('已经兑现过了', '这个心愿已经兑现完成');
      return;
    }
    if (wish.isRedeemPending) return;

    final now = DateTime.now();
    wishes[index] = wish.copyWith(
      redeemRequestedAt: now,
      clearRedeemRejected: true,
    );
    await _safePersist(
      () => _wishes.updateWishRedeemState(
        id: wishId,
        redeemRequestedAt: now,
        clearRedeemRejected: true,
      ),
    );
    _safeSnackbar(
      '已提交申请',
      wish.needsPoints ? '等家长确认后扣除 ${wish.pointCost} 积分' : '等家长确认兑现',
    );

    if (Get.isRegistered<NotificationController>()) {
      Get.find<NotificationController>().addNotification(
        title: '心愿兑换申请',
        body: wish.needsPoints
            ? '孩子申请兑现「${wish.title}」，需要 ${wish.pointCost} 积分。'
            : '孩子申请兑现「${wish.title}」，不消耗积分。',
        targetUserId: '',
        type: NotificationType.wish,
        relatedBizId: wishId,
      );
    }
  }

  /// 撤回兑换申请。家长还没处理时，孩子可以反悔。
  Future<void> cancelWishRedeem(String wishId) async {
    final index = wishes.indexWhere((w) => w.id == wishId);
    if (index < 0) return;
    final wish = wishes[index];
    if (!wish.isRedeemPending) return;

    wishes[index] = wish.copyWith(clearRedeemRequest: true);
    await _safePersist(
      () => _wishes.updateWishRedeemState(
        id: wishId,
        clearRedeemRequest: true,
      ),
    );
    _safeSnackbar('已撤回', '兑换申请已撤回，积分没有变动');
  }

  Future<void> updateStudyPlanStatus(String id, StudyPlanStatus status) async {
    final index = studyPlans.indexWhere((item) => item.id == id);
    if (index >= 0) {
      final current = studyPlans[index];
      studyPlans[index] = current.copyWith(status: status);
      await _safePersist(
        () => _studyPlans.updateStudyPlanStatus(id, status),
      );

      if (Get.isRegistered<NotificationController>()) {
        final label = status == StudyPlanStatus.active
            ? '学生已确认计划'
            : status == StudyPlanStatus.rejected
            ? '学生已拒绝计划'
            : '学习计划状态更新';
        Get.find<NotificationController>().addNotification(
          title: '学习计划',
          body: '$label：${current.title}',
        );
      }
    }
  }

  Future<void> rejectStudyPlan(String id, {String? reason}) async {
    final index = studyPlans.indexWhere((item) => item.id == id);
    if (index >= 0) {
      final current = studyPlans[index];
      final trimmed = (reason ?? '').trim();
      studyPlans[index] = current.copyWith(
        status: StudyPlanStatus.rejected,
        rejectReason: trimmed,
      );
      await _safePersist(
        () => _studyPlans.updateStudyPlanStatus(
          id,
          StudyPlanStatus.rejected,
          rejectReason: trimmed,
        ),
      );
      if (Get.isRegistered<NotificationController>()) {
        Get.find<NotificationController>().addNotification(
          title: '学习计划',
          body: trimmed.isEmpty
              ? '学生已拒绝计划：${current.title}'
              : '学生已拒绝计划：${current.title}，理由：$trimmed',
        );
      }
    }
  }

  // ===== 学习计划每日打卡 =====

  /// 今天需要执行的已生效计划
  List<StudyPlanModel> get todayPlans {
    final today = DateTime.now();
    return studyPlans
        .where(
          (p) => p.status == StudyPlanStatus.active && p.appliesToDate(today),
        )
        .toList();
  }

  /// 今天待打卡（尚未打卡）的计划数量
  int get todayPendingCheckinCount =>
      todayPlans.where((p) => !isCheckedInToday(p.id)).length;

  /// 今天计划是否已全部打卡
  bool get todayAllCheckedIn =>
      todayPlans.isNotEmpty && todayPendingCheckinCount == 0;

  bool isCheckedInOn(String planId, DateTime date) {
    final key = studyPlanDateKey(date);
    return studyPlanCheckins.any((c) => c.planId == planId && c.date == key);
  }

  bool isCheckedInToday(String planId) => isCheckedInOn(planId, DateTime.now());

  /// 计划已打卡的日期集合
  Set<String> checkinDateKeys(String planId) => studyPlanCheckins
      .where((c) => c.planId == planId)
      .map((c) => c.date)
      .toSet();

  /// 打卡 / 取消今日打卡（误点可撤销）
  Future<void> toggleTodayCheckin(StudyPlanModel plan) async {
    final now = DateTime.now();
    final key = studyPlanDateKey(now);
    final ownerId = plan.studentId.isEmpty ? _currentStudentId : plan.studentId;
    final pointKey = PointController.planKey(plan.id, key);
    final index = studyPlanCheckins.indexWhere(
      (c) => c.planId == plan.id && c.date == key,
    );
    if (index >= 0) {
      studyPlanCheckins.removeAt(index);
      await _safePersist(
        () => _studyPlans.deleteStudyPlanCheckin(plan.id, key),
      );
      // 分也要跟着退。这里用冲正而不是删记录 —— 账本上留下
      // 「发过一笔 + 冲掉一笔」，孩子和家长都能看出发生了什么；
      // 更要紧的是，反复开关不会把分刷上去（净额恒等于一次）。
      await _points.revoke(
        studentId: ownerId,
        idempotencyKey: pointKey,
        reason: '撤销打卡：${plan.title}',
      );
      _safeSnackbar('已撤销', '已取消「${plan.title}」的今日打卡');
      return;
    }

    final checkin = StudyPlanCheckin(
      id: 'spc_${now.millisecondsSinceEpoch}',
      planId: plan.id,
      studentId: ownerId,
      date: key,
      createdAt: now,
    );
    studyPlanCheckins.add(checkin);
    await _safePersist(
      () => _studyPlans.insertStudyPlanCheckin(checkin),
    );
    await _points.award(
      action: PointAction.planCheckin,
      studentId: ownerId,
      reason: '完成今日计划：${plan.title}',
      idempotencyKey: pointKey,
      refType: 'plan',
      refId: plan.id,
      createdBy: ownerId,
    );
    _safeSnackbar('打卡成功', '已完成今日计划：${plan.title}');
    if (Get.isRegistered<NotificationController>()) {
      Get.find<NotificationController>().addNotification(
        title: '学习计划打卡',
        body: '学生已完成今日计划：${plan.title}',
      );
    }
  }

}
