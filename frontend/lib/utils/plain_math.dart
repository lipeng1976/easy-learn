/// 把带 LaTeX 标记的文本变成「能印在纸上的一句话」。
///
/// ── 为什么需要它 ────────────────────────────────────────────────────────
///
/// 模型写的题目和错因里会带 `$...$`：`当 $x>20$ 时，水费为 $20 \times 2$`。
/// 屏幕上有 `MathText` 负责渲染，但**打印出来的卷子没有渲染器** ——
/// 直接印出来就是满纸 `$` 和 `\times`，看起来像程序坏了。
///
/// 这里不做真正的排版（`\frac` 排成分式要 PDF 引擎），只做两件事：
/// 去掉定界符、把高频命令换成对应符号。`\frac{1}{2}` 变成 `1/2`，
/// 比印成 `\frac{1}{2}` 好得多，也比「什么都不做、留个美元符号」好得多。
///
/// ⚠️ 这是**纯函数**，且刻意只处理一遍、不递归展开嵌套花括号 ——
/// 复杂的嵌套公式一定是残缺的（`\frac{\frac{1}{2}}{3}` 只会出一部分）。
/// 但那种公式本来就该由渲染器画，印在纸上也读不了。宁可简单可靠。
library;

/// 常见命令 → 可直接显示的符号。
///
/// 顺序有讲究：`\le` 必须在 `\leq` 之前匹配会出错（`\leq` 会被切成 `<` + `q`），
/// 所以这里按**长度从长到短**排序后再替换。
const Map<String, String> _symbols = {
  r'\leqslant': '≤',
  r'\geqslant': '≥',
  r'\rightarrow': '→',
  r'\leftarrow': '←',
  r'\Rightarrow': '⇒',
  r'\times': '×',
  r'\cdot': '·',
  r'\div': '÷',
  r'\leq': '≤',
  r'\geq': '≥',
  r'\neq': '≠',
  r'\approx': '≈',
  r'\infty': '∞',
  r'\angle': '∠',
  r'\triangle': '△',
  r'\pi': 'π',
  r'\alpha': 'α',
  r'\beta': 'β',
  r'\theta': 'θ',
  r'\sqrt': '√',
  r'\pm': '±',
  r'\because': '∵',
  r'\therefore': '∴',
  r'\perp': '⊥',
  r'\parallel': '∥',
  r'\circ': '°',
  r'\left': '',
  r'\right': '',
  r'\quad': ' ',
  r'\qquad': '  ',
  // 换行与间距：印在纸上没有意义，删掉比留一串反斜杠好。
  r'\\': ' ',
  r'\,': ' ',
  r'\;': ' ',
  r'\!': '',
  r'\ ': ' ',
};

/// 去掉定界符、替换命令。
String plainMathText(String raw) {
  if (raw.isEmpty) return raw;

  var text = raw
      // 块级定界符先处理，否则 `$$` 会各剩一个 `$`。
      .replaceAll(r'$$', '')
      .replaceAll(r'\[', '')
      .replaceAll(r'\]', '')
      .replaceAll(r'\(', '')
      .replaceAll(r'\)', '')
      .replaceAll(r'$', '');

  // `\text{……}` / `\mathrm{……}`：花括号里是给人看的字，取内容。
  text = text.replaceAllMapped(
    RegExp(r'\\(?:text|mathrm|mathbf|operatorname)\{([^{}]*)\}'),
    (match) => match.group(1) ?? '',
  );

  // `\frac{a}{b}` → `a/b`（只处理不嵌套的那层）。
  text = text.replaceAllMapped(
    RegExp(r'\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}'),
    (match) => '${match.group(1)}/${match.group(2)}',
  );

  // `\sqrt{x}` → `√(x)`。
  text = text.replaceAllMapped(
    RegExp(r'\\sqrt\{([^{}]*)\}'),
    (match) => '√(${match.group(1)})',
  );

  // 长的命令先替换：`\leq` 不能被 `\le` 抢先切掉。
  final keys = _symbols.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final key in keys) {
    text = text.replaceAll(key, _symbols[key]!);
  }

  // 剩下的 `\xxx` 命令：去掉反斜杠保留名字，好过留个孤零零的反斜杠。
  text = text.replaceAllMapped(
    RegExp(r'\\([a-zA-Z]+)'),
    (match) => match.group(1) ?? '',
  );

  // 花括号本身在纸上是噪音；正文里本来不该出现它们。
  text = text.replaceAll('{', '').replaceAll('}', '');

  // 连续空格压成一个：公式两边常留下多余空白。
  return text.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
}
