import 'package:easy_learn_app/models/checkin_models.dart';
import 'package:easy_learn_app/pages/parent/checkin_setup_page.dart';
import 'package:easy_learn_app/repositories/checkin_repository.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 家长设置打卡范围的判据。
///
/// 这一页的产物只有一个：[CheckinSetup]。所以测的是「用户点完之后，
/// 交回去的那份范围对不对」，而不是「界面长得对不对」。
///
/// 重点盯三条：
///   1. 勾选顺序要保留（顺序就是「先考哪个」的优先级）；
///   2. 最多 6 个（与服务端 `MAX_SEED_POINTS`、网关 `MAX_CHECKIN_ITEMS` 同步，
///      界面先拦，别让用户选完了再被服务端 400）；
///   3. 候选取不到时**不阻断**：家长仍能手输知识点出题。
class _FakeRepo implements CheckinRepository {
  _FakeRepo({this.seeds = const [], this.error});

  List<CheckinSeed> seeds;
  Object? error;
  int calls = 0;

  /// 最近一次请求带上来的科目。切学科后必须变 —— 断「界面切了、请求没切」
  /// 这一类静默失败（候选还是旧科的，勾上就串了）。
  String? lastSubject;

  @override
  Future<List<CheckinSeed>> loadSeeds({String? studentId, String? subject}) async {
    calls += 1;
    lastSubject = subject;
    final failure = error;
    if (failure != null) throw failure;
    return seeds;
  }

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
  }) =>
      throw UnimplementedError();

  @override
  Future<CheckinQuiz> generate({
    String? studentId,
    required String quizDate,
    String subject = '数学',
    int count = 5,
    List<String> knowledgePoints = const [],
    String difficulty = '',
  }) =>
      throw UnimplementedError();

  @override
  Future<CheckinSubmitResult> submit({
    required String quizId,
    required Map<int, String> picked,
  }) =>
      throw UnimplementedError();
}

/// 打开设置页的脚手架：`result` 在页面关闭后由 `await push` 写入。
class _Harness {
  CheckinSetup? result;
}

Future<_Harness> _open(WidgetTester tester, _FakeRepo repo) async {
  final harness = _Harness();

  await tester.pumpWidget(
    GetMaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                harness.result = await Navigator.of(context).push<CheckinSetup>(
                  MaterialPageRoute(
                    builder: (_) => CheckinSetupPage(
                      studentId: 'stu_1',
                      repository: repo,
                    ),
                  ),
                );
              },
              child: const Text('打开设置'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('打开设置'));
  await tester.pumpAndSettle();
  return harness;
}

/// 按文字点一个控件（按钮、chip）。
///
/// ⚠️ 页面是 ListView（懒构建）：视口外的 chip / 底部按钮**还没被创建**，
/// 这时 `ensureVisible` 会直接抛 `Bad state: No element` —— 报错看起来像
/// 「控件不存在」，其实只是没滚到。先滚再 ensureVisible，两条都要。
///
/// `scrollUntilVisible` 只会朝一个方向找（delta 为正 = 往下）。前一步操作
/// 可能已经把页面滚到底部，而这次要点的 chip 在**上面** —— 那种情况它会
/// 一直往下找不到、最后抛错。所以补一次「滚回顶部再找」。
Future<void> _tapText(WidgetTester tester, String label) async {
  final target = find.text(label);
  if (target.evaluate().isEmpty) {
    final scrollable = find.byType(Scrollable).first;
    try {
      await tester.scrollUntilVisible(target, 240, scrollable: scrollable);
    } catch (_) {
      await tester.drag(scrollable, const Offset(0, 2000));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(target, 240, scrollable: scrollable);
    }
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// 勾选候选列表里的一行。
///
/// ⚠️ 不能用 `find.text(label)`：勾上之后顶部会出现同名的已选 chip，
/// 同一个字符串在页面上出现两次，tap 会直接抛「Too many elements」。
/// 按 CheckboxListTile 定位才能唯一命中列表项。
Future<void> _tapSeed(WidgetTester tester, String label) async {
  final tile = find.widgetWithText(CheckboxListTile, label);
  await tester.ensureVisible(tile);
  await tester.pumpAndSettle();
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('候选显示错题次数；勾选的顺序被原样保留', (tester) async {
    final repo = _FakeRepo(
      seeds: const [
        CheckinSeed(knowledge: '幂的运算', wrongCount: 3),
        CheckinSeed(knowledge: '图形想象', wrongCount: 1),
      ],
    );
    final harness = await _open(tester, repo);

    expect(find.text('错过 3 次'), findsOneWidget);

    // 勾选顺序**故意与字典序相反**：「幂」(U+5E42) 排在「图」(U+56FE) 之后。
    // 如果实现里用了 Set 或提交前 sort，交回去的顺序就会翻过来 ——
    // 而翻过来意味着「先考哪个」被悄悄改掉了。
    await _tapSeed(tester, '幂的运算');
    await _tapSeed(tester, '图形想象');

    await _tapText(tester, '出题');

    expect(harness.result, isNotNull, reason: '点出题后必须把范围交回去');
    expect(harness.result!.knowledgePoints, ['幂的运算', '图形想象']);
    expect(harness.result!.subject, '数学', reason: '没改学科时就是默认的数学');
    expect(harness.result!.count, 5);
    expect(harness.result!.difficulty, '基础');
  });

  testWidgets('最多选 6 个：第 7 个选不上，并且明确告诉用户', (tester) async {
    final repo = _FakeRepo(
      seeds: [
        for (var i = 1; i <= 7; i++) CheckinSeed(knowledge: '知识点$i', wrongCount: i),
      ],
    );
    final harness = await _open(tester, repo);

    for (var i = 1; i <= 6; i++) {
      await _tapSeed(tester, '知识点$i');
    }
    await _tapSeed(tester, '知识点7');

    // 提示必须出现 —— 静默忽略会让用户以为第 7 个也选上了。
    expect(find.textContaining('最多选 6 个'), findsOneWidget);

    await _tapText(tester, '出题');
    expect(harness.result!.knowledgePoints.length, 6);
    expect(harness.result!.knowledgePoints, isNot(contains('知识点7')));
  });

  testWidgets('候选取不到时仍能出题（手输知识点是兜底）', (tester) async {
    final repo = _FakeRepo(
      error: const DataApiException(code: 'network', message: '连不上', retryable: true),
    );
    final harness = await _open(tester, repo);

    // 错误要说出来，而不是伪装成「你还没有错题」
    // （`network` 走 userMessage 的统一文案，所以这里匹配「网络」而不是原文）
    expect(find.textContaining('网络'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '负数乘方');
    await _tapText(tester, '添加');
    await _tapText(tester, '出题');

    expect(harness.result!.knowledgePoints, ['负数乘方']);
  });

  testWidgets('改难度与题量会进到最终范围里', (tester) async {
    final repo = _FakeRepo(seeds: const [CheckinSeed(knowledge: '幂的运算', wrongCount: 2)]);
    final harness = await _open(tester, repo);

    await _tapText(tester, '提高');
    await _tapText(tester, '3 题');
    await _tapText(tester, '出题');

    expect(harness.result!.difficulty, '提高');
    expect(harness.result!.count, 3);
  });

  // 全科开放出题后，这一页才真的会被拿来出语文/历史题。
  // 切科学科但候选不跟着切，家长勾的就会是别的科的知识点，
  // 而界面上两批候选长得一模一样。
  testWidgets('切学科：候选按该科重新加载，已勾的旧科知识点被清掉', (tester) async {
    final repo = _FakeRepo(seeds: const [CheckinSeed(knowledge: '幂的运算', wrongCount: 2)]);
    final harness = await _open(tester, repo);

    expect(repo.lastSubject, '数学', reason: '默认学科的候选也要按科取');

    await _tapSeed(tester, '幂的运算');
    await _tapText(tester, '语文');

    expect(repo.lastSubject, '语文', reason: '切了学科，候选必须跟着换');
    expect(repo.calls, 2, reason: '不重新拉就只能显示旧科的候选');

    await _tapText(tester, '出题');
    expect(harness.result!.subject, '语文');
    expect(harness.result!.knowledgePoints, isEmpty,
        reason: '数学的知识点不能当语文范围交上去');
  });
}
