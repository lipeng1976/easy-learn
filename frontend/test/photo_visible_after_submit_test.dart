import 'dart:typed_data';

import 'package:easy_learn_app/models/homework_image_model.dart';
import 'package:easy_learn_app/services/cloud_runtime.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/services/remote_image_storage.dart';
import 'package:easy_learn_app/widgets/homework_image_viewer.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真机反馈：「**学生提交作业后，在当前界面看不到提交的图片**，
/// 切换其他菜单再回来也没用，但是**退出登录再进来就可以**。」
///
/// ## 为什么「重登就好」指向的是 id，而不是「照片没传上去」
///
/// 重登会重走 `queryHomeworkImages`，那时拿到的行**带的是服务端生成的 id**。
/// 而读图是按 **id** 查的（`GET /data/homework/images/file?id=`）——
/// 也就是说：**区别只在 id**，字节一直在。
///
/// 主因判据在 `homework_id_adoption_test.dart`（提交后内存里那份行必须换成
/// 服务端那一行）。这个文件钉的是**退路**：即便采纳那一步没成功
/// （落库那次网络失败、`_safePersist` 吞掉异常），本进程刚上传的字节
/// 也必须看得见 —— 它就在内存里，看不到纯属白丢。
///
/// 三条用例是一组**断言 + 两个控制组**：只有中间那条「行 id 用对了就能
/// 下载到」成立时，第一条才说明「命中内存」不是巧合；而最后一条复现的
/// 正是真机上那个症状。
class _FakeApi extends DataApiClient {
  _FakeApi() : super(config: const DataConfig(baseUrl: 'http://127.0.0.1:1'));

  /// 「服务端真有字节的那些行的 id」→ 字节。
  ///
  /// 与线上同形：`GET /data/homework/images/file?id=` 是**按行 id 查的**，
  /// 查不到就 404 —— 行 id 对不对，只有这里能反映出来。
  final Map<String, Uint8List> byRowId = <String, Uint8List>{};

  int downloads = 0;
  final List<String> requestedIds = <String>[];

  @override
  Future<Map<String, dynamic>> uploadBytes(
    String path, {
    required Uint8List bytes,
    required String contentType,
    Map<String, Object?>? query,
  }) async {
    return <String, dynamic>{
      'storageKey': '20260922/stu/uploaded-${byRowId.length}.jpg',
      'byteSize': bytes.length,
      'mimeType': contentType,
    };
  }

  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Map<String, Object?>? query,
  }) async {
    downloads++;
    final id = (query?['id'] as String?) ?? '';
    requestedIds.add(id);
    final bytes = byRowId[id];
    if (bytes == null) {
      throw DataApiException(
        code: 'not_found',
        message: '照片不存在，或不在你的可见范围内',
      );
    }
    return bytes;
  }
}

void main() {
  late _FakeApi api;
  late CloudRuntime runtime;

  final bytes = Uint8List.fromList(List<int>.filled(16, 9));

  setUp(() {
    HomeworkImageReader.resetForTest();
    api = _FakeApi();
    runtime = CloudRuntime(
      config: const DataConfig(baseUrl: 'http://127.0.0.1:1'),
      api: api,
    );
    DatabaseService.useCloudRuntime(runtime);
  });

  tearDown(() {
    // 全局状态必须清掉：留着会影响同文件后面的用例，
    // 而那种失败表现为「单独跑能过、一起跑就挂」。
    DatabaseService.useCloudRuntime(null);
    runtime.dispose();
    HomeworkImageReader.resetForTest();
  });

  HomeworkImageModel modelWith({
    required String id,
    required String storageKey,
  }) => HomeworkImageModel(
    id: id,
    studentId: 'stu-1',
    homeworkId: 'hw-1',
    storageKey: storageKey,
    fileName: 'math.jpg',
    fileSize: bytes.length,
    mimeType: 'image/jpeg',
    ocrStatus: 'pending',
    ocrText: '',
    createdAt: DateTime(2026, 9, 22, 10),
  );

  group('服务端键的照片：字节能不能拿到', () {
    test('刚在本进程上传过 → 命中内存那份，看得到（且不必打网络）', () async {
      final storage = RemoteImageStorageService(api);
      final uploaded = await storage.saveHomeworkImage(
        studentId: 'stu-1',
        fileName: 'math-1.jpg',
        bytes: bytes,
        homeworkId: 'hw-1',
      );
      // 服务端把行写进去、id 由它自己生成 —— 客户端手里这个还只是占位。
      api.byRowId['srv-img-1'] = bytes;

      final got = await HomeworkImageReader.load(uploaded);

      expect(got, equals(bytes), reason: '字节就在本进程里，看不到只能是读的路走错了');
      expect(
        api.downloads,
        0,
        reason: '已经在内存里，不该再打一次网络（也不该拿那个占位 id 去查）',
      );
    });

    test('控制组①：内存里没有它（别的设备传的）→ 走网络，且行 id 对了就下得到', () async {
      // 这条保证上一条不是因为「load 恒为 not null」而通过。
      api.byRowId['srv-img-2'] = bytes;
      final model = modelWith(
        id: 'srv-img-2',
        storageKey: '20260922/stu/other-device.jpg',
      );

      final got = await HomeworkImageReader.load(model);

      expect(got, equals(bytes));
      expect(api.downloads, 1);
      expect(api.requestedIds, equals(<String>['srv-img-2']));
    });

    test('控制组②：只有本地占位 id → 读回 null，界面一片空白（真机那个症状）', () async {
      // 服务端**有**这一行的字节，只是它的行 id 是 `srv-img-3`；
      // 客户端手里还是上传时那个 `img_…`。按占位 id 查 → 404 → 空白。
      // 这一条是「为什么必须采纳服务端那一行」的直接证据。
      api.byRowId['srv-img-3'] = bytes;
      final model = modelWith(
        id: 'img_1758520000000000_0',
        storageKey: '20260922/stu/only-placeholder.jpg',
      );

      expect(await HomeworkImageReader.load(model), isNull);
      expect(
        api.requestedIds,
        equals(<String>['img_1758520000000000_0']),
        reason: '拿本地占位 id 去查行 —— 服务端不认得它，这正是照片空白的成因',
      );
    });
  });
}
