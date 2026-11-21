import 'package:easy_learn_app/constants/app_colors.dart';
import 'package:easy_learn_app/controllers/checkin_entry_state.dart';
import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/models/checkin_models.dart';
import 'package:easy_learn_app/models/study_plan_model.dart';
import 'package:easy_learn_app/models/workout_model.dart';
import 'package:easy_learn_app/pages/parent/tabs/plans_tab.dart';
import 'package:easy_learn_app/repositories/checkin_repository.dart';
import 'package:easy_learn_app/services/cloud_runtime.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 家长「计划」页的版面判据。
///
/// 这一页 2026-10-27 重排过一次：原来上半是「学习计划」一大段（标题 + 按钮 +
/// 列表），下半是「运动计划」一大段（标题 + 按钮 + 列表），同一个动作在同一屏
/// 出现两次、长得还不一样。现在合成三段：**出题 → 新建（两个并排按钮）→ 列表**。
///
/// 守的是「版面关系」，不是「文案对不对」：
///   ① 出题区必须在**最上面**（用纵坐标比，不是「存在」—— 存在但排在最下面
///      等于没改）；
///   ② 两个新建按钮并排且都在；
///   ③ 两类计划的卡片底色必须**不同**（合在一个列表后，这是唯一的类型线索）；
///   ④ 一个计划都没有时要有空态，不能只剩两个按钮。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ParentController controller;

  /// 出题卡只在云模式渲染（题目快照必须存在服务端），所以这里开一个假云运行时。
  ///
  /// ⚠️ 它只是让 `isCloud` 为真，**不能**让 `ParentController.onInit` 的
  /// `loadData()` 真去连它 —— 那会在这个用例背后发一串 HTTP，测试跑完了请求
  /// 还在飞（实测报 "This test failed after it had already completed"）。
  /// 所以下面用 `_SilentParentController` 把 `loadData` 空掉：这一页要的是版面，
  /// 列表数据由用例自己 assign。
  setUp(() {
    DatabaseService.useCloudRuntime(
      CloudRuntime(config: const DataConfig(baseUrl: 'http://127.0.0.1:8788')),
    );
    // 出题卡会拉「今天做完了吗」的状态；不预注入的话它拿 HTTP 实现真去连
    // 127.0.0.1:8788（见 checkin_entry_card_test 的教训）。
    Get.put(CheckinEntryState(repository: _NeverCheckedinRepo()));
    controller = _SilentParentController();
    // 先设孩子再注册：`onInit` 里挂了 `ever(selectedStudentId)`，
    // 注册后再改会去拉积分（`PointController.to`），与本页无关。
    controller.selectedStudentId.value = 'stu_001';
    Get.put<ParentController>(controller);
  });

  tearDown(() {
    DatabaseService.useCloudRuntime(null);
    Get.reset();
  });

  StudyPlanModel studyPlan() => StudyPlanModel(
    id: 'sp_1',
    title: '每天背 20 个单词',
    content: '睡前用词表过一遍',
    startAt: DateTime(2026, 10, 1),
    endAt: DateTime(2026, 12, 31),
    type: '背诵',
    // 待学生确认：这条分支只有「撤回计划」一个按钮，
    // 不牵动 `PlanExecutionSection`（它要读打卡记录）。
    status: StudyPlanStatus.pendingStudentConfirm,
    studentId: 'stu_001',
  );

  WorkoutPlan workoutPlan() => WorkoutPlan(
    id: 'wp_1',
    title: '晚饭后跳绳',
    project: '跳绳',
    weekdays: const ['一', '三', '五'],
    targetMinutes: 15,
    isActive: true,
    studentId: 'stu_001',
  );

  Future<void> pumpTab(WidgetTester tester) async {
    // ⚠️ 默认视口 800×600 装不下这一段（出题卡 + 两个按钮 + 两张卡），
    // 而 `ListView` 只构建可见区域 —— 运动卡会被判成「不存在」，
    // 看着像颜色没生效。视口必须放大（B23 同族）。
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: PlansTab())),
    );
    await tester.pumpAndSettle();
  }

  /// `_PlanTile` 的底色 = 类型色 8% 叠在白卡上（与线上代码同一个算式）。
  Color tileColor(Color accent) =>
      Color.alphaBlend(accent.withValues(alpha: 0.08), AppColors.card);

  Finder coloredTile(Color color) => find.byWidgetPredicate(
    (w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration! as BoxDecoration).color == color,
  );

  testWidgets('出题区在最上面，两个新建按钮并排，两类卡底色不同', (tester) async {
    controller.studyPlans.assignAll([studyPlan()]);
    controller.workoutPlans.assignAll([workoutPlan()]);
    await pumpTab(tester);

    // ① 出题区在新建按钮**上方**（纵坐标比较，比「找到过」强得多）。
    // 2026-11-12 起这一块是两段式（学科范围 / 今天出什么），
    // 用「今天练什么」这个分段标题当锚点：它没了，说明整块被挪走了。
    final checkinY = tester.getTopLeft(find.text('今天练什么')).dy;
    final newStudyY = tester.getTopLeft(find.text('新建学习计划')).dy;
    expect(
      checkinY,
      lessThan(newStudyY),
      reason: '出题区应该在最上面，实际它在新建按钮下面',
    );

    // ② 两个按钮并排：同一行（纵坐标相同），且学习在左。
    expect(find.text('新建学习计划'), findsOneWidget);
    expect(find.text('新建运动计划'), findsOneWidget);
    final studyBtn = tester.getTopLeft(find.text('新建学习计划'));
    final workoutBtn = tester.getTopLeft(find.text('新建运动计划'));
    expect(studyBtn.dy, workoutBtn.dy, reason: '两个新建按钮不在同一行');
    expect(studyBtn.dx, lessThan(workoutBtn.dx));

    // ③ 两类卡的颜色必须不一样 —— 合在一个列表后，这是唯一的类型线索。
    expect(
      coloredTile(tileColor(AppColors.primary)),
      findsOneWidget,
      reason: '学习计划卡没按蓝色底渲染',
    );
    expect(
      coloredTile(tileColor(AppColors.warning)),
      findsOneWidget,
      reason: '运动计划卡没按橙色底渲染',
    );

    // 列表两条都在（同一个列表里，不分两段）。
    expect(find.text('每天背 20 个单词'), findsOneWidget);
    expect(find.text('晚饭后跳绳'), findsOneWidget);
    expect(find.text('2 项'), findsOneWidget);
  });

  testWidgets('没有任何计划时给空态，而不是只剩两个按钮', (tester) async {
    await pumpTab(tester);

    expect(find.textContaining('还没有任何计划'), findsOneWidget);
    // 空态也得看到新建入口 —— 文案就是「先在上面选一个」。
    expect(find.text('新建学习计划'), findsOneWidget);
    expect(find.text('新建运动计划'), findsOneWidget);
  });

  testWidgets('窄屏（360dp 手机）：两个并排按钮不溢出', (tester) async {
    // 视口一放大什么都放得下，这个版面真正的风险在**窄屏**：
    // 两个 `Expanded` 里各塞「图标 + 新建学习计划」，360dp 下容易挤出
    // RenderFlex overflow（红黄条），而那在真机上就是文字被裁掉。
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    controller.studyPlans.assignAll([studyPlan()]);
    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: PlansTab())),
    );
    await tester.pumpAndSettle();

    // 布局溢出会以异常形式抛出来，这里显式收一次，报错比「看起来通过」好。
    expect(tester.takeException(), isNull);

    // 360dp 下「今天练什么」两段式占满了首屏，新建按钮在折叠线下面 ——
    // ListView 懒构建，不滚下去根本不会建出来。滚动本身也是判据：
    // 能滚到、能建出来，说明这一页没有因宽度溢出而布局失败。
    await tester.scrollUntilVisible(find.text('新建学习计划'), 300);
    expect(tester.takeException(), isNull);
    expect(find.text('新建学习计划'), findsOneWidget);
    expect(find.text('新建运动计划'), findsOneWidget);
  });
}

/// 只把 `loadData()` 空掉的家长控制器：版面测试不需要它真去读库 / 连服务。
/// 用子类而不是给线上代码加 `skipLoad` 开关 —— 测试需要的东西不该漏进产品。
class _SilentParentController extends ParentController {
  @override
  Future<void> loadData() async {}
}

/// 永远「今天还没做」：入口卡按未完成（浅绿）渲染，版面测试够用。
class _NeverCheckedinRepo implements CheckinRepository {
  @override
  @override
  Future<List<CheckinSubjectSummary>> subjectSummaries({String? studentId}) async =>
      // 假仓库不做分组：需要汇总数字的用例自己给一份（见
      // `checkin_subject_summary_test.dart`）。默认空 = 页面退回平铺列表。
      const <CheckinSubjectSummary>[];

  @override
  Future<CheckinQuizPage> getQuizzes({
    String? studentId,
    CheckinQuizStatus status = CheckinQuizStatus.all,
    // 按科目过滤由真仓库下到 SQL；假仓库不实现（用例只关心分区与分页）。
    String subject = '',
    int limit = 0,
    int offset = 0,
  }) async =>
      CheckinQuizPage.empty;

  @override
  Future<List<CheckinSeed>> loadSeeds({String? studentId, String? subject}) async => const [];

  @override
  Future<CheckinQuiz> generate({
    String? studentId,
    required String quizDate,
    String subject = '数学',
    int count = 5,
    List<String> knowledgePoints = const [],
    String difficulty = '',
  }) =>
      throw UnimplementedError();

  @override
  Future<CheckinSubmitResult> submit({
    required String quizId,
    required Map<int, String> picked,
  }) =>
      throw UnimplementedError();
}
