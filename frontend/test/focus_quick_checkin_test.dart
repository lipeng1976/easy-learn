import 'dart:io';
import 'dart:typed_data';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/focus_session_model.dart';
import 'package:easy_learn_app/models/homework_image_model.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/models/study_plan_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/student/focus_timer_launcher.dart';
import 'package:easy_learn_app/pages/student/focus_timer_page.dart';
import 'package:easy_learn_app/pages/student/tabs/plan_tab.dart';
import 'package:easy_learn_app/pages/student/widgets/focus_timer_entry.dart';
import 'package:easy_learn_app/repositories/focus_repository.dart';
import 'package:easy_learn_app/repositories/homework_repository.dart';
import 'package:easy_learn_app/services/focus_timer_service.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';

/// 临时打卡 + 计划计时的**入口判据**。
///
/// 这两条是这个功能的门面：入口不出现 = 功能不存在，
/// 而这种错在别处的整体测试里极容易被别的文案淹掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MemoryFocus focus;
  late _FakeHomework homeworkRepo;
  late StudentController controller;
  Directory? tempDir;

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

  setUpAll(() async {
    // 库在**整个文件期间**保持打开：`StudentController.onInit` 会自己拉一次
    // 演示数据（未 await 的那一份），若每个用例结束就关库，那次加载会撞上
    // 「database_closed」，而这个报错与被测行为毫无关系。
    tempDir = await setUpTestDatabase();
  });

  tearDownAll(() async {
    final dir = tempDir;
    if (dir != null) await tearDownTestDatabase(dir);
  });

  setUp(() async {
    Get.testMode = true;
    focus = _MemoryFocus();
    homeworkRepo = _FakeHomework();
    Get.put(AuthController()).currentUser.value = UserModel(
      id: 'stu_001',
      name: '林小宇',
      phone: '13800000001',
      role: 'student',
      avatar: '',
    );
    controller = Get.put(
      StudentController(
        aiCheckDelay: Duration.zero,
        homework: homeworkRepo,
        focus: focus,
        imageStorage: _MemoryStorage(),
      ),
    );
    // `onInit` 会自己拉一次演示数据（未 await 的那一份）。这里再等它一次，
    // 是为了让 `homeworkList` 稳定下来 —— 否则用例里刚加进去的作业会被那次
    // 加载**整体替换**掉，而表现是「作业不存在，或不属于当前学生」，
    // 一眼看去完全不像竞争。
    await controller.loadData();
  });

  tearDown(() {
    // 计时器是应用级单例：只 reset，不 dispose（下一个用例还要用）。
    FocusTimerService.instance.reset();
    Get.reset();
  });

  /// 让计时页那次读设置的 I/O 真的跑完。
  ///
  /// 计时页会读一次本机设置（`AppSettings.restReminderMinutes`），而 sqflite 在
  /// fakeAsync 下拿不到真实事件循环 —— 事务停在那儿，它给事务锁挂的那颗 10 秒
  /// `Timer` 也就一直挂着，测试以「A Timer is still pending」收场。
  /// 推进假时钟能把定时器烧掉，但会顺带打出「database has been locked for 10s」；
  /// 让 I/O 真的完成才是干净的了结。
  Future<void> settleDbTimers(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }

  Future<void> pumpPlan(WidgetTester tester) async {
    controller.studyPlans.value = [samplePlan()];
    await tester.pumpWidget(MaterialApp(home: PlanTab()));
    await tester.pump();
    // 计划页现在挂着「今日打卡」那几张卡（2026-11-12 从复习页搬来），
    // 它们各自会读一次本机状态（今日概念训练进度、单词打卡）。sqflite 在
    // fakeAsync 下不推进事务，会把事务锁的 10 秒 Timer 留着，测试以
    // 「A Timer is still pending」收场 —— 必须先让这些 I/O 跑完。
    await settleDbTimers(tester);
  }

  testWidgets('计划页：临时打卡按钮 → 选「阅读」→ 进计时页', (tester) async {
    await pumpPlan(tester);

    expect(find.text('临时打卡 · 记一段时间'), findsOneWidget);
    await tester.tap(find.text('临时打卡 · 记一段时间'));
    await tester.pumpAndSettle();

    expect(find.text('临时打卡 · 记一段时间'), findsNWidgets(2), reason: '选项面板要给出常用标签');
    await tester.tap(find.text('阅读').last);
    await tester.pumpAndSettle();

    // 进了闹钟屏：标签就是刚刚选的那个，脚注说清楚会记到哪儿。
    expect(find.byType(FocusTimerPage), findsOneWidget);
    expect(
      find.text('结束后「阅读」将记入'),
      findsNothing,
      reason: '还没计时时说的是「只有计时中的时间会记入」',
    );
    expect(find.textContaining('阅读'), findsWidgets);
    expect(FocusTimerService.instance.target?.kind, FocusTargetKind.free);
    expect(FocusTimerService.instance.target?.title, '阅读');
    await settleDbTimers(tester);
  });

  testWidgets('计划卡片上有计时入口，点了就是给这个计划计时', (tester) async {
    await pumpPlan(tester);

    final entry = find.byWidgetPredicate(
      (w) => w is FocusTimerEntry && w.targetId == 'plan_read',
    );
    // 计划页顶部现在多了「今日打卡」那四张卡（2026-11-12），计划卡被推到屏外。
    // `ListView` 懒构建：没滚到之前这个 widget 根本不存在，直接 tap 会打空
    //（框架只警告、不报错），于是「点了没反应」看起来像功能没接上。
    await tester.scrollUntilVisible(
      entry,
      320,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(entry, findsOneWidget, reason: '计划页也必须能开计时');
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    final timer = FocusTimerService.instance;
    expect(timer.target?.kind, FocusTargetKind.plan);
    expect(timer.target?.id, 'plan_read');
    await settleDbTimers(tester);
  });

  testWidgets('还有一段计时没结束：先问一句，结束并开始', (tester) async {
    final timer = FocusTimerService.instance;
    final busy = HomeworkItem(
      id: 'hw_busy',
      title: '语文作文',
      subject: '语文',
      imageUrl: '',
      dueAt: DateTime(2026, 10, 20),
      estimatedMinutes: 40,
      actualSeconds: 0,
      status: HomeworkStatus.pending,
      wrongCount: 0,
      aiEnabled: true,
      needsGrading: true,
      userRole: 'student',
      studentId: 'stu_001',
    );
    controller.homeworkList.add(busy);
    // 用刚加进去的那一份，不要用 `first`：演示数据已经把表填满了，
    // `first` 是别人的作业 —— 而保存照样成功，于是错得非常安静。
    timer.start(FocusTarget.homework(busy));

    await tester.pumpWidget(MaterialApp(home: _Host(controller: controller)));
    // 计的是**墙钟差**，而 `pump(Duration)` 推的是 Flutter 的假时钟，
    // `DateTime.now()` 不吃这一套。要让「上一段真的有秒数」只能等真实时间，
    // 而 `testWidgets` 的 body 跑在假异步里 —— 所以外面套一层 `runAsync`。
    // （0 秒是**故意不写库**的：进去看一眼不该在统计里留下一行「0 分钟」。）
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1100)),
    );
    await tester.tap(find.text('开一段临时打卡'));
    await tester.pumpAndSettle();

    expect(find.text('还有一段计时没结束'), findsOneWidget);
    await tester.tap(find.text('结束并开始'));
    await tester.pumpAndSettle();

    // 上一段必须真的被存下来 —— 否则「结束并开始」= 把那段时间扔掉。
    expect(focus.saved, hasLength(1));
    expect(focus.saved.single.kind, FocusTargetKind.homework);
    expect(focus.saved.single.sourceId, 'hw_busy');
    // 新的一段是临时打卡。
    expect(timer.target?.kind, FocusTargetKind.free);
    await settleDbTimers(tester);
  });
}

/// 直接调 `FocusTimerLauncher` 的宿主页（计划页那条路径另有覆盖）。
class _Host extends StatelessWidget {
  const _Host({required this.controller});

  final StudentController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => FocusTimerLauncher.open(
            context,
            controller,
            FocusTarget.free('运动', id: 'free_host'),
          ),
          child: const Text('开一段临时打卡'),
        ),
      ),
    );
  }
}

class _MemoryFocus implements FocusRepository {
  final List<FocusSession> saved = <FocusSession>[];
  Object? error;

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
  }) async => saved;
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
