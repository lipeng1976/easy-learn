/// 变式题的**规则**：选项清洗、答案归一、本地判定。
///
/// 全部是纯函数，刻意不依赖 Flutter / 网络 / 模型 —— 因为这里每一个判断
/// 都会直接决定「学生答对还是答错」，而它又是**唯一**不经过模型的一环。
/// 错了没有任何上游能兜住：模型不会告诉你它判错了，因为它压根没参与。
///
/// 用错的方式只有一种：把做对的学生判成错的。所以每个归一化都只在
/// **能确定**的时候给结论，拿不准就返回 null，交给模型去判。
library;

import '../models/review_model.dart';

/// `A.` / `A、` / `A．` / `A)` / `A）` / `A：` 这些前缀。
///
/// 提示词里明确要求模型不要写前缀，但它仍然会写 —— 而且格式每次都不一样。
/// 与其指望提示词，不如在这里统一剥掉：选项里带不带前缀，界面渲染与
/// 答案比对都必须一致，否则会出现「看起来选对了、判成错」。
final RegExp _optionPrefix = RegExp(r'^\s*[A-Za-z]\s*[.、．)）:：]\s*');

/// 去掉选项前的字母序号。
String stripOptionPrefix(String raw) => raw.replaceFirst(_optionPrefix, '').trim();

/// 选项的展示序号：0 → `A`，1 → `B` …
String optionLetter(int index) {
  if (index < 0 || index > 25) return '';
  return String.fromCharCode(0x41 + index);
}

/// 选项是否可用：恰好 4 个、都不为空、互不重复。
///
/// 重复选项必须拦：`["2", "2", "3", "4"]` 里两个「2」意味着「选 A 还是选 B」
/// 本来就无解，无论学生点哪个都可能被判错。
bool isUsableOptions(List<String> options) {
  if (options.length != 4) return false;
  final seen = <String>{};
  for (final option in options) {
    final value = option.trim();
    if (value.isEmpty) return false;
    if (!seen.add(value)) return false;
  }
  return true;
}

/// 把选择题答案归一成 `A`–`D`。
///
/// 模型三种写法都要认：
/// 1. `A` —— 规范形式；
/// 2. `A. 2x+1=5` —— 带前缀；
/// 3. `2x+1=5` —— 直接抄了选项内容。
///
/// 第 3 种只在**唯一匹配**时才承认。两个选项文本相同（或都包含同样的
/// 片段）时返回 null —— 那种题本来就无法靠字符串判定。
String? normalizeChoiceAnswer(String raw, List<String> options) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  if (text.length == 1) {
    final letter = text.toUpperCase();
    if (letter.codeUnitAt(0) >= 0x41 && letter.codeUnitAt(0) <= 0x44) {
      return letter;
    }
  }

  final prefixed = RegExp(r'^([A-Za-z])\s*[.、．)）:：]').firstMatch(text);
  if (prefixed != null) {
    final letter = prefixed.group(1)!.toUpperCase();
    if (letter.codeUnitAt(0) >= 0x41 && letter.codeUnitAt(0) <= 0x44) {
      return letter;
    }
  }

  final cleaned = stripOptionPrefix(text);
  final matches = <int>[];
  for (var i = 0; i < options.length; i++) {
    if (options[i].trim() == cleaned) matches.add(i);
  }
  if (matches.length == 1 && matches.single < 4) {
    return optionLetter(matches.single);
  }
  return null;
}

/// 把判断题答案归一成「正确」/「错误」。
///
/// 只认**明确的**对错词。`是` / `否` 不认 —— 它们在一道
/// 「下列说法是否正确」的题里可能指的是别的东西，硬猜就是把对的判成错的。
String? normalizeJudgeAnswer(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  const yes = {'正确', '对', 'true', '√', '✓', '对的', '正确的'};
  const no = {'错误', '错', 'false', '×', '✗', 'x', '不对', '错的', '错误的'};
  final lower = text.toLowerCase();
  if (yes.contains(text) || yes.contains(lower)) return '正确';
  if (no.contains(text) || no.contains(lower)) return '错误';
  return null;
}

/// 本地判定结果。
enum LocalGrade {
  /// 答对。
  correct,

  /// 答错。
  wrong,

  /// 这道题**不能**本地判（题型不支持，或答案不是可识别的形式）。
  ///
  /// 刻意做成三态而不是 `bool?`：`null` 太容易被写成一个
  /// 「顺手当 false 用」的默认值，而这里的 false 会直接把学生判错。
  undecidable,
}

/// 选择题 / 判断题的本地判定。
///
/// 只有 [PracticeQuestionType.choice] 与 [PracticeQuestionType.judge] 可判。
/// 填空与解答一律 [LocalGrade.undecidable] —— 正确答案常有多种等价写法，
/// 硬比对会把 `0.5` 和 `1/2` 判成两个人。
LocalGrade gradeLocally({
  required PracticeQuestionType type,
  required String studentAnswer,
  required String correctAnswer,
  List<String> options = const [],
}) {
  switch (type) {
    case PracticeQuestionType.choice:
      if (!isUsableOptions(options)) return LocalGrade.undecidable;
      final picked = normalizeChoiceAnswer(studentAnswer, options);
      final expected = normalizeChoiceAnswer(correctAnswer, options);
      if (picked == null || expected == null) return LocalGrade.undecidable;
      return picked == expected ? LocalGrade.correct : LocalGrade.wrong;

    case PracticeQuestionType.judge:
      final picked = normalizeJudgeAnswer(studentAnswer);
      final expected = normalizeJudgeAnswer(correctAnswer);
      if (picked == null || expected == null) return LocalGrade.undecidable;
      return picked == expected ? LocalGrade.correct : LocalGrade.wrong;

    case PracticeQuestionType.fill:
    case PracticeQuestionType.solution:
      return LocalGrade.undecidable;
  }
}
