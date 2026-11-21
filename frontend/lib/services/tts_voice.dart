import 'package:flutter/foundation.dart';

/// 伴读的**音色 / 来源约定**（虫子 11-08 定）：
///
/// ```
/// 男声 = 本机：① 手机本地缓存  ② 手机直连微软 Edge TTS
/// 女声 = 云端：③ 直连失败后退回网关 /ai/tts → 百炼 qwen3-tts-flash
/// ```
///
/// 目的是「一听就知道这次朗读从哪儿出声」，不用翻日志。
///
/// ## 为什么音色必须进缓存键（与语速正好相反）
///
/// 语速是播放层 `AudioPlayer.setSpeed` 的倍率，**音频字节没变**，所以缓存
/// 与语速无关（切档不重合成、断网也能慢）。音色却是**合成时写进字节**的：
/// 改了音色还沿用同一个键，手机里 v1 的 Aria 女声 mp3 会被直接命中 ——
/// 孩子听到女声、以为走了 Qwen，这个区分方案反而制造了最坏的误判。
///
/// 所以 [cacheSchema] 进 digest：旧目录自然作废（随后按 LRU 淘汰），新目录
/// 只放男声。🔴 **以后每换一次本地音色，必须 bump 这个版本号。**
///
/// ## 为什么 Qwen 那条路不再把音频落到本机
///
/// 以前 `_storeForOffline` 会把网关给的 wav 下载进同一个 digest 目录。
/// 让女声 wav 住进「本机缓存槽」，下次断网命中本地时仍是女声，
/// 「男声 = 本机」当场破功。云端兜底本来就是实时合成（URL 另有一份
/// 12 小时的缓存），不再写字节；**主路直连成功时照常落盘，断网可听不变**。
///
/// 一句话取舍：宁可「Qwen 兜底那次不留离线副本」，也不要一个听起来
/// 像云端、其实是本地的音频。
class TtsVoices {
  const TtsVoices._();

  /// Edge / 微软英文男声。Guy 是成年男声、吐字稳，慢速下也清楚。
  static const String localMaleEn = 'en-US-GuyNeural';

  /// Edge / 微软中文男声（云希）。
  /// 中文目前不走直连（`_tryDirect` 只放行 `en`），留着给以后放开时用。
  static const String localMaleZh = 'zh-CN-YunxiNeural';

  /// 百炼 `qwen3-tts-flash` 的女声「芊悦」。
  ///
  /// 已核官方文档《Qwen-TTS音色列表》（更新 2026-10-11）的**非实时**部分：
  /// Cherry = 阳光积极、亲切自然小姐姐（女性），支持英语。它不是实时型号
  /// 专属音色，用在 HTTP 的非实时接口上是厂商支持的。
  static const String cloudFemale = 'Cherry';

  /// 本地（直连）音色只允许从这一个函数取，别在别处再写一份字符串。
  static String localVoiceFor(String language) =>
      language == 'zh' ? localMaleZh : localMaleEn;

  /// 音频缓存的**模式版本**，参与 digest。
  ///
  /// v1（2026-11-07 及之前）＝ `sha256(语言\n正文)`，装的是 Aria 女声、
  /// 而且 Qwen 的 wav 会混进同一个槽。v2 起本地槽只放 Guy 男声。
  /// 这个字符串不是给人看的标签，换音色却不改它＝旧音频被当作新音色命中。
  static const String cacheSchema = 'local-male-v2';
}

/// 这一次朗读的声音从哪儿来。UI 把它显示成一行小字，作为音色的文字备份：
/// 万一设备外放听不出男女，也还有一处能看。
enum TtsAudioSource {
  /// 手机本地文件命中，完全不联网。
  local,

  /// 手机直连微软合成，不经自家服务器。
  direct,

  /// 直连失败，退回网关 / 百炼。
  cloud,
}

extension TtsAudioSourceX on TtsAudioSource {
  /// 只有云端那条是女声。音色约定与来源一一对应，别拆开改。
  bool get isMale => this != TtsAudioSource.cloud;

  String get label => switch (this) {
        TtsAudioSource.local => '男声 · 本机缓存（不联网）',
        TtsAudioSource.direct => '男声 · 手机直连朗读',
        TtsAudioSource.cloud => '女声 · 云端 Qwen 兜底',
      };
}

/// 最近一次朗读的来源。`null` = 现在没在念。
///
/// 放在这里而不是 `ServerTts` 内部，是为了让阅读页不必 import 播放器那坨
/// 依赖，也方便测试直接置值（widget 测试里 `speakForTest` 不会走真链路）。
final ValueNotifier<TtsAudioSource?> speechSource =
    ValueNotifier<TtsAudioSource?>(null);
