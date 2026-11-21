import 'dart:io';

import 'package:easy_learn_app/models/workout_model.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/db_test_helper.dart';

/// 运动记录 / 计划「重试不落两条」的回归判据。
///
/// ## 为什么这条不能靠「界面看着对」来验
///
/// 两张表的 `id` 是**客户端生成的主键**，而它同时是幂等键 —— 这是 R2
/// （「id 由服务端生成」）**唯一一处刻意的例外**，理由是运动记录属于打卡类数据：
/// 重试如果插出两条，「今天跑了几次」就被网络抖动改掉了。
///
/// 但这条不变量在界面上**看不见**：两个调用方都把它包在 `_safePersist` 里
/// （`student_controller.dart` / `parent_controller.dart`），异常被吞掉之后
/// 「只有一行」和「插了两条」在列表里长得一模一样 —— 列表读的是内存里那份
/// RxList，本来就已经去重了。所以判据只能打在**库**上。
///
/// ## 与服务端必须同形
///
/// 服务端那一侧写的是 `on conflict (id) do nothing` 再回查原行
/// （`serverless/data-service/src/routes/workout.js`）。本地默认的
/// `INSERT`（不带冲突子句）会直接抛 `UNIQUE constraint failed` ——
/// 结果**碰巧**也对（异常被吞、库里只有一行），但机制不同：换一个不吞异常的
/// 调用方，两边立刻分叉。这条用例钉的就是「同形」。
void main() {
  late Directory dir;

  setUp(() async {
    dir = await setUpTestDatabase();
  });

  tearDown(() async {
    await tearDownTestDatabase(dir);
  });

  WorkoutRecord record(String id, {int minutes = 30, String feedback = ''}) =>
      WorkoutRecord(
        id: id,
        project: '跑步',
        start: DateTime.utc(2026, 9, 21, 1),
        end: DateTime.utc(2026, 9, 21, 1, 30),
        minutes: minutes,
        feedback: feedback,
        studentId: 'stu_001',
      );

  WorkoutPlan plan(String id, {int targetMinutes = 30}) => WorkoutPlan(
        id: id,
        title: '对账·每周跑步',
        project: '跑步',
        weekdays: const ['一', '三', '五'],
        targetMinutes: targetMinutes,
        isActive: false,
        studentId: 'stu_001',
      );

  test('同一条运动记录提交两次：库里只有一行，而且是**原来**那一行', () async {
    final db = DatabaseService.instance;
    await db.insertWorkoutRecord(record('wr_dup'));
    await db.insertWorkoutRecord(record('wr_dup', minutes: 99));

    final hit =
        (await db.queryWorkoutRecords()).where((r) => r.id == 'wr_dup').toList();

    expect(
      hit.length,
      1,
      reason: '重试插出了两条 —— 「今天跑了几次」会被网络抖动改坏，'
          '而这条正是 id 当幂等键的全部意义',
    );
    // 服务端 `do nothing` 保留的是**原行**，不是重试那一次的值。
    // 两边若一个覆盖一个保留，差异只在「重试的请求体不同」时才显形。
    expect(hit.single.minutes, 30, reason: '重试把原行改写了，服务端保留的是原行');
  });

  test('同一个运动计划新建两次：库里只有一行，且原值不变', () async {
    final db = DatabaseService.instance;
    await db.insertWorkoutPlan(plan('wp_dup'));
    await db.insertWorkoutPlan(plan('wp_dup', targetMinutes: 99));

    final hit =
        (await db.queryWorkoutPlans()).where((p) => p.id == 'wp_dup').toList();

    expect(hit.length, 1, reason: '重复新建落了两条计划 —— 孩子会看到两张一样的卡');
    expect(hit.single.targetMinutes, 30);
  });

  // ⚠️ 上面两条都只断言「只有一行」。一个「什么都不插」的实现同样能通过 ——
  // 所以必须有这一条把「幂等」与「失效」分开。
  test('不同 id 的记录互不影响：两条都在', () async {
    final db = DatabaseService.instance;
    await db.insertWorkoutRecord(record('wr_a', minutes: 20));
    await db.insertWorkoutRecord(record('wr_b', minutes: 40));

    final ids = (await db.queryWorkoutRecords()).map((r) => r.id).toSet();

    expect(ids.contains('wr_a'), isTrue, reason: '幂等不该把「正常的第二条」也吃掉');
    expect(ids.contains('wr_b'), isTrue);
  });
}
