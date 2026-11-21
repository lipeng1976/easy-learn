import 'package:easy_learn_app/widgets/math_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

/// 公式切分的判据。
///
/// 切错的表现全部是**静的**：界面照常渲染，只是 `$` 和反斜杠露了出来，
/// 或者半段正文被吞进公式里。所以这些断言必须精确到片段内容。
void main() {
  test('行内公式被切出来，两侧文字保留', () {
    final segments = splitMathSegments(r'计算 $\frac{1}{2}+\frac{1}{3}$ 的值');

    expect(segments.map((s) => s.kind), [
      MathSegmentKind.text,
      MathSegmentKind.inline,
      MathSegmentKind.text,
    ]);
    expect(segments[0].text, '计算 ');
    expect(segments[1].text, r'\frac{1}{2}+\frac{1}{3}');
    expect(segments[2].text, ' 的值');
  });

  test('双美元符优先于单美元符，不会切出空公式', () {
    // 先认 `$` 的话，`$$x$$` 会变成「空公式 + $x$ + $」——
    // 界面上会多出两个美元符号，而没有人会想到是切分顺序的问题。
    final segments = splitMathSegments(r'$$x^2+1$$');
    expect(segments.length, 1);
    expect(segments.single.kind, MathSegmentKind.display);
    expect(segments.single.text, 'x^2+1');
  });

  test(r'\(...\) 与 \[...\] 也认', () {
    expect(
      splitMathSegments(r'\(a+b\)').single.kind,
      MathSegmentKind.inline,
    );
    expect(
      splitMathSegments(r'\[a+b\]').single.kind,
      MathSegmentKind.display,
    );
  });

  test('没闭合的公式整段退化成文字，不吞掉后面的正文', () {
    const raw = r'答案是 $\frac{1}{2} 这一步算错了';
    final segments = splitMathSegments(raw);
    expect(segments.length, 1);
    expect(segments.single.kind, MathSegmentKind.text);
    expect(segments.single.text, raw, reason: '原文必须一字不差地留着');
  });

  test('单个美元符当货币符号时不吞正文', () {
    const raw = r'这本书 $5 元';
    final segments = splitMathSegments(raw);
    expect(segments.single.kind, MathSegmentKind.text);
    expect(segments.single.text, raw);
  });

  test('空公式按原文写回，不产生空的数学块', () {
    // 空的 `$ $` 会被渲染成一个零宽占位，视觉上像多了一个空格。
    final segments = splitMathSegments(r'a $$ b');
    expect(segments.length, 1);
    expect(segments.single.kind, MathSegmentKind.text);
    expect(segments.single.text, r'a $$ b');
  });

  test('没有公式的文本保持一段', () {
    final segments = splitMathSegments('先通分，再比较分子');
    expect(segments.length, 1);
    expect(segments.single.isMath, isFalse);
  });

  testWidgets('含公式的文本能渲染出来（解析失败也不炸整页）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MathText(r'先通分：$\frac{1}{2}+\frac{1}{3}=\frac{5}{6}$'),
              // 故意少一个 `}`：模型输出半截 LaTeX 是常见状态，
              // 它不该让整页讲解白屏。
              MathText(r'坏掉的公式：$\frac{1}{2$'),
            ],
          ),
        ),
      ),
    );

    // 有公式的那条不再是单个 Text，而是 Text.rich + WidgetSpan。
    expect(find.byType(MathText), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  // 「分数、平方到底显示得出来吗」这件事的**直接判据**。
  //
  // 上面那些测的是「怎么切文字」，这两条测的是「切完之后界面上到底有没有公式」。
  // 少了这一步，切分全对也可能只是渲染那一段没接上 —— 而它的表现和
  // 「模型没写公式」一模一样，都是界面上出现一串反斜杠。
  //
  // ⚠️ 关键是**反面**：不带 `$` 的 `1/2`、`x^2` **不会**被渲染。
  // 这决定了整件事的上游：客户端的渲染能力只对**模型输出 LaTeX** 的文本有效。
  // 所以「公式能不能显示」不是一个客户端问题，是「模型有没有按要求写」的问题。
  testWidgets(r'带 $ 的分数与平方真的变成公式块', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MathText(r'计算 $\frac{3}{4}+\frac{1}{2}$ 的值'),
              MathText(r'化简 $x^2-5x+6$ 与 $30^\circ$'),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(Math), findsNWidgets(3), reason: '3 个公式就该有 3 个公式块');
    // 原文不能被留在界面上：留着就说明渲染那一步根本没生效。
    expect(find.textContaining(r'\frac'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('数学算式里的裸斜线分数会归一成竖排分式 —— 与题干统一', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MathText('错因：第 9 题 (-3) ÷ 1/3 = -3 × 3，学生算成了 -16'),
              MathText('通分：1/2 - 1/3 + 1/4 = 5/12'),
            ],
          ),
        ),
      ),
    );

    // 裸分数被包成了 \frac，界面上不该再出现斜线的「1/3」字面量。
    expect(find.textContaining('1/3'), findsNothing);
    expect(find.byType(Math), findsNWidgets(5),
        reason: '第一条 1 个（1/3），第二条 4 个（1/2、1/3、1/4、5/12）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('除法与日期不会被误转成竖排分式', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MathText('6 ÷ 2 = 3，这里 2 不是分数'),
              MathText('日期 2026/10/21 不变'),
              MathText('这道题 3/5 的家长做对了'), // 比例/叙述，前面是「题 」不是算式边界
            ],
          ),
        ),
      ),
    );

    // 6÷2 的 2 前面是 ÷，不转；2026/10 分子 4 位不转；「题 3/5」前面是汉字不转。
    expect(find.byType(Math), findsNothing,
        reason: '除法、日期、叙述里的斜线都不该被当成分数');
    expect(find.textContaining('6 ÷ 2'), findsOneWidget);
    expect(find.textContaining('2026/10/21'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已带 \$ 的公式原样走渲染，归一化不介入', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MathText(r'计算 $\frac{3}{4}+\frac{1}{2}$ 的值'),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(Math), findsOneWidget,
        reason: r'$\frac{3}{4}+\frac{1}{2}$ 是一个 $...$ 包裹的单个公式块');
    expect(find.textContaining(r'\frac'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
