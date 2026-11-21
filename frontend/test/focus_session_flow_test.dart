import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/focus_session_model.dart';
import 'package:easy_learn_app/models/homework_image_model.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/models/study_plan_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/repositories/focus_repository.dart';
import 'package:easy_learn_app/repositories/homework_repository.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 专注计时的**保存口径**。
///
/// 这份数据要回答两个不同的问题，所以落两处：
///   · 作业：`actualSeconds` 是这份作业的**总数**（幂等覆盖）；
///   · 所有目标：一条流水，回答「今天在某个事上花了多久」。
///
/// 判据盯的是「两条路径各自不会串味」：
///   ① 流水写的是**本次会话**的秒数，不是总数（否则今天读 20 分钟会记成
///      「已累计 8 小时」）；
///   ② 作业的镜像才是总数；
///   ③ 计划只写流水（它没有「总数」这个概念 —— 它是按天重复的）；
///   ④ 临时打卡的 `sourceId` 必须是空的（标签会变，不能拿来汇总）。
void main() {
  late _Clock clock;
  late _MemoryFocus focus;
  late _FakeHomework homeworkRepo;
  late StudentController controller;

  HomeworkItem sampleHomework(int actualSeconds) => HomeworkItem(
        id: 'hw_1',
        title: '数学练习册 P28',
        subject: '数学',
        imageUrl: '',
        dueAt: DateTime(2026, 10, 20),
        estimatedMinutes: 30,
        actualSeconds: actualSeconds,
        status: HomeworkStatus.pending,
        wrongCount: 0,
        aiEnabled: true,
        needsGrading: true,
        userRole: 'student',
        studentId: 'stu_001',
      );

  StudyPlanModel samplePlan() => StudyPlanModel(
        id: 'plan_read',
        title: '每天阅读 20 分钟',
        content: '读完一章',
        startAt: DateTime(2026, 10, 1),
        endAt: DateTime(2026, 12, 31),
        type: '阅读',
        status: StudyPlanStatus.active,
        studentId: 'stu_001',
      );

  setUp(() {
    Get.testMode = true;
    clock = _Clock();
    focus = _MemoryFocus();
    homeworkRepo = _FakeHomework();
    Get.put(AuthController()).currentUser.value = UserModel(
      id: 'stu_001',
      name: '林小宇',
      phone: '13800000001',
      role: 'student',
      avatar: '',
    );
    controller = StudentController(
      aiCheckDelay: Duration.zero,
      homework: homeworkRepo,
      focus: focus,
      imageStorage: _MemoryStorage(),
      clock: clock.call,
    )..homeworkList.add(sampleHomework(0));
  });

  tearDown(() => Get.reset());

  test('作业：镜像写总数，流水写本次会话', () async {
    final result = await controller.saveFocusProgress(
      target: FocusTarget.homework(controller.homeworkList.first),
      sessionId: 'fs_1',
      sessionSeconds: 754,
      totalSeconds: 754,
      startedAt: clock.call(),
    );

    expect(result.ok, isTrue, reason: result.message);
    // ① 作业卡片上那个数 = 总数
    expect(homeworkRepo.patches.last.toMap()['actualSeconds'], 754);
    // ② 流水里是本次会话的秒数，不是总数
    expect(focus.saved.single.seconds, 754);
    expect(focus.saved.single.kind, FocusTargetKind.homework);
    expect(focus.saved.single.sourceId, 'hw_1');
  });

  test('作业：第二次保存，镜像累加、流水仍是本次（不是翻倍）', () async {
    controller.homeworkList[0] = sampleHomework(754);
    await controller.saveFocusProgress(
      target: FocusTarget.homework(controller.homeworkList.first),
      sessionId: 'fs_1',
      sessionSeconds: 754,
      totalSeconds: 754,
      startedAt: clock.call(),
    );
    // 同一个会话再写一个检查点（学生的这一次变成 800 秒）
    await controller.saveFocusProgress(
      target: FocusTarget.homework(controller.homeworkList.first),
      sessionId: 'fs_1',
      sessionSeconds: 800,
      totalSeconds: 800,
      startedAt: clock.call(),
    );

    expect(homeworkRepo.patches.last.toMap()['actualSeconds'], 800);
    expect(focus.saved, hasLength(1), reason: '同一次会话只能有一行');
    expect(focus.saved.single.seconds, 800);

    // 新开一次会话：这次 100 秒，总数应该是 800 + 100。
    await controller.saveFocusProgress(
      target: FocusTarget.homework(controller.homeworkList.first),
      sessionId: 'fs_2',
      sessionSeconds: 100,
      totalSeconds: 900,
      startedAt: clock.call(),
    );
    expect(homeworkRepo.patches.last.toMap()['actualSeconds'], 900);
    expect(focus.saved, hasLength(2));
    expect(focus.saved.last.seconds, 100, reason: '第二条流水是这一次的 100 秒');
  });

  test('计划：只写流水，且基数只算今天', () async {
    // 昨天的流水不该进「今天」
    await focus.seed(
      FocusSession(
        id: 'fs_yest',
        studentId: 'stu_001',
        kind: FocusTargetKind.plan,
        sourceId: 'plan_read',
        title: '每天阅读 20 分钟',
        date: '2026-10-18',
        seconds: 3600,
        startedAt: DateTime(2026, 10, 18, 20),
        updatedAt: DateTime(2026, 10, 18, 20, 30),
      ),
    );
    controller.focusSessions.value = await focus.queryFocusSessions(
      studentId: 'stu_001',
      from: '2026-10-18',
      to: '2026-10-19',
    );

    expect(
      controller.todaySecondsForPlan('plan_read'),
      0,
      reason: '昨天的投入不能算进今天的基数',
    );

    final result = await controller.saveFocusProgress(
      target: FocusTarget.plan(samplePlan()),
      sessionId: 'fs_today',
      sessionSeconds: 1200,
      totalSeconds: 1200,
      startedAt: clock.call(),
    );
    expect(result.ok, isTrue);
    expect(
      controller.todaySecondsForPlan('plan_read'),
      1200,
      reason: '今天读了 20 分钟，就该显示 20 分钟',
    );
    // 计划不该动任何作业字段
    expect(homeworkRepo.patches, isEmpty);
  });

  test('临时打卡：sourceId 留空，记在今天的标签下', () async {
    final result = await controller.saveFocusProgress(
      target: FocusTarget.free('阅读', id: 'free_1'),
      sessionId: 'fs_free',
      sessionSeconds: 900,
      totalSeconds: 900,
      startedAt: clock.call(),
    );
    expect(result.ok, isTrue);
    final row = focus.saved.single;
    expect(row.kind, FocusTargetKind.free);
    expect(row.sourceId, isEmpty, reason: '标签会改，不能拿来当汇总键');
    expect(row.title, '阅读');
    expect(row.date, '2026-10-19');
    expect(controller.todayFocusSeconds, 900);
    expect(controller.todayFocusByTitle.single.title, '阅读');
  });

  test('空标签归一到「其它」', () async {
    await controller.saveFocusProgress(
      target: FocusTarget.free('   ', id: 'free_2'),
      sessionId: 'fs_blank',
      sessionSeconds: 60,
      totalSeconds: 60,
      startedAt: clock.call(),
    );
    expect(focus.saved.single.title, '其它');
  });

  test('没有可记录的时间（0 秒）不写库', () async {
    final result = await controller.saveFocusProgress(
      target: FocusTarget.free('阅读', id: 'free_3'),
      sessionId: 'fs_zero',
      sessionSeconds: 0,
      totalSeconds: 0,
      startedAt: clock.call(),
    );
    expect(result.ok, isTrue, reason: '进去看一眼不该报错');
    expect(focus.saved, isEmpty, reason: '「今天阅读 0 分钟」进了统计只会误导');
  });

  test('写失败：如实返回失败，不吞', () async {
    focus.error = StateError('网络断了');
    final result = await controller.saveFocusProgress(
      target: FocusTarget.free('运动', id: 'free_4'),
      sessionId: 'fs_err',
      sessionSeconds: 300,
      totalSeconds: 300,
      startedAt: clock.call(),
    );
    expect(result.ok, isFalse);
    expect(result.message, isNotEmpty);
  });
}

class _Clock {
  DateTime _now = DateTime(2026, 10, 19, 20, 30);
  DateTime call() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

class _MemoryFocus implements FocusRepository {
  final List<FocusSession> saved = <FocusSession>[];
  Object? error;

  Future<void> seed(FocusSession session) async => saved.add(session);

  @override
  Future<void> saveFocusSession(FocusSession session) async {
    final e = error;
    if (e != null) throw e;
    final index = saved.indexWhere((s) => s.id == session.id);
    if (index >= 0) {
      saved[index] = session;
    } else {
      saved.add(session);
    }
  }

  @override
  Future<List<FocusSession>> queryFocusSessions({
    required String studentId,
    required String from,
    required String to,
  }) async =>
      saved
          .where((s) =>
              s.studentId == studentId &&
              s.date.compareTo(from) >= 0 &&
              s.date.compareTo(to) <= 0)
          .toList();
}

class _FakeHomework implements HomeworkRepository {
  final List<HomeworkPatch> patches = <HomeworkPatch>[];

  @override
  Future<void> updateHomework(HomeworkPatch patch) async => patches.add(patch);

  @override
  Future<List<HomeworkItem>> queryHomework(String userRole) => _unused();

  @override
  Future<List<HomeworkItem>> queryHomeworkByStudentIds(List<String> ids) =>
      _unused();

  @override
  Future<HomeworkItem> insertHomework(HomeworkItem item, String userRole) =>
      _unused();

  @override
  Future<List<HomeworkImageModel>> saveHomeworkImage(
    HomeworkImageModel image,
  ) => _unused();

  @override
  Future<SavedHomeworkImages> saveHomeworkImages(
    List<HomeworkImageModel> images,
  ) => _unused();

  @override
  Future<List<HomeworkImageModel>> queryHomeworkImages(String studentId) =>
      _unused();

  @override
  Future<List<HomeworkImageModel>> queryHomeworkImagesByHomeworkId(
    String homeworkId,
  ) => _unused();

  @override
  Future<void> deleteHomework(String id) => _unused();

  @override
  Future<void> deleteHomeworkImagesByHomeworkId(String homeworkId) => _unused();

  @override
  Future<int> countHomeworkImages(String homeworkId) => _unused();
}

class _MemoryStorage implements ImageStorageService {
  @override
  void deleteImage(String storageKey) {}

  @override
  Uint8List? readImage(String storageKey) => null;

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
  }) => _unused();
}

Never _unused() =>
    throw UnimplementedError('这个替身只实现 updateHomework —— 走到这里说明调用方多做了什么');
