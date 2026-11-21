import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy_learn_app/services/tts_audio_cache.dart';
import 'package:flutter_test/flutter_test.dart';

/// 伴读「断网也能读」的判据。
///
/// 照 `REA-projects/podcast`（听见）verify8-p0 的思路：**把网络弄死，看还能不能
/// 从持久层取到音频**。光验「文件存在」不算 —— 播放器真正要的是「不联网也能
/// 拿到完整的一套音频」。
class _Env {
  _Env() {
    root = Directory.systemTemp.createTempSync('tts_cache_test_');
  }

  late Directory root;
  int downloads = 0;
  final Map<String, List<int>> payload = {
    'u1': List<int>.filled(4096, 1),
    'u2': List<int>.filled(4096, 2),
  };

  TtsAudioCache cache({int limit = 200 * 1024 * 1024, int keep = 150 * 1024 * 1024}) =>
      TtsAudioCache(
        rootDir: () async => root,
        fetch: (url) async {
          downloads++;
          final body = payload[url];
          if (body == null) throw StateError('HTTP 404 $url');
          return body;
        },
        limitBytes: limit,
        keepBytes: keep,
      );

  void dispose() {
    // 缓存命中会 fire-and-forget 地刷新 meta.json，Windows 上偶尔还有句柄没放，
    // 删不掉临时目录不影响判据 —— 别让它把「断言通过」读成「测试失败」。
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } on FileSystemException {
      // 忽略：临时目录由系统回收
    }
  }
}

void main() {
  late _Env env;

  setUp(() => env = _Env());
  tearDown(() => env.dispose());

  test('没缓存过的一律返 null —— 不能假命中', () async {
    expect(await env.cache().lookup('nope'), isNull);
  });

  test('存完之后能按顺序取回，内容与段序都对得上', () async {
    final cache = env.cache();
    await cache.save('d1', ['u1', 'u2']);

    final files = await cache.lookup('d1');
    expect(files, isNotNull);
    expect(files!.length, 2);
    expect(await files[0].length(), 4096);
    expect(await files[0].readAsBytes().then((b) => b.first), 1);
    expect(await files[1].readAsBytes().then((b) => b.first), 2);
  });

  test('断网：本地已有的篇目完全不碰网络', () async {
    await env.cache().save('d1', ['u1', 'u2']);
    final before = env.downloads;

    // fetch 一律失败 = 断网。lookup 必须根本不走这条。
    final offline = TtsAudioCache(
      rootDir: () async => env.root,
      fetch: (url) async => throw const SocketException('no network'),
    );
    final files = await offline.lookup('d1');

    expect(files, isNotNull);
    expect(files!.length, 2);
    expect(env.downloads, before);
  });

  test('中间一段被删 → 整篇作废，不能放半篇', () async {
    final cache = env.cache();
    await cache.save('d1', ['u1', 'u2']);
    File('${env.root.path}/d1/000.wav').deleteSync();

    expect(await cache.lookup('d1'), isNull);
  });

  test('截断的文件不算缓存命中', () async {
    final cache = env.cache();
    await cache.save('d1', ['u1', 'u2']);
    File('${env.root.path}/d1/001.wav').writeAsBytesSync(List<int>.filled(10, 0));

    expect(await cache.lookup('d1'), isNull);
  });

  test('下载失败不抛异常，也不留半套文件白占空间', () async {
    final cache = env.cache();
    await cache.save('d1', ['u1', 'missing']);

    expect(await cache.lookup('d1'), isNull);
    expect(Directory('${env.root.path}/d1').existsSync(), isFalse);
  });

  test('已经存好的段不重复下载', () async {
    final cache = env.cache();
    await cache.save('d1', ['u1', 'u2']);
    expect(env.downloads, 2);

    await cache.save('d1', ['u1', 'u2']);
    expect(env.downloads, 2);
  });

  test('命中会刷新 at —— 淘汰时才认得出「最近用过」', () async {
    final cache = env.cache();
    await cache.save('d1', ['u1']);
    final meta = File('${env.root.path}/d1/meta.json');
    final before = jsonDecode(meta.readAsStringSync())['at'] as String;

    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await cache.lookup('d1');
    // _touch 是不 await 的，给落盘一点时间
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final after = jsonDecode(meta.readAsStringSync())['at'] as String;
    expect(after, isNot(before));
    expect(DateTime.parse(after).isAfter(DateTime.parse(before)), isTrue);
  });

  test('超过上限时按最久未用淘汰到保留线', () async {
    // 每篇 2 段 × 4KB ≈ 8KB。上限 12KB、保留 9KB：
    // 存第二篇时总占用 16KB > 12KB → 删掉最旧的 a 剩 8KB，停在 9KB 以下。
    final cache = env.cache(limit: 12000, keep: 9000);
    await cache.save('a', ['u1', 'u2']);
    await cache.save('b', ['u1', 'u2']);

    expect(await cache.lookup('a'), isNull);
    expect(await cache.lookup('b'), isNotNull);

    final info = await cache.info();
    expect(info.count, 1);
    expect(info.bytes, lessThanOrEqualTo(9000));
  });

  // ── 分块合成（边播边合成）用的那三个动作 ──────────────────────────

  test('分块写入没集齐时不写 meta —— 半篇不能算「已缓存」', () async {
    final cache = env.cache();
    await cache.putChunk('c1', 0, Uint8List.fromList(List<int>.filled(4096, 1)));
    await cache.commit('c1', 2); // 只有 1 块，却说要 2 块

    expect(File('${env.root.path}/c1/meta.json').existsSync(), isFalse);
    expect(await cache.lookup('c1'), isNull);
  });

  test('集齐之后提交，lookup 按块序取回', () async {
    final cache = env.cache();
    await cache.putChunk('c2', 0, Uint8List.fromList(List<int>.filled(4096, 1)));
    await cache.putChunk('c2', 1, Uint8List.fromList(List<int>.filled(4096, 2)));
    await cache.commit('c2', 2);

    final files = await cache.lookup('c2');
    expect(files, isNotNull);
    expect(files!.length, 2);
    expect(files[0].readAsBytesSync().first, 1);
    expect(files[1].readAsBytesSync().first, 2);
  });

  test('已有块只认够长、且是同一种格式的', () async {
    final cache = env.cache();
    await cache.putChunk('c3', 0, Uint8List.fromList(List<int>.filled(4096, 1)));
    // 残片（<1KB）和另一种格式（.wav）都不该被当成「这块已经有了」。
    File('${env.root.path}/c3/001.mp3').writeAsBytesSync(List<int>.filled(10, 0));
    File('${env.root.path}/c3/002.wav').writeAsBytesSync(List<int>.filled(4096, 0));

    final ready = await cache.existingChunks('c3');
    expect(ready.keys.toList(), [0]);
  });

  test('提交时会清掉另一种格式的残块 —— 免得 meta 的 ext 与目录对不上', () async {
    final cache = env.cache();
    // 上次走网关留下的是 wav，这次直连写的是 mp3。
    Directory('${env.root.path}/c4').createSync(recursive: true);
    File('${env.root.path}/c4/000.wav').writeAsBytesSync(List<int>.filled(4096, 7));
    await cache.putChunk('c4', 0, Uint8List.fromList(List<int>.filled(4096, 1)));
    await cache.commit('c4', 1);

    expect(File('${env.root.path}/c4/000.wav').existsSync(), isFalse);
    expect(File('${env.root.path}/c4/000.mp3').existsSync(), isTrue);
    expect(await cache.lookup('c4'), isNotNull);
  });
}
