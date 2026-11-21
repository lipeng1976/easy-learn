// 真联网的凭证测试。**不在 test/ 下**，所以 `flutter test` 默认不会跑它。
//
//   flutter test tool/live_edge_tts_test.dart
//
// 为什么单独放：它依赖微软那个非公开接口和外网。网络一抖整包测试就红，
// 那是把「环境问题」混成「代码坏了」。但发版前必须手动跑一次 ——
// 单元测试只能证明 SSML 拼得对，证明不了这条链路今天还通。
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:easy_learn_app/services/edge_tts_client.dart';
import 'package:easy_learn_app/services/tts_audio_cache.dart';
import 'package:easy_learn_app/services/tts_chunk_feed.dart';
import 'package:easy_learn_app/services/tts_chunker.dart';
import 'package:easy_learn_app/services/tts_voice.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('live：英文短句能合成出 mp3 字节', () async {
    final bytes = await const EdgeTtsClient().synthesize(
      text: 'Learning a language is like building a bridge. '
          'Every word you learn adds another plank.',
      language: 'en',
    );
    // 这句话对方给我们 37KB 左右；只要过千就说明真拿到音频了。
    expect(bytes.length, greaterThan(1000));
    // mp3 帧同步字：0xFF 后三位是 111
    expect(bytes[0], 0xFF);
    expect(bytes[1] & 0xE0, 0xE0);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('live：男声 Guy 可用，且接口真的按 voice 换了声音', () async {
    // 11-08 把本地默认音色从 Aria 女声换成 Guy 男声。这是微软的**非公开**
    // 接口，音色名不被支持时不会报「voice 无效」，只会静默回退或空音频 ——
    // 后果是直连整条路被熔断、全部退回 Qwen 女声，看起来像「一直在走云端」。
    // 所以发版前必须真连一次，并且证实两次合成的字节确实不同。
    const sample = 'Every word you learn adds another plank.';
    const client = EdgeTtsClient();
    final male = await client.synthesize(
      text: sample,
      language: 'en',
      voice: TtsVoices.localMaleEn,
    );
    final female = await client.synthesize(
      text: sample,
      language: 'en',
      voice: 'en-US-AriaNeural',
    );

    expect(male.length, greaterThan(1000), reason: 'Guy 男声没拿到音频');
    expect(female.length, greaterThan(1000));
    expect(male[0], 0xFF, reason: '不是 mp3 帧头');
    expect(female[0], 0xFF);
    expect(
      sha256.convert(male).toString(),
      isNot(sha256.convert(female).toString()),
      reason: '两段字节一样 = 接口忽略了 voice，换音色是假的',
    );
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('live：最长的一课按块合成，第一块多久能出声、整篇要多久', () async {
    // 与书里最长那一课（L15，4822 字符）等量。
    final paragraph = 'Is it worth it? That is the question the narrator keeps '
        'asking himself. Every morning he walks past the same shop window and '
        'stops to look at the same old bicycle. It is not expensive, but it is '
        'not cheap either. He has saved for three months, and now the money is '
        'finally enough. Yet he hesitates, because wanting something and '
        'needing it are two very different things. ';
    final text = List.filled(10, paragraph).join('\n\n').trim();

    final chunks = splitForSpeech(text);
    final root = Directory.systemTemp.createTempSync('tts_live_');
    final cache = TtsAudioCache(rootDir: () async => root);
    const client = EdgeTtsClient();

    final feed = TtsChunkFeed(
      digest: 'live',
      chunks: chunks,
      language: 'en',
      synthesize: (body, lang) => client.synthesize(text: body, language: lang),
      cache: cache,
    );

    final watch = Stopwatch()..start();
    final first = await feed.next();
    final firstMs = watch.elapsedMilliseconds;

    expect(first, isNotNull, reason: '第一块都没合成出来');
    final firstBytes = await first!.length();

    var rest = 0;
    while (await feed.next() != null) {
      rest++;
    }
    final totalMs = watch.elapsedMilliseconds;

    // 这两条不设硬性阈值（网络会抖），只把数字打出来供人判断 ——
    // 真正的判据是「第一块明显小于整篇耗时」这个量级关系。
    // ignore: avoid_print
    print('LIVE 字符=${text.length} 块数=${chunks.length} '
        '第一块=${chunks.first.length}字/${firstBytes}B 首声=${firstMs}ms '
        '其余$rest块 合计=${totalMs}ms');

    expect(feed.failed, isFalse);
    expect(chunks.length, greaterThan(1));
    expect(firstMs * 3, lessThan(totalMs), reason: '分块没换来更早出声');
    expect(await cache.lookup('live'), isNotNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
