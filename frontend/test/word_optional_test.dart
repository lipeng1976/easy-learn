import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:easy_learn_app/services/word_api.dart';

/// 「不是所有人都有 ima；没有时功能可以缺、不可错」的客户端判据。
/// 行为判据（UnavailableWordRepository 全链路不抛）+ 源码契约（入口隐藏、
/// 学生 id 口径、DB 版本三处同步）。
///
/// 源码契约只看**代码**，不看注释：设计说明里本该出现反面口径的名字，
/// 把它算进结果会变成「注释写清楚了反而判据红」的假阳性。
String _codeOnly(String source) => source
    .split('\n')
    .map((line) {
      final i = line.indexOf('//');
      return i < 0 ? line : line.substring(0, i);
    })
    .join('\n');

void main() {
  test('纯本地 / 服务端没部署：七个端点全部不抛异常', () async {
    const repo = UnavailableWordRepository();
    final books = await repo.listBooks('s1');
    expect(books.connected, isFalse);
    expect(books.importAvailable, isFalse, reason: '导入入口据此隐藏');
    expect(await repo.listEntries(studentId: 's1', bookId: 'b1'), isEmpty);
    final scope = await repo.getScope('s1');
    expect(scope.hasBook, isFalse);
    expect((await repo.putScope(scope)).hasBook, isFalse);
    await expectLater(
      repo.postDaily(
        studentId: 's1',
        day: '2026-11-11',
        total: 0,
        correct: 0,
        streak: 0,
        wrongWords: const <Map<String, dynamic>>[],
      ),
      completes,
    );
    expect(await repo.listDaily(studentId: 's1'), isEmpty);
    final imported = await repo.importBook(studentId: 's1', mediaId: 'm1');
    expect(imported['imported'], isFalse);
  });

  test('源码契约：无 ima 隐藏导入区，家长端全线取 selectedStudentId', () {
    final page = File('lib/pages/parent/word_scope_page.dart').readAsStringSync();
    expect(page.contains('_books.connected && _books.available.isNotEmpty'), isTrue,
        reason: 'connected:false 时导入区整块不渲染');
    expect(_codeOnly(page).contains('selectedStudentId'), isTrue);
    expect(_codeOnly(page).contains('targetStudentId'), isFalse,
        reason: 'targetStudentId 取 boundStudents.first，多孩家庭会串库');

    final cardCode = _codeOnly(File('lib/widgets/word_daily_card.dart').readAsStringSync());
    expect(cardCode.contains('targetStudentId'), isFalse,
        reason: '家长端摘要也必须按所选孩子取数');

    final card = File('lib/widgets/word_daily_card.dart').readAsStringSync();
    expect(card.contains('catch (_)'), isTrue, reason: '摘要读失败不得冒泡成页面红条');
    expect(card.contains('ever<String>'), isTrue, reason: 'boundStudents 晚到要靠 ever 重试');
    expect(card.contains('_generation'), isTrue, reason: '快速切孩子要丢掉迟到响应');
  });

  test('源码契约：DB v32 三处同步 + 三条路由已注册', () {
    final db = File('lib/services/local_database_service.dart').readAsStringSync();
    expect(db.contains('version: 32,'), isTrue);
    expect(db.contains('if (oldVersion < 32)'), isTrue);
    expect(db.contains('CREATE TABLE IF NOT EXISTS word_entry_local'), isTrue);
    expect(db.contains('CREATE TABLE IF NOT EXISTS word_answer'), isTrue);
    expect(db.contains('queryWordAnswers'), isTrue);

    final app = File('lib/app.dart').readAsStringSync();
    for (final route in <String>['/word-drill', '/word-scope', '/word-daily-logs']) {
      expect(app.contains("name: '$route'"), isTrue, reason: '$route 必须注册');
    }
  });
}
