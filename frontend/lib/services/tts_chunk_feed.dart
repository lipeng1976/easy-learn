import 'dart:io';

import 'package:flutter/foundation.dart';

import 'tts_audio_cache.dart';

/// 合成一块音频：`(文本, 语言) → 音频字节`。
///
/// 抽成函数类型是为了让 [TtsChunkFeed] 不依赖网络 —— 测试里塞一个
/// 假实现就能验证「顺序、失败、补齐」这些真正会出错的地方。
typedef TtsSynthFn = Future<Uint8List> Function(String text, String language);

/// 按顺序把分块课文变成音频文件，**一次交付一块**。
///
/// 上层拿到第一块就开始播，剩下的块在播放过程中由 [next] 一块块取。
///
/// 这个类只管「取下一块」，不碰播放器 —— 于是它的行为（尤其是失败之后
/// 不再继续、以及最后才写 `meta.json`）可以被单测直接盯住。播放那一半
/// 只能靠真机，所以越薄越好。
///
/// ## 为什么最后才提交
///
/// 中途没取完（学生按了暂停、翻页、断网）时本地会有前几块、没有
/// `meta.json`。`lookup` 见到没有 meta 就判「不完整」，于是下次从头补；
/// 而已经落盘的那几块会被 [TtsChunkFeed] 直接复用，不会重合成。
/// 也就是说：**中断 = 续传，不是报废**。
class TtsChunkFeed {
  TtsChunkFeed({
    required this.digest,
    required this.chunks,
    required this.language,
    required this.synthesize,
    required this.cache,
    Map<int, File>? ready,
  }) : _ready = ready ?? const <int, File>{};

  /// 这一篇的目录名（`sha256(语言 + 全文)`），也是缓存键。
  final String digest;

  /// 切好的块，顺序即播放顺序。
  final List<String> chunks;

  final String language;
  final TtsSynthFn synthesize;
  final TtsAudioCache cache;

  /// 上次中断留下的、已经可用的块。命中就跳过合成。
  final Map<int, File> _ready;

  int _cursor = 0;
  bool _failed = false;
  Object? _cause;

  bool get failed => _failed;

  /// 失败的**原始原因**（可能是 `EdgeTtsException`）。
  ///
  /// 上层要据此决定直连要不要熔断 —— 所以这里不能把它翻成一句人话了事。
  Object? get cause => _cause;

  bool get finished => _cursor >= chunks.length;

  /// 取下一块。
  ///
  /// - 还有块 → 返回该块的文件；
  /// - 全取完了 → 返回 null（[finished] 为真）；
  /// - 失败了 → 返回 null（[failed] 为真，[cause] 有原因），之后不再继续。
  ///
  /// 「取完了」和「失败了」都返回 null 是刻意的：调用方的处置完全相反
  /// （一个正常收尾，一个要提示孩子），所以必须看 [failed] 分辨，
  /// 而不是靠返回值猜。
  Future<File?> next() async {
    if (_failed || finished) return null;

    final index = _cursor;
    final cached = _ready[index];
    if (cached != null) {
      _cursor++;
      await _commitIfDone();
      return cached;
    }

    try {
      final bytes = await synthesize(chunks[index], language);
      final file = await cache.putChunk(digest, index, bytes);
      if (file == null) {
        _failed = true;
        _cause = StateError('第 ${index + 1} 块音频写不进本机');
        return null;
      }
      _cursor++;
      await _commitIfDone();
      return file;
    } catch (cause) {
      _failed = true;
      _cause = cause;
      debugPrint('伴读第 ${index + 1}/${chunks.length} 块合成失败：$cause');
      return null;
    }
  }

  /// 全部齐了才写 `meta.json` —— 半篇音频比没有更难排查（孩子以为课文被裁了）。
  Future<void> _commitIfDone() async {
    if (!finished) return;
    await cache.commit(digest, chunks.length);
  }
}
