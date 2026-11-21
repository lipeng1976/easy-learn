import 'dart:async';

import 'package:get/get.dart';

import '../models/reading_models.dart';
import '../repositories/reading_repository.dart';
import '../services/data_api_client.dart';
import '../services/database_service.dart';
import 'checkin_controller.dart';
import 'parent_controller.dart';

/// 英文阅读的状态。
///
/// ## 一个任务，一条进度，没有「今天」
///
/// 任务是长期挂在一本书上的（见 `sql/023_reading.sql`）。所以这里没有
/// 「今日阅读」这种派生状态：[ReadingTask.doneLessons] 就是全部真相，
/// 断更三天再打开，卡片上的数字原样不动。
///
/// 卡片上的「今天读了几篇」如果以后要显示，应该按 [ReadingTask.readLessonNos]
/// 之外的 `reading_log.day` 去算 —— 但现在**不做**：多一个按天的口径，
/// 就多一处会和「任务进度」打架的数字。
///
/// ## 这个控制器同时服务三个界面
///
///   · 计划页的入口卡（只读 [tasks] 里进行中的那份）；
///   · 学生阅读页（打开某一课、打卡）；
///   · 家长的选书/布置页（[books]、[available]、[createTask]）。
///
/// 合成一个而不是三个，是因为「导入一本新书 → 立刻布置 → 学生端看到」
/// 这三步共享同一份缓存。拆开的话，导入成功后家长页仍然显示旧书列表 ——
/// 而它不会报错，只是看起来「导入没成功」。
class ReadingController extends GetxController {
  ReadingController({
    ReadingRepository? repository,
    DateTime Function()? clock,
  })  : _repo = repository ?? DatabaseService.reading,
        _clock = clock ?? _defaultClock;

  static DateTime _defaultClock() => DateTime.now();

  final ReadingRepository _repo;
  final DateTime Function() _clock;

  /// 任务（进行中在前，服务端已排好序）。
  final RxList<ReadingTask> tasks = <ReadingTask>[].obs;

  /// 已导入的书。
  final RxList<ReadingBook> books = <ReadingBook>[].obs;

  /// ima 侧可导入的书。
  final RxList<ReadingAvailableBook> available = <ReadingAvailableBook>[].obs;

  /// 正在读的那一课（阅读页）。
  final Rxn<ReadingLesson> lesson = Rxn<ReadingLesson>();

  /// 正在读的那份任务。
  final Rxn<ReadingTask> currentTask = Rxn<ReadingTask>();

  final RxBool loading = false.obs;
  final RxBool loadingLibrary = false.obs;
  final RxBool lessonLoading = false.obs;
  final RxBool busy = false.obs;
  final RxBool importing = false.obs;

  /// 页面级失败原因（已是可直接展示的中文）。null = 没错。
  ///
  /// ⚠️ 只给**核心功能**（已导入书库 / 任务）用。ima 是可选的，
  /// 它的任何失败都走 [availableHint]，不许变成页面顶部的红色横幅。
  final RxnString error = RxnString();

  /// ima 书源是否可用：`false` = 没开通（「从 ima 导入」整块隐藏），
  /// `true` = 可用，`null` = 还没问到 / 这次没读到（保留入口给刷新）。
  final Rxn<bool> imaBooksAvailable = Rxn<bool>();

  /// 「从 ima 导入」区的灰字说明（这次没读到 / 导入失败）。
  final RxnString availableHint = RxnString();

  // ===== 打卡记录 =====
  //
  // 与 [tasks] 分开两份状态，是刻意的：
  //   · [todayLogs] 只服务计划页那张卡（今天读了没有），一次小请求；
  //   · [logs] 服务记录页（带筛选和分页），可能翻到几十上百条。
  // 合成一份的话，记录页翻到第 5 页再回计划页，卡上就会拿「最近 30 条」
  // 里的今天去算 —— 而今天可能根本没在那 30 条里。

  /// 今天的打卡记录（计划页的阅读卡直接用）。
  final RxList<ReadingLogEntry> todayLogs = <ReadingLogEntry>[].obs;
  final RxBool todayLogsLoading = false.obs;

  /// 读今天记录失败的原因。**不并入 [error]**：记录读不到不该让整张卡
  /// 变成红色错误（进度还在，只是少一行「今天读了什么」）。
  final RxnString todayLogsError = RxnString();

  /// 记录页的数据。
  final RxList<ReadingLogEntry> logs = <ReadingLogEntry>[].obs;
  final RxBool logsLoading = false.obs;
  final RxBool logsLoadingMore = false.obs;
  final RxBool logsHasMore = false.obs;
  final RxInt logsTotal = 0.obs;
  final RxnString logsError = RxnString();

  /// 一页 30 条：一个月每天读一篇正好一页，弱网下也不会等太久。
  static const int logsPageSize = 30;

  /// 记录页当前的查询窗口（翻页时要原样带上）。
  String? _logsFrom;
  String? _logsTo;

  /// 筛选切换时用来丢弃**上一个筛选**迟到的响应。
  ///
  /// 没有它的话：点「今天」→ 立刻点「全部」，两个请求并行回来，
  /// 后回来的「今天」会把「全部」覆盖掉，而界面上的选中项是「全部」。
  int _logsGeneration = 0;

  /// 家长端「孩子还没绑好」时的重试订阅。
  Worker? _studentReady;

  /// 进行中的任务。**只取第一份**：模型上「一本书一个进行中任务」，
  /// 但不同书可以各有一份 —— 学生端入口卡按约定显示最靠前的那份，
  /// 其余的在阅读页里翻。
  ReadingTask? get activeTask {
    for (final task in tasks) {
      if (task.isActive) return task;
    }
    return null;
  }

  /// 有进行中的任务在催。
  bool get hasActive => activeTask != null;

  /// 已读完的任务（最近一份）—— 入口卡在「没有进行中」时用它说「已读完 X 本」。
  ReadingTask? get lastFinished {
    for (final task in tasks) {
      if (task.finished) return task;
    }
    return null;
  }

  ReadingTask? taskById(String id) {
    for (final task in tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  /// 「当前是哪个学生」—— 与打卡**同一个口径**。
  ///
  /// 复用 `CheckinController.targetStudentId()` 而不是再写一份：那是全工程
  /// 「学生是自己、家长是第一个结伴孩子」的单点定义。两处各写一份的话，
  /// 哪天多孩子切换 UI 落地，只改一处就会出现「卡查的是 A、打卡记在 B 名下」。
  static String? targetStudentId() => CheckinController.targetStudentId();

  /// 本地日（`yyyy-MM-dd`）。打卡时随请求发给服务端（R4）。
  String get today => CheckinController.formatDate(_clock());

  /// 读任务列表。失败写 [error]，不抛 —— 入口卡在 build 里调它。
  Future<void> load({String? studentId}) async {
    final id = studentId ?? targetStudentId();
    // ⚠️ 家长端有一个**真机上很难复现**的时序：`ParentController.loadData()`
    // 是异步的，而计划页的阅读卡可能先建出来。那一刻 `boundStudents` 还是空的，
    // `targetStudentId()` 返回 null；以前这里直接 return，于是家长看到的
    // 永远是「未布置」，而且**再也不会自己重试**（tab 常驻，initState 不再跑）。
    // 现在挂一个一次性订阅，等孩子列表到了再拉一次。
    if (id == null) {
      _retryWhenStudentReady();
      return;
    }
    if (!DatabaseService.isCloud) return;
    loading.value = true;
    error.value = null;
    try {
      tasks.assignAll(await _repo.listTasks(studentId: id));
    } on DataApiException catch (e) {
      error.value = e.userMessage;
    } catch (e) {
      error.value = '读取阅读任务失败：$e';
    } finally {
      loading.value = false;
    }
  }

  /// 等家长的学生列表就绪后补拉一次。
  ///
  /// 只在「确实有一个家长控制器、且它的孩子列表还是空的」时订阅 ——
  /// 学生端不存在这个控制器，直接跳过。
  void _retryWhenStudentReady() {
    if (_studentReady != null) return;
    if (!Get.isRegistered<ParentController>()) return;
    final parent = Get.find<ParentController>();
    if (parent.boundStudents.isNotEmpty) return;
    _studentReady = ever(parent.boundStudents, (value) {
      if (value.isEmpty) return;
      _studentReady?.dispose();
      _studentReady = null;
      load();
      loadTodayLogs();
    });
  }

  @override
  void onClose() {
    _studentReady?.dispose();
    _studentReady = null;
    super.onClose();
  }

  /// 今天的打卡记录。失败只写 [todayLogsError]，**不清空上一次的结果** ——
  /// 网络抖一下就把「今天读了 2 篇」抹掉，家长会以为孩子没读。
  Future<void> loadTodayLogs({String? studentId}) async {
    final id = studentId ?? targetStudentId();
    if (id == null) {
      _retryWhenStudentReady();
      return;
    }
    if (!DatabaseService.isCloud) return;
    todayLogsLoading.value = true;
    todayLogsError.value = null;
    try {
      final page = await _repo.listLogs(
        studentId: id,
        from: today,
        to: today,
        // 一天最多几十篇，不分页。
        limit: 0,
      );
      todayLogs.assignAll(page.logs);
    } on DataApiException catch (e) {
      todayLogsError.value = e.userMessage;
    } catch (e) {
      todayLogsError.value = '读取今天的打卡记录失败：$e';
    } finally {
      todayLogsLoading.value = false;
    }
  }

  /// 记录页：按窗口取一页。
  ///
  /// [append] 为 true 时接着上一页往后取（沿用当前窗口，不重新设置筛选）。
  Future<void> loadLogs({
    String? studentId,
    String? from,
    String? to,
    bool append = false,
  }) async {
    final id = studentId ?? targetStudentId();
    if (id == null) {
      _retryWhenStudentReady();
      return;
    }
    if (!DatabaseService.isCloud) return;
    if (append && (logsLoadingMore.value || !logsHasMore.value)) return;

    final generation = append ? _logsGeneration : ++_logsGeneration;
    if (!append) {
      _logsFrom = from;
      _logsTo = to;
      logsLoading.value = true;
      logsError.value = null;
    } else {
      logsLoadingMore.value = true;
    }

    try {
      final page = await _repo.listLogs(
        studentId: id,
        from: append ? _logsFrom : from,
        to: append ? _logsTo : to,
        limit: logsPageSize,
        offset: append ? logs.length : 0,
      );
      // 迟到的旧筛选结果直接丢掉。**不能**只看 loading 标志 ——
      // 那个标志是「当前」请求的，分不出这份响应对应哪个窗口。
      if (generation != _logsGeneration) return;
      if (append) {
        logs.addAll(page.logs);
      } else {
        logs.assignAll(page.logs);
      }
      logsTotal.value = page.total;
      logsHasMore.value = page.hasMore;
    } on DataApiException catch (e) {
      if (generation != _logsGeneration) return;
      logsError.value = e.userMessage;
    } catch (e) {
      if (generation != _logsGeneration) return;
      logsError.value = '读取打卡记录失败：$e';
    } finally {
      if (generation == _logsGeneration) {
        logsLoading.value = false;
        logsLoadingMore.value = false;
      }
    }
  }

  /// 读书库（已导入的书 + ima 可导入的书）。
  ///
  /// 两个请求并行：弱网下串行就是两份 RTT，而这两个列表在同一个页面上
  /// 同时出现。任一成功都有东西可显示，所以不用 `Future.wait` 的
  /// 「一个失败全失败」语义 —— 分开 catch。
  Future<void> loadLibrary({String? studentId}) async {
    if (!DatabaseService.isCloud) return;
    final id = studentId ?? targetStudentId();
    if (id == null) {
      // ⚠️ 这里**不能**静默 return。
      //
      // 家长端的「当前学生」来自 `boundStudents`，而它是一次异步请求；
      // 页面进得太早或结伴关系还没拉到，这里就是 null。以前直接 return，
      // 界面表现是「没有读到可导入的书」—— 家长会跑去 ima 里翻目录，
      // 而目录里明明有书。把原因说出来，比一个空的列表诚实得多。
      error.value = '还没有找到要布置给谁 —— 先完成和孩子的结伴，再回来选书';
      loadingLibrary.value = false;
      return;
    }
    loadingLibrary.value = true;
    error.value = null;
    try {
      books.assignAll(await _repo.listBooks(studentId: id));
    } on DataApiException catch (e) {
      error.value = e.userMessage;
    } catch (e) {
      error.value = '读取书库失败：$e';
    }

    try {
      final list = await _repo.listAvailableBooks(studentId: id);
      available.assignAll(list);
      imaBooksAvailable.value = true;
      availableHint.value = null;
    } on ImaBookSourceUnavailable {
      // 没开通 ima：功能不出现。清掉上次残留的书目，避免「其实已经不可用」
      // 却还列着几本能点的书。不写 error —— 没开通不是故障。
      imaBooksAvailable.value = false;
      available.clear();
      availableHint.value = null;
    } on DataApiException catch (e) {
      // 临时读不到（网络 / 服务端抖一下）：入口与上次结果都留着给家长刷新，
      // 只给一句灰字。⚠️ 以前这里写 `error.value ??= e.userMessage`，
      // 注释却说「不是红色错误」—— 家长一进页就看到红条，正是要消灭的。
      availableHint.value = e.userMessage;
    } catch (_) {
      availableHint.value = '暂时没读到可导入的书，点右上角刷新再试。';
    } finally {
      loadingLibrary.value = false;
    }
  }

  /// 从 ima 导入一本书。返回导入结果（`null` = 失败，原因在 [availableHint]）。
  Future<ReadingImportResult?> importBook({
    required ReadingAvailableBook book,
    String? studentId,
  }) async {
    if (importing.value) return null;
    importing.value = true;
    availableHint.value = null;
    try {
      final result = await _repo.importBook(
        mediaId: book.mediaId,
        studentId: studentId ?? targetStudentId(),
        fileName: book.fileName,
        title: book.title,
      );
      // 就地更新两个列表，而不是重新拉一遍：
      //   · 已导入里可能出现这本（首次导入）；
      //   · 可导入里那一行要换成「已导入」。
      // 重拉会多两次 RTT，还会让页面闪一下。
      final index = books.indexWhere((b) => b.id == result.book.id);
      if (index >= 0) {
        books[index] = result.book;
      } else {
        books.insert(0, result.book);
      }
      final at = available.indexWhere((b) => b.mediaId == book.mediaId);
      if (at >= 0) {
        available[at] = ReadingAvailableBook(
          mediaId: book.mediaId,
          fileName: book.fileName,
          title: result.book.title,
          importedBookId: result.book.id,
          importedLessonCount: result.book.lessonCount,
        );
      }
      return result;
    } on DataApiException catch (e) {
      // 导入是家长主动点的动作，给反馈；但也不写页面级红色 error。
      availableHint.value = e.userMessage;
      return null;
    } catch (_) {
      availableHint.value = '导入没成功，请稍后重试。';
      return null;
    } finally {
      importing.value = false;
    }
  }

  /// 布置任务（一本书一个进行中任务）。
  ///
  /// `created == false` 表示这本书本来就在读 —— 界面要说「继续读」，
  /// 而不是假装刚刚布置了一份新任务。
  Future<({ReadingTask task, bool created})?> createTask({
    required ReadingBook book,
    String? studentId,
  }) async {
    if (busy.value) return null;
    busy.value = true;
    error.value = null;
    try {
      final result = await _repo.createTask(
        bookId: book.id,
        studentId: studentId ?? targetStudentId(),
      );
      _upsertTask(result.task);
      // 书上的「进行中任务数」跟着变，否则按钮还写着「布置」。
      final at = books.indexWhere((b) => b.id == book.id);
      if (at >= 0) books[at] = _withActiveTask(books[at], books[at].activeTaskCount + (result.created ? 1 : 0));
      return result;
    } on DataApiException catch (e) {
      error.value = e.userMessage;
      return null;
    } catch (e) {
      error.value = '布置任务失败：$e';
      return null;
    } finally {
      busy.value = false;
    }
  }

  /// 取消任务（家长）。
  Future<bool> cancelTask(ReadingTask task, {String? studentId}) async {
    if (busy.value) return false;
    busy.value = true;
    error.value = null;
    try {
      final updated = await _repo.cancelTask(
        taskId: task.id,
        studentId: studentId ?? targetStudentId(),
      );
      _upsertTask(updated);
      return true;
    } on DataApiException catch (e) {
      error.value = e.userMessage;
      return false;
    } catch (e) {
      error.value = '取消任务失败：$e';
      return false;
    } finally {
      busy.value = false;
    }
  }

  /// 打开某一课（阅读页）。
  Future<void> openLesson({
    required ReadingTask task,
    required int lessonNo,
    String? studentId,
  }) async {
    currentTask.value = task;
    lessonLoading.value = true;
    error.value = null;
    lesson.value = null;
    try {
      lesson.value = await _repo.getLesson(
        bookId: task.bookId,
        lessonNo: lessonNo,
        studentId: studentId ?? targetStudentId(),
      );
    } on DataApiException catch (e) {
      error.value = e.userMessage;
    } catch (e) {
      error.value = '读取课文失败：$e';
    } finally {
      lessonLoading.value = false;
    }
  }

  /// 打卡：读完了当前这一篇。
  ///
  /// 用的是**当前任务快照里的 `nextLessonNo`**，不是页面手里的课号 ——
  /// 页面可能因为一次失败的刷新而过期（例如在另一台设备上已经读过）。
  /// 服务端会再校验一次顺序，两边不一致时以服务端为准。
  ///
  /// 返回 `ReadingReadResult`（`null` = 失败，原因在 [error]）。
  Future<ReadingReadResult?> markRead(ReadingTask task, {String? studentId}) async {
    final lessonNo = task.nextLessonNo;
    if (lessonNo == null || busy.value) return null;
    busy.value = true;
    error.value = null;
    try {
      final result = await _repo.readLesson(
        taskId: task.id,
        lessonNo: lessonNo,
        day: today,
        studentId: studentId ?? targetStudentId(),
      );
      _upsertTask(result.task);
      currentTask.value = result.task;
      // 打完卡立刻把「今天读了什么」刷一遍：计划页的卡是常驻的，
      // 只更新进度的话它仍会显示「今天还没读」，孩子刚打完卡就看到
      // 一句「没读」—— 会以为没记上，然后连点第二次。
      unawaited(loadTodayLogs(studentId: studentId));
      return result;
    } on DataApiException catch (e) {
      // 「请按顺序读」这类 400 会带着服务端认为的下一篇课号。如实显示，
      // 学生才知道该点哪一篇。
      error.value = e.userMessage;
      // 本地快照可能已经过期：重拉一次任务，让按钮指向正确的那一课。
      await load(studentId: studentId ?? targetStudentId());
      final fresh = taskById(task.id);
      if (fresh != null) currentTask.value = fresh;
      return null;
    } catch (e) {
      error.value = '打卡失败：$e';
      return null;
    } finally {
      busy.value = false;
    }
  }

  /// 把一份任务写回列表：同 id 覆盖，没有就插到最前。
  ///
  /// 覆盖式而不是「add 一份新的」：同一份任务在列表里出现两行，Flutter 会报
  /// duplicate key，用户看到的是「读了一篇，多出一张一模一样的卡」。
  void _upsertTask(ReadingTask task) {
    final at = tasks.indexWhere((t) => t.id == task.id);
    if (at >= 0) {
      tasks[at] = task;
    } else {
      tasks.insert(0, task);
    }
    // 进行中的排最前：刚布置的那份立刻要到顶，否则家长布置完看不到变化。
    tasks.sort((a, b) {
      if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
      return 0;
    });
  }

  ReadingBook _withActiveTask(ReadingBook book, int count) => ReadingBook(
        id: book.id,
        title: book.title,
        author: book.author,
        intro: book.intro,
        lessonCount: book.lessonCount,
        source: book.source,
        activeTaskCount: count,
      );
}
