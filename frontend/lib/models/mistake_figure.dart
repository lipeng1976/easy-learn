import 'practice_figure.dart';

/// 讲解页的「理解图」：**这张图该不该画 + 画什么**。
///
/// ## 为什么「不画」也要有个对象
///
/// `null` 在 Dart 里只有一个意思：「没有」。而这里有两种「没有图」，
/// 它们对学生要说的话完全不同：
/// · 这题是纯符号运算，画图没有意义 → 「这道题用式子讲更清楚」
/// · 模型画了，但图对不上题（标注长度与边长不符）→ 得说「这次没画成」
///
/// 把两者都折成 `null`，界面就只剩一种文案，家长会以为功能坏了。
///
/// ## 为什么图本身复用 [PracticeFigure]
///
/// 举一反三的配图和这里的图是**同一种东西**（点、线、标注），
/// 服务端也都是 `normalizeFigure` 校验过的。另造一套模型意味着
/// 两套渲染器、两次校验、两份会漂开的契约 —— 而漂开的表现是
/// 「有的题能画、有的题画不出来」，看起来像两个不相干的 bug。
class MistakeFigure {
  const MistakeFigure({
    this.figure,
    required this.reason,
    this.caption = '',
  });

  /// 可画的图；为 null 时 [reason] 说明为什么没画。
  final PracticeFigure? figure;

  /// 为什么画 / 为什么不画。这句话会直接显示给学生和家长，
  /// 所以它必须是人话 —— 服务端 `normalizeFigure` 的内部原因
  /// （「尺寸线长度与任何一条边都对不上」）不该出现在这里。
  final String reason;

  /// 图下方的一句话：这张图要看哪里。
  final String caption;

  bool get drawable => figure != null;

  /// 从接口返回的 JSON 解析。
  ///
  /// 返回 null 表示**契约坏了**（`draw=true` 却没有能解析的图），
  /// 由 `_invoke` 走重试。注意这和服务端说「不画」是两回事：
  /// 后者是一个正常结果，parse 会成功返回 `drawable == false`。
  static MistakeFigure? parse(Object? raw) {
    if (raw is! Map) return null;
    // `draw` 缺失**不算「不画」**：契约里它是必填的，缺了说明服务端和客户端
    // 的版本对不上。当成「不画」会静默吞掉这次不一致 —— 表现是「图功能
    // 突然全都不出图了，但不报错」，而那是最难查的一类故障。
    if (raw['draw'] is! bool) return null;

    final reason = _text(raw['reason']);
    if (raw['draw'] != true) {
      return MistakeFigure(
        reason: reason.isEmpty ? '这道题用式子讲更清楚，不需要配图。' : reason,
      );
    }

    final figure = PracticeFigure.parse(raw['figure']);
    // 服务端已经用 normalizeFigure 校过一遍，到这里还解析不出来，
    // 只能说明两边的契约漂了 —— 让上层重试一次，别把半张图塞给学生。
    if (figure == null) return null;

    return MistakeFigure(
      figure: figure,
      reason: reason.isEmpty ? '对照这张图看上面的步骤。' : reason,
      caption: _text(raw['caption']),
    );
  }

  static String _text(Object? value) =>
      value is String ? value.trim() : '';
}
