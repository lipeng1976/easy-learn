import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'edge_tts_token.dart';
import 'tts_voice.dart';

/// 直连合成失败。**带上 [code]**，因为上层要据此决定「要不要退回网关」。
class EdgeTtsException implements Exception {
  const EdgeTtsException(this.message, {this.code = ''});

  final String message;

  /// `forbidden`（UA/令牌被拒，大概率要等更新）/ `network` / `timeout` /
  /// `empty_audio`。
  final String code;

  @override
  String toString() => message;
}

/// 手机自己直连微软朗读接口，拿回 mp3 字节。
///
/// ## 为什么不用 `WebSocket.connect(headers:)`
///
/// **它带不上 User-Agent。** Dart 的 HttpClient 会先写自己的
/// `user-agent: Dart/x.y`，你传的同名头变成第二个值，服务端只看见 Dart，
/// 于是稳定 403 —— 而报错只说「没升级成 websocket」，看不出是 UA 的问题。
/// 实测对照：UA 带 `Edg/` → 101，不带 → 403。
///
/// 所以这里自己握 WebSocket 升级：设 `HttpClient.userAgent` → 手工发
/// `Upgrade` 头 → `detachSocket()` → `fromUpgradedSocket()`。
///
/// ## 这是非公开接口
///
/// 令牌算法随时可能变（v1 已经作废）。所以它只做「首选」，失败必须能退回
/// 网关。上层 `ServerTts` 就是这么用的。
class EdgeTtsClient {
  const EdgeTtsClient();

  static const String _host = 'speech.platform.bing.com';
  static const String _path =
      '/consumer/speech/synthesize/readaloud/edge/v1';
  static const String _trusted = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';

  /// 唯一必须的东西是里面那个 `Edg/`，其余随便。少了它就是 403。
  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0';

  /// 一篇课文（最长 4822 字符）实测 15.9 秒，这里留足余量。
  static Duration timeoutFor(int chars) =>
      Duration(seconds: 30 + chars ~/ 300);

  Future<Uint8List> synthesize({
    required String text,
    String language = 'en',
    String? voice,
    Duration? timeout,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const EdgeTtsException('没有可朗读的文字', code: 'empty_text');
    }

    final uri = Uri.https(_host, _path, {
      'TrustedClientToken': _trusted,
      'ConnectionId': _uuid(),
      'Sec-MS-GEC': secMsGec(),
      'Sec-MS-GEC-Version': gecVersion,
    });

    final WebSocket socket;
    try {
      socket = await _open(uri).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const EdgeTtsException('连接朗读接口超时', code: 'timeout');
    } on EdgeTtsException {
      rethrow;
    } on SocketException catch (e) {
      throw EdgeTtsException('连不上朗读接口：${e.message}', code: 'network');
    } on TlsException catch (e) {
      throw EdgeTtsException('朗读接口的证书校验失败：${e.message}', code: 'tls');
    }

    final chunks = <Uint8List>[];
    final done = Completer<void>();
    late final StreamSubscription<dynamic> sub;

    void finish() {
      if (!done.isCompleted) done.complete();
    }

    sub = socket.listen(
      (dynamic data) {
        if (data is String) {
          if (data.contains('Path:turn.end')) finish();
          return;
        }
        if (data is! List<int>) return;
        final bytes = data is Uint8List ? data : Uint8List.fromList(data);
        if (bytes.length < 2) return;
        final headLength = ByteData.sublistView(bytes).getUint16(0, Endian.big);
        if (bytes.length < 2 + headLength) return;
        final head = utf8.decode(
          bytes.sublist(2, 2 + headLength),
          allowMalformed: true,
        );
        if (!head.contains('Path:audio')) return;
        chunks.add(bytes.sublist(2 + headLength));
      },
      onError: (Object cause) {
        if (!done.isCompleted) done.completeError(cause);
      },
      onDone: finish,
      cancelOnError: true,
    );

    try {
      socket.add(_configFrame());
      socket.add(_ssmlFrame(trimmed, voice: voice, language: language));

      await done.future.timeout(timeout ?? timeoutFor(trimmed.length));
    } on TimeoutException {
      throw const EdgeTtsException('朗读合成超时', code: 'timeout');
    } finally {
      await sub.cancel();
      try {
        await socket.close();
      } catch (_) {
        // 关不掉不影响这次结果
      }
    }

    if (chunks.isEmpty) {
      throw const EdgeTtsException('朗读接口没有返回音频', code: 'empty_audio');
    }
    return _concat(chunks);
  }

  /// 自己握 WebSocket 升级。见类注释：这一步就是为了让 UA 真的发出去。
  Future<WebSocket> _open(Uri uri) async {
    final client = HttpClient();
    client.userAgent = _userAgent;
    try {
      // HttpClient 只认 http/https，wss 换成 https 走同一套 TLS。
      final request = await client.openUrl('GET', uri.replace(scheme: 'https'));
      request.headers.set('Connection', 'Upgrade');
      request.headers.set('Upgrade', 'websocket');
      request.headers.set('Sec-WebSocket-Version', '13');
      request.headers.set('Sec-WebSocket-Key', base64.encode(_randomBytes(16)));
      request.headers.set('Origin', 'https://localhost');

      final response = await request.close();
      if (response.statusCode != HttpStatus.switchingProtocols) {
        // 必须把响应体读干净，否则连接不会被复用/释放。
        try {
          await response.drain<void>();
        } catch (_) {}
        throw EdgeTtsException(
          '朗读接口拒绝连接 HTTP ${response.statusCode}',
          code: response.statusCode == HttpStatus.forbidden
              ? 'forbidden'
              : 'handshake',
        );
      }

      final upgraded = await response.detachSocket();
      return WebSocket.fromUpgradedSocket(
        upgraded,
        serverSide: false,
        compression: CompressionOptions.compressionOff,
      );
    } finally {
      client.close(force: false);
    }
  }

  static String _configFrame() =>
      'X-Timestamp:${_date()}\r\n'
      'Content-Type:application/json; charset=utf-8\r\n'
      'Path:speech.config\r\n\r\n'
      '{"context":{"synthesis":{"audio":{"metadataoptions":'
      '{"sentenceBoundaryEnabled":"true","wordBoundaryEnabled":"false"},'
      '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n';

  static String _ssmlFrame(
    String text, {
    String? voice,
    required String language,
  }) {
    final ssml = buildSsml(
      text,
      voice: voice ?? voiceFor(language),
      language: langFor(language),
    );
    return 'X-RequestId:${_uuid()}\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:${_date()}Z\r\n'
        'Path:ssml\r\n\r\n'
        '$ssml';
  }

  /// 默认音色：**男声**。
  ///
  /// 11-08 起的约定见 `tts_voice.dart`：本机 / 直连这条必须是男声，
  /// 这样和网关兜底的 Qwen 女声一听就能分开。原先的 Aria / 晓晓都是女声，
  /// 换过来会撞上「旧缓存还是女声」的问题 —— 所以 `TtsVoices.cacheSchema`
  /// 同时 bump 了，别只改这里。
  static String voiceFor(String language) => TtsVoices.localVoiceFor(language);

  static String langFor(String language) =>
      language == 'zh' ? 'zh-CN' : 'en-US';

  /// 单独抽出来是为了能测：少转义一个 `&`，整篇就合成失败，
  /// 而错误只说「接口没返回音频」。
  @visibleForTesting
  static String buildSsml(
    String text, {
    required String voice,
    required String language,
  }) =>
      "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
      "xml:lang='$language'><voice name='$voice'>"
      "<prosody pitch='+0Hz' rate='+0%' volume='+0%'>"
      '${escapeXml(text)}</prosody></voice></speak>';

  @visibleForTesting
  static String escapeXml(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static Uint8List _concat(List<Uint8List> chunks) {
    final total = chunks.fold<int>(0, (n, c) => n + c.length);
    final out = Uint8List(total);
    var offset = 0;
    for (final chunk in chunks) {
      out.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return out;
  }

  static List<int> _randomBytes(int count) {
    final random = Random.secure();
    return List<int>.generate(count, (_) => random.nextInt(256));
  }

  static String _uuid() => _randomBytes(16)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  /// `Sat Nov 07 2026 11:22:05 GMT+0000 (Coordinated Universal Time)`
  static String _date() {
    const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final d = DateTime.now().toUtc();
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${days[d.weekday % 7]} ${months[d.month - 1]} ${p2(d.day)} '
        '${d.year} ${p2(d.hour)}:${p2(d.minute)}:${p2(d.second)} '
        'GMT+0000 (Coordinated Universal Time)';
  }
}
