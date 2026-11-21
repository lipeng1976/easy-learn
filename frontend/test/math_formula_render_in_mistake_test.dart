import 'package:easy_learn_app/controllers/review_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/pages/student/mistake_detail_page.dart';
import 'package:easy_learn_app/services/simulated_ai_data_source.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 真机反馈：「大模型分析的结果还是不支持数学公式展示」。
///
/// ── 根因 ────────────────────────────────────────────────────────────────
///
/// 错题详情页里，**题目和讲解都用了 `MathText`**，唯独
/// 「当时的答案」和「错因」这两行还是纯 `Text` —— 于是模型写的
/// `$2x$`、`$20 \times 2+(x-20) \times 2.6=…$` 原样显示成美元符号加反斜杠。
///
/// 这两行恰恰是错题卡上最常被看的两句，而且它们几乎全是算式。
///
/// ⚠️ 这个缺陷的形状很典型：**同一页里一部分用了正确组件、另一部分没有**。
/// 只看截图的人会以为是「模型没写公式」，去看渲染器的人会把 `MathText`
/// 查一遍然后说「没问题」—— 因为出问题的那两行压根没走它。
///
/// ## 判据为什么必须是「原文找不到 + 出现 Math 块」
///
/// 只断言「有 Math 块」是不够的：页面上原来的题目也可能带公式，
/// 那样即使答案那两行仍是纯文本，`Math` 一样存在，测试恒绿。
/// 所以同时断言 **`$2x$` 这段原文在界面上消失**。
void main() {
  setUp(() {
    Get.testMode = true;
  });

  tearDown(Get.reset);

  ReviewMistake mistakeWithFormulas() => ReviewMistake(
    id: 'm_formula',
    subject: '数学',
    title: r'列代数式（分段计费）',
    // 与真机上那条同形：分号分隔两个空，各用 `$...$` 包着。
    originalAnswer: r'$2x$;$106.6-2.6x$',
    wrongReason:
        r'第二空列式错误：当 $x>20$ 时，水费应为 $20 \times 2+(x-20) \times 2.6=2.6x - 12$。'
        r'学生填写的 $106.6-2.6x$ 常数项和符号都不对。',
    createdAt: DateTime(2026, 10, 20, 9),
    state: ReviewState.pending,
    studentId: 'stu_001',
    knowledgePoint: '列代数式',
  );

  Future<void> pumpDetail(
    WidgetTester tester,
    ReviewMistake mistake, {
    // 头部默认是收起的（题干两行、其余要点开看）。这组用例要断的是
    // 「答案/错因里的公式有没有被渲染」，所以先把摘要展开 ——
    // 否则断到的是收起态，与公式渲染无关。
    bool expandHeader = true,
  }) async {
    // 只用内存里这一条错题：不建真库、不加载整页数据。
    // `explainMistake` 走 [SimulatedAiDataSource]（纯本地），不发网络。
    final student = StudentController(ai: const SimulatedAiDataSource());
    student.mistakes.assignAll([mistake]);

    final controller = ReviewController(
      student: student,
      ai: const SimulatedAiDataSource(),
    );
    // ⚠️ 注册 key 必须是父类类型 —— 写成推断出的子类会让页面 `find` 不到。
    Get.put<ReviewController>(controller);

    await tester.pumpWidget(
      GetMaterialApp(home: MistakeDetailPage(mistakeId: mistake.id)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    if (expandHeader) {
      final expand = find.text('展开');
      expect(expand, findsOneWidget, reason: '头部没有「展开」入口');
      await tester.tap(expand);
      await tester.pump();
    }
  }

  testWidgets('「当时的答案」与「错因」里的公式被渲染，不再是 LaTeX 原文', (tester) async {
    await pumpDetail(tester, mistakeWithFormulas());

    // ① 原文必须消失 —— 这是这条判据的核心。
    expect(
      find.textContaining(r'$2x$'),
      findsNothing,
      reason: r'界面上还能看到 `$2x$` 原文：这两行没走 MathText',
    );
    expect(
      find.textContaining(r'\times'),
      findsNothing,
      reason: '`\\times` 原样露出来了，说明公式没被解析',
    );

    // ② 且确实渲染成了公式块。
    expect(
      find.byType(Math),
      findsWidgets,
      reason: '一个公式块都没有 —— 这两行退回了纯文本',
    );

    // ③ 标签还在（不是整段被吞掉）。
    expect(find.textContaining('当时的答案'), findsOneWidget);
    expect(find.textContaining('错因'), findsOneWidget);
  });

  testWidgets('头部默认收起：先看到题目，整段错因要点开才出现', (tester) async {
    // 这条盯的是「内容区被头部吃掉」这个实际反馈：头部曾经把题干全文、
    // 照片、当时的答案、当时的过程、错因全铺在固定区里（不参与滚动），
    // 一道应用题就能占掉大半屏，下面 Tab 里的内容只剩一条缝。
    await pumpDetail(tester, mistakeWithFormulas(), expandHeader: false);

    expect(find.text('展开'), findsOneWidget, reason: '收起态没有展开入口');
    expect(
      find.textContaining('错因：'),
      findsNothing,
      reason: '收起态就把整段错因铺出来了 —— 内容区又被它吃掉',
    );
  });

  testWidgets('点「展开」后能看到全文与错因', (tester) async {
    await pumpDetail(tester, mistakeWithFormulas());

    expect(find.textContaining('错因：'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);
  });

  testWidgets('没有公式的错题照常显示（保证上一条不是恒绿）', (tester) async {
    final plain = mistakeWithFormulas().copyWith(
      originalAnswer: '75',
      wrongReason: '忘了进位',
    );
    await pumpDetail(tester, plain);

    // 只断**这两行专属**的文本：`75` 这类短数字在页面上别处也会出现
    // （分数、日期），拿它当判据会得到「找到 2 个」这种与机制无关的红。
    expect(find.textContaining('当时的答案：75'), findsOneWidget);
    expect(find.textContaining('错因：忘了进位'), findsOneWidget);
  });
}
