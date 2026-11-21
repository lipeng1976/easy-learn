import 'package:easy_learn_app/repositories/homework_repository.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/services/local_database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/db_test_helper.dart';

/// 作业「实际用时」在本地的存储层判据。
///
/// 三件事分别对应三种**不报错**的坏法：
///   · 写进去读不回来 ⇒ 计时结束回到列表，用时还是空的（学生以为白计了）；
///   · 只改 `_onCreate` 不改迁移 ⇒ 老库升级后没有这一列，点一下「结束并保存」才炸，
///     而报错是 `no such column: actualSeconds`，看着像存储层坏了；
///   · 迁移不判表在不在 ⇒ 极简老库里 `ALTER TABLE homework` 直接抛
///     `no such table`，而它发生在 `openDatabase` 期间 —— **整个库打不开**。
void main() {
  test('写入实际用时后能按同一份数据读回来', () async {
    final dir = await setUpTestDatabase();
    addTearDown(() => tearDownTestDatabase(dir));

    final repo = LocalDatabaseService.instance;
    final items = await repo.queryHomework('student');
    expect(items, isNotEmpty);
    final target = items.first;
    expect(target.actualSeconds, 0, reason: '演示数据不该凭空带着用时');

    await repo.updateHomework(
      HomeworkPatch(id: target.id)..actualSeconds = 754,
    );

    final again = await repo.queryHomework('student');
    final updated = again.firstWhere((item) => item.id == target.id);
    expect(updated.actualSeconds, 754);
    expect(
      updated.estimatedMinutes,
      target.estimatedMinutes,
      reason: '写用时不能顺手把「预计用时」覆盖掉',
    );
  });

  test('v25 老库升级补出 actualSeconds，历史行是 0（不是编出来的数）', () async {
    final dir = await createIsolatedTestDir('easy_learn_v25_');
    addTearDown(() => tearDownTestDatabase(dir));
    pointPathProviderTo(dir);
    await DatabaseService.resetForTesting();

    final legacy = await databaseFactory.openDatabase(
      testDatabasePath(dir),
      options: OpenDatabaseOptions(
        version: 25,
        onCreate: (db, version) async {
          // v25 的 homework：**没有** actualSeconds。夹具里带上它就是测迁移本身了。
          await db.execute('''
            CREATE TABLE homework (
              id TEXT PRIMARY KEY,
              title TEXT,
              subject TEXT,
              imageUrl TEXT,
              dueAt TEXT,
              estimatedMinutes REAL,
              status TEXT,
              wrongCount INTEGER,
              aiEnabled INTEGER,
              needsGrading INTEGER NOT NULL DEFAULT 1,
              userRole TEXT,
              studentId TEXT NOT NULL DEFAULT '',
              submittedAt TEXT,
              checkedAt TEXT,
              score INTEGER,
              summary TEXT NOT NULL DEFAULT '',
              imageCount INTEGER NOT NULL DEFAULT 0,
              submitBatchId TEXT NOT NULL DEFAULT '',
              gradingSource TEXT NOT NULL DEFAULT ''
            )
          ''');
          await db.insert('homework', {
            'id': 'hw_old',
            'title': '老作业',
            'subject': '数学',
            'dueAt': '2026-10-01T20:00:00.000',
            'estimatedMinutes': 30,
            'status': 'finished',
            'wrongCount': 0,
            'aiEnabled': 1,
            'userRole': 'student',
            'studentId': 'stu_001',
          });
        },
      ),
    );
    await legacy.close();

    final repo = LocalDatabaseService.instance;
    final items = await repo.queryHomework('student');
    expect(items, hasLength(1));
    expect(
      items.single.actualSeconds,
      0,
      reason: '这一版之前没有计时记录，回填 estimatedMinutes*60 等于伪造用时',
    );

    // 补出来的列必须真的可写。
    await repo.updateHomework(
      HomeworkPatch(id: 'hw_old')..actualSeconds = 90,
    );
    final again = await repo.queryHomework('student');
    expect(again.single.actualSeconds, 90);
  });

  test('只有 app_user 的极简老库也能打开 —— 迁移必须判表在不在', () async {
    final dir = await createIsolatedTestDir('easy_learn_v25_min_');
    addTearDown(() => tearDownTestDatabase(dir));
    pointPathProviderTo(dir);
    await DatabaseService.resetForTesting();

    final legacy = await databaseFactory.openDatabase(
      testDatabasePath(dir),
      options: OpenDatabaseOptions(
        version: 25,
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
          await db.insert('app_user', {
            'id': 'stu_min',
            'name': '极简老库',
            'phone': '13700000099',
            'role': 'student',
            'avatar': 'student',
            'password': 'abc123',
          });
        },
      ),
    );
    await legacy.close();

    // 只要库能打开，这一条就成立。不给 homework 表建列的守卫漏掉时，
    // 这里抛的是 `no such table: homework`，而且是从 openDatabase 里抛出来的。
    final user = await DatabaseService.instance.findUserByPhone('13700000099');
    expect(user, isNotNull);
    expect(user!['id'], 'stu_min');
  });
}
