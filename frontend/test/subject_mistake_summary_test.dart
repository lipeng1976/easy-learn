import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/models/subject_mistake_summary.dart';
import 'package:easy_learn_app/models/subject_scope.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「按学科看错题」的算账口径。
///
/// 这一组只测纯函数，不测界面：色块上的 87、108、80% 都是从这几个函数出来的。
/// 它们错了界面照样能画，家长也照样会信 —— 所以每一条都要能在改坏时变红。
void main() {
  ReviewMistake mistake({
    String id = 'm1',
    String subject = '数学',
    ReviewState state = ReviewState.pending,
    int wrongCount = 1,
    bool masteredBySelf = false,
    DateTime? createdAt,
    MistakeSource sourceType = MistakeSource.manual,
  }) {
    return ReviewMistake(
      id: id,
      subject: subject,
      title: '题目 $id',
      originalAnswer: '',
      wrongReason: '',
      createdAt: createdAt ?? DateTime(2026, 11, 15),
      state: state,
      wrongCount: wrongCount,
      masteredBySelf: masteredBySelf,
      sourceType: sourceType,
    );
  }

  group('科目归一', () {
    test('空串与纯空白都归到「其他」', () {
      expect(normalizeMistakeSubject(''), '其他');
      expect(normalizeMistakeSubject('   '), '其他');
    });

    test('白名单内原样保留', () {
      // 直接引用唯一真值：白名单加一科时这条跟着覆盖到，
      // 抄一份副本会在加科目那天悄悄漏测。
      for (final subject in kSubjectNames) {
        expect(normalizeMistakeSubject(subject), subject);
      }
    });

    test('白名单外的科目归到「其他」，不新开一块', () {
      expect(normalizeMistakeSubject('科学'), '其他');
      expect(normalizeMistakeSubject('编程'), '其他');
    });

    test('「其他」本身原样保留（不能变成「其他其他」）', () {
      expect(normalizeMistakeSubject('其他'), '其他');
    });
  });

  group('汇总与排序', () {
    test('待复习 = 非 mastered（含复习中 / 待批改）', () {
      final result = summarizeMistakesBySubject([
        mistake(id: 'a', state: ReviewState.pending),
        mistake(id: 'b', state: ReviewState.reviewing),
        mistake(id: 'c', state: ReviewState.verifying),
        mistake(id: 'd', state: ReviewState.mastered),
      ]);

      expect(result, hasLength(1));
      expect(result.single.poolCount, 3);
      expect(result.single.masteredCount, 1);
      expect(result.single.total, 4);
    });

    test('按待复习数降序：数学 87 必须排在语文 9 前面', () {
      final result = summarizeMistakesBySubject([
        for (var i = 0; i < 9; i++) mistake(id: 'y$i', subject: '语文'),
        for (var i = 0; i < 87; i++) mistake(id: 's$i', subject: '数学'),
        for (var i = 0; i < 10; i++) mistake(id: 'e$i', subject: '英语'),
      ]);

      expect(result.map((one) => one.subject).toList(), ['数学', '英语', '语文']);
    });

    test('待复习数相同时，总题数多的在前', () {
      final result = summarizeMistakesBySubject([
        mistake(id: 'a1', subject: '语文'),
        mistake(id: 'b1', subject: '英语'),
        mistake(id: 'b2', subject: '英语', state: ReviewState.mastered),
      ]);

      // 两科都是待复习 1，但英语总题数 2。
      expect(result.first.subject, '英语');
    });

    test('「其他」永远垫底 —— 哪怕它待复习最多', () {
      final result = summarizeMistakesBySubject([
        for (var i = 0; i < 5; i++) mistake(id: 'o$i', subject: '科学'),
        mistake(id: 'm1', subject: '数学'),
      ]);

      expect(result.last.subject, '其他');
      expect(result.last.poolCount, 5, reason: '垫底不等于丢掉数字');
    });

    test('白名单外的多个科目合并进同一块「其他」，不重复开块', () {
      final result = summarizeMistakesBySubject([
        mistake(id: 'a', subject: '科学'),
        mistake(id: 'b', subject: '编程'),
        mistake(id: 'c', subject: ''),
      ]);

      expect(result, hasLength(1));
      expect(result.single.subject, '其他');
      expect(result.single.poolCount, 3);
    });

    test('自评掌握单独计数，且是已掌握的子集', () {
      final result = summarizeMistakesBySubject([
        mistake(id: 'a', state: ReviewState.mastered, masteredBySelf: true),
        mistake(id: 'b', state: ReviewState.mastered, masteredBySelf: true),
        mistake(id: 'c', state: ReviewState.mastered),
      ]);

      final one = result.single;
      expect(one.masteredCount, 3);
      expect(one.selfMasteredCount, 2);
      expect(one.verifiedMasteredCount, 1, reason: '通过检查毕业的只有 1 道');
      expect(one.hasSelfMastered, isTrue);
    });

    test('累计错次是各题 wrongCount 之和，不是题数', () {
      final result = summarizeMistakesBySubject([
        mistake(id: 'a', wrongCount: 3),
        mistake(id: 'b', wrongCount: 2),
      ]);

      expect(result.single.poolCount, 2);
      expect(result.single.wrongCount, 5);
    });

    test('空列表返回空，不抛', () {
      expect(summarizeMistakesBySubject(const <ReviewMistake>[]), isEmpty);
    });

    test('findSubjectSummary 找到返回汇总，找不到返回 null', () {
      final result = summarizeMistakesBySubject([mistake()]);
      expect(findSubjectSummary(result, '数学')?.poolCount, 1);
      expect(findSubjectSummary(result, '化学'), isNull);
    });

    test('返回的列表不可变 —— 页面不能偷偷改排序', () {
      final result = summarizeMistakesBySubject([mistake()]);
      expect(() => result.add(result.first), throwsUnsupportedError);
    });
  });

  group('试卷导入计数', () {
    test('只数 imaExam 来源，别的来源一律不算', () {
      final result = summarizeMistakesBySubject([
        mistake(id: 'a', sourceType: MistakeSource.imaExam),
        mistake(id: 'b', sourceType: MistakeSource.imaExam),
        mistake(id: 'c', sourceType: MistakeSource.checkin),
        mistake(id: 'd', sourceType: MistakeSource.homework),
        mistake(id: 'e'),
      ]);

      expect(result.single.examCount, 2);
      expect(result.single.total, 5, reason: '试卷导入是来源细分，不改变总题数');
      expect(result.single.hasExamImported, isTrue);
    });

    test('没有试卷导入的科目 hasExamImported 为 false（详情页据此不露那一行）', () {
      final result = summarizeMistakesBySubject([mistake()]);
      expect(result.single.examCount, 0);
      expect(result.single.hasExamImported, isFalse);
    });

    test('按来源计题数，不按 sourceRef 去重 —— 一份卷 4 道就是 4', () {
      final result = summarizeMistakesBySubject([
        mistake(id: 'a', sourceType: MistakeSource.imaExam),
        mistake(id: 'b', sourceType: MistakeSource.imaExam),
        mistake(id: 'c', sourceType: MistakeSource.imaExam),
        mistake(id: 'd', sourceType: MistakeSource.imaExam),
      ]);

      expect(result.single.examCount, 4);
    });

    test('已掌握的试卷题也算进 examCount（是来源属性，不是待复习属性）', () {
      final result = summarizeMistakesBySubject([
        mistake(id: 'a', sourceType: MistakeSource.imaExam),
        mistake(
          id: 'b',
          state: ReviewState.mastered,
          sourceType: MistakeSource.imaExam,
        ),
      ]);

      expect(result.single.poolCount, 1);
      expect(result.single.masteredCount, 1);
      expect(result.single.examCount, 2);
    });
  });
}
