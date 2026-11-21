import 'package:easy_learn_app/utils/speech_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LaTeX 转口语', () {
    test(r'\frac 按中文语序读成「分母 分之 分子」', () {
      expect(speakableMath(r'\frac{x-1}{2}'), '2 分之 x-1');
    });

    test('嵌套分式从里往外读', () {
      expect(speakableMath(r'\frac{\frac{1}{2}}{3}'), '3 分之 2 分之 1');
    });

    test('平方与立方有专门读法，其余读作次方', () {
      expect(speakableMath('x^2 + 2x + 1'), 'x 的平方 + 2x + 1');
      expect(speakableMath('a^3'), 'a 的立方');
      expect(speakableMath(r'10^{-2}'), '10 的 -2 次方');
      expect(speakableMath(r'x^{n+1}'), 'x 的 n+1 次方');
    });

    test(r'^\circ 直接读「度」，不再叠一层「次方」', () {
      expect(speakableMath(r'90^\circ'), '90度');
    });

    test('根号与 n 次方根', () {
      expect(speakableMath(r'\sqrt{16}'), '根号 16');
      expect(speakableMath(r'\sqrt[3]{8}'), '8 的 3 次方根');
    });

    test('不等号的读法', () {
      expect(speakableMath(r'a \leq b'), 'a 小于等于 b');
      expect(speakableMath(r'x \neq 0'), 'x 不等于 0');
      expect(speakableMath(r'\pi \approx 3.14'), '派 约等于 3.14');
    });

    test('下标读作「下标」', () {
      expect(speakableMath('a_1 + a_2'), 'a 下标 1 + a 下标 2');
    });

    test('去掉数学定界符，但不动正文里的单个美元符', () {
      expect(speakableMath(r'$x+1$ 等于 $2$'), 'x+1 等于 2');
      expect(speakableMath(r'价格 $5'), r'价格 $5');
    });

    test('未闭合的公式不崩，也不把反斜杠念出来', () {
      final spoken = speakableMath(r'$\frac{1}$');
      expect(spoken.contains(r'\'), isFalse);
      expect(spoken.contains('frac'), isFalse);
    });

    test(r'\text{...} 只去掉命令、保留内容', () {
      expect(speakableMath(r'\text{面积} = 12'), '面积 = 12');
    });
  });

  group('Markdown 清理', () {
    test('去掉加粗标记与列表符号', () {
      expect(speakableText('**先通分**\n- 再相加\n> 注意符号'), '先通分\n再相加\n注意符号');
    });

    test('数字前的负号不会被当成列表符号删掉', () {
      expect(speakableText('-1 和 -2'), '-1 和 -2');
    });
  });

  group('讲解稿拼接', () {
    test('五段按「考点 → 错因 → 步骤 → 提醒 → 记忆点」排列', () {
      final spoken = explanationSpeechText(
        knowledgePoint: '分数加法',
        position: '七年级上册第三章',
        whyWrong: '分母没有通分',
        steps: [r'先通分：\frac{1}{2}+\frac{1}{3}=\frac{5}{6}', '再约分'],
        pitfalls: ['忘记通分'],
        mnemonic: '异分母先通分',
      );
      expect(spoken, contains('这道题考的是分数加法，七年级上册第三章。'));
      expect(spoken, contains('你错在：分母没有通分。'));
      expect(spoken, contains('第1步，先通分：2 分之 1+3 分之 1=6 分之 5。'));
      expect(spoken, contains('第2步，再约分。'));
      expect(spoken, contains('容易出错的地方：1，忘记通分。'));
      expect(spoken, contains('一句话记住：异分母先通分。'));
      expect(spoken.contains('考的是'), isTrue);
      expect(spoken.indexOf('考的是') < spoken.indexOf('你错在'), isTrue);
      expect(spoken.indexOf('你错在') < spoken.indexOf('第1步'), isTrue);
      expect(spoken.indexOf('第1步') < spoken.indexOf('容易出错'), isTrue);
    });

    test('空字段不会留下「：。」这种半截句子', () {
      final spoken = explanationSpeechText(
        knowledgePoint: '分数加法',
        position: '',
        whyWrong: '',
        steps: const [],
        pitfalls: const [],
        mnemonic: '',
      );
      expect(spoken, '这道题考的是分数加法。');
    });

    test('已经是句号的句子不重复加句号', () {
      final spoken = explanationSpeechText(
        knowledgePoint: '分数加法',
        position: '',
        whyWrong: '没有通分。',
        steps: const [],
        pitfalls: const [],
        mnemonic: '',
      );
      expect(spoken, contains('你错在：没有通分。'));
      expect(spoken.contains('。。'), isFalse);
    });
  });

  group('长稿切段', () {
    test('每段都不超过上限，且内容不丢', () {
      final text = List<String>.generate(60, (i) => '第$i句话大概有十几个字。').join();
      final chunks = splitForSpeech(text, maxChars: 100);
      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(chunk.length, lessThanOrEqualTo(100));
        expect(chunk.isEmpty, isFalse);
      }
      expect(chunks.join(), text);
    });

    test('没有标点的超长文本硬切，不抛异常', () {
      final chunks = splitForSpeech('a' * 250, maxChars: 100);
      expect(chunks.length, 3);
      expect(chunks.every((chunk) => chunk.length <= 100), isTrue);
      expect(chunks.join(), 'a' * 250);
    });

    test('空文本得到空列表', () {
      expect(splitForSpeech('   '), isEmpty);
    });
  });

  group('按句切开（句间要能喘气）', () {
    test('一句一段：整篇不会一口气念到完', () {
      final sentences = splitIntoSentences(
        '这道题考的是一元一次方程。先移项，再合并同类项。最后验算一下。',
      );
      expect(sentences, [
        '这道题考的是一元一次方程。',
        '先移项，再合并同类项。',
        '最后验算一下。',
      ]);
    });

    test('末尾没有标点也算一句，不会整段被丢掉', () {
      expect(splitIntoSentences('把分子分母同时除以 2'), ['把分子分母同时除以 2']);
    });

    test('连续标点跟着同一句走，不析出只有「。」的一句', () {
      final sentences = splitIntoSentences('真的吗？！不可能。');
      expect(sentences, ['真的吗？！', '不可能。']);
    });

    test('换行也是句子边界（讲解稿是按段拼的）', () {
      final sentences = splitIntoSentences('第一段。\n第二段。');
      expect(sentences, ['第一段。', '第二段。']);
    });

    test('空行不产生空句子', () {
      expect(splitIntoSentences('第一句。\n\n\n第二句。'), ['第一句。', '第二句。']);
    });

    test('超长句落在逗号上切，不从词中间砍', () {
      // 每 6 个字一个逗号：第 40 个字是「丁」，离它最近的逗号在后面第 41 位。
      // 软切应停在 36（最后一个逗号之后），硬切会停在 40 —— 两者结果不同，
      // 这条用例才真的能区分「有没有找软切点」。
      const unit = '甲乙丙丁戊，';
      final sentence = unit * 12 + '结束。';
      final pieces = splitIntoSentences(sentence, maxChars: 40);
      expect(pieces.length, 2);
      expect(pieces.first.length, 36);
      expect(pieces.first.endsWith('，'), isTrue);
      expect(pieces.join(), sentence);
    });

    test('够短的那句原样留下，不会被切成更小的碎片', () {
      // 前 240 个字没有标点 ⇒ 只能硬切；剩下 9 个字含标点却已经够短，
      // 所以必须整句留下 —— 碎成更小的片段会念得比原来更糟。
      final sentence = '${'甲乙丙丁' * 60}，然后再移项求解。';
      final pieces = splitIntoSentences(sentence, maxChars: 40);
      expect(pieces.length, 7);
      expect(pieces.last, '，然后再移项求解。');
      expect(pieces.join(), sentence);
    });

    test('一个逗点都没有时退化为硬切，但结果拼回去必须完整', () {
      final sentence = '甲乙丙丁' * 100;
      final pieces = splitIntoSentences(sentence, maxChars: 50);
      expect(pieces.length, 8);
      expect(pieces.join(), sentence);
      for (final piece in pieces) {
        expect(piece.length, lessThanOrEqualTo(50));
      }
    });

    test('空文本得到空列表', () {
      expect(splitIntoSentences('  \n '), isEmpty);
    });
  });

  group('英文课文断句（伴读）', () {
    const lesson =
        'Tom is a little boy. He likes swimming very much! '
        'Do you know why? Because the water is cool.';

    test('按英文句末标点切开，一句一段', () {
      final sentences = splitIntoSentences(lesson, english: true);
      expect(sentences, [
        'Tom is a little boy.',
        'He likes swimming very much!',
        'Do you know why?',
        'Because the water is cool.',
      ]);
    });

    test('🔴 不切给 english: true 的话，整篇会被当成一句', () {
      // 这就是「念英文像念稿」的根因：中文那套只认 。！？；，
      // 英文文章里一个都没有 → 整段一次交给引擎，从头到尾不换气。
      // 断言必须钉在「数量」上：只看内容拼回去，两种切法都等于原文。
      expect(splitIntoSentences(lesson).length, 1);
      expect(splitIntoSentences(lesson, english: true).length, 4);
    });

    test('省略号不会被切成一句「...」', () {
      final sentences = splitIntoSentences('Wait... what happened?', english: true);
      expect(sentences, ['Wait...', 'what happened?']);
    });

    test('英文不把分号当句末（后面还是同一句话）', () {
      final sentences = splitIntoSentences('I came; I saw; I conquered.', english: true);
      expect(sentences.length, 1);
    });

    test('超长英文按空格软切，不把单词拦腰砍断', () {
      final text = List.filled(60, 'wonderful').join(' ');
      final pieces = splitIntoSentences(text, maxChars: 50, english: true);
      expect(pieces.length, greaterThan(1));
      for (final piece in pieces) {
        expect(piece.length, lessThanOrEqualTo(50));
        // 硬切的产物会是 "wonderf" 这种半个词，这里必须每个词都完整。
        for (final word in piece.split(' ')) {
          expect('wonderful'.startsWith(word) || word.isEmpty, isTrue);
        }
      }
    });

    test('切段（3000 字符上限）也认英文句号', () {
      // 超过上限才会走切段逻辑：英文没有 `。` 时以前只能整块硬切，
      // 3000 字符正好落在句子中间，念出来是半截话。
      final long = List.filled(400, 'This is a sentence.').join(' ');
      final chunks = splitForSpeech(long, english: true);
      expect(chunks.length, greaterThan(1));
      expect(chunks.every((c) => c.length <= 3000), isTrue);
      // 每一块都必须停在句号上，不能停在句子中间。
      for (final chunk in chunks) {
        expect(chunk.trimRight().endsWith('.'), isTrue, reason: '切在了句子中间：${chunk.substring(chunk.length - 20)}');
      }
      expect(chunks.join(' ').replaceAll(RegExp(r'\s+'), ' '), long);
    });
  });
}
