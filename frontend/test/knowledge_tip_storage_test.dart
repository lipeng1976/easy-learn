import 'package:easy_learn_app/models/knowledge_tip.dart';
import 'package:easy_learn_app/services/app_settings.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/services/local_database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/db_test_helper.dart';

/// 本机缓存（知识点提示）与偏好设置（休息提醒阈值）的存储判据。
///
/// 这两张表是 v27 新增的，各自对应一种**不报错**的坏法：
///   · `_onCreate` 建了、迁移没建 ⇒ 老库升级后提示区一直空着，没人知道为什么；
///   · 迁移没判「表是否存在」⇒ 极简老库在 `openDatabase` 里就炸，整库打不开；
///   · 替换提示时只插不删 ⇒ 上一个知识点的「你总在这里错」永远挂在计时页上。
void main() {
  KnowledgeTip makeTip({
    String id = 't1',
    String point = '分式化简',
    String text = '先通分再加减。',
    int order = 0,
    String signature = 'sig-1',
  }) => KnowledgeTip(
    id: id,
    studentId: 'stu_001',
    subject: '数学',
    knowledgePoint: point,
    text: text,
    source: KnowledgeTipSource.model,
    sortOrder: order,
    generatedAt: DateTime(2026, 10, 19, 9),
    signature: signature,
  );

  test('提示按科目读写；替换会删掉同一科目下不在新批次里的旧提示', () async {
    final dir = await setUpTestDatabase();
    addTearDown(() => tearDownTestDatabase(dir));
    final repo = LocalDatabaseService.instance;

    await repo.replaceKnowledgeTips(
      studentId: 'stu_001',
      subject: '数学',
      tips: [makeTip(), makeTip(id: 't2', point: '勾股定理', order: 1)],
    );

    var rows = await repo.queryKnowledgeTips(
      studentId: 'stu_001',
      subject: '数学',
    );
    expect(rows.map((row) => row.knowledgePoint), ['分式化简', '勾股定理']);
    expect(rows.first.source, KnowledgeTipSource.model);
    expect(rows.first.generatedAt, DateTime(2026, 10, 19, 9));

    await repo.replaceKnowledgeTips(
      studentId: 'stu_001',
      subject: '数学',
      tips: [makeTip(id: 't3', point: '一元二次方程')],
    );
    rows = await repo.queryKnowledgeTips(studentId: 'stu_001', subject: '数学');
    expect(rows, hasLength(1));
    expect(rows.single.knowledgePoint, '一元二次方程');

    // 别的科目不受影响（虽然当前只有一个，这条锁的是 where 条件）。
    await repo.replaceKnowledgeTips(
      studentId: 'stu_001',
      subject: '语文',
      tips: [
        KnowledgeTip(
          id: 'c1',
          studentId: 'stu_001',
          subject: '语文',
          knowledgePoint: '古诗默写',
          text: '先理解再背。',
          source: KnowledgeTipSource.rule,
          generatedAt: DateTime(2026, 10, 19, 9),
        ),
      ],
    );
    expect(
      await repo.queryKnowledgeTips(studentId: 'stu_001', subject: '数学'),
      hasLength(1),
    );
    expect(
      await repo.queryKnowledgeTips(studentId: 'stu_001', subject: '语文'),
      hasLength(1),
    );
  });

  test('设置项：没写过返回 null，写过能被新值覆盖', () async {
    final dir = await setUpTestDatabase();
    addTearDown(() => tearDownTestDatabase(dir));
    final repo = LocalDatabaseService.instance;

    expect(await repo.readLocalSetting(AppSettings.restReminderKey), isNull);

    await repo.writeLocalSetting(AppSettings.restReminderKey, '25');
    expect(await repo.readLocalSetting(AppSettings.restReminderKey), '25');

    await repo.writeLocalSetting(AppSettings.restReminderKey, '50');
    expect(
      await repo.readLocalSetting(AppSettings.restReminderKey),
      '50',
      reason: '同一个 key 只能有一行，第二次写必须是覆盖而不是追加',
    );
  });

  test('AppSettings：默认 40；写入后读得到；脏数据回默认', () async {
    final dir = await setUpTestDatabase();
    addTearDown(() => tearDownTestDatabase(dir));

    expect(await AppSettings.restReminderMinutes(), 40);

    await AppSettings.setRestReminderMinutes(25);
    expect(await AppSettings.restReminderMinutes(), 25);

    // 0 是合法值（不提醒），不能被当成「没配过」。
    await AppSettings.setRestReminderMinutes(0);
    expect(await AppSettings.restReminderMinutes(), 0);

    await DatabaseService.instance.writeLocalSetting(
      AppSettings.restReminderKey,
      '不是数字',
    );
    expect(await AppSettings.restReminderMinutes(), 40);
  });

  test('v26 老库升级到 v27：两张新表都补出来（极简老库也能打开）', () async {
    final dir = await createIsolatedTestDir('easy_learn_v26_min_');
    addTearDown(() => tearDownTestDatabase(dir));
    pointPathProviderTo(dir);
    await DatabaseService.resetForTesting();

    final legacy = await databaseFactory.openDatabase(
      testDatabasePath(dir),
      options: OpenDatabaseOptions(
        version: 26,
        onCreate: (db, version) async {
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
              bio TEXT DEFAULT '',
              passwordUpdatedAt TEXT
            )
          ''');
        },
      ),
    );
    await legacy.close();

    final repo = LocalDatabaseService.instance;
    // 能读到东西 = 库打开了（迁移没抛）。表不存在时这两条都会抛 no such table。
    expect(
      await repo.queryKnowledgeTips(studentId: 'stu_001', subject: '数学'),
      isEmpty,
    );
    expect(await repo.readLocalSetting(AppSettings.restReminderKey), isNull);

    // 补出来的表必须真的可写。
    await repo.replaceKnowledgeTips(
      studentId: 'stu_001',
      subject: '数学',
      tips: [makeTip()],
    );
    expect(
      await repo.queryKnowledgeTips(studentId: 'stu_001', subject: '数学'),
      hasLength(1),
    );
  });
}
