/// 作业项归一化：把「识别出来的一段文字」变成「一条能照着做的事」。
///
/// 为什么需要这一层：OCR 之后拿到的只是自由文本，而系统后面所有动作
/// （按科目分组、算今日待完成、组卷、家长端按科目统计）都建立在
/// **一条 = 一件事** 这个前提上。前提一旦被破坏，出错的地方离现场很远 ——
/// 清单里少了一条，看起来就像学生自己漏抄了。
///
/// **刻意用纯规则、不交给模型**：同一段文本两次归一化必须得到同样的结果。
/// 模型负责「看见」（版式信息只有它有），这一层负责「定形」（必须是确定的）。
/// 换个说法：模型给的是候选，这里做的是收敛。
///
/// 需要模型能力的地方（批改 / 判定 / 讲解 / 出题）仍然收敛在 `AiDataSource`。
class HomeworkItemNormalizer {
  const HomeworkItemNormalizer._();

  /// 科目没定下来时的取值。
  ///
  /// 它同时是「模型没判断出来」和「学生还没选」两种状态的展示值 ——
  /// 刻意不区分：这两种情况学生要做的事完全一样（对着照片看一眼再选）。
  static const String unknownSubject = '待确认';

  /// 能作为一门课出现的科目名。
  ///
  /// 与 `HomeworkTextParser` 的科目正则保持同一集合 —— 那边认出来的科目
  /// 必须能在这里被认作「已知」，否则解析出的「历史」到了界面上会变成一个
  /// 下拉框里没有的怪值。
  static const List<String> subjectNames = [
    '语文',
    '数学',
    '英语',
    '物理',
    '化学',
    '生物',
    '历史',
    '地理',
    '政治',
    '其他',
  ];

  /// 界面上可供选择的科目，顺序即展示顺序：先「待确认」（待办要显眼），再按常用度。
  static const List<String> pickableSubjects = [unknownSubject, ...subjectNames];

  /// 拉丁文/英文写法 → 科目名。
  ///
  /// 单独一张表而不是靠模糊匹配：模型偶尔会用英文回（`Math` / `English`），
  /// 而模糊匹配一旦猜错，学生会看到一门错误的课而且不会怀疑它。
  static const Map<String, String> _latinSubjects = {
    'chinese': '语文',
    'math': '数学',
    'maths': '数学',
    'mathematics': '数学',
    'english': '英语',
    'physics': '物理',
    'chemistry': '化学',
    'biology': '生物',
    'history': '历史',
    'geography': '地理',
    'politics': '政治',
  };

  /// 科目名后面跟着的这些词是修饰，不是科目的一部分。
  static final RegExp _subjectSuffix = RegExp(r'(作业|功课|练习|试卷|卷|课|本)+$');

  /// 把模型或正则给出的科目名收敛成规范名。
  ///
  /// 不收敛的代价是**分散**：模型今天回「数学作业」、明天回「数学」，
  /// 于是同一门课在按科目分组、按科目筛错题、家长端按科目看统计时
  /// 会被算成两门，而每一处单看都「没错」。
  ///
  /// 认不出来的名字**原样保留**（例如「科学」），不塞进「其他」：
  /// 收敛是为了合并同义写法，不是为了消灭没见过的科目。
  /// 丢掉的名称无法恢复，而多出来的一个选项最多是没人选。
  static String canonicalSubject(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return unknownSubject;

    // 整体标签落到单条上就等于没定下来。
    if (text == '多科目' || text == '未知' || text == '不确定' || text == '未定') {
      return unknownSubject;
    }

    // 「英语（Unit 2）」→「英语」：括号里是范围，不是科目名。
    final withoutTail = text
        .replaceFirst(RegExp(r'[（(][^）)]*[)）]\s*$'), '')
        .trim();
    if (withoutTail.isNotEmpty) text = withoutTail;

    final latin = _latinSubjects[text.toLowerCase()];
    if (latin != null) return latin;

    final stripped = text.replaceFirst(_subjectSuffix, '').trim();
    if (stripped.isEmpty) return text;
    return _latinSubjects[stripped.toLowerCase()] ?? stripped;
  }

  /// 文本以「科目：」开头时把科目取出来，返回 (科目, 剩余正文)。
  ///
  /// 用来兜住模型一种很常见的输出：`subject` 填了「待确认」，
  /// 内容却老老实实写着「数学：练习册P12」。同一张照片里明明认出来了，
  /// 却当成没认出来，学生会看到一屏「待确认」而不知道该选什么。
  ///
  /// 前缀不是一个已知科目时**原样返回**：像「要求：朗读课文」这种，
  /// 把「要求」当科目只会平白多出一门不存在的课。
  static (String?, String) splitSubjectPrefix(String text) {
    final match = RegExp(
      r'^\s*([\u4e00-\u9fa5A-Za-z]{1,6})\s*[:：]\s*',
    ).firstMatch(text);
    if (match == null) return (null, text);
    final candidate = canonicalSubject(match.group(1)!);
    if (!subjectNames.contains(candidate)) return (null, text);
    return (candidate, text.substring(match.end));
  }

  /// 行首/分隔符之后成组出现的序号：`1.` `2、` `(3)` `①`。
  ///
  /// 序号前面**必须**是行首或分隔符。少了这条约束，「做1、2、3题」会被
  /// 当成三条作业 —— 那串序号是内容的一部分，拆开就凭空多出两条待办。
  ///
  /// 用**捕获组**记住那个分隔符（group 1）：后续按它切分时要把分隔符
  /// 从片段里去掉，否则第一个片段的尾巴上会挂着「，」这类字符。
  ///
  /// 序号后**不吞尾随空格**：吞了的话，`1.  2. ` 里第一个 marker 会一路
  /// 吃掉中间的空格，第二个 marker 的起点被推到序号之后，
  /// 于是切出来的片段只剩一个孤零零的 `2.`。空格留给片段自己 trim。
  static final RegExp _listMarkers = RegExp(
    r'(^|[\s，,、；;：:])(?:[（(]\s*\d{1,2}\s*[)）]|\d{1,2}\s*[.、)）]|[①-⑳])',
  );

  /// 去掉条目开头的序号（`1.` / `（2）` / `③`）。
  ///
  /// 序号后紧跟数字时不认（`3.14159` / `1.5小时`）：那不是序号，是数值。
  static final RegExp _leadingMarker = RegExp(
    r'^(?:[（(]\s*\d{1,2}\s*[)）]|\d{1,2}\s*[.、)）](?!\d)|[①-⑳])\s*',
  );

  static String _stripLeadingMarker(String text) =>
      text.replaceFirst(_leadingMarker, '').trim();

  /// 照片上学生把几个题号连写成一串时的那串数字：`1.2.37`。
  ///
  /// 三条约束缺一不可：
  /// - **独立成词**（前后不是数字/字母/点）—— 否则 `P27` 尾巴、`1.2.3.4` 的片段都会被咬。
  /// - **至少三段**（两个点）—— 两段的点分数字更可能是小数（`3.14`、`1.5`），
  ///   三段以上在作业语境里人一眼就知道是题号连写。
  /// - **每段至多两位** —— `3.14159` 那种长尾自然被挡在外面。
  static final RegExp _serialRun = RegExp(
    r'(?<![0-9A-Za-z.])(\d{1,2}(?:[.．]\d{1,2}){2,})(?![0-9A-Za-z.])',
  );

  /// 行尾的一串题号：`1、2、3、7`。
  ///
  /// 认它是因为 `_listMarkers` **只看得见「数字 + 顿号」**，会把这种串
  /// 当成列表切碎（实测 `1、2、3、7` 会被切成一条 `、7`）——
  /// 而它其实是**内容本身**。
  static final RegExp _serialTail = RegExp(
    r'\d{1,3}(?:\s*[、,，.．]\s*\d{1,3})+\s*$',
  );

  /// 把「题号连写」读成列举：`1.2.37` → `1、2、3、7`。
  ///
  /// **为什么不能交给模型**：2026-09-29 同一张照片实测 25 次，
  /// 模型自己改写这串时有 **6 次把 `7` 丢了**（写成 `1、2、3题`）。
  /// 这是确定能算对的事，换成「大概率对」就是白丢准确率 ——
  /// 而且丢的那一题没有任何机制能发现。
  ///
  /// **逐位读**（`37` → `3`、`7`）而不是按段读成「第 37 题」：
  /// 用户在 2026-09-29 明确了这个口径 —— 原图写的是 `1.2.37`，
  /// 意思就是第 1、2、3、7 题。唯一的例外是**含 0 的两位段**
  /// （`10`、`20`）：题号从 1 起，所以那必然是「第十题」「第二十题」，
  /// 拆开就会凭空造出一个「第 0 题」。
  static String expandSerialRuns(String text) {
    return text.replaceAllMapped(_serialRun, (match) {
      final numbers = <String>[];
      for (final segment in match.group(1)!.split(RegExp(r'[.．]'))) {
        if (segment.length >= 2 && segment.contains('0')) {
          numbers.add(segment);
        } else {
          numbers.addAll(segment.split(''));
        }
      }
      return numbers.join('、');
    });
  }

  /// 这一段是不是「标题」而不是「一项作业」。
  ///
  /// 序号前面那截文字（`今天的作业：1. …` 里的「今天的作业」）有两种可能：
  /// 要么是标题，要么真是一件作业。**只有明确的标题形态才丢**，
  /// 其余一律保留 —— 丢内容是不可恢复的，而多一条学生能自己删掉。
  static bool _looksLikeHeading(String head) {
    // 以冒号结尾：`今天的作业：`。
    if (head.endsWith('：') || head.endsWith(':')) return true;
    // 「今日/今天/明天 + 作业/任务」这类整体标题。
    return RegExp(r'^(?:今日|今天|明天|本[周日])?的?(?:作业|任务|清单)$').hasMatch(head);
  }

  /// 把一条可能塞进了多件事的文本拆成真正的「一条一件事」。
  ///
  /// 存在的理由：模型多数时候会自己拆好，但偶尔会把整行原样丢回来
  /// （`数学：1.练习册P12 2.口算20题`）。不拆的话，学生看到的是一条
  /// 正文里带两个序号的怪作业，而按条计完成度、按科目统计全都要错。
  ///
  /// **拆分是有门槛的**：至少出现两个序号才按列表拆。只有一个时更可能是
  /// 正文里的点（`练习册P12.`），拆开反而把一条完整的作业切成两条残句。
  static List<String> splitIntoItems(String text) {
    final normalized = text.replaceAll('\r', '\n').trim();
    if (normalized.isEmpty) return const [];

    final out = <String>[];
    for (final block in normalized.split(RegExp(r'[\n；;]+'))) {
      final line = block.trim();
      if (line.isEmpty) continue;

      // 整行以「题号列举」收尾（`学法P27 1、2、3、7`）时整行保留。
      //
      // 那串数字**本身就是内容**，而 `_listMarkers` 只看得见「数字 + 顿号」，
      // 会把它当列表切碎 —— 实测 `1、2、3、7` 会被切成一条 `、7`。
      // 还要看尾巴**前面**有没有别的序号：`1. 练习册P12 2. 口算1、2、3`
      // 尾巴前面真站着两个序号，那才是列表，不能短路。
      //
      // 位置必须在下面取 markers 之前 —— 短路的意思就是「不参与列表判定」。
      final serialTail = _serialTail.firstMatch(line);
      if (serialTail != null &&
          !_listMarkers.hasMatch(line.substring(0, serialTail.start))) {
        out.add(line);
        continue;
      }

      // 整体只有一个序号时，剥掉它整行成一条 —— 包括「1.」后面空无一物
      // 的情况：剥完是空，这一行就不该产出任何东西，而不是留下一个「1.」。
      final markers = _listMarkers.allMatches(line).toList();
      if (markers.length < 2) {
        final single = _stripLeadingMarker(line);
        if (single.isNotEmpty) out.add(single);
        continue;
      }

      // 第一个序号之前的字不能直接丢 —— 丢了就是静默少内容。
      // 但明显是标题的（「今天的作业：」）要丢，它本身不是一项作业。
      // 冒号会被 `_listMarkers` 当作分隔符捕走，所以要连同它一起取出来判。
      final headRaw = line.substring(0, markers.first.start);
      final head = headRaw.trim();
      final headWithColon =
          (head + line.substring(markers.first.start, markers.first.end)).trim();
      final isHeading = _looksLikeHeading(head) || _looksLikeHeading(headWithColon);
      if (head.isNotEmpty && !isHeading) {
        final cleaned = _stripLeadingMarker(head);
        if (cleaned.isNotEmpty) out.add(cleaned);
      }

      for (var i = 0; i < markers.length; i++) {
        final match = markers[i];
        // 片段从「序号本身之后」开始。终点停在**下一个序号的分隔符之前**
        // （而不是下一个序号之前）—— 分隔符是 `，`、空格、冒号这类字符，
        // 留在片段里会让「做1，2题」被切成「做，」这种带标点的残句。
        final start = match.end;
        final end = i + 1 < markers.length
            ? markers[i + 1].start + markers[i + 1].group(1)!.length
            : line.length;
        if (end <= start) continue;
        final piece = _stripLeadingMarker(line.substring(start, end).trim());
        if (piece.isNotEmpty) out.add(piece);
      }
    }
    return out;
  }

  /// 剥掉序号、分隔符、空白之后，还剩下真正的字吗。
  ///
  /// 用来区分「拆空了是因为原文没内容」（`1.  2.`）和
  /// 「拆空了是因为这段就该丢了」（`数学：`）。
  static bool _hasContentBeyondMarkers(String text) {
    final stripped = text
        .replaceAll(_leadingMarker, '')
        .replaceAll(_listMarkers, '')
        .replaceAll(RegExp(r'[\s，,、；;：:。.]'), '')
        .trim();
    return stripped.isNotEmpty;
  }

  /// 归一化一条任务，可能变成零条、一条或多条。
  ///
  /// 三条规则：文本自带的科目前缀优先于 `subject` 字段 → 按列表拆开 →
  /// 逐条收敛科目。返回列表而不是单条，是因为「一条变三条」是本层的
  /// 正常产出，逼调用方处理比让它在别处悄悄发生要好。
  static List<Map<String, dynamic>> normalizeTask(Map<String, dynamic> task) {
    final rawText = (task['text'] as String? ?? '').trim();
    if (rawText.isEmpty) return const [];
    final uncertain = task['uncertain'] == true;

    // 以正文里的科目前缀为准：`subject` 说「待确认」而正文写着「数学：」
    // 是很常见的组合，用正文能救回一条。
    final (prefixSubject, body) = splitSubjectPrefix(rawText);
    final subject = prefixSubject ?? canonicalSubject(task['subject'] as String? ?? '');

    final pieces = splitIntoItems(body);
    // 拆完是空的说明正文本身只剩一个科目前缀，保留原文总比丢掉好 ——
    // 学生能看见并删掉一条没用的条目，看不见的地方少内容他无从发现。
    //
    // 但**原文本身就只剩序号时不能退**：`1.  2.` 剥掉序号后一个字都不剩，
    // 退回原文只会造出一条名为「1.  2.」的假作业，而它是纯粹的噪音。
    final texts = pieces.isNotEmpty
        ? pieces
        : (_hasContentBeyondMarkers(rawText) ? [rawText] : const <String>[]);
    if (texts.isEmpty) return const [];

    // 模型给的耗时**只在「一条还是一条」时透传**。
    //
    // 拆成多条时这个数描述的是整块文字的量（`1.练习册P12 2.口算20题` 的
    // 30 分钟是两件事合起来的时间），照抄给每条会让总时长凭空翻倍，
    // 平分又没有依据 —— 不如留给各自按标题重估。
    //
    // 之前这里漏掉了这个字段，后果是：模型明明看得见「一张卷子两面」这种
    // 规则数不出来的量，客户端却只拿得到按标题兜底的整数，
    // 一路白给。范围校验放在这一层是因为它可能被单独调用，
    // 不能假设上游（HTTP 解析）已经挡过。
    final suggestedMinutes = texts.length == 1
        ? _plausibleMinutes(task['estimatedMinutes'])
        : null;

    return [
      for (final text in texts)
        <String, dynamic>{
          'subject': subject,
          // 题号连写在这里读成列举（`1.2.37` → `1、2、3、7`）。
          //
          // 必须放在**最后一步**：展开出来的顿号会被 `_listMarkers`
          // 当成列表分隔符，先展开就会把一条作业切成四条待办。
          'text': expandSerialRuns(text),
          if (uncertain) 'uncertain': true,
          // `?` 的语义正是「值为 null 就整个 entry 不带」——
          // 比写成 if 判断更贴本意，也不会漏掉某个分支。
          'estimatedMinutes': ?suggestedMinutes,
        },
    ];
  }

  /// 模型给的耗时建议是否可信。
  ///
  /// 域与网关 schema 一致（5–120 的整数），但这里仍要挡一道：
  /// schema 是服务端的事，客户端不能假设它一定生效。
  /// 不合理就**整条丢掉**（连字段都不带）而不是夹到边界 ——
  /// 带个夹过的数过去，看起来就像模型真的这么估过。
  static int? _plausibleMinutes(Object? raw) {
    if (raw is! num) return null;
    final value = raw.round();
    return value >= 5 && value <= 120 ? value : null;
  }

  /// 去重键：科目 + 抹平空白与标点后的正文。
  ///
  /// 不能直接比字符串：多张照片拍到同一页时，「练习册 P12」和「练习册P12」
  /// 会被当成两条，而学生在清单上看到的是同一项作业出现了两次 ——
  /// 他会以为老师布置了两遍，然后照着做两遍。
  static String dedupeKey(Map<String, dynamic> task) {
    final subject = (task['subject'] as String? ?? '').trim();
    final text = (task['text'] as String? ?? '')
        .toLowerCase()
        .replaceAll(
          RegExp(r'[\s，,。.、；;：:!！?？~～\-—_（）()【】\[\]"“”‘’]'),
          '',
        );
    return '$subject\u0000$text';
  }

  /// 把一条任务并入清单：新的追加，重复的**只补一次「没把握」标记**。
  ///
  /// 重复时宁可保留谨慎：两张照片里同一项，一张标了没把握、一张没标，
  /// 记成没把握最多让学生多看一眼；记成没问题，那个错字就过去了。
  static void mergeInto(
    List<Map<String, dynamic>> acc,
    Map<String, dynamic> task,
  ) {
    final key = dedupeKey(task);
    for (final existing in acc) {
      if (dedupeKey(existing) != key) continue;
      if (task['uncertain'] == true) existing['uncertain'] = true;
      return;
    }
    acc.add(task);
  }

  /// 批量归一化 + 去重。多张照片的识别结果都从这里过一遍。
  static List<Map<String, dynamic>> normalizeAll(
    List<Map<String, dynamic>> tasks,
  ) {
    final out = <Map<String, dynamic>>[];
    for (final task in tasks) {
      for (final item in normalizeTask(task)) {
        mergeInto(out, item);
      }
    }
    return out;
  }

  /// 下拉框里能选哪些科目：规范清单 ∪ 这一批里实际出现的。
  ///
  /// 取并集不是为了灵活，是为了**不崩**：`DropdownButtonFormField` 要求
  /// `initialValue` 必须在 `items` 里，而识别出的科目是自由字符串
  /// （模型可能给「科学」这种清单外的名字）。只给固定清单的话，
  /// 遇到清单外的科目会直接断言失败；release 下不崩，但输入框显示为空，
  /// 学生既看不到识别出的科目、也选不回它。
  static List<String> subjectOptionsFor(Iterable<String> presentSubjects) {
    final options = [...pickableSubjects];
    for (final raw in presentSubjects) {
      final subject = canonicalSubject(raw);
      if (subject.isEmpty || options.contains(subject)) continue;
      options.add(subject);
    }
    return options;
  }
}
