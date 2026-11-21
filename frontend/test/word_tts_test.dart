import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easy_learn_app/services/server_tts.dart';
import 'package:easy_learn_app/services/speech_rate.dart';
import 'package:easy_learn_app/services/tts_audio_cache.dart';
import 'package:easy_learn_app/services/tts_voice.dart';
import 'package:easy_learn_app/services/word_tts.dart';
import 'package:easy_learn_app/services/edge_tts_client.dart';

class _FakeCache extends TtsAudioCache {
  _FakeCache({this.cached = false});

  bool cached;
  int puts = 0;
  int commits = 0;
  String? lastDigest;

  @override
  Future<List<File>?> lookup(String digest) async {
    lastDigest = digest;
    return cached ? <File>[File('/fake/000.mp3')] : null;
  }

  @override
  Future<File?> putChunk(
    String digest,
    int index,
    Uint8List bytes, {
    String ext = 'mp3',
  }) async {
    puts += 1;
    lastDigest = digest;
    return File('/fake/000.mp3');
  }

  @override
  Future<void> commit(String digest, int count, {String ext = 'mp3'}) async {
    commits += 1;
    lastDigest = digest;
  }
}

class _FakeEdge extends EdgeTtsClient {
  const _FakeEdge({this.fail = false});

  final bool fail;

  @override
  Future<Uint8List> synthesize({
    required String text,
    String language = 'en',
    String? voice,
    Duration? timeout,
  }) async {
    if (fail) throw Exception('edge 403');
    return Uint8List.fromList(List<int>.filled(2048, 1));
  }
}

void main() {
  setUp(() {
    WordTts.supportedForTest = true;
    WordTts.error.value = null;
    WordTts.cloudForTest = null;
  });

  tearDown(() {
    WordTts.supportedForTest = null;
    WordTts.playForTest = null;
    WordTts.cloudForTest = null;
    SpeechRateSettings.current.value = SpeechRate.normal;
  });

  test('缓存键带 word 前缀，与课文全文 digest 不互串', () {
    final word = WordTts.digestOf('hello');
    final lesson = ServerTts.digestOf('hello', 'en');
    expect(word, isNot(lesson));
    expect(WordTts.digestOf(' hello '), word, reason: 'trim 后才进键');
    expect(WordTts.digestOf('Hello'), isNot(word), reason: '大小写不同是不同的词');
    expect(TtsVoices.cacheSchema, isNotEmpty, reason: '音色版本必须参与 digest');
    // 只比「和课文 digest 不相等」不够：课文那边多一段 language，去掉 word
    // 前缀后依然不相等，判据会假绿。这里直接盯住命名空间前缀本身。
    final withoutPrefix = sha256
        .convert(utf8.encode('${TtsVoices.cacheSchema}\nhello'))
        .toString();
    expect(word, isNot(withoutPrefix),
        reason: 'word\\n 前缀是隔离点，去掉就跟别的短文本撞车');
  });

  test('本地命中：完全不联网，直接播本地文件', () async {
    final cache = _FakeCache(cached: true);
    WordTts.audioCache = cache;
    WordTts.edgeClient = const _FakeEdge();
    String? played;
    bool? isFile;
    WordTts.playForTest = (target, file, speed) async {
      played = target;
      isFile = file;
    };
    WordTts.cloudForTest = (word) async => throw StateError('不该打网关');
    await WordTts.speak('hello');
    expect(played, '/fake/000.mp3');
    expect(isFile, isTrue);
    expect(cache.puts, 0);
  });

  test('直连男声：结果落盘、播本地文件、慢速档在播放层生效', () async {
    final cache = _FakeCache();
    final edge = _FakeEdge();
    WordTts.audioCache = cache;
    WordTts.edgeClient = edge;
    SpeechRateSettings.current.value = SpeechRate.slow;
    double? speed;
    bool? isFile;
    WordTts.playForTest = (target, file, value) async {
      isFile = file;
      speed = value;
    };
    await WordTts.speak('hello');
    expect(cache.puts, 1);
    expect(cache.commits, 1);
    expect(cache.lastDigest, WordTts.digestOf('hello'));
    expect(isFile, isTrue);
    expect(speed, SpeechRate.slow.speed, reason: '慢速只改播放器倍率，不重合成');
  });

  test('Qwen 女声兜底：不落盘，播的是 URL 而不是本地文件', () async {
    final cache = _FakeCache();
    WordTts.audioCache = cache;
    WordTts.edgeClient = const _FakeEdge(fail: true);
    String? cloudWord;
    WordTts.cloudForTest = (word) async {
      cloudWord = word;
      return <String, dynamic>{
        'segments': <Map<String, dynamic>>[
          <String, dynamic>{'url': 'https://tts.test/qwen.wav'},
        ],
      };
    };
    String? played;
    bool? isFile;
    WordTts.playForTest = (target, file, speed) async {
      played = target;
      isFile = file;
    };
    await WordTts.speak('hello');
    expect(cloudWord, 'hello');
    expect(played, 'https://tts.test/qwen.wav');
    expect(isFile, isFalse);
    expect(cache.puts, 0, reason: '女声落盘会污染「男声＝本机」的来源约定');
    expect(cache.commits, 0);
  });

  test('三层全失败 / 设备不支持：给灰字提示，绝不抛异常', () async {
    WordTts.audioCache = _FakeCache();
    WordTts.edgeClient = const _FakeEdge(fail: true);
    WordTts.cloudForTest = (word) async => throw Exception('gateway 500');
    await expectLater(WordTts.speak('hello'), completes);
    expect(WordTts.error.value, isNotNull);

    WordTts.supportedForTest = false;
    WordTts.error.value = null;
    await expectLater(WordTts.speak('hello'), completes);
    expect(WordTts.error.value, isNotNull);
  });

  test('设备不支持时连缓存都不碰（置灰喇叭点了也不产生副作用）', () async {
    final cache = _FakeCache(cached: true);
    WordTts.audioCache = cache;
    WordTts.edgeClient = const _FakeEdge();
    WordTts.playForTest = (_, _, _) async => throw StateError('不该播');
    WordTts.cloudForTest = (word) async => throw StateError('不该打网关');
    WordTts.supportedForTest = false;
    await expectLater(WordTts.speak('hello'), completes);
    expect(cache.lastDigest, isNull, reason: 'isSupported 要在最前面拦住');
    expect(WordTts.error.value, isNotNull);
    expect(WordTts.busy.value, isFalse, reason: '早退不能把 busy 永久卡住');
  });

  test('源码契约：喇叭置灰 + 页级一条灰字提示（不是十张卡各弹一句）', () {
    final page = File('lib/pages/student/word_drill_page.dart').readAsStringSync();
    expect(page.contains('WordTts.isSupported'), isTrue,
        reason: '设备不支持时喇叭要置灰');
    expect(page.contains('valueListenable: WordTts.busy'), isTrue,
        reason: '合成中不能再点，否则会连开好几个播放器');
    expect(page.contains('onPressed: enabled'), isTrue,
        reason: '置灰必须真的禁用 onPressed，不是只换颜色');
    expect(page.split('valueListenable: WordTts.error').length - 1, 1,
        reason: 'WordTts.error 是全局 ValueNotifier，十张卡各挂一条会变噪音');
  });
}
