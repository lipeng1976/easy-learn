import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:easy_learn_app/services/server_tts.dart';
import 'package:easy_learn_app/services/tts_audio_cache.dart';
import 'package:easy_learn_app/services/tts_voice.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「男声 = 本机 / 直连，女声 = 云端 Qwen」这条约定的判据。
///
/// 最要紧的不是「常量写对了」，而是**旧缓存不会把新约定毁掉**：
/// 音色写在音频字节里，改了音色却沿用旧 digest，升级后第一次点伴读
/// 会直接命中手机里 v1 的 Aria 女声 mp3 —— 听到女声，误判成走了 Qwen。
/// 这正是本项目最怕的那种「功能安静地不对」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const text = 'Poor or Rich';
  const lang = 'en';

  /// v1（2026-11-07 及之前）的键：`sha256(语言\n正文)`。
  String legacyDigest(String t, String l) =>
      sha256.convert(utf8.encode('$l\n$t')).toString();

  group('音色与来源一一对应', () {
    test('本机 / 直连用男声，云端 Qwen 用女声', () {
      expect(TtsVoices.localMaleEn, 'en-US-GuyNeural');
      expect(TtsVoices.localMaleZh, 'zh-CN-YunxiNeural');
      // 已核阿里云《Qwen-TTS音色列表》非实时部分（2026-10-11）：
      // Cherry = 芊悦，女性，支持英语。
      expect(TtsVoices.cloudFemale, 'Cherry');
      expect(TtsVoices.localVoiceFor('en'), isNot(TtsVoices.cloudFemale));
      expect(TtsVoices.localVoiceFor('zh'), isNot(TtsVoices.cloudFemale));
      expect(TtsVoices.cacheSchema, contains('male'));
    });

    test('三个来源的男女标注不能串', () {
      expect(TtsAudioSource.local.isMale, isTrue);
      expect(TtsAudioSource.direct.isMale, isTrue);
      expect(TtsAudioSource.cloud.isMale, isFalse);
      expect(TtsAudioSource.local.label, contains('男声'));
      expect(TtsAudioSource.direct.label, contains('男声'));
      expect(TtsAudioSource.cloud.label, contains('女声'));
      expect(TtsAudioSource.cloud.label, contains('云端'));
    });

    test('没在念时来源为空（不显示徽标）', () {
      expect(speechSource.value, isNull);
    });

    test('网关请求体固定带女声 Cherry', () {
      final body = ServerTts.ttsBodyFor(text, lang);
      expect(body['text'], text);
      expect(body['language'], lang);
      expect(body['voice'], TtsVoices.cloudFemale);
      expect(body['voice'], 'Cherry');
    });
  });

  group('缓存键必须随音色变', () {
    test('新 digest ≠ v1 旧 digest', () {
      expect(ServerTts.digestOf(text, lang), isNot(legacyDigest(text, lang)));
    });

    test('同一篇稳定；换正文 / 换语言都换键', () {
      final a = ServerTts.digestOf(text, lang);
      expect(ServerTts.digestOf(text, lang), a);
      expect(ServerTts.digestOf('$text!', lang), isNot(a));
      expect(ServerTts.digestOf(text, 'zh'), isNot(a));
    });

    test('真目录：v1 女声缓存完整可命中，但新代码查的是另一个键', () async {
      final tmp = await Directory.systemTemp.createTemp('tts_voice_test');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      final root = Directory('${tmp.path}/tts');
      final cache = TtsAudioCache(rootDir: () async => root);

      final legacy = legacyDigest(text, lang);
      final dir = Directory('${root.path}/$legacy');
      await dir.create(recursive: true);
      await File('${dir.path}/000.mp3').writeAsBytes(Uint8List(2048));
      await File('${dir.path}/meta.json').writeAsString(jsonEncode({
        'count': 1,
        'bytes': 2048,
        'ext': 'mp3',
        'at': DateTime.now().toIso8601String(),
      }));

      // 先证明这份「旧缓存」本身是完整有效的；否则下面那条 null
      // 什么也说明不了（目录根本没造对也会返回 null）。
      expect(
        await cache.lookup(legacy),
        isNotNull,
        reason: '假缓存必须真的可命中，这条判据才有意义',
      );
      expect(
        await cache.lookup(ServerTts.digestOf(text, lang)),
        isNull,
        reason: '换了音色还复用旧键 = 升级后第一次朗读会放出旧女声',
      );
    });

    test('网关兜底不再往本地音频缓存写 wav（静态闸门）', () {
      // 这是防回归的文本闸门，不是行为证明：真跑通 `_play` 需要平台播放器，
      // widget 测试里走的是 `speakForTest` 分支。它只负责挡住「有人把
      // _storeForOffline 加回来」，让女声 wav 混进男声缓存槽这件事不会发生。
      final file = File('lib/services/server_tts.dart');
      expect(file.existsSync(), isTrue, reason: 'flutter test 的工作目录应是包根目录');
      final src = file.readAsStringSync();
      expect(src.contains('audioCache.save('), isFalse);
      expect(src.contains('_storeForOffline'), isFalse);
      // 反过来：真链路**必须**发布来源，否则底栏那行小字永远不出现，
      // 而 widget 测试走的是 speakForTest 分支，看不出这个洞。
      expect(
        src.contains('speechSource.value = plan.source;'),
        isTrue,
        reason: '只有 _play 真的置了来源，男/女声的文字备份才会出现',
      );
    });
  });
}
