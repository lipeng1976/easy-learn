import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:just_audio/just_audio.dart';

import '../controllers/auth_controller.dart';
import 'ai_api_client.dart';
import 'ai_config.dart';
import 'database_service.dart';
import 'edge_tts_client.dart';
import 'speech_rate.dart';
import 'tts_audio_cache.dart';
import 'tts_voice.dart';

/// 单词打卡里的「点一下读这个单词」。
///
/// ⚠️ **刻意不复用 `ServerTts`**：那是全局单例 + 分块边合成边播 + 60s 超时 +
/// 全文 digest，对 1 个单词全是负担，而且会跟正在播的课文抢同一个播放器。
///
/// 三层与伴读同口径：① 本地音频命中（断网可听）→ ② 手机直连微软男声 →
/// ③ 网关 Qwen 女声兜底。**Qwen 那次不落盘**：否则女声文件会被误当成
/// 本地男声命中，「男声＝本机」这条来源约定就废了（11-08 踩过）。
///
/// 缓存键带 `word\n` 前缀与音色版本，与课文全文 digest 完全隔离。
class WordTts {
  WordTts._();

  static final ValueNotifier<bool> busy = ValueNotifier<bool>(false);
  static final ValueNotifier<String?> error = ValueNotifier<String?>(null);

  static AudioPlayer? _player;

  @visibleForTesting
  static TtsAudioCache audioCache = TtsAudioCache();

  @visibleForTesting
  static EdgeTtsClient edgeClient = const EdgeTtsClient();

  /// 测试接缝：替换真正的播放器（widget 测试里没有平台通道）。
  /// 回调拿到「路径 / URL、是不是本地文件、播放倍率」。
  @visibleForTesting
  static Future<void> Function(String target, bool isFile, double speed)?
      playForTest;

  /// 测试接缝：替换网关兜底，避免单测真联网。
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(String word)? cloudForTest;

  /// 测试接缝：flutter test 里 `defaultTargetPlatform` 不固定，判据不该依赖它。
  @visibleForTesting
  static bool? supportedForTest;

  static bool get isSupported =>
      supportedForTest ??
      (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS));

  /// ⚠️ 前缀 `word\n` 是隔离点：同一串文本既是单词又是课文里的句子时，
  /// 两边不能命中同一份音频（音色版本也必须进键，见 `TtsVoices.cacheSchema`）。
  static String digestOf(String word) => sha256
      .convert(utf8.encode('word\n${TtsVoices.cacheSchema}\n${word.trim()}'))
      .toString();

  static double get _speed => SpeechRateSettings.current.value.speed;

  static Future<void> speak(String word) async {
    final one = word.trim();
    if (one.isEmpty) return;
    if (!isSupported) {
      error.value = '这台设备暂时不能朗读单词，打卡不受影响。';
      return;
    }
    error.value = null;
    busy.value = true;
    try {
      final digest = digestOf(one);

      // ① 本地命中：完全不联网。
      final cached = await audioCache.lookup(digest);
      if (cached != null && cached.isNotEmpty) {
        await _play(cached.first.path, true);
        return;
      }

      // ② 直连微软（男声），合成结果落盘，下次断网也能听。
      try {
        final bytes = await edgeClient.synthesize(
          text: one,
          language: 'en',
          voice: TtsVoices.localMaleEn,
        );
        final file = await audioCache.putChunk(digest, 0, bytes, ext: 'mp3');
        if (file != null) {
          await audioCache.commit(digest, 1, ext: 'mp3');
          await _play(file.path, true);
          return;
        }
      } catch (_) {
        // 直连失败 → 静默走网关兜底，孩子不该看到 403。
      }

      // ③ Qwen 女声兜底：**不落盘**。
      final data = cloudForTest != null
          ? await cloudForTest!(one)
          : await _cloudTts(one);
      final segments = data['segments'];
      final url = segments is List && segments.isNotEmpty
          ? (segments.first is Map
              ? (segments.first['url'] ?? '').toString()
              : '')
          : '';
      if (url.isEmpty) {
        error.value = '暂时读不出这个单词的发音，打卡不受影响。';
        return;
      }
      await _play(url, false);
    } catch (_) {
      // 可选能力：设备不支持 / 断网且无缓存 → 灰字提示，绝不抛异常。
      error.value = '暂时读不出这个单词的发音，打卡不受影响。';
    } finally {
      busy.value = false;
    }
  }

  static Future<Map<String, dynamic>> _cloudTts(String word) async {
    // 取票只走 AiIdentity.resolve，且 session 必须是 cloud.api.session 那份
    // （项目硬约束：另建一份票的表现是网关 401，而本机一切正常）。
    final auth = Get.isRegistered<AuthController>()
        ? Get.find<AuthController>()
        : null;
    final client = AiApiClient(
      config: AiConfig.resolve(),
      identity: AiIdentity.resolve(
        session: DatabaseService.cloud?.api.session,
        localUserId: auth?.currentUser.value?.id,
      ),
    );
    try {
      return await client.postJson(
        AiEndpoints.tts,
        <String, Object?>{
          'text': word,
          'language': 'en',
          'voice': TtsVoices.cloudFemale,
        },
      );
    } finally {
      client.close();
    }
  }

  static Future<void> _play(String target, bool isFile) async {
    if (playForTest != null) {
      await playForTest!(target, isFile, _speed);
      return;
    }
    final player = _player ??= AudioPlayer();
    if (isFile) {
      await player.setFilePath(target);
    } else {
      await player.setUrl(target);
    }
    // 语速只在播放层控制：**音频字节与缓存都跟语速无关**（11-08 定）。
    await player.setSpeed(_speed);
    await player.play();
  }
}
