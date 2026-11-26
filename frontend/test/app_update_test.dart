import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:easy_learn_app/services/app_update_service.dart';

/// 更新链路的判据：**只断结果不算通过**，这里用假 HTTP 客户端真跑
/// 「清单 → 下载 → 写盘 → sha256 → 失败删除」整条链。

class _FakeClient extends http.BaseClient {
  _FakeClient(this._onRequest);

  final Future<http.StreamedResponse> Function(http.BaseRequest) _onRequest;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _onRequest(request);
}

http.StreamedResponse _stream(int status, List<int> bytes) => http.StreamedResponse(
      Stream<List<int>>.fromIterable([bytes]),
      status,
      request: http.Request('GET', Uri.parse('http://test/app/download')),
    );

Map<String, dynamic> _manifest({
  required String sha,
  required int size,
  String fileName = 'update.apk',
  int versionCode = 999,
}) =>
    {
      'ok': true,
      'data': {
        'available': true,
        'latest': {
          'versionCode': versionCode,
          'versionName': '1.0.9',
          'changelog': '测试更新',
          'fileName': fileName,
          'size': size,
          'sha256': sha,
          'publishedAt': '2026-11-26T09:00:00+08:00',
        },
      },
    };

void main() {
  late Directory dir;
  late Uint8List apk;
  late String sha;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('easylearn-update-test-');
    apk = Uint8List.fromList(List<int>.generate(2048, (i) => i % 251));
    sha = 'placeholder'; // 每个用例自己算。
  });

  tearDown(() async => dir.delete(recursive: true));

  test('清单有效 + 版本更高 → hasNewerThan 为真', () async {
    final bytes = utf8.encode(jsonEncode(_manifest(sha: 'a' * 64, size: 10)));
    final client = _FakeClient((req) async => _stream(200, bytes));
    final service = AppUpdateService(httpClient: client, currentVersionCode: 100, updatesDir: () async => dir.path);
    final result = await service.check(const ['http://primary']);
    expect(result.available, isTrue);
    expect(result.hasNewerThan(100), isTrue);
    expect(result.latest!.fileName, 'update.apk');
  });

  test('版本更低或相等 → 不提示（避免升完还反复弹）', () async {
    final bytes = utf8.encode(jsonEncode(_manifest(sha: 'a' * 64, size: 10, versionCode: 100)));
    final client = _FakeClient((req) async => _stream(200, bytes));
    final service = AppUpdateService(httpClient: client, updatesDir: () async => dir.path);
    final result = await service.check(const ['http://primary']);
    expect(result.hasNewerThan(100), isFalse);
    expect(result.hasNewerThan(99), isTrue);
  });

  test('available:false（服务端没配更新包）→ 静默，不试备用地址', () async {
    var calls = 0;
    final client = _FakeClient((req) async {
      calls++;
      return _stream(200, utf8.encode(jsonEncode({'ok': true, 'data': {'available': false}})));
    });
    final service = AppUpdateService(httpClient: client, updatesDir: () async => dir.path);
    final result = await service.check(const ['http://a', 'http://b']);
    expect(result.available, isFalse);
    expect(calls, 1);
  });

  test('首选地址失败 → 自动换备用地址', () async {
    final bytes = utf8.encode(jsonEncode(_manifest(sha: 'a' * 64, size: 10)));
    final client = _FakeClient((req) async {
      if (req.url.host == 'a') return _stream(502, utf8.encode('{}'));
      return _stream(200, bytes);
    });
    final service = AppUpdateService(httpClient: client, updatesDir: () async => dir.path);
    final result = await service.check(const ['http://a', 'http://b']);
    expect(result.available, isTrue);
  });

  test('下载 → 写盘 → sha256 一致 → 返回路径', () async {
    sha = _shaHex(apk);
    final client = _FakeClient((req) async {
      if (req.url.path.endsWith('/app/download')) return _stream(200, apk);
      return _stream(200, utf8.encode(jsonEncode(_manifest(sha: sha, size: apk.length))));
    });
    final service = AppUpdateService(httpClient: client, updatesDir: () async => dir.path);
    final info = UpdateInfo.fromJson(
      (_manifest(sha: sha, size: apk.length)['data'] as Map)['latest'] as Map<String, dynamic>,
    );
    final downloaded = await service.download(const ['http://primary'], info);
    expect(downloaded.sha256, sha);
    expect(File(downloaded.path).existsSync(), isTrue);
    expect(File(downloaded.path).lengthSync(), apk.length);
  });

  test('sha256 不匹配 → 删掉坏包并抛错（防止下次被大小骗过去）', () async {
    final info = UpdateInfo.fromJson(
      (_manifest(sha: '0' * 64, size: apk.length)['data'] as Map)['latest'] as Map<String, dynamic>,
    );
    final client = _FakeClient((req) async => _stream(200, apk));
    final service = AppUpdateService(httpClient: client, updatesDir: () async => dir.path);
    await expectLater(
      service.download(const ['http://primary'], info),
      throwsA(isA<UpdateDownloadException>()),
    );
    expect(File('${dir.path}${Platform.pathSeparator}update.apk').existsSync(), isFalse);
  });

  test('文件名带 ../ → 客户端再挡一次，不发下载请求', () async {
    var sends = 0;
    final client = _FakeClient((req) async {
      sends++;
      return _stream(200, apk);
    });
    final info = UpdateInfo.fromJson(
      (_manifest(sha: _shaHex(apk), size: apk.length, fileName: '../evil.apk')['data'] as Map)['latest']
          as Map<String, dynamic>,
    );
    final service = AppUpdateService(httpClient: client, updatesDir: () async => dir.path);
    await expectLater(
      service.download(const ['http://primary'], info),
      throwsA(isA<UpdateDownloadException>()),
    );
    expect(sends, 0);
  });
}

String _shaHex(List<int> bytes) => sha256.convert(bytes).toString();
