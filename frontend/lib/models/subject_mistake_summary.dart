/// 家长端「按学科看错题」的汇总口径（**唯一一处**）。
///
/// 为什么要单独抽出来：色块上的每个数字都会被家长当成结论读。如果分组、
/// 排序、兜底散在页面里，改一次排版就可能悄悄换一套口径（「数学 87」变成
/// 88、或「其他」把白名单外的科目吞掉却不显示），而界面照样能画出来。
/// 所以页面只负责画，算账只在这里。
///
/// ## 两条不能动的约定
///
/// 1. **待复习 = `state.inPool`**（pending / reviewing / verifying），
///    与 `ParentController.visiblePoolMistakes` 同一个判据 —— 两边不一致时，
///    色块上的 87 和顶部的「待复习 108」会当场对不上。
/// 2. **自评掌握单独计数**。掌握率的既有口径是「自评不算」；色块如果把
///    自评掌握混进「已掌握」，家长就会看到一个比掌握率更漂亮的数字。
library;

import 'review_model.dart';
import 'subject_scope.dart';

/// `subject` 为空、空白或不在十科白名单里时，一律归到这一块。
///
/// 归到「其他」不等于丢信息：详情页里的每张错题卡仍显示**原始**
/// `mistake.subject`，只是色块这一层不再为生僻科目名新开一块。
const String kOtherSubjectName = '其他';

/// 把一条错题的 `subject` 归一到十科白名单（含「其他」）。
///
/// 为什么不在数据写入时统一：库里有历史数据（作业批改、拍照、手工录入
/// 各时期写的值），清洗旧数据是不可逆操作；读取时归一可以随时改规则。
String normalizeMistakeSubject(String raw) {
  final subject = raw.trim();
  if (subject.isEmpty) return kOtherSubjectName;
  return kSubjectNames.contains(subject) ? subject : kOtherSubjectName;
}

/// 一个学科的错题汇总。
class SubjectMistakeSummary {
  const SubjectMistakeSummary({
    required this.subject,
    required this.poolCount,
    required this.masteredCount,
    required this.selfMasteredCount,
    required this.wrongCount,
    required this.examCount,
  });

  /// 归一后的科目名（十科之一）。
  final String subject;

  /// 仍在待复习池里的题数（含复习中 / 待批改）。
  final int poolCount;

  /// 已毕业的题数（**含**自评掌握）。
  final int masteredCount;

  /// 已毕业里「孩子自己标记掌握」的题数，是 [masteredCount] 的子集。
  final int selfMasteredCount;

  /// 累计错误次数（每条错题的 `wrongCount` 之和，不是题数）。
  final int wrongCount;

  /// 其中来自「考试卷导入」的题数（`MistakeSource.imaExam`）。
  ///
  /// 单独计数而不是混进 `total` 之外的某个比例：家长问的是「这里面有多少
  /// 是考试卷上的」，答不上来就只能去翻每一张卡。只在详情页显示，
  /// 色块上不摆 —— 2×2 的块里已经有三段信息了。
  final int examCount;

  int get total => poolCount + masteredCount;

  bool get hasSelfMastered => selfMasteredCount > 0;

  bool get hasExamImported => examCount > 0;

  /// 通过检查毕业的题数（自评不算）——与掌握率同一口径。
  int get verifiedMasteredCount => masteredCount - selfMasteredCount;
}

class _Tally {
  int pool = 0;
  int mastered = 0;
  int selfMastered = 0;
  int wrongs = 0;
  int exam = 0;
}

/// 按学科汇总当前孩子的全部错题。
///
/// 排序：**待复习多的在前**（家长先看到最该管的科）；同数时总题数多的在前；
/// 再相同按十科白名单顺序。`其他` 永远排最后 —— 它不是一门课，不该抢主位。
List<SubjectMistakeSummary> summarizeMistakesBySubject(
  Iterable<ReviewMistake> mistakes,
) {
  final tally = <String, _Tally>{};
  for (final mistake in mistakes) {
    final subject = normalizeMistakeSubject(mistake.subject);
    final one = tally.putIfAbsent(subject, _Tally.new);
    if (mistake.state.inPool) {
      one.pool += 1;
    } else {
      one.mastered += 1;
    }
    if (mistake.masteredBySelf) one.selfMastered += 1;
    one.wrongs += mistake.wrongCount;
    // 按**来源**计，不按 `sourceRef` 去重：一份试卷导入 4 道题，
    // 家长看到「试卷导入 4」问的是题数，不是导入过几份卷子。
    if (mistake.sourceType == MistakeSource.imaExam) one.exam += 1;
  }

  final summaries = tally.entries
      .map(
        (entry) => SubjectMistakeSummary(
          subject: entry.key,
          poolCount: entry.value.pool,
          masteredCount: entry.value.mastered,
          selfMasteredCount: entry.value.selfMastered,
          wrongCount: entry.value.wrongs,
          examCount: entry.value.exam,
        ),
      )
      .toList();

  summaries.sort((a, b) {
    // 「其他」永远垫底：哪怕它的待复习数最多，也不该占主色块的位置。
    final aOther = a.subject == kOtherSubjectName;
    final bOther = b.subject == kOtherSubjectName;
    if (aOther != bOther) return aOther ? 1 : -1;

    final byPool = b.poolCount.compareTo(a.poolCount);
    if (byPool != 0) return byPool;

    final byTotal = b.total.compareTo(a.total);
    if (byTotal != 0) return byTotal;

    return kSubjectNames.indexOf(a.subject).compareTo(
      kSubjectNames.indexOf(b.subject),
    );
  });

  return List<SubjectMistakeSummary>.unmodifiable(summaries);
}

/// 取某一个学科的汇总；没有该科错题时返回 `null`。
///
/// 详情页用它画顶部汇总条。返回 `null` 而不是一个全 0 的对象，是为了让
/// 「这一科的错题刚被清空」与「本来就是 0」在界面上能分开处理。
SubjectMistakeSummary? findSubjectSummary(
  List<SubjectMistakeSummary> summaries,
  String subject,
) {
  for (final one in summaries) {
    if (one.subject == subject) return one;
  }
  return null;
}
