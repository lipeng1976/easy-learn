/// 把讲解稿变成「能听懂的普通话」。
///
/// 讲解里混着 LaTeX（`\frac{x-1}{2}`、`x^2`）和 Markdown（`**加粗**`）。
/// 原样丢给 TTS，念出来是「反斜杠 f r a c 左花括号 x 减 1……」，学生根本听不懂。
/// 这种失败还是**静音的** —— 声音出来了，只是内容不是人话，比没声音更难发现。
///
/// 这一层是纯函数，不依赖任何平台能力，所以可以被测试直接盯住。
library;

/// 符号命令 → 中文读法。
const Map<String, String> _commandReadings = <String, String>{
  r'\times': '乘',
  r'\cdot': '乘',
  r'\div': '除以',
  r'\pm': '正负',
  r'\mp': '负正',
  r'\leq': '小于等于',
  r'\le': '小于等于',
  r'\geq': '大于等于',
  r'\ge': '大于等于',
  r'\neq': '不等于',
  r'\ne': '不等于',
  r'\approx': '约等于',
  r'\equiv': '恒等于',
  r'\infty': '无穷大',
  r'\pi': '派',
  r'\alpha': '阿尔法',
  r'\beta': '贝塔',
  r'\gamma': '伽马',
  r'\delta': '德尔塔',
  r'\theta': '西塔',
  r'\lambda': '兰布达',
  r'\mu': '缪',
  r'\sigma': '西格玛',
  r'\omega': '欧米伽',
  r'\phi': '斐',
  r'\angle': '角',
  r'\triangle': '三角形',
  r'\perp': '垂直于',
  r'\parallel': '平行于',
  r'\because': '因为',
  r'\therefore': '所以',
  r'\sum': '求和',
  r'\int': '积分',
  r'\sin': 'sin',
  r'\cos': 'cos',
  r'\tan': 'tan',
  r'\log': 'log',
  r'\ln': 'ln',
  r'\circ': '度',
  r'\degree': '度',
  r'\left': '',
  r'\right': '',
  r'\quad': ' ',
  r'\qquad': ' ',
  r'\text': '',
  r'\mathrm': '',
  r'\mathbf': '',
  r'\mathit': '',
};

/// 把一段可能混着公式的文本转成朗读稿。
String speakableText(String input) {
  if (input.trim().isEmpty) return '';
  return _cleanup(_rewriteMath(_stripMarkdown(input)));
}

/// 只处理公式部分（不做 Markdown 清理）。测试与内部递归都用它。
String speakableMath(String input) {
  if (input.trim().isEmpty) return '';
  return _cleanup(_rewriteMath(input));
}

/// 把一篇错题讲解拼成一段口语稿。
///
/// 顺序就是学生听课的顺序：考什么 → 你为什么错 → 正确怎么做 → 哪里容易栽 → 记什么。
String explanationSpeechText({
  required String knowledgePoint,
  required String position,
  required String whyWrong,
  required List<String> steps,
  required List<String> pitfalls,
  required String mnemonic,
}) {
  final parts = <String>[];

  final point = speakableText(knowledgePoint).trim();
  final where = speakableText(position).trim();
  if (point.isNotEmpty) {
    parts.add(where.isEmpty ? '这道题考的是$point。' : '这道题考的是$point，$where。');
  } else if (where.isNotEmpty) {
    parts.add('这道题考的是$where。');
  }

  final why = speakableText(whyWrong).trim();
  if (why.isNotEmpty) parts.add('你错在：${_sentence(why)}');

  final stepTexts = <String>[];
  for (var i = 0; i < steps.length; i++) {
    final step = speakableText(steps[i]).trim();
    if (step.isEmpty) continue;
    stepTexts.add('第${i + 1}步，${_sentence(step)}');
  }
  if (stepTexts.isNotEmpty) {
    parts.add('正确解法：${stepTexts.join()}');
  }

  final pitfallsText = <String>[];
  for (var i = 0; i < pitfalls.length; i++) {
    final item = speakableText(pitfalls[i]).trim();
    if (item.isEmpty) continue;
    pitfallsText.add('${i + 1}，${_sentence(item)}');
  }
  if (pitfallsText.isNotEmpty) parts.add('容易出错的地方：${pitfallsText.join()}');

  final remember = speakableText(mnemonic).trim();
  if (remember.isNotEmpty) parts.add('一句话记住：${_sentence(remember)}');

  return parts.join('\n');
}

/// 把长稿切成 TTS 能吃的段。
///
/// Android 的 `TextToSpeech.getMaxSpeechInputLength()` 是 4000 字符，超了直接抛。
/// 这里按句末标点切、尽量贴近 [maxChars]，既不会超限，也不会把一句话拦腰截断。
///
/// [english] 决定按哪套标点断句。**这不是美化，是功能**：英文文章里没有 `。`，
/// 不给 `.` 就等于整篇当一句 —— 于是 3000 字符一刀切下去，正好切在某个单词
/// 中间，念出来谁也听不懂（而且照样有声音，属于最难发现的静默失败）。
List<String> splitForSpeech(
  String text, {
  int maxChars = 3000,
  bool english = false,
}) {
  final normalized = text.trim();
  if (normalized.isEmpty) return const <String>[];
  if (normalized.length <= maxChars) return <String>[normalized];

  final pieces = <String>[];
  var start = 0;
  for (var i = 0; i < normalized.length; i++) {
    if (_isSentenceEnd(normalized[i], english: english)) {
      pieces.add(normalized.substring(start, i + 1));
      start = i + 1;
    }
  }
  if (start < normalized.length) pieces.add(normalized.substring(start));

  final chunks = <String>[];
  final buffer = StringBuffer();
  for (final piece in pieces) {
    // 单句本身就超长（没有标点的技术文本）：硬切，总比抛异常好。
    if (piece.length > maxChars) {
      if (buffer.isNotEmpty) {
        chunks.add(buffer.toString());
        buffer.clear();
      }
      var offset = 0;
      while (offset < piece.length) {
        final end = (offset + maxChars).clamp(0, piece.length);
        chunks.add(piece.substring(offset, end));
        offset = end;
      }
      continue;
    }
    if (buffer.length + piece.length > maxChars && buffer.isNotEmpty) {
      chunks.add(buffer.toString());
      buffer.clear();
    }
    buffer.write(piece);
  }
  if (buffer.isNotEmpty) chunks.add(buffer.toString());
  return chunks;
}

/// 句末标点：念完天然该喘一口气。
///
/// 只收中文全角标点：**不断句就一口气念到完**，这才是「听着生硬」的主因之一。
const String _sentenceEndings = '。！？；\n';

/// 英文的句末标点。
///
/// 不收 `;`：英文分号后面往往还是同一个意思，切开会让句子读着断气。
/// 缩写（`Mr.`、`e.g.`）会被误判成句末 —— 代价只是多一次呼吸；
/// 反过来漏判的代价是整段不喘气，两害相权取轻。
const String _englishSentenceEndings = '.!?\n';

bool _isSentenceEnd(String ch, {required bool english}) =>
    (english ? _englishSentenceEndings : _sentenceEndings).contains(ch);

/// 句里面可以软切的位置（优先级从高到低，见 [_softCutAt]）。
const String _softBreakChars = '，,、：:）)】］';

/// 把一段朗读稿切成一句句。
///
/// 为什么不用「整篇一次交给引擎」：Android 的 TTS 拿到一大段文字会**不停顿地**
/// 从头念到尾，句读全丢 —— 学生听到的就是「念稿」而不是「讲」。切成一句句之后，
/// 原生侧可以在每句之间插一段静默（[playSilentUtterance]），听感立刻不一样。
///
/// [maxChars] 是**单句上限**，不是目标长度：句子本来就该有多长就多长，
/// 只有当模型吐出一段没有标点的技术文本时才由它兜底。
///
/// [english] 切换断句规则，见 [_englishSentenceEndings]。
List<String> splitIntoSentences(
  String input, {
  int maxChars = 180,
  bool english = false,
}) {
  final text = input.trim();
  if (text.isEmpty) return const <String>[];

  final sentences = <String>[];
  final buffer = StringBuffer();
  void flush() {
    final piece = buffer.toString().trim();
    buffer.clear();
    if (piece.isEmpty) return;
    if (piece.length <= maxChars) {
      sentences.add(piece);
    } else {
      sentences.addAll(_splitLongSentence(piece, maxChars));
    }
  }

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    buffer.write(ch);
    if (_isSentenceEnd(ch, english: english)) {
      // 连续标点（「……」「？！」「...」）要跟着同一句走，否则会析出「。」这样一句。
      while (i + 1 < text.length &&
          _isSentenceEnd(text[i + 1], english: english)) {
        i++;
        buffer.write(text[i]);
      }
      flush();
    }
  }
  flush();
  return sentences;
}

/// 切一条超长句：先在 [maxChars] 以内找最后一个软切点，找不到才硬切。
///
/// 从词中间砍开会念出谁也听不懂的音 —— 那种失败照样是静音的
/// （声音出来了，只是不是人话），所以宁可多留几个字也不能硬砍。
Iterable<String> _splitLongSentence(String sentence, int maxChars) sync* {
  var start = 0;
  while (start < sentence.length) {
    if (sentence.length - start <= maxChars) {
      yield sentence.substring(start).trim();
      return;
    }
    final limit = start + maxChars;
    final cut = _softCutAt(sentence, start, limit);
    final end = cut > start ? cut : limit;
    final piece = sentence.substring(start, end).trim();
    if (piece.isNotEmpty) yield piece;
    start = end;
  }
}

/// 在 `[start, limit)` 里找最靠后的软切点（切完之后那一小标点跟着前一句）。
int _softCutAt(String text, int start, int limit) {
  for (var i = limit - 1; i > start; i--) {
    if (_softBreakChars.contains(text[i])) return i + 1;
  }
  for (var i = limit - 1; i > start; i--) {
    if (text[i] == ' ') return i;
  }
  return -1;
}

String _sentence(String value) {
  if (value.isEmpty) return value;
  const endings = '。！？；：,，';
  return endings.contains(value[value.length - 1]) ? value : '$value。';
}

String _stripMarkdown(String input) {
  var text = input;
  text = text.replaceAll('**', '');
  text = text.replaceAll('__', '');
  text = text.replaceAll('`', '');
  text = text.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '');
  text = text.replaceAll(RegExp(r'^\s{0,3}[-*+]\s+', multiLine: true), '');
  text = text.replaceAll(RegExp(r'^\s{0,3}>\s?', multiLine: true), '');
  return text;
}

String _rewriteMath(String input) {
  var text = _stripMathDelimiters(input);
  text = _rewriteFractions(text);
  text = _rewriteRoots(text);
  text = _rewriteScripts(text);
  text = _replaceCommands(text);
  text = text.replaceAll(RegExp(r'\\[^a-zA-Z]'), ' ');
  return text;
}

String _stripMathDelimiters(String input) {
  var text = input;
  // 先 $$...$$ 再 $...$：反过来会把 $$ 切成两个空公式。
  text = text.replaceAllMapped(
    RegExp(r'\$\$([\s\S]*?)\$\$'),
    (match) => match[1] ?? '',
  );
  text = text.replaceAllMapped(
    RegExp(r'\$([^\$\n]+?)\$'),
    (match) => match[1] ?? '',
  );
  text = text.replaceAll(RegExp(r'\\\(|\\\)|\\\[|\\\]'), '');
  return text;
}

/// `\frac{a}{b}` → 「b 分之 a」。
///
/// 中文读法分母在前，和 LaTeX 的书写顺序相反 —— 这是最容易写反的一处。
String _rewriteFractions(String input) {
  const names = <String>[r'\dfrac', r'\tfrac', r'\frac'];
  final out = StringBuffer();
  var i = 0;
  while (i < input.length) {
    String? matched;
    if (input[i] == r'\') {
      for (final name in names) {
        if (input.startsWith(name, i)) {
          matched = name;
          break;
        }
      }
    }
    if (matched != null) {
      final numerator = _readGroup(input, i + matched.length);
      if (numerator != null) {
        final denominator = _readGroup(input, numerator.end);
        if (denominator != null) {
          final top = speakableMath(numerator.value);
          final bottom = speakableMath(denominator.value);
          out.write('$bottom 分之 $top');
          i = denominator.end;
          continue;
        }
      }
    }
    out.write(input[i]);
    i++;
  }
  return out.toString();
}

/// `\sqrt{x}` → 「根号 x」；`\sqrt[3]{x}` → 「x 的 3 次方根」。
String _rewriteRoots(String input) {
  const name = r'\sqrt';
  final out = StringBuffer();
  var i = 0;
  while (i < input.length) {
    if (input.startsWith(name, i)) {
      var cursor = i + name.length;
      String? degree;
      if (cursor < input.length && input[cursor] == '[') {
        final close = input.indexOf(']', cursor);
        if (close > cursor) {
          degree = input.substring(cursor + 1, close);
          cursor = close + 1;
        }
      }
      final radicand = _readGroup(input, cursor);
      if (radicand != null) {
        final inner = speakableMath(radicand.value);
        if (degree == null) {
          out.write('根号 $inner');
        } else {
          out.write('$inner 的 ${speakableMath(degree)} 次方根');
        }
        i = radicand.end;
        continue;
      }
    }
    out.write(input[i]);
    i++;
  }
  return out.toString();
}

/// `x^2` → 「x 的平方」，`x^{n+1}` → 「x 的 n+1 次方」，`a_1` → 「a 下标 1」。
String _rewriteScripts(String input) {
  final out = StringBuffer();
  var i = 0;
  while (i < input.length) {
    final ch = input[i];
    if (ch == '^' || ch == '_') {
      final group = _readGroup(input, i + 1);
      if (group != null) {
        final inner = speakableMath(group.value).trim();
        if (inner.isNotEmpty) {
          out.write(ch == '^' ? _superscript(inner) : ' 下标 $inner');
        }
        i = group.end;
        continue;
      }
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}

String _superscript(String inner) {
  if (inner == '度' || inner == '∘') return '度';
  if (inner == '2') return ' 的平方';
  if (inner == '3') return ' 的立方';
  return ' 的 $inner 次方';
}

String _replaceCommands(String input) {
  return input.replaceAllMapped(RegExp(r'\\([a-zA-Z]+)'), (match) {
    final name = '\\${match[1]}';
    return _commandReadings[name] ?? '';
  });
}

String _cleanup(String input) {
  var text = input.replaceAll(RegExp(r'[{}]'), '');
  text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
  text = text.replaceAll(RegExp(r' *\n *'), '\n');
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return text.trim();
}

class _Group {
  const _Group(this.value, this.end);

  final String value;

  /// 组结束后的下一个下标。
  final int end;
}

/// 读取一个 LaTeX 参数：`{...}`（支持嵌套）或单个字符/命令。
_Group? _readGroup(String source, int start) {
  var i = start;
  while (i < source.length && source[i] == ' ') {
    i++;
  }
  if (i >= source.length) return null;

  if (source[i] == '{') {
    var depth = 0;
    final buffer = StringBuffer();
    for (var j = i; j < source.length; j++) {
      final ch = source[j];
      if (ch == '{') {
        depth++;
        if (depth == 1) continue;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return _Group(buffer.toString(), j + 1);
      }
      buffer.write(ch);
    }
    // 花括号没闭合：不猜，原样留给后面的清理。
    return null;
  }

  if (source[i] == r'\') {
    var j = i + 1;
    while (j < source.length && RegExp(r'[a-zA-Z]').hasMatch(source[j])) {
      j++;
    }
    if (j == i + 1) j = i + 2;
    return _Group(source.substring(i, j), j.clamp(0, source.length));
  }

  return _Group(source[i], i + 1);
}
