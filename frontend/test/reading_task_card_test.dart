import 'package:easy_learn_app/constants/app_colors.dart';
import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/reading_controller.dart';
import 'package:easy_learn_app/models/reading_models.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/repositories/reading_repository.dart';
import 'package:easy_learn_app/services/cloud_runtime.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/widgets/reading_task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 阅读任务入口卡的判据。
///
/// 三态必须分开渲染，这是整张卡唯一容易写错的地方：
///
///   ① 有进行中的任务 → 浅绿 + 进度 + 「读第 N 篇」；
///   ② 任务读完了 → 白卡 + 「已读完」，**不能再催**；
///   ③ 一本书都没有 → 「未布置」（学生看到「等家长布置」）。
///
/// ② 和 ③ 都是「现在没东西读」，但含义相反。写成同一句「暂无阅读任务」，
/// 孩子会以为自己的成绩丢了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void useFakeCloud() {
    DatabaseService.useCloudRuntime(
      CloudRuntime(config: const DataConfig(baseUrl: 'http://127.0.0.1:8788')),
    );
  }

  tearDown(() {
    DatabaseService.useCloudRuntime(null);
    Get.reset();
  });

  Widget host({bool isParent = false, String? taskId}) => GetMaterialApp(
        initialRoute: '/entry',
        getPages: [
          GetPage(
            name: '/entry',
            page: () => Scaffold(body: ReadingTaskCard(isParent: isParent)),
          ),
          GetPage(
            name: '/reading',
            page: () => const Scaffold(body: Text('READING_PAGE')),
          ),
          GetPage(
            name: '/reading-setup',
            page: () => const Scaffold(body: Text('SETUP_PAGE')),
          ),
          GetPage(
            name: '/reading-logs',
            page: () => const Scaffold(body: Text('LOGS_PAGE')),
          ),
        ],
      );

  void registerStudent() {
    Get.put(AuthController()).currentUser.value = UserModel(
      id: 'stu_001',
      name: '林小宇',
      phone: '13800000001',
      role: 'student',
      avatar: '🧒',
    );
  }

  ReadingTask task({
    int done = 0,
    int total = 96,
    int? next = 1,
    String status = 'active',
    bool finished = false,
    List<int> read = const [],
  }) =>
      ReadingTask(
        id: 'rt_1',
        bookId: 'rb_1',
        bookTitle: '感动世界的文字',
        status: status,
        doneLessons: done,
        totalLessons: total,
        nextLessonNo: next,
        finished: finished,
        readLessonNos: read,
      );

  testWidgets('本地模式：整张卡不渲染', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('阅读打卡'), findsNothing);
    expect(find.text('布置阅读任务'), findsNothing);
  });

  testWidgets('有进行中的任务：浅绿 + 进度 + 「读第 N 篇」', (tester) async {
    useFakeCloud();
    registerStudent();
    Get.put(ReadingController(repository: _FakeReadingRepo([task(done: 3, next: 4, read: [1, 2, 3])])));

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('阅读打卡'), findsOneWidget);
    expect(find.text('《感动世界的文字》'), findsOneWidget);
    expect(find.text('3/96 篇'), findsOneWidget);
    expect(find.text('读第 4 篇'), findsOneWidget,
        reason: '按钮要指向下一篇，不能只说「继续阅读」');
    expect(find.text('还剩 93 篇'), findsOneWidget);

    final card = tester.widget<Card>(find.byType(Card));
    expect(
      card.color,
      Color.alphaBlend(AppColors.success.withValues(alpha: 0.14), AppColors.card),
      reason: '还有没读的，要用绿色催',
    );
  });

  testWidgets('读完了：白卡 + 「已读完」，不再催', (tester) async {
    useFakeCloud();
    registerStudent();
    Get.put(ReadingController(
      repository: _FakeReadingRepo([
        task(done: 96, total: 96, next: null, status: 'done', finished: true),
      ]),
    ));

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('已读完'), findsOneWidget);
    expect(find.text('还剩 0 篇'), findsNothing, reason: '读完就不该再显示「还剩」');
    expect(find.text('《感动世界的文字》已读完，共 96 篇。'), findsOneWidget);
    expect(find.text('等家长安排下一本书。'), findsOneWidget);

    final card = tester.widget<Card>(find.byType(Card));
    expect(card.color, AppColors.card, reason: '读完就要退场，不能继续绿着');
  });

  testWidgets('一本书都没有：学生看到「未布置」，且不给布置按钮', (tester) async {
    useFakeCloud();
    registerStudent();
    Get.put(ReadingController(repository: _FakeReadingRepo(const [])));

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('未布置'), findsOneWidget);
    expect(find.text('家长还没给你布置阅读任务。'), findsOneWidget);
    // 学生端不放「布置」按钮：布置是家长的动作。
    expect(find.text('布置阅读任务'), findsNothing);
  });

  testWidgets('家长看到「布置阅读任务」并能进配置页', (tester) async {
    useFakeCloud();
    registerStudent();
    Get.put(ReadingController(repository: _FakeReadingRepo(const [])));

    await tester.pumpWidget(host(isParent: true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('布置阅读任务'));
    await tester.pumpAndSettle();

    expect(find.text('SETUP_PAGE'), findsOneWidget);
  });

  // ===== 打卡记录 =====
  //
  // 这一组防的是「打完卡什么都看不到」：进度 +1 是唯一的变化，孩子
  // 无法确认这次到底记上没有。判据必须看**渲染出来的文字**，
  // 只看 `controller.todayLogs` 为空与否抓不住「页面没接上」。

  String day(DateTime at) =>
      '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';

  ReadingLogEntry log(int lessonNo, {String? dayText}) => ReadingLogEntry(
        id: 'rl_$lessonNo',
        taskId: 'rt_1',
        bookId: 'rb_1',
        bookTitle: '感动世界的文字',
        lessonNo: lessonNo,
        day: dayText ?? day(DateTime.now()),
        lessonTitle: 'Lesson $lessonNo',
        readAt: DateTime.now(),
      );

  testWidgets('今天读过：卡上写「今天已读 2 篇」，且只查今天', (tester) async {
    useFakeCloud();
    registerStudent();
    final repo = _FakeReadingRepo(
      [task(done: 3, next: 4, read: [1, 2, 3])],
      logs: [log(3), log(2)],
    );
    Get.put(ReadingController(repository: repo));

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.textContaining('今天已读 2 篇'), findsOneWidget);
    // 窗口必须是「今天 → 今天」：不带窗口就会把全部历史当今天。
    expect(repo.logQueries, isNotEmpty, reason: '计划页根本没查记录');
    final q = repo.logQueries.first;
    expect(q.from, day(DateTime.now()));
    expect(q.to, day(DateTime.now()));
    expect(q.limit, 0, reason: '一天最多几十条，不该分页');
  });

  testWidgets('今天没读：写「今天还没打卡」，不显示数字', (tester) async {
    useFakeCloud();
    registerStudent();
    Get.put(ReadingController(repository: _FakeReadingRepo([task(done: 3, next: 4)])));

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('今天还没打卡'), findsOneWidget);
    expect(find.textContaining('今天已读'), findsNothing);
  });

  testWidgets('已读完的卡也能看记录 —— 这正是最常发现「记录没了」的时候', (tester) async {
    useFakeCloud();
    registerStudent();
    Get.put(ReadingController(
      repository: _FakeReadingRepo(
        [task(done: 96, total: 96, next: null, status: 'done', finished: true)],
        logs: [log(96)],
      ),
    ));

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.textContaining('今天已读 1 篇'), findsOneWidget);
    expect(find.text('全部记录'), findsOneWidget);
  });

  testWidgets('任务被家长取消后，历史记录仍然进得去', (tester) async {
    useFakeCloud();
    registerStudent();
    // 取消的任务既不是 active 也不是 finished —— 卡回到「未布置」。
    // 但那些打卡记录还在库里，入口不能跟着消失。
    Get.put(ReadingController(
      repository: _FakeReadingRepo([
        task(done: 3, next: null, status: 'cancelled', read: [1, 2, 3]),
      ]),
    ));

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('未布置'), findsOneWidget);
    expect(find.text('全部记录'), findsOneWidget);
  });

  testWidgets('点「全部记录」进记录页；家长端同样有入口', (tester) async {
    useFakeCloud();
    registerStudent();
    Get.put(ReadingController(repository: _FakeReadingRepo([task(done: 3, next: 4)])));

    await tester.pumpWidget(host(isParent: true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('全部记录'));
    await tester.pumpAndSettle();

    expect(find.text('LOGS_PAGE'), findsOneWidget);
  });
}

/// 只回任务的假仓库。
///
/// 其余方法一律抛错：这条用例只关心卡片怎么读 `tasks`，
/// 如果有人在这里意外调了别的方法，应该**当场炸**而不是拿到一个空值
/// 继续往下走（那会让「卡片读错了接口」这种 bug 变得看不见）。
class _FakeReadingRepo implements ReadingRepository {
  _FakeReadingRepo(this._tasks, {this.logs = const []});

  final List<ReadingTask> _tasks;

  /// 「今天」的打卡记录。
  final List<ReadingLogEntry> logs;

  /// 每次查记录用的窗口。用来钉住「计划页只查今天」——
  /// 不带窗口的话，`todayLogs` 会装进全部历史，卡上就会显示
  /// 「今天已读 96 篇」。
  final List<({String? from, String? to, int limit})> logQueries = [];

  @override
  Future<List<ReadingTask>> listTasks({String? studentId}) async => _tasks;

  @override
  Future<ReadingLogPage> listLogs({
    String? studentId,
    String? from,
    String? to,
    int limit = 50,
    int offset = 0,
  }) async {
    logQueries.add((from: from, to: to, limit: limit));
    return ReadingLogPage(logs: logs, total: logs.length);
  }

  Never _unused() => throw UnimplementedError('入口卡不该调这个方法');

  @override
  Future<List<ReadingAvailableBook>> listAvailableBooks({String? studentId}) async => _unused();

  @override
  Future<ReadingImportResult> importBook({
    required String mediaId,
    String? studentId,
    String fileName = '',
    String title = '',
  }) async =>
      _unused();

  @override
  Future<List<ReadingBook>> listBooks({String? studentId}) async => _unused();

  @override
  Future<List<ReadingLessonSummary>> listLessons({
    required String bookId,
    String? studentId,
  }) async =>
      _unused();

  @override
  Future<ReadingLesson> getLesson({
    required String bookId,
    required int lessonNo,
    String? studentId,
  }) async =>
      _unused();

  @override
  Future<({ReadingTask task, bool created})> createTask({
    required String bookId,
    String? studentId,
  }) async =>
      _unused();

  @override
  Future<ReadingReadResult> readLesson({
    required String taskId,
    required int lessonNo,
    required String day,
    String? studentId,
  }) async =>
      _unused();

  @override
  Future<ReadingTask> cancelTask({required String taskId, String? studentId}) async => _unused();
}
