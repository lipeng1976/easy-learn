import 'package:easy_learn_app/models/mistake_figure.dart';
import 'package:easy_learn_app/models/practice_figure.dart';
import 'package:easy_learn_app/pages/student/widgets/explain_figure_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 讲解页「理解图」卡片的四种状态。
///
/// ## 为什么这四种都要单独测
///
/// 它们里有三种在界面上都是「**没有图**」：
/// 还没点过（按钮）、这题不用画（一句话）、这次没画成（一句话 + 重试）。
/// 摆错一个的症状都一样 —— **学生觉得按钮点空了**，而这是这套 App 里
/// 最高频的一类 bug（点了没反应、转圈停不下来）。
///
/// 而第四种（真画出来了）如果漏测，最常见的坏法是「图到了但卡片还停在转圈上」，
/// 因为状态更新没被 `Obx` 追踪到。那条路径只能靠 controller 的 Rx 保证，
/// 这里测的是**卡片拿到数据后会不会真的把图画出来**。
void main() {
  PracticeFigure figure() {
    final parsed = PracticeFigure.parse({
      'type': 'plane',
      'points': [
        {'name': 'A', 'x': 0, 'y': 0},
        {'name': 'B', 'x': 3, 'y': 0},
      ],
      'segments': [
        ['A', 'B'],
      ],
    });
    expect(parsed, isNotNull, reason: '夹具不合法，后面的断言没有意义');
    return parsed!;
  }

  Future<void> pump(WidgetTester tester, Widget card) {
    return tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: card))),
    );
  }

  testWidgets('还没点过：显示「画一张理解图」，点了会回调', (tester) async {
    var taps = 0;
    await pump(
      tester,
      ExplainFigureCard(
        figure: null,
        failure: null,
        loading: false,
        onGenerate: () => taps += 1,
      ),
    );

    expect(find.text('画一张理解图'), findsOneWidget);
    await tester.tap(find.text('画一张理解图'));
    expect(taps, 1);
  });

  testWidgets('正在画：转圈 + 明确文案，不显示按钮（免得连点）', (tester) async {
    await pump(
      tester,
      const ExplainFigureCard(
        figure: null,
        failure: null,
        loading: true,
        onGenerate: _noop,
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('正在画…'), findsOneWidget);
    expect(find.text('画一张理解图'), findsNothing);
  });

  testWidgets('这题不用画：给一句话，不留按钮（这是结论，不是失败）', (tester) async {
    await pump(
      tester,
      ExplainFigureCard(
        figure: const MistakeFigure(reason: '这是纯幂的运算，画图帮不上忙。'),
        failure: null,
        loading: false,
        onGenerate: _noop,
      ),
    );

    expect(find.text('这道题不画图'), findsOneWidget);
    expect(find.text('这是纯幂的运算，画图帮不上忙。'), findsOneWidget);
    // 结论不该给重试入口：再点一百次也是同一句话，白等十几秒。
    expect(find.text('再试一次'), findsNothing);
  });

  testWidgets('这次没画成：给重试按钮，点了会重新请求', (tester) async {
    var retries = 0;
    await pump(
      tester,
      ExplainFigureCard(
        figure: null,
        failure: '这次没画成，检查网络后再点一次',
        loading: false,
        onGenerate: () => retries += 1,
      ),
    );

    expect(find.text('这次没画成，检查网络后再点一次'), findsOneWidget);
    await tester.tap(find.text('再试一次'));
    expect(retries, 1);
  });

  testWidgets('画出来了：图真的被渲染，caption 与 reason 都在', (tester) async {
    await pump(
      tester,
      ExplainFigureCard(
        figure: MistakeFigure(
          figure: figure(),
          reason: '左右两个位置都要画出来。',
          caption: '看这两个点',
        ),
        failure: null,
        loading: false,
        onGenerate: _noop,
      ),
    );

    expect(find.text('理解图'), findsOneWidget);
    expect(find.text('看这两个点'), findsOneWidget);
    expect(find.text('左右两个位置都要画出来。'), findsOneWidget);
    // 这条最关键：只断言文案的话，「数据到了但图没画」的坏版本会绿过去。
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('失败原因与旧图同时存在时，优先显示失败（可重试），不假装画好了', (tester) async {
    // 正常的实现不会出现这个组合，但如果将来有人把 `_figures` 和
    // `_figureFailures` 的清理顺序写反，就会「失败了却还挂着上一张图」。
    await pump(
      tester,
      ExplainFigureCard(
        figure: MistakeFigure(figure: figure(), reason: '旧图'),
        failure: '这次没画成',
        loading: false,
        onGenerate: _noop,
      ),
    );

    expect(find.text('这次没画成'), findsOneWidget);
    expect(find.text('再试一次'), findsOneWidget);
  });
}

void _noop() {}
