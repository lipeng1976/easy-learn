import 'dart:io';

import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/services/local_database_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/db_test_helper.dart';

/// P1-1：演示种子数据与真实数据分开。
///
/// 真实用户第一次打开应用**不该**看到「别人的孩子」。这件事原先必然发生，
/// 而且不止一条路：
/// ① 三个控制器的初始列表加载路径都经过 `LocalSeedService.init()`，
///    它把 `seedIfEmpty()` 藏在**每一次读取**里；
/// ② `app_user` 的 `findUserByPhone` / `findUserByWechat` / `findUserById`
///    还会**按需**补写同一批演示账号 —— 于是「演示数据是否完整」被绑在了
///    「谁先发起一次用户查询」上。
///
/// 所以判据要盯**两条**：首启不写、以及「查一次账号不会凭空多出一个账号」。
/// 只盯第一条的话，②那条路照样会把演示账号写进真实用户的库。
///
/// ⚠️ 本文件刻意**不**用 `setUpTestDatabase()`：那个 helper 会显式传
/// `demoData: true`（它要的是「和演示首启一致」的那份数据），
/// 而这里要验的恰恰是**默认**这一侧。
void main() {
  late Directory dir;

  setUp(() async {
    dir = await createIsolatedTestDir('easy_learn_seed_gate_');
    pointPathProviderTo(dir);
    await DatabaseService.resetForTesting();
  });

  tearDown(() async {
    await tearDownTestDatabase(dir);
  });

  test('默认不灌演示数据：新库首启看不到任何演示账号与演示作业', () async {
    await DatabaseService.instance.seedIfEmpty();

    final db = await LocalDatabaseService.instance.database;
    expect(
      await db.query('app_user'),
      isEmpty,
      reason: '演示账号不该被写进真实用户的库 —— 家长端会把它列成「我的孩子」',
    );
    expect(await db.query('homework'), isEmpty, reason: '演示作业同理');
    expect(await db.query('relationship'), isEmpty, reason: '演示结伴关系同理');
    // 走控制器真正用的那条读路径再确认一次：列表为空**是正确结果**，
    // 不是「读失败」—— 新用户本来就还没有作业。
    expect(await DatabaseService.instance.queryHomework('student'), isEmpty);
  });

  test('默认不按需补账号：用演示手机号查一次，不该凭空多出一个账号', () async {
    final db = await LocalDatabaseService.instance.database;
    expect(await db.query('app_user'), isEmpty);

    final found = await DatabaseService.instance.findUserByPhone('13800000001');
    expect(found, isNull, reason: '真实环境按手机号查不到就该查不到，而不是把它造出来');

    // 关键：**查询动作零副作用**。少了这条断言，①写路径被关掉也看不出来。
    expect(
      await db.query('app_user'),
      isEmpty,
      reason: '「查一次账号」不该真的往库里写一个账号',
    );
  });

  test('反面：演示环境（demoData: true）仍然拿到完整演示数据', () async {
    await DatabaseService.instance.seedIfEmpty(demoData: true);

    final db = await LocalDatabaseService.instance.database;
    expect(
      await db.query('app_user'),
      isNotEmpty,
      reason: '少这一条，一个「什么都不插」的实现也能让上面两条过',
    );
    expect(await db.query('homework'), isNotEmpty);
    expect(
      await db.query('relationship'),
      isNotEmpty,
      reason: '账号与结伴关系必须一起准备好，否则家长端查不到任何孩子',
    );

    final demoStudent = await db.query(
      'app_user',
      where: 'id = ?',
      whereArgs: ['stu_001'],
    );
    expect(demoStudent, hasLength(1));
    expect(await DatabaseService.instance.queryHomework('student'), isNotEmpty);
  });

  test('演示环境下按手机号仍能查到演示账号（懒插入这条路没被关死）', () async {
    // 演示环境里只要灌过一次种子，账号就在库里；这里额外确认
    // 「查找」这条路在演示环境下语义正确（真实环境下它必须返回 null）。
    await DatabaseService.instance.seedIfEmpty(demoData: true);
    final found = await DatabaseService.instance.findUserByPhone('13800000001');
    expect(found, isNotNull);
    expect(found!['id'], 'stu_001');
  });
}
