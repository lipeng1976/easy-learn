import 'dart:math' as math;

import '../models/review_model.dart';
import 'ai_data_source.dart';

/// 组卷结果：卷头 + 卷内快照。
class ComposedPaper {
  final ReviewPaper paper;
  final List<ReviewPaperItem> items;

  const ComposedPaper({required this.paper, required this.items});
}

/// 毕业判定结论。
class GraduationDecision {
  /// 是否通过本轮（本次作答是否正确）。
  final bool passed;

  /// 是否达到毕业条件、可以移出错题库。
  final bool mastered;

  /// 本次达成/需要的连续通过轮数。
  final int streak;
  final int requiredStreak;

  /// 给学生看的一句话说明。
  final String reason;

  const GraduationDecision({
    required this.passed,
    required this.mastered,
    required this.streak,
    required this.requiredStreak,
    required this.reason,
  });
}

/// 薄弱知识点。
class WeakKnowledgePoint {
  final String name;
  final String subject;

  /// 该知识点下所有错题的累计错误次数。
  final int wrongCount;
  final int mistakeCount;

  const WeakKnowledgePoint({
    required this.name,
    required this.subject,
    required this.wrongCount,
    required this.mistakeCount,
  });
}

/// 周期报告（周报 / 月报）的完整口径。
///
/// `ReviewSummary` 是为了**落库**而存在的：字段少、能塞进一张表。
/// 但报告页要讲的远不止那几个数——这周哪几天真的坐下来复习了、
/// 分科通过率差多少、哪些是「自己说会了」而不是「判出来会了」。
/// 这些都算完就丢、不入库，所以需要一个比 `ReviewSummary` 更宽的载体。
///
/// 两者是「快照」与「存档」的关系：[toSummary] 负责把宽口径压成可落库的窄口径。
class PeriodReport {
  const PeriodReport({
    required this.scope,
    required this.scopeKey,
    required this.title,
    required this.start,
    required this.end,
    this.attemptCount = 0,
    this.passCount = 0,
    this.failCount = 0,
    this.graduatedCount = 0,
    this.selfMasteredCount = 0,
    this.paperAttemptCount = 0,
    this.practiceAttemptCount = 0,
    this.explainedCount = 0,
    this.paperIssueCount = 0,
    this.paperGradedCount = 0,
    this.poolRemain = 0,
    this.bestStreak = 0,
    this.activeDays = 0,
    this.passRate = 0,
    this.weakPoints = const [],
    this.subjectAttempts = const {},
    this.subjectPasses = const {},
    this.highlights = const [],
    this.suggestions = const [],
  });

  final SummaryScope scope;

  /// 周期键：周报 `2026-W38`，月报 `2026-09`。同一周期只会有一份报告。
  final String scopeKey;
  final String title;
  final DateTime start;
  final DateTime end;

  /// 期内作答次数（纸卷判定 + 纸卷自评 + 举一反三，每次作答算一次）。
  final int attemptCount;
  final int passCount;
  final int failCount;

  /// 期内**通过检查**毕业的题数（不含自评「标记掌握」）。
  final int graduatedCount;

  /// 期内自评标记掌握的题数。单列出来是为了能说清「掌握率为什么没涨」。
  final int selfMasteredCount;

  final int paperAttemptCount;
  final int practiceAttemptCount;

  /// 期内看讲解的次数。讲解不构成毕业，只是过程指标。
  final int explainedCount;

  /// 期内生成 / 批改的资料数。
  final int paperIssueCount;
  final int paperGradedCount;

  /// 期末仍在待复习池中的题数。
  final int poolRemain;

  /// 期内单题最长的连续通过轮数。
  final int bestStreak;

  /// 期内真正有作答记录的天数。
  final int activeDays;

  final double passRate;
  final List<WeakKnowledgePoint> weakPoints;
  final Map<String, int> subjectAttempts;
  final Map<String, int> subjectPasses;
  final List<String> highlights;
  final List<String> suggestions;

  /// 「自己说会了」在全部掌握里的占比。这个数字高得离谱，说明闭环在空转。
  double get selfMasteredRatio {
    final total = graduatedCount + selfMasteredCount;
    return total == 0 ? 0 : selfMasteredCount / total;
  }

  /// 压成可落库的窄口径。
  ReviewSummary toSummary({required String studentId, required DateTime now}) =>
      ReviewSummary(
        id: 'sum_${studentId}_$scopeKey',
        studentId: studentId,
        scope: scope,
        scopeKey: scopeKey,
        totalCount: attemptCount,
        passCount: passCount,
        masteredCount: graduatedCount,
        remainCount: poolRemain,
        passRate: passRate,
        weakPoints: weakPoints.map((e) => e.name).toList(),
        body: body,
        generatedAt: now,
      );

  /// 纯文本报告。既用于页面正文，也用于家长端推送与复制分享。
  String get body {
    // 判断「这一周期毫无动作」只看**周期内的行为**，不看池子里还剩多少题：
    // 池子有几道是当前状态，不是本周做了什么。把池子算进来的话，
    // 一个本周完全没动、但池里恰好有 2 道题的学生会看到
    // 「完成 0 次作答，通过率 0%」——数字没错，但没说人话。
    if (attemptCount == 0 &&
        paperIssueCount == 0 &&
        paperGradedCount == 0 &&
        explainedCount == 0) {
      return '$title：这一周期还没有复习记录。'
          '先完成作业批改收集错题，再生成一份重做卷开始第一轮。';
    }

    final buffer = StringBuffer()
      ..writeln(
        '$title（${_formatDay(start)} - ${_formatDay(end)}）：'
        '完成 $attemptCount 次作答，通过 $passCount 次，'
        '通过率 ${(passRate * 100).round()}%。',
      );

    if (graduatedCount > 0 || selfMasteredCount > 0) {
      buffer.writeln(
        '其中 $graduatedCount 道通过检查移出错题库'
        '${selfMasteredCount > 0 ? '，另有 $selfMasteredCount 道为自评掌握（不计入通过率）' : ''}。',
      );
    } else {
      buffer.writeln('这一周期还没有错题毕业，先看讲解再做一轮。');
    }

    if (explainedCount > 0) {
      buffer.writeln('共查看 $explainedCount 次讲解。');
    }
    if (paperIssueCount > 0) {
      buffer.writeln(
        '生成资料 $paperIssueCount 份'
        '${paperGradedCount > 0 ? '，完成批改 $paperGradedCount 份' : ''}。',
      );
    }
    if (weakPoints.isNotEmpty) {
      buffer.writeln(
        '需要重点突破：${weakPoints.map((e) => e.name).take(3).join('、')}。',
      );
    }
    buffer.write('当前错题库还有 $poolRemain 道待复习。');
    return buffer.toString();
  }

  static String _formatDay(DateTime value) => '${value.month}月${value.day}日';
}

/// 复习闭环的领域服务：**组卷选题、毕业判定、报告聚合**。
///
/// 刻意不碰 UI 与持久化：这三个都是纯函数式的决策，
/// 一旦和 GetX 的 Rx / sqflite 混在一起，就没法单独测了。
/// 闭环最容易出错的地方恰恰是判定规则（做对了到底算不算毕业），
/// 所以规则必须能脱离界面被断言。
class ReviewService {
  ReviewService._();

  static int _seq = 0;

  /// 本地 ID 生成。时间戳 + 自增序号，避免同一毫秒内批量写入时撞 ID
  /// （组卷一次要写十几条快照，纯时间戳会重）。
  static String newId(String prefix) =>
      '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';

  /// 错 3 次及以上的题，要求连续 2 轮通过才毕业。
  static const int repeatedWrongThreshold = 3;

  /// 反复错的题需要的连续通过轮数。
  static const int requiredStreakForRepeatedWrong = 2;

  /// 单份资料最多收录的题量。一次印 30 道题没人做得完，
  /// 卷子太长只会让闭环死在「印了但没做」。
  static const int defaultPaperLimit = 10;

  /// 组卷：从错题池挑题，并把题目**冻结**成快照。
  ///
  /// 只挑 `pending`（还在池中、没有被别的卷占用）的题：
  /// 允许 `reviewing`/`verifying` 的题再进新卷，会让同一道题同时躺在两份卷子上，
  /// 学生做完第一份、第二份就变成了幽灵题。
  static Future<ComposedPaper> compose({
    required List<ReviewMistake> pool,
    required String studentId,
    required String paperId,
    required DateTime now,
    required AiDataSource ai,
    List<String>? mistakeIds,
    String subject = '',
    int round = 1,
    int limit = defaultPaperLimit,
  }) async {
    final explicit = mistakeIds != null && mistakeIds.isNotEmpty;
    final candidates = pool
        .where((mistake) => explicit || mistake.state == ReviewState.pending)
        .where((mistake) {
          if (explicit) return mistakeIds.contains(mistake.id);
          if (subject.isEmpty || subject == '全部') return true;
          return mistake.subject == subject;
        })
        .toList();

    // 先按薄弱度排（错得多、最近错的优先），同分时按入池时间排，
    // 保证「先错的那道先被复习」，而不是让新错题一直插队。
    candidates.sort((a, b) {
      final byWeakness = b.weaknessScore(now).compareTo(a.weaknessScore(now));
      if (byWeakness != 0) return byWeakness;
      return a.createdAt.compareTo(b.createdAt);
    });

    final picked = candidates.take(math.max(limit, 0)).toList();

    final items = <ReviewPaperItem>[];
    // 参考答案在组卷时冻结：纸质卷印出去之后，学生手上的纸和库里的题就分叉了，
    // 批改时再实时生成的话，题目一改答案就对不上。
    //
    // 走批量接口而不是逐题调用：云端实现是一次 HTTP 往返，
    // 一页 20 道题逐条请求就是 20 次往返的延迟，而且每次都要重付一遍
    // 同样的提示词输入 token。这里把「要哪些答案」一次交出去，
    // 由 `AiDataSource` 自己决定是压成一次请求还是逐条算。
    final queries = [
      for (final mistake in picked)
        ReferenceQuery(
          subject: mistake.subject,
          knowledgePoint: mistake.knowledgePoint,
          // 带上题目原文：同名知识点下的题目差异可能很大，
          // 只给知识点名，模型只能给一份泛泛的解题要点。
          questionTitle: mistake.title,
        ),
    ];
    final answerKeys = await ai.referenceAnswersFor(queries);
    for (var i = 0; i < picked.length; i++) {
      final mistake = picked[i];
      items.add(
        ReviewPaperItem(
          id: '${paperId}_i$i',
          paperId: paperId,
          mistakeId: mistake.id,
          subject: mistake.subject,
          knowledgePoint: mistake.knowledgePoint,
          questionTitle: mistake.title,
          questionBody: _questionBody(mistake),
          originalAnswer: mistake.originalAnswer,
          wrongReason: mistake.wrongReason,
          // 契约要求批量实现覆盖全部入参；`?? ''` 只是防御 ——
          // 但真落到空串上时，判定会走 inconclusive 而不是判「错」，
          // 学生不会被一道没有答案的题卡住毕不了业。
          answerKey: answerKeys[queries[i].key] ?? '',
          sortOrder: i,
        ),
      );
    }

    final knowledgePoints = <String>[];
    for (final item in items) {
      if (item.knowledgePoint.isNotEmpty &&
          !knowledgePoints.contains(item.knowledgePoint)) {
        knowledgePoints.add(item.knowledgePoint);
      }
    }
    final subjects = items.map((e) => e.subject).toSet();
    final subjectLabel = subjects.length == 1 && subjects.first.isNotEmpty
        ? subjects.first
        : (subjects.isEmpty ? '错题' : '多科目');

    return ComposedPaper(
      paper: ReviewPaper(
        id: paperId,
        studentId: studentId,
        // 卷名带生成日期，不再用「第 N 轮」——那个标志学生看不懂（它其实
        // 是「这是错题库里第几份资料」，和这道题重做几轮没关系）。日期能让人
        // 一眼分清「哪天的卷子」，和列表里「10月22日」这类时间戳对得上。
        title: '$subjectLabel错题重做卷 · ${_monthDay(now)}',
        subject: subjects.length == 1 ? subjects.first : '',
        knowledgePoints: knowledgePoints,
        status: PaperStatus.draft,
        itemCount: items.length,
        createdAt: now,
      ),
      items: items,
    );
  }

  static String _monthDay(DateTime value) =>
      '${value.month}月${value.day}日';

  /// 卷面题干。
  ///
  /// ⭐ 2026-10-21 改：**优先用原题**（`mistake.questionBody`）。
  ///
  /// 之前这里只写「重新独立完成这道题，写出完整过程。」+ 上次的答案 + 上次的错因，
  /// 理由写在注释里是「库里没有真实题干（一期是模拟批改）」—— 那个前提早就不成立了：
  /// AI 批改产出的错题带着 `item.question`，手工录入也存了 OCR 出来的题干。
  /// 结果是学生拿到一张**没有题目**的卷子，只知道「上次错了」，不知道错在哪道题上。
  ///
  /// 「上次的答案 / 错因」不再拼进题干：它们在 [ReviewPaperItem.originalAnswer] /
  /// [ReviewPaperItem.wrongReason] 里本来就有，由渲染层单独用弱化样式排 ——
  /// 拼进题干会让它们和题目正文混成一段，印出来分不清哪句是题。
  static String _questionBody(ReviewMistake mistake) {
    final original = mistake.questionBody.trim();
    if (original.isNotEmpty) return original;
    // 早期错题确实没有题干（只有标签），这时给一句可执行的要求，
    // 总比印一个空白页好 —— 但这是**兜底**，不是常态。
    return '重新独立完成这道题，写出完整过程。';
  }

  /// 毕业判定。
  ///
  /// 基础规则是「通过一次即毕业」——这符合「做对就从错题库移出」的直觉。
  /// 但错 3 次以上的题要求**连续 2 轮通过**：反复错的题通常是概念性问题，
  /// 蒙对一次的概率不低，放过它等于把假闭环写进数据。
  ///
  /// [history] 必须是本次之前的历史作答（按时间升序），不含本次。
  static GraduationDecision judge({
    required ReviewMistake mistake,
    required bool passed,
    required List<ReviewAttempt> history,
  }) {
    final required = mistake.wrongCount >= repeatedWrongThreshold
        ? requiredStreakForRepeatedWrong
        : 1;

    if (!passed) {
      return GraduationDecision(
        passed: false,
        mastered: false,
        streak: 0,
        requiredStreak: required,
        reason: '本次未通过，错误次数 +1，已回到错题库待复习。',
      );
    }

    var streak = 1;
    for (final attempt in history.reversed) {
      if (!attempt.correct) break;
      streak++;
    }

    final mastered = streak >= required;
    return GraduationDecision(
      passed: true,
      mastered: mastered,
      streak: streak,
      requiredStreak: required,
      reason: mastered
          ? (required == 1
                ? '通过检查，已从错题库移出。'
                : '连续 $streak 轮通过，确认掌握，已从错题库移出。')
          : '本轮通过，但这道题反复错，需要连续 $required 轮通过才移出错题库'
                '（当前 $streak/$required）。',
    );
  }

  /// 单卷报告。数字必须自洽：题量 = 通过 + 未通过。
  static ReviewSummary buildPaperReport({
    required ReviewPaper paper,
    required List<ReviewPaperItem> items,
    required DateTime now,
  }) {
    final pass = items
        .where((item) => item.result == PaperItemResult.correct)
        .length;
    final fail = items
        .where((item) => item.result == PaperItemResult.wrong)
        .length;
    final pending = items.length - pass - fail;

    final weak = <String>[];
    for (final item in items) {
      if (item.result != PaperItemResult.wrong) continue;
      final key = item.knowledgePoint.isEmpty
          ? '${item.subject}·未标注知识点'
          : item.knowledgePoint;
      if (!weak.contains(key)) weak.add(key);
    }

    final rate = items.isEmpty ? 0.0 : pass / items.length;
    return ReviewSummary(
      id: 'sum_${paper.id}',
      studentId: paper.studentId,
      scope: SummaryScope.paper,
      scopeKey: paper.id,
      totalCount: items.length,
      passCount: pass,
      masteredCount: pass,
      remainCount: fail + pending,
      passRate: rate,
      weakPoints: weak,
      body: _paperReportBody(paper, pass, fail, pending, rate, weak),
      generatedAt: now,
    );
  }

  static String _paperReportBody(
    ReviewPaper paper,
    int pass,
    int fail,
    int pending,
    double rate,
    List<String> weak,
  ) {
    final buffer = StringBuffer()
      ..writeln('《${paper.title}》共 ${paper.itemCount} 道题。')
      ..writeln('通过 $pass 道，未通过 ${fail + pending} 道，通过率 '
          '${(rate * 100).round()}%。');

    if (fail + pending == 0) {
      buffer.write('这一轮全部做对，涉及的错题已从错题库移出。');
    } else if (weak.isEmpty) {
      buffer.write('未通过的题还需要重做一轮。');
    } else {
      buffer.write('还没过关的知识点：${weak.join('、')}。'
          '建议先看这几个知识点的讲解，再做下一轮。');
    }
    return buffer.toString();
  }

  /// 错题生命周期时间线——「有过程」这件事的落点。
  ///
  /// 它回答的是家长和老师最想知道的三个问题：
  /// 这道题什么时候错的、来源是哪次作业、中间到底复习过几轮。
  static List<MistakeTimelineEntry> timeline({
    required ReviewMistake mistake,
    required List<ReviewAttempt> attempts,
    required List<ExplainRecord> explanations,
  }) {
    final entries = <MistakeTimelineEntry>[
      MistakeTimelineEntry(
        at: mistake.createdAt,
        title: '加入错题库',
        detail: mistake.sourceHomeworkTitle.isEmpty
            ? '来自作业批改'
            : '来自《${mistake.sourceHomeworkTitle}》'
                  '${mistake.knowledgePoint.isEmpty ? '' : ' · ${mistake.knowledgePoint}'}',
        kind: TimelineKind.created,
      ),
    ];

    for (final record in explanations) {
      entries.add(
        MistakeTimelineEntry(
          at: record.createdAt,
          title: '看过讲解',
          detail: record.knowledgePoint.isEmpty
              ? 'AI 讲解'
              : '${record.knowledgePoint} · AI 讲解',
          kind: TimelineKind.explained,
        ),
      );
    }

    for (final attempt in attempts) {
      entries.add(
        MistakeTimelineEntry(
          at: attempt.createdAt,
          title: attempt.correct ? '第 ${attempt.round} 轮通过' : '第 ${attempt.round} 轮未通过',
          // 渠道不再拼进文案：界面用 [MistakeTimelineEntry.channel] 渲染成徽章。
          // 同一个信息在两处表达，迟早会出现「文案说自评、徽章说 AI 判定」。
          detail: attempt.comment,
          kind: attempt.correct ? TimelineKind.practiced : TimelineKind.failed,
          channel: attempt.channel,
        ),
      );
    }

    if (mistake.state == ReviewState.mastered && mistake.masteredAt != null) {
      entries.add(
        MistakeTimelineEntry(
          at: mistake.masteredAt!,
          title: mistake.masteredBySelf ? '自评标记掌握' : '通过检查毕业',
          detail: mistake.masteredBySelf
              ? '自评掌握，不计入掌握率统计'
              : '已从待复习池移出，保留在已掌握档案中',
          kind: TimelineKind.mastered,
        ),
      );
    }

    entries.sort((a, b) => a.at.compareTo(b.at));
    return entries;
  }

  /// 薄弱知识点排行：按累计错误次数降序。
  ///
  /// 注意统计单位是「知识点」而不是「题目」——错题本里两道同知识点的题
  /// 是两道题，但薄弱的是那一个知识点。
  static List<WeakKnowledgePoint> weakPoints(
    List<ReviewMistake> pool, {
    int limit = 5,
  }) {
    final tally = <String, WeakKnowledgePoint>{};
    for (final mistake in pool) {
      if (mistake.state == ReviewState.mastered) continue;
      final key = mistake.knowledgePoint.isEmpty
          ? '${mistake.subject}·未标注知识点'
          : mistake.knowledgePoint;
      final existing = tally[key];
      tally[key] = WeakKnowledgePoint(
        name: key,
        subject: mistake.subject,
        wrongCount: (existing?.wrongCount ?? 0) + mistake.wrongCount,
        mistakeCount: (existing?.mistakeCount ?? 0) + 1,
      );
    }
    final list = tally.values.toList()
      ..sort((a, b) {
        final byWrong = b.wrongCount.compareTo(a.wrongCount);
        return byWrong != 0 ? byWrong : b.mistakeCount.compareTo(a.mistakeCount);
      });
    return limit <= 0 ? list : list.take(limit).toList();
  }

  /// 掌握率：通过检查毕业的题 /（毕业 + 待复习）。
  ///
  /// **自评掌握不计入分子**。否则「点一下标记掌握」就能把掌握率做漂亮，
  /// 这个数字也就不值得看了。
  static double masteryRate(List<ReviewMistake> pool) {
    var verified = 0;
    var remain = 0;
    for (final mistake in pool) {
      if (mistake.state == ReviewState.mastered) {
        if (!mistake.masteredBySelf) verified++;
      } else {
        remain++;
      }
    }
    final total = verified + remain;
    return total == 0 ? 0 : verified / total;
  }

  /// 周期报告（周报 / 月报）。
  ///
  /// 统计窗口的边界刻意选成「自然周从周一 00:00 起」「自然月从 1 号 00:00 起」，
  /// 而不是「最近 7 天 / 最近 30 天」：家长看的是「这周孩子学了没」，
  /// 滚动窗口会把上周日的记录算进这周，出现「今天才周一，怎么已经学了 3 天」。
  ///
  /// 另外一个容易写错的地方：**通过率的分母是「期内作答次数」而不是「期内错题数」**。
  /// 一道反复错的题做 3 轮才算毕业，若按题目数算分母，这道题会把整周的通过率
  /// 稀释掉，表现和「做了 3 道各错 1 次的题」完全一样——而这显然是两回事。
  static PeriodReport buildPeriodReport({
    required SummaryScope scope,
    required DateTime now,
    required List<ReviewMistake> pool,
    required List<ReviewPaper> papers,
    required List<ReviewAttempt> attempts,
    required List<ExplainRecord> explanations,
    int weakLimit = 5,
  }) {
    final start = periodStart(scope, now);
    final end = now;
    bool inWindow(DateTime? at) =>
        at != null && !at.isBefore(start) && !at.isAfter(end);

    final scopedAttempts = attempts.where((a) => inWindow(a.createdAt)).toList();
    final scopedExplains = explanations
        .where((e) => inWindow(e.createdAt))
        .toList();

    final mistakeById = {for (final m in pool) m.id: m};

    var passCount = 0;
    var paperAttempts = 0;
    var practiceAttempts = 0;
    final subjectAttempts = <String, int>{};
    final subjectPasses = <String, int>{};
    final weakTally = <String, WeakKnowledgePoint>{};
    final activeDayKeys = <String>{};
    final bestStreakByMistake = <String, int>{};
    final runningStreak = <String, int>{};

    for (final attempt in scopedAttempts) {
      final mistake = mistakeById[attempt.mistakeId];
      final subject = mistake?.subject ?? '';
      if (attempt.correct) passCount++;
      subjectAttempts[subject] = (subjectAttempts[subject] ?? 0) + 1;
      if (attempt.correct) {
        subjectPasses[subject] = (subjectPasses[subject] ?? 0) + 1;
      }
      if (attempt.channel == AttemptChannel.practice) {
        practiceAttempts++;
      } else {
        paperAttempts++;
      }

      activeDayKeys.add(_dayKey(attempt.createdAt));

      // 单题连续通过轮数：按时间顺序扫描，一断就归零。
      final streak = attempt.correct
          ? (runningStreak[attempt.mistakeId] ?? 0) + 1
          : 0;
      runningStreak[attempt.mistakeId] = streak;
      if (streak > (bestStreakByMistake[attempt.mistakeId] ?? 0)) {
        bestStreakByMistake[attempt.mistakeId] = streak;
      }

      if (!attempt.correct) {
        final point = (mistake?.knowledgePoint ?? '').isEmpty
            ? '${subject.isEmpty ? '未标注科目' : subject}·未标注知识点'
            : mistake!.knowledgePoint;
        final existing = weakTally[point];
        weakTally[point] = WeakKnowledgePoint(
          name: point,
          subject: subject,
          wrongCount: (existing?.wrongCount ?? 0) + 1,
          mistakeCount: (existing?.mistakeCount ?? 0) + 1,
        );
      }
    }

    final weak = weakTally.values.toList()
      ..sort((a, b) => b.wrongCount.compareTo(a.wrongCount));
    final weakLimited = weakLimit <= 0 ? weak : weak.take(weakLimit).toList();

    final graduated = pool
        .where(
          (m) =>
              m.state == ReviewState.mastered &&
              !m.masteredBySelf &&
              inWindow(m.masteredAt),
        )
        .length;
    final selfMastered = pool
        .where(
          (m) =>
              m.state == ReviewState.mastered &&
              m.masteredBySelf &&
              inWindow(m.masteredAt),
        )
        .length;

    final issued = papers
        .where((p) => inWindow(p.exportedAt ?? p.createdAt))
        .length;
    final graded = papers.where((p) => inWindow(p.gradedAt)).length;

    final bestStreak = bestStreakByMistake.values.isEmpty
        ? 0
        : bestStreakByMistake.values.reduce(math.max);
    final rate = scopedAttempts.isEmpty ? 0.0 : passCount / scopedAttempts.length;

    return PeriodReport(
      scope: scope,
      scopeKey: periodKey(scope, now),
      title: scope == SummaryScope.month ? '本月复习报告' : '本周复习报告',
      start: start,
      end: end,
      attemptCount: scopedAttempts.length,
      passCount: passCount,
      failCount: scopedAttempts.length - passCount,
      graduatedCount: graduated,
      selfMasteredCount: selfMastered,
      paperAttemptCount: paperAttempts,
      practiceAttemptCount: practiceAttempts,
      explainedCount: scopedExplains.length,
      paperIssueCount: issued,
      paperGradedCount: graded,
      poolRemain: pool.where((m) => m.state.inPool).length,
      bestStreak: bestStreak,
      activeDays: activeDayKeys.length,
      passRate: rate,
      weakPoints: weakLimited,
      subjectAttempts: subjectAttempts,
      subjectPasses: subjectPasses,
      highlights: _highlights(
        scope: scope,
        attemptCount: scopedAttempts.length,
        passCount: passCount,
        graduated: graduated,
        selfMastered: selfMastered,
        bestStreak: bestStreak,
        activeDays: activeDayKeys.length,
        explainedCount: scopedExplains.length,
        graded: graded,
      ),
      suggestions: _suggestions(
        attemptCount: scopedAttempts.length,
        graduated: graduated,
        selfMastered: selfMastered,
        poolRemain: pool.where((m) => m.state.inPool).length,
        weak: weakLimited,
      ),
    );
  }

  /// 周期起点：周报从本周一 00:00 起，月报从本月 1 号 00:00 起。
  static DateTime periodStart(SummaryScope scope, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return switch (scope) {
      SummaryScope.month => DateTime(now.year, now.month, 1),
      SummaryScope.week => today.subtract(Duration(days: now.weekday - 1)),
      SummaryScope.paper => today,
    };
  }

  /// 周期键。周报用 ISO 周号，月报用年月。
  static String periodKey(SummaryScope scope, DateTime now) {
    if (scope == SummaryScope.month) {
      final mm = now.month < 10 ? '0${now.month}' : '${now.month}';
      return '${now.year}-$mm';
    }
    if (scope == SummaryScope.paper) {
      final mm = now.month < 10 ? '0${now.month}' : '${now.month}';
      final dd = now.day < 10 ? '0${now.day}' : '${now.day}';
      return '${now.year}-$mm-$dd';
    }
    final (weekYear, week) = isoWeekOf(now);
    return '$weekYear-W$week';
  }

  /// ISO 周号，以及**这一周所属的年份**。
  ///
  /// 两者必须一起算出来。2025-12-31 是周三、属于 2026 年第 1 周，
  /// 如果年份取日历年就会得到「2025-W1」——那和 2025 年真正的第 1 周
  /// 撞成同一个周期键，同一周会攒出两份互相覆盖的报告。
  ///
  /// 规则：一周归属于包含它那个周四的年份（周一起始）。
  static (int year, int week) isoWeekOf(DateTime date) {
    final thursday = date.add(Duration(days: 4 - date.weekday));
    final firstDayOfYear = DateTime(thursday.year, 1, 1);
    final dayOfYear = thursday.difference(firstDayOfYear).inDays + 1;
    return (thursday.year, ((dayOfYear - 1) / 7).floor() + 1);
  }

  static String _dayKey(DateTime value) {
    final local = value.toLocal();
    return '${local.year}-${local.month}-${local.day}';
  }

  /// 亮点：只报**做成了什么**，不报「你没做什么」。
  ///
  /// 这一条是有意为之：周报是给孩子和家长一起看的，
  /// 通篇都是「错的、没做的」，孩子下次就不愿意打开了。
  static List<String> _highlights({
    required SummaryScope scope,
    required int attemptCount,
    required int passCount,
    required int graduated,
    required int selfMastered,
    required int bestStreak,
    required int activeDays,
    required int explainedCount,
    required int graded,
  }) {
    final list = <String>[];
    final scopeLabel = scope == SummaryScope.month ? '本月' : '本周';

    if (attemptCount == 0) return list;
    if (attemptCount >= 10) {
      list.add('$scopeLabel完成 $attemptCount 次作答，复习节奏稳。');
    } else {
      list.add('$scopeLabel完成 $attemptCount 次作答。');
    }
    if (activeDays >= 3) {
      list.add('有 $activeDays 天留下了复习记录，习惯正在形成。');
    }
    if (graduated > 0) {
      list.add('$graduated 道错题通过检查移出错题库。');
    }
    if (bestStreak >= ReviewService.requiredStreakForRepeatedWrong) {
      list.add('最难的一道题连续 $bestStreak 轮做对，反复错的题也拿下了。');
    }
    if (selfMastered > 0) {
      list.add('另有 $selfMastered 道由学生自评掌握（不计入通过率）。');
    }
    if (explainedCount > 0) {
      list.add('查看讲解 $explainedCount 次，先看懂再动笔。');
    }
    if (graded > 0) {
      list.add('完成 $graded 份资料的批改。');
    }
    return list;
  }

  /// 建议：必须**可执行**，说得出「下一步做什么」。
  static List<String> _suggestions({
    required int attemptCount,
    required int graduated,
    required int selfMastered,
    required int poolRemain,
    required List<WeakKnowledgePoint> weak,
  }) {
    final list = <String>[];

    if (attemptCount == 0) {
      if (poolRemain > 0) {
        list.add('错题库里还有 $poolRemain 道题，先挑这几道生成一份重做卷。');
      } else {
        list.add('暂时没有错题，保持作业提交后的检查习惯即可。');
      }
      return list;
    }
    if (graduated == 0 && poolRemain > 0) {
      list.add('这一周期没有错题毕业。挑 3 道最常错的题，先看讲解再做，别一次铺开。');
    }
    if (weak.isNotEmpty) {
      list.add('「${weak.first.name}」错了 ${weak.first.wrongCount} 次，建议用举一反三连做两轮。');
    }
    if (poolRemain == 0 && graduated > 0) {
      list.add('错题库已清空，可以回到作业检查，把新错题重新攒起来。');
    }
    if (selfMastered > graduated && selfMastered > 0) {
      list.add('自评掌握的题比通过检查的还多，建议挑其中两道补一次实际作答，掌握率才站得住。');
    }
    return list;
  }

  /// 作答渠道判定：**录了答案才算 AI 判定，只标了对错就是自评**。
  ///
  /// 这条规则同时被批改流程和资料详情页用到。写在这里而不是各写一遍，
  /// 是因为两边一旦不一致，就会出现「详情页显示 AI 判定、家长端显示自评」
  /// 这种对不上号的情况——而渠道恰恰是判断掌握可信度的依据。
  static AttemptChannel channelForAnswer(String answer) =>
      answer.trim().isEmpty ? AttemptChannel.paperSelf : AttemptChannel.paper;

  /// 下一轮的轮次号：这道题已有几轮作答就 +1。
  static int nextRound(List<ReviewAttempt> history) => history.length + 1;
}
