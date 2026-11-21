import '../services/ai_data_source.dart';

/// 批改结果里那句「书写规范提醒」的文案。
///
/// 单独抽出来，是为了让它**可以被测到** —— 之前它是控制器里的一个私有片段，
/// `test/` 下一条覆盖都没有，改坏了也不会有任何东西变红。
///
/// ⚠️ 口径（`B13`）：漏单位 / 没写答句 / 跳步 → **不算错、不扣分，也不进错题库**。
/// 它只是提醒。所以这句文案**必须自带「不计错题」这四个字** ——
/// 学生看到「有 3 处问题」会以为错题本里多了 3 道题，而那里其实一道都没多，
/// 两边对不上以后就再也说不清了。
class HomeworkFeedbackText {
  const HomeworkFeedbackText._();

  /// 提醒里最多列几条明细。
  ///
  /// snackbar 放不下一整页作文；更重要的是，把「得分 / 错题数」挤到看不见
  /// 比少说两条规范提醒严重得多。多出来的用「等 N 处」带过。
  static const maxHints = 3;

  /// 单条明细最多多少字（超出截断）。
  static const maxDetailChars = 28;

  /// 把 [issues] 拼成一句看得懂的话；没有提醒时返回**空串**。
  ///
  /// 只给条数等于没给：学生看到「另有 3 处」并不知道是哪 3 处、该怎么改，
  /// 而模型给的 `detail`（如「第 4 题算对了但没写单位 元」）本来就是给人看的。
  ///
  /// ⚠️ `detail` 为空的条目会被跳过（解析层已经滤过一次，这里是双保险）：
  /// 一条没有内容的提醒在界面上就是一句废话。全都空时退回「只报条数」，
  /// 而不是返回空串 —— 那时模型确实说了有 N 处，只是没写明是哪几处。
  static String formatIssueNote(List<HomeworkFormatIssue> issues) {
    if (issues.isEmpty) return '';

    final shown = <String>[];
    for (final issue in issues) {
      if (shown.length >= maxHints) break;
      final detail = issue.detail.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (detail.isEmpty) continue;
      shown.add(
        detail.length > maxDetailChars
            ? '${detail.substring(0, maxDetailChars)}…'
            : detail,
      );
    }

    final head = '另有 ${issues.length} 处书写规范可改进（不计错题、不扣分）';
    if (shown.isEmpty) return '$head。';
    // 列全了就用冒号，只列了一部分就用「例如」，免得被当成完整清单。
    final joiner = shown.length < issues.length ? '，例如：' : '：';
    return '$head$joiner${shown.join('；')}。';
  }
}
