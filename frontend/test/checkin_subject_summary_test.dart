import 'package:easy_learn_app/constants/subject_colors.dart';
import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/models/checkin_models.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/student/checkin_page.dart';
import 'package:easy_learn_app/pages/student/checkin_subject_page.dart';
import 'package:easy_learn_app/repositories/checkin_repository.dart';
import 'package:easy_learn_app/services/checkin_question_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 学生端「已完成」按科目分组（2026-11-12 虫子要求）。
///
/// 原话：「在学生的概念打卡那，有未完成的和已完成的……已完成的，是不是参考
/// 配置端的大色块那，按科目分类，点进去才是详细的当前科目完成的打卡记录。」
///
/// ## 这些判据在盯什么
///
/// 1. **数字是真的**：份数来自 `subjectSummaries`（服务端 group by），
///    不是数已加载的那一页。假仓库故意让汇总（12 份）与列表页（2 份）
///    不一致 —— 页面显示 2 就说明它数的是列表。
/// 2. **点得动**：点色块要真的推上去那一科的记录页。只断「色块存在」
///    在回调没绑上时照样绿（这个仓库栽过）。
/// 3. **拿不到汇总要退回平铺**：老服务端没有 `/data/checkin/summary`，
///    这时显示「已完成 12 份」却一块色块都没有，比旧版更糟。
/// 4. **家长不受影响**：他要看的是「最近孩子做了什么」，保持时间倒序平铺。

class _FakeRepo implements CheckinRepository {
  _FakeRepo({
    this.quizzes = const [],
    this.summaries = const [],
    this.summaryThrows = false,
  });

  final List<CheckinQuiz> quizzes;
  final List<CheckinSubjectSummary> summaries;

  /// 模拟「老服务端 / 断网」：汇总接口失败。
  final bool summaryThrows;

  /// 记录最近一次 `getQuizzes` 的调用参数（科目过滤是否真传下去）。
  String lastSubject = '';
  int loadCount = 0;

  @override
  Future<List<CheckinSubjectSummary>> subjectSummaries({String? studentId}) async {
    if (summaryThrows) throw StateError('summary endpoint missing');
    return summaries;
  }

  @override
  Future<CheckinQuizPage> getQuizzes({
    String? studentId,
    CheckinQuizStatus status = CheckinQuizStatus.all,
    String subject = '',
    int limit = 0,
    int offset = 0,
  }) async {
    loadCount += 1;
    lastSubject = subject;
    var filtered = quizzes;
    if (status == CheckinQuizStatus.pending) {
      filtered = quizzes.where((q) => q.submittedResult == null).toList();
    } else if (status == CheckinQuizStatus.done) {
      filtered = quizzes.where((q) => q.submittedResult != null).toList();
    }
    if (subject.isNotEmpty) {
      filtered = filtered.where((q) => q.subject == subject).toList();
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

CheckinQuiz _done(String id, String subject, {int score = 4}) => CheckinQuiz(
      id: id,
      studentId: 'stu_001',
      quizDate: '2026-11-10',
      subject: subject,
      status: 'done',
      questions: const [
        CheckinQuestion(
          stem: '1+1=?',
          options: ['1', '2', '3', '4'],
          answer: 'B',
          knowledge: '加法',
          type: CheckinQuestionType.choice,
        ),
      ],
      submittedResult: CheckinSubmitResult(
        quizId: id,
        score: score,
        total: 5,
        items: const [
          CheckinItemResult(
            index: 0,
            picked: 'B',
            answer: 'B',
            correct: true,
            knowledge: '加法',
          ),
        ],
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void registerStudent() {
    Get.put(AuthController()).currentUser.value = UserModel(
      id: 'stu_001',
      name: '林小宇',
      phone: '13800000003',
      role: 'student',
      avatar: '🧑',
    );
  }

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

  tearDown(Get.reset);

  Future<void> pumpPage(WidgetTester tester, _FakeRepo repo) async {
    await tester.pumpWidget(
      GetMaterialApp(
        initialRoute: '/checkin',
        getPages: [
          GetPage(name: '/checkin', page: () => CheckinPage(repository: repo)),
          GetPage(
            name: '/checkin-subject',
            page: () => CheckinSubjectPage(
              subject: Get.arguments as String? ?? '其他',
              repository: repo,
            ),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('学生：已完成按科目出大色块，份数取服务端的真数', (tester) async {
    registerStudent();
    final repo = _FakeRepo(
      // 列表页只加载到 2 份（分页 10 的前 2 条）。
      quizzes: [_done('a', '数学'), _done('b', '数学')],
      // 汇总说数学一共 12 份 —— 页面必须显示 12。
      summaries: const [
        CheckinSubjectSummary(
          subject: '数学',
          done: 12,
          lastScore: 4,
          lastTotal: 5,
        ),
      ],
    );

    await pumpPage(tester, repo);

    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('数学'), findsOneWidget, reason: '已完成区要有科目色块');
    expect(
      find.text('12 份'),
      findsOneWidget,
      reason: '份数必须来自汇总；显示 2 说明页面在数已加载的那一页',
    );
    expect(
      find.textContaining('最近 4/5'),
      findsOneWidget,
      reason: '色块上要给最近一次成绩，否则家长得逐份点进去才知道学会没有',
    );
    // 平铺的「日期 · 难度 · 共 N 题」行不该出现在已完成区（学生走分组）。
    expect(find.textContaining('共 5 题'), findsNothing);
  });

  testWidgets('学生：点科目色块 → 推上那一科的记录页，且请求真的带了 subject', (tester) async {
    registerStudent();
    final repo = _FakeRepo(
      quizzes: [_done('a', '数学')],
      summaries: const [CheckinSubjectSummary(subject: '数学', done: 1)],
    );

    await pumpPage(tester, repo);
    await tester.tap(find.text('数学'));
    await tester.pumpAndSettle();

    // 只断「色块存在」在回调没绑上时照样绿 —— 必须看下一页在不在。
    expect(find.text('数学 · 打卡记录'), findsOneWidget);
    expect(
      repo.lastSubject,
      '数学',
      reason: '记录页必须把科目下到请求里（客户端 filter 会把分页数搞错）',
    );
    // 记录页里那一份的得分要看得见。
    expect(find.text('4/5'), findsOneWidget);
  });

  testWidgets('学生：汇总拿不到（老服务端）→ 退回平铺列表，不出现空白的已完成区', (tester) async {
    registerStudent();
    final repo = _FakeRepo(
      quizzes: [_done('a', '数学', score: 3)],
      summaryThrows: true,
    );

    await pumpPage(tester, repo);

    expect(find.text('已完成'), findsOneWidget);
    // 平铺那一行的分数 —— 说明兜底路径真的在渲染。
    expect(find.text('3/5'), findsOneWidget);
    expect(find.text('看记录 ›'), findsNothing, reason: '没有汇总就不该有分组入口');
  });

  testWidgets('家长：已完成保持时间倒序的平铺列表（不受分组影响）', (tester) async {
    registerParent();
    final repo = _FakeRepo(
      quizzes: [_done('a', '数学')],
      // 即使服务端能给出汇总，家长也不用它。
      summaries: const [CheckinSubjectSummary(subject: '数学', done: 12)],
    );

    await pumpPage(tester, repo);

    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('12 份'), findsNothing);
    expect(find.text('4/5'), findsOneWidget, reason: '家长看的是每一份的得分');
  });

  testWidgets('未完成那一份带本科目的颜色（不是一律主题色）', (tester) async {
    registerStudent();
    final repo = _FakeRepo(
      quizzes: const [
        CheckinQuiz(
          id: 'p1',
          studentId: 'stu_001',
          quizDate: '2026-11-12',
          subject: '语文',
          status: 'pending',
          questions: [
            CheckinQuestion(
              stem: '1+1=?',
              options: ['1', '2'],
              answer: 'B',
              knowledge: '加法',
              type: CheckinQuestionType.choice,
            ),
          ],
        ),
      ],
    );

    await pumpPage(tester, repo);

    expect(find.text('未完成'), findsOneWidget);
    // 色块里那个首字「语」的底色 = 语文的科目色（不是主题蓝）。
    final tile = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('语'),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = tile.decoration as BoxDecoration;
    expect(
      decoration.color,
      subjectColor('语文').withValues(alpha: 0.18),
      reason: '科目色要在未完成的行上就生效，不能等点进去才区分',
    );
  });
}
