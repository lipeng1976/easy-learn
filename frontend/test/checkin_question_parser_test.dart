import 'dart:convert';

import 'package:easy_learn_app/services/checkin_question_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CheckinQuestionParser', () {
    test('解析标准 choice JSON，保留 LaTeX', () {
      final json = jsonEncode({
        'questions': [
          {
            'stem': r'若 $x+3=15$，则 $x=?$',
            'options': ['A. 11', 'B. 12', 'C. 13', 'D. 14'],
            'answer': 'B',
            'knowledge': '解一元一次方程',
            'analysis': r'移项得 $x=15-3=12$'
          }
        ]
      });
      final res = CheckinQuestionParser.parse(json);
      expect(res.questions.length, 1);
      final q = res.questions.first;
      expect(q.type, CheckinQuestionType.choice);
      expect(q.answer, 'B');
      expect(q.options.length, 4);
      expect(q.stem.contains(r'$x+3=15$'), isTrue);
      expect(q.analysis, r'移项得 $x=15-3=12$');
    });

    test('带 ```json 围栏与前后散文也能解析', () {
      final raw = '这是题目：\n```json\n'
          '{"questions":[{"stem":"2+2=?","options":["A.3","B.4"],"answer":"B","knowledge":"加法"}]}'
          '\n```\n完毕';
      final res = CheckinQuestionParser.parse(raw);
      expect(res.questions.length, 1);
      expect(res.questions.first.answer, 'B');
    });

    test('判断题答案 正确/错误 归一为 T/F', () {
      final json = jsonEncode({
        'questions': [
          {
            'stem': '0 是偶数',
            'options': ['正确', '错误'],
            'answer': '正确',
            'type': 'judge'
          },
          {
            'stem': '1 是质数',
            'options': ['正确', '错误'],
            'answer': '错误',
            'type': 'judge'
          },
        ]
      });
      final res = CheckinQuestionParser.parse(json);
      expect(res.questions.length, 2);
      expect(res.questions[0].answer, 'T');
      expect(res.questions[1].answer, 'F');
      expect(res.questions[0].isJudge, isTrue);
    });

    test('答案不在选项范围 -> 该条被跳过、好题保留、留警告', () {
      final json = jsonEncode({
        'questions': [
          {'stem': '好的', 'options': ['A.1', 'B.2'], 'answer': 'A'},
          {
            'stem': 'q',
            'options': ['A.1', 'B.2'],
            'answer': 'C'
          } // 越界，应被跳过
        ]
      });
      final res = CheckinQuestionParser.parse(json);
      expect(res.questions.length, 1);
      expect(res.warnings.length, 1);
      expect(res.questions.first.answer, 'A');
    });

    test('全部题目都坏 -> 抛异常（触发本地兜底）', () {
      final json = jsonEncode({
        'questions': [
          {
            'stem': 'q',
            'options': ['A.1', 'B.2'],
            'answer': 'C'
          }
        ]
      });
      expect(() => CheckinQuestionParser.parse(json),
          throwsA(isA<CheckinQuestionParseException>()));
    });

    test('非法 JSON 抛 CheckinQuestionParseException', () {
      expect(() => CheckinQuestionParser.parse('完全不是 json'),
          throwsA(isA<CheckinQuestionParseException>()));
    });

    test('缺 questions 数组抛异常', () {
      expect(() => CheckinQuestionParser.parse('{"foo":1}'),
          throwsA(isA<CheckinQuestionParseException>()));
    });

    test('LaTeX 单反斜杠丢失可修复（frac -> \\frac）', () {
      // 模拟模型把 \frac 写成 frac（无反斜杠）的损坏输入
      const broken =
          '{"questions":[{"stem":"frac{1}{2} 的一半","options":["A. frac{1}{4}","B. frac{1}{3}"],"answer":"A","knowledge":"分数"}]}';
      final res = CheckinQuestionParser.parse(broken);
      expect(res.questions.first.stem.contains(r'\frac'), isTrue);
      expect(res.questions.first.options.first.contains(r'\frac'), isTrue);
    });

    test('已正确的 \\frac 不被二次破坏（幂等）', () {
      final json = jsonEncode({
        'questions': [
          {
            'stem': r'计算 $\frac{1}{2}+\frac{1}{3}$',
            'options': [r'A. $\frac{5}{6}$', r'B. $\frac{2}{5}$'],
            'answer': 'A',
            'knowledge': '分数加法'
          }
        ]
      });
      final res = CheckinQuestionParser.parse(json);
      expect(res.questions.first.stem.contains(r'\frac{1}{2}'), isTrue);
      expect(res.questions.first.stem.contains(r'\\frac'), isFalse);
    });

    test('多题批量：坏题被跳过、好题保留、警告累积', () {
      final json = jsonEncode({
        'questions': [
          {'stem': '好的', 'options': ['A.1', 'B.2'], 'answer': 'A'},
          {'stem': '缺答案', 'options': ['A.1', 'B.2']},
          {'stem': '好的2', 'options': ['A.1', 'B.2'], 'answer': 'B'},
        ]
      });
      final res = CheckinQuestionParser.parse(json);
      expect(res.questions.length, 2);
      expect(res.warnings.length, 1);
    });
  });
}
