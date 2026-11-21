import 'dart:convert';
import 'dart:typed_data';

import 'package:easy_learn_app/services/ai_api_client.dart';
import 'package:easy_learn_app/services/ai_config.dart';
import 'package:easy_learn_app/services/ai_data_source.dart';
import 'package:easy_learn_app/services/ai_image_transport.dart';
import 'package:easy_learn_app/services/http_ocr_data_source.dart';
import 'package:easy_learn_app/services/ocr_data_source.dart';
import 'package:easy_learn_app/services/ocr_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 这组测试守的是 2026-09-15 那次线上现象：
///
/// 学生拍照上传，界面说「没能认出作业内容」，并建议「光线太暗、拍歪了」。
/// 实际上**模型一次都没被调用** —— AI 运行时是在没有登录态时装配出来的，
/// 客户端把占位符 `anonymous` 当学号发给了网关，网关按「无身份」拒收
/// （配额与审计没法归到任何学生），客户端再降级成本地模拟，
/// 于是「被拒绝」被显示成了「照片认不出」。
///
/// 三条独立防线，各自被下面的用例钉住：
/// ① 传输层看到无效身份**不发请求**（省掉一次必然失败的往返）；
/// ② 失败原因一路传到界面，不再一律说「认不出」；
/// ③ 图片类型按真实字节判断，不写死 jpeg。

AiConfig _config() => const AiConfig(
  baseUrl: 'https://gw.test',
  requestTimeout: Duration(seconds: 5),
);

Uint8List _pngBytes() => Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG 魔数
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
]);

Uint8List _jpegBytes() =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46]);

Uint8List _webpBytes() => Uint8List.fromList([
  0x52, 0x49, 0x46, 0x46, // RIFF
  0x24, 0x00, 0x00, 0x00, // 长度
  0x57, 0x45, 0x42, 0x50, // WEBP
]);

Uint8List _heicBytes() => Uint8List.fromList([
  0x00, 0x00, 0x00, 0x18, // 长度
  0x66, 0x74, 0x79, 0x70, // ftyp
  0x68, 0x65, 0x69, 0x63, // heic
]);

void main() {
  group('身份可用性', () {
    test('空学号与占位符都不可用 —— 网关无从记账', () {
      expect(const AiIdentity(studentId: '').usable, isFalse);
      expect(const AiIdentity(studentId: kAnonymousStudentId).usable, isFalse);
      // 前后空白也算空：`' '` 拼进缓存键就是一个谁也不是的账号。
      expect(const AiIdentity(studentId: '  ').usable, isFalse);
    });

    test('真实学号可用', () {
      expect(const AiIdentity(studentId: 'stu_demo_001').usable, isTrue);
    });
  });

  group('传输层：身份无效就不发请求', () {
    test('占位符学号 → 一个请求都不发，报 no_identity', () async {
      var calls = 0;
      final client = AiApiClient(
        config: _config(),
        identity: const AiIdentity(studentId: kAnonymousStudentId),
        client: MockClient((request) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );

      await expectLater(
        client.postJson('/ai/homework/ocr', const {'fileName': 'a.png'}),
        throwsA(
          isA<AiRequestException>()
              .having((e) => e.code, 'code', 'no_identity')
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
      // 关键断言：不是「失败了」，而是**根本没发出去**。
      // 发了也只能换回一个读不懂的 bad_request，还白等一次往返。
      expect(calls, 0);
    });

    test('探活不受身份影响 —— 否则未登录时连能力位都探不到', () async {
      var calls = 0;
      final client = AiApiClient(
        config: _config(),
        identity: const AiIdentity(studentId: ''),
        client: MockClient((request) async {
          calls++;
          return http.Response(
            jsonEncode({
              'ok': true,
              'data': {
                'capabilities': {'vision': true},
                'modelClient': 'ark',
                'region': 'cn-beijing',
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await client.health();
      expect(calls, 1);
    });

    test('身份按请求解析：登录后同一个客户端立刻用上新学号', () async {
      final seen = <String?>[];
      var current = '';
      final client = AiApiClient(
        config: _config(),
        identity: const AiIdentity(studentId: ''),
        identityOf: () => AiIdentity(studentId: current),
        client: MockClient((request) async {
          seen.add(request.headers['X-Student-Id']);
          return http.Response(
            jsonEncode({
              'ok': true,
              'data': {'text': 'x', 'subject': '数学', 'confidence': 0.9, 'tasks': []},
              'meta': {'requestId': 'r'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      // 未登录：请求不发。
      await expectLater(
        client.postJson('/ai/homework/ocr', const {}),
        throwsA(isA<AiRequestException>()),
      );
      expect(seen, isEmpty);

      // 登录后：同一个 client 实例直接就能用，不需要重建运行时。
      current = 'stu_demo_001';
      await client.postJson('/ai/homework/ocr', const {});
      expect(seen, ['stu_demo_001']);
    });
  });

  group('OCR 失败原因', () {
    test('未登录 → 原因标成 noIdentity，而不是「照片认不出」', () async {
      final degradations = <AiDegradation>[];
      final source = HttpOcrDataSource(
        client: AiApiClient(
          config: _config(),
          identity: const AiIdentity(studentId: kAnonymousStudentId),
        ),
        onDegraded: degradations.add,
      );

      final result = await source.recognizeHomework(
        fileName: 'homework.png',
        bytes: _pngBytes(),
      );

      expect(result.success, isFalse);
      expect(result.failure, OcrFailureKind.noIdentity);
      expect(degradations.single.code, 'no_identity');
      // 兜底实现自己的原因是「我没接模型」，这里必须被真实成因覆盖 ——
      // 否则界面会把人引向「那接上模型不就好了」的错误结论。
      expect(result.failureNote, isNot(contains('离线模式')));
    });

    test('视觉模型未开通 → 归为 offline（不是服务端拒绝）', () async {
      final source = HttpOcrDataSource(
        client: AiApiClient(
          config: _config().copyWith(
            capabilities: const AiCapabilities(
              vision: false,
              reasoning: true,
              light: true,
            ),
          ),
          identity: const AiIdentity(studentId: 'stu_1'),
        ),
      );

      final result = await source.recognizeHomework(
        fileName: 'homework.png',
        bytes: _pngBytes(),
      );

      expect(result.failure, OcrFailureKind.offline);
    });

    test('多张照片各有成因时，取最该被处理的那个', () async {
      final service = OcrService(
        dataSource: const _FailuresByFileName(),
        storage: null,
        database: null,
      );

      final result = await service.recognizeHomework(
        studentId: 'stu_1',
        inputs: [
          HomeworkOcrInput(
            fileName: 'not-recognized.png',
            bytes: Uint8List(0),
          ),
          HomeworkOcrInput(fileName: 'rejected.png', bytes: Uint8List(0)),
        ],
      );

      // 两张都失败时，「服务端拒了」比「模型没认出来」更该被说出来：
      // 前者要我们排障，后者才轮到学生重拍。
      expect(result.failure, OcrFailureKind.rejected);
      expect(result.recognizedImageCount, 0);
    });
  });

  group('图片类型按真实字节判断', () {
    test('PNG 字节无论叫什么名字都报 png', () {
      expect(imageMimeTypeOf(_pngBytes()), 'image/png');
      // 伪装成 jpg 也一样 —— 文件名是用户侧的东西，不可信。
      expect(imageMimeTypeOf(_pngBytes(), fileName: 'a.jpg'), 'image/png');
      expect(imageMimeTypeOf(_pngBytes(), fileName: 'a.jpeg'), 'image/png');
    });

    test('JPEG / WebP / HEIC 都能认出来', () {
      expect(imageMimeTypeOf(_jpegBytes()), 'image/jpeg');
      expect(imageMimeTypeOf(_webpBytes()), 'image/webp');
      expect(imageMimeTypeOf(_heicBytes()), 'image/heic');
    });

    test('认不出魔数时回落到扩展名，都没有才当 jpeg', () {
      final unknown = Uint8List.fromList([0x00, 0x01, 0x02, 0x03]);
      expect(imageMimeTypeOf(unknown, fileName: 'shot.png'), 'image/png');
      expect(imageMimeTypeOf(unknown, fileName: 'shot.webp'), 'image/webp');
      // 默认 png/jpeg 里选 jpeg：相机与 ImagePicker 的默认输出就是 jpeg。
      expect(imageMimeTypeOf(unknown, fileName: 'shot'), 'image/jpeg');
    });

    test('上行请求里的 mimeType 用真实字节算出来的那个', () async {
      String? sentMime;
      final source = HttpOcrDataSource(
        client: AiApiClient(
          config: _config(),
          identity: const AiIdentity(studentId: 'stu_1'),
          client: MockClient((request) async {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final images = body['images'] as List;
            sentMime = (images.first as Map)['mimeType'] as String?;
            return http.Response(
              jsonEncode({
                'ok': true,
                'data': {
                  'text': '数学：第8页',
                  'subject': '数学',
                  'confidence': 0.92,
                  'tasks': [
                    {'subject': '数学', 'text': '第8页'},
                  ],
                },
                'meta': {'requestId': 'r'},
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      );

      // 文件名说 jpeg，字节是 png —— 应当以字节为准。
      final result = await source.recognizeHomework(
        fileName: '作业.jpg',
        bytes: _pngBytes(),
      );

      expect(result.success, isTrue);
      expect(sentMime, 'image/png');
    });
  });

  /// 手写体识别最典型的失败**不是**「认不出」，而是「认成了一个读起来通顺的错词」。
  ///
  /// 实测（本机 gemma4:26b，同一份作业清单从楷体换到潦草体）：5 档里 4 档 6/6 全对，
  /// 最潦草的那档把「静夜思」认成「静在恩」——**转录读起来毫无异常**，
  /// 而且自报置信度仍是 **0.9**（客户端门槛是 0.8）。
  /// 也就是说置信度这条线识别不出这类错误，学生扫一眼也发现不了，
  /// 最后照着一项假作业去做。
  ///
  /// 唯一能提示他的，是模型自己说「这几个字我没把握」。所以这个标记
  /// 从网关到界面这一路**不能掉**：它掉了不会报错，只会安静地没人提示。
  group('可疑条目的标记（手写识别）', () {
    HttpOcrDataSource sourceReturning(Map<String, dynamic> data) =>
        HttpOcrDataSource(
          client: AiApiClient(
            config: _config(),
            identity: const AiIdentity(studentId: 'stu_1'),
            client: MockClient(
              (request) async => http.Response(
                jsonEncode({
                  'ok': true,
                  'data': data,
                  'meta': {'requestId': 'r'},
                }),
                200,
                headers: {'content-type': 'application/json'},
              ),
            ),
          ),
        );

    test('模型标了 uncertain 的条目，标记要原样带到调用方', () async {
      final result = await sourceReturning({
        'text': '语文：1. 抄写第3课生字 2. 背诵《静在恩》',
        'subject': '语文',
        'confidence': 0.9,
        'tasks': [
          {'subject': '语文', 'text': '抄写第3课生字'},
          {'subject': '语文', 'text': '背诵《静在恩》', 'uncertain': true},
        ],
      }).recognizeHomework(fileName: 'h.png', bytes: _pngBytes());

      expect(result.success, isTrue);
      expect(result.tasks.length, 2);
      expect(taskIsUncertain(result.tasks[0]), isFalse);
      expect(taskIsUncertain(result.tasks[1]), isTrue);
      // 置信度照旧在门槛之上 —— 这正是问题所在：那条错误读起来毫无异常，
      // 门槛拦不住它。把这条钉下来，免得将来有人以为「够高就没事了」。
      expect(result.confidence, greaterThanOrEqualTo(kOcrConfidenceFloor));
    });

    test('模型没给这个字段时，不能被当成可疑', () async {
      final result = await sourceReturning({
        'text': '数学：口算20题',
        'subject': '数学',
        'confidence': 0.95,
        'tasks': [
          {'subject': '数学', 'text': '口算20题'},
        ],
      }).recognizeHomework(fileName: 'h.png', bytes: _pngBytes());

      expect(result.tasks.single.containsKey('uncertain'), isFalse);
      expect(taskIsUncertain(result.tasks.single), isFalse);
    });

    test('字段类型不对（字符串）不当作已标记', () async {
      // 网关侧的 schema 校验会拦下非布尔值并触发一次带提示的重试，
      // 但客户端仍要自己站稳：`'是' == true` 在 Dart 里是假的，
      // 万一那一次重试也失败、结果被降级或走了别的路径，
      // 我们不能把「字符串形式的 true」当成「没把握」以外的任何东西。
      final result = await sourceReturning({
        'text': '语文：背诵《静在恩》',
        'subject': '语文',
        'confidence': 0.9,
        'tasks': [
          {'subject': '语文', 'text': '背诵《静在恩》', 'uncertain': '是'},
        ],
      }).recognizeHomework(fileName: 'h.png', bytes: _pngBytes());

      expect(
        taskIsUncertain(result.tasks.single),
        isFalse,
        reason: '只认真正的布尔 true；含糊的取值宁可不算，也不猜',
      );
    });
  });
}

/// 按文件名返回指定成因的假数据源，用来验证「多张照片取哪个成因」。
class _FailuresByFileName implements OcrDataSource {
  const _FailuresByFileName();

  @override
  Future<OcrRecognitionResult> recognizeHomework({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final kind = fileName.contains('rejected')
        ? OcrFailureKind.rejected
        : OcrFailureKind.notRecognized;
    return OcrRecognitionResult(
      success: false,
      text: '',
      subject: '待确认',
      confidence: 0,
      tasks: const [],
      failure: kind,
      failureNote: kind.name,
    );
  }
}
