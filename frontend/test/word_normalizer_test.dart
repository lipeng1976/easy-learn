import 'package:flutter_test/flutter_test.dart';
import 'package:easy_learn_app/utils/word_normalizer.dart';

/// ⚠️ 这组 golden vectors 与 `serverless/data-service/test/word-import.test.js`
/// 是**同一份样本**。两端各有一份同规则实现，改规则必须两边同步改，
/// 否则漂移会变成「选项里出现两个正确答案」这类没人报错的错题。
void main() {
  test('normalizeWord：去空白 / 小写 / 去首尾标点，内部撇号保留', () {
    expect(normalizeWord('  Hello. '), 'hello');
    expect(normalizeWord("It's"), "it's");
    expect(normalizeWord('**book**'), 'book');
    expect(normalizeWord('  '), '');
  });

  test('primaryMeaning：只取首义、去词性前缀', () {
    expect(primaryMeaning('n. 名字；名称'), '名字');
    expect(primaryMeaning('v 遇见；结识'), '遇见');
    expect(primaryMeaning('令人愉快的；宜人的'), '令人愉快的');
    expect(primaryMeaning('adj. 好的, 不错的'), '好的');
    expect(primaryMeaning('n.'), '');
  });
}
