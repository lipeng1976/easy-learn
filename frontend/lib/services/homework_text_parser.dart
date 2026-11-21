/// 作业文本的纯规则解析。
///
/// 把一段 OCR 出来的文本按「科目：内容」切成条目，本质是确定的字符串处理。
/// **刻意不交给模型**：一是慢且贵，二是会引入不确定性 ——
/// 同一段文本两次解析出不同结果，后面所有统计都不可信。
///
/// 需要模型的能力（批改 / 判定 / 讲解 / 出题）都收敛在 `AiDataSource`，
/// 本地实现见 `SimulatedAiDataSource`。
class HomeworkTextParser {
  const HomeworkTextParser._();

  /// 按「科目：内容」切分作业文本。
  ///
  /// 识别不到任何科目时返回单条「待确认」，而不是空列表 ——
  /// 调用方一律按「至少有一条待确认任务」处理，比分别处理
  /// 「空列表」和「待确认」两种形态要少一堆分支。
  static List<Map<String, dynamic>> parse(String text) {
    final normalized = text
        .replaceAll('：', ':')
        .replaceAll('；', ';')
        .replaceAll('，', ',')
        .replaceAll('\r', '\n');
    final subjectPattern = RegExp(
      r'(语文|数学|英语|物理|化学|生物|历史|地理|政治)\s*:',
      multiLine: true,
    );
    final matches = subjectPattern.allMatches(normalized).toList();
    if (matches.isEmpty) {
      return [
        {'subject': '待确认', 'text': text.trim()},
      ];
    }

    final tasks = <Map<String, dynamic>>[];
    for (var index = 0; index < matches.length; index++) {
      final match = matches[index];
      final subject = match.group(1)!;
      final sectionEnd = index + 1 < matches.length
          ? matches[index + 1].start
          : normalized.length;
      final section = normalized.substring(match.end, sectionEnd).trim();
      final items = section
          .split(RegExp(r'[;\n]+'))
          .map((item) => item.trim())
          .map((item) => item.replaceFirst(RegExp(r'^\d+[.、)]\s*'), '').trim())
          .where((item) => item.isNotEmpty)
          .toList();
      for (final item in items) {
        tasks.add({'subject': subject, 'text': item});
      }
    }
    return tasks.isEmpty
        ? [
            {'subject': '待确认', 'text': text.trim()},
          ]
        : tasks;
  }

  /// 按科目给识别出的任务分组。
  ///
  /// 两条排序规则都是为了让**核对**这件事变便宜 —— 学生拿这张清单对着
  /// 抄作业的本子看，顺序对不上就得来回找：
  /// 1. 组间按**首次出现的顺序**，不按科目名字典序。照片上「语文」在前，
  ///    清单里就该「语文」在前，哪怕「数学」二字排序更靠前。
  /// 2. 「待确认」永远排在最后。它是待处理项，挡在真实科目前面只会碍事。
  ///
  /// 组内也去重：多张照片里有同一项作业（比如同一页拍了两遍）只会出一条。
  static List<OcrTaskGroup> groupBySubject(List<Map<String, dynamic>> tasks) {
    final order = <String>[];
    final buckets = <String, List<String>>{};
    for (final task in tasks) {
      final text = (task['text'] as String?)?.trim();
      if (text == null || text.isEmpty) continue;
      final rawSubject = (task['subject'] as String?)?.trim();
      final subject = rawSubject == null || rawSubject.isEmpty
          ? '待确认'
          : rawSubject;
      final bucket = buckets.putIfAbsent(subject, () {
        order.add(subject);
        return <String>[];
      });
      if (!bucket.contains(text)) bucket.add(text);
    }

    final sorted = order.where((subject) => subject != '待确认').toList();
    if (buckets.containsKey('待确认')) sorted.add('待确认');
    return [
      for (final subject in sorted)
        OcrTaskGroup(subject: subject, texts: buckets[subject]!),
    ];
  }
}

/// [HomeworkTextParser.groupBySubject] 的分组结果。
class OcrTaskGroup {
  const OcrTaskGroup({required this.subject, required this.texts});

  final String subject;
  final List<String> texts;

  int get count => texts.length;
}
