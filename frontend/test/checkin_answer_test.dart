import 'dart:async';

import 'package:easy_learn_app/constants/app_colors.dart';
import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/checkin_controller.dart';
import 'package:easy_learn_app/controllers/checkin_entry_state.dart';
import 'package:easy_learn_app/models/checkin_models.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/services/checkin_question_parser.dart';
import 'package:easy_learn_app/pages/student/checkin_page.dart';
import 'package:easy_learn_app/widgets/checkin_result_paper_card.dart';
import 'package:easy_learn_app/repositories/checkin_repository.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 学生端打卡的**作答判据**：点一下选项，界面到底认不认。
///
/// ## 2026-10-27 真机坏在哪
///
/// 家长出题正常，孩子那边点选项**一点反应都没有**：不变色、不标记、
/// 「已答 0/8」不动，交卷按钮一直说「还有 8 题没选」。而 `picked` 里
/// 其实**已经写进去了** —— 状态改对了，界面不重建。
///
/// 根因是 Obx 的作用域：页面外层那个 `Obx` 只负责构建 `_QuizBody(controller:)`
/// 这个**组件对象**，`_QuizBody.build` 是在它自己的 Element 里跑的，**不在**
/// Obx 的追踪区内。于是 `controller.picked[i]` / `answeredCount` 这些读取
/// 全部**不被记账** → `picked` 变了也没人知道要重建。
///
/// 这正是「点了没反应」的第二种长相：不是没绑事件，是**改了 Rx 没人看**。
///
/// 所以判据只能是：真点一次，再断言**界面上的计数与选中底色**。
/// 「picked 里有没有值」这种断言在 bug 在的时候是绿的（状态本来就改对了），
/// 抓不住它 —— 那正是这次故障能活到真机的原因。
class _FakeRepo implements CheckinRepository {
  _FakeRepo(this.quiz);

  final CheckinQuiz quiz;

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
  }) async {
    // 这份卷有没有交过，决定它出现在哪个列表里 —— 不按 status 过滤的话
    // `load()` 会把它同时放进「未完成」和「已完成」，页面上就成了两份。
    final done = quiz.submittedResult != null;
    final inThisList = status == CheckinQuizStatus.all ||
        (status == CheckinQuizStatus.done) == done;
    return CheckinQuizPage(
      items: inThisList ? [quiz] : const [],
      total: inThisList ? 1 : 0,
      hasMore: false,
    );
  }

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
  }) async =>
      CheckinSubmitResult(
        quizId: quizId,
        score: quiz.questions
            .asMap()
            .entries
            .where((e) => e.value.answer == picked[e.key])
            .length,
        total: quiz.questions.length,
        items: const [],
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 一道选择题 + 一道判断题 —— 用户报的正是这两类都点不动。
  final quiz = CheckinQuiz(
    id: 'quiz_001',
    studentId: 'stu_001',
    quizDate: '2026-10-27',
    subject: '数学',
    difficulty: '基础',
    questions: const [
      CheckinQuestion(
        stem: '“x 的 3 倍与 5 的和”用数学式子表示为？',
        options: ['3x + 5', '3(x + 5)', 'x/3 + 5', '5x + 3'],
        answer: 'A',
        knowledge: '文字描述到数学表达转换',
        type: CheckinQuestionType.choice,
      ),
      CheckinQuestion(
        stem: '“比 a 少 2 的数”可以写成 2 - a。',
        options: ['正确', '错误'],
        answer: 'F',
        knowledge: '文字描述到数学表达转换',
        type: CheckinQuestionType.judge,
      ),
    ],
  );

  setUp(() {
    Get.put(AuthController()).currentUser.value = UserModel(
      id: 'stu_001',
      name: '林小宇',
      phone: '13800000001',
      role: 'student',
      avatar: '🧒',
    );
    // 入口卡的状态槽：交卷成功后 `CheckinController` 要往这里推 markDone，
    // 计划页那张卡才能从「待完成」翻成「已完成」—— 不预注册的话推不到。
    Get.put(CheckinEntryState(repository: _FakeRepo(quiz)));
  });

  tearDown(Get.reset);

  Future<void> pumpPage(WidgetTester tester) async {
    // 这一屏要一屏放下（两道题 + 交卷按钮），默认 800×600 会把第二题裁掉，
    // 于是「判断题点不动」看起来像「控件不存在」（B23 同族坑）。
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      GetMaterialApp(home: CheckinPage(repository: _FakeRepo(quiz))),
    );
    await tester.pumpAndSettle();

    // 2026-10-29 起打卡页先给列表（未完成 / 已完成两区），点进去才答题。
    // 这一步放在这里而不是每个用例里：所有用例都要过它，写一份就不会漏。
    await tester.tap(find.text('数学').first);
    await tester.pumpAndSettle();
  }

  /// 选项那层 Container 的底色 —— 用来看「选上了没有」。
  Color? optionColor(WidgetTester tester, int questionIndex, int optionIndex) {
    final box = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(ValueKey('checkin-option-$questionIndex-$optionIndex')),
            matching: find.byType(Container),
          )
          .first,
    );
    return (box.decoration as BoxDecoration?)?.color;
  }

  testWidgets('点选择题选项 → 计数前进、选项变色', (tester) async {
    await pumpPage(tester);

    expect(find.text('已答 0/2'), findsOneWidget);
    expect(optionColor(tester, 0, 0), Colors.transparent);

    await tester.tap(find.byKey(const ValueKey('checkin-option-0-0')));
    await tester.pump();

    // ① 计数 —— bug 在的时候这里还是「已答 0/2」。
    expect(find.text('已答 1/2'), findsOneWidget);
    // ② 选中态 —— 用户原话「没变色也没被标记为选上」。
    expect(
      optionColor(tester, 0, 0),
      AppColors.primary.withValues(alpha: 0.10),
      reason: '选中的选项底色应该变，否则孩子不知道自己点了没点上',
    );
    // ③ 没选的那个仍是透明，别把整题都点亮。
    expect(optionColor(tester, 0, 1), Colors.transparent);
  });

  testWidgets('点判断题选项 → 计数前进、按钮文案改成剩余题数', (tester) async {
    await pumpPage(tester);

    expect(find.text('还有 2 题没选'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('checkin-option-1-0')));
    await tester.pump();

    expect(find.text('已答 1/2'), findsOneWidget);
    expect(find.text('还有 1 题没选'), findsOneWidget);
    expect(optionColor(tester, 1, 0), AppColors.primary.withValues(alpha: 0.10));
  });

  testWidgets('两题都选完 → 按钮变「交卷」并且真能交出去', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey('checkin-option-0-0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('checkin-option-1-1')));
    await tester.pump();

    expect(find.text('已答 2/2'), findsOneWidget);
    expect(find.text('交卷'), findsOneWidget);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '交卷'),
    );
    expect(button.onPressed, isNotNull, reason: '全选完按钮不该还是灰的');

    await tester.tap(find.text('交卷'));
    await tester.pumpAndSettle();

    // 答案第 1 题 A、第 2 题 F，点的是 A 和「错误」→ 2/2。
    expect(find.text('全对，厉害'), findsOneWidget);
    // 交卷成功那一刻就要把「今天做完了」推给入口卡（CheckinEntryState）：
    // 计划页那张卡是常驻的，不推的话做完返回去还是浅绿「待完成」。
    expect(
      Get.find<CheckinEntryState>().progressByStudent['stu_001']!.allDone,
      true,
      reason: '交卷成功后入口卡的状态必须立刻翻成已完成',
    );
  });

  testWidgets('点「出 5 道题」→ 出题期间按钮转圈（否则几秒里全是「没反应」）', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      GetMaterialApp(home: CheckinPage(repository: _PendingRepo())),
    );
    await tester.pumpAndSettle();

    expect(find.text('出 5 道题'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.text('出 5 道题'));
    // 出题没完成，所以只能 `pump` 一帧，不能 `pumpAndSettle`。
    await tester.pump();

    // 这一行就是「有没有在干活」的唯一可见证据：模型要跑几秒，
    // 界面一动不动时用户只会再点一次（然后被 busy 挡掉，更像坏了）。
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  test('交卷遇 404：丢弃旧卷、拉新卷重做，而不是挂着交不上去的旧题', () async {
    // 家长在孩子作答中途重新出题 → 服务端换新 id，旧 id 交卷 404
    //（2026-10-27 串题修复）。客户端必须丢卷重拉，不能让孩子对着
    // 一份再也交不上去的旧题。
    final fresh = CheckinQuiz(
      id: 'quiz_999',
      studentId: 'stu_001',
      quizDate: '2026-10-27',
      subject: '数学',
      difficulty: '基础',
      questions: quiz.questions,
    );
    final controller = CheckinController(repository: _StaleQuizRepo(quiz, fresh));
    await controller.load();
    expect(controller.runs.single.quiz.value.id, 'quiz_001');

    final run = controller.runs.single;
    controller.pick(run, 0, 'A');
    controller.pick(run, 1, 'T');
    final stored = await controller.submit(run);

    expect(stored, isFalse, reason: '404 意味着没存上');
    expect(controller.runs.single.quiz.value.id, 'quiz_999', reason: '必须换成新卷');
    expect(controller.error.value, contains('题目已更新'));
    expect(controller.runs.single.picked, isEmpty, reason: '旧作答不能残留到新卷上');
  });

  testWidgets('重开页面（已交卷）：逐题明细每题都在，能看到选了什么、该选什么', (tester) async {
    // 2026-10-27 用户报的第三个问题：交完卷重开页面只剩一句汇总
    // 「有 1 题需要再看看」，看不到是哪个题。根因是旧服务端读题接口
    // 不回逐题明细。现在服务端从存档派生回传，页面必须全部渲染出来。
    final done = CheckinQuiz(
      id: 'quiz_001',
      studentId: 'stu_001',
      quizDate: '2026-10-27',
      subject: '数学',
      status: 'done',
      submittedResult: const CheckinSubmitResult(
        quizId: 'quiz_001',
        score: 1,
        total: 2,
        items: [
          CheckinItemResult(
            index: 0,
            picked: 'A',
            answer: 'A',
            correct: true,
            knowledge: '文字描述到数学表达转换',
          ),
          CheckinItemResult(
            index: 1,
            picked: 'T',
            answer: 'F',
            correct: false,
            knowledge: '文字描述到数学表达转换',
          ),
        ],
      ),
      questions: quiz.questions,
    );

    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      GetMaterialApp(home: CheckinPage(repository: _FakeRepo(done))),
    );
    await tester.pumpAndSettle();

    // 已交卷的那份现在在「已完成」区，点开才是复盘。
    await tester.tap(find.text('数学').first);
    await tester.pumpAndSettle();

    expect(find.text('有 1 题要再看看'), findsOneWidget);
    // 两题都要以「试卷排版」逐题回放，而不是只剩一行汇总。
    expect(find.byType(CheckinResultPaperCard), findsNWidgets(2));
    // 试卷排版下题号是「1. / 2.」而不是「第 1 题」。
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    // 错的那题要能看出选了什么、该选什么（判断题：选了「正确」，该选「错误」）。
    expect(find.textContaining('你的答案：正确'), findsOneWidget);
    expect(find.textContaining('正确答案：错误'), findsOneWidget);
  });

  testWidgets('交卷后说清「错题去了哪」：计划 → 复习的交接要看得见', (tester) async {
    // 边界（11-12）：计划只出选择/判断，做错的题自动进错题本、成为复习的原料。
    // 界面上不说这一句的话，「打卡做错了」和「复习里多了一道题」在孩子眼里
    // 是两件互不相关的事，而它们其实是同一条链。
    final done = CheckinQuiz(
      id: 'quiz_003',
      studentId: 'stu_001',
      quizDate: '2026-11-12',
      subject: '数学',
      status: 'done',
      submittedResult: const CheckinSubmitResult(
        quizId: 'quiz_003',
        score: 1,
        total: 2,
        mistakesAdded: 1,
        items: [
          CheckinItemResult(
            index: 0,
            picked: 'A',
            answer: 'A',
            correct: true,
            knowledge: '文字描述到数学表达转换',
          ),
          CheckinItemResult(
            index: 1,
            picked: 'T',
            answer: 'F',
            correct: false,
            knowledge: '文字描述到数学表达转换',
          ),
        ],
      ),
      questions: quiz.questions,
    );

    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      GetMaterialApp(home: CheckinPage(repository: _FakeRepo(done))),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('数学').first);
    await tester.pumpAndSettle();

    expect(
      find.text('做错的 1 题已进错题本，去「复习」可以重做。'),
      findsOneWidget,
      reason: '不说这句，孩子不知道错题已经进了复习队列',
    );
  });
}

/// 出题永远不返回：用来观察「进行中」这一屏。
class _PendingRepo implements CheckinRepository {
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
  }) async => CheckinQuizPage.empty;

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
      Completer<CheckinQuiz>().future;

  @override
  Future<CheckinSubmitResult> submit({
    required String quizId,
    required Map<int, String> picked,
  }) =>
      throw UnimplementedError();
}

/// 重新出题后的旧卷：服务端换新 id，旧 id 交卷 404。
class _StaleQuizRepo extends _FakeRepo {
  _StaleQuizRepo(super.quiz, this.freshQuiz);

  /// 重新拉题时服务端给的新卷（id 不同，才能断言「真的换了」）。
  final CheckinQuiz freshQuiz;
  int loadCount = 0;

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
  }) async {
    loadCount += 1;
    // 第一次是初始进页面的旧卷，之后（交卷 404 触发的重拉）是新卷。
    // 两份都是**没交卷**的，所以「已完成」那次查询要回空 —— 否则
    // `load()` 会把同一份卷同时放进两个列表（两个不同的 CheckinRun），
    // 而 `runs.single` 会直接炸。
    if (status == CheckinQuizStatus.done) return CheckinQuizPage.empty;
    final one = loadCount == 1 ? quiz : freshQuiz;
    return CheckinQuizPage(items: [one], total: 1, hasMore: false);
  }

  @override
  Future<CheckinSubmitResult> submit({
    required String quizId,
    required Map<int, String> picked,
  }) =>
      throw const DataApiException(
        code: 'not_found',
        message: '打卡不存在，或不属于当前账号',
        status: 404,
      );
}
