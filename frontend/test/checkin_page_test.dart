import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/models/checkin_models.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/parent/checkin_setup_page.dart';
import 'package:easy_learn_app/pages/student/checkin_page.dart';
import 'package:easy_learn_app/repositories/checkin_repository.dart';
import 'package:easy_learn_app/services/checkin_question_parser.dart';
import 'package:easy_learn_app/widgets/checkin_question_card.dart';
import 'package:easy_learn_app/widgets/checkin_result_paper_card.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 打卡页的**入口判据**：点了到底有没有反应。
///
/// ## 为什么这一条必须真点一下
///
/// 2026-10-27 真机上家长点「设置今天的题」**什么都没发生**：不是没绑事件，
/// 而是 `Get.toNamed<CheckinSetup>` 在 GetX 4.7.3 里必抛
///
/// ```
/// type 'GetPageRoute<dynamic>' is not a subtype of type 'Route<String?>?'
/// #1 NavigatorState.pushNamed
/// #2 GetNavigation.toNamed (extension_navigation.dart:596)
/// ```
///
/// `toNamed<T>` 最后一步是 `Navigator.pushNamed<T?>`，而 `getPages` 造出来的
/// 路由恒为 `GetPageRoute<dynamic>` —— 这个 cast 不可能成功。异常抛在手势
/// 回调里，于是**没有红屏、没有提示、页面不动**，看起来像按钮没绑定。
///
/// 所以判据只能是：真点一次，再看下一页在不在。
/// 「按钮存在」「onPressed != null」「文案对」这三种断言在 bug 在的时候
/// **全都是绿的**，一条都抓不住它。
///
/// 答题态不渲染答案那条判据在 `test/checkin_question_card_test.dart`（那里有
/// 带答案的题直接渲染），不在这里重复一份。
class _FakeCheckinRepo implements CheckinRepository {
  _FakeCheckinRepo({this.seeds = const [], this.quizzes = const []});

  final List<CheckinSeed> seeds;
  final List<CheckinQuiz> quizzes;

  @override
  Future<List<CheckinSeed>> loadSeeds({String? studentId, String? subject}) async => seeds;

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
    // 与真仓库同口径：按「成绩行在不在」分未完成 / 已完成，再翻页。
    // 页面分区的判据全靠这里 —— 假仓库不实现过滤的话，把 done 的卷子
    // 塞进「未完成」列表这种错也测不出来。
    final List<CheckinQuiz> filtered;
    if (status == CheckinQuizStatus.pending) {
      filtered = quizzes.where((q) => q.submittedResult == null).toList();
    } else if (status == CheckinQuizStatus.done) {
      filtered = quizzes.where((q) => q.submittedResult != null).toList();
    } else {
      filtered = quizzes;
    }
    final page = limit > 0
        ? filtered.skip(offset).take(limit).toList()
        : filtered.skip(offset).toList();
    return CheckinQuizPage(
      items: page,
      total: filtered.length,
      hasMore: limit > 0 && offset + page.length < filtered.length,
    );
  }

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 家长登录态 + 一个结伴孩子。
  ///
  /// `boundStudents` 空着的话 `_targetStudentId()` 返回 null，服务端会 400 ——
  /// 那不是这条判据要测的东西，但也不能省：没有孩子时按钮点了照样能推页，
  /// 有孩子才是线上的真实路径。
  void registerParent() {
    Get.put(AuthController()).currentUser.value = UserModel(
      id: 'par_001',
      name: '李妈妈',
      phone: '13800000002',
      role: 'parent',
      avatar: '👩',
    );
    Get.put<ParentController>(ParentController())
      ..boundStudents.assignAll([const ParentChild(id: 'stu_001', name: '林小宇')])
      ..selectedStudentId.value = 'stu_001';
  }

  /// 学生登录态。
  ///
  /// `_isParent()` 读的就是这个角色：学生走 [_QuizBody]（不渲染答案），
  /// 家长走预览。注册了才有「孩子点进去答题」这条真实路径。
  void registerStudent() {
    Get.put(AuthController()).currentUser.value = UserModel(
      id: 'stu_001',
      name: '林小宇',
      phone: '13800000003',
      role: 'student',
      avatar: '🧑',
    );
  }

  tearDown(Get.reset);

  testWidgets('家长点「设置今天的题」→ 设置页真的推上去', (tester) async {
    registerParent();
    final repo = _FakeCheckinRepo(
      seeds: const [CheckinSeed(knowledge: '幂的运算', wrongCount: 3)],
    );

    await tester.pumpWidget(
      GetMaterialApp(
        initialRoute: '/checkin',
        getPages: [
          GetPage(name: '/checkin', page: () => const CheckinPage()),
          // 与 `app.dart` 一致：范围页自己不去查「挂在谁名下」，
          // 这个值只有调用方知道，靠 `arguments` 传。
          GetPage(
            name: '/checkin-setup',
            page: () => CheckinSetupPage(
              studentId: Get.arguments as String?,
              repository: repo,
            ),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // 本地库模式下 `DatabaseService.checkin` 是 Unavailable，读题会失败，
    // 但「今天还没有题」这个空态正是要点的这一屏。
    expect(find.text('设置今天的题'), findsOneWidget);

    await tester.tap(find.text('设置今天的题'));
    await tester.pumpAndSettle();

    // 推不上去时这里一个都找不到 —— 就是线上那个症状。
    expect(find.text('设置今天的打卡'), findsOneWidget);
    expect(find.text('幂的运算'), findsOneWidget);
  });

  /// 交卷后的**逐题明细**（2026-10-27 用户报的「数学题展示不友好」）。
  ///
  /// 症状：明细行把 `$\frac{a+b}{2}$` 原样印出来 —— 美元符号、反斜杠、
  /// 花括号全在，家长看到的是"代码"而不是公式。
  ///
  /// ⚠️ 判据必须是**两种断言一起**：
  /// ① `Math` widget 真的出现了（渲染走了公式那条路）；
  /// ② 界面上再也找不到 `\frac` / `$` 原文（没走成普通 Text）。
  /// 只断①的话，题干里同时有纯文本时仍可能漏一段；只断②的话，
  /// 整块明细消失（比如明细压根没渲染）也能"通过"。
  testWidgets('交卷后的逐题明细：公式渲染成数学符号，不露 LaTeX 原文', (tester) async {
    registerParent();

    const question = CheckinQuestion(
      stem: r'$\frac{a+b}{2}$ 的值是多少？',
      options: [r'$\frac{a+b}{2}$', 'a+b', r'$2(a+b)$', '4'],
      answer: 'A',
      knowledge: r'分式 $\frac{a}{b}$ 的意义',
      type: CheckinQuestionType.choice,
    );
    const quiz = CheckinQuiz(
      id: 'ck_1',
      studentId: 'stu_001',
      quizDate: '2026-10-27',
      subject: '数学',
      status: 'done',
      questions: [question],
      submittedResult: CheckinSubmitResult(
        quizId: 'ck_1',
        score: 0,
        total: 1,
        items: [
          CheckinItemResult(
            index: 0,
            picked: 'B',
            answer: 'A',
            correct: false,
            knowledge: r'分式 $\frac{a}{b}$ 的意义',
          ),
        ],
      ),
    );

    final repo = _FakeCheckinRepo(quizzes: const [quiz]);
    await tester.pumpWidget(
      GetMaterialApp(
        initialRoute: '/checkin',
        getPages: [
          GetPage(name: '/checkin', page: () => CheckinPage(repository: repo)),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // 2026-10-29 起一律走列表：单份也在「已完成」那一区，点进去才看到回放。
    await tester.tap(find.text('数学'));
    await tester.pumpAndSettle();

    // 试卷排版真的渲染出来了（否则下面两条断言会"空转通过"）。
    expect(
      find.byType(CheckinResultPaperCard),
      findsWidgets,
      reason: '逐题回放没渲染出来时，下面的负向断言会空转',
    );

    expect(find.byType(Math), findsWidgets, reason: '公式必须交给 MathText 渲染');
    expect(
      find.textContaining(r'\frac', findRichText: true),
      findsNothing,
      reason: '界面上不能再出现 LaTeX 原文（用户看到的就是这个）',
    );
    expect(
      find.textContaining(r'$', findRichText: true),
      findsNothing,
      reason: '美元定界符也不能露出来',
    );
  });

  /// 一天多份时的**分层**（2026-10-27 用户要求）。
  ///
  /// 老样子是「第一节的题 + 第二节的题」一路平铺下来：孩子滑到中间分不清
  /// 自己在答哪一套，交卷按钮也不知道属于谁。用户原话是"看起来很不舒服"。
  ///
  /// 判据必须盯**题目有没有被铺出来**（`CheckinQuestionCard` 的数量），
  /// 而不是"清单有没有渲染"—— 后者在平铺版本里也能同时存在（清单加在
  /// 上面、题目照样铺在下面），只断清单会整条绿过去。
  group('多份打卡：先清单、点一套再答一套', () {
    CheckinQuiz quizOf(String id, String subject, List<String> stems) =>
        CheckinQuiz(
          id: id,
          studentId: 'stu_001',
          quizDate: '2026-10-27',
          subject: subject,
          questions: [
            for (final stem in stems)
              CheckinQuestion(
                stem: stem,
                options: const ['A', 'B'],
                answer: 'A',
                knowledge: '',
                type: CheckinQuestionType.choice,
              ),
          ],
        );

    Future<void> pumpPage(WidgetTester tester, _FakeCheckinRepo repo) async {
      await tester.pumpWidget(
        GetMaterialApp(
          initialRoute: '/checkin',
          getPages: [
            GetPage(name: '/checkin', page: () => CheckinPage(repository: repo)),
          ],
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('两份未完成 → 只出清单，题目一律不铺在页面上', (tester) async {
      registerStudent();
      await pumpPage(
        tester,
        _FakeCheckinRepo(
          quizzes: [
            quizOf('ck_math', '数学', ['数学题一', '数学题二']),
            quizOf('ck_en', '英语', ['英语题一', '英语题二']),
          ],
        ),
      );

      // 🔴 核心判据先断：一套都不许铺出来。
      // 放在最前面是刻意的 —— 平铺版本里「清单」可能照样画在题目上面，
      // 只断清单文案会在坏版本上整条通过；先断题目数量才抓得住它。
      expect(
        find.byType(CheckinQuestionCard),
        findsNothing,
        reason: '多份时页面只能是清单；题目平铺正是用户说的"看起来很不舒服"',
      );
      expect(
        find.textContaining('数学题一', findRichText: true),
        findsNothing,
        reason: '清单态连题干碎片都不该出现',
      );

      // 分区标题：未完成 2 份（已完成那区一份都没有，不渲染）。
      expect(find.text('未完成'), findsOneWidget);
      expect(find.text('2 份'), findsOneWidget);
      expect(find.text('数学'), findsOneWidget);
      expect(find.text('英语'), findsOneWidget);
    });

    testWidgets('点「数学」那一条 → 只展开数学那一套，还能回清单', (tester) async {
      registerStudent();
      await pumpPage(
        tester,
        _FakeCheckinRepo(
          quizzes: [
            quizOf('ck_math', '数学', ['数学题一', '数学题二']),
            quizOf('ck_en', '英语', ['英语题一', '英语题二']),
          ],
        ),
      );

      await tester.tap(find.text('数学'));
      await tester.pumpAndSettle();

      // 进的是数学这一套：两张题卡，英语的题一道都不许跟着出来。
      expect(find.text('数学打卡'), findsOneWidget, reason: 'AppBar 应指出在答哪一套');
      expect(find.byType(CheckinQuestionCard), findsNWidgets(2));
      expect(
        find.textContaining('英语题一', findRichText: true),
        findsNothing,
        reason: '一次只答一套，别的卷不能混进来',
      );

      // 返回清单：题目收起，两套又都列在下面。
      await tester.tap(find.text('任务列表（共 2 套）'));
      await tester.pumpAndSettle();
      expect(find.byType(CheckinQuestionCard), findsNothing);
      expect(find.text('未完成'), findsOneWidget);
      expect(find.text('英语'), findsOneWidget);
    });

    testWidgets('只有一份 → 也走列表（分区之后不再自动展开）', (tester) async {
      registerStudent();
      await pumpPage(
        tester,
        _FakeCheckinRepo(
          quizzes: [
            quizOf('ck_math', '数学', ['数学题一', '数学题二']),
          ],
        ),
      );

      // 2026-10-29 的行为变更：以前「一份就自动展开」，是为了少点一次；
      // 但现在列表要同时装下「未完成」和「已完成」两区，自动展开会把
      // 已完成那半整块挡住 —— 所以统一改成点进去。这条判据盯的就是
      // 「别再退回到自动展开」。
      expect(find.byType(CheckinQuestionCard), findsNothing);
      expect(find.text('未完成'), findsOneWidget);

      await tester.tap(find.text('数学'));
      await tester.pumpAndSettle();
      expect(find.byType(CheckinQuestionCard), findsNWidgets(2));
    });

    testWidgets('清单里已完成的那套直接给出得分', (tester) async {
      registerStudent();
      const done = CheckinQuiz(
        id: 'ck_math',
        studentId: 'stu_001',
        quizDate: '2026-10-27',
        subject: '数学',
        status: 'done',
        submittedResult: CheckinSubmitResult(
          quizId: 'ck_math',
          score: 1,
          total: 2,
          items: [],
        ),
        questions: [
          CheckinQuestion(
            stem: '数学题一',
            options: ['A', 'B'],
            answer: 'A',
            knowledge: '',
            type: CheckinQuestionType.choice,
          ),
          CheckinQuestion(
            stem: '数学题二',
            options: ['A', 'B'],
            answer: 'A',
            knowledge: '',
            type: CheckinQuestionType.choice,
          ),
        ],
      );

      await pumpPage(
        tester,
        _FakeCheckinRepo(
          quizzes: [done, quizOf('ck_en', '英语', ['英语题一'])],
        ),
      );

      // 挑卷时最想知道的就是"哪套还没做、哪套几分"。
      expect(find.text('1/2'), findsOneWidget, reason: '已完成那条要直接给出得分');
      expect(find.text('待完成'), findsOneWidget, reason: '英语那条还没做');
      expect(find.text('已完成'), findsOneWidget, reason: '两半必须分区，做过的不能在未完成里');
      expect(find.text('未完成'), findsOneWidget);
    });
  });

  /// 2026-10-28 用户报「家长端概念打卡出题的功能不见了」。
  ///
  /// 复现条件是**今天只有一份、且已交卷**：页面按「一份就直接展开」的规则
  /// 进到结果态，而结果态原先只画分数与逐题回放，**一个出题按钮都没有**。
  /// 出题入口那时只在两处：未交卷的 `_ParentPreview`、和多份时的清单底部。
  /// 单份交卷正好两条都不占 —— 家长看到 3/8 想再来一套，整页找不到入口。
  ///
  /// 判据必须是**真的点下去、看到设置页**，不能只断按钮存在：
  /// 「按钮在但点了没反应」在本页已经发生过一次（`toNamed<T>` 必抛）。
  group('交卷之后仍然能再出一组', () {
    const doneQuiz = CheckinQuiz(
      id: 'ck_math',
      studentId: 'stu_001',
      quizDate: '2026-10-28',
      subject: '数学',
      status: 'done',
      submittedResult: CheckinSubmitResult(
        quizId: 'ck_math',
        score: 3,
        total: 5,
        items: [],
      ),
      questions: [
        CheckinQuestion(
          stem: '数学题一',
          options: ['A', 'B'],
          answer: 'A',
          knowledge: '',
          type: CheckinQuestionType.choice,
        ),
      ],
    );

    Future<void> pumpPage(WidgetTester tester, _FakeCheckinRepo repo) async {
      await tester.pumpWidget(
        GetMaterialApp(
          initialRoute: '/checkin',
          getPages: [
            GetPage(name: '/checkin', page: () => CheckinPage(repository: repo)),
            GetPage(
              name: '/checkin-setup',
              page: () => CheckinSetupPage(
                studentId: Get.arguments as String?,
                repository: repo,
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('家长 · 唯一一份已交卷 → 结果下面有入口，点了真推设置页', (tester) async {
      registerParent();
      await pumpPage(
        tester,
        _FakeCheckinRepo(
          seeds: const [CheckinSeed(knowledge: '幂的运算', wrongCount: 3)],
          quizzes: const [doneQuiz],
        ),
      );

      // 2026-10-29 起先进列表：已完成那份在「已完成」区，点开才是结果态。
      expect(find.text('已完成'), findsOneWidget);
      await tester.tap(find.text('数学'));
      await tester.pumpAndSettle();
      expect(find.text('3'), findsOneWidget, reason: '分数要在结果卡上');

      // 「再出一组」必须出现在交卷之后（2026-10-28 用户报的）。
      // 单份交卷时页面直接展开这一份、不进清单；原先出题入口只在
      // 「未交卷」和「多份清单」两处，于是整页没有出题按钮。

      final entry = find.text('再出一组新的试卷');
      expect(
        entry,
        findsOneWidget,
        reason: '单份交卷后整页没有任何出题入口 —— 用户报的正是这条',
      );

      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.text('设置今天的打卡'), findsOneWidget);
    });

    testWidgets('学生 · 同一份已交卷 → 不给这个入口', (tester) async {
      registerStudent();
      await pumpPage(
        tester,
        _FakeCheckinRepo(quizzes: const [doneQuiz]),
      );

      expect(find.text('已完成'), findsOneWidget);
      expect(
        find.text('再出一组新的试卷'),
        findsNothing,
        reason: '出题是家长的动作；学生端出现它就成了「自己给自己布置作业」',
      );
    });
  });
}
