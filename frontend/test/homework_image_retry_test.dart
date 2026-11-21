import 'dart:typed_data';

import 'package:easy_learn_app/models/homework_image_model.dart';
import 'package:easy_learn_app/services/cloud_runtime.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/widgets/homework_image_viewer.dart';
import 'package:flutter_test/flutter_test.dart';

/// VPN / 弱网下，作业照片的字节请求偶尔会「发了但隧道里丢了」——
/// 服务端根本没收到，客户端只看到 `null`。这种失败是**瞬时**的，
/// 重发一次往往就好。这个文件钉住「自动重试」这件事：
///
/// - 主用例：前两次网络失败、第三次成功 → `load` 最终拿到字节，且确实多发了请求；
/// - 控制组：始终失败 → `load` 返回 null，且把重试次数用满（而不是只试一次就放弃）。
///
/// ## 证伪方式
/// 把 `homework_image_viewer.dart` 里 `_imageMaxRetries` 临时改成 0，
/// 主用例会立刻失败（首次失败直接返回 null，不再重试）—— 说明「重试」确实在起作用，
/// 而不是测试本身在放水。

class _FlakyApi extends DataApiClient {
  _FlakyApi() : super(config: const DataConfig(baseUrl: 'http://127.0.0.1:1'));

  int calls = 0;
  final Uint8List payload = Uint8List.fromList([1, 2, 3, 4]);

  /// 前 [failUntil] 次抛网络异常，之后返回字节。
  int failUntil = 2;

  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Map<String, Object?>? query,
  }) async {
    calls++;
    if (calls <= failUntil) {
      throw const DataApiException(
        code: 'network',
        message: 'simulated tunnel drop',
      );
    }
    return payload;
  }
}

final _image = HomeworkImageModel(
  id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
  studentId: '36e392cd-2d4c-408f-8aef-5672a35cefd4',
  homeworkId: '3b05d1d9-2eb4-40be-bc96-daa5c69dfae9',
  storageKey:
      '20260920/36e392cd-2d4c-408f-8aef-5672a35cefd4/retry.jpg',
  fileName: 'retry.jpg',
  fileSize: 268270,
  mimeType: 'image/jpeg',
  ocrStatus: 'pending',
  ocrText: '',
  createdAt: DateTime(2026, 9, 20, 23, 54),
);

void main() {
  setUp(() => HomeworkImageReader.resetForTest());
  tearDown(() => DatabaseService.useCloudRuntime(null));

  test('瞬时网络失败自动重试后成功（不用手动点重试）', () async {
    final api = _FlakyApi()..failUntil = 2; // 第 3 次才成功
    DatabaseService.useCloudRuntime(
      CloudRuntime(api: api, config: const DataConfig(baseUrl: 'http://127.0.0.1:1')),
    );

    final bytes = await HomeworkImageReader.load(_image);
    expect(bytes, isNotNull, reason: '重试后应当拿到字节');
    expect(bytes, api.payload);
    expect(api.calls, greaterThan(1), reason: '至少重试了一次');
    // _imageMaxRetries = 2 → 失败 2 次 + 成功 1 次 = 3 次。
    expect(api.calls, 3);
  });

  test('控制组：始终失败会用满重试次数再放弃（返回 null）', () async {
    final api = _FlakyApi()..failUntil = 999; // 永远失败
    DatabaseService.useCloudRuntime(
      CloudRuntime(api: api, config: const DataConfig(baseUrl: 'http://127.0.0.1:1')),
    );

    final bytes = await HomeworkImageReader.load(_image);
    expect(bytes, isNull, reason: '始终拿不到应返回 null');
    // 首次 1 次 + 重试 2 次 = 3 次（把重试额度用满再放弃）。
    expect(api.calls, 3);
  });

  test('控制组：not_on_server 是永久结论，不重试', () async {
    final api = _AlwaysNotOnServerApi();
    DatabaseService.useCloudRuntime(
      CloudRuntime(api: api, config: const DataConfig(baseUrl: 'http://127.0.0.1:1')),
    );

    final bytes = await HomeworkImageReader.load(_image);
    expect(bytes, isNull);
    expect(api.calls, 1, reason: 'not_on_server 不应重试，只发一次');
  });
}

/// 永远回 `not_on_server` 的假客户端（旧数据：字节只在当初那台设备）。
class _AlwaysNotOnServerApi extends DataApiClient {
  _AlwaysNotOnServerApi()
      : super(config: const DataConfig(baseUrl: 'http://127.0.0.1:1'));

  int calls = 0;

  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Map<String, Object?>? query,
  }) async {
    calls++;
    throw DataApiException(
      code: 'not_found',
      message: 'not on server',
      details: const <String, Object?>{'reason': 'not_on_server'},
    );
  }
}
