import 'package:easy_learn_app/models/homework_kind.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/services/database_service.dart';
// 这里要直连**本地库**跑原生 SQL（造数据 / 断言存储层），
// 而上云门面 `DatabaseService` 不承诺「`.database` 就是当前数据源」——
// 云端模式下它是服务端。所以显式指名本地实现。
import 'package:easy_learn_app/services/local_database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/db_test_helper.dart';

/// 「这份作业要不要批改」的判断口径。
///
/// 这一层全是纯规则，没有 I/O，所以断言可以写得很细：
/// 一旦哪天有人把 `needsGrading` 的默认值翻过来，或者把
/// `HomeworkGradingMode.of` 的顺序写反，这些用例会当场炸。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('按作业类型推「要不要批改」的默认值', () {
    test('过程型作业没有可判的产出', () {
      for (final title in const [
        '背诵《静夜思》',
        '背诵课文第3段',
        '朗读课文',
        '熟读并朗读第五课',
        '预习第五单元',
        '复习第三单元',
      ]) {
        expect(
          HomeworkKind.of(title).needsGrading,
          isFalse,
          reason: '「$title」的产出是一段过程，不是一张有答案的纸',
        );
      }
    });

    test('默写、听写、抄写、字帖：有对错，但题干不在照片里', () {
      // 这类作业的对错当场就由念词表的人核对完了，交上来的照片是
      // 「我做过了」的凭证，不是一道待判的题 —— 让模型照着这张照片判，
      // 它只能猜学生写的是什么、猜得对不对。
      for (final title in const [
        '默写单词',
        '默写英语单词Unit3',
        '听写第3课生字',
        '抄写第3课生字',
        '英语单词抄写',
        '字帖一页',
        '练字20分钟',
        '描红本第5页',
      ]) {
        expect(
          HomeworkKind.of(title).needsGrading,
          isFalse,
          reason: '「$title」的题干（词表/范字）没被拍进来，没有可判的东西',
        );
      }
    });

    test('口算、订正、书面：题目和答案在同一张纸上', () {
      for (final title in const [
        '口算20题',
        '订正昨天的错题',
        '完成练习册P12',
        '作文一篇',
      ]) {
        expect(
          HomeworkKind.of(title).needsGrading,
          isTrue,
          reason: '「$title」照着题面就能判，可以批',
        );
      }
    });

    test('照抄和默写要分开 —— 「英语单词抄写」不是默写', () {
      // 「单词」会把标题拉去 dictation，但照着写和听人念着默出来是两回事。
      // 这条钉住的是 _patterns 的键序，不是措辞。
      // （两类在「要不要批改」上结论相同，所以这里错判只影响那张类型标签 ——
      // 但标签错了，学生会去关一个本来就已经关着的开关。）
      expect(HomeworkKind.of('英语单词抄写'), HomeworkKind.copywork);
      expect(HomeworkKind.of('英语单词抄写').label, '抄写');
    });

    test('「背诵并默写」按默写算 —— 背下来还得落到纸上', () {
      // 两种都命中时取更靠前的那个类型（默写）。这条钉的是判定顺序；
      // 而默写现在默认不批（题干不在照片里），是另一条独立的约定。
      expect(HomeworkKind.of('背诵并默写《静夜思》'), HomeworkKind.dictation);
      expect(HomeworkKind.of('背诵并默写《静夜思》').label, '默写');
      expect(HomeworkKind.of('背诵并默写《静夜思》').needsGrading, isFalse);
    });

    test('判不出类型时按书面对待 —— 大多数作业本来就是书面的', () {
      expect(HomeworkKind.of('').needsGrading, isTrue);
      expect(HomeworkKind.of('把今天的错题整理一下').needsGrading, isTrue);
    });
  });

  group('批改口径三态', () {
    test('不需要批改时，AI 开没开都一样 —— 都是「无需批改」', () {
      for (final aiEnabled in const [true, false]) {
        expect(
          HomeworkGradingMode.of(needsGrading: false, aiEnabled: aiEnabled),
          HomeworkGradingMode.notRequired,
          reason: '朗读作业不需要批改，与批改能力无关',
        );
      }
    });

    test('需要批改时，能力决定是「要批」还是「批不了」', () {
      expect(
        HomeworkGradingMode.of(needsGrading: true, aiEnabled: true),
        HomeworkGradingMode.auto,
      );
      expect(
        HomeworkGradingMode.of(needsGrading: true, aiEnabled: false),
        HomeworkGradingMode.unavailable,
      );
    });

    test('只有 auto 会真的去批', () {
      expect(HomeworkGradingMode.auto.willGrade, isTrue);
      expect(HomeworkGradingMode.notRequired.willGrade, isFalse);
      expect(HomeworkGradingMode.unavailable.willGrade, isFalse);
    });

    test('作业上的 gradingMode 由两个字段现算，不落库', () {
      final base = HomeworkItem(
        id: 'hw_1',
        title: '朗读课文',
        subject: '语文',
        imageUrl: '',
        dueAt: DateTime(2026, 9, 16),
        estimatedMinutes: 10,
        status: HomeworkStatus.pending,
        wrongCount: 0,
        aiEnabled: true,
        userRole: 'student',
      );
      expect(base.gradingMode, HomeworkGradingMode.auto);

      expect(
        base.copyWith(needsGrading: false).gradingMode,
        HomeworkGradingMode.notRequired,
      );
      expect(
        base.copyWith(aiEnabled: false).gradingMode,
        HomeworkGradingMode.unavailable,
      );
    });
  });

  group('copyWith 的两处陷阱', () {
    HomeworkItem graded() => HomeworkItem(
      id: 'hw_1',
      title: '口算20题',
      subject: '数学',
      imageUrl: '',
      dueAt: DateTime(2026, 9, 16),
      estimatedMinutes: 15,
      status: HomeworkStatus.needFix,
      wrongCount: 3,
      aiEnabled: true,
      submittedAt: DateTime(2026, 9, 16, 20),
      checkedAt: DateTime(2026, 9, 16, 20, 5),
      score: 72,
      summary: '错了三道',
      gradingSource: GradingSource.cloud,
      userRole: 'student',
    );

    test('needsGrading 能真的改成 false（false 不是「不改」）', () {
      // `bool?` 参数 + `??` 的写法里，`false` 会被正确写进去 ——
      // 但改用 `bool x = true` 之类的签名就会永远改不过去，
      // 这条用例专门盯住那个方向。
      expect(graded().copyWith(needsGrading: false).needsGrading, isFalse);
    });

    test('clearResult 清得掉已批改的痕迹', () {
      final cleared = graded().copyWith(clearResult: true);
      expect(cleared.checkedAt, isNull);
      expect(cleared.score, isNull);
      expect(cleared.summary, isEmpty);
      // 反过来：不传 clearResult 就得原样留着，别顺手清了。
      final kept = graded().copyWith(status: HomeworkStatus.checking);
      expect(kept.score, 72);
      expect(kept.checkedAt, isNotNull);
    });
  });

  group('数据库迁移 v20 → v21', () {
    test('老库补上 needsGrading，历史作业一律按「需要批改」算', () async {
      final dir = await createIsolatedTestDir('easy_learn_v20_');
      pointPathProviderTo(dir);
      await DatabaseService.resetForTesting();

      // 造一个 v20 的库。列要和真正的 v20 一致（含 gradingSource），
      // 夹具少一列就变成在测夹具而不是测迁移 —— 上一个迁移用例
      // 就是踩了「homework 必须建」这个点。
      final legacy = await databaseFactory.openDatabase(
        testDatabasePath(dir),
        options: OpenDatabaseOptions(
          version: 20,
          onCreate: (db, version) async {
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
            // wish 也必须建：后续版本（v22）会给它补积分兑换的列。
            // 夹具缺表 → 迁移在 `ALTER TABLE wish` 那步炸掉，而这个失败
            // 与「夹具省了张表」有关，跟被测的 v21 迁移毫无关系 ——
            // 那种红是最费时间的红。
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
            // app_user 同样必须建：它是 v1 就有的基础表，而 v23 的迁移
            // 要给它补 passwordUpdatedAt。夹具省掉它，红的是夹具 ——
            // 报错会写成「no such table: app_user」，跟被测的迁移毫无关系。
            // 这里刻意用 v3 时代的形状（**没有** passwordUpdatedAt），
            // 好让 v23 那一步真的有列可加。
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
            // 一条批过的、一条没提交的。迁移之后两条都得是「需要批改」。
            await db.insert('homework', {
              'id': 'hw_old_graded',
              'title': '旧版已批改作业',
              'subject': '数学',
              'status': 'finished',
              'wrongCount': 0,
              'aiEnabled': 1,
              'userRole': 'student',
              'studentId': 'stu_001',
              'checkedAt': DateTime.now().toIso8601String(),
              'score': 88,
              'summary': '旧版批改结论',
              'gradingSource': 'cloud',
            });
            await db.insert('homework', {
              'id': 'hw_old_pending',
              'title': '旧版待完成作业',
              'subject': '语文',
              'status': 'pending',
              'wrongCount': 0,
              'aiEnabled': 1,
              'userRole': 'student',
              'studentId': 'stu_001',
            });
          },
        ),
      );
      await legacy.close();

      // 用当前版本打开 → 触发 _onUpgrade。
      final db = await LocalDatabaseService.instance.database;

      final columns = (await db.rawQuery('PRAGMA table_info(homework)'))
          .map((row) => row['name'] as String)
          .toSet();
      expect(
        columns,
        contains('needsGrading'),
        reason: '_onCreate 与 _onUpgrade 必须同时补，漏一边就是「老库升级没事、'
            '全新安装直接炸」',
      );

      // 默认值必须是 1：历史作业全是按「要批改」跑的。
      // 反过来（默认 0）会让一份已经批过的卷子突然变成「无需批改」，
      // 家长会以为系统把结果吃了。
      final items = await DatabaseService.instance.queryHomework('student');
      final graded = items.firstWhere((e) => e.id == 'hw_old_graded');
      expect(graded.needsGrading, isTrue);
      expect(graded.gradingMode, HomeworkGradingMode.auto);
      // 迁移不该顺手改动已有的批改结果。
      expect(graded.score, 88);
      expect(graded.summary, '旧版批改结论');
      expect(graded.gradingSource, GradingSource.cloud);

      expect(
        items.firstWhere((e) => e.id == 'hw_old_pending').needsGrading,
        isTrue,
      );
    });
  });
}
