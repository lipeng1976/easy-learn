/// 打卡出题的 JSON 解析器。
///
/// 大模型（百炼等）返回的「出题」结果走这里统一解析。设计要点：
/// 1. 大模型只负责**产出题目内容**，不负责判分——判分由 App 本地确定性比对完成。
/// 2. 模型输出不可信，所以解析层做 5 重守卫：
///    - 剥离 ```json 围栏与前后散文
///    - 严格 JSON 解析失败即抛异常（不静默）
///    - 答案字母必须 ∈ 选项（选择题）/ 能被识别为 T/F（判断题）
///    - 选项数量守卫（选择题 >=2，判断题应为 2）
///    - LaTeX 单反斜杠丢失兜底修复（frac/times/sqrt...）
/// 3. 解析结果区分「有效题目」与「警告」，单条坏题不拖垮整批。
library;

import 'dart:convert';

/// 打卡题型。
enum CheckinQuestionType {
  choice,
  judge,
}

/// 单道打卡题。
class CheckinQuestion {
  final String stem;
  final List<String> options;

  /// 选择题为选项字母（A/B/C/D…）；判断题为 T/F。
  ///
  /// ⚠️ **交卷前绝不能进 UI**。答案随题下发的（含 [analysis]），
  /// 因为交卷那一刻要在本机判对错 —— 但答题界面只渲染题干和选项。
  /// 把 `answer` / `analysis` 画进答题分支，等于把答案摆在孩子眼前，
  /// 打卡就从「练」变成「抄」。`test/checkin_question_card_test.dart` 守着这条。
  ///
  /// 判分只走 `CheckinSubmitResult.judge`，别在页面里就地比对 ——
  /// 那样会出现第二份判分规则。
  final String answer;
  final String knowledge;
  final String? analysis;
  final CheckinQuestionType type;

  const CheckinQuestion({
    required this.stem,
    required this.options,
    required this.answer,
    required this.knowledge,
    this.analysis,
    required this.type,
  });

  bool get isJudge => type == CheckinQuestionType.judge;

  Map<String, dynamic> toJson() => {
        'stem': stem,
        'options': options,
        'answer': answer,
        'knowledge': knowledge,
        'analysis': analysis,
        'type': isJudge ? 'judge' : 'choice',
      };
}

/// 解析结果：有效题目 + 过程警告。
class CheckinParseResult {
  final List<CheckinQuestion> questions;
  final List<String> warnings;
  CheckinParseResult(this.questions, this.warnings);
}

/// 解析失败异常。携带 detail 便于上层定位（模型到底返回了什么）。
class CheckinQuestionParseException implements Exception {
  final String message;
  final Map<String, dynamic>? detail;
  const CheckinQuestionParseException(this.message, [this.detail]);
  @override
  String toString() => 'CheckinQuestionParseException: $message';
}

class CheckinQuestionParser {
  static const List<String> _choiceLetters = ['A', 'B', 'C', 'D', 'E', 'F'];
  static const Set<String> _judgeTrue = {
    'T',
    'TRUE',
    '对',
    '正确',
    '√',
    'V',
    'YES',
    'Y'
  };
  static const Set<String> _judgeFalse = {
    'F',
    'FALSE',
    '错',
    '错误',
    '×',
    'X',
    'NO',
    'N'
  };

  /// LaTeX 常见命令的兜底修复表：模型序列化把 `\frac` 写成 `frac`（单反斜杠被吞）时用。
  static const Map<String, String> _latexFix = {
    'frac': r'\frac',
    'times': r'\times',
    'sqrt': r'\sqrt',
    'left': r'\left',
    'right': r'\right',
    'cdot': r'\cdot',
    'leq': r'\leq',
    'geq': r'\geq',
    'neq': r'\neq',
    'alpha': r'\alpha',
    'beta': r'\beta',
    'pi': r'\pi',
    'sum': r'\sum',
    'int': r'\int',
  };

  /// 解析模型返回的原文（可能带 ```json 围栏或前后散文）。
  static CheckinParseResult parse(String raw,
      {String defaultKnowledge = '通用'}) {
    final cleaned = _stripFences(raw).trim();
    if (cleaned.isEmpty) {
      throw const CheckinQuestionParseException('返回内容为空');
    }
    Map<String, dynamic> root;
    try {
      root = jsonDecode(cleaned) as Map<String, dynamic>;
    } catch (_) {
      throw CheckinQuestionParseException('返回内容不是合法 JSON', {
        'rawHead':
            cleaned.length > 160 ? cleaned.substring(0, 160) : cleaned,
      });
    }

    final rawList = root['questions'] ?? root['data'] ?? root['items'];
    if (rawList is! List) {
      throw CheckinQuestionParseException('JSON 缺少 questions 数组', {
        'keys': root.keys.toList(),
      });
    }

    final questions = <CheckinQuestion>[];
    final warnings = <String>[];
    for (var i = 0; i < rawList.length; i++) {
      final item = rawList[i];
      if (item is! Map) {
        warnings.add('第${i + 1}条不是对象，已跳过');
        continue;
      }
      final q = _parseOne(Map<String, dynamic>.from(item), i,
          defaultKnowledge, warnings);
      if (q != null) questions.add(q);
    }

    if (questions.isEmpty) {
      throw CheckinQuestionParseException('未解析出任何有效题目', {
        'warnings': warnings,
      });
    }
    return CheckinParseResult(questions, warnings);
  }

  /// 去掉 ```json ... ``` 围栏与前后散文，尽量定位到第一个 { 到最后一个 }。
  static String _stripFences(String raw) {
    var s = raw.trim();
    final fence =
        RegExp(r'```(?:json)?\s*([\s\S]*?)```', caseSensitive: false);
    final m = fence.firstMatch(s);
    if (m != null) s = m.group(1)!.trim();
    final first = s.indexOf('{');
    final last = s.lastIndexOf('}');
    if (first != -1 && last != -1 && last > first) {
      s = s.substring(first, last + 1);
    }
    return s;
  }

  static CheckinQuestion? _parseOne(Map<String, dynamic> item, int i,
      String defaultKnowledge, List<String> warnings) {
    final stem = _asString(item['stem'] ?? item['question'] ?? item['题干']);
    if (stem == null || stem.isEmpty) {
      warnings.add('第${i + 1}条缺题干，已跳过');
      return null;
    }

    final rawOpts = item['options'];
    final options = <String>[];
    if (rawOpts is List) {
      for (final e in rawOpts) {
        final t = _asString(e);
        if (t != null && t.isNotEmpty) options.add(t);
      }
    }

    final rawAnswer = _asString(item['answer'] ?? item['答案']);
    if (rawAnswer == null || rawAnswer.isEmpty) {
      warnings.add('第${i + 1}条缺答案，已跳过');
      return null;
    }

    final knowledge =
        _asString(item['knowledge'] ?? item['知识点']) ?? defaultKnowledge;
    final analysis = _asString(item['analysis'] ?? item['解析']);

    final typeRaw = _asString(item['type']);
    final CheckinQuestionType type;
    if (typeRaw == 'judge' || typeRaw == '判断' || typeRaw == '判断题') {
      type = CheckinQuestionType.judge;
    } else if (typeRaw == 'choice' ||
        typeRaw == '选择' ||
        typeRaw == '选择题') {
      type = CheckinQuestionType.choice;
    } else {
      // 推断：只有两个选项且都像对/错 -> 判断
      type = (options.length == 2 &&
              _isJudgeOption(options[0]) &&
              _isJudgeOption(options[1]))
          ? CheckinQuestionType.judge
          : CheckinQuestionType.choice;
    }

    // 选项数量守卫
    if (type == CheckinQuestionType.choice && options.length < 2) {
      warnings.add('第${i + 1}条选择题选项不足，已跳过');
      return null;
    }

    final answer = _normalizeAnswer(rawAnswer, type, options, i, warnings);
    if (answer == null) return null;

    return CheckinQuestion(
      stem: _repairLatex(stem),
      options: options.map(_repairLatex).toList(),
      answer: answer,
      knowledge: knowledge,
      analysis: analysis == null ? null : _repairLatex(analysis),
      type: type,
    );
  }

  /// 归一答案：返回 'A'..'F'（选择）或 'T'/'F'（判断）；无法识别返回 null。
  static String? _normalizeAnswer(
      String raw,
      CheckinQuestionType type,
      List<String> options,
      int i,
      List<String> warnings) {
    final a = raw.trim().toUpperCase();
    if (type == CheckinQuestionType.judge) {
      if (_judgeTrue.contains(a) || _judgeTrue.contains(raw.trim())) {
        return 'T';
      }
      if (_judgeFalse.contains(a) || _judgeFalse.contains(raw.trim())) {
        return 'F';
      }
      warnings.add('第${i + 1}条判断题答案"$raw"无法识别，已跳过');
      return null;
    }

    // 选择题：允许 "B" / "B." / "B.xxx"
    String letter = a;
    if (letter.length > 1) {
      final m = RegExp(r'[A-F]').firstMatch(letter);
      letter = m?.group(0) ?? letter;
    }
    if (!_choiceLetters.contains(letter)) {
      warnings.add('第${i + 1}条答案"$raw"不是有效选项字母，已跳过');
      return null;
    }

    final hasPrefix = options.isNotEmpty &&
        RegExp(r'^[A-F][.、]\s?').hasMatch(options.first);
    final idx = _choiceLetters.indexOf(letter);
    if (hasPrefix) {
      final ok = options.any((o) => o.trim().toUpperCase().startsWith(letter));
      if (!ok) {
        warnings.add('第${i + 1}条答案$letter与任何选项前缀不符，已跳过');
        return null;
      }
    } else if (idx >= options.length) {
      warnings.add('第${i + 1}条答案$letter超出选项数(${options.length})，已跳过');
      return null;
    }
    return letter;
  }

  static bool _isJudgeOption(String s) {
    final t = s.trim().toUpperCase();
    return _judgeTrue.contains(t) || _judgeFalse.contains(t);
  }

  static String? _asString(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  /// 修复模型把单反斜杠吞掉导致的 LaTeX 损坏（frac -> \frac 等）。
  /// 仅在「前不是反斜杠且不是字母」时修复，已正确的 \frac 不会被二次破坏（幂等）。
  static String _repairLatex(String s) {
    _latexFix.forEach((bad, good) {
      final re = RegExp('(^|[^\\\\a-zA-Z])$bad(?![a-zA-Z])');
      s = s.replaceAllMapped(re, (m) => '${m.group(1)}$good');
    });
    return s;
  }
}
