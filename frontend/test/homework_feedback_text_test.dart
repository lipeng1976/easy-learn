import 'package:flutter_test/flutter_test.dart';
import 'package:easy_learn_app/services/ai_data_source.dart';
import 'package:easy_learn_app/utils/homework_feedback_text.dart';

/// 这些用例盯的是「书写规范提醒」这句文案 —— 也就是 B13 里
/// 「漏单位 / 没写答句 → 不算错，但可以作为提醒」那一半。
///
/// 为什么值得专门测：此前这段逻辑是控制器里的一个私有片段（`_formatIssueNote`
/// 之前根本不存在，只有一句「另有 N 处」），**`test/` 下一条覆盖都没有** ——
/// 改坏了不会有任何东西变红，而它坏掉的表现恰恰是最难被发现的那种：
/// 学生看到「有 3 处问题」却不知道是哪 3 处，也不会有人报错。
HomeworkFormatIssue issue(String detail, {String point = '有理数运算'}) =>
    HomeworkFormatIssue(knowledgePoint: point, detail: detail);

void main() {
  group('formatIssueNote', () {
    test('没有提醒时返回空串（不能凭空冒出一句「另有 0 处」）', () {
      expect(HomeworkFeedbackText.formatIssueNote([]), '');
    });

    test('单条提醒里要出现模型给的 detail 原文', () {
      final note = HomeworkFeedbackText.formatIssueNote([
        issue('第 4 题算对了但没写单位 元'),
      ]);
      expect(note, contains('第 4 题算对了但没写单位 元'));
      expect(note, contains('1 处'));
    });

    test('⚠️ 必须自带「不计错题」—— 否则学生以为错题本里多了几道题', () {
      // 这条是 B13 的硬要求：规范问题不进错题库。
      // 文案如果说成「另有 3 处问题」，学生去错题本里找会发现什么都没有，
      // 两边对不上之后就再也说不清了。
      final note = HomeworkFeedbackText.formatIssueNote([
        issue('第 4 题漏了单位'),
        issue('第 6 题没写答句'),
      ]);
      expect(note, contains('不计错题'));
      expect(note, contains('不扣分'));
    });

    test('多条按「；」并列，条数与明细同时出现', () {
      final note = HomeworkFeedbackText.formatIssueNote([
        issue('第 4 题漏单位'),
        issue('第 6 题没写答句'),
      ]);
      expect(note, contains('2 处'));
      expect(note, contains('第 4 题漏单位；第 6 题没写答句'));
    });

    test('超过上限只列前几条，并用「例如」标明这不是完整清单', () {
      final note = HomeworkFeedbackText.formatIssueNote([
        issue('第 1 题漏单位'),
        issue('第 2 题漏单位'),
        issue('第 3 题漏单位'),
        issue('第 4 题漏单位'),
        issue('第 5 题漏单位'),
      ]);
      expect(note, contains('5 处'), reason: '总数要说全');
      expect(note, contains('第 1 题漏单位'));
      expect(note, isNot(contains('第 5 题漏单位')));
      // 「例如」这个词是刻意的：列不全却写成完整清单的样子，就是误导。
      expect(note, contains('例如'));
    });

    test('条数刚好等于上限时不写「例如」', () {
      final note = HomeworkFeedbackText.formatIssueNote([
        issue('a'),
        issue('b'),
        issue('c'),
      ]);
      expect(note, isNot(contains('例如')));
      expect(note, contains('3 处'));
    });

    test('超长明细被截断，避免把「得分 / 错题数」挤出屏幕', () {
      final long = '第 4 题${'写了很多很多字的解释' * 10}';
      final note = HomeworkFeedbackText.formatIssueNote([issue(long)]);
      expect(
        note.length,
        lessThan(long.length),
        reason: '原文长度 ${long.length}，文案不该原样照搬',
      );
      expect(note, endsWith('。'));
    });

    test('detail 全为空时退回「只报条数」，而不是返回空串', () {
      // 模型确实说了有 2 处，只是没写明是哪几处 ——
      // 这时一声不吭比「不知道是哪几处」更糟。
      final note = HomeworkFeedbackText.formatIssueNote([
        issue('   '),
        issue(''),
      ]);
      expect(note, isNotEmpty);
      expect(note, contains('2 处'));
      expect(note, isNot(contains('：')));
    });

    test('detail 里的换行被压成空格（snackbar 里换行会把版面撑乱）', () {
      final note = HomeworkFeedbackText.formatIssueNote([
        issue('第 4 题\n漏了单位\n记得补上'),
      ]);
      expect(note, isNot(contains('\n')));
      expect(note, contains('第 4 题 漏了单位 记得补上'));
    });

    test('空明细条目被跳过，且它占掉的额度会让位给后面有内容的条目', () {
      final note = HomeworkFeedbackText.formatIssueNote([
        issue('   '),
        issue('第 6 题没写答句'),
      ]);
      expect(note, contains('第 6 题没写答句'));
    });
  });
}
