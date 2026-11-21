import 'package:easy_learn_app/models/subject_scope.dart';
import 'package:easy_learn_app/models/textbook.dart';
import 'package:easy_learn_app/models/user_profile_model.dart';
import 'package:easy_learn_app/pages/parent/subject_scope_page.dart';
import 'package:easy_learn_app/repositories/user_repository.dart';
import 'package:easy_learn_app/services/subject_api.dart';
import 'package:easy_learn_app/services/textbook_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 配置页的「教材」区：选中书 → 选起始节 → 保存时**一并写下去**。
///
/// ## 为什么要单独盯这一段
///
/// 「保存」按钮只做一件事：把这一屏的值写到服务端。教材是后来加的三个字段，
/// 最容易的出错方式是 `_save()` 里手工 `SubjectScope(...)` 忘了带 `bookId`
/// —— 保存返回 200、界面还显示书名（本地 `_scope` 没被覆盖），
/// 但下一次打开就是「没选教材」。这类「保存成功但丢了一半」的 bug
/// 只有断言**发给服务端的 payload** 才抓得到，断言界面文字抓不到。
void main() {
  /// 默认视口 800×600 装不下这一整页（教材 + 题量 + 难度 + 范围 + 保存按钮），
  /// ListView 只构建可见区域，`tap` 会打在空处并只留一句 warning ——
  /// 症状是「保存没发请求」，看起来像按钮没接上（B23 同族坑）。
  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1080, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(GetMaterialApp(home: page));
    await tester.pumpAndSettle();
  }

  test('模型：教材三件套必须进写请求；摘要显示书名而不是「每天 5 题」', () {
    const scope = SubjectScope(
      studentId: 's1',
      subject: '数学',
      configured: true,
      bookId: 'tb_1',
      bookTitle: '人教版七上',
      startUnitNo: 3,
      unitsPerDay: 2,
    );
    final body = scope.toWriteJson();
    expect(body['bookId'], 'tb_1');
    expect(body['startUnitNo'], 3);
    expect(body['unitsPerDay'], 2);
    expect(scope.summary, contains('人教版七上'));
    expect(scope.summary, contains('第 3 节起'));

    // 取消选书必须能被表达出来（否则家长永远退不回「手填范围」）。
    final cleared = scope.copyWith(clearBook: true);
    expect(cleared.bookId, isNull);
    expect(cleared.toWriteJson()['bookId'], '');
  });

  testWidgets('没导入过教材：只给「从 ima 导入」，不给下拉', (tester) async {
    await pumpPage(
      tester,
      SubjectScopePage(
        subject: '数学',
        studentId: 's1',
        repository: _FakeScopeRepo(),
        textbookRepository: _FakeTextbookRepo(
          library: const TextbookLibrary(
            connected: true,
            folderPath: '教学资料/教材/数学',
            books: <TextbookBook>[],
          ),
        ),
        userRepository: const _FakeUserRepo(),
      ),
    );

    expect(find.text('从 ima 导入'), findsOneWidget);
    expect(find.text('删除已导入'), findsNothing,
        reason: '没有已导入的书时给删除按钮，点开是空列表');
    expect(find.textContaining('从第几节开始'), findsNothing,
        reason: '没有书的时候给下拉，家长点开是空的');
  });

  testWidgets('选中教材 + 选到第 2 节 → 保存时 bookId / startUnitNo 一起发出去', (tester) async {
    final scopeRepo = _FakeScopeRepo();
    await pumpPage(
      tester,
      SubjectScopePage(
        subject: '数学',
        studentId: 's1',
        repository: scopeRepo,
        textbookRepository: _FakeTextbookRepo(
          library: const TextbookLibrary(
            connected: true,
            folderPath: '教学资料/教材/数学',
            books: <TextbookBook>[
              TextbookBook(id: 'tb_1', title: '人教版七上', unitCount: 2),
            ],
          ),
          units: const <TextbookUnit>[
            TextbookUnit(unitNo: 1, title: '第1章 有理数', summary: '数轴'),
            TextbookUnit(unitNo: 2, title: '第2章 整式', summary: '同类项'),
          ],
        ),
        userRepository: const _FakeUserRepo(),
      ),
    );

    await tester.tap(find.text('人教版七上（2 节）'));
    await tester.pumpAndSettle();

    // 选书后章节下拉才出现 —— 这是「书和章节是父子关系」的界面证据。
    expect(find.textContaining('从第几节开始'), findsOneWidget);

    await tester.tap(find.text('1. 第1章 有理数'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2. 第2章 整式').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存范围'));
    await tester.pumpAndSettle();

    final sent = scopeRepo.lastWritten;
    expect(sent, isNotNull, reason: '保存必须真的发出请求');
    expect(sent!.bookId, 'tb_1');
    expect(sent.startUnitNo, 2, reason: '选的起始节没写下去的话，下次打开又回到第 1 节');
    expect(sent.bookTitle, '人教版七上', reason: '书名只用于显示，但丢了会让色块摘要变成「教材 · 第 2 节起」');
  });

  testWidgets('教材库读不到（027 未迁移 / 断网）：页面不红，手填范围照常保存', (tester) async {
    final scopeRepo = _FakeScopeRepo();
    await pumpPage(
      tester,
      SubjectScopePage(
        subject: '数学',
        studentId: 's1',
        repository: scopeRepo,
        textbookRepository: _ThrowingTextbookRepo(),
        userRepository: const _FakeUserRepo(),
      ),
    );

    expect(find.text('保存范围'), findsOneWidget, reason: '可选能力挂掉不能把整页搞成错误页');

    await tester.enterText(find.byType(TextField), '有理数加减');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存范围'));
    await tester.pumpAndSettle();

    expect(scopeRepo.lastWritten?.points, contains('有理数加减'));
    expect(scopeRepo.lastWritten?.bookId, isNull);
  });

  const twoEnglishBooks = <TextbookBook>[
    TextbookBook(id: 'tb_old', title: '英语ENGLISH', unitCount: 27),
    TextbookBook(id: 'tb_new', title: '人教版七年级上册 英语', unitCount: 10),
  ];

  TextbookLibrary englishLibrary() => const TextbookLibrary(
        connected: true,
        folderPath: '教学资料/教材/英语',
        books: twoEnglishBooks,
      );

  /// 走完「删除已导入 → 选书 → 确认」三步；`confirm=false` 时点取消。
  Future<void> deleteThroughUi(WidgetTester tester, String bookTitle, {bool confirm = true}) async {
    await tester.tap(find.text('删除已导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(bookTitle));
    await tester.pumpAndSettle();
    expect(find.text('删除这本教材？'), findsOneWidget, reason: '删整本书必须二次确认');
    await tester.tap(find.text(confirm ? '删除' : '取消'));
    await tester.pumpAndSettle();
  }

  testWidgets('两本英语教材：删掉旧的那本后只剩新的（先选书、再确认）', (tester) async {
    final textbookRepo = _FakeTextbookRepo(library: englishLibrary());
    await pumpPage(
      tester,
      SubjectScopePage(
        subject: '英语',
        studentId: 's1',
        repository: _FakeScopeRepo(
          scope: const SubjectScope(
            studentId: 's1', subject: '英语', bookId: 'tb_new',
            bookTitle: '人教版七年级上册 英语',
          ),
        ),
        textbookRepository: textbookRepo,
        userRepository: const _FakeUserRepo(),
      ),
    );

    expect(find.text('删除已导入'), findsOneWidget,
        reason: '以前没有删除入口，导错的旧教材只能一直留在配置页');
    await deleteThroughUi(tester, '英语ENGLISH');

    expect(textbookRepo.deletedBookIds, <String>['tb_old']);
    expect(find.text('英语ENGLISH（27 节）'), findsNothing, reason: '删完必须刷新书列表');
    expect(find.text('人教版七年级上册 英语（10 节）'), findsOneWidget);
    expect(find.textContaining('已删除'), findsOneWidget);
  });

  testWidgets('列表里标出「当前正在使用」，避免删错正在出题的那本', (tester) async {
    await pumpPage(
      tester,
      SubjectScopePage(
        subject: '英语',
        studentId: 's1',
        repository: _FakeScopeRepo(
          scope: const SubjectScope(studentId: 's1', subject: '英语', bookId: 'tb_new'),
        ),
        textbookRepository: _FakeTextbookRepo(library: englishLibrary()),
        userRepository: const _FakeUserRepo(),
      ),
    );
    await tester.tap(find.text('删除已导入'));
    await tester.pumpAndSettle();
    expect(find.textContaining('当前正在使用'), findsOneWidget);
  });

  testWidgets('删的是当前选中的教材：随后保存不能把已删的 bookId 写回去', (tester) async {
    final scopeRepo = _FakeScopeRepo(
      scope: const SubjectScope(
        studentId: 's1', subject: '数学', bookId: 'tb_1',
        bookTitle: '人教版七上', startUnitNo: 2,
      ),
    );
    await pumpPage(
      tester,
      SubjectScopePage(
        subject: '数学',
        studentId: 's1',
        repository: scopeRepo,
        textbookRepository: _FakeTextbookRepo(
          library: const TextbookLibrary(
            connected: true,
            folderPath: '教学资料/教材/数学',
            books: <TextbookBook>[
              TextbookBook(id: 'tb_1', title: '人教版七上', unitCount: 2),
            ],
          ),
          units: const <TextbookUnit>[
            TextbookUnit(unitNo: 1, title: '第1章 有理数', summary: '数轴'),
            TextbookUnit(unitNo: 2, title: '第2章 整式', summary: '同类项'),
          ],
          deleteScopeCleared: true,
        ),
        userRepository: const _FakeUserRepo(),
      ),
    );

    expect(find.textContaining('从第几节开始'), findsOneWidget);
    await deleteThroughUi(tester, '人教版七上');

    expect(find.textContaining('从第几节开始'), findsNothing,
        reason: '书删了，章节下拉不该还挂着');
    await tester.tap(find.text('保存范围'));
    await tester.pumpAndSettle();

    expect(scopeRepo.lastWritten, isNotNull);
    expect(scopeRepo.lastWritten!.bookId, isNull,
        reason: '写回已删的 bookId = 界面显示教材、出题静默退回手填范围');
    expect(scopeRepo.lastWritten!.toWriteJson()['bookId'], '');
  });

  testWidgets('二次确认点取消：一本都不删', (tester) async {
    final textbookRepo = _FakeTextbookRepo(library: englishLibrary());
    await pumpPage(
      tester,
      SubjectScopePage(
        subject: '英语',
        studentId: 's1',
        repository: _FakeScopeRepo(),
        textbookRepository: textbookRepo,
        userRepository: const _FakeUserRepo(),
      ),
    );
    await deleteThroughUi(tester, '英语ENGLISH', confirm: false);
    expect(textbookRepo.deletedBookIds, isEmpty);
    expect(find.text('英语ENGLISH（27 节）'), findsOneWidget);
  });

  testWidgets('删除失败要响亮提示，书不能从列表里先消失', (tester) async {
    await pumpPage(
      tester,
      SubjectScopePage(
        subject: '英语',
        studentId: 's1',
        repository: _FakeScopeRepo(),
        textbookRepository: _FailingDeleteRepo(library: englishLibrary()),
        userRepository: const _FakeUserRepo(),
      ),
    );
    await deleteThroughUi(tester, '英语ENGLISH');
    expect(find.textContaining('删除没成功'), findsOneWidget);
    expect(find.text('英语ENGLISH（27 节）'), findsOneWidget);
  });
}

class _FakeScopeRepo implements SubjectScopeRepository {
  _FakeScopeRepo({this.scope});

  /// 打开页面时服务端已有的范围（用来模拟「正在用某本教材」）。
  final SubjectScope? scope;
  SubjectScope? lastWritten;

  @override
  Future<List<SubjectScope>> listScopes(String studentId) async => const <SubjectScope>[];

  @override
  Future<SubjectScope> getScope({
    required String studentId,
    required String subject,
  }) async =>
      scope ?? SubjectScope(studentId: studentId, subject: subject);

  @override
  Future<List<String>> loadSeeds({
    required String studentId,
    required String subject,
  }) async =>
      const <String>[];

  @override
  Future<SubjectScope> putScope(SubjectScope scope) async {
    lastWritten = scope;
    return scope.copyWith(configured: true);
  }
}

class _FakeTextbookRepo implements TextbookRepository {
  _FakeTextbookRepo({
    this.library = TextbookLibrary.empty,
    this.units = const <TextbookUnit>[],
    this.deleteScopeCleared = false,
  });

  TextbookLibrary library;
  final List<TextbookUnit> units;
  final bool deleteScopeCleared;
  final List<String> deletedBookIds = <String>[];

  @override
  Future<TextbookLibrary> listBooks({
    required String studentId,
    required String subject,
  }) async =>
      library;

  @override
  Future<List<TextbookUnit>> listUnits({
    required String studentId,
    required String bookId,
  }) async =>
      units;

  @override
  Future<TextbookBook> importBook({
    required String studentId,
    required String subject,
    required String mediaId,
    String fileName = '',
    String grade = '',
    String term = '',
  }) async =>
      const TextbookBook(id: 'tb_new', title: '新教材', unitCount: 1);

  @override
  Future<bool> deleteBook({
    required String studentId,
    required String bookId,
  }) async {
    deletedBookIds.add(bookId);
    // 与真服务端一致：删完重新列书，这本不再出现。
    library = TextbookLibrary(
      connected: library.connected,
      folderPath: library.folderPath,
      books: library.books.where((one) => one.id != bookId).toList(),
      available: library.available,
      reason: library.reason,
    );
    return deleteScopeCleared;
  }
}

/// 模拟 027 未迁移：连「有没有书」都读不到。
class _ThrowingTextbookRepo implements TextbookRepository {
  @override
  Future<TextbookLibrary> listBooks({
    required String studentId,
    required String subject,
  }) async =>
      throw StateError('relation "subject_book" does not exist');

  @override
  Future<List<TextbookUnit>> listUnits({
    required String studentId,
    required String bookId,
  }) async =>
      throw StateError('relation "subject_unit" does not exist');

  @override
  Future<TextbookBook> importBook({
    required String studentId,
    required String subject,
    required String mediaId,
    String fileName = '',
    String grade = '',
    String term = '',
  }) async =>
      throw StateError('relation "subject_book" does not exist');

  @override
  Future<bool> deleteBook({
    required String studentId,
    required String bookId,
  }) async =>
      throw StateError('relation "subject_book" does not exist');
}

/// 删除请求失败：书不能被乐观地从界面上抹掉。
class _FailingDeleteRepo extends _FakeTextbookRepo {
  _FailingDeleteRepo({required super.library});

  @override
  Future<bool> deleteBook({
    required String studentId,
    required String bookId,
  }) async =>
      throw StateError('服务端删除失败');
}

/// 学生档案仓储的假实现：年级学期查询立刻返回（无档案），
/// 让配置页的 `_load` 不会去连真实后端而卡住 `pumpAndSettle`。
class _FakeUserRepo implements UserRepository {
  const _FakeUserRepo();

  @override
  Future<UserProfileModel?> queryUserProfile(String userId) async => null;

  @override
  Future<void> updateUserProfile(UserProfileModel profile) async {}

  @override
  Future<List<Map<String, dynamic>>> queryUsersByIds(List<String> ids) async =>
      const <Map<String, dynamic>>[];
}
