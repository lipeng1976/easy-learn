import 'package:easy_learn_app/services/ai_data_source.dart';
import 'package:easy_learn_app/services/simulated_ai_data_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// AI 数据源的**契约测试**。
///
/// 断言直接对着 `AiDataSource` 接口写，不依赖具体实现细节 ——
/// 接入云端实现后这些用例应当继续成立。它们守住三条底线：
///
/// 1. **确定性**：同一输入永远同一结果。批改结果会写进错题本、驱动毕业判定，
///    飘一次就是一次错误的知识信号。
/// 2. **判定不能惩罚认真作答**：过程写得完整的学生必须判对；规则啃不动的题
///    必须显式标 `inconclusive`，而不是默默判错。
/// 3. **不编造答案**：题库没覆盖时给通用解题要点，而不是假造一个具体答案。
void main() {
  const ai = SimulatedAiDataSource();

  group('单题判定：三态', () {
    test('短答案答对判 correct', () async {
      final result = await ai.judgeAnswer(
        studentAnswer: '11/12',
        referenceAnswer: '11/12（通分后 8/12 + 3/12）',
        knowledgePoint: '分数计算',
      );

      expect(result.verdict, AnswerVerdict.correct);
      expect(result.passed, isTrue);
      expect(result.score, 100);
      expect(result.comment, isNotEmpty);
    });

    test('学生只写核心答案、参考答案带过程说明，判 correct', () async {
      final result = await ai.judgeAnswer(
        studentAnswer: '40平方厘米',
        referenceAnswer: '40 平方厘米（(6+10)×5÷2）',
        knowledgePoint: '几何图形面积',
      );

      expect(result.verdict, AnswerVerdict.correct);
    });

    test('嵌套括号的过程说明不会把做对判成错', () async {
      // 回归保护：曾经只剥「参考答案」一侧的括号说明，导致认真写过程的学生
      // 反而被判错（写得越完整越容易错）；而且一次正则替换碰上嵌套括号
      // 只会吃掉半截，留下一个孤零零的右括号。
      final result = await ai.judgeAnswer(
        studentAnswer: '40 平方厘米（(6+10)×5÷2）',
        referenceAnswer: '40 平方厘米（(6+10)×5÷2）',
        knowledgePoint: '几何图形面积',
      );

      expect(result.verdict, AnswerVerdict.correct);
    });

    test('全角半角与空格差异不影响判定', () async {
      final result = await ai.judgeAnswer(
        studentAnswer: ' 11 / 12 ',
        referenceAnswer: '11/12',
      );

      expect(result.verdict, AnswerVerdict.correct);
    });

    test('答案写错判 wrong', () async {
      final result = await ai.judgeAnswer(
        studentAnswer: '13/12',
        referenceAnswer: '11/12（通分后 8/12 + 3/12）',
      );

      expect(result.verdict, AnswerVerdict.wrong);
      expect(result.passed, isFalse);
      expect(result.score, 0);
    });

    test('空答案判 wrong，而不是 inconclusive', () async {
      // 「没写」是确定的事实，不该被归到「判不了」里 ——
      // 否则云端接入后这些题会被白白送去模型判定，浪费一次调用。
      final result = await ai.judgeAnswer(
        studentAnswer: '   ',
        referenceAnswer: '11/12',
      );

      expect(result.verdict, AnswerVerdict.wrong);
      expect(result.passed, isFalse);
    });

    test('参考答案是「作答要求」时标 inconclusive，不当作错误', () async {
      // 「说清条件 + 给出一个符合条件的具体例子」这类答案，用字符串包含关系
      // 判定必然为假。判「错」等于惩罚认真作答的学生，所以必须显式标记
      // 「判不了」，交给云端模型判定。
      final result = await ai.judgeAnswer(
        studentAnswer: '同分母比分子，异分母先通分，比如 1/2 和 1/3。',
        referenceAnswer: '说清条件 + 给出一个符合条件的具体例子。',
        knowledgePoint: '概念复述',
      );

      expect(result.verdict, AnswerVerdict.inconclusive);
    });

    test('inconclusive 不算通过', () async {
      final result = await ai.judgeAnswer(
        studentAnswer: '随便写点什么',
        referenceAnswer: '说清条件 + 给出一个符合条件的具体例子。',
      );

      expect(
        result.passed,
        isFalse,
        reason: '判不了 ≠ 通过；若算通过，一条规则覆盖不到的题就能让错题白白毕业',
      );
    });

    test('同一输入重复判定，结论与文案完全一致', () async {
      Future<AnswerJudgement> judge() => ai.judgeAnswer(
        studentAnswer: '11/12',
        referenceAnswer: '11/12（通分后 8/12 + 3/12）',
        knowledgePoint: '分数计算',
      );

      final first = await judge();
      final second = await judge();

      expect(first.verdict, second.verdict);
      expect(first.score, second.score);
      expect(first.comment, second.comment);
    });
  });

  group('作业批改', () {
    test('结果稳定、分数在合理区间、错题数与明细一致', () async {
      final first = await ai.checkHomework(subject: '数学', title: '数学作业A');
      final second = await ai.checkHomework(subject: '数学', title: '数学作业A');

      expect(first.score, second.score);
      expect(first.wrongCount, second.wrongCount);
      expect(first.score, inInclusiveRange(60, 100));
      expect(
        first.wrongCount,
        first.items.length,
        reason: '错题数必须与明细条数一致，否则家长端会显示自相矛盾的数字',
      );
    });

    test('错题的总结里点名对应知识点', () async {
      // hash 决定错题数，所以遍历找一个确实产出错题的输入。
      HomeworkCheckOutcome? withWrong;
      for (final title in ['数学作业A', '数学作业B', '数学作业C', '数学作业D']) {
        final outcome = await ai.checkHomework(subject: '数学', title: title);
        if (outcome.wrongCount > 0) {
          withWrong = outcome;
          break;
        }
      }

      expect(withWrong, isNotNull, reason: '至少要有一组输入能产出错题');
      for (final item in withWrong!.items) {
        expect(withWrong.summary, contains(item.knowledgePoint));
        expect(item.knowledgePoint, isNotEmpty);
        expect(item.wrongReason, isNotEmpty);
      }
    });

    test('接受作业照片路径（云端实现靠它把图交给视觉模型）', () async {
      // 本地实现忽略这个参数，但签名必须支持 —— 接入云端时调用方
      // 已经在传了，不用回头改。
      final outcome = await ai.checkHomework(
        subject: '数学',
        title: '数学作业A',
        imagePaths: const ['hw/math-1.jpg', 'hw/math-2.jpg'],
      );

      expect(outcome.score, inInclusiveRange(60, 100));
    });
  });

  group('举一反三', () {
    test('能按知识点出满指定道数，每题都带题干与答案', () async {
      final questions = await ai.generatePractice(
        subject: '数学',
        knowledgePoint: '分数计算',
        count: 3,
      );

      expect(questions.length, 3);
      for (final question in questions) {
        expect(question.title, isNotEmpty);
        expect(question.content, isNotEmpty);
        expect(question.answer, isNotEmpty);
      }
    });

    test('同一轮重复出题结果一致', () async {
      final first = await ai.generatePractice(
        subject: '数学',
        knowledgePoint: '分数计算',
        round: 1,
      );
      final second = await ai.generatePractice(
        subject: '数学',
        knowledgePoint: '分数计算',
        round: 1,
      );

      expect(
        first.map((q) => q.content).toList(),
        second.map((q) => q.content).toList(),
        reason: '重复出题给出两套不同题目，学生会以为系统出错',
      );
    });
  });

  group('参考答案冻结', () {
    test('题库命中时返回具体答案', () async {
      final answer = await ai.referenceAnswerFor(
        subject: '数学',
        knowledgePoint: '分数计算',
      );

      expect(answer, isNotEmpty);
      expect(answer, contains('/'));
    });

    test('题库未覆盖时不编造具体答案，退化为通用解题要点', () async {
      // 「宁可给一份通用的解题要点，也不要假造一个具体答案」——
      // 假的参考答案会把做对的学生判成错的，比没有答案更糟。
      final answer = await ai.referenceAnswerFor(
        subject: '未知科目',
        knowledgePoint: '未知知识点',
      );

      expect(answer, contains('圈条件'));
      expect(
        answer,
        contains('未知知识点'),
        reason: '兜底答案也要点名知识点，否则学生不知道该看哪里',
      );
    });
  });
}
