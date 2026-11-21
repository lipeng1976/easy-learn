import 'package:easy_learn_app/controllers/review_controller.dart';
import 'package:easy_learn_app/pages/student/widgets/review_export_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 导出面板：**三个去向都得在，而且要各说各的**。
///
/// 这里刻意不 pump 整个资料页 —— 那要拉起数据库、控制器和一串页面依赖，
/// 而这条断言真正想锁住的只是「面板有没有把三条路摆出来」。
/// 分工是：`exportPaper` 的分支行为归闭环测试，这里只管 UI 摆了什么。
///
/// 为什么要专门锁「三条都在」：这正是这次改动的原因。以前只有「打印」一个
/// 出口，家里没打印机的学生走到这一步就断了；少一条就等于那个学生又断了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  Future<void> openSheet(WidgetTester tester) async {
    // 无参构造：不注入替身，因为这里不点任何选项 —— 点了才会用到导出端口。
    final controller = ReviewController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => openReviewExportSheet(
                  context: context,
                  controller: controller,
                  paperId: 'rp_ui',
                ),
                child: const Text('打开导出面板'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开导出面板'));
    await tester.pumpAndSettle();
  }

  testWidgets('三条去向都在：打印、保存 PDF、转发', (tester) async {
    await openSheet(tester);

    expect(find.text('打印 / 另存 PDF'), findsOneWidget);
    // 「下载文件」改名成「保存 PDF 文件」：2026-10-21 起交出去的是 PDF，
    // 而「下载」在手机上容易被理解成浏览器那种下载。
    expect(find.text('保存 PDF 文件'), findsOneWidget);
    expect(find.text('转发到微信'), findsOneWidget);
  });

  testWidgets('答案开关默认打开，并说明关掉是给谁用的', (tester) async {
    await openSheet(tester);

    expect(find.text('附带参考答案'), findsOneWidget);
    expect(
      find.textContaining('先独立完成'),
      findsOneWidget,
      reason: '开关得有明确的用途说明，否则没人知道什么时候该关',
    );
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('答案开关可以关掉', (tester) async {
    await openSheet(tester);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.text('附带参考答案'), findsOneWidget);
  });
}
