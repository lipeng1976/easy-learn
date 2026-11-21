import 'package:easy_learn_app/controllers/checkin_entry_state.dart';
import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/models/checkin_models.dart';
import 'package:easy_learn_app/models/study_plan_model.dart';
import 'package:easy_learn_app/models/workout_model.dart';
import 'package:easy_learn_app/pages/parent/plans_archive_page.dart';
import 'package:easy_learn_app/pages/parent/tabs/plans_tab.dart';
import 'package:easy_learn_app/repositories/checkin_repository.dart';
import 'package:easy_learn_app/services/cloud_runtime.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 家长「计划」页的收拢判据。
///
/// 原来所有计划（含已完成、已暂停）都平铺成大卡片，计划一多页面就越滚越长。
/// 现在主列表只留进行中的，其余收进底部一行小框，点进去才看明细。
///
/// 守的是**分配关系**，不是文案：
///   ① 已结束的卡不能还留在主列表（否则等于没改）；
///   ② 小框的计数必须等于已结束的条数（对不上就是口径漏了状态）；
///   ③ 点小框真能进到详情页，且详情页按状态分了段。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ParentController controller;

  setUp(() {
    DatabaseService.useCloudRuntime(
      CloudRuntime(config: const DataConfig(baseUrl: 'http://127.0.0.1:8788')),
    );
    Get.put(CheckinEntryState(repository: _NeverCheckedinRepo()));
    controller = _SilentParentController();
    controller.selectedStudentId.value = 'stu_001';
    Get.put<ParentController>(controller);
  });

  tearDown(() {
    DatabaseService.useCloudRuntime(null);
    Get.reset();
  });

  StudyPlanModel study(String id, String title, StudyPlanStatus status) =>
      StudyPlanModel(
        id: id,
        title: title,
        content: '每天 20 分钟',
        startAt: DateTime(2026, 11, 1),
        endAt: DateTime(2026, 12, 31),
        type: '背诵',
        status: status,
        studentId: 'stu_001',
      );

  WorkoutPlan workout(String id, String title, {required bool active}) =>
      WorkoutPlan(
        id: id,
        title: title,
        project: '跳绳',
        weekdays: const ['一', '三', '五'],
        targetMinutes: 15,
        isActive: active,
        studentId: 'stu_001',
      );

  Future<void> pumpTab(WidgetTester tester) async {
    // 出题卡 + 两张卡 + 小框：默认 800×600 装不下，ListView 懒构建会
    // 把底部小框判成「不存在」（与 parent_plans_tab_test 同族坑）。
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: PlansTab())),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('已结束的计划不占主列表，只在底部小框里计数', (tester) async {
    controller.studyPlans.assignAll([
      study('sp_1', '待确认的背诵计划', StudyPlanStatus.pendingStudentConfirm),
      study('sp_2', '已经完成的阅读计划', StudyPlanStatus.completed),
    ]);
    controller.workoutPlans.assignAll([
      workout('wp_1', '进行中的跳绳', active: true),
      workout('wp_2', '已暂停的跑步', active: false),
    ]);
    await pumpTab(tester);

    // ① 两张已结束的卡都不该在主列表里。
    expect(find.text('已经完成的阅读计划'), findsNothing);
    expect(find.text('已暂停的跑步'), findsNothing);
    // 进行中的两张还在。
    expect(find.text('待确认的背诵计划'), findsOneWidget);
    expect(find.text('进行中的跳绳'), findsOneWidget);

    // ② 主列表标题按「进行中」计数。
    expect(find.text('进行中的计划'), findsOneWidget);
    expect(find.text('2 项'), findsNWidgets(2), reason: '进行中 2 项 + 已结束 2 项');

    // ③ 小框按状态拆开写。
    expect(find.text('已结束 · 已完成 1 · 已暂停 1'), findsOneWidget);
  });

  testWidgets('点小框进详情页，按状态分段并能恢复已暂停的运动计划', (tester) async {
    controller.studyPlans.assignAll([
      study('sp_1', '待确认的背诵计划', StudyPlanStatus.pendingStudentConfirm),
      study('sp_2', '已经完成的阅读计划', StudyPlanStatus.completed),
    ]);
    controller.workoutPlans.assignAll([
      workout('wp_1', '进行中的跳绳', active: true),
      workout('wp_2', '已暂停的跑步', active: false),
    ]);
    await pumpTab(tester);

    await tester.tap(find.text('已结束 · 已完成 1 · 已暂停 1'));
    await tester.pumpAndSettle();

    expect(find.text('已结束的计划'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('已暂停'), findsOneWidget);
    expect(find.text('已经完成的阅读计划'), findsOneWidget);
    expect(find.text('已暂停的跑步'), findsOneWidget);
    // 详情页不重复显示进行中的计划。
    expect(find.text('待确认的背诵计划'), findsNothing);
    // 暂停的计划在主列表已经看不到，详情页必须留恢复入口。
    expect(find.text('恢复计划'), findsOneWidget);
  });

  testWidgets('一条已结束都没有时，小框整个不出现', (tester) async {
    controller.studyPlans.assignAll([
      study('sp_1', '待确认的背诵计划', StudyPlanStatus.pendingStudentConfirm),
    ]);
    controller.workoutPlans.assignAll([
      workout('wp_1', '进行中的跳绳', active: true),
    ]);
    await pumpTab(tester);

    expect(find.textContaining('已结束 · '), findsNothing);
    expect(find.byIcon(Icons.inventory_2_outlined), findsNothing);
  });

  testWidgets('全部已结束：说「没有进行中的计划」，不能说自己「还没有任何计划」', (tester) async {
    controller.studyPlans.assignAll([
      study('sp_2', '已经完成的阅读计划', StudyPlanStatus.completed),
    ]);
    await pumpTab(tester);

    expect(find.textContaining('没有进行中的计划'), findsOneWidget);
    expect(find.textContaining('还没有任何计划'), findsNothing);
    expect(find.text('已结束 · 已完成 1'), findsOneWidget);
  });

  testWidgets('详情页单独打开（不经过列表）也是同样分段', (tester) async {
    controller.studyPlans.assignAll([
      study('sp_2', '已经完成的阅读计划', StudyPlanStatus.completed),
      study('sp_3', '被拒绝的写作计划', StudyPlanStatus.rejected),
    ]);
    controller.workoutPlans.assignAll([
      workout('wp_2', '已暂停的跑步', active: false),
    ]);

    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const GetMaterialApp(home: PlansArchivePage()));
    await tester.pumpAndSettle();

    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('已暂停'), findsOneWidget);
    expect(find.text('已拒绝'), findsOneWidget);
    expect(find.text('已撤回'), findsNothing, reason: '没有的段落不该出现');
  });
}

/// 只把 `loadData()` 空掉的家长控制器：版面测试不需要它真去读库 / 连服务。
class _SilentParentController extends ParentController {
  @override
  Future<void> loadData() async {}
}

/// 永远「今天还没做」：出题卡按未完成渲染，版面测试够用。
class _NeverCheckedinRepo implements CheckinRepository {
  @override
  Future<List<CheckinSubjectSummary>> subjectSummaries({String? studentId}) async =>
      const <CheckinSubjectSummary>[];

  @override
  Future<CheckinQuizPage> getQuizzes({
    String? studentId,
    CheckinQuizStatus status = CheckinQuizStatus.all,
    String subject = '',
    int limit = 0,
    int offset = 0,
  }) async => CheckinQuizPage.empty;

  @override
  Future<List<CheckinSeed>> loadSeeds({String? studentId, String? subject}) async =>
      const [];

  @override
  Future<CheckinQuiz> generate({
    String? studentId,
    required String quizDate,
    String subject = '数学',
    int count = 5,
    List<String> knowledgePoints = const [],
    String difficulty = '',
  }) => throw UnimplementedError();

  @override
  Future<CheckinSubmitResult> submit({
    required String quizId,
    required Map<int, String> picked,
  }) => throw UnimplementedError();
}
