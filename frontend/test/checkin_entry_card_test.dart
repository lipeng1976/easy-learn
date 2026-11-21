import 'package:easy_learn_app/constants/app_colors.dart';
import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/checkin_entry_state.dart';
import 'package:easy_learn_app/models/checkin_models.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/repositories/checkin_repository.dart';
import 'package:easy_learn_app/services/cloud_runtime.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/widgets/checkin_entry_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 每日概念打卡**入口卡**的判据。
///
/// 这一轮把它从「个人信息页」搬到了「计划标签页」，所以判据盯几件事：
///   ① 本地库模式**整张卡不渲染**（题目必须存服务端，本地点了只会报错）；
///   ② 家长 / 学生文案分开（家长是「设置今天的题」，学生是一键出题）；
///   ③ 点一下**真能**进打卡页 —— 只断言按钮存在抓不住跳转崩掉那种 bug
///      （`Get.toNamed<T>` 的例子见 `test/checkin_page_test.dart`）；
///   ④ 两态两色：**没做完浅绿**（今天还有一件事，要醒目）、做完归白灰
///      （提醒该退场了）。状态只看 `submittedResult`，与打卡页的完成口径一致。
///
/// ⚠️ 状态必须预注入 [CheckinEntryState]：不注入的话卡会用
/// `DatabaseService.checkin`（这里是 HTTP 实现）真去连 127.0.0.1:8788 ——
/// 连不上是运气好（立刻失败被吞），赶上连接慢就是 pending timer。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 只要 `isCloud` 为真，不真的发请求：云运行时构造本身不发网络请求。
  void useFakeCloud() {
    DatabaseService.useCloudRuntime(
      CloudRuntime(config: const DataConfig(baseUrl: 'http://127.0.0.1:8788')),
    );
  }

  tearDown(() {
    DatabaseService.useCloudRuntime(null);
    Get.reset();
  });

  Widget host({bool isParent = true}) => GetMaterialApp(
        initialRoute: '/entry',
        getPages: [
          GetPage(
            name: '/entry',
            page: () => Scaffold(body: CheckinEntryCard(isParent: isParent)),
          ),
          GetPage(
            name: '/checkin',
            page: () => const Scaffold(body: Text('CHECKIN_PAGE')),
          ),
        ],
      );

  testWidgets('本地模式：入口卡不渲染', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('概念打卡'), findsNothing);
    expect(find.text('出新的打卡题'), findsNothing);
  });

  testWidgets('云模式：家长点「设置今天的题」进打卡页', (tester) async {
    useFakeCloud();
    Get.put(CheckinEntryState(repository: _FakeEntryRepo()));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('概念打卡'), findsOneWidget);
    await tester.tap(find.text('出新的打卡题'));
    await tester.pumpAndSettle();

    expect(find.text('CHECKIN_PAGE'), findsOneWidget);
  });

  testWidgets('云模式：学生看到的是「去做今天的打卡」，不是家长那句', (tester) async {
    useFakeCloud();
    Get.put(CheckinEntryState(repository: _FakeEntryRepo()));
    await tester.pumpWidget(host(isParent: false));
    await tester.pumpAndSettle();

    expect(find.text('每日概念打卡'), findsOneWidget);
    expect(find.text('去做打卡'), findsOneWidget);
    expect(find.text('出新的打卡题'), findsNothing);
  });

  testWidgets('一份题都没有：「还没有题」灰标 + 白卡，不催人', (tester) async {
    useFakeCloud();
    registerStudent();
    Get.put(CheckinEntryState(repository: _FakeEntryRepo()));

    await tester.pumpWidget(host(isParent: false));
    await tester.pumpAndSettle();

    // 2026-10-29 改：原来是「今天没题也亮绿标待完成」，家长会以为系统在催他，
    // 而其实他自己还没出过题（孩子端则是「家长还没出题」）。
    expect(find.text('还没有题'), findsOneWidget);
    expect(find.text('待完成 1 份'), findsNothing);
    final card = tester.widget<Card>(find.byType(Card));
    expect(card.color, AppColors.card, reason: '一份都没有时不该用绿色催');
  });

  testWidgets('做了一部分（两份完成一份）：仍是浅绿，但标上进度', (tester) async {
    useFakeCloud();
    registerStudent();
    // 一天多份：家长出了数学、英语两份，孩子只交了数学。
    Get.put(CheckinEntryState(repository: _FakeEntryRepo(doneToday: true, total: 2)));

    await tester.pumpWidget(host(isParent: false));
    await tester.pumpAndSettle();

    expect(find.text('待完成 1 份'), findsOneWidget, reason: '要写清还有几份没做，别只说「待完成」');
    expect(find.text('已全部完成'), findsNothing);
    final card = tester.widget<Card>(find.byType(Card));
    expect(
      card.color,
      Color.alphaBlend(AppColors.success.withValues(alpha: 0.14), AppColors.card),
      reason: '没全部做完就得继续用绿色催',
    );
  });

  testWidgets('今天做完了：白卡 + 「已完成」标，不再用绿色催', (tester) async {
    useFakeCloud();
    registerStudent();
    Get.put(CheckinEntryState(repository: _FakeEntryRepo(doneToday: true)));

    await tester.pumpWidget(host(isParent: false));
    await tester.pumpAndSettle();

    expect(find.text('已全部完成'), findsOneWidget);
    expect(find.text('还没有题'), findsNothing);
    expect(find.text('看看做过的'), findsOneWidget,
        reason: '做完之后按钮要指向历史，不能再叫「去做打卡」');
    final card = tester.widget<Card>(find.byType(Card));
    expect(card.color, AppColors.card, reason: '做完之后不该还是浅绿');
  });
}

void registerStudent() {
  Get.put(AuthController()).currentUser.value = UserModel(
    id: 'stu_001',
    name: '林小宇',
    phone: '13800000001',
    role: 'student',
    avatar: '🧒',
  );
}

class _FakeEntryRepo implements CheckinRepository {
  _FakeEntryRepo({this.doneToday = false, this.total = 1});

  final bool doneToday;

  /// 今天的打卡总份数（多科目）。doneToday = true 时前 `total - 1` 份是
  /// 已交卷、最后一份是未交卷 —— 用来造「做了一部分」的中间态。
  final int total;

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
  }) async {
    if (studentId != 'stu_001') return CheckinQuizPage.empty;
    if (!doneToday) return CheckinQuizPage.empty;
    final all = [
      for (var i = 0; i < total; i++)
        CheckinQuiz(
          id: 'quiz_00$i',
          studentId: studentId!,
          // 入口卡不显示日期，给个固定值即可（原来这里是查询参数，
          // 2026-10-29 起列表不再按天取，参数没了）。
          quizDate: '2026-10-29',
          subject: i.isEven ? '数学' : '英语',
          // total == 1 时这一份就是「全都做完了」；total > 1 时只有最后一份
          // 留作 pending（造「做了一部分」的中间态）。
          status: (i < total - 1 || total == 1) ? 'done' : 'pending',
          submittedResult: (i < total - 1 || total == 1)
              ? const CheckinSubmitResult(
                  quizId: 'quiz_000',
                  score: 2,
                  total: 2,
                  items: [],
                )
              : null,
          questions: const [],
        ),
    ];
    // 入口卡的两个数分别来自两次查询（pending / all），所以这里必须按
    // status 过滤；不实现过滤的话，「还有几份没做」会被算成总份数，
    // 而断言照样可能绿。
    final items = status == CheckinQuizStatus.pending
        ? all.where((q) => q.submittedResult == null).toList()
        : status == CheckinQuizStatus.done
            ? all.where((q) => q.submittedResult != null).toList()
            : all;
    return CheckinQuizPage(items: items, total: items.length, hasMore: false);
  }

  @override
  Future<List<CheckinSeed>> loadSeeds({String? studentId, String? subject}) async => const [];

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
