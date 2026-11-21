import 'package:easy_learn_app/utils/vocabulary_highlight.dart';
import 'package:flutter_test/flutter_test.dart';

/// 切片的不变量：所有片段拼起来必须与原文逐字相同。
///
/// 这条是**必须**的：丢一个空格、吞一个换行，页面看起来只是排版变了，
/// 没人会想到是切词切坏了。
void expectLossless(String source, List<VocabularyPiece> pieces) {
  expect(pieces.map((piece) => piece.text).join(), source);
}

List<String> highlighted(String source, List<String> words) => [
      for (final piece in splitVocabulary(source, words))
        if (piece.isVocabulary) piece.text,
    ];

void main() {
  group('命中', () {
    test('原形直接命中', () {
      const text = 'The young man walked into the room.';
      expect(highlighted(text, ['young']), ['young']);
    });

    test('句首大写也命中', () {
      const text = 'Young people learn fast.';
      expect(highlighted(text, ['young']), ['Young']);
    });

    test('同一段里出现多次，每一处都标', () {
      const text = 'The young man met a young woman.';
      expect(highlighted(text, ['young']), ['young', 'young']);
    });

    test('多个生词各标各的', () {
      const text = 'She felt hungry and tired after the long walk.';
      expect(highlighted(text, ['hungry', 'walk']), ['hungry', 'walk']);
    });
  });

  group('词形还原', () {
    test('过去式（规则 / 不规则）', () {
      expect(highlighted('He spent all his money.', ['spend']), ['spent']);
      expect(highlighted('They stopped at the corner.', ['stop']), ['stopped']);
      expect(highlighted('She married him last year.', ['marry']), ['married']);
      expect(highlighted('He won the game.', ['win']), ['won']);
    });

    test('三单 / 复数', () {
      expect(highlighted('She studies English every day.', ['study']), ['studies']);
      expect(highlighted('He enjoys the music.', ['enjoy']), ['enjoys']);
      expect(highlighted('Two boxes of apples.', ['box']), ['boxes']);
    });

    test('进行时', () {
      expect(highlighted('He is making a cake.', ['make']), ['making']);
      expect(highlighted('They are running fast.', ['run']), ['running']);
    });

    test('比较级 / 最高级', () {
      expect(highlighted('This one is easier.', ['easy']), ['easier']);
      expect(highlighted('He is the tallest boy.', ['tall']), ['tallest']);
    });
  });

  group('不误伤', () {
    test('词边界：短生词不会命中更长的词', () {
      const text = 'He started the car and went to the market.';
      // 生词 art：start / market 里都含 art，但都不是这个词
      expect(highlighted(text, ['art']), isEmpty);
    });

    test('生词没出现在正文里就什么都不标', () {
      const text = 'The weather is nice today.';
      expect(highlighted(text, ['give', 'lesson']), isEmpty);
    });

    test('空生词表原样返回', () {
      const text = 'Anything goes here.';
      final pieces = splitVocabulary(text, const []);
      expect(pieces.length, 1);
      expect(pieces.single.isVocabulary, isFalse);
      expectLossless(text, pieces);
    });

    test('空白生词不会凭空匹配', () {
      const text = 'Hello world.';
      expect(highlighted(text, ['', '   ']), isEmpty);
    });
  });

  group('逐字不丢', () {
    test('标点、换行、多空格都保留', () {
      const text = 'He  said, "stop!"\nThen he stopped.\n\nAnd left.';
      final pieces = splitVocabulary(text, ['stop']);
      expectLossless(text, pieces);
      expect(highlighted(text, ['stop']), ['stop', 'stopped']);
    });

    test('没有生词命中时也逐字不丢', () {
      const text = 'Line one.\nLine two — with a dash.';
      expectLossless(text, splitVocabulary(text, ['zzz']));
    });

    test('撇号不会被拆开', () {
      const text = "Don't stop believing.";
      final pieces = splitVocabulary(text, ['stop']);
      expectLossless(text, pieces);
      expect(highlighted(text, ['stop']), ['stop']);
    });

    test('空正文返回空列表', () {
      expect(splitVocabulary('', ['stop']), isEmpty);
    });
  });

  group('整段判定', () {
    test('vocabularyAppearsIn 能看到变形后的生词', () {
      expect(vocabularyAppearsIn('He spent a lot.', ['spend']), isTrue);
      expect(vocabularyAppearsIn('Nothing here.', ['spend']), isFalse);
    });
  });
}
