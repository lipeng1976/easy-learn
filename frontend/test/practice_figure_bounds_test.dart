import 'package:easy_learn_app/models/practice_figure.dart';
import 'package:easy_learn_app/pages/student/widgets/practice_figure_view.dart';
import 'package:flutter_test/flutter_test.dart';

/// 图形包围盒。
///
/// ## 这些用例是为什么存在的
///
/// 2026-10-28 之前 `FigureBounds.of` 把 `top`/`bottom` 的初始化写反了：
/// 求最大值从 `+∞` 起、求最小值从 `-∞` 起，于是 `math.max(+∞, y)` 恒为
/// `+∞`、边界永远是 ±Infinity。后果是**画布上只剩一根坐标轴** ——
/// 点和线全被投影到无穷远，而坐标轴因为被 `clamp` 顶在边缘反而还在。
///
/// 这个 bug 活了很久，因为：
/// · 它不报错、不抛异常、不违反任何类型；
/// · `analyze` 和单元测试全绿（没人测过包围盒）；
/// · 看起来像「这张图本来就这么空」。
///
/// 所以这里只盯一件最朴素的事：**包围盒的四个数必须是有限值，跨度必须为正**。
void main() {
  PracticeFigure figureWith(List<Map<String, dynamic>> points,
      {List<Map<String, dynamic>> dims = const []}) {
    final parsed = PracticeFigure.parse({
      'type': 'coord',
      'points': points,
      'segments': points.length >= 2
          ? [
              [points.first['name'], points.last['name']],
            ]
          : null,
      if (dims.isNotEmpty) 'dims': dims,
    });
    expect(parsed, isNotNull, reason: '夹具本身就不合法，后面的断言没有意义');
    return parsed!;
  }

  test('数轴上的点：边界有限，纵向跨度为正（不是恒为 1）', () {
    // 真实场景：B 在 0，C 在 ±2，尺寸线画在 y=0.6，标签在 y=-0.5。
    final figure = figureWith(
      [
        {'name': 'B', 'x': 0, 'y': 0},
        {'name': 'C1', 'x': -2, 'y': 0},
        {'name': 'C2', 'x': 2, 'y': 0},
      ],
      dims: [
        {
          'from': {'x': -2, 'y': 0.6},
          'to': {'x': 0, 'y': 0.6},
          'text': '2',
        },
      ],
    );
    final bounds = FigureBounds.of(figure);

    expect(bounds.top.isFinite, isTrue, reason: 'top 是 +Infinity ⇒ 初始化方向写反了');
    expect(bounds.bottom.isFinite, isTrue, reason: 'bottom 是 -Infinity ⇒ 初始化方向写反了');
    expect(bounds.left.isFinite, isTrue);
    expect(bounds.right.isFinite, isTrue);

    // 跨度要反映真实图形：y 从 0（点）到 0.6（尺寸线），两侧各留 0.6 的边距
    // ⇒ 约 1.8。而不是 `math.max(bottom - top, 1)` 兜出来的那个 1。
    expect(bounds.height, greaterThan(1.5));
    expect(bounds.width, greaterThan(4.0));
  });

  test('top 是较大的 y、bottom 是较小的 y（数学坐标，y 向上）', () {
    final figure = figureWith([
      {'name': 'A', 'x': 0, 'y': -1},
      {'name': 'B', 'x': 3, 'y': 4},
    ]);
    final bounds = FigureBounds.of(figure);

    // 搞反的话 top 会比 bottom 小，height 变成负数再被 max 兜成 1 ——
    // 图在画布上会被压成一条线，同样「看起来像张图」。
    expect(bounds.top, greaterThan(bounds.bottom));
    expect(bounds.top, closeTo(4 + 0.6, 0.001));
    expect(bounds.bottom, closeTo(-1 - 0.6, 0.001));
  });

  test('只有一条水平线时跨度仍为正（不能因为高度是 0 就退化）', () {
    // 数轴题最常见的样子：所有点 y 都等于 0。
    // 没有 dims/labels 时真实高度就是 0，靠 margin 撑出 1.2。
    final figure = figureWith([
      {'name': 'A', 'x': -1, 'y': 0},
      {'name': 'B', 'x': 1, 'y': 0},
    ]);
    final bounds = FigureBounds.of(figure);

    expect(bounds.height.isFinite, isTrue);
    expect(bounds.height, greaterThan(0));
  });
}
