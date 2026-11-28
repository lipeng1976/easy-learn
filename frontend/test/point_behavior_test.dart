import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'package:easy_learn_app/controllers/point_controller.dart';
import 'package:easy_learn_app/models/point_model.dart';
import 'package:easy_learn_app/pages/shared/point_ledger_page.dart';
import 'package:easy_learn_app/repositories/point_repository.dart';
import 'package:easy_learn_app/widgets/point_behavior_widgets.dart';

/// 行为扣分的判据。
///
/// 盯的不是「页面上有按钮」，而是三件会静默出错的事：
///   ① 内置配置重复落表 / 家长改过的分值被默认值冲掉；
///   ② 扣分没有按行为记录 refId，导致明细页筛不出来；
///   ③ 内置行为被删掉后，历史扣分只剩一个看不懂的 id。
class _Repo implements PointRepository {
  final entries = <PointLedgerEntry>[];
  final behaviors = <PointBehavior>[];

  @override
  Future<List<PointLedgerEntry>> queryPointLedger(String studentId) async =>
      entries.where((e) => e.studentId == studentId).toList();

  @override
  Future<List<PointRule>> queryPointRules(String studentId) async => const [];

  @override
  Future<void> upsertPointRule(PointRule rule) async {}

  @override
  Future<PointLedgerEntry?> findActivePointEntry({
    required String studentId,
    required String idempotencyKey,
  }) async {
    for (final entry in entries) {
      if (entry.studentId == studentId &&
          entry.idempotencyKey == idempotencyKey &&
          entry.reversedAt == null) {
        return entry;
      }
    }
    return null;
  }

  @override
  Future<bool> insertPointLedger(PointLedgerEntry entry) async {
    if (await findActivePointEntry(
          studentId: entry.studentId,
          idempotencyKey: entry.idempotencyKey,
        ) !=
        null) {
      return false;
    }
    entries.add(entry);
    return true;
  }

  @override
  Future<void> markPointEntryReversed(String id, DateTime reversedAt) async {}

  @override
  Future<List<PointBehavior>> queryPointBehaviors(String studentId) async =>
      behaviors.where((b) => b.studentId == studentId).toList();

  @override
  Future<void> upsertPointBehavior(PointBehavior behavior) async {
    behaviors.removeWhere(
      (b) => b.studentId == behavior.studentId && b.id == behavior.id,
    );
    behaviors.add(behavior);
  }

  @override
  Future<void> deletePointBehavior(String studentId, String id) async {
    behaviors.removeWhere((b) => b.studentId == studentId && b.id == id);
  }
}

void main() {
  test('内置行为首次进入时落表一次，家长改过的分值不会被默认值冲掉', () async {
    final repo = _Repo();
    final controller = PointController(repository: repo);
    controller.clock = () => DateTime(2026, 11, 28, 9);

    await controller.loadFor('stu_1');
    expect(controller.behaviors.length, 3);
    expect(
      controller.behaviors.map((b) => b.id),
      containsAll(['builtin_late', 'builtin_absent', 'builtin_discipline']),
    );
    expect(repo.behaviors.length, 3);

    await controller.setBehavior(
      studentId: 'stu_1',
      id: 'builtin_late',
      name: '迟到',
      points: 6,
      enabled: true,
      builtin: true,
    );
    await controller.loadFor('stu_1', force: true);
    expect(
      controller.behaviors.firstWhere((b) => b.id == 'builtin_late').points,
      6,
      reason: '重新进入页面不能把家长配的分值重置成默认 2',
    );
    expect(repo.behaviors.length, 3,
        reason: '已存在的内置行为不能再插一遍');
  });

  test('扣分写负数流水且带行为 id；两次扣分是两笔，不是被防重掉', () async {
    final repo = _Repo();
    final controller = PointController(repository: repo);
    controller.clock = () => DateTime(2026, 11, 28, 10);
    await controller.loadFor('stu_1');

    final first = await controller.deductBehavior(
      studentId: 'stu_1',
      behaviorId: 'builtin_absent',
      createdBy: 'par_1',
    );
    final second = await controller.deductBehavior(
      studentId: 'stu_1',
      behaviorId: 'builtin_absent',
      createdBy: 'par_1',
      note: '下午第一节',
    );
    expect(first, PointGrantOutcome.granted);
    expect(second, PointGrantOutcome.granted);

    expect(repo.entries.length, 2, reason: '每次扣分都是独立事件');
    expect(repo.entries.every((e) => e.points == -5), isTrue);
    expect(
      repo.entries.every((e) =>
          e.action == 'behaviorDeduction' &&
          e.refType == 'behavior' &&
          e.refId == 'builtin_absent'),
      isTrue,
      reason: '没有 refId 就没法在明细页按行为查到',
    );
    expect(repo.entries.last.reason, '旷课：下午第一节');
    expect(controller.account.value.balance, -10);
  });

  test('关闭的行为不扣分，内置行为不能删，自定义行为可以删', () async {
    final repo = _Repo();
    final controller = PointController(repository: repo);
    await controller.loadFor('stu_1');

    await controller.setBehavior(
      studentId: 'stu_1',
      id: 'builtin_late',
      name: '迟到',
      points: 2,
      enabled: false,
      builtin: true,
    );
    expect(
      await controller.deductBehavior(
        studentId: 'stu_1',
        behaviorId: 'builtin_late',
        createdBy: 'par_1',
      ),
      PointGrantOutcome.disabled,
    );
    expect(repo.entries, isEmpty);

    expect(
      await controller.deleteBehavior(studentId: 'stu_1', id: 'builtin_late'),
      isFalse,
    );
    expect(repo.behaviors.any((b) => b.id == 'builtin_late'), isTrue);

    await controller.setBehavior(
      studentId: 'stu_1',
      id: 'custom_chat',
      name: '上课讲话',
      points: 3,
      enabled: true,
    );
    expect(
      await controller.deleteBehavior(studentId: 'stu_1', id: 'custom_chat'),
      isTrue,
    );
    expect(repo.behaviors.any((b) => b.id == 'custom_chat'), isFalse);
  });

  testWidgets('积分明细可按行为筛选，余额不受筛选影响', (tester) async {
    final repo = _Repo()
      ..behaviors.add(
        PointBehavior(
          studentId: 'stu_1',
          id: 'builtin_late',
          name: '迟到筛选标记',
          points: 2,
          builtin: true,
        ),
      )
      ..entries.addAll([
        PointLedgerEntry(
          id: 'e1',
          studentId: 'stu_1',
          action: 'behaviorDeduction',
          points: -2,
          reason: '迟到扣分标记',
          refType: 'behavior',
          refId: 'builtin_late',
          createdAt: DateTime(2026, 11, 28, 9),
        ),
        PointLedgerEntry(
          id: 'e2',
          studentId: 'stu_1',
          action: 'homeworkGraded',
          points: 5,
          reason: '作业流水标记',
          createdAt: DateTime(2026, 11, 28, 8),
        ),
      ]);

    await tester.pumpWidget(
      GetMaterialApp(
        home: PointLedgerPage(studentId: 'stu_1', repository: repo),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('迟到扣分标记'), findsOneWidget);
    expect(find.text('作业流水标记'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '迟到筛选标记'));
    await tester.pumpAndSettle();

    expect(find.text('迟到扣分标记'), findsOneWidget);
    expect(find.text('作业流水标记'), findsNothing,
        reason: '筛选后不该混进加分流水');
  });

  testWidgets('扣分入口是带文字的按钮，点了真的记一笔；关闭后不可点', (tester) async {
    var deducted = 0;
    final behavior = PointBehavior(
      studentId: 'stu_1',
      id: 'builtin_late',
      name: '迟到',
      points: 2,
      builtin: true,
    );

    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: PointBehaviorTile(
            behavior: behavior,
            onDeduct: () => deducted++,
            onPoints: (_) async {},
            onEnabled: (_) {},
            onDelete: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 触屏设备上 tooltip 不显示 → 入口必须有文字，不能只留一个圆形图标。
    expect(find.widgetWithText(ElevatedButton, '扣分'), findsOneWidget,
        reason: '扣分是动作，必须一眼看得见');
    await tester.tap(find.widgetWithText(ElevatedButton, '扣分'));
    await tester.pumpAndSettle();
    expect(deducted, 1, reason: '点了扣分按钮必须真的触发记账');

    // 关闭的行为不给扣分，避免误操作。
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: PointBehaviorTile(
            behavior: PointBehavior(
              studentId: 'stu_1',
              id: 'builtin_late',
              name: '迟到',
              points: 2,
              builtin: true,
              enabled: false,
            ),
            onDeduct: () => deducted++,
            onPoints: (_) async {},
            onEnabled: (_) {},
            onDelete: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, '扣分'),
    );
    expect(button.onPressed, isNull, reason: '关闭的行为不能再扣分');
  });

  test('源码契约：客户端 DB v33 的行为表只在两处定义', () {
    final source =
        File('lib/services/local_database_service.dart').readAsStringSync();
    expect(source.contains('version: 33,'), isTrue);
    expect(source.contains('if (oldVersion < 33)'), isTrue);
    // 两份 DDL 都得有，缺 onCreate 会「新装炸」，缺 onUpgrade 会「升级少表」。
    expect(
      source.contains('CREATE TABLE point_behavior'),
      isTrue,
      reason: 'onCreate 必须建行为表',
    );
    expect(
      source.contains('CREATE TABLE IF NOT EXISTS point_behavior'),
      isTrue,
      reason: 'onUpgrade 必须建行为表',
    );
  });
}
