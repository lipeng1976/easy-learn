import 'dart:async';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/controllers/reading_controller.dart';
import 'package:easy_learn_app/models/reading_models.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/shared/reading_logs_page.dart';
import 'package:easy_learn_app/repositories/reading_repository.dart';
import 'package:easy_learn_app/services/cloud_runtime.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 打卡记录的判据。
///
/// 这里盯的是三件**不会报错**的事：
///   · 家长的孩子列表晚到时，计划页是否还会自己补拉一次（否则永远「未布置」）；
///   · 翻页是不是接着上一页取，而不是把列表重置；
///   · 快速切筛选时，迟到的旧响应会不会把新结果盖掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Get.reset();
    DatabaseService.useCloudRuntime(
      CloudRuntime(config: const DataConfig(baseUrl: 'http://127.0.0.1:8788')),
    );
  });

  tearDown(() {
    DatabaseService.useCloudRuntime(null);
    Get.reset();
  });

  String day(DateTime at) =>
      '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';

  ReadingTask task() => const ReadingTask(
        id: 'rt_1',
        bookId: 'rb_1',
        bookTitle: '感动世界的文字',
        doneLessons: 3,
        totalLessons: 96,
        nextLessonNo: 4,
        readLessonNos: [1, 2, 3],
      );

  ReadingLogEntry entry(int lessonNo, {String? dayText, String title = ''}) =>
      ReadingLogEntry(
        id: 'rl_$lessonNo',
        taskId: 'rt_1',
        bookId: 'rb_1',
        bookTitle: '感动世界的文字',
        lessonNo: lessonNo,
        day: dayText ?? day(DateTime.now()),
        lessonTitle: title.isEmpty ? 'Lesson $lessonNo' : title,
        readAt: DateTime.now(),
      );

  void loginStudent() {
    Get.put(AuthController()).currentUser.value = UserModel(
      id: 'stu_1',
      name: '林小宇',
      phone: '13800000001',
      role: 'student',
      avatar: '🧒',
    );
  }

  group('家长的孩子列表晚到', () {
    test('先到的是空列表：任务不请求，等孩子到位后自动补拉', () async {
      Get.put(AuthController()).currentUser.value = UserModel(
        id: 'par_1',
        name: '妈妈',
        phone: '13800000002',
        role: 'parent',
        avatar: '👩',
      );
      // loadData 里是一串串行查询，测试里换成空实现 —— 这里要验的是
      // 「孩子列表晚到」这个时序，不是家长端的整包加载。
      final parent = Get.put<ParentController>(_NoLoadParentController());
      final repo = _FakeReadingRepository(tasks: [task()]);
      final reading = Get.put(ReadingController(repository: repo));

      await reading.load();
      expect(
        repo.taskCalls,
        0,
        reason: '还不知道挂在谁名下，就不该发一个必然失败的请求',
      );
      expect(reading.error.value, isNull, reason: '这不是错误，只是还没就绪');

      parent.boundStudents.assignAll(const [ParentChild(id: 'stu_1', name: '林小宇')]);
      await pumpEventQueue(times: 20);

      expect(repo.taskCalls, 1, reason: '孩子到位后没有补拉，家长会永远看到「未布置」');
      expect(reading.tasks.length, 1);
    });
  });

  group('记录分页', () {
    test('加载更多是接着上一页取，不清空已有记录', () async {
      loginStudent();
      final repo = _FakeReadingRepository(
        tasks: [task()],
        // 第一页 3 条、第二页 2 条，服务端 total=5。
        pages: {
          0: ReadingLogPage(
            logs: [entry(3), entry(2), entry(1)],
            total: 5,
            hasMore: true,
          ),
          3: ReadingLogPage(
            logs: [entry(0), entry(1, dayText: '2026-11-01')],
            total: 5,
            hasMore: false,
          ),
        },
      );
      final reading = Get.put(ReadingController(repository: repo));

      await reading.loadLogs(from: '2026-11-01', to: '2026-11-07');
      expect(reading.logs.length, 3);
      expect(reading.logsTotal.value, 5);
      expect(reading.logsHasMore.value, isTrue);

      await reading.loadLogs(append: true);
      expect(reading.logs.length, 5, reason: '翻页要把新的一页接在后面');
      expect(reading.logsHasMore.value, isFalse);
      expect(repo.logOffsets, [0, 3]);
      // 翻页必须沿用第一页的窗口。带了别的窗口就会混进另一段时间的记录。
      expect(repo.logQueries.last.from, '2026-11-01');
      expect(repo.logQueries.last.to, '2026-11-07');
    });

    test('快速切筛选：迟到的旧响应不能盖掉新结果', () async {
      loginStudent();
      final first = Completer<ReadingLogPage>();
      final second = Completer<ReadingLogPage>();
      final repo = _FakeReadingRepository(
        tasks: [task()],
        pending: [first, second],
      );
      final reading = Get.put(ReadingController(repository: repo));

      final a = reading.loadLogs(from: '2026-11-07', to: '2026-11-07'); // 今天
      final b = reading.loadLogs(from: null, to: null); // 全部
      // 后点的「全部」先回来，先点的「今天」后回来 —— 正是弱网下常见的顺序。
      second.complete(ReadingLogPage(logs: [entry(3), entry(2)], total: 2));
      await b;
      first.complete(ReadingLogPage(logs: [entry(3)], total: 1));
      await a;
      await pumpEventQueue(times: 10);

      expect(
        reading.logs.length,
        2,
        reason: '界面选中的是「全部」，却被「今天」的结果盖掉了',
      );
      expect(reading.logsTotal.value, 2);
    });
  });

  group('记录页', () {
    testWidgets('按天分组、报总数、能切到「全部」', (tester) async {
      loginStudent();
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));
      final repo = _FakeReadingRepository(
        tasks: [task()],
        pages: {
          0: ReadingLogPage(
            logs: [
              entry(3),
              entry(2, dayText: day(yesterday)),
            ],
            total: 2,
          ),
        },
      );
      Get.put(ReadingController(repository: repo));

      await tester.pumpWidget(const GetMaterialApp(home: ReadingLogsPage()));
      await tester.pumpAndSettle();

      expect(find.text('共 2 次打卡'), findsOneWidget);
      expect(find.text('第 3 篇'), findsOneWidget);
      expect(find.text('第 2 篇'), findsOneWidget);
      // 今天的日期头要写「今天」，否则家长得自己对照日历。
      expect(find.textContaining('今天 ·'), findsOneWidget);
      expect(find.textContaining('昨天 ·'), findsOneWidget);

      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();

      final last = repo.logQueries.last;
      expect(last.from, isNull, reason: '「全部」必须是真全量，不能偷偷带一个窗口');
      expect(last.to, isNull);
    });

    testWidgets('空记录要说清是「这段没读」还是「一次都没读」', (tester) async {
      loginStudent();
      final repo = _FakeReadingRepository(
        tasks: [task()],
        pages: {0: const ReadingLogPage()},
      );
      Get.put(ReadingController(repository: repo));

      await tester.pumpWidget(const GetMaterialApp(home: ReadingLogsPage()));
      await tester.pumpAndSettle();

      expect(find.textContaining('这段时间没有打卡记录'), findsOneWidget);

      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();

      expect(find.textContaining('还没有任何阅读打卡记录'), findsOneWidget);
      expect(find.textContaining('这段时间没有打卡记录'), findsNothing);
    });
  });
}

/// `loadData` 换成空实现：它是一串串行查询，与这里要验的时序无关。
class _NoLoadParentController extends ParentController {
  @override
  Future<void> loadData() async {}
}

/// 可编排的假仓库。
class _FakeReadingRepository implements ReadingRepository {
  _FakeReadingRepository({
    this.tasks = const [],
    this.pages = const {},
    this.pending = const [],
  });

  final List<ReadingTask> tasks;

  /// `offset → 一页数据`。
  final Map<int, ReadingLogPage> pages;

  /// 非空时按调用顺序返回这些 Completer 的 future（用来编排「迟到的响应」）。
  final List<Completer<ReadingLogPage>> pending;

  int taskCalls = 0;
  final List<int> logOffsets = [];
  final List<({String? from, String? to})> logQueries = [];

  @override
  Future<List<ReadingTask>> listTasks({String? studentId}) async {
    taskCalls += 1;
    return tasks;
  }

  @override
  Future<ReadingLogPage> listLogs({
    String? studentId,
    String? from,
    String? to,
    int limit = 50,
    int offset = 0,
  }) async {
    if (pending.isNotEmpty) {
      final index = logQueries.length;
      logQueries.add((from: from, to: to));
      logOffsets.add(offset);
      return pending[index].future;
    }
    logQueries.add((from: from, to: to));
    logOffsets.add(offset);
    return pages[offset] ?? const ReadingLogPage();
  }

  Never _unused() => throw UnimplementedError('记录相关的用例不该调这个方法');

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
