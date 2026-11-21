import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/reading_controller.dart';
import 'package:easy_learn_app/models/reading_models.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/parent/reading_setup_page.dart';
import 'package:easy_learn_app/repositories/reading_repository.dart';
import 'package:easy_learn_app/services/cloud_runtime.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 家长「英文阅读」设置页的判据。
///
/// 这一页最容易出的不是崩溃，而是**安静的消失**：导入第一本书之后，
/// 「从 ima 导入」区块里只剩一行「已导入」，家长再也找不到第二次导入的入口。
/// 数据没问题（服务端确实返回了目录里全部 md），错在界面上没有
/// 「再看一眼知识库」这个动作 —— 所以判据要盯住**按钮在不在**，
/// 而不是盯住列表长度。
class _FakeReadingRepository implements ReadingRepository {
  _FakeReadingRepository({
    List<ReadingAvailableBook>? available,
    List<ReadingBook>? books,
    List<ReadingTask>? tasks,
  })  : available = List.of(available ?? const []),
        books = List.of(books ?? const []),
        tasks = List.of(tasks ?? const []);

  List<ReadingAvailableBook> available;
  List<ReadingBook> books;
  List<ReadingTask> tasks;

  /// 每次 `listAvailableBooks` 被调用就 +1。用来证明「刷新真的重新问了知识库」。
  int availableCalls = 0;
  Object? availableError;

  @override
  Future<List<ReadingAvailableBook>> listAvailableBooks({String? studentId}) async {
    availableCalls += 1;
    if (availableError != null) throw availableError!;
    return List.of(available);
  }

  @override
  Future<List<ReadingBook>> listBooks({String? studentId}) async => List.of(books);

  @override
  Future<List<ReadingTask>> listTasks({String? studentId}) async => List.of(tasks);

  @override
  Future<ReadingImportResult> importBook({
    required String mediaId,
    String? studentId,
    String fileName = '',
    String title = '',
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<List<ReadingLessonSummary>> listLessons({
    required String bookId,
    String? studentId,
  }) async =>
      const [];

  @override
  Future<ReadingLesson> getLesson({
    required String bookId,
    required int lessonNo,
    String? studentId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<({ReadingTask task, bool created})> createTask({
    required String bookId,
    String? studentId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<ReadingReadResult> readLesson({
    required String taskId,
    required int lessonNo,
    required String day,
    String? studentId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<ReadingTask> cancelTask({required String taskId, String? studentId}) async =>
      throw UnimplementedError();

  @override
  Future<ReadingLogPage> listLogs({
    String? studentId,
    String? from,
    String? to,
    int limit = 50,
    int offset = 0,
  }) async =>
      const ReadingLogPage();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 每个用例都从干净的容器开始：上一轮的控制器会带着旧的 fake repo 留下来，
    // 表现是「第一条过、后面全红」，很容易被误读成页面逻辑有问题。
    Get.reset();
    DatabaseService.useCloudRuntime(
      CloudRuntime(config: const DataConfig(baseUrl: 'http://127.0.0.1:8788')),
    );
    Get.put(AuthController()).currentUser.value = UserModel(
      id: 'stu_001',
      name: '林小宇',
      phone: '13800000002',
      role: 'student',
      avatar: '🧒',
    );
    // ⚠️ 这里用**学生身份**而不是家长：家长端的「当前学生」要经
    // `ParentController.boundStudents` 这一跳，而那是个异步加载的列表。
    // 测试里造它只会把两个无关的关注点绞在一起（试过，`Get.put`
    // 在同一个容器里连跑会撞生命周期异常）。页面本身不区分角色，
    // 学生口径同样能验证「书列表怎么渲染、刷新有没有真的重问」。
  });

  tearDown(() {
    DatabaseService.useCloudRuntime(null);
    Get.reset();
  });

  /// 页面本体。用 `Get.put` 先注册控制器，页面 initState 里会 `Get.find` 复用。
  Future<_FakeReadingRepository> pumpSetup(
    WidgetTester tester, {
    List<ReadingAvailableBook>? available,
    List<ReadingBook>? books,
    Object? availableError,
  }) async {
    final repo = _FakeReadingRepository(available: available, books: books)
      ..availableError = availableError;
    Get.put(ReadingController(repository: repo));

    await tester.pumpWidget(
      const GetMaterialApp(home: ReadingSetupPage()),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  ReadingAvailableBook availableBook(String mediaId, String title, {String? doneId}) =>
      ReadingAvailableBook(
        mediaId: mediaId,
        fileName: '$title.md',
        title: title,
        importedBookId: doneId,
        importedLessonCount: doneId == null ? 0 : 96,
      );

  testWidgets('目录里两本书、只导过一本 → 另一本仍然要给「导入」按钮', (tester) async {
    await pumpSetup(
      tester,
      available: [
        availableBook('m_2', '提高篇'),
        availableBook('m_1', '基础篇', doneId: 'rb_1'),
      ],
      books: [
        const ReadingBook(id: 'rb_1', title: '基础篇', lessonCount: 96),
      ],
    );

    // 这本没导过的必须还能导 —— 这正是「只能导第一本」那个 bug 的判据。
    expect(find.text('提高篇'), findsOneWidget);
    expect(find.text('导入'), findsOneWidget);

    // 已导入的那本不该再给按钮（点了也只是把同一本书返回一次）。
    expect(find.text('已导入'), findsOneWidget);
  });

  testWidgets('点「刷新知识库」会重新问 ima，新放进目录的书立刻出现', (tester) async {
    final repo = await pumpSetup(
      tester,
      available: [availableBook('m_1', '基础篇', doneId: 'rb_1')],
      books: [
        const ReadingBook(id: 'rb_1', title: '基础篇', lessonCount: 96),
      ],
    );

    expect(find.text('提高篇'), findsNothing);
    expect(repo.availableCalls, 1);

    // 家长在 ima 里新传了一本，然后回来点刷新。
    repo.available = [
      availableBook('m_2', '提高篇'),
      availableBook('m_1', '基础篇', doneId: 'rb_1'),
    ];

    await tester.tap(find.byTooltip('刷新知识库'));
    await tester.pumpAndSettle();

    expect(repo.availableCalls, 2, reason: '刷新必须真的再问一次知识库');
    expect(find.text('提高篇'), findsOneWidget);
    expect(find.text('导入'), findsOneWidget);
  });

  testWidgets('读知识库失败时，已经读到的书不能跟着消失', (tester) async {
    final repo = await pumpSetup(
      tester,
      available: [
        availableBook('m_2', '提高篇'),
        availableBook('m_1', '基础篇', doneId: 'rb_1'),
      ],
      books: [
        const ReadingBook(id: 'rb_1', title: '基础篇', lessonCount: 96),
      ],
    );

    expect(find.text('提高篇'), findsOneWidget);

    // 网络抖一下 / ima 侧 500 —— 列表要保留，只提示这次没读到。
    repo.availableError = Exception('ima 500');
    await tester.tap(find.byTooltip('刷新知识库'));
    await tester.pumpAndSettle();

    expect(find.text('提高篇'), findsOneWidget, reason: '拉取失败不该清空上次的结果');
    // 关键判据：ima 是可选功能，它读失败**不是整页故障**。
    // 旧实现把 `e.userMessage` 写进 controller.error → 页面顶部红色横幅。
    expect(
      find.byKey(const Key('library_error_banner')),
      findsNothing,
      reason: '可选功能失败不能变成红色错误横幅',
    );
  });

  testWidgets('ima 接口抛 DataApiException：不能变成红色横幅，入口要留着刷新', (tester) async {
    // 与上面那条普通 Exception 分开：`loadLibrary` 有两个 catch 分支，
    // 旧实现两个都写 `error.value`，只盯一个会漏掉另一半（11-07 证伪时发现的）。
    await pumpSetup(
      tester,
      books: [const ReadingBook(id: 'rb_1', title: '基础篇', lessonCount: 96)],
      availableError: const DataApiException(code: 'internal', message: '服务端开小差了'),
    );

    expect(find.byKey(const Key('library_error_banner')), findsNothing);
    expect(find.text('从 ima 导入'), findsOneWidget, reason: '临时故障要留刷新入口');
    expect(find.text('基础篇'), findsOneWidget);
  });

  testWidgets('没开通 ima：「从 ima 导入」整块不出现，也不弹任何错误', (tester) async {
    await pumpSetup(
      tester,
      books: [const ReadingBook(id: 'rb_1', title: '基础篇', lessonCount: 96)],
      availableError: const ImaBookSourceUnavailable(),
    );

    // 功能可以没有。
    expect(find.text('从 ima 导入'), findsNothing);
    expect(find.byTooltip('刷新知识库'), findsNothing);
    // 但不能出错：没有红条，已导入的书和任务照常在。
    expect(find.byKey(const Key('library_error_banner')), findsNothing);
    expect(find.text('基础篇'), findsOneWidget);
  });

  testWidgets('没开通 ima 且书库为空：空态不能把家长指向已隐藏的区块', (tester) async {
    await pumpSetup(
      tester,
      availableError: const ImaBookSourceUnavailable(),
    );

    expect(find.textContaining('下面的「从 ima 导入」'), findsNothing);
    expect(find.byKey(const Key('library_error_banner')), findsNothing);
  });
}
