import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 伴读音频的**本地副本** —— 「断网也能读」的地基。
///
/// ## 为什么不沿用「只缓存 URL」
///
/// 之前 `server_tts.dart` 缓存的是一份 JSON：`{urls, at}`，TTL 12 小时。
/// 它只省掉一次合成请求，**断网时播放器拿不到任何字节** —— 学生点「伴读」
/// 只会看到「连不上朗读服务」。
///
/// 这套做法参考 `REA-projects/podcast`（听见）的 `tcGet/tcPut`：
///
///  · **先查本地，命中就完全不发请求** —— 不是「请求失败了再退回本地」，
///    那是两回事：弱网下前者秒开，后者要等一次超时。
///  · 落盘**不阻塞播放** —— 出声不等写完。
///  · 按「最近使用」淘汰，命中时刷新时间戳。
///  · **任一段缺失即整篇作废** —— 半篇音频会让孩子以为课文被裁了。
///
/// 与听见的差别：听见自己切 90 字的段、每段一个缓存键；伴学的网关那条
/// 由服务端决定分段（一篇 1~3 段），直连那条由 `tts_chunker` 切块。
/// 所以目录里是 `<digest>/000.mp3 …`，**块数与来源无关**——只要 `meta.json`
/// 说的块数都在，就算完整。
class TtsAudioCache {
  TtsAudioCache({
    this.rootDir,
    this.fetch,
    this.limitBytes = defaultMaxBytes,
    this.keepBytes = defaultKeepBytes,
  });

  /// 测试接缝：换掉根目录。生产走 [getApplicationSupportDirectory]。
  final Future<Directory> Function()? rootDir;

  /// 测试接缝：换掉真正的 HTTP 下载。生产传 null 走 [http.Client]。
  final Future<List<int>> Function(String url)? fetch;

  /// 上限 200MB，超了删到 150MB。
  ///
  /// 为什么按字节而不是听见那样按「段数」：听见一段固定 90 字、15~25KB，
  /// 段数好算；伴学一篇 1200 字约 3~5MB，篇幅差异大，按篇数估不准占用。
  static const int defaultMaxBytes = 200 * 1024 * 1024;
  static const int defaultKeepBytes = 150 * 1024 * 1024;

  /// 上限与「删到多少」。测试注入小额度，不然要造 200MB 数据才能验淘汰。
  final int limitBytes;
  final int keepBytes;

  Future<Directory> _root() async {
    final make = rootDir;
    if (make != null) return make();
    // 用 support 目录，不用 temporary：临时目录系统随时会清，
    // 「昨天存的今天没了」这种失败没人能解释。
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/tts');
  }

  Future<Directory> _dir(String digest) async =>
      Directory('${(await _root()).path}/$digest');

  /// 网关给的是 wav，直连给的是 mp3 —— 扩展名记在 meta 里，别写死。
  static String _name(int index, String ext) =>
      '${index.toString().padLeft(3, '0')}.$ext';

  /// 本地是否完整。完整则返回按顺序排好的文件，否则返回 null。
  ///
  /// 「完整」= `meta.json` 里的段数与实际文件数一致、且每个文件都非空。
  Future<List<File>?> lookup(String digest) async {
    try {
      final dir = await _dir(digest);
      final meta = File('${dir.path}/meta.json');
      if (!await meta.exists()) return null;

      final raw = jsonDecode(await meta.readAsString());
      if (raw is! Map) return null;
      final count = (raw['count'] as num?)?.toInt() ?? 0;
      if (count <= 0) return null;
      final ext = '${raw['ext'] ?? 'wav'}';

      final files = <File>[];
      for (var i = 0; i < count; i++) {
        final file = File('${dir.path}/${_name(i, ext)}');
        if (!await file.exists()) return null;
        // 0 字节或几百字节的残片一律当缺失：截断的 wav 播出来是杂音，
        // 比「没有」更难排查。
        if (await file.length() < 1024) return null;
        files.add(file);
      }

      unawaited(_touch(meta, raw));
      return files;
    } catch (cause) {
      debugPrint('伴读本地缓存读不出来（当没有处理）：$cause');
      return null;
    }
  }

  /// 命中时刷新 `at`，让淘汰认得「最近用过」。写失败不影响这次播放。
  Future<void> _touch(File meta, Map<Object?, Object?> raw) async {
    try {
      await meta.writeAsString(
        jsonEncode({...raw, 'at': DateTime.now().toIso8601String()}),
        flush: false,
      );
    } catch (_) {}
  }

  /// 把整篇的音频下载到本地。**失败不抛** —— 它只是让下次不能离线，
  /// 不该反过来影响这次正在播的内容。
  ///
  /// ⚠️ 11-08 起生产链路**不再调用它**（`ServerTts._storeForOffline` 已移除）。
  /// 原因见 `tts_voice.dart`：网关兜底是 Qwen 女声，把它的 wav 写进本地槽
  /// 会让「男声 = 本机」破功。现在这个目录只由 `TtsChunkFeed` 写直连的
  /// 男声 mp3。保留本方法是给离线导入 / 将来换音源用，测试也仍在盯它。
  Future<void> save(String digest, List<String> urls) async {
    if (urls.isEmpty) return;
    final dir = await _dir(digest);
    try {
      await dir.create(recursive: true);

      var total = 0;
      for (var i = 0; i < urls.length; i++) {
        final target = File('${dir.path}/${_name(i, 'wav')}');
        if (await target.exists() && await target.length() >= 1024) {
          total += await target.length();
          continue;
        }

        final bytes = await _download(urls[i]);
        if (bytes.length < 1024) {
          throw StateError('第 ${i + 1} 段只有 ${bytes.length} 字节');
        }
        // 先写 .part 再改名：中途被杀不会留下一个「看起来完整」的短文件。
        final part = File('${target.path}.part');
        await part.writeAsBytes(bytes, flush: true);
        await part.rename(target.path);
        total += bytes.length;
      }

      await File('${dir.path}/meta.json').writeAsString(
        jsonEncode({
          'count': urls.length,
          'bytes': total,
          'ext': 'wav',
          'at': DateTime.now().toIso8601String(),
        }),
        flush: true,
      );
      await trim();
    } catch (cause) {
      debugPrint('伴读音频落盘失败（下次仍需联网）：$cause');
      // 半套文件不能留：`lookup` 虽然会判缺失，但它会白占空间。
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// 分块合成用的三个动作：查已有块、写一块、全部齐了才提交。
  ///
  /// 为什么不复用 [save]：那条路是「拿到一串 URL 一次性下完」，而分块是
  /// **边合成边播**——第一块必须立刻落盘，其余块在播放过程中陆续到来。
  /// 用 [save] 的话，`meta.json` 一开始就会按全部段数写下去，中途断掉
  /// 就变成「meta 说 5 段、实际 2 段」，`lookup` 虽然会判缺失，但下次
  /// 重来的成本是整篇重合成。

  /// 已经落盘的块（**不要求齐全**）。上次听到一半停下的情况靠它续传。
  Future<Map<int, File>> existingChunks(String digest, {String ext = 'mp3'}) async {
    final out = <int, File>{};
    try {
      final dir = await _dir(digest);
      if (!await dir.exists()) return out;
      await for (final node in dir.list(followLinks: false)) {
        if (node is! File) continue;
        final match = _chunkPattern.firstMatch(_baseName(node.path));
        if (match == null) continue;
        if (match.group(2) != ext) continue;
        // 残片不算：几百字节的 mp3 播出来是杂音，比「没有」更难排查。
        if (await node.length() < 1024) continue;
        out[int.parse(match.group(1)!)] = node;
      }
    } catch (cause) {
      debugPrint('伴读已存块读不出来（当没有处理）：$cause');
    }
    return out;
  }

  /// 写一块。返回写好的文件；写不进去返回 null。
  ///
  /// **不清目录**：旁边的块是这次朗读还要用的。
  Future<File?> putChunk(
    String digest,
    int index,
    Uint8List bytes, {
    String ext = 'mp3',
  }) async {
    if (bytes.length < 1024) return null;
    try {
      final dir = await _dir(digest);
      await dir.create(recursive: true);
      final file = File('${dir.path}/${_name(index, ext)}');
      // 先写 .part 再改名：中途被杀不会留下「看起来完整」的短文件。
      final part = File('${file.path}.part');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(file.path);
      return file;
    } catch (cause) {
      debugPrint('伴读第 ${index + 1} 块写不进本地：$cause');
      return null;
    }
  }

  /// 全部 [count] 块都在了才写 `meta.json`，[lookup] 之后才会认这一篇完整。
  ///
  /// 顺手清掉另一种格式的残块：上次走网关留下的是 `.wav`，这次直连写的是
  /// `.mp3`，混在一起会让 `meta` 的 `ext` 与目录里的文件对不上。
  Future<void> commit(String digest, int count, {String ext = 'mp3'}) async {
    if (count <= 0) return;
    try {
      final dir = await _dir(digest);
      if (!await dir.exists()) return;

      await for (final node in dir.list(followLinks: false)) {
        if (node is! File) continue;
        final match = _chunkPattern.firstMatch(_baseName(node.path));
        if (match == null) continue;
        if (match.group(2) == ext) continue;
        try {
          await node.delete();
        } catch (_) {}
      }

      var total = 0;
      for (var i = 0; i < count; i++) {
        final file = File('${dir.path}/${_name(i, ext)}');
        if (!await file.exists()) return;
        total += await file.length();
      }

      await File('${dir.path}/meta.json').writeAsString(
        jsonEncode({
          'count': count,
          'bytes': total,
          'ext': ext,
          'at': DateTime.now().toIso8601String(),
        }),
        flush: true,
      );
      await trim();
    } catch (cause) {
      debugPrint('伴读音频提交失败（下次仍当没存过）：$cause');
    }
  }

  /// `000.mp3` / `012.wav` → `(序号, 扩展名)`。
  static final RegExp _chunkPattern = RegExp(r'^(\d{3,})\.([a-z0-9]+)$');

  static String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

  Future<List<int>> _download(String url) async {
    final hook = fetch;
    if (hook != null) return hook(url);

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        throw StateError('下载音频返回 HTTP ${response.statusCode}');
      }
      final chunks = await response.stream.toBytes();
      return chunks;
    } finally {
      client.close();
    }
  }

  /// 超过 [maxBytes] 就按「最久未用」删到 [keepBytes]。
  Future<void> trim() async {
    try {
      final root = await _root();
      if (!await root.exists()) return;

      final entries = <_CacheEntry>[];
      var total = 0;
      await for (final node in root.list(followLinks: false)) {
        if (node is! Directory) continue;
        var bytes = 0;
        var at = 0;
        await for (final file in node.list(followLinks: false)) {
          if (file is! File) continue;
          bytes += await file.length();
          if (!file.path.endsWith('meta.json')) continue;
          try {
            final meta = jsonDecode(await file.readAsString());
            at = DateTime.tryParse('${meta['at']}')?.millisecondsSinceEpoch ?? 0;
          } catch (_) {}
        }
        if (at == 0) {
          at = (await node.stat()).modified.millisecondsSinceEpoch;
        }
        entries.add(_CacheEntry(node, bytes, at));
        total += bytes;
      }

      if (total <= limitBytes) return;
      entries.sort((a, b) => a.at.compareTo(b.at));
      var live = total;
      for (final entry in entries) {
        if (live <= keepBytes) break;
        await entry.dir.delete(recursive: true);
        live -= entry.bytes;
      }
    } catch (cause) {
      debugPrint('伴读缓存清理失败（忽略）：$cause');
    }
  }

  /// 给诊断/设置页用：缓存了多少篇、占多少字节。
  Future<({int count, int bytes})> info() async {
    try {
      final root = await _root();
      if (!await root.exists()) return (count: 0, bytes: 0);
      var count = 0;
      var bytes = 0;
      await for (final node in root.list(followLinks: false)) {
        if (node is! Directory) continue;
        count++;
        await for (final file in node.list(followLinks: false)) {
          if (file is File) bytes += await file.length();
        }
      }
      return (count: count, bytes: bytes);
    } catch (_) {
      return (count: 0, bytes: 0);
    }
  }

}

class _CacheEntry {
  const _CacheEntry(this.dir, this.bytes, this.at);

  final Directory dir;
  final int bytes;
  final int at;
}
