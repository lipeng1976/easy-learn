import 'package:easy_learn_app/models/focus_session_model.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/services/local_database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/db_test_helper.dart';

/// 专注流水在**本地**的存储层判据。
///
/// 三件事对应三种「不报错、只是数字不对」的坏法：
///   · 重复保存新增一行 ⇒ 暂停三次时长翻三倍，界面只显示「今天读了 30 分钟」；
///   · 日期窗口不过滤 ⇒ 「今天读了多少」里混进昨天的；
///   · 迁移漏了 ⇒ 老库升级后点「结束并保存」才炸。
void main() {
  FocusSession session({
    required String id,
    String date = '2026-10-19',
    int seconds = 600,
    String kind = 'free',
    String sourceId = '',
    String title = '阅读',
  }) =>
      FocusSession(
        id: id,
        studentId: 'stu_001',
        kind: FocusTargetKindWire.fromWire(kind),
        sourceId: sourceId,
        title: title,
        date: date,
        seconds: seconds,
        startedAt: DateTime(2026, 10, 19, 10),
        updatedAt: DateTime(2026, 10, 19, 10),
      );

  test('同一会话重复保存 = 更新，不是新增', () async {
    final dir = await setUpTestDatabase();
    addTearDown(() => tearDownTestDatabase(dir));

    final repo = LocalDatabaseService.instance;
    await repo.saveFocusSession(session(id: 'fs_1', seconds: 600));
    await repo.saveFocusSession(session(id: 'fs_1', seconds: 900));
    await repo.saveFocusSession(session(id: 'fs_2', seconds: 300));

    final rows = await repo.queryFocusSessions(
      studentId: 'stu_001',
      from: '2026-10-19',
      to: '2026-10-19',
    );
    expect(rows, hasLength(2), reason: '两个会话只能是两行');
    final first = rows.firstWhere((r) => r.id == 'fs_1');
    expect(first.seconds, 900, reason: '最后一次检查点生效');
    expect(first.title, '阅读');
    expect(first.kind, FocusTargetKind.free);
  });

  test('按天取一段：窗口外的不算进「今天」', () async {
    final dir = await setUpTestDatabase();
    addTearDown(() => tearDownTestDatabase(dir));

    final repo = LocalDatabaseService.instance;
    await repo.saveFocusSession(session(id: 'fs_today', date: '2026-10-19'));
    await repo.saveFocusSession(session(id: 'fs_yest', date: '2026-10-18'));
    await repo.saveFocusSession(session(id: 'fs_far', date: '2026-09-01'));

    final today = await repo.queryFocusSessions(
      studentId: 'stu_001',
      from: '2026-10-19',
      to: '2026-10-19',
    );
    expect(today.map((r) => r.id), ['fs_today']);

    final twoWeeks = await repo.queryFocusSessions(
      studentId: 'stu_001',
      from: '2026-10-06',
      to: '2026-10-19',
    );
    expect(twoWeeks.map((r) => r.id).toSet(), {'fs_today', 'fs_yest'});
  });

  test('别人的流水取不到', () async {
    final dir = await setUpTestDatabase();
    addTearDown(() => tearDownTestDatabase(dir));

    final repo = LocalDatabaseService.instance;
    await repo.saveFocusSession(
      session(id: 'fs_1').studentIdOf('stu_002'),
    );
    await repo.saveFocusSession(session(id: 'fs_2'));

    final rows = await repo.queryFocusSessions(
      studentId: 'stu_001',
      from: '2026-10-01',
      to: '2026-10-31',
    );
    expect(rows.map((r) => r.id), ['fs_2']);
  });

  test('v27 老库升级补出 focus_session，且能写能读', () async {
    final dir = await createIsolatedTestDir('easy_learn_v27_');
    addTearDown(() => tearDownTestDatabase(dir));
    pointPathProviderTo(dir);
    await DatabaseService.resetForTesting();

    final legacy = await databaseFactory.openDatabase(
      testDatabasePath(dir),
      options: OpenDatabaseOptions(
        version: 27,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE app_user (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              phone TEXT UNIQUE,
              role TEXT NOT NULL,
              avatar TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    await legacy.close();

    // 表的存在性就是判据：缺表时这里抛 `no such table: focus_session`，
    // 而它只在学生第一次点「临时打卡」保存时才出现 —— 很难复现。
    final repo = LocalDatabaseService.instance;
    await repo.saveFocusSession(session(id: 'fs_after', seconds: 120));
    final rows = await repo.queryFocusSessions(
      studentId: 'stu_001',
      from: '2026-10-19',
      to: '2026-10-19',
    );
    expect(rows.single.seconds, 120);
  });
}

extension on FocusSession {
  FocusSession studentIdOf(String value) => FocusSession(
        id: id,
        studentId: value,
        kind: kind,
        sourceId: sourceId,
        title: title,
        date: date,
        seconds: seconds,
        startedAt: startedAt,
        updatedAt: updatedAt,
      );
}
