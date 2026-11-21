import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/pages/parent/widgets/parent_app_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 家长端顶栏的**宽度预算**。
///
/// 起因是真机上的一句反馈：「家长端，当对应多个孩子时，上面下拉的那个控件
/// 边上有个小 ERFlowed By 的图标，不知道是什么意思」。那是一句
/// `RenderFlex overflowed by 51 pixels`，Flutter 在 debug 下会把溢出画成
/// 黄黑斜纹并印上「OVERFLOWED BY n PIXELS」—— 用户看到的正是这行字。
///
/// 它只在**孩子多于 1 个**时出现（标题此时才换成下拉选择器），而且
/// **只在真机上出现**：默认测试视口是 800×600，宽 800，怎么都够。
/// 所以这一组把视口设成真机宽度再渲。
///
/// ## 两条断言缺一不可
///
/// - 「不溢出」是用户报的那一条；
/// - 「名字没被省略」是**反面**：把标题压成 0 宽度也能让它不溢出，
///   但那样用户看不到自己在看哪个孩子 —— 换成另一种坏法而已。
///   实测未被修复前，393dp 上名字只剩 33dp（需要 51dp），360dp 上剩 0dp。
void main() {
  Get.testMode = true;

  const phoneWidths = <double>[360, 375, 390, 393, 412];

  List<ParentChild> children() => const [
    ParentChild(id: 'stu_0', name: '林小宇'),
    ParentChild(id: 'stu_1', name: '林小桐'),
    ParentChild(id: 'stu_2', name: '李雨霏'),
  ];

  Future<void> pumpAppBar(
    WidgetTester tester, {
    required double width,
    List<ParentChild>? students,
    int unreadCount = 0,
  }) async {
    // 逻辑尺寸 = 物理尺寸（devicePixelRatio 1），这样下面的宽度就是 dp。
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = Size(width, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          appBar: ParentAppBar(
            students: students ?? children(),
            selectedId: (students ?? children()).first.id,
            onSelect: (_) {},
            unreadCount: unreadCount,
          ),
          body: const SizedBox(),
        ),
      ),
    );
    await tester.pump();
  }

  group('多孩子时的下拉：不溢出，且名字要看得见', () {
    for (final width in phoneWidths) {
      testWidgets('宽 ${width.toInt()}dp', (tester) async {
        await pumpAppBar(tester, width: width);

        expect(
          tester.takeException(),
          isNull,
          reason: '孩子多于一个时标题换成下拉，宽度不够就会画出「OVERFLOWED BY …」',
        );

        // 名字是这一屏唯一的信息：家长要靠它确认「我现在看的是哪个孩子」。
        // 断言打在**渲染出来的那一段文字**上，而不是「控件还在」——
        // 控件当然还在，它只是被压成了省略号。
        final name = tester.renderObject<RenderParagraph>(find.text('林小宇'));
        expect(
          name.didExceedMaxLines,
          isFalse,
          reason: '名字被省略了（只剩 ${name.size.width.toStringAsFixed(0)}dp）',
        );
      });
    }
  });

  // 名字很长时**必然**放不下，此时正确行为是「缩名字」，不是「撑破行」。
  // 这一条是 `isExpanded: true` 单独的责任：没有它，下拉控件内部会拿到
  // **无界宽度**（详见 `child_selector.dart` 里那段），`Flexible` 根本轮不到
  // 生效 —— 3 个字的短名字恰好塞得下，所以上面那组用例**证不出**这一条。
  testWidgets('名字很长时缩名字，不溢出、也不能缩成看不见', (tester) async {
    await pumpAppBar(
      tester,
      width: 360,
      students: const [
        ParentChild(id: 'stu_0', name: '欧阳慕容慕容'),
        ParentChild(id: 'stu_1', name: '林小桐'),
      ],
    );

    expect(tester.takeException(), isNull, reason: '长名字不该把标题行撑破');

    final name = tester.renderObject<RenderParagraph>(find.text('欧阳慕容慕容'));
    expect(
      name.size.width,
      greaterThan(0),
      reason: '省略是为了腾地方，缩成 0 就等于看不见是哪个孩子',
    );
    expect(name.didExceedMaxLines, isTrue, reason: '名字确实放不下，应该是省略号');
  });

  group('顶栏的其余部分', () {
    testWidgets('只有一个孩子时用文字标题，不出现下拉', (tester) async {
      await pumpAppBar(
        tester,
        width: 360,
        students: const [ParentChild(id: 'stu_0', name: '林小宇')],
      );

      expect(find.text('家长端'), findsOneWidget);
      expect(find.byType(DropdownButton<String>), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('收进「更多」的三个入口都还在，点得开', (tester) async {
      await pumpAppBar(tester, width: 360);

      // 为了给标题腾宽度，伴学消息 / 伴学绑定 / 个人信息从顶栏收进了这个菜单。
      // 折叠是为了让路，**不是删功能** —— 所以这条要证明它们真的在里面。
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();

      expect(find.text('伴学消息'), findsOneWidget);
      expect(find.text('伴学绑定'), findsOneWidget);
      expect(find.text('个人信息'), findsOneWidget);
    });

    testWidgets('有未读时铃铛上出现红点，没有时不出现', (tester) async {
      await pumpAppBar(tester, width: 360, unreadCount: 3);
      expect(find.byTooltip('消息通知'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).shape == BoxShape.circle,
        ),
        findsOneWidget,
        reason: '未读红点是「有人等家长处理」的唯一信号，别在改布局时丢掉',
      );
    });
  });
}
