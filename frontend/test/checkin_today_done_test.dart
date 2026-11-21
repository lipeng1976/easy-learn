import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/checkin_controller.dart';
import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/models/checkin_models.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/student/checkin_page.dart';
import 'package:easy_learn_app/repositories/checkin_repository.dart';
import 'package:easy_learn_app/services/checkin_question_parser.dart';
import 'package:easy_learn_app/utils/checkin_label.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 「已完成」列表里把**今天完成**的几份框起来（11-15 需求）。
///
/// ## 判据要盯住的不是「有没有边框」
///
/// 光断言「出现了一个 Container」在分组写错时照样全绿。真正的风险是
/// **口径**：列表每行原来显示的是 `quizDate`（出题日），而用户要的是
/// 「今天做完的」。本机库里真有 `quiz_date=11-12/11-13`、
/// `submitted_at=11-14` 的行 —— 按出题日分组会把这些漏出框外，且不报错。
///
/// 所以这里既有纯函数判据（交卷日 / 跨天 / 缺字段不猜今天），也有真渲染的
/// widget 判据（框里到底装了哪几份、框外还剩什么、行上日期改没改）。
const _today = '2026-11-15';
final DateTime _clockNow = DateTime(2026, 11, 15, 10);

const _question = CheckinQuestion(
  stem: '1+1=?',
  options: ['1', '2'],
  answer: 'B',
  knowledge: '加法',
  type: CheckinQuestionType.choice,
);

CheckinQuiz _quiz({
  required String id,
  required String subject,
  required String quizDate,
  DateTime? submittedAt,
  bool withResult = true,
}) =>
    CheckinQuiz(
      id: id,
      studentId: 'stu_001',
      quizDate: quizDate,
      subject: subject,
      status: submittedAt == null ? 'pending' : 'done',
      questions: const [_question],
      submittedResult: withResult
          ? CheckinSubmitResult(
              quizId: id,
              score: 1,
              total: 1,
              items: const [],
              submittedAt: submittedAt,
            )
          : null,
    );

class _FakeRepo implements CheckinRepository {
  _FakeRepo(this.quizzes);

  final List<CheckinQuiz> quizzes;

  @override
  Future<CheckinQuizPage> getQuizzes({
    String? studentId,
    CheckinQuizStatus status = CheckinQuizStatus.all,
    String subject = '',
    int limit = 0,
    int offset = 0,
  }) async {
    // 与真服务端同口径：做没做完看**成绩行在不在**。
    final filtered = quizzes
        .where((q) => status == CheckinQuizStatus.pending
            ? q.submittedResult == null
            : status == CheckinQuizStatus.done
                ? q.submittedResult != null
                : true)
        .toList();
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
  Future<List<CheckinSubjectSummary>> subjectSummaries({String? studentId}) async =>
      // 留空 = 页面走平铺列表（家长端常态，也是学生端汇总取不到时的降级）。
      const [];

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
  }) =>
      throw UnimplementedError();

  @override
  Future<CheckinSubmitResult> submit({
    required String quizId,
    required Map<int, String> picked,
  }) =>
      throw UnimplementedError();
}

/// 提交接口**故意不回** `submittedAt`，与真服务端一致。
class _SubmitRepo extends _FakeRepo {
  _SubmitRepo(super.quizzes);

  @override
  Future<CheckinSubmitResult> submit({
    required String quizId,
    required Map<int, String> picked,
  }) async =>
      CheckinSubmitResult(quizId: quizId, score: 1, total: 1, items: const []);
}

void _registerParent() {
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

void _registerStudent() {
  Get.put(AuthController()).currentUser.value = UserModel(
    id: 'stu_001',
    name: '林小宇',
    phone: '13800000003',
    role: 'student',
    avatar: '🧑',
  );
}

Future<void> _pump(WidgetTester tester, CheckinRepository repo) async {
  await tester.pumpWidget(GetMaterialApp(
    home: CheckinPage(repository: repo, clock: () => _clockNow),
  ));
  await tester.pumpAndSettle();
}

Finder get _box => find.byKey(const Key('checkin_today_done_box'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(Get.reset);

  // ===== 纯函数：交卷时刻从哪来、日期怎么定 =====

  test('列表接口返回的 submittedAt 会被真的解析出来', () {
    final parsed = CheckinSubmitResult.fromJson(const {
      'quizId': 'ck_1',
      'score': 1,
      'total': 1,
      'items': [],
      'submittedAt': '2026-11-15T01:31:50.202Z',
    });
    expect(parsed.submittedAt, DateTime.parse('2026-11-15T01:31:50.202Z'));
  });

  test('本机判分带上交卷时刻（提交接口不回这个字段）', () {
    final judged = CheckinSubmitResult.judge(
      quizId: 'ck_1',
      questions: const [_question],
      picked: const {0: 'B'},
      submittedAt: _clockNow,
    );
    expect(judged.submittedAt, _clockNow);
    expect(judged.synced, isFalse);
  });

  test('换成存档真值时保留本机交卷时刻', () {
    final local = CheckinSubmitResult(
      quizId: 'ck_1',
      score: 1,
      total: 1,
      items: const [],
      synced: false,
      submittedAt: _clockNow,
    );
    const stored = CheckinSubmitResult(
      quizId: 'ck_1',
      score: 1,
      total: 1,
      items: [],
    );
    expect(stored.submittedAt, isNull);
    expect(stored.copyWith(submittedAt: local.submittedAt).submittedAt, _clockNow);
  });

  test('交卷日取本地日，且优先于出题日（跨天）', () {
    final quiz = _quiz(
      id: 'ck_cross',
      subject: '语文',
      quizDate: '2026-11-14',
      submittedAt: DateTime(2026, 11, 15, 9, 31),
    );
    expect(checkinDoneDateKey(quiz, quiz.submittedResult!), _today);
    expect(checkinShortDate(checkinDoneDateKey(quiz, quiz.submittedResult!)), '11-15');
  });

  test('老服务端没给交卷时刻时退回出题日，绝不猜成今天', () {
    final quiz = _quiz(
      id: 'ck_old',
      subject: '英语',
      quizDate: '2026-11-12',
      submittedAt: null,
    );
    // 手写一份「有成绩、但没有时间戳」的结果。
    const result = CheckinSubmitResult(quizId: 'ck_old', score: 1, total: 1, items: []);
    expect(checkinDoneDateKey(quiz, result), '2026-11-12');
    expect(checkinDoneDateKey(quiz, result), isNot(_today));
  });

  test('交卷链路：换成存档真值后仍带交卷时刻，跨天的那份算今天', () async {
    // 出题在昨天、作答在今天。提交接口不回 submittedAt 时，如果控制器
    // 不保留本机时刻，这一份就会被按出题日分到「更早」，静默漏出今天的框。
    final pending = _quiz(
      id: 'ck_pending',
      subject: '数学',
      quizDate: '2026-11-14',
      withResult: false,
    );
    final controller = CheckinController(
      repository: _SubmitRepo([pending]),
      clock: () => _clockNow,
    );
    await controller.load(studentId: 'stu_001');
    final run = controller.pendingRuns.single;
    controller.pick(run, 0, 'B');

    expect(await controller.submit(run), isTrue);
    final result = run.result.value;
    expect(result, isNotNull);
    expect(result!.submittedAt, _clockNow);
    expect(checkinDoneDateKey(run.quiz.value, result), _today);
    expect(controller.doneRuns.single.quiz.value.id, 'ck_pending');
  });

  test('日期键单点：控制器与分组用同一个格式', () {
    expect(CheckinController.formatDate(_clockNow), checkinDateKey(_clockNow));
    expect(checkinDateKey(DateTime(2026, 1, 1, 23, 59)), '2026-01-01');
  });

  // ===== 真渲染：框里装什么、框外剩什么 =====

  testWidgets('家长端：今天完成的被框住，跨天出题今天交卷的也在框里', (tester) async {
    _registerParent();
    final repo = _FakeRepo([
      _quiz(
        id: 'ck_cross',
        subject: '语文',
        quizDate: '2026-11-14', // 昨天出题
        submittedAt: DateTime(2026, 11, 15, 9, 31), // 今天交卷
      ),
      _quiz(
        id: 'ck_today',
        subject: '数学',
        quizDate: _today,
        submittedAt: DateTime(2026, 11, 15, 8, 0),
      ),
      _quiz(
        id: 'ck_older',
        subject: '英语',
        quizDate: '2026-11-13',
        submittedAt: DateTime(2026, 11, 14, 8, 20),
      ),
      _quiz(id: 'ck_pending', subject: '历史', quizDate: _today, withResult: false),
    ]);
    await _pump(tester, repo);

    expect(_box, findsOneWidget, reason: '今天有完成却没画方框');
    expect(find.text('今天完成'), findsOneWidget);
    expect(find.text('2 份'), findsOneWidget, reason: '框内份数必须是真数');

    // ① 框内恰好是今天交卷的那两份（含跨天那份）；
    expect(find.descendant(of: _box, matching: find.text('语文')), findsOneWidget);
    expect(find.descendant(of: _box, matching: find.text('数学')), findsOneWidget);
    expect(find.descendant(of: _box, matching: find.text('英语')), findsNothing);
    // ② 更早的那份没被吞掉，只是落在框外；
    expect(find.text('英语'), findsOneWidget);
    // ③ 行上日期改成完成日：框里不该再出现 11-14，框外那条老的写 11-14。
    expect(find.descendant(of: _box, matching: find.textContaining('11-14')), findsNothing);
    expect(find.textContaining('11-14'), findsOneWidget);
    expect(find.descendant(of: _box, matching: find.textContaining('11-15')), findsNWidgets(2));
    // ④ 未完成区照旧。
    expect(find.text('历史'), findsOneWidget);
    expect(find.text('未完成'), findsOneWidget);
  });

  testWidgets('第一页全是今天且还有下一页：份数写 N+ 不写成 N', (tester) async {
    _registerParent();
    final repo = _FakeRepo([
      for (var i = 0; i < 11; i++)
        _quiz(
          id: 'ck_$i',
          subject: '数学',
          quizDate: _today,
          submittedAt: DateTime(2026, 11, 15, 9, i),
        ),
    ]);
    await _pump(tester, repo);

    expect(_box, findsOneWidget);
    // 控制器一页 10 条，服务端说还有下一页 → 今天到底几份还不知道。
    expect(find.text('10+ 份'), findsOneWidget);
    expect(find.text('10 份'), findsNothing);
    // 11 份里第一页确实只加载了 10 份；「加载更多」在屏幕外，别用 find.text
    // 去断一个 ListView 还没构建的行（那会假红）。
    expect(find.descendant(of: _box, matching: find.text('数学')), findsNWidgets(10));
  });

  testWidgets('学生端退回平铺列表时，同一份方框照样出现', (tester) async {
    _registerStudent();
    final repo = _FakeRepo([
      _quiz(
        id: 'ck_today',
        subject: '数学',
        quizDate: _today,
        submittedAt: DateTime(2026, 11, 15, 9, 0),
      ),
      _quiz(
        id: 'ck_older',
        subject: '语文',
        quizDate: '2026-11-14',
        submittedAt: DateTime(2026, 11, 14, 9, 0),
      ),
    ]);
    await _pump(tester, repo);

    expect(_box, findsOneWidget);
    expect(find.text('1 份'), findsWidgets);
    expect(find.descendant(of: _box, matching: find.text('数学')), findsOneWidget);
    expect(find.text('语文'), findsOneWidget);
  });

  testWidgets('今天一份都没完成：不画空框，历史照旧列出来', (tester) async {
    _registerParent();
    final repo = _FakeRepo([
      _quiz(
        id: 'ck_older',
        subject: '英语',
        quizDate: '2026-11-13',
        submittedAt: DateTime(2026, 11, 14, 8, 20),
      ),
    ]);
    await _pump(tester, repo);

    expect(_box, findsNothing);
    expect(find.text('今天完成'), findsNothing);
    expect(find.text('英语'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
  });
}
