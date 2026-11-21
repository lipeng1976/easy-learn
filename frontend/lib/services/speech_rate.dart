import 'package:flutter/foundation.dart';

import 'database_service.dart';

/// 英文伴读的语速档位（11-08 加）。
///
/// 只给两档是刻意的：给小朋友选，滑杆上那 20 个刻度没有意义，
/// 「正常 / 慢速」一眼能懂，也不必每次朗读前都调一次。
///
/// ## 为什么是「播放变速」而不是「让模型念慢一点」
///
/// 伴读有三条音源（本机缓存 → 手机直连微软 → 网关 /ai/tts），而百炼
/// `qwen3-tts-flash` 的 HTTP 接口**没有可靠的语速参数**（只有音色和
/// language_type；`instructions` 要换 instruct 版模型）。若靠合成端变速：
///   · 断网时已缓存的正常速音频没法变慢，选了慢速反而听不了；
///   · 切一次档要把整篇重新合成一遍（最长那课 15 秒）；
///   · 三种音源各有一套缓存，慢速音频和正常速音频串了就是「选了没反应」。
///
/// 所以统一在 `just_audio` 播放层做 **0.8× 时间拉伸，音高保持 1.0**
/// （已核 0.10.6 源码：Android 走 `PlaybackParameters(speed, pitch)`，
/// 加载新音源时会重新应用 speed）。音频字节与档位无关，**缓存不需要分家**，
/// 已存到手机里的课文切慢速立刻生效，念到一半切也立刻生效。
///
/// 代价：听感是「放慢的录音」而不是模型重新用慢节奏念。给小朋友跟读
/// 用这是可接受的（和视频 0.8× 一档），换来的是离线可用 + 切换零等待。
enum SpeechRate {
  normal(1.0, '正常', 'normal'),
  slow(0.8, '慢速', 'slow');

  const SpeechRate(this.speed, this.label, this.storageValue);

  /// 传给 `AudioPlayer.setSpeed` 的倍率。1.0 = 原速。
  final double speed;

  /// 界面上的文字。**别拿它当测试锚点**，用 `storageValue` 拼 key。
  final String label;

  /// 写进 `app_setting` 的值。认不出一律回落到 [normal]。
  final String storageValue;

  static SpeechRate fromStorage(String? raw) =>
      raw == slow.storageValue ? slow : normal;
}

/// 伴读语速的全局状态 + 本机持久化。
///
/// 与「讲题朗读」的 `TtsSettingsSheet` 是两套东西：那边调的是手机系统
/// TTS 引擎的语速（讲中文），这边调的是**英文伴读**的播放倍率。分开存，
/// 免得家长在设置里调了讲题语速，孩子听英文忽然变快/变慢。
abstract final class SpeechRateSettings {
  static const String storageKey = 'reading.speechRate';

  /// 当前档位。UI 与播放器都看这一份，切档即时生效。
  static final ValueNotifier<SpeechRate> current =
      ValueNotifier<SpeechRate>(SpeechRate.normal);

  /// 本次启动后用户**主动选过**没有。
  ///
  /// 冷启动时 [load] 是异步的：孩子手快，在 DB 读回来之前就点了「慢速」，
  /// 随后 load 不能把他的选择覆盖回「正常」。有这面旗就不会。
  static bool _touched = false;

  /// 测试接缝：换掉本机读写。
  @visibleForTesting
  static Future<String?> Function(String key)? readForTest;

  @visibleForTesting
  static Future<void> Function(String key, String value)? writeForTest;

  /// 从本机读出上次的档位。读不到 / 读坏了都按正常速，**不抛**：
  /// 一个偏好项坏掉的正确表现是「用默认值」，不是让阅读页打不开。
  static Future<void> load() async {
    String? raw;
    try {
      final read = readForTest;
      raw = read != null
          ? await read(storageKey)
          : await DatabaseService.instance.readLocalSetting(storageKey);
    } catch (_) {
      return;
    }
    if (_touched) return;
    current.value = SpeechRate.fromStorage(raw);
  }

  /// 选一档。先改内存再落盘：写失败只影响下次启动，不该让这一次的
  /// 点击「看起来没反应」，更不能把播放打断。
  static Future<void> select(SpeechRate rate) async {
    _touched = true;
    current.value = rate;
    try {
      final write = writeForTest;
      if (write != null) {
        await write(storageKey, rate.storageValue);
      } else {
        await DatabaseService.instance.writeLocalSetting(
          storageKey,
          rate.storageValue,
        );
      }
    } catch (_) {
      debugPrint('伴读语速没存上（这次仍然生效）：$storageKey');
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _touched = false;
    current.value = SpeechRate.normal;
  }
}
