import 'package:easy_learn_app/data/drill_bank.dart';
import 'package:easy_learn_app/models/drill_question.dart';
import 'package:flutter_test/flutter_test.dart';

/// 题库完整性判据。
///
/// 这些断言盯的是**不报错的那类坏法**：选项只有 3 个、答案下标越界、
/// 两个选项是同一个式子、四步法漏字段 —— 任何一条都能让题目「看起来
/// 正常」地教错。特别是「选项互异」：两份等价的干扰项会让孩子觉得
/// 「两个都对/两个都错」，而这种题在纸面上是查不出来的。
void main() {
  group('题库完整性', () {
    test('每道题结构合法：4 个互异选项、答案下标合法、五步解析非空', () {
      for (final q in kDrillBank) {
        final where = '题 ${q.id}';
        expect(q.id.isNotEmpty, true, reason: where);
        expect(q.options, hasLength(4), reason: '$where 选项数');
        expect(
          q.options.toSet().length,
          4,
          reason: '$where 有重复选项（等价干扰项会让孩子觉得题出错了）',
        );
        expect(q.answerIndex, inInclusiveRange(0, 3), reason: '$where 答案下标');
        expect(q.stem.trim().isNotEmpty, true, reason: '$where 题干为空');
        expect(q.pattern.trim().isNotEmpty, true, reason: '$where 句式为空');
        expect(q.knowledge.trim().isNotEmpty, true, reason: '$where 知识点为空');
        expect(q.explain.subject.trim().isNotEmpty, true, reason: '$where 缺主体');
        expect(q.explain.numbers.trim().isNotEmpty, true, reason: '$where 缺数值');
        expect(q.explain.relation.trim().isNotEmpty, true, reason: '$where 缺关系');
        expect(q.explain.goal.trim().isNotEmpty, true, reason: '$where 缺目标');
        expect(q.explain.pitfall.trim().isNotEmpty, true, reason: '$where 缺错因');
      }
    });

    test('id 唯一', () {
      final ids = kDrillBank.map((q) => q.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'id 重复 = 历史记录串题');
    });

    test('题干互异（同一天不能出两道一模一样的题）', () {
      final stems = kDrillBank.map((q) => q.stem).toList();
      expect(stems.toSet().length, stems.length);
    });

    test('三个分层都有题，且基础层不少于进阶+综合', () {
      final basic = kDrillBank.where((q) => q.tier == DrillTier.basic).length;
      final advanced = kDrillBank
          .where((q) => q.tier == DrillTier.advanced)
          .length;
      final composite = kDrillBank
          .where((q) => q.tier == DrillTier.composite)
          .length;
      expect(basic, greaterThan(0));
      expect(advanced, greaterThan(0));
      expect(composite, greaterThan(0));
      // 题库是素材池，每天出的 3:2:1 比例由选题器（drill_selector）保证，
      // 不要求题库总量按该比例分布。这里只守住底线：作为根概念的基础层，
      // 题量不应少于最难的综合层——否则「基础不牢、拔高题先来」会打击信心。
      expect(basic, greaterThanOrEqualTo(composite));
    });

    test('knowledge 取值对齐错题本既有词表（加权才可能生效）', () {
      // 错题本里实际出现过的数学知识点（2026-10-25 查库）：
      // 这些词必须在题库里有对应题，否则「按弱项加权」对她是空转。
      const expected = {
        '用字母表示数',
        '列代数式',
        '列方程解应用题',
        '解一元一次方程',
        '和倍问题',
        '相遇问题',
        '相反数与倒数',
        '代数式表示图形面积',
      };
      final known = kDrillBank.map((q) => q.knowledge).toSet();
      expect(
        known.containsAll(expected),
        true,
        reason: '缺：${expected.difference(known)}',
      );
    });

    test('用户点例题在库里：「一个数的 3 倍比这个数大 10」', () {
      final q = kDrillBank.firstWhere((q) => q.id == 'dq-nfold-02');
      expect(q.stem, contains('3 倍'));
      expect(q.stem, contains('大 10'));
      expect(q.options[q.answerIndex], r'$3x = x + 10$');
    });

    test('错题本弱项 TOP（有理数混合运算）有对应句式覆盖', () {
      // 有理数混合运算本身是计算题，不在概念训练范围；
      // 但它的上游「列代数式/找关系」必须在库里有足量题。
      final covered = kDrillBank
          .where((q) =>
              q.knowledge == '列代数式' || q.knowledge == '用字母表示数')
          .length;
      expect(covered, greaterThanOrEqualTo(8));
    });

    test('补齐后覆盖她的真实弱项 canonical 知识点（加权才生效）', () {
      // 这些规范词与 drill_selector.kKnowledgeAlias 的归一目标一一对应；
      // 数量门槛防止「补齐」偷偷退化成空转。
      int count(String k) => kDrillBank.where((q) => q.knowledge == k).length;
      expect(count('有理数混合运算'), greaterThanOrEqualTo(6));
      expect(count('列方程解应用题'), greaterThanOrEqualTo(5));
      expect(count('解一元一次方程'), greaterThanOrEqualTo(3));
      expect(count('图形想象'), greaterThanOrEqualTo(6));
      expect(count('幂的运算'), greaterThanOrEqualTo(2));
    });
  });
}
