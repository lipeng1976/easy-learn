import 'package:easy_learn_app/services/homework_text_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// 文本解析是**纯规则**，因此断言可以写得很死 ——
/// 这正是它不交给模型的原因：同一段文本必须每次解析出同一份结果。
void main() {
  test('parses one paper into subject-grouped homework tasks', () {
    const text = '1.语文：背诵第二课；小作文《新学期新希望》\n2.数学：资料第8-9页；试卷一套\n3.英语：听写单词unit2';

    final tasks = HomeworkTextParser.parse(text);

    expect(tasks.length, 5);
    expect(tasks[0], {'subject': '语文', 'text': '背诵第二课'});
    expect(tasks[1], {'subject': '语文', 'text': '小作文《新学期新希望》'});
    expect(tasks[2], {'subject': '数学', 'text': '资料第8-9页'});
    expect(tasks[3], {'subject': '数学', 'text': '试卷一套'});
    expect(tasks[4], {'subject': '英语', 'text': '听写单词unit2'});
  });
}
