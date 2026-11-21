/// 把一篇英文课文切成若干块，让**第一块**尽快合成出来先出声。
///
/// ## 为什么需要切
///
/// 直连合成是「整篇一次请求」：书里最长的一课 4822 字符实测要 15.9 秒。
/// 也就是说学生点完「伴读」要愣十几秒才听到第一个词 —— 这十几秒里界面
/// 只是转圈，看起来跟坏了一模一样。
///
/// 切成块之后，首声只等第一块（约 200 字符，1.5 秒左右），后面的块在
/// 播放的同时合成。
///
/// ## 硬约束：切出来的块必须能拼回原文
///
/// 切错一个词，孩子听到的是一句原文里不存在的句子，而界面上**没有任何
/// 异常** —— 这是本项目最典型的静默失败。所以 [splitForSpeech] 的判据
/// 不是「块数够多」，而是「把所有块按顺序接起来，和原文逐字一致」。
///
/// 两个容易切错的地方：
///  · `Mr. Smith` / `U.S.` —— 点在缩写里，不是句子结束；
///  · `3.14` / `example.com` —— 点后面没有空白，不是句子结束。
library;

/// 常见缩写。点在这些词后面不算句子结束。
///
/// 不用 NLP，只认一张小表：课文是给初中生读的，出现生僻缩写的概率极低，
/// 而多认错一个的代价只是「两句合成一块」，不影响正确性。
const Set<String> _abbreviations = {
  'mr', 'mrs', 'ms', 'dr', 'prof', 'st', 'mt', 'jr', 'sr', 'vs', 'etc',
  'fig', 'no', 'vol', 'ch', 'pp', 'p', 'u.s', 'u.k', 'a.m', 'p.m', 'e.g', 'i.e',
};

/// 切块。
///
/// [firstChunkChars] 比 [targetChars] 小得多：第一块越小，出声越早。
/// 但它至少要能装下一句完整的话 —— 所以真正切出来的第一块会落在
/// [firstChunkChars, maxChars] 之间。
///
/// 返回的每一块都非空、已 trim，按顺序接起来（块间补一个空格、空白归一）
/// 与原文一致。
List<String> splitForSpeech(
  String text, {
  int firstChunkChars = 220,
  int targetChars = 420,
  int maxChars = 700,
}) {
  assert(targetChars > 0, 'targetChars 必须为正');
  assert(maxChars >= targetChars, 'maxChars 不能小于 targetChars');
  assert(firstChunkChars > 0 && firstChunkChars <= targetChars);

  final paragraphs = text
      .replaceAll('\r\n', '\n')
      .split(RegExp(r'\n\s*\n'))
      .map((p) => p.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((p) => p.isNotEmpty);

  final out = <String>[];
  final buffer = StringBuffer();

  void flush() {
    final s = buffer.toString().trim();
    buffer.clear();
    if (s.isNotEmpty) out.add(s);
  }

  for (final paragraph in paragraphs) {
    for (final sentence in _sentences(paragraph)) {
      for (final piece in _fit(sentence, maxChars)) {
        // 装不下了先收口，保证任何一块都不超过 maxChars。
        if (buffer.isNotEmpty && buffer.length + 1 + piece.length > maxChars) {
          flush();
        }
        if (buffer.isNotEmpty) buffer.write(' ');
        buffer.write(piece);
        final target = out.isEmpty ? firstChunkChars : targetChars;
        if (buffer.length >= target) flush();
      }
    }
  }
  flush();
  return out;
}

/// 按句末标点切句。点后面没有空白的不算（`3.14`），缩写里的点不算（`Mr.`）。
Iterable<String> _sentences(String paragraph) sync* {
  var start = 0;
  var i = 0;
  while (i < paragraph.length) {
    final c = paragraph[i];
    if (c != '.' && c != '!' && c != '?') {
      i++;
      continue;
    }

    // 把连着的标点和右引号一起吃掉：`!"` / `...`
    var j = i;
    while (j + 1 < paragraph.length && '.!?"\u201D\u2019'.contains(paragraph[j + 1])) {
      j++;
    }

    final nextIsSpace = j + 1 >= paragraph.length || paragraph[j + 1] == ' ';
    if (!nextIsSpace) {
      // `3.14` / `example.com` —— 继续往后找真正的句末。
      i = j + 1;
      continue;
    }
    if (c == '.' && _isAbbreviation(paragraph, start, i)) {
      i = j + 1;
      continue;
    }

    yield paragraph.substring(start, j + 1);
    start = j + 1;
    i = j + 1;
  }
  if (start < paragraph.length) yield paragraph.substring(start);
}

/// [dot] 处的点前面那个词是不是缩写。
bool _isAbbreviation(String p, int start, int dot) {
  var k = dot - 1;
  while (k >= start && (RegExp('[A-Za-z.]').hasMatch(p[k]))) {
    k--;
  }
  final raw = p.substring(k + 1, dot);
  if (raw.isEmpty) return false;
  if (_abbreviations.contains(raw.toLowerCase())) return true;
  // 单个大写字母 = 姓名首字母（`J. K. Rowling`）。
  return raw.length == 1 &&
      raw == raw.toUpperCase() &&
      raw != raw.toLowerCase();
}

/// 一句话本身就超过 [maxChars] 时，在空格处硬切 —— 绝不切在单词中间。
Iterable<String> _fit(String sentence, int maxChars) sync* {
  var rest = sentence.trim();
  while (rest.length > maxChars) {
    var cut = rest.lastIndexOf(' ', maxChars);
    if (cut <= 0) cut = maxChars;
    final head = rest.substring(0, cut).trim();
    if (head.isNotEmpty) yield head;
    rest = rest.substring(cut).trim();
  }
  if (rest.isNotEmpty) yield rest;
}
