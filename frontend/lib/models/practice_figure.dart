import 'dart:ui';

/// 举一反三的**配图**：一份「点和线」的描述，画由本地做。
///
/// ## 为什么不是图片 URL
///
/// 图是模型描述出来的，不是画出来的。图像生成模型画的几何图，线长和标注
/// 数字对不上 —— 图上标着 `a` 的边可能是任意长度，写着 50° 的角可能是 80°。
/// 那种图看起来完全正常，学生照着它推理就会得出基于错误前提的结论。
/// 所以坐标是数、长度由坐标算出来，标注写什么与线画多长由同一组数决定。
///
/// ## 为什么解析失败就整张丢
///
/// 半张图比没有图更糟：少画一条尺寸线的图，学生读到的是「这条边没有标注」，
/// 那是另一个意思。所以 [PracticeFigure.parse] 在任何一处对不上时返回 null，
/// 由界面退回纯文字。—— 与网关侧 `figure.js` 的处置保持一致。
class PracticeFigure {
  const PracticeFigure({
    required this.type,
    required this.points,
    required this.polygons,
    required this.segments,
    required this.dashed,
    required this.dims,
    required this.labels,
    required this.marks,
  });

  /// `plane`（平面几何图）或 `coord`（直角坐标系）。
  final String type;
  final List<FigurePoint> points;

  /// 用点名的顺序围成的封闭图形。
  final List<List<String>> polygons;
  final List<List<String>> segments;

  /// 虚线：辅助线、延长线。
  final List<List<String>> dashed;
  final List<FigureDim> dims;
  final List<FigureLabel> labels;
  final List<FigureMark> marks;

  bool get isCoord => type == 'coord';

  Offset? pointAt(String name) {
    for (final point in points) {
      if (point.name == name) return point.at;
    }
    return null;
  }

  /// 从接口返回的 JSON 解析。
  ///
  /// 只认这一套字段；缺了必要的东西就返回 null。**不猜、不补默认值** ——
  /// 给一个能渲染但内容错的图，比不渲染更危险。
  static PracticeFigure? parse(Object? raw) {
    if (raw is! Map) return null;

    final typeRaw = raw['type'];
    final type = typeRaw is String ? typeRaw.trim() : 'plane';
    // 模型常把平面几何图写成 polygon，与服务端用的是同一套别名。
    const aliases = {
      'polygon': 'plane',
      'geometry': 'plane',
      'planeGeometry': 'plane',
      'coordinate': 'coord',
      'cartesian': 'coord',
    };
    final normalized = aliases[type] ?? type;
    if (normalized != 'plane' && normalized != 'coord') return null;

    final points = <FigurePoint>[];
    final seen = <String>{};
    final rawPoints = raw['points'];
    if (rawPoints is List) {
      for (final item in rawPoints) {
        final point = FigurePoint.parse(item);
        if (point == null || !seen.add(point.name)) return null;
        points.add(point);
      }
    }
    if (points.length < 2) return null;

    List<List<String>>? readShapes(Object? value, int minLength) {
      if (value == null) return [];
      if (value is! List) return null;
      final out = <List<String>>[];
      for (final shape in value) {
        if (shape is! List || shape.length < minLength) return null;
        final names = <String>[];
        for (final name in shape) {
          if (name is! String || !seen.contains(name)) return null;
          names.add(name);
        }
        out.add(names);
      }
      return out;
    }

    final polygons = readShapes(raw['polygons'], 3);
    final segments = readShapes(raw['segments'], 2);
    final dashed = readShapes(raw['dashed'], 2);
    if (polygons == null || segments == null || dashed == null) return null;
    if (normalized == 'plane' && polygons.isEmpty && segments.isEmpty) return null;

    final dims = <FigureDim>[];
    if (raw['dims'] != null) {
      final list = raw['dims'];
      if (list is! List) return null;
      for (final item in list) {
        final dim = FigureDim.parse(item);
        if (dim == null) return null;
        dims.add(dim);
      }
    }

    final labels = <FigureLabel>[];
    if (raw['labels'] != null) {
      final list = raw['labels'];
      if (list is! List) return null;
      for (final item in list) {
        final label = FigureLabel.parse(item);
        if (label == null) return null;
        labels.add(label);
      }
    }

    final marks = <FigureMark>[];
    if (raw['marks'] != null) {
      final list = raw['marks'];
      if (list is! List) return null;
      for (final item in list) {
        final mark = FigureMark.parse(item);
        if (mark == null) return null;
        marks.add(mark);
      }
    }

    return PracticeFigure(
      type: normalized,
      points: points,
      polygons: polygons,
      segments: segments,
      dashed: dashed,
      dims: dims,
      labels: labels,
      marks: marks,
    );
  }
}

class FigurePoint {
  const FigurePoint({required this.name, required this.x, required this.y});

  final String name;
  final double x;
  final double y;

  Offset get at => Offset(x, y);

  static FigurePoint? parse(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String || name.trim().isEmpty) return null;
    return _point(name.trim(), raw);
  }
}

/// 尺寸标注：一条带箭头的线 + 一个量。
class FigureDim {
  const FigureDim({required this.from, required this.to, required this.text});

  final Offset from;
  final Offset to;
  final String text;

  static FigureDim? parse(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    if (text is! String || text.trim().isEmpty) return null;
    final from = _offsetOf(raw['from']);
    final to = _offsetOf(raw['to']);
    if (from == null || to == null) return null;
    if ((to - from).distance < 0.2) return null;
    return FigureDim(from: from, to: to, text: text.trim());
  }
}

class FigureLabel {
  const FigureLabel({required this.text, required this.at});

  final String text;
  final Offset at;

  static FigureLabel? parse(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    if (text is! String || text.trim().isEmpty) return null;
    final at = _offsetOf(raw);
    if (at == null) return null;
    return FigureLabel(text: text.trim(), at: at);
  }
}

/// 直角标记 / 角弧标记。
class FigureMark {
  const FigureMark({required this.kind, required this.at, this.text = ''});

  final String kind;
  final Offset at;
  final String text;

  static FigureMark? parse(Object? raw) {
    if (raw is! Map) return null;
    final kind = raw['kind'];
    if (kind != 'rightAngle' && kind != 'arc') return null;
    final at = _offsetOf(raw['at']);
    if (at == null) return null;
    final text = raw['text'];
    return FigureMark(
      kind: kind as String,
      at: at,
      text: text is String ? text.trim() : '',
    );
  }
}

FigurePoint? _point(String name, Map raw) {
  final x = _doubleOf(raw['x']);
  final y = _doubleOf(raw['y']);
  if (x == null || y == null) return null;
  if (x.abs() > 50 || y.abs() > 50) return null;
  return FigurePoint(name: name, x: x, y: y);
}

Offset? _offsetOf(Object? raw) {
  if (raw is! Map) return null;
  final x = _doubleOf(raw['x']);
  final y = _doubleOf(raw['y']);
  if (x == null || y == null) return null;
  if (x.abs() > 50 || y.abs() > 50) return null;
  return Offset(x, y);
}

double? _doubleOf(Object? raw) {
  if (raw is num) {
    final value = raw.toDouble();
    return value.isFinite ? value : null;
  }
  if (raw is String) return double.tryParse(raw.trim());
  return null;
}
