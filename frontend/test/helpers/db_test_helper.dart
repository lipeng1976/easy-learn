import 'dart:io';

import 'package:easy_learn_app/controllers/drill_controller.dart';
import 'package:easy_learn_app/controllers/word_drill_controller.dart';
import 'package:easy_learn_app/models/drill_question.dart';
import 'package:easy_learn_app/models/word_checkin.dart';
import 'package:easy_learn_app/repositories/drill_repository.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/services/word_api.dart';
import 'package:get/get.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

/// 把 path_provider 指到一个临时目录。
///
/// `DatabaseService` 通过 `getApplicationDocumentsDirectory()` 决定库文件位置，
/// 而平台通道在 `flutter test` 里没有实现，会抛 MissingPluginException。
/// 与其为了测试去改生产代码，不如在测试侧把这个平台接口换掉。
class _TempDirPathProvider extends PathProviderPlatform {
  _TempDirPathProvider(this.directory);

  final Directory directory;

  @override
  Future<String?> getApplicationDocumentsPath() async => directory.path;

  @override
  Future<String?> getTemporaryPath() async => directory.path;
}

/// 只把引擎与落点准备好，**不创建数据库、不灌种子数据**。
///
/// 迁移用例需要自己造一个旧版本的库文件，不能先被种子数据占住路径，
/// 所以这里把「准备工作」和「建库灌数据」拆开。
void pointPathProviderTo(Directory directory) {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  PathProviderPlatform.instance = _TempDirPathProvider(directory);
}

/// 建一个空的临时目录，并把 path_provider 与数据库引擎指向它。
Future<Directory> createIsolatedTestDir([String prefix = 'easy_learn_test_']) =>
    Directory.systemTemp.createTemp(prefix);

/// 数据库文件在测试里的落点，与 `DatabaseService` 保持一致。
String testDatabasePath(Directory directory) =>
    '${directory.path}${Platform.pathSeparator}easy_learn_v2.db';

/// 让当前测试文件跑在真实 SQLite 上。
///
/// 默认的 `sqflite` 只覆盖移动端；测试进程在桌面 Dart VM 上，
/// 必须切到 FFI 实现，否则 `openDatabase` 直接抛「databaseFactory not initialized」。
/// 返回临时目录，调用方可在 tearDown 里删掉。
Future<Directory> setUpTestDatabase() async {
  final directory = await createIsolatedTestDir();
  pointPathProviderTo(directory);
  await DatabaseService.resetForTesting();

  // 走应用自己的演示数据入口，保证测试看到的数据和真实首启一致
  // （账号、结伴关系、作业、错题……）。
  //
  // ⚠️ `demoData: true` 是**必须显式写的**：生产默认不灌演示数据
  // （开关 `DemoSeed.enabled`，默认关 —— 真实用户不该看到「别人的孩子」）。
  // 测试要的是「和演示首启一致」的那份数据，所以在这里明确表态，
  // 而不是去改那个常量的默认值。
  await DatabaseService.instance.seedIfEmpty(demoData: true);
  return directory;
}

/// 关闭连接并清理临时目录。
Future<void> tearDownTestDatabase(Directory directory) async {
  await DatabaseService.resetForTesting();
  try {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  } catch (_) {
    // 临时目录清理失败不影响测试结论
  }
}

/// 测试用桩：`DrillController` 的依赖都不碰数据库。
///
/// 复习页顶部的「今日概念训练」入口卡依赖 `DrillController`，而它只在
/// `StudentHomePage` 里 `Get.put`。**直接 pump `ReviewTab` 的测试**缺这一环，
/// 会在 State 字段初始化时抛 "DrillController not found"。这里给一个无副作用的
/// 实现，让这类测试能独立构建复习页，而不必拉起整个首页或真实库。
class StubDrillRepository implements DrillRepository {
  @override
  Future<List<DrillAnswer>> queryDrillAnswers({
    required String studentId,
    int limit = 300,
  }) =>
      Future.value(const []);

  @override
  Future<void> insertDrillAnswers(List<DrillAnswer> answers) => Future.value();
}

/// 注册一个无数据库的 `DrillController`，供独立 pump 复习页的用例使用。
///
/// `fixedNow` 固定「今天」，避免 `DrillSelector` 的种子随真实日期漂移
/// （跨午夜的用例会随机红）。
DrillController registerStubDrillController({DateTime? fixedNow}) {
  if (Get.isRegistered<DrillController>()) Get.delete<DrillController>();
  return Get.put(
    DrillController(
      repository: StubDrillRepository(),
      mistakeWeightsLoader: () => Future.value(const <String, int>{}),
      now: () => fixedNow ?? DateTime(2026, 10, 26),
    ),
  );
}

/// 复习页里新挂的单词入口卡会自己 `loadToday()`。不塞这个桩，它会连真
/// sqflite / 真 HTTP：在假时钟里留下 sqflite 的 10s 事务超时 timer，
/// 「A Timer is still pending」把整组复习分段判据染红 —— 症状跟被测内容
/// 毫无关系。与 `registerStubDrillController` 同一套路：只隔离，不假装测过。
WordDrillController registerStubWordDrillController() {
  if (Get.isRegistered<WordDrillController>()) {
    Get.delete<WordDrillController>();
  }
  return Get.put(
    WordDrillController(
      repository: const UnavailableWordRepository(),
      local: const _EmptyWordLocalStore(),
      studentId: 'stu_001',
      now: () => DateTime(2026, 10, 26),
    ),
  );
}

class _EmptyWordLocalStore implements WordLocalStore {
  const _EmptyWordLocalStore();

  @override
  Future<void> replaceWordEntries({
    required String studentId,
    required String bookId,
    required List<WordEntry> entries,
  }) async {}

  @override
  Future<List<WordEntry>> queryWordEntries({
    required String studentId,
    required String bookId,
  }) async =>
      const <WordEntry>[];

  @override
  Future<List<WordQuestion>> queryWordAnswers({required String studentId}) async =>
      const <WordQuestion>[];

  @override
  Future<void> insertWordAnswers(List<WordQuestion> answers) async {}

  @override
  Future<String?> readSetting(String key) async => null;

  @override
  Future<void> writeSetting(String key, String value) async {}
}
