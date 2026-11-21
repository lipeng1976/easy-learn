import 'dart:io';
import 'dart:typed_data';

import 'package:easy_learn_app/services/edge_tts_client.dart';
import 'package:easy_learn_app/services/tts_audio_cache.dart';
import 'package:easy_learn_app/services/tts_chunk_feed.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「边播边合成」里唯一可以脱离真机验证的那一半：**取块的顺序、失败、
/// 续传**。播放器那一半只能真机看，所以这里把它剥掉了。
class _Env {
  _Env() {
    root = Directory.systemTemp.createTempSync('tts_feed_test_');
    cache = TtsAudioCache(rootDir: () async => root, fetch: (_) async => throw StateError('不该走网络'));
  }

  late Directory root;
  late TtsAudioCache cache;

  /// 每次合成被要走的文本，按顺序记下来 —— 顺序错了，念出来就是乱的。
  final List<String> calls = <String>[];

  TtsSynthFn synth({int failAt = -1, int bytes = 4096}) => (text, language) async {
    final index = calls.length;
    calls.add(text);
    if (index == failAt) {
      throw const EdgeTtsException('朗读接口拒绝连接 HTTP 403', code: 'forbidden');
    }
    return Uint8List.fromList(List<int>.filled(bytes, index + 1));
  };

  void dispose() {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄没放掉不影响判据
    }
  }
}

void main() {
  late _Env env;

  setUp(() => env = _Env());
  tearDown(() => env.dispose());

  const chunks = ['first part.', 'second part.', 'third part.'];

  test('一块一块按顺序交付，最后才提交成「完整的一篇」', () async {
    final feed = TtsChunkFeed(
      digest: 'd1',
      chunks: chunks,
      language: 'en',
      synthesize: env.synth(),
      cache: env.cache,
    );

    final files = <File>[];
    while (true) {
      final file = await feed.next();
      if (file == null) break;
      files.add(file);
    }

    expect(feed.finished, isTrue);
    expect(feed.failed, isFalse);
    expect(files.map((f) => f.uri.pathSegments.last).toList(), [
      '000.mp3',
      '001.mp3',
      '002.mp3',
    ]);

    // 提交之后才算「完整」—— 播放层下次才会走本地、完全不联网。
    final ready = await env.cache.lookup('d1');
    expect(ready, isNotNull);
    expect(ready!.length, 3);
  });

  test('中途失败：立刻停手，不写 meta —— 半篇音频宁可当没存过', () async {
    final feed = TtsChunkFeed(
      digest: 'd2',
      chunks: chunks,
      language: 'en',
      synthesize: env.synth(failAt: 1),
      cache: env.cache,
    );

    expect(await feed.next(), isNotNull); // 第一块成功
    expect(await feed.next(), isNull); // 第二块失败
    expect(feed.failed, isTrue);
    expect(feed.cause, isA<EdgeTtsException>());

    // 再取也不会「跳过坏的那块往后合成」—— 那会让课文缺一段。
    expect(await feed.next(), isNull);
    expect(env.calls.length, 2);

    expect(File('${env.root.path}/d2/meta.json').existsSync(), isFalse);
    expect(await env.cache.lookup('d2'), isNull);
  });

  test('失败原因原样带出去 —— 上层要靠 code 决定熔断多久', () async {
    final feed = TtsChunkFeed(
      digest: 'd3',
      chunks: chunks,
      language: 'en',
      synthesize: env.synth(failAt: 0),
      cache: env.cache,
    );

    expect(await feed.next(), isNull);
    final cause = feed.cause;
    expect(cause, isA<EdgeTtsException>());
    expect((cause! as EdgeTtsException).code, 'forbidden');
  });

  test('中断过的篇目续传：已有的块不重合成', () async {
    // 造出「上次念到第二块就停了」的现场：000、001 在，没有 meta。
    await env.cache.putChunk('d4', 0, Uint8List.fromList(List<int>.filled(4096, 9)));
    await env.cache.putChunk('d4', 1, Uint8List.fromList(List<int>.filled(4096, 9)));
    final ready = await env.cache.existingChunks('d4');

    final feed = TtsChunkFeed(
      digest: 'd4',
      chunks: chunks,
      language: 'en',
      synthesize: env.synth(),
      cache: env.cache,
      ready: ready,
    );

    while (await feed.next() != null) {}

    expect(env.calls, ['third part.']); // 只补缺的那一块
    expect((await env.cache.lookup('d4'))!.length, 3);
  });

  test('音频太短（写不进）算失败，不能拿杂音去播', () async {
    final feed = TtsChunkFeed(
      digest: 'd5',
      chunks: chunks,
      language: 'en',
      synthesize: env.synth(bytes: 10),
      cache: env.cache,
    );

    expect(await feed.next(), isNull);
    expect(feed.failed, isTrue);
    expect(feed.cause, isA<StateError>());
  });

  test('取完之后再取也没有东西 —— 不会无限循环', () async {
    final feed = TtsChunkFeed(
      digest: 'd6',
      chunks: const ['only one.'],
      language: 'en',
      synthesize: env.synth(),
      cache: env.cache,
    );

    expect(await feed.next(), isNotNull);
    expect(await feed.next(), isNull);
    expect(feed.finished, isTrue);
    expect(feed.failed, isFalse);
  });
}
