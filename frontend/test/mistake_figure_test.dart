import 'package:easy_learn_app/models/mistake_figure.dart';
import 'package:flutter_test/flutter_test.dart';

/// 讲解配图的解析契约。
///
/// 这些用例盯的是**三种「没有图」不能混为一谈**：
/// · 这题本来就不该画（服务端说 draw=false）→ 正常结果，要显示一句话
/// · 模型画了但图坏了（服务端会退回 draw=false 并标 figure_invalid）→ 也要显示
/// · 契约对不上（draw 缺失、draw=true 却没有能解析的图）→ 必须返回 null
///   让上层重试，绝不能悄悄当成「不画」
///
/// 最后一条最重要：混进前两种之后，配图功能整体坏掉时表现是「所有题都不出图」，
/// 而那看起来和「这些题恰好都不需要图」一模一样。
void main() {
  /// 一张最小的合法图：两个点 + 一条线段。
  Map<String, dynamic> planeFigure() => {
    'type': 'plane',
    'points': [
      {'name': 'A', 'x': 0, 'y': 0},
      {'name': 'B', 'x': 3, 'y': 0},
    ],
    'segments': [
      ['A', 'B'],
    ],
  };

  test('draw=false：正常返回「不画」，reason 原样留着给界面显示', () {
    final figure = MistakeFigure.parse({
      'draw': false,
      'reason': '纯符号运算，画图看不出新东西。',
      'rejected': 'model_declined',
    });

    expect(figure, isNotNull);
    expect(figure!.drawable, isFalse);
    expect(figure.reason, '纯符号运算，画图看不出新东西。');
  });

  test('draw=false 且没给 reason：给一句兜底文案，不能是空串', () {
    // 界面上一行空文本等于「点了按钮什么都没发生」。
    final figure = MistakeFigure.parse({'draw': false});

    expect(figure, isNotNull);
    expect(figure!.reason.isNotEmpty, isTrue);
  });

  test('draw=false 但原因是图没画对：同样不画，但话要说得不一样', () {
    // 服务端把 figure_invalid 也归成 draw=false，客户端只负责把 reason 显示出来。
    // 这条用例锁的是「reason 不被吞掉」——它和「这题不用画」是完全不同的两件事。
    final figure = MistakeFigure.parse({
      'draw': false,
      'reason': '这张图没画对（标注与图形对不上），改用文字讲。',
      'rejected': 'figure_invalid',
    });

    expect(figure!.drawable, isFalse);
    expect(figure.reason, contains('没画对'));
  });

  test('draw=true + 合法图：能渲染，caption 与 reason 都带出来', () {
    final figure = MistakeFigure.parse({
      'draw': true,
      'reason': '两个位置都要画出来。',
      'caption': '看这两个点',
      'figure': planeFigure(),
    });

    expect(figure, isNotNull);
    expect(figure!.drawable, isTrue);
    expect(figure.figure!.points.length, 2);
    expect(figure.caption, '看这两个点');
  });

  test('draw=true 但 figure 解析不出来 ⇒ null（走重试，不当成「不画」）', () {
    // 服务端已用 normalizeFigure 校过，到这里还解析不出来只能是两边契约漂了。
    // 返回一个 drawable=false 的对象会让学生看到「这题不用画图」——
    // 而真相是「画了但没解析出来」，两者该有完全不同的处置。
    final figure = MistakeFigure.parse({
      'draw': true,
      'reason': '画好了',
      'figure': {
        'type': 'plane',
        'points': [
          {'name': 'A', 'x': 0, 'y': 0},
          {'name': 'B', 'x': 3, 'y': 0},
        ],
        // 只有点、没有任何边 —— 画出来是一堆孤立的点。
      },
    });

    expect(figure, isNull);
  });

  test('draw 字段缺失 ⇒ null，不能默认成「不画」', () {
    final figure = MistakeFigure.parse({
      'reason': '随便说点什么',
    });

    expect(figure, isNull);
  });

  test('draw 不是布尔值（模型给了字符串 "true"）⇒ null', () {
    final figure = MistakeFigure.parse({
      'draw': 'true',
      'figure': planeFigure(),
    });

    expect(figure, isNull);
  });
}
