import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/services/local_database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/db_test_helper.dart';

/// v23 迁移的护栏：`app_user.passwordUpdatedAt`。
///
/// 单开一个文件而不是塞进 `auth_provision_test.dart`：那边是纯单元 +
/// widget 测试，而这个文件要切 sqflite 的全局 factory 到 FFI 实现。
/// 混在一个文件里，一旦测试执行顺序变化，widget 测试就可能踩到
/// 「databaseFactory 已经被换掉」的副作用 —— 那种红的成因极难定位。
///
/// 迁移用例的价值和别处一样：**「老库升级没事、全新安装直接炸」**
/// 是这个项目已经栽过一次的坑（`_onCreate` 漏列）。所以这里两条都测。
void main() {
  test('老库升级补出 passwordUpdatedAt；只有设过密码的账号才被回填', () async {
    final dir = await createIsolatedTestDir('easy_learn_v22_');
    addTearDown(() => tearDownTestDatabase(dir));
    pointPathProviderTo(dir);
    await DatabaseService.resetForTesting();

    // 造一个 v22 的库。app_user 用 v3 时代的形状（**没有** passwordUpdatedAt），
    // 这正是本次迁移要补的那一列 —— 夹具里带上它，测的就不是迁移了。
    final legacy = await databaseFactory.openDatabase(
      testDatabasePath(dir),
      options: OpenDatabaseOptions(
        version: 22,
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
              bio TEXT DEFAULT ''
            )
          ''');
          await db.insert('app_user', {
            'id': 'stu_old',
            'name': '老账号',
            'phone': '13700000001',
            'role': 'student',
            'avatar': 'student',
            'password': 'abc123',
            'hobbies': '阅读',
          });
          // 微信建的号没有密码。它**不该**被回填「设置过密码」的时间 ——
          // 回填了的话，界面上一个从未设过密码的账号会显示「已设置」。
          await db.insert('app_user', {
            'id': 'wx_old',
            'name': '微信老账号',
            'role': 'student',
            'avatar': 'student',
            'password': null,
            'wechatOpenId': 'mock-wechat-student',
          });
        },
      ),
    );
    await legacy.close();

    // 用应用自己的连接打开，触发 onUpgrade。
    final student = await DatabaseService.instance.findUserByPhone(
      '13700000001',
    );
    expect(student, isNotNull);
    expect(
      DateTime.tryParse(student!['passwordUpdatedAt'] as String? ?? ''),
      isNotNull,
      reason: '有密码的老账号必须被回填一个可解析的时间，否则「改密后失效旧登录态」没有依据',
    );

    final wechat = await DatabaseService.instance.findUserByWechat(
      'mock-wechat-student',
    );
    expect(wechat, isNotNull);
    expect(
      wechat!['passwordUpdatedAt'],
      isNull,
      reason: '从未设置过密码的账号不能有「密码设置时间」——语义会被读反',
    );

    // v25：这个极简库里**没有** ai_practice_question。
    //
    // 只跳过 ALTER 是不够的：库能打开、登录能用、其它页面都正常，
    // 直到学生点「生成变式题」才报 `no such table` —— 而那时看到的
    // 是复习页坏了，没人会想到是迁移少建了一张表。
    final db = await LocalDatabaseService.instance.database;
    final columns = await db.rawQuery('PRAGMA table_info(ai_practice_question)');
    expect(
      columns.map((row) => row['name']).toList(),
      containsAll(<String>['questionType', 'optionsJson']),
      reason: '缺表的极简老库必须在这里把最终形态建出来',
    );
  });

  test('全新安装就有这一列，且演示账号带着密码时间', () async {
    final dir = await setUpTestDatabase();
    addTearDown(() => tearDownTestDatabase(dir));

    for (final phone in const ['13800000001', '13800000002']) {
      final user = await DatabaseService.instance.findUserByPhone(phone);
      expect(user, isNotNull, reason: '演示账号 $phone 应当存在');
      expect(user!['password'], 'abc123');
      expect(
        DateTime.tryParse(user['passwordUpdatedAt'] as String? ?? ''),
        isNotNull,
        reason:
            '_onCreate 漏这一列会造成「老库升级没事、全新安装直接炸」——'
            '所以全新安装这条路必须单独测一次',
      );
    }
  });
}
