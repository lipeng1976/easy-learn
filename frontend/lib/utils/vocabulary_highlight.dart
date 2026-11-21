/// 把正文按「生词 / 普通文字」切片，供页面渲染成粗体蓝色。
///
/// ## 为什么要做词形还原
///
/// 生词表给的是**原形**（`spend` / `stop` / `study`），正文里却是
/// `spent` / `stopped` / `studies`。只做精确匹配的话，实测 96 课 344 个生词
/// 只有 73.8% 能在正文里找到 —— 剩下两成多的词在文章里明明看得见，
/// 却没被标出来，学生会以为这些词没出现在课文里。
///
/// 加上屈折形式（复数、过去式、进行时、比较级 + 一张不规则动词表）之后
/// 命中率升到 96.8%。剩下的 3.2% 是**原书词汇表列了但正文确实没这个词**
/// （`lesson`、`own`、`give` 等），或者是要靠派生词（`honesty`↔`honest`）
/// 才能对上的 —— 派生不做，因为 `success`↔`successful` 这种跨义项匹配
/// 容易把不该标的词标上。
///
/// ## 只标一次同一个词
///
/// 同一段里同一个生词出现多次要**都标**（学生重读时每一处都需要提示），
/// 所以这里不做去重。
library;

/// 正文里的一个片段。
class VocabularyPiece {
  const VocabularyPiece(this.text, {this.isVocabulary = false});

  final String text;

  /// 是否是命中的生词（渲染成粗体蓝色）。
  final bool isVocabulary;
}

/// 英文单词（含撇号，如 `don't`）。
///
/// 连字符在这里被当成分隔符：`well-known` 会切成 `well` 和 `known`，
/// 生词表里没有短语，这样切反而更容易命中。
final RegExp _tokenPattern = RegExp(r"[A-Za-z][A-Za-z'’]*");

/// 把 [text] 切成片段，[words] 是这一课的生词（原形）。
///
/// **不变量**：所有片段的 `text` 按序拼起来必须与入参逐字相同。
/// 正文里任何一个字符（空格、换行、标点）都不能在切片过程中丢掉。
List<VocabularyPiece> splitVocabulary(String text, Iterable<String> words) {
  if (text.isEmpty) return const [];

  final index = _buildIndex(words);
  if (index.isEmpty) return [VocabularyPiece(text)];

  final pieces = <VocabularyPiece>[];
  var cursor = 0;
  for (final match in _tokenPattern.allMatches(text)) {
    final token = match.group(0)!;
    if (!index.containsKey(token.toLowerCase())) continue;
    if (match.start > cursor) {
      pieces.add(VocabularyPiece(text.substring(cursor, match.start)));
    }
    pieces.add(VocabularyPiece(token, isVocabulary: true));
    cursor = match.end;
  }
  if (pieces.isEmpty) return [VocabularyPiece(text)];
  if (cursor < text.length) pieces.add(VocabularyPiece(text.substring(cursor)));
  return pieces;
}

/// 这一课的生词是否真的在正文里出现过（用来决定要不要给页面加提示）。
bool vocabularyAppearsIn(String text, Iterable<String> words) {
  final index = _buildIndex(words);
  if (index.isEmpty) return false;
  for (final match in _tokenPattern.allMatches(text)) {
    if (index.containsKey(match.group(0)!.toLowerCase())) return true;
  }
  return false;
}

Map<String, String> _buildIndex(Iterable<String> words) {
  final index = <String, String>{};
  for (final raw in words) {
    final word = raw.trim().toLowerCase();
    if (word.isEmpty) continue;
    for (final form in _formsOf(word)) {
      index[form] = word;
    }
  }
  return index;
}

/// 原形 + 它的屈折形式。
///
/// 允许**多生成**（比如 `open` 会多出个 `openning`）：多出来的形式正文里
/// 几乎不会出现，代价只是索引大一点；少生成才会漏标。唯一要守住的是
/// 不能生成**别的常用词**，所以规则都在词尾，且带单音节限制。
Set<String> _formsOf(String word) {
  final out = <String>{word};
  if (word.length < 2) return out;

  final endsWithConsonantY = RegExp(r'[^aeiou]y$').hasMatch(word);
  final last = word[word.length - 1];

  // 复数 / 三单
  if (RegExp(r'(s|x|z|ch|sh|o)$').hasMatch(word)) {
    out.add('${word}es');
  } else if (endsWithConsonantY) {
    out.add('${word.substring(0, word.length - 1)}ies');
  } else {
    out.add('${word}s');
  }

  // 过去式 / 进行时
  if (last == 'e') {
    out.add('${word}d');
    out.add('${word.substring(0, word.length - 1)}ing');
  } else if (endsWithConsonantY) {
    out.add('${word.substring(0, word.length - 1)}ied');
    out.add('${word}ing');
  } else {
    out.add('${word}ed');
    out.add('${word}ing');
  }

  // 双写末尾辅音：stop → stopped / stopping（只在单音节里做，
  // 否则 open 会被推成 openning）
  if (_isSingleSyllableCvc(word)) {
    final doubled = '$word$last';
    out.add('${doubled}ed');
    out.add('${doubled}ing');
    out.add('${doubled}er');
    out.add('${doubled}est');
  }

  // 比较级 / 最高级
  out.add('${word}er');
  out.add('${word}est');
  if (last == 'e') {
    out.add('${word}r');
    out.add('${word}st');
  }
  if (endsWithConsonantY) {
    final stem = word.substring(0, word.length - 1);
    out.add('${stem}ier');
    out.add('${stem}iest');
  }

  for (final irregular in _irregular[word] ?? const <String>[]) {
    out.add(irregular);
  }
  return out;
}

bool _isSingleSyllableCvc(String word) {
  if (word.length < 3) return false;
  const vowels = 'aeiou';
  final last = word[word.length - 1];
  final second = word[word.length - 2];
  final third = word[word.length - 3];
  if (vowels.contains(last) || 'wxy'.contains(last)) return false;
  if (!vowels.contains(second)) return false;
  if (vowels.contains(third)) return false;
  // 元音组数必须是 1（`stop` ✓ / `open` ✗）
  return RegExp(r'[aeiouy]+').allMatches(word).length == 1;
}

/// 不规则动词原形 → 过去式/过去分词。
///
/// 只收课文里真会出现的（初一/初二阅读的高频词）。宁可少收 ——
/// 收错了会把不相干的词标成生词。
const Map<String, List<String>> _irregular = {
  'be': ['is', 'am', 'are', 'was', 'were', 'been', 'being'],
  'become': ['became'],
  'begin': ['began', 'begun'],
  'bite': ['bit', 'bitten'],
  'blow': ['blew', 'blown'],
  'break': ['broke', 'broken'],
  'bring': ['brought'],
  'build': ['built'],
  'buy': ['bought'],
  'catch': ['caught'],
  'choose': ['chose', 'chosen'],
  'come': ['came'],
  'cut': ['cut'],
  'dig': ['dug'],
  'do': ['did', 'done'],
  'draw': ['drew', 'drawn'],
  'drink': ['drank', 'drunk'],
  'drive': ['drove', 'driven'],
  'eat': ['ate', 'eaten'],
  'fall': ['fell', 'fallen'],
  'feed': ['fed'],
  'feel': ['felt'],
  'fight': ['fought'],
  'find': ['found'],
  'fly': ['flew', 'flown'],
  'forget': ['forgot', 'forgotten'],
  'freeze': ['froze', 'frozen'],
  'get': ['got', 'gotten'],
  'give': ['gave', 'given'],
  'go': ['went', 'gone'],
  'grow': ['grew', 'grown'],
  'hang': ['hung'],
  'have': ['had'],
  'hear': ['heard'],
  'hide': ['hid', 'hidden'],
  'hold': ['held'],
  'keep': ['kept'],
  'know': ['knew', 'known'],
  'lead': ['led'],
  'learn': ['learnt'],
  'leave': ['left'],
  'lend': ['lent'],
  'lie': ['lay', 'lain', 'lying'],
  'light': ['lit'],
  'lose': ['lost'],
  'make': ['made'],
  'mean': ['meant'],
  'meet': ['met'],
  'overhear': ['overheard'],
  'pay': ['paid'],
  'ride': ['rode', 'ridden'],
  'ring': ['rang', 'rung'],
  'rise': ['rose', 'risen'],
  'run': ['ran'],
  'say': ['said'],
  'see': ['saw', 'seen'],
  'seek': ['sought'],
  'sell': ['sold'],
  'send': ['sent'],
  'shake': ['shook', 'shaken'],
  'shoot': ['shot'],
  'sing': ['sang', 'sung'],
  'sit': ['sat'],
  'sleep': ['slept'],
  'speak': ['spoke', 'spoken'],
  'spend': ['spent'],
  'stand': ['stood'],
  'steal': ['stole', 'stolen'],
  'stick': ['stuck'],
  'strike': ['struck'],
  'swim': ['swam', 'swum'],
  'take': ['took', 'taken'],
  'teach': ['taught'],
  'tell': ['told'],
  'think': ['thought'],
  'throw': ['threw', 'thrown'],
  'understand': ['understood'],
  'wake': ['woke', 'woken'],
  'wear': ['wore', 'worn'],
  'win': ['won'],
  'write': ['wrote', 'written'],
};
