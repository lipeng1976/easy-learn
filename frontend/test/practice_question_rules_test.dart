import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/utils/practice_question_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('选项清洗', () {
    test('剥掉各种字母前缀', () {
      expect(stripOptionPrefix('A. 2x+1=5'), '2x+1=5');
      expect(stripOptionPrefix('B、3x-1=4'), '3x-1=4');
      expect(stripOptionPrefix('C．x/2=2'), 'x/2=2');
      expect(stripOptionPrefix('D) 4x=6'), '4x=6');
      expect(stripOptionPrefix('a）x=1'), 'x=1');
      expect(stripOptionPrefix('x=2'), 'x=2', reason: '没有前缀就原样');
    });

    test('只有「字母 + 分隔符」才算前缀', () {
      // 「A 是一个常数」里的 A 不是序号 —— 把 A 剥掉会把选项内容改坏。
      expect(stripOptionPrefix('A 是一个常数'), 'A 是一个常数');
      expect(stripOptionPrefix('B2 细胞'), 'B2 细胞');
    });

    test('选项可用性：恰好 4 个、非空、不重复', () {
      expect(isUsableOptions(['2', '3', '4', '5']), isTrue);
      expect(isUsableOptions(['2', '3', '4']), isFalse, reason: '3 个不行');
      expect(isUsableOptions(['2', '3', '4', '5', '6']), isFalse);
      expect(isUsableOptions(['2', ' ', '4', '5']), isFalse);
      expect(
        isUsableOptions(['2', '2', '4', '5']),
        isFalse,
        reason: '重复选项意味着「选 A 还是 B」本来就无解',
      );
    });
  });

  group('选择题答案归一', () {
    const options = ['2x+1=5', '3x-1=4', 'x/2=2', '4x=6'];

    test('字母本身', () {
      expect(normalizeChoiceAnswer('A', options), 'A');
      expect(normalizeChoiceAnswer(' c ', options), 'C');
    });

    test('带前缀', () {
      expect(normalizeChoiceAnswer('A. 2x+1=5', options), 'A');
      expect(normalizeChoiceAnswer('B、3x-1=4', options), 'B');
    });

    test('直接抄选项内容', () {
      expect(normalizeChoiceAnswer('x/2=2', options), 'C');
      expect(normalizeChoiceAnswer('4x=6', options), 'D');
    });

    test('认不出来时返回 null，绝不猜一个', () {
      expect(normalizeChoiceAnswer('', options), isNull);
      expect(normalizeChoiceAnswer('E', options), isNull);
      expect(normalizeChoiceAnswer('不知道', options), isNull);
      // 两个选项文本相同 → 无法确定他选的是哪一个。
      expect(
        normalizeChoiceAnswer('2', const ['2', '2', '4', '5']),
        isNull,
      );
    });
  });

  group('判断题答案归一', () {
    test('各种对', () {
      for (final raw in ['正确', '对', 'true', 'TRUE', '√']) {
        expect(normalizeJudgeAnswer(raw), '正确', reason: raw);
      }
    });

    test('各种错', () {
      for (final raw in ['错误', '错', 'false', '×', '不对']) {
        expect(normalizeJudgeAnswer(raw), '错误', reason: raw);
      }
    });

    test('含糊的词不猜', () {
      // 「是 / 否」在一道「下列说法是否正确」的题里可能指别的东西，
      // 硬猜等于把做对的学生判错。
      expect(normalizeJudgeAnswer('是'), isNull);
      expect(normalizeJudgeAnswer('否'), isNull);
      expect(normalizeJudgeAnswer(''), isNull);
    });
  });

  group('本地判定', () {
    const options = ['2x+1=5', '3x-1=4', 'x/2=2', '4x=6'];

    test('选择题：答对 / 答错', () {
      expect(
        gradeLocally(
          type: PracticeQuestionType.choice,
          studentAnswer: 'A',
          correctAnswer: 'A',
          options: options,
        ),
        LocalGrade.correct,
      );
      expect(
        gradeLocally(
          type: PracticeQuestionType.choice,
          studentAnswer: 'B',
          correctAnswer: 'A',
          options: options,
        ),
        LocalGrade.wrong,
      );
    });

    test('选择题：选项不合格就转交模型，不硬判', () {
      expect(
        gradeLocally(
          type: PracticeQuestionType.choice,
          studentAnswer: 'A',
          correctAnswer: 'A',
          options: const ['2', '2', '4', '5'],
        ),
        LocalGrade.undecidable,
        reason: '重复选项的题无论如何都不该本地判',
      );
      expect(
        gradeLocally(
          type: PracticeQuestionType.choice,
          studentAnswer: 'A',
          correctAnswer: 'A',
          options: const ['2', '3'],
        ),
        LocalGrade.undecidable,
      );
    });

    test('判断题：答对 / 答错', () {
      expect(
        gradeLocally(
          type: PracticeQuestionType.judge,
          studentAnswer: '对',
          correctAnswer: '正确',
        ),
        LocalGrade.correct,
      );
      expect(
        gradeLocally(
          type: PracticeQuestionType.judge,
          studentAnswer: 'false',
          correctAnswer: '正确',
        ),
        LocalGrade.wrong,
      );
    });

    test('填空 / 解答一律转交模型', () {
      // 正确答案的等价写法太多（0.5 / 1/2），字符串比对会把做对的判错。
      for (final type in [
        PracticeQuestionType.fill,
        PracticeQuestionType.solution,
      ]) {
        expect(
          gradeLocally(
            type: type,
            studentAnswer: '1/2',
            correctAnswer: '0.5',
          ),
          LocalGrade.undecidable,
          reason: '$type 不该本地判',
        );
      }
    });

    test('老数据没有题型 → solution，行为与以前一致', () {
      expect(PracticeQuestionType.parse(null), PracticeQuestionType.solution);
      expect(PracticeQuestionType.parse(''), PracticeQuestionType.solution);
      expect(PracticeQuestionType.parse('选择题'), PracticeQuestionType.choice);
      expect(PracticeQuestionType.parse('judge'), PracticeQuestionType.judge);
      // 不认识的值也回落到最宽松的那条路，不让整组题作废。
      expect(PracticeQuestionType.parse('作图'), PracticeQuestionType.solution);
    });
  });
}
