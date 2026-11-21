import 'package:easy_learn_app/services/tts_chunker.dart';
import 'package:flutter_test/flutter_test.dart';

/// 切块的判据。
///
/// 最重要的一条不是「切成了几块」，而是**切完还能逐字拼回原文**：
/// 切错一个词，孩子听到一句原文里不存在的句子，界面上却毫无异常。
/// 这是本项目最典型的静默失败（声音出来了，内容不是人话）。

/// 空白归一，用来比较「拼回去等不等于原文」。
String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

void main() {
  test('长课文切成多块，第一块明显更小（首声要快）', () {
    final text = List.generate(
      12,
      (i) => 'Paragraph $i. This is a sentence that we use to fill the article '
          'so that the splitter has enough material to work with.',
    ).join('\n\n');

    final chunks = splitForSpeech(text);

    expect(chunks.length, greaterThan(2));
    // 第一块只为了让第一个词快点出来，不该跟后面的块一样长。
    expect(chunks.first.length, lessThan(chunks[1].length));
  });

  test('切完拼回去与原文一致 —— 一个字都不能少、不能重', () {
    final text = List.generate(
      9,
      (i) => 'Lesson $i starts here. Mr. Smith opened the window and looked out. '
          'It cost 3.14 dollars, which was cheap. Was it worth it? Yes!',
    ).join('\n\n');

    final chunks = splitForSpeech(text);

    expect(_norm(chunks.join(' ')), _norm(text));
  });

  test('缩写后面的点不算句末 —— Mr. 和后面的名字不会被拆开', () {
    final text = 'Mr. Smith walked into the room and sat down. '
        'He said hello to Mrs. Brown, then he left. '
        'Dr. Lee was already outside waiting for the bus.';

    // 阈值调到最小，等于强制「每句一块」—— 缩写一旦被当成句末，
    // `Mr.` 就会单独成块，和后面的名字分开念。
    final chunks = splitForSpeech(text, firstChunkChars: 3, targetChars: 3);

    expect(chunks, isNotEmpty);
    for (final pair in [('Mr.', 'Smith'), ('Mrs.', 'Brown'), ('Dr.', 'Lee')]) {
      final chunk = chunks.firstWhere(
        (c) => c.contains(pair.$1),
        orElse: () => '',
      );
      expect(chunk, isNotEmpty, reason: '找不到含 ${pair.$1} 的块');
      expect(
        chunk.contains(pair.$2),
        isTrue,
        reason: '${pair.$1} 被当成了句末，和后面的名字拆开了：$chunk',
      );
    }
    expect(_norm(chunks.join(' ')), _norm(text));
  });

  test('小数点不算句末 —— 3.14 不会被拆成两半', () {
    final text = 'The answer is 3.14 and the price is 2.50 today. '
        'Please remember it for the test tomorrow morning.';

    final chunks = splitForSpeech(text, firstChunkChars: 20, targetChars: 30);

    for (final chunk in chunks) {
      expect(RegExp(r'\d\.$').hasMatch(chunk), isFalse, reason: '在小数点处切断了：$chunk');
    }
    expect(_norm(chunks.join(' ')), _norm(text));
  });

  test('一句话的短课文只切一块 —— 别为了分块而分块', () {
    final chunks = splitForSpeech('Hello, this is a very short lesson.');
    expect(chunks.length, 1);
  });

  test('空文本返回空列表，不返回「一个空块」', () {
    expect(splitForSpeech('   \n\n  '), isEmpty);
    expect(splitForSpeech(''), isEmpty);
  });

  test('没有句号的超长段落也要切，且不切在单词中间', () {
    final text = List.filled(200, 'word').join(' '); // 999 字符、没有标点

    final chunks = splitForSpeech(text, firstChunkChars: 100, targetChars: 150, maxChars: 200);

    expect(chunks.length, greaterThan(1));
    for (final chunk in chunks) {
      expect(chunk.length, lessThanOrEqualTo(200));
      expect(chunk.startsWith(' '), isFalse);
    }
    // 每个块必须由完整单词组成：拼回去仍然是原文那 200 个 word。
    expect(_norm(chunks.join(' ')), _norm(text));
  });

  test('段落之间不会粘成一个词', () {
    final chunks = splitForSpeech('First part ends here.\n\nSecond part begins.');
    expect(_norm(chunks.join(' ')), 'First part ends here. Second part begins.');
  });
}
