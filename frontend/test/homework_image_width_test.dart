import 'dart:convert';
import 'dart:typed_data';

import 'package:easy_learn_app/models/homework_image_model.dart';
import 'package:easy_learn_app/services/cloud_runtime.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/widgets/homework_image_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// VPN / 弱网下，**大原图**最容易被 MTU 黑洞卡死。修法是让服务端按请求宽度
/// 现场缩图：客户端把 `width` 作为 `w` 传给 `GET /data/homework/images/file`。
///
/// 这个文件钉住两条，任何一条坏了「缩图」就静默失效（用户只会看到图又打不开）：
/// ① `load(image, width: N)` 必须真的把 `w=N` 放进请求 query；
/// ② 不同宽度必须是**不同的缓存键** —— 否则缩略图(w=800)先缓存后，
///    全屏(w=1280)会直接拿到那张 800 的小图，看起来"糊"却不报错。
///
/// ## 证伪方式
/// 把 `_fetch` 里 `if (width != null) query['w'] = width;` 删掉，或把 cacheKey
/// 里的 `widthTag` 去掉，对应用例立刻变红。

class _CapturingApi extends DataApiClient {
  _CapturingApi() : super(config: const DataConfig(baseUrl: 'http://127.0.0.1:1'));

  final List<Map<String, Object?>> queries = <Map<String, Object?>>[];
  final Uint8List payload = Uint8List.fromList([1, 2, 3, 4, 5]);

  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Map<String, Object?>? query,
  }) async {
    queries.add(Map<String, Object?>.from(query ?? const {}));
    return payload;
  }
}

/// 记录每次请求的 query，并让前 [failUntil] 次抛网络异常。
class _FlakyCapturingApi extends _CapturingApi {
  int failUntil = 2;

  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Map<String, Object?>? query,
  }) async {
    queries.add(Map<String, Object?>.from(query ?? const {}));
    if (queries.length <= failUntil) {
      throw const DataApiException(code: 'network', message: 'simulated drop');
    }
    return payload;
  }
}

/// 返回一张**真能解码**的 1×1 PNG。
///
/// widget 级用例里 `Image.memory` 会真的去解码字节，喂 `[1,2,3,4,5]`
/// 那种假数据会抛「Invalid image data」—— 那是测试脚手架的问题，
/// 却会把「宽度传对了」这条结论一起带红，看起来像功能坏了。
class _PngBytesApi extends _CapturingApi {
  static final Uint8List png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Map<String, Object?>? query,
  }) async {
    queries.add(Map<String, Object?>.from(query ?? const {}));
    return png;
  }
}

final _image = HomeworkImageModel(
  id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
  studentId: '36e392cd-2d4c-408f-8aef-5672a35cefd4',
  homeworkId: '3b05d1d9-2eb4-40be-bc96-daa5c69dfae9',
  storageKey: '20260920/36e392cd-2d4c-408f-8aef-5672a35cefd4/width.jpg',
  fileName: 'width.jpg',
  fileSize: 679017,
  mimeType: 'image/jpeg',
  ocrStatus: 'pending',
  ocrText: '',
  createdAt: DateTime(2026, 9, 20, 23, 54),
);

void _use(_CapturingApi api) {
  DatabaseService.useCloudRuntime(
    CloudRuntime(api: api, config: const DataConfig(baseUrl: 'http://127.0.0.1:1')),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  setUp(() => HomeworkImageReader.resetForTest());
  tearDown(() => DatabaseService.useCloudRuntime(null));

  test('缩略图 width=800 会把 w=800 放进请求', () async {
    final api = _CapturingApi();
    _use(api);

    final bytes = await HomeworkImageReader.load(_image, width: 800);

    expect(bytes, api.payload);
    expect(api.queries, hasLength(1));
    expect(api.queries.single['id'], _image.id);
    expect(api.queries.single['w'], 800, reason: '缩图宽度必须以 w 传给服务端');
  });

  test('全屏那档宽度是 1600，并会把 w=1600 放进请求', () async {
    final api = _CapturingApi();
    _use(api);

    await HomeworkImageReader.load(
      _image,
      width: HomeworkImageReader.fullScreenWidth,
    );

    expect(
      HomeworkImageReader.fullScreenWidth,
      1600,
      reason: '全屏档位是刻意调的：手机上要看得清，VPN（MTU 1280）下又过得了',
    );
    expect(api.queries.single['w'], 1600);
  });

  test('不传 width 时不带 w（保持原图，向后兼容）', () async {
    final api = _CapturingApi();
    _use(api);

    await HomeworkImageReader.load(_image);

    expect(api.queries, hasLength(1));
    expect(api.queries.single.containsKey('w'), isFalse);
  });

  test('不同宽度分开缓存：缩略图之后全屏仍会再发一次请求', () async {
    final api = _CapturingApi();
    _use(api);

    await HomeworkImageReader.load(
      _image,
      width: HomeworkImageReader.thumbnailWidth,
    );
    await HomeworkImageReader.load(
      _image,
      width: HomeworkImageReader.fullScreenWidth,
    );

    expect(api.queries, hasLength(2), reason: '不同宽度不能共用缓存，否则全屏看到的是缩略图');
    expect(api.queries[0]['w'], 800);
    expect(api.queries[1]['w'], 1600);
  });

  test('同宽度重复 load 命中缓存，不重复发请求', () async {
    final api = _CapturingApi();
    _use(api);

    await HomeworkImageReader.load(_image, width: 800);
    await HomeworkImageReader.load(_image, width: 800);

    expect(api.queries, hasLength(1), reason: '同宽度应命中缓存');
  });

  /// ⚠️ 上面那几条只证明「**传了**宽度会带 w」。它们盯不住**页面传的是哪一档** ——
  /// 谁把全屏那行改回硬编码 `width: 800`，前面照样全绿，用户却在全屏看到糊图。
  /// 所以这条要真的把查看器打开，看它发出去的请求。
  testWidgets('全屏查看器实际请求 w=1600，而不是缩略图那一档', (tester) async {
    final api = _PngBytesApi();
    _use(api);

    await tester.pumpWidget(
      GetMaterialApp(home: Scaffold(body: SizedBox.shrink())),
    );
    openHomeworkImages(images: [_image]);
    await tester.pumpAndSettle();

    expect(api.queries, hasLength(1), reason: '全屏应当自己去取一次图');
    expect(
      api.queries.single['w'],
      1600,
      reason: '全屏必须请求 1600 那档；请求成 800 会「看起来正常、其实很糊」',
    );
  });

  test('重试时宽度逐级调小：800 → 480 → 320', () async {
    final api = _FlakyCapturingApi()..failUntil = 2;
    _use(api);

    final bytes = await HomeworkImageReader.load(_image, width: 800);

    expect(bytes, api.payload, reason: '最后一档应当拿到字节');
    expect(
      api.queries.map((q) => q['w']).toList(),
      <Object?>[800, 480, 320],
      reason: '每次重试都该比上一档更小，才更可能穿过劣化链路',
    );
  });
}
