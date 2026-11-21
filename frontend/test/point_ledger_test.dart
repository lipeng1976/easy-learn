import 'dart:io';

import 'package:easy_learn_app/controllers/point_controller.dart';
import 'package:easy_learn_app/models/point_model.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/db_test_helper.dart';

/// 积分账本的内核测试。
///
/// 这一层**不碰任何界面**：积分是「孩子做了什么 → 记一笔 → 余额变了」，
/// 界面上看到的数字对不对，取决于这里的账对不对。先把账测准。
void main() {
  late Directory dir;
  late PointController points;
  var tick = 0;

  setUp(() async {
    dir = await setUpTestDatabase();
    points = PointController()
      // 注入时钟：断言「撤销后重新打卡」这类跨时刻的行为时，
      // 用真实时间会让用例在不同时刻跑出不同结果。
      ..clock = () => DateTime(2026, 9, 17, 20, 0, 0).add(
        Duration(seconds: tick++),
      );
    tick = 0;
    await points.loadFor('stu_001');
  });

  tearDown(() async {
    await tearDownTestDatabase(dir);
  });

  group('分值表', () {
    test('家长没配过时用出厂默认值', () {
      expect(points.pointsFor(PointAction.homeworkGraded), 5);
      expect(points.pointsFor(PointAction.homeworkNoGrading), 3);
      expect(points.pointsFor(PointAction.reviewRound), 10);
      expect(points.pointsFor(PointAction.mistakeGraduated), 10);
      expect(points.isEnabled(PointAction.homeworkGraded), isTrue);
    });

    test('家长改过之后按新的算', () async {
      await points.setRule(
        studentId: 'stu_001',
        action: PointAction.reviewRound,
        points: 20,
      );
      expect(points.pointsFor(PointAction.reviewRound), 20);

      // 重新拉一遍，确认真的落库了，而不是只改了内存
      final reloaded = PointController()
        ..clock = () => DateTime(2026, 9, 17, 20, 0, 0);
      await reloaded.loadFor('stu_001');
      expect(reloaded.pointsFor(PointAction.reviewRound), 20);
    });

    test('分值按孩子独立：改了一个不影响另一个', () async {
      await points.setRule(
        studentId: 'stu_001',
        action: PointAction.workoutCheckin,
        points: 8,
      );
      final other = PointController()
        ..clock = () => DateTime(2026, 9, 17, 20, 0, 0);
      await other.loadFor('stu_002');
      expect(other.pointsFor(PointAction.workoutCheckin), 5);
    });
  });

  group('记分与防重', () {
    test('记一笔分，余额与累计同时变化', () async {
      final outcome = await points.award(
        action: PointAction.workoutCheckin,
        studentId: 'stu_001',
        reason: '运动打卡：跳绳',
        idempotencyKey: PointController.workoutKey('跳绳', '2026-09-17'),
      );

      expect(outcome, PointGrantOutcome.granted);
      expect(points.account.value.balance, 5);
      expect(points.account.value.totalEarned, 5);
      expect(points.account.value.totalSpent, 0);
    });

    test('同一个防重键发两次，只记一笔', () async {
      final key = PointController.planKey('sp_1', '2026-09-17');
      final first = await points.award(
        action: PointAction.planCheckin,
        studentId: 'stu_001',
        reason: '完成今日计划',
        idempotencyKey: key,
      );
      final second = await points.award(
        action: PointAction.planCheckin,
        studentId: 'stu_001',
        reason: '完成今日计划',
        idempotencyKey: key,
      );

      expect(first, PointGrantOutcome.granted);
      // 「重复」是一个正常结论，不是错误 —— 调用方据此知道防重生效了。
      expect(second, PointGrantOutcome.duplicated);
      expect(points.account.value.balance, 5);
      expect(points.ledger.length, 1);
    });

    test('防重也拦在数据库层：绕过控制器直接写两次同样只进一笔', () async {
      final entry = PointLedgerEntry(
        id: 'pl_manual_1',
        studentId: 'stu_001',
        action: PointAction.planCheckin.code,
        points: 5,
        reason: '手写一笔',
        idempotencyKey: 'plan:sp_manual:2026-09-17',
        createdAt: DateTime(2026, 9, 17, 20),
      );
      final first = await DatabaseService.instance.insertPointLedger(entry);
      final second = await DatabaseService.instance.insertPointLedger(
        // id 不同、防重键相同 —— 模拟「连点两次」生成的另一笔
        PointLedgerEntry(
          id: 'pl_manual_2',
          studentId: 'stu_001',
          action: PointAction.planCheckin.code,
          points: 5,
          reason: '手写一笔',
          idempotencyKey: 'plan:sp_manual:2026-09-17',
          createdAt: DateTime(2026, 9, 17, 20, 0, 1),
        ),
      );

      expect(first, isTrue);
      expect(second, isFalse);
      final ledger = await DatabaseService.instance.queryPointLedger(
        'stu_001',
      );
      expect(ledger.length, 1);
    });

    test('家长关掉某项后就不再记分', () async {
      await points.setRule(
        studentId: 'stu_001',
        action: PointAction.workoutCheckin,
        enabled: false,
      );
      final outcome = await points.award(
        action: PointAction.workoutCheckin,
        studentId: 'stu_001',
        reason: '运动打卡',
        idempotencyKey: PointController.workoutKey('跳绳', '2026-09-17'),
      );

      expect(outcome, PointGrantOutcome.disabled);
      expect(points.account.value.balance, 0);
    });

    test('分值为 0 时不记空账', () async {
      await points.setRule(
        studentId: 'stu_001',
        action: PointAction.planCheckin,
        points: 0,
      );
      final outcome = await points.award(
        action: PointAction.planCheckin,
        studentId: 'stu_001',
        reason: '完成今日计划',
        idempotencyKey: PointController.planKey('sp_1', '2026-09-17'),
      );

      expect(outcome, PointGrantOutcome.zeroPoints);
      expect(points.ledger, isEmpty);
    });

    test('没有学生身份时不记分', () async {
      final outcome = await points.award(
        action: PointAction.planCheckin,
        studentId: '',
        reason: '完成今日计划',
        idempotencyKey: 'plan:x:2026-09-17',
      );
      expect(outcome, PointGrantOutcome.noStudent);
    });
  });

  group('撤销走冲正', () {
    test('打卡 → 撤销 → 再打卡，净得分只有一次', () async {
      // 这是整条设计里最关键的一条路径：`toggleTodayCheckin` 是个开关，
      // 学生点两下就撤销了。如果撤销靠删记录，反复开关就能无限刷分。
      final key = PointController.planKey('sp_1', '2026-09-17');
      await points.award(
        action: PointAction.planCheckin,
        studentId: 'stu_001',
        reason: '完成今日计划',
        idempotencyKey: key,
      );
      expect(points.account.value.balance, 5);

      final revoked = await points.revoke(
        studentId: 'stu_001',
        idempotencyKey: key,
      );
      expect(revoked, isTrue);
      expect(points.account.value.balance, 0);
      // 累计获得不能凭空留着那 5 分 —— 否则家长看到「撤销了但赚过」
      expect(points.account.value.totalEarned, 0);

      final again = await points.award(
        action: PointAction.planCheckin,
        studentId: 'stu_001',
        reason: '完成今日计划',
        idempotencyKey: key,
      );
      expect(again, PointGrantOutcome.granted);
      expect(points.account.value.balance, 5);

      // 反复开关也不会累积
      await points.revoke(studentId: 'stu_001', idempotencyKey: key);
      await points.award(
        action: PointAction.planCheckin,
        studentId: 'stu_001',
        reason: '完成今日计划',
        idempotencyKey: key,
      );
      expect(points.account.value.balance, 5);
      expect(points.account.value.totalEarned, 5);
    });

    test('撤销不删记录，账本里留着原笔与冲正笔', () async {
      final key = PointController.planKey('sp_1', '2026-09-17');
      await points.award(
        action: PointAction.planCheckin,
        studentId: 'stu_001',
        reason: '完成今日计划',
        idempotencyKey: key,
      );
      await points.revoke(studentId: 'stu_001', idempotencyKey: key);

      // 两笔都在：一笔被标掉、一笔是相反数。删掉的话孩子会觉得
      // 「我明明做过」的东西凭空消失，家长也无从查证。
      expect(points.ledger.length, 2);
      final original = points.ledger.firstWhere((e) => !e.isReversal);
      final reversal = points.ledger.firstWhere((e) => e.isReversal);
      expect(original.isReversed, isTrue);
      expect(reversal.points, -original.points);
      expect(reversal.reversalOf, original.id);
    });

    test('没发过分的动作撤销是空操作', () async {
      final revoked = await points.revoke(
        studentId: 'stu_001',
        idempotencyKey: 'plan:never:2026-09-17',
      );
      expect(revoked, isFalse);
      expect(points.ledger, isEmpty);
    });
  });

  group('花钱与奖励', () {
    test('愿望兑换扣分', () async {
      await points.award(
        action: PointAction.reviewRound,
        studentId: 'stu_001',
        reason: '完成一轮复习',
        idempotencyKey: PointController.reviewPaperKey('rp_1'),
      );
      expect(points.account.value.balance, 10);

      final outcome = await points.spend(
        action: PointAction.wishRedeem,
        studentId: 'stu_001',
        points: 8,
        reason: '兑现心愿：去游乐园',
        idempotencyKey: PointController.wishRedeemKey('w_1'),
        refType: 'wish',
        refId: 'w_1',
      );

      expect(outcome, PointGrantOutcome.granted);
      expect(points.account.value.balance, 2);
      expect(points.account.value.totalSpent, 8);
      // 累计获得仍是 10 —— 花掉的分不该把赚到的记录抹掉
      expect(points.account.value.totalEarned, 10);
    });

    test('同一个愿望只扣一次', () async {
      await points.grantReward(
        studentId: 'stu_001',
        points: 50,
        reason: '奖励',
        createdBy: 'par_001',
      );
      final key = PointController.wishRedeemKey('w_1');
      await points.spend(
        action: PointAction.wishRedeem,
        studentId: 'stu_001',
        points: 30,
        reason: '兑现心愿',
        idempotencyKey: key,
      );
      await points.spend(
        action: PointAction.wishRedeem,
        studentId: 'stu_001',
        points: 30,
        reason: '兑现心愿',
        idempotencyKey: key,
      );

      expect(points.account.value.balance, 20);
    });

    test('家长奖励不做防重：点两次就是两笔', () async {
      await points.grantReward(
        studentId: 'stu_001',
        points: 5,
        reason: '帮忙做家务',
        createdBy: 'par_001',
      );
      await points.grantReward(
        studentId: 'stu_001',
        points: 5,
        reason: '帮忙做家务',
        createdBy: 'par_001',
      );
      expect(points.account.value.balance, 10);
    });
  });

  group('余额派生', () {
    test('账户数字全部来自流水，不另存字段', () {
      final now = DateTime(2026, 9, 17);
      final ledger = [
        PointLedgerEntry(
          id: 'a',
          studentId: 's',
          action: PointAction.workoutCheckin.code,
          points: 5,
          reason: '',
          createdAt: now,
        ),
        // 被撤销的那笔：连同冲正笔一起跳过
        PointLedgerEntry(
          id: 'b',
          studentId: 's',
          action: PointAction.planCheckin.code,
          points: 5,
          reason: '',
          createdAt: now,
          reversedAt: now,
        ),
        PointLedgerEntry(
          id: 'c',
          studentId: 's',
          action: PointAction.planCheckin.code,
          points: -5,
          reason: '',
          reversalOf: 'b',
          createdAt: now,
        ),
        PointLedgerEntry(
          id: 'd',
          studentId: 's',
          action: PointAction.wishRedeem.code,
          points: -3,
          reason: '',
          createdAt: now,
        ),
      ];

      final account = PointAccount.fromLedger(ledger);
      expect(account.balance, 2);
      expect(account.totalEarned, 5);
      expect(account.totalSpent, 3);
      expect(account.entryCount, 2);
    });
  });

  group('动作标识', () {
    test('认不出来的 code 不抛异常', () {
      expect(pointActionFromCode('homeworkGraded'), PointAction.homeworkGraded);
      expect(pointActionFromCode('some_removed_action'), isNull);
      // 老记录里的陌生动作要能原样显示，而不是把整个明细页搞崩
      expect(pointActionLabel('some_removed_action'), 'some_removed_action');
    });

    test('奖励与兑换不进设置表', () {
      final codes = kConfigurablePointActions
          .map((action) => action.code)
          .toList();
      expect(codes, contains('homeworkGraded'));
      expect(codes, contains('mistakeGraduated'));
      // 2026-11-16 起多了「每日练习完成 / 全对」两项：7 → 9。
      // 这里的数字刻意写死：新增动作时必须来改这一行，等于强制想一遍
      // 「它该不该出现在家长的分值设置里」。
      expect(codes, contains('checkinCompleted'));
      expect(codes, contains('checkinAllCorrect'));
      expect(codes, hasLength(9));
      expect(codes, isNot(contains('parentReward')));
      expect(codes, isNot(contains('wishRedeem')));
    });
  });

  group('数据库迁移 v21 → v22', () {
    test('老库补出两张积分表与心愿的兑换列，且积分从 0 开始', () async {
      final dir = await createIsolatedTestDir('easy_learn_v21_');
      pointPathProviderTo(dir);
      await DatabaseService.resetForTesting();

      // 造一个 v21 的库。wish 表必须建 —— v22 的迁移要给它加列，
      // 夹具省掉它，测的就不是迁移而是夹具（前两个迁移用例都踩过这个）。
      final legacy = await databaseFactory.openDatabase(
        testDatabasePath(dir),
        options: OpenDatabaseOptions(
          version: 21,
          onCreate: (db, version) async {
            await db.execute('''
              CREATE TABLE wish (
                id TEXT PRIMARY KEY,
                title TEXT,
                description TEXT,
                isPublic INTEGER,
                parentConfirmed INTEGER,
                studentConfirmed INTEGER,
                isArchived INTEGER,
                userRole TEXT,
                studentId TEXT NOT NULL DEFAULT '',
                expectedDate TEXT
              )
            ''');
            // app_user 也必须建：v23 的迁移要给它补 passwordUpdatedAt。
            // 用 v3 时代的形状，好让那一步真的有列可加。
            await db.execute('''
              CREATE TABLE app_user (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                phone TEXT UNIQUE,
                role TEXT NOT NULL,
                avatar TEXT NOT NULL,
                password TEXT,
                wechatOpenId TEXT UNIQUE,
                gender TEXT DEFAULT '',
                grade TEXT DEFAULT '',
                hobbies TEXT DEFAULT '',
                bio TEXT DEFAULT ''
              )
            ''');
            await db.insert('wish', {
              'id': 'w_legacy',
              'title': '老心愿',
              'description': '升级前就存在的',
              'isPublic': 1,
              'parentConfirmed': 1,
              'studentConfirmed': 1,
              'isArchived': 0,
              'userRole': 'student',
              'studentId': 'stu_001',
            });
          },
        ),
      );
      await legacy.close();

      // 用应用自己的连接打开，触发 onUpgrade
      final wishes = await DatabaseService.instance.queryWishes('student');
      final migrated = wishes.firstWhere((wish) => wish.id == 'w_legacy');

      // 老心愿不能被当成「要花积分」而卡住兑换流程
      expect(migrated.pointCost, 0);
      expect(migrated.needsPoints, isFalse);
      expect(migrated.redeemRequestedAt, isNull);
      expect(migrated.redeemedAt, isNull);
      expect(migrated.redeemRejectedAt, isNull);

      // 升级上来的库，历史上一分都没有 —— 不回填，余额如实为 0。
      final points = PointController()
        ..clock = () => DateTime(2026, 9, 17, 20);
      await points.loadFor('stu_001');
      expect(points.account.value.balance, 0);
      expect(points.pointsFor(PointAction.homeworkGraded), 5);

      // 迁移建出来的表要真的能用：写一笔、读回来、防重照样生效
      final outcome = await points.award(
        action: PointAction.homeworkGraded,
        studentId: 'stu_001',
        reason: '提交数学作业A',
        idempotencyKey: PointController.homeworkKey('hw_001', 'batch_1'),
      );
      expect(outcome, PointGrantOutcome.granted);
      expect(points.account.value.balance, 5);

      await tearDownTestDatabase(dir);
    });
  });
}
