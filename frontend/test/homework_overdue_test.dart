import 'dart:io';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/services/local_database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';

/// 「作业上不再有超时概念」这条口径的判据（2026-09-28 建立，同日随实现改写）。
///
/// ## 背景：为什么会走到「删掉它」
///
/// 虫子看到「作业录入的时候，下面就有个超时的提示」，判断「没什么意义」。
/// 查下来机制是三个事实叠出来的：
///
///   1. 录入对话框里**没有任何「计划完成时间」输入框**（只有科目 / 内容 /
///      预计耗时 / 需不需要批改）。`dueAt` 的唯一来源是
///      `_HomeworkTabState._selectedDate`（`homework_tab.dart`），它初始化成
///      `DateTime.now()` —— 也就是**打开作业页那一刻**；
///   2. `isOverdue` = `!hasSubmission && now.isAfter(dueAt)` ⇒ 保存那一刻早已
///      越过 `dueAt`，**刚录完就为真**，卡片上「截止 …」那行当场标红；
///   3. 下一次 `loadData()` 里的 `_sweepOverdue` 把 `status` 写成 `timeout`
///      ⇒ chip 变「已超时」，家长端统计跟着涨。
///
/// 实测物证：当时跑出来的 `dueAt` 是 `2026-09-28T22:56:24.304591` ——
/// **带着微秒**。人手选的时刻只会落在整分。
///
/// 危害不是「不好看」：家长端会报「已超时 N 项」，**把「还没做」说成一个负面
/// 事实**，而家长没有任何办法干预；那个数字还取决于学生上次什么时候打开过 App
/// （服务端不参与计算）。
///
/// 于是口径改成：**系统里不再有超时这个概念**，家长端看
/// 「已提交（含提交时间）/ 尚未提交」—— 那两句话本来就有。
///
/// ## 本文件盯什么
///
/// 1. 录入一条 `dueAt` 落在过去的作业（等价于真实链路），刷新多少次都不会变成
///    超时 —— 并且**直接查库**确认落盘的值也没被改写；
/// 2. 老设备库里存着的 `'timeout'` 字符串读出来是「待完成」（不迁移、不改库版本，
///    靠 `HomeworkStatus.parse` 归一）。
///
/// ⚠️ 第 2 条盯的是**结果**（老数据读出来是待完成），不是「必须走哪个代码分支」
/// —— `parse` 末尾的兜底 `return pending` 对未知值同样成立。这里没有承诺过它
/// 必须走显式分支，所以「分不出是哪一条路径」不算这条判据的缺陷。
///
/// ⚠️ **没有自动化判据的部分**：家长端把那两句话渲染成 UI 的代码
/// （`overview_tab.dart` 列表副标题、`homework_detail_page.dart` 的
/// 「提交时间：…」）没有 widget 测试盯着。谁去改那两行文案，别指望这里会红。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  Directory? tempDir;

  setUp(() async {
    tempDir = await setUpTestDatabase();
    final auth = Get.put(AuthController());
    auth.currentUser.value = UserModel(
      id: 'stu_001',
      name: '林小宇',
      phone: '13800000001',
      role: 'student',
      avatar: '👦',
    );
  });

  tearDown(() async {
    Get.reset();
    final dir = tempDir;
    if (dir != null) await tearDownTestDatabase(dir);
  });

  /// 造一条 `dueAt` 落在 3 分钟前的作业 ——
  /// 等价于真实链路里「学生打开作业页、过几分钟才点保存」。
  Future<StudentController> seedStudentWithPastDue() async {
    final controller = StudentController(
      aiCheckDelay: Duration.zero,
      imageStorage: LocalImageStorageService(useMemory: true),
    );
    await controller.loadData();
    await controller.addHomeworks([
      {
        'title': '口算20题',
        'subject': '数学',
        'dueAt': DateTime.now().subtract(const Duration(minutes: 3)),
        'estimatedMinutes': 10,
        'needsGrading': true,
      },
    ]);
    return controller;
  }

  group('作业上不再有「超时」', () {
    test('录入的作业不会自己变成超时：刷新多少次都不变，库里也没被改写', () async {
      final controller = await seedStudentWithPastDue();
      final id = controller.homeworkList.first.id;

      expect(controller.homeworkById(id)!.status, HomeworkStatus.pending);
      expect(
        controller.homeworkById(id)!.canSubmit,
        isTrue,
        reason: 'dueAt 在过去不该影响「能不能交」—— 它已经不参与任何判断',
      );

      // 刷新两次：原来 `_sweepOverdue` 就挂在这条路径上。
      await controller.loadData();
      await controller.loadData();
      expect(controller.homeworkById(id)!.status, HomeworkStatus.pending);

      // 直接查库，绕过内存态：只看 controller 的话，
      // 「没被写坏」和「内存里碰巧是对的」分不开。
      final db = await LocalDatabaseService.instance.database;
      final rows = await db.query('homework', where: 'id = ?', whereArgs: [id]);
      expect(
        rows.single['status'],
        'pending',
        reason: '落盘的值也不能是 timeout —— 那说明扫描逻辑又回来了',
      );

      // 反方向对照：`dueAt` 在未来的也不该被特殊对待。
      // 原来这里有两个分支（过去 ⇒ 超时、未来 ⇒ 不超时），现在一个都不该有 ——
      // 只测过去的那一侧，会漏掉「有人把不超时那侧改成超时」。
      await controller.addHomeworks([
        {
          'title': '预习课文',
          'subject': '语文',
          'dueAt': DateTime.now().add(const Duration(hours: 12)),
          'estimatedMinutes': 15,
          'needsGrading': false,
        },
      ]);
      expect(controller.homeworkList.first.status, HomeworkStatus.pending);

      // 结构性断言：枚举里根本没有「已超时」这一档。
      // 它拦的是「有人把状态加回来」这种改法 —— 行为断言拦不住。
      expect(
        HomeworkStatus.values.map((value) => value.label),
        isNot(contains('已超时')),
      );
    });

    test('历史数据：库里存着废弃的 timeout，读出来是「待完成」', () async {
      final controller = await seedStudentWithPastDue();
      final id = controller.homeworkList.first.id;

      // 模拟老设备：库里那一行的 status 还是废弃值。
      final db = await LocalDatabaseService.instance.database;
      final changed = await db.update(
        'homework',
        {'status': 'timeout'},
        where: 'id = ?',
        whereArgs: [id],
      );
      // 没有这条，「没改到行」会让下面几条断言在空转中全绿。
      expect(changed, 1, reason: '没改到那一行，下面的断言就是空转');

      await controller.loadData();
      final reread = controller.homeworkById(id)!;
      expect(reread.status, HomeworkStatus.pending);
      expect(reread.status.label, '待完成');
      expect(
        reread.canSubmit,
        isTrue,
        reason: '老数据也不该因为一个废弃状态而变得不能提交',
      );
    });
  });
}
