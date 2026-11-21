import '../models/checkin_models.dart';

/// 打卡的显示名与日期格式 —— **单点定义**。
///
/// 学生端有两个页面要显示同一批记录（打卡页的清单、按科目分组的记录页），
/// 两处各写一份 `isEmpty ? '综合' : subject` 的话，哪天改了文案必有一处漏掉，
/// 而症状是「同一个科目在两个页面叫两个名字」，谁都不会报错。

/// 科目显示名：空串 = 学生自发起、服务端没记科目，显示「综合」。
String checkinSubjectLabel(CheckinQuiz quiz) =>
    quiz.subject.isEmpty ? '综合' : quiz.subject;

/// `2026-10-28` → `10-28`（列表里只需要认得出是哪天）。
///
/// 不是 `yyyy-MM-dd` 原样印：占四个字符的年份在每行里没有信息量，
/// 而且会把辅助信息挤到换行。空串/异常值原样返回，别在这里抛。
String checkinShortDate(String date) =>
    date.length >= 10 ? date.substring(5) : date;

/// 本地日 → `yyyy-MM-dd`。打卡日期键的**单点定义**：
/// `CheckinController.formatDate` 与「今天完成」的分组都走这里。
String checkinDateKey(DateTime at) {
  final month = at.month.toString().padLeft(2, '0');
  final day = at.day.toString().padLeft(2, '0');
  return '${at.year}-$month-$day';
}

/// 一份「已完成」记录属于哪一天 —— 按**交卷日**（本地日）。
///
/// 为什么不看 `quiz.quizDate`：那是出题日。家长头晚出题、孩子第二天早上
/// 才做时两者差一天，按出题日分组会把「今天刚做完的」漏到框外，而且
/// 界面上没有任何报错。服务端 `GET /data/checkin/quiz` 已在 result 里
/// 返回 `submittedAt`；只有老服务端缺字段时才退回出题日。
String checkinDoneDateKey(CheckinQuiz quiz, CheckinSubmitResult result) {
  final at = result.submittedAt?.toLocal();
  return at == null ? quiz.quizDate : checkinDateKey(at);
}
