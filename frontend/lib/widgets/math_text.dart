import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../constants/app_colors.dart';

/// 一段文本里的数学公式切片。
///
/// 与 [MathText] 分开是为了让「怎么切」这件事能被单独测试：
/// 切错了不会报错，只会让界面上出现一串 `\frac{1}{2}` 原文 ——
/// 而它看起来像「模型写错了公式」，实际是渲染没接上。
enum MathSegmentKind {
  /// 普通文字。
  text,

  /// 行内公式（`$...$` 或 `\(...\)`）。
  inline,

  /// 独立公式（`$$...$$` 或 `\[...\]`）。
  display,
}

class MathSegment {
  const MathSegment(this.text, this.kind);

  final String text;
  final MathSegmentKind kind;

  bool get isMath => kind != MathSegmentKind.text;
}

/// 把带 LaTeX 的文本切成「文字 / 公式」片段。
///
/// ## 认哪些定界符
///
/// `$...$`、`$$...$$`、`\(...\)`、`\[...\]` —— 这四种是模型和教材里
/// 最常出现的写法。**先认 `$$` 再认 `$`**：反过来的话 `$$x$$` 会被切成
/// 「空公式 + `$x$` + `$`」，界面上多出一对美元符号。
///
/// ## 没闭合怎么办
///
/// 整段退化成文字。宁可让一段公式显示成 `$\frac{1}{2}$` 原文，
/// 也不要把它后面所有的字都当成公式 —— 那会让半页讲解变成一个红叉。
///
/// 这条规则有代价：文本里出现单个 `$`（比如价格「$5」）时，它后面的
/// 内容会被当作公式直到下一个 `$`。数学题里这个符号几乎不出现，
/// 而「宁可漏认也不吞掉正文」是更重要的那一半。
List<MathSegment> splitMathSegments(String raw) {
  if (raw.isEmpty) return const [];

  const openers = <({String open, String close, MathSegmentKind kind})>[
    (open: r'$$', close: r'$$', kind: MathSegmentKind.display),
    (open: r'\[', close: r'\]', kind: MathSegmentKind.display),
    (open: r'\(', close: r'\)', kind: MathSegmentKind.inline),
    (open: r'$', close: r'$', kind: MathSegmentKind.inline),
  ];

  final segments = <MathSegment>[];
  final buffer = StringBuffer();

  void flushText() {
    if (buffer.isEmpty) return;
    segments.add(MathSegment(buffer.toString(), MathSegmentKind.text));
    buffer.clear();
  }

  var index = 0;
  while (index < raw.length) {
    ({String open, String close, MathSegmentKind kind})? hit;
    for (final opener in openers) {
      if (raw.startsWith(opener.open, index)) {
        hit = opener;
        break;
      }
    }

    if (hit == null) {
      buffer.write(raw[index]);
      index++;
      continue;
    }

    final start = index + hit.open.length;
    final end = raw.indexOf(hit.close, start);
    if (end < 0) {
      // 没闭合：从这里往后全是正文。
      buffer.write(raw.substring(index));
      break;
    }

    final body = raw.substring(start, end);
    if (body.trim().isEmpty) {
      // `$$` 空公式：按原文写回，别在界面上留一个占位空块。
      buffer.write(raw.substring(index, end + hit.close.length));
      index = end + hit.close.length;
      continue;
    }

    flushText();
    segments.add(MathSegment(body, hit.kind));
    index = end + hit.close.length;
  }

  flushText();
  return segments;
}

/// 把「数学上下文里的裸斜线分数」包成 LaTeX 分式，交给渲染器。
///
/// ## 为什么需要它
///
/// 模型在**错因**字段里经常不遵守 LaTeX 约定：题干写 `$\frac{2}{3}$`，
/// 错因却写裸的 `1/3`、`-3/4`、`2/17`。结果同一页上，题干是竖排分式、
/// 错因是斜线分数 —— 学生和家长看到的就是「分数没统一」。
/// 错因里这些分数**没有 `$...$` 包裹**，`splitMathSegments` 认不出它们是
/// 公式，只能当普通文字显示斜线。
///
/// ## 为什么这么保守
///
/// 斜线 `/` 除了分数，还表示除法（`6÷2`）、日期（`2026/10/21`）、
/// 比例（`3/5 的家长`）。乱猜会把它们全变成竖排分式，错得更离谱。
/// 所以只转**同时满足全部条件**的形态：
/// 1. 分子分母都是**纯整数**（`-?\d+`，不带小数点、不带字母、不带嵌套分数）；
/// 2. 前面紧邻的字符是「空格 / 运算符 / 括号 / 负号 / 等号 / 逗号 / 冒号 /
///    中文标点 / 行首」—— 即它出现在一个**算式的边界**上；
/// 3. 前面不是 `÷`、不是 `/`、不是数字（排除 `6÷2`、`3/4/5`、`2026/10`）。
///
/// 只满足这些还**不够**：`2026/10` 的分子 `2026` 是整数、前面是空格，会误中。
/// 所以再加一道闸 —— 分数整体长度 ≤ 4（`-?\d{1,3}` 之间）才转，把年份/日期这类
/// 长数字挡在外面。错因里的分数分子分母几乎都在 3 位以内（`1/3`、`39/5`、
/// `13/14`、`2028/2029` 是极端但仍在范围内，日期 `2026/10` 被 4 位分子挡住）。
///
/// ## 返回 `null` 表示「没有可转的裸分数」，调用方原样走旧逻辑
String? normalizeBareFractions(String raw) {
  if (raw.isEmpty) return null;
  if (raw.contains(r'$')) return null; // 已有公式标记的交给 splitMathSegments。
  if (raw.contains(r'\frac')) return null;

  // 一个「分子/分母」的裸分数。分子分母都只允许整数，最多 3 位，
  // 前面允许一个负号。这样 2026 这类 4 位年份分子会被排除。
  final fraction = RegExp(r'(-?\d{1,3})/(-?\d{1,3})');

  var changed = false;
  final out = StringBuffer();
  final matches = <({int start, int end, String numerator, String denominator})>[];
  for (final m in fraction.allMatches(raw)) {
    matches.add((
      start: m.start,
      end: m.end,
      numerator: m.group(1)!,
      denominator: m.group(2)!,
    ));
  }

  var last = 0;
  for (final m in matches) {
    // 前视：`m.start` 前必须是一个算式边界，而不是数字/字母/`.`/`/`/`÷`。
    if (m.start > 0) {
      final prev = raw[m.start - 1];
      if (RegExp(r'[0-9A-Za-z./÷]').hasMatch(prev)) continue;
    }
    // 后视：分数后面跳过空格后若是汉字（CJK），多半是叙述（「3/5 的家长」），
    // 不转。算式里的分数后面跟的是运算符、标点、括号或行尾。
    var probe = m.end;
    while (probe < raw.length && raw[probe] == ' ') {
      probe++;
    }
    if (probe < raw.length && _isCjk(raw[probe])) continue;
    // 写前面一段原样。
    out.write(raw.substring(last, m.start));
    // 分数本身包成 LaTeX 分式。
    out.write(r'$\frac{');
    out.write(m.numerator);
    out.write('}{');
    out.write(m.denominator);
    out.write(r'}$');
    changed = true;
    last = m.end;
  }
  if (!changed) return null;
  out.write(raw.substring(last));
  return out.toString();
}

bool _isCjk(String ch) {
  final code = ch.codeUnitAt(0);
  // 中日韩统一表意文字 + 常用标点。只判基本区，够用。
  return (code >= 0x4E00 && code <= 0x9FFF) ||
      (code >= 0x3000 && code <= 0x303F);
}

/// 会把 `$...$` 渲染成数学公式的文本。
///
/// 错题讲解里到处都是 `\frac{x-1}{2}=3` 这种写法。不渲染的话学生看到的是
/// 一串反斜杠和花括号 —— 而这正是「讲解看不懂」里最容易被忽略的一层：
/// 不是模型讲错了，是界面没把公式显示出来。
///
/// ## 解析失败时显示原文
///
/// 模型偶尔会输出半截 LaTeX（少一个 `}`）。`Math.tex` 自带
/// `onErrorFallback`，这里把它接到「显示原文」上：一道题的公式写坏了，
/// 不该连累整页讲解渲染不出来。
class MathText extends StatelessWidget {
  const MathText(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final effective = style ?? DefaultTextStyle.of(context).style;
    // 错因里的裸斜线分数（`1/3`、`-3/4`）先归一成 LaTeX 分式，
    // 让它们与题干的 `\frac{}{}` 显示成同一种竖排分式。归一失败（没有
    // 可转的裸分数）时原样走旧逻辑，一个字节都不变。
    final normalized = normalizeBareFractions(text) ?? text;
    final segments = splitMathSegments(normalized);
    if (!segments.any((segment) => segment.isMath)) {
      return Text(
        text,
        style: effective,
        textAlign: textAlign,
        maxLines: maxLines,
        // 与下面带公式那条路保持一致：给了 `maxLines` 就省略号收尾。
        // 不写 `overflow` 时 `Text` 默认是 `clip` —— 截断处没有省略号，
        // 读起来像「这句话本来就断在这」，而不是「还有下文」。
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
      );
    }

    final spans = <InlineSpan>[];
    for (final segment in segments) {
      if (!segment.isMath) {
        spans.add(TextSpan(text: segment.text));
        continue;
      }
      spans.add(
        WidgetSpan(
          // `middle` 而不是 `baseline`：分式和根号的基线不好对齐，
          // 用基线会让公式明显偏下，而 `middle` 在常见字号下最稳。
          alignment: PlaceholderAlignment.middle,
          child: Math.tex(
            segment.text,
            // 块级公式也按行内排：`MathStyle.display` 在 `WidgetSpan` 里
            // 会把整段行距撑开，一页讲解里出现两个分式就散架了。
            mathStyle: MathStyle.text,
            textStyle: effective,
            onErrorFallback: (error) => Text(
              '\$${segment.text}\$',
              style: effective.copyWith(color: AppColors.textMuted),
            ),
          ),
        ),
      );
    }

    return Text.rich(
      TextSpan(style: effective, children: spans),
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}
