import 'package:easy_learn_app/constants/subject_colors.dart';
import 'package:easy_learn_app/controllers/subject_board_controller.dart';
import 'package:easy_learn_app/models/checkin_models.dart';
import 'package:easy_learn_app/models/subject_scope.dart';
import 'package:easy_learn_app/models/word_checkin.dart';
import 'package:easy_learn_app/repositories/checkin_repository.dart';
import 'package:easy_learn_app/services/checkin_question_parser.dart';
import 'package:easy_learn_app/services/cloud_runtime.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/services/subject_api.dart';
import 'package:easy_learn_app/services/word_api.dart';
import 'package:easy_learn_app/widgets/subject_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 「今天练什么」两段式 · 判据（纯 Dart，不碰 sqflite / 网络）。
///
/// 盯四件事：
///   ① 十科都能配、科目名与配色不缺（新增一科不会静默只有配置没有色块）；
///   ② 出题用的是**已保存的范围**（题量 / 难度 / 条目），不是写死的 5 题；
///   ③ 读不到配置（026 未迁移 / 断网）时页面不红，按「每科未配置」渲染；
///   ④ 十科都能出教材题（11-13 起英语也能）；英语另有本地单词题，
///      两本资料各管各的，不合成一份范围、不互相覆盖摘要。
class _FakeSubjectRepo implements SubjectScopeRepository {
  _FakeSubjectRepo({this.rows = const <SubjectScope>[], this.throwOnRead = false});

  List<SubjectScope> rows;
  bool throwOnRead;
  SubjectScope? written;

  @override
  Future<List<SubjectScope>> listScopes(String studentId) async {
    if (throwOnRead) throw StateError('026 not migrated');
    return rows;
  }

  @override
  Future<SubjectScope> getScope({
    required String studentId,
    required String subject,
  }) async {
    if (throwOnRead) throw StateError('026 not migrated');
    return rows.firstWhere(
      (one) => one.subject == subject,
      orElse: () => SubjectScope(studentId: studentId, subject: subject),
    );
  }

  @override
  Future<List<String>> loadSeeds({
    required String studentId,
    required String subject,
  }) async =>
      const <String>[];

  @override
  Future<SubjectScope> putScope(SubjectScope scope) async {
    written = scope;
    return scope.copyWith(configured: true);
  }
}

class _FakeCheckinRepo implements CheckinRepository {
  _FakeCheckinRepo({this.pending = const <String>[], this.failWith});

  List<String> pending;
  String? failWith;
  Map<String, dynamic>? lastGenerate;

  @override
  @override
  Future<List<CheckinSubjectSummary>> subjectSummaries({String? studentId}) async =>
      // 假仓库不做分组：需要汇总数字的用例自己给一份（见
      // `checkin_subject_summary_test.dart`）。默认空 = 页面退回平铺列表。
      const <CheckinSubjectSummary>[];

  @override
  Future<CheckinQuizPage> getQuizzes({
    String? studentId,
    CheckinQuizStatus status = CheckinQuizStatus.all,
    // 按科目过滤由真仓库下到 SQL；假仓库不实现（用例只关心分区与分页）。
    String subject = '',
    int limit = 0,
    int offset = 0,
  }) async =>
      CheckinQuizPage(
        items: pending
            .map((subject) => CheckinQuiz(
                  id: 'q_$subject',
                  studentId: studentId ?? 's1',
                  quizDate: '2026-11-12',
                  questions: const <CheckinQuestion>[],
                  subject: subject,
                ))
            .toList(),
        total: pending.length,
        hasMore: false,
      );

  @override
  Future<List<CheckinSeed>> loadSeeds({String? studentId, String? subject}) async =>
      const <CheckinSeed>[];

  @override
  Future<CheckinQuiz> generate({
    String? studentId,
    required String quizDate,
    String subject = '',
    int count = 0,
    List<String> knowledgePoints = const <String>[],
    String difficulty = '',
  }) async {
    lastGenerate = <String, dynamic>{
      'studentId': studentId,
      'quizDate': quizDate,
      'subject': subject,
      'count': count,
      'knowledgePoints': knowledgePoints,
      'difficulty': difficulty,
    };
    if (failWith != null) throw StateError(failWith!);
    return CheckinQuiz(
      id: 'new',
      studentId: studentId ?? 's1',
      quizDate: quizDate,
      questions: List<CheckinQuestion>.generate(
        count,
        (i) => CheckinQuestion(
          stem: '题$i',
          options: const <String>['A', 'B', 'C', 'D'],
          answer: 'A',
          knowledge: subject,
          analysis: '',
          type: CheckinQuestionType.choice,
        ),
      ),
      subject: subject,
      difficulty: difficulty,
    );
  }

  @override
  Future<CheckinSubmitResult> submit({
    required String quizId,
    required Map<int, String> picked,
  }) async =>
      const CheckinSubmitResult(
        quizId: 'q',
        score: 0,
        total: 0,
        items: <CheckinItemResult>[],
      );
}

SubjectScope scopeOf(String subject, {int count = 5, List<String> points = const []}) =>
    SubjectScope(
      studentId: 's1',
      subject: subject,
      dailyCount: count,
      difficulty: '提高',
      points: points,
      configured: true,
    );

void main() {
  test('十科都在：都有配色、都有范围标签；十科都能出题', () {
    expect(kSubjectNames.length, 10);
    for (final subject in kSubjectNames) {
      expect(kSubjectColors.containsKey(subject), isTrue,
          reason: '$subject 没有配色，色块会显示成「其他」的灰');
      expect(subjectPointLabel(subject), isNotEmpty);
    }
    // 11-12 定：语文/历史等也只出选择题和判断题，于是十科一起开。
    expect(kSubjectDrillReady, kSubjectNames,
        reason: '「出题待开放」已取消，十科都该能出');
    final colors = kSubjectNames.map(subjectColor).toSet();
    expect(colors.length, kSubjectNames.length, reason: '任意两科撞色就分不出来了');
  });

  test('加载：已配的进 scopes，没配的读出来是「未配置」而不是 null', () async {
    final subjectRepo = _FakeSubjectRepo(rows: <SubjectScope>[
      scopeOf('数学', count: 8, points: <String>['整式化简']),
    ]);
    final c = SubjectBoardController(
      subjectRepo: subjectRepo,
      checkinRepo: _FakeCheckinRepo(),
      studentId: 's1',
    );

    await c.load();

    expect(c.scopeOf('数学').configured, isTrue);
    expect(c.scopeOf('数学').dailyCount, 8);
    final chinese = c.scopeOf('语文');
    expect(chinese.configured, isFalse);
    expect(chinese.dailyCount, 5, reason: '未配置也要能直接拿去出题');
    expect(chinese.points, isEmpty);
  });

  test('出题用已保存的范围（题量/难度/条目），不是写死的 5 题', () async {
    final subjectRepo = _FakeSubjectRepo(rows: <SubjectScope>[
      scopeOf('数学', count: 3, points: <String>['有理数加减', '整式化简']),
    ]);
    final checkinRepo = _FakeCheckinRepo();
    final c = SubjectBoardController(
      subjectRepo: subjectRepo,
      checkinRepo: checkinRepo,
      studentId: 's1',
      now: () => DateTime(2026, 11, 12, 20, 30),
    );

    await c.load();
    final ok = await c.generate('数学');

    expect(ok, isTrue);
    final sent = checkinRepo.lastGenerate!;
    expect(sent['count'], 3);
    expect(sent['difficulty'], '提高');
    expect(sent['knowledgePoints'], <String>['有理数加减', '整式化简']);
    expect(sent['quizDate'], '2026-11-12',
        reason: '晚上 8 点后必须还是本地日，UTC 会把题记到明天');
    expect(c.hint.value, contains('3'));
  });

  test('未配置也能出题：携带空范围交给服务端回落错题本，难度不假装是「基础」', () async {
    final checkinRepo = _FakeCheckinRepo();
    final c = SubjectBoardController(
      subjectRepo: _FakeSubjectRepo(),
      checkinRepo: checkinRepo,
      studentId: 's1',
    );

    await c.load();
    await c.generate('数学');

    expect(checkinRepo.lastGenerate!['knowledgePoints'], isEmpty);
    expect(checkinRepo.lastGenerate!['difficulty'], '',
        reason: '空串 = 没指定，别凭空造一批「基础」题进统计');
  });

  test('待完成按科目计数：语文 2 份不会算到数学头上', () async {
    final c = SubjectBoardController(
      subjectRepo: _FakeSubjectRepo(),
      checkinRepo: _FakeCheckinRepo(pending: <String>['语文', '语文', '数学']),
      studentId: 's1',
    );

    await c.load();

    expect(c.pendingBySubject['语文'], 2);
    expect(c.pendingBySubject['数学'], 1);
  });

  test('读不到配置（026 未迁移 / 断网）：不抛错，按每科未配置渲染', () async {
    final c = SubjectBoardController(
      subjectRepo: _FakeSubjectRepo(throwOnRead: true),
      checkinRepo: _FakeCheckinRepo(),
      studentId: 's1',
    );

    await c.load();

    expect(c.loading.value, isFalse);
    expect(c.scopes, isEmpty);
    expect(c.scopeOf('数学').configured, isFalse,
        reason: '可选能力规矩：功能可以缺，不能让整页变红');
  });

  test('出题失败把原因说人话（no_seed 提示先填范围）', () async {
    final checkinRepo = _FakeCheckinRepo(failWith: 'bad_request: no_seed');
    final c = SubjectBoardController(
      subjectRepo: _FakeSubjectRepo(rows: <SubjectScope>[scopeOf('数学')]),
      checkinRepo: checkinRepo,
      studentId: 's1',
    );

    await c.load();
    final ok = await c.generate('数学');

    expect(ok, isFalse);
    expect(c.hint.value, contains('先'));
    expect(c.generating, isEmpty, reason: '失败要退出「出题中」，否则色块永久转圈');
  });

  test('英语块保留「今天做了多少」：合并掉 WordDailyCard 后信息不能丢', () async {
    final c = SubjectBoardController(
      subjectRepo: _FakeSubjectRepo(),
      checkinRepo: _FakeCheckinRepo(),
      wordRepo: _FakeWordRepo(
        scope: const WordScope(
          studentId: 's1',
          bookId: 'wb',
          bookTitle: '人教版七上',
          unitMode: 'learned',
          dailyCount: 10,
          configured: true,
        ),
        daily: const <WordDailyResult>[
          WordDailyResult(day: '2026-11-12', total: 10, correct: 8, streak: 3),
        ],
      ),
      studentId: 's1',
      now: () => DateTime(2026, 11, 12, 9),
    );

    await c.load();

    expect(c.wordSummary.value, contains('人教版七上'));
    expect(c.wordToday.value, contains('10 题'));
    expect(c.wordToday.value, contains('80%'), reason: '家长每天要看的就是这句');
  });

  test('十科都能调 AI 出教材题（英语 11-13 放开；空科目仍不许）', () {
    final c = SubjectBoardController(
      subjectRepo: _FakeSubjectRepo(),
      checkinRepo: _FakeCheckinRepo(),
      studentId: 's1',
    );
    for (final subject in kSubjectNames) {
      expect(c.canGenerate(subject), isTrue, reason: '$subject 应该能出教材题');
    }
    expect(c.canGenerate('英语'), isTrue,
        reason: '英语现在有教材骨架（语法/时态），色块第二动作会调 generate');
    expect(c.canGenerate(''), isFalse, reason: '空科目不能拿去出题');
  });

  test('证伪：canGenerate 又把英语排除时，十科断言恰好变红', () {
    // 对照旧实现（`subject != '英语'`）：不多不少，只有英语那一条会失败。
    bool oldImplementation(String subject) =>
        subject.isNotEmpty && subject != '英语';
    final failed = kSubjectNames
        .where((subject) => !oldImplementation(subject))
        .toList();
    expect(failed, <String>['英语'],
        reason: '证伪要精确地红：错一条比全红更能定位');
  });

  test('语文/历史按自己那一科出题：subject 报文必须是选中科目', () async {
    final checkinRepo = _FakeCheckinRepo();
    final c = SubjectBoardController(
      subjectRepo: _FakeSubjectRepo(rows: <SubjectScope>[
        scopeOf('历史', count: 3, points: <String>['辛亥革命']),
      ]),
      checkinRepo: checkinRepo,
      studentId: 's1',
    );

    await c.load();
    final ok = await c.generate('历史');

    expect(ok, isTrue);
    expect(checkinRepo.lastGenerate!['subject'], '历史',
        reason: '写成数学会让「历史」色块出的题记到数学名下，记录里查不到');
    expect(checkinRepo.lastGenerate!['knowledgePoints'], <String>['辛亥革命']);
    expect(c.hint.value, contains('历史'));
  });

  // ===== 英语的配置入口（11-12 丢过一次）=====
  //
  // 事故：英语的范围存在 `word_scope`，`subject_scope` 里没有它的行；
  // 「学科范围」只列 `subject_scope` 有的科目 ⇒ 配好词表后英语不出现在配置区，
  // 而英语色块已配置时点击进的是「看记录」⇒ 家长（虫子）当场找不到词表配置。
  // 下面两条一条盯结论、一条盯界面（点得进去才算入口还在）。

  test('英语：词表配好后 scopeOf 必须是「已配置」；没配时不能假装配了', () async {
    final configured = SubjectBoardController(
      subjectRepo: _FakeSubjectRepo(),
      checkinRepo: _FakeCheckinRepo(),
      wordRepo: _FakeWordRepo(
        scope: const WordScope(
          studentId: 's1',
          bookId: 'wb',
          bookTitle: '人教版七上',
          configured: true,
        ),
      ),
      studentId: 's1',
    );
    await configured.load();
    expect(configured.scopeOf('英语').configured, isTrue,
        reason: '不补这一行，「学科范围」里永远没有英语，配置入口就消失了');

    final empty = SubjectBoardController(
      subjectRepo: _FakeSubjectRepo(),
      checkinRepo: _FakeCheckinRepo(),
      wordRepo: _FakeWordRepo(),
      studentId: 's1',
    );
    await empty.load();
    expect(empty.scopeOf('英语').configured, isFalse,
        reason: '没配词表也合成一行的话，家长会以为已经配好了');
  });

  testWidgets('点「学科范围」里的英语行，进的是词表配置页', (tester) async {
    // 家长端计划页默认是云模式；这一页在本地模式整块不渲染。
    DatabaseService.useCloudRuntime(
      CloudRuntime(config: const DataConfig(baseUrl: 'http://127.0.0.1:8788')),
    );
    addTearDown(() {
      DatabaseService.useCloudRuntime(null);
      Get.reset();
    });

    final controller = SubjectBoardController(
      subjectRepo: _FakeSubjectRepo(),
      checkinRepo: _FakeCheckinRepo(),
      wordRepo: _FakeWordRepo(
        scope: const WordScope(
          studentId: 's1',
          bookId: 'wb',
          bookTitle: '人教版七上',
          configured: true,
        ),
      ),
      studentId: 's1',
    );
    Get.put(controller);
    await controller.load();

    await tester.pumpWidget(
      GetMaterialApp(
        home: const Scaffold(body: SubjectBoard()),
        getPages: <GetPage>[
          GetPage(
            name: '/word-scope',
            page: () => const Scaffold(body: Text('WORD_SCOPE_PAGE')),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // 配置区是那张 Card；色块不是 Card，所以这里命中的只可能是「学科范围」行。
    final row = find.descendant(
      of: find.byType(Card),
      matching: find.text('英语'),
    );
    expect(row, findsOneWidget, reason: '配好词表后英语必须出现在学科范围里');

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text('WORD_SCOPE_PAGE'), findsOneWidget,
        reason: '这一行点下去必须是词表配置，不能是别的地方');
  });

  // 「出题待开放」取消后的判据：以前历史/语文色块**不可点**，现在必须能点，
  // 而且点下去发的就是这一科的题。只断 canGenerate 不够 —— 它绿着但
  // `tappable` 还写着旧条件的话，家长点了仍然没反应（这类「判据绿、界面死」
  // 在英语配置入口那次已经栽过一次）。
  testWidgets('已配置的历史色块可点，点下去发的是历史题', (tester) async {
    DatabaseService.useCloudRuntime(
      CloudRuntime(config: const DataConfig(baseUrl: 'http://127.0.0.1:8788')),
    );
    addTearDown(() {
      DatabaseService.useCloudRuntime(null);
      Get.reset();
    });

    final checkinRepo = _FakeCheckinRepo();
    final controller = SubjectBoardController(
      subjectRepo: _FakeSubjectRepo(rows: <SubjectScope>[
        scopeOf('历史', count: 3, points: <String>['辛亥革命']),
      ]),
      checkinRepo: checkinRepo,
      studentId: 's1',
    );
    Get.put(controller);
    await controller.load();

    await tester.pumpWidget(
      GetMaterialApp(
        home: const Scaffold(body: SubjectBoard()),
        getPages: <GetPage>[
          GetPage(name: '/checkin', page: () => const Scaffold(body: Text('CHECKIN_PAGE'))),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // 配置区（Card 内）也写着「历史」，而出题色块在它之后，所以取 last。
    final tile = find.text('历史').last;
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(checkinRepo.lastGenerate, isNotNull,
        reason: '色块写着「出一组 ›」却点不动 = 入口是假的');
    expect(checkinRepo.lastGenerate!['subject'], '历史');
    expect(find.text('CHECKIN_PAGE'), findsOneWidget,
        reason: '出完题要进打卡列表，让家长看见刚出的那份');
  });

  // ===== 「配了但没有范围」不能变成一个点了就报错的按钮（11-12 事故）=====
  //
  // 事故：中国历史配了教材（`book_id` 有值、章节能选），但骨架 MD 里没有
  // 一行「考点：」。服务端把整本书判成「没配考点」→ 退回错题本 → 历史这种
  // 还没学过的科目当然没有错题 → 点一次报一次「错题本还是空的」。
  // 服务端已改成用章节标题兜底；客户端这一层要保证**真没范围时别发请求**，
  // 直接进配置页 —— 一个点了才失败的按钮比没有按钮更糟。

  testWidgets('已配置但没有范围：点色块进配置页，不发请求', (tester) async {
    DatabaseService.useCloudRuntime(
      CloudRuntime(config: const DataConfig(baseUrl: 'http://127.0.0.1:8788')),
    );
    addTearDown(() {
      DatabaseService.useCloudRuntime(null);
      Get.reset();
    });

    final checkinRepo = _FakeCheckinRepo();
    final controller = SubjectBoardController(
      subjectRepo: _FakeSubjectRepo(rows: <SubjectScope>[
        // 配过（configured=true）但 points 空、bookId 空 —— 正是「配了一半」。
        scopeOf('历史', count: 3),
      ]),
      checkinRepo: checkinRepo,
      studentId: 's1',
    );
    Get.put(controller);
    await controller.load();

    await tester.pumpWidget(
      GetMaterialApp(
        home: const Scaffold(body: SubjectBoard()),
        getPages: <GetPage>[
          GetPage(name: '/subject-scope', page: () => const Scaffold(body: Text('SCOPE_PAGE'))),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final tile = find.text('历史').last;
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(checkinRepo.lastGenerate, isNull,
        reason: '发出去只会换回一句「还没有出题范围」，家长会以为是自己点错了');
    expect(find.text('SCOPE_PAGE'), findsOneWidget,
        reason: '要把人送到能配教材的那一页，而不是停在一句报错上');
    expect(controller.hint.value, contains('出题范围'),
        reason: '跳转的原因是「没范围」，得说一句，不然像是点错了');
  });

  // ===== 英语两本资料（11-13）=====
  //
  // 英语现在有两套题：词表题（本地自动出，色块「看记录」）+ 教材题
  // （语法 / 时态，家长点「出一组教材题」调 generate）。两本资料各有配置页：
  // 词表 `/word-scope`，教材 `/subject-scope`（arguments='英语'）。
  // 下面判据盯的是「两个入口都在、各走各的路、摘要互不覆盖」——
  // 11-12 刚丢过一次英语配置入口，这类静默丢失必须被界面级断言挡住。

  testWidgets('英语色块并列两个动作：看记录 + 出一组教材题', (tester) async {
    await _pumpEnglishBoard(
      tester,
      rows: <SubjectScope>[scopeOf('英语', points: <String>['一般现在时'])],
      checkinRepo: _FakeCheckinRepo(),
      pages: <GetPage>[],
    );

    expect(find.text('看记录 ›'), findsOneWidget,
        reason: '词表题的入口不能被教材题挤掉');
    expect(find.text('出一组教材题 ›'), findsOneWidget,
        reason: '第二动作是这次新增的教材题入口，缺了就只剩单词');
  });

  testWidgets('点「出一组教材题」→ generate(英语) 且带英语教材范围', (tester) async {
    final checkinRepo = _FakeCheckinRepo();
    await _pumpEnglishBoard(
      tester,
      rows: <SubjectScope>[
        scopeOf('英语', count: 3, points: <String>['一般现在时', '名词复数']),
      ],
      checkinRepo: checkinRepo,
      pages: <GetPage>[
        GetPage(name: '/checkin', page: () => const Scaffold(body: Text('CHECKIN_PAGE'))),
      ],
    );

    await tester.tap(find.text('出一组教材题 ›'));
    await tester.pumpAndSettle();

    expect(checkinRepo.lastGenerate, isNotNull,
        reason: '按钮写着「出一组」却没发请求 = 入口是假的');
    expect(checkinRepo.lastGenerate!['subject'], '英语',
        reason: '写成别科会让英语教材题记到别科名下');
    expect(checkinRepo.lastGenerate!['knowledgePoints'],
        <String>['一般现在时', '名词复数'],
        reason: '必须用英语教材的范围，不能拿词表或全科错题顶');
    expect(checkinRepo.lastGenerate!['count'], 3);
    expect(find.text('CHECKIN_PAGE'), findsOneWidget);
  });

  testWidgets('英语没配教材范围：点第二动作进教材范围页（不是词表页），不发请求',
      (tester) async {
    final checkinRepo = _FakeCheckinRepo();
    Object? capturedArgs;
    await _pumpEnglishBoard(
      tester,
      // 只配词表：subject_scope 里没有英语行 ⇒ 教材范围为空。
      checkinRepo: checkinRepo,
      pages: <GetPage>[
        GetPage(
          name: '/subject-scope',
          page: () {
            capturedArgs = Get.arguments;
            return const Scaffold(body: Text('SUBJECT_SCOPE_PAGE'));
          },
        ),
        GetPage(name: '/word-scope', page: () => const Scaffold(body: Text('WORD_SCOPE_PAGE'))),
      ],
    );

    await tester.tap(find.text('出一组教材题 ›'));
    await tester.pumpAndSettle();

    expect(checkinRepo.lastGenerate, isNull,
        reason: '没范围还发请求只会换回一句 no_seed，家长会以为点错了');
    expect(find.text('SUBJECT_SCOPE_PAGE'), findsOneWidget,
        reason: '要点的是教材题，就得送进能选英语教材的那一页');
    expect(find.text('WORD_SCOPE_PAGE'), findsNothing,
        reason: '词表页配不出语法范围，跳过去等于把人送错地方');
    expect(capturedArgs, '英语', reason: '配置页必须知道自己配的是英语');
  });

  testWidgets('配置区英语行：两套摘要都在，词表摘要不被教材摘要覆盖', (tester) async {
    await _pumpEnglishBoard(
      tester,
      rows: <SubjectScope>[
        scopeOf('英语', count: 3, points: <String>['一般现在时', '名词复数']),
      ],
      wordScope: const WordScope(
        studentId: 's1',
        bookId: 'wb',
        bookTitle: '人教版七上',
        configured: true,
      ),
      checkinRepo: _FakeCheckinRepo(),
      pages: <GetPage>[],
    );

    final card = find.byType(Card);
    expect(find.descendant(of: card, matching: find.textContaining('人教版七上')),
        findsOneWidget,
        reason: '词表摘要被教材摘要覆盖 ⇒ 家长以为词表没配');
    expect(find.descendant(of: card, matching: find.textContaining('2 个范围')),
        findsOneWidget,
        reason: '教材摘要（2 个范围）也必须看得见');
    expect(find.descendant(of: card, matching: find.text('词表')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('教材')), findsOneWidget);
  });

  testWidgets('配置区英语行点「教材」→ 教材范围页（arguments=英语）', (tester) async {
    Object? capturedArgs;
    await _pumpEnglishBoard(
      tester,
      rows: <SubjectScope>[scopeOf('英语', points: <String>['一般现在时'])],
      checkinRepo: _FakeCheckinRepo(),
      pages: <GetPage>[
        GetPage(
          name: '/subject-scope',
          page: () {
            capturedArgs = Get.arguments;
            return const Scaffold(body: Text('SUBJECT_SCOPE_PAGE'));
          },
        ),
        GetPage(name: '/word-scope', page: () => const Scaffold(body: Text('WORD_SCOPE_PAGE'))),
      ],
    );

    await tester.tap(find.descendant(
      of: find.byType(Card),
      matching: find.text('教材'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('SUBJECT_SCOPE_PAGE'), findsOneWidget);
    expect(find.text('WORD_SCOPE_PAGE'), findsNothing);
    expect(capturedArgs, '英语');
  });

  testWidgets('配置区英语行点「词表」→ 词表配置页（旧行为不回归）', (tester) async {
    await _pumpEnglishBoard(
      tester,
      checkinRepo: _FakeCheckinRepo(),
      pages: <GetPage>[
        GetPage(name: '/word-scope', page: () => const Scaffold(body: Text('WORD_SCOPE_PAGE'))),
        GetPage(name: '/subject-scope', page: () => const Scaffold(body: Text('SUBJECT_SCOPE_PAGE'))),
      ],
    );

    await tester.tap(find.descendant(
      of: find.byType(Card),
      matching: find.text('词表'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('WORD_SCOPE_PAGE'), findsOneWidget);
    expect(find.text('SUBJECT_SCOPE_PAGE'), findsNothing,
        reason: '词表配置不能被教材配置吞掉');
  });

}

/// 英语看板判据的公共泵：云模式 + 可注入的三套假仓库 + 指定路由。
Future<void> _pumpEnglishBoard(
  WidgetTester tester, {
  List<SubjectScope> rows = const <SubjectScope>[],
  WordScope? wordScope,
  required _FakeCheckinRepo checkinRepo,
  required List<GetPage> pages,
}) async {
  DatabaseService.useCloudRuntime(
    CloudRuntime(config: const DataConfig(baseUrl: 'http://127.0.0.1:8788')),
  );
  addTearDown(() {
    DatabaseService.useCloudRuntime(null);
    Get.reset();
  });

  final controller = SubjectBoardController(
    subjectRepo: _FakeSubjectRepo(rows: rows),
    checkinRepo: checkinRepo,
    wordRepo: _FakeWordRepo(
      scope: wordScope ??
          const WordScope(
            studentId: 's1',
            bookId: 'wb',
            bookTitle: '人教版七上',
            configured: true,
          ),
    ),
    studentId: 's1',
  );
  Get.put(controller);
  await controller.load();

  await tester.pumpWidget(
    GetMaterialApp(
      home: const Scaffold(body: SingleChildScrollView(child: SubjectBoard())),
      getPages: pages,
    ),
  );
  await tester.pumpAndSettle();
}

/// 英语色块的数据来自两套真值：词表（范围）+ 今日摘要（做了多少）。
/// 这里只实现判据用到的两条，其余方法给最小实现。
class _FakeWordRepo implements WordRepository {
  _FakeWordRepo({this.scope, this.daily = const <WordDailyResult>[]});

  final WordScope? scope;
  final List<WordDailyResult> daily;

  @override
  Future<WordScope> getScope(String studentId) async =>
      scope ?? WordScope(studentId: studentId);

  @override
  Future<List<WordDailyResult>> listDaily({
    required String studentId,
    String? from,
    String? to,
    int limit = 30,
    int offset = 0,
  }) async =>
      daily;

  @override
  Future<WordBookList> listBooks(String studentId) async =>
      const WordBookList(connected: false);

  @override
  Future<Map<String, dynamic>> importBook({
    required String studentId,
    required String mediaId,
    String? fileName,
    String? title,
    String grade = '',
    String term = '',
  }) async =>
      <String, dynamic>{'imported': false};

  @override
  Future<List<WordEntry>> listEntries({
    required String studentId,
    required String bookId,
  }) async =>
      const <WordEntry>[];

  @override
  Future<WordScope> putScope(WordScope scope) async => scope;

  @override
  Future<void> postDaily({
    required String studentId,
    required String day,
    required int total,
    required int correct,
    required int streak,
    required List<Map<String, dynamic>> wrongWords,
  }) async {}
}
