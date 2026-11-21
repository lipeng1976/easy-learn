import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../constants/app_colors.dart';
import '../../../models/practice_figure.dart';

/// 举一反三卡片上的配图。
///
/// 图由 [PracticeFigure]（点、线、标注）在本地画出来，不是图片。
/// 这么做的理由写在 `lib/models/practice_figure.dart` 顶部：模型画的位图，
/// 线长和标注数字会对不上，而学生看不出来。
///
/// ## 尺寸为什么按宽高比自适应
///
/// 几何题的图有瘦高的（三角形的高）也有扁宽的（L 形组合图形）。固定高度
/// 会把扁图压成一条线。这里按图本身的长宽比算高度，再夹在 120–220 之间 ——
/// 太小看不清标注，太大一屏放不下两道题。
class PracticeFigureView extends StatelessWidget {
  const PracticeFigureView({super.key, required this.figure});

  final PracticeFigure figure;

  static const double _minHeight = 120;
  static const double _maxHeight = 220;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final bounds = FigureBounds.of(figure);
        final ratio = bounds.height / math.max(bounds.width, 0.001);
        final height = (width * ratio).clamp(_minHeight, _maxHeight);
        return SizedBox(
          width: width,
          height: height,
          child: CustomPaint(painter: _FigurePainter(figure)),
        );
      },
    );
  }
}

/// 把图形坐标映射到画布坐标。
///
/// 数学坐标的 y 向上、屏幕的 y 向下，所以这里要翻一次 —— 忘了翻，整张图
/// 会上下颠倒，而且看起来「还是个图」，很难第一时间发现。
class _Projection {
  _Projection(this.bounds, this.size) {
    const padding = 26.0;
    final usableWidth = math.max(size.width - padding * 2, 1);
    final usableHeight = math.max(size.height - padding * 2, 1);
    scale = math.min(usableWidth / bounds.width, usableHeight / bounds.height);
    final drawnWidth = bounds.width * scale;
    final drawnHeight = bounds.height * scale;
    offsetX = (size.width - drawnWidth) / 2 - bounds.left * scale;
    // `top` 是**数学坐标里最大的 y**，所以它在画布上对应最上面一行：
    // 上边距是 (h - h_graph)/2。写成 (h + h_graph)/2 会整体下移一个图高，
    // 而图比画布高一点时，整张图就滑出可视区了。
    offsetY = (size.height - drawnHeight) / 2 + bounds.top * scale;
  }

  final FigureBounds bounds;
  final Size size;
  late final double scale;
  late final double offsetX;
  late final double offsetY;

  Offset call(Offset point) =>
      Offset(offsetX + point.dx * scale, offsetY - point.dy * scale);

  /// 长度换算：只用于箭头、直角框这类固定像素的装饰，不受缩放影响。
  double get unit => math.min(scale, 26);
}

/// 图形在数学坐标系里的包围盒。
///
/// 对外可见（而不是 `_FigureBounds`）只为了一件事：**它曾经算错过，
/// 而且错得完全无声**。`top`/`bottom` 的初始化方向反了之后，边界恒为
/// ±Infinity、跨度恒为 1、投影出的 `offsetY` 是无穷大 —— 画布上只剩
/// 一根被 `clamp` 顶在边缘的坐标轴，看起来像「这道题的图本来就这么空」。
/// 现在 `practice_figure_bounds_test.dart` 直接盯这几个数。
@visibleForTesting
class FigureBounds {
  FigureBounds({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
  });

  final double left;
  final double right;
  final double top;
  final double bottom;

  double get width => math.max(right - left, 1);

  /// 纵向跨度。**`top` 是数学坐标里的最大 y、`bottom` 是最小 y** ——
  /// 与屏幕坐标相反（屏幕的 y 向下）。这两个名字容易搞反，而搞反之后
  /// 跨度恒为 0、投影出的 `offsetY` 是无穷大，**所有点和线都画到画布外**，
  /// 只剩坐标轴被 `clamp` 顶在边缘上 —— 看起来像「这张图只有个空坐标系」。
  double get height => math.max(top - bottom, 1);

  static FigureBounds of(PracticeFigure figure) {
    var left = double.infinity;
    var right = double.negativeInfinity;
    // ⚠️ 初始化方向不能写反：求最大 y 要从 -∞ 起、求最小 y 要从 +∞ 起。
    // 反过来写的话 `math.max(+∞, y)` 恒为 +∞，边界永远是 ±Infinity，
    // 而编译、静态分析、单测都不会报任何错。
    var top = double.negativeInfinity;
    var bottom = double.infinity;

    void take(Offset point) {
      left = math.min(left, point.dx);
      right = math.max(right, point.dx);
      top = math.max(top, point.dy);
      bottom = math.min(bottom, point.dy);
    }

    for (final point in figure.points) {
      take(point.at);
    }
    for (final dim in figure.dims) {
      take(dim.from);
      take(dim.to);
    }
    for (final label in figure.labels) {
      take(label.at);
    }

    if (left == double.infinity) {
      return FigureBounds(left: 0, right: 1, top: 1, bottom: 0);
    }
    // 留一点余量给尺寸线的箭头和顶点字母，否则它们会被画布边缘切掉。
    const margin = 0.6;
    return FigureBounds(
      left: left - margin,
      right: right + margin,
      top: top + margin,
      bottom: bottom - margin,
    );
  }
}

class _FigurePainter extends CustomPainter {
  _FigurePainter(this.figure);

  final PracticeFigure figure;

  // 颜色跟着全局常量走：图形是题干的一部分，字与线该是同一个墨色。
  // 只有 `_fill`（多边形填充）没有对应常量 —— 它是主色的浅底，
  // 用途单一，写死在这里比再往 `AppColors` 里加一个只此一处的名字更清楚。
  static const Color _ink = AppColors.text;
  static const Color _fill = Color(0xFFEEF3FF);
  static const Color _dimColor = AppColors.textMuted;

  @override
  void paint(Canvas canvas, Size size) {
    final projection = _Projection(FigureBounds.of(figure), size);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = _ink;

    if (figure.isCoord) {
      _paintAxes(canvas, projection, size, stroke);
    }

    final fill = Paint()..color = _fill;
    for (final polygon in figure.polygons) {
      final path = _pathOf(polygon, projection, close: true);
      if (path == null) continue;
      canvas.drawPath(path, fill);
      canvas.drawPath(path, stroke);
    }
    for (final segment in figure.segments) {
      final path = _pathOf(segment, projection, close: false);
      if (path != null) canvas.drawPath(path, stroke);
    }
    final dashedStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = _dimColor;
    for (final segment in figure.dashed) {
      final path = _pathOf(segment, projection, close: false);
      if (path != null) _drawDashed(canvas, path, dashedStroke);
    }

    for (final mark in figure.marks) {
      _paintMark(canvas, projection, mark, stroke);
    }
    for (final dim in figure.dims) {
      _paintDim(canvas, projection, dim);
    }
    for (final label in figure.labels) {
      _paintText(canvas, label.text, projection(label.at), 12, _ink);
    }
    for (final point in figure.points) {
      final at = projection(point.at);
      canvas.drawCircle(at, 2.2, Paint()..color = _ink);
      // 顶点名放在点的右上方，避开线条本身。
      if (point.name.isNotEmpty) {
        _paintText(
          canvas,
          point.name,
          at + const Offset(5, -12),
          12,
          _ink,
        );
      }
    }
  }

  Path? _pathOf(List<String> names, _Projection projection, {required bool close}) {
    final points = <Offset>[];
    for (final name in names) {
      final at = figure.pointAt(name);
      if (at == null) return null;
      points.add(projection(at));
    }
    if (points.length < 2) return null;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    if (close) path.close();
    return path;
  }

  void _paintAxes(Canvas canvas, _Projection projection, Size size, Paint stroke) {
    final origin = projection(Offset.zero);
    final axes = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = _dimColor.withValues(alpha: 0.8);
    canvas.drawLine(Offset(0, origin.dy.clamp(0, size.height)),
        Offset(size.width, origin.dy.clamp(0, size.height)), axes);
    canvas.drawLine(Offset(origin.dx.clamp(0, size.width), 0),
        Offset(origin.dx.clamp(0, size.width), size.height), axes);
  }

  void _paintDim(Canvas canvas, _Projection projection, FigureDim dim) {
    final from = projection(dim.from);
    final to = projection(dim.to);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = _dimColor;
    canvas.drawLine(from, to, paint);

    final direction = to - from;
    final length = direction.distance;
    if (length > 0.001) {
      final unit = direction / length;
      _arrow(canvas, from, unit, paint);
      _arrow(canvas, to, -unit, paint);
    }

    // 文字压在线段中点，沿法线方向轻轻推开，避免与线本身重叠。
    final normal = length > 0.001
        ? Offset(-direction.dy / length, direction.dx / length)
        : Offset.zero;
    final middle = Offset((from.dx + to.dx) / 2, (from.dy + to.dy) / 2);
    _paintText(
      canvas,
      dim.text,
      middle + normal * 9,
      11.5,
      _dimColor,
      center: true,
    );
  }

  /// 箭头：两条相对于方向成 150° 的短线。
  void _arrow(Canvas canvas, Offset tip, Offset unit, Paint paint) {
    const size = 5.0;
    const cos = 0.866;
    const sin = 0.5;
    for (final sign in const [1.0, -1.0]) {
      final back = Offset(
        unit.dx * cos - unit.dy * sin * sign,
        unit.dx * sin * sign + unit.dy * cos,
      );
      canvas.drawLine(tip, tip + back * size, paint);
    }
  }

  void _paintMark(Canvas canvas, _Projection projection, FigureMark mark, Paint stroke) {
    final at = projection(mark.at);
    final unit = projection.unit;
    if (mark.kind == 'rightAngle') {
      const side = 7.0;
      final path = Path()
        ..moveTo(at.dx + side, at.dy)
        ..lineTo(at.dx + side, at.dy - side)
        ..lineTo(at.dx, at.dy - side);
      canvas.drawPath(path, stroke);
      return;
    }
    // 角弧：半圆 + 度数。半径跟着缩放走，太大会盖住图形。
    final radius = math.max(9.0, math.min(unit * 0.8, 16.0));
    canvas.drawArc(
      Rect.fromCircle(center: at, radius: radius),
      -math.pi * 0.15,
      math.pi * 0.6,
      false,
      stroke,
    );
    if (mark.text.isNotEmpty) {
      _paintText(
        canvas,
        mark.text,
        at + Offset(radius * 0.75, -radius * 0.9),
        11,
        _ink,
      );
    }
  }

  void _drawDashed(Canvas canvas, Path path, Paint paint) {
    const dash = 5.0;
    const gap = 3.5;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + gap;
      }
    }
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset at,
    double fontSize,
    Color color, {
    bool center = false,
  }) {
    if (text.isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          fontWeight: FontWeight.w500,
          height: 1.1,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final origin = center
        ? at - Offset(painter.width / 2, painter.height / 2)
        : at;
    painter.paint(canvas, origin);
  }

  @override
  bool shouldRepaint(covariant _FigurePainter oldDelegate) =>
      !identical(oldDelegate.figure, figure);
}
