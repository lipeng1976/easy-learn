import 'dart:io';

import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/pages/parent/tabs/review_parent_tab.dart';
import 'package:easy_learn_app/services/exam_mistake_api.dart';
import 'package:easy_learn_app/widgets/exam_mistake_import_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 试卷错题导入 · 客户端判据。
///
/// 最重要的一条是「没开通 ima 时不报错」：可选能力缺失只许入口隐藏，
/// 不许红条、不许异常、不许拖垮复习页。其余盯的是二次确认与
/// 「导入后列表不刷新」这类安静地不对的表现。
class _FakeRepo implements ExamMistakeRepository {
  _FakeRepo({
    this.connected = true,
    List<ExamMistakeFile>? files,
    this.failImport = false,
    this.failList = false,
  }) : files = files ??
            [
              const ExamMistakeFile(
                mediaId: 'm_exam_1',
                fileName: '七上期中卷.md',
                importedCount: 0,
              ),
            ];

  bool connected;
  List<ExamMistakeFile> files;
  bool failImport;
  bool failList;
  int listCalls = 0;
  int importCalls = 0;
  int revokeCalls = 0;

  @override
  Future<ExamMistakeLibrary> listFiles({required String studentId}) async {
    listCalls += 1;
    if (failList) throw StateError('ima 读不到');
    return ExamMistakeLibrary(
      connected: connected,
      folderPath: '教学资料/试卷错题',
      files: List<ExamMistakeFile>.of(files),
      reason: connected ? '' : 'ima_unavailable',
    );
  }

  @override
  Future<ExamMistakeImportResult> importFile({
    required String studentId,
    required String mediaId,
  }) async {
    importCalls += 1;
    if (failImport) throw StateError('格式不对');
    _setCount(mediaId, 4);
    return const ExamMistakeImportResult(
      imported: 4,
      removed: 0,
      examTitle: '七上期中卷',
    );
  }

  @override
  Future<int> revoke({
    required String studentId,
    required String mediaId,
  }) async {
    revokeCalls += 1;
    _setCount(mediaId, 0);
    return 4;
  }

  void _setCount(String mediaId, int count) {
    files = files
        .map(
          (one) => one.mediaId == mediaId
              ? ExamMistakeFile(
                  mediaId: one.mediaId,
                  fileName: one.fileName,
                  importedCount: count,
                )
              : one,
        )
        .toList();
  }
}

/// 整页判据专用：`ParentController.onInit` 会 `loadData()` 读真 SQLite，
/// 这里刻意不调 super（与 `parent_answer_photos_test.dart` 同一套路）。
class _NoAutoLoadParentController extends ParentController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

Future<void> _pumpEntry(
  WidgetTester tester, {
  required _FakeRepo repo,
  VoidCallback? onChanged,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ExamMistakeImportEntry(
          studentId: 's1',
          repository: repo,
          onChanged: onChanged,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('exam_mistake_import_entry')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('没开通 ima → 入口整块隐藏，不抛异常也不弹红条', (tester) async {
    final repo = _FakeRepo(connected: false);
    await _pumpEntry(tester, repo: repo);

    expect(find.byKey(const Key('exam_mistake_import_entry')), findsNothing);
    expect(find.textContaining('失败'), findsNothing);
    expect(tester.takeException(), isNull);
    expect(repo.listCalls, 1);
  });

  testWidgets('读 ima 失败 → 同样静默隐藏（可选能力不许拖垮页面）', (tester) async {
    final repo = _FakeRepo(failList: true);
    await _pumpEntry(tester, repo: repo);
    expect(find.byKey(const Key('exam_mistake_import_entry')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已连接 → 列出文件与目录说明', (tester) async {
    await _pumpEntry(tester, repo: _FakeRepo());
    expect(find.byKey(const Key('exam_mistake_import_entry')), findsOneWidget);

    await _openSheet(tester);
    // 按钮文案与弹窗标题同名，屏幕上会同时有两个。
    expect(find.text('从 ima 导入试卷错题'), findsNWidgets(2));
    expect(find.textContaining('教学资料/试卷错题'), findsOneWidget);
    expect(find.text('七上期中卷.md'), findsOneWidget);
    expect(find.text('未导入'), findsOneWidget);
    expect(find.text('撤销'), findsNothing, reason: '没导入过的文件不该给撤销按钮');
  });

  testWidgets('导入要二次确认；确认后才调用接口并显示条数', (tester) async {
    final repo = _FakeRepo();
    await _pumpEntry(tester, repo: repo);
    await _openSheet(tester);

    await tester.tap(find.byKey(const Key('exam_import_m_exam_1')));
    await tester.pumpAndSettle();
    expect(find.text('导入这份试卷？'), findsOneWidget);
    expect(repo.importCalls, 0, reason: '没确认就写库是静默副作用');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repo.importCalls, 0);

    await tester.tap(find.byKey(const Key('exam_import_m_exam_1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(repo.importCalls, 1);
    expect(find.textContaining('已导入 4 条错题'), findsOneWidget);
    expect(find.text('已导入 4 条'), findsOneWidget, reason: '导入后必须刷新列表');
    expect(find.text('重新导入'), findsOneWidget);
    expect(find.text('撤销'), findsOneWidget);
  });

  testWidgets('撤销取消不删、确定才删，且删完列表回到「未导入」', (tester) async {
    final repo = _FakeRepo(
      files: const [
        ExamMistakeFile(
          mediaId: 'm_exam_1',
          fileName: '七上期中卷.md',
          importedCount: 4,
        ),
      ],
    );
    await _pumpEntry(tester, repo: repo);
    await _openSheet(tester);

    await tester.tap(find.byKey(const Key('exam_revoke_m_exam_1')));
    await tester.pumpAndSettle();
    expect(find.text('撤销这批错题？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repo.revokeCalls, 0);

    await tester.tap(find.byKey(const Key('exam_revoke_m_exam_1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(repo.revokeCalls, 1);
    expect(find.textContaining('已撤销 4 条错题'), findsOneWidget);
    expect(find.text('未导入'), findsOneWidget);
    expect(find.byKey(const Key('exam_revoke_m_exam_1')), findsNothing);
  });

  testWidgets('导入失败要响亮提示，绝不谎报成功', (tester) async {
    final repo = _FakeRepo(failImport: true);
    await _pumpEntry(tester, repo: repo);
    await _openSheet(tester);
    await tester.tap(find.byKey(const Key('exam_import_m_exam_1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.textContaining('导入没成功'), findsOneWidget);
    expect(find.textContaining('已导入'), findsNothing);
    expect(find.text('未导入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有改动时关闭 → onChanged 触发，家长端错题本会刷新', (tester) async {
    final repo = _FakeRepo();
    var changed = 0;
    await _pumpEntry(tester, repo: repo, onChanged: () => changed += 1);
    await _openSheet(tester);
    await tester.tap(find.byKey(const Key('exam_import_m_exam_1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(changed, 1);
  });

  testWidgets('没改动时关闭 → 不刷新，也不报错', (tester) async {
    final repo = _FakeRepo();
    var changed = 0;
    await _pumpEntry(tester, repo: repo, onChanged: () => changed += 1);
    await _openSheet(tester);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(changed, 0);
    expect(tester.takeException(), isNull);
  });

  // ── 11-15 真机反馈：入口挂在 ListView 最底部，家长在首屏根本注意不到 ──
  // 这两条盯的是「位置」，不是「有没有这个功能」。只查 connected 的判据
  // 在这件事上会一直绿，因为按钮确实存在，只是被压在四块内容下面。
  test('入口排在首屏：在进度卡 / 复习资料 / 作业提交记录之前', () {
    final source = File(
      'lib/pages/parent/tabs/review_parent_tab.dart',
    ).readAsStringSync();
    final entry = RegExp(
      r'^[ \t]*ExamMistakeImportEntry\(',
      multiLine: true,
    ).firstMatch(source);
    expect(entry, isNotNull, reason: '页面上必须真的挂着导入入口');

    final at = entry!.start;
    for (final anchor in <String>[
      '_ProgressCard(',
      "title: '复习资料'",
      "title: '作业提交记录'",
      // 11-15 重排后「错题清单」被学科色块取代，锚点跟着换成新的
      // ③ 区标题。锚点不换的话这条会因为「找不到旧字符串」假红，
      // 而入口位置其实没动。
      "title: '按学科看错题'",
    ]) {
      final anchorAt = source.indexOf(anchor);
      expect(anchorAt, greaterThan(-1), reason: '$anchor 得还在页面上');
      expect(
        at,
        lessThan(anchorAt),
        reason: '入口掉到 $anchor 后面 ⇒ 又要滚到页面底部才看得到',
      );
    }
  });

  testWidgets('默认视口就能看到入口，且坐标在页面上方', (tester) async {
    // 刻意不放大视口：800×600 是手机首屏的量级，底部懒构建的 widget
    // 压根不会进树。还原成旧位置时这条会红，而不是「看着通过」。
    final ParentController controller = _NoAutoLoadParentController();
    controller.selectedStudentId.value = 's1';
    Get.put<ParentController>(controller);
    addTearDown(() => Get.reset());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReviewParentTab(examMistakeRepository: _FakeRepo()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final entry = find.byKey(const Key('exam_mistake_import_entry'));
    expect(entry, findsOneWidget, reason: '不放大视口也必须能在树上找到入口');
    final entryY = tester.getCenter(entry).dy;
    expect(entryY, lessThan(200), reason: '入口要紧贴标题，不能落在首屏之外');

    final reviewHeader = find.text('复习资料');
    expect(reviewHeader, findsOneWidget);
    expect(
      tester.getCenter(reviewHeader).dy,
      greaterThan(entryY),
      reason: '复习资料在入口下方，证明入口没被挪回底部',
    );
    expect(tester.takeException(), isNull);
  });
}
