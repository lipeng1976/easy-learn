import 'dart:convert';
import 'dart:typed_data';

import 'package:easy_learn_app/services/ai_api_client.dart';
import 'package:easy_learn_app/services/ai_config.dart';
import 'package:easy_learn_app/services/ai_data_source.dart';
import 'package:easy_learn_app/services/ai_image_transport.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/services/remote_ai_data_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// `_parseAnswerRecognition`（拍照作答识别的解析层）的判据。
///
/// ## 为什么要有这个文件
///
/// B14 的 13 条控制器测试全部用**假数据源**喂控制器，解析器本身零覆盖 ——
/// 2026-09-25 真模型冒烟发现：模型对转录有把握时**不返回** `uncertain`
/// （网关契约里它是可选字段，schema 只 required `text` + `confidence`），
/// 而解析器当时按必填报 → 每一次**成功**的识别都被客户端判成 schema
/// violation、整单降级成本地占位文案。云端明明答对了，学生看到的是
/// 「识别不了」。这三条用例把正确行为钉住：
/// `uncertain` 缺席是常态、字符串照搬、置信度夹取不回归。
void main() {
  Uint8List pngBytes() => Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG 魔数
      ]);

  /// 组一个「云端总是回 [data]」的数据源；图片走内存存储，
  /// 键由 [saveImage] 写入，保证 `prepare` 读得到字节。
  Future<(RemoteAiDataSource, String)> sourceReturning(
    Map<String, dynamic> data,
  ) async {
    final storage = LocalImageStorageService(useMemory: true);
    final image = await storage.saveHomeworkImage(
      studentId: 'stu_1',
      fileName: 'answer.png',
      bytes: pngBytes(),
    );
    final source = RemoteAiDataSource(
      client: AiApiClient(
        config: const AiConfig(baseUrl: 'https://gw.test'),
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
      imageUploader: InlineHomeworkImageUploader(storage: storage),
    );
    return (source, image.storageKey);
  }

  test('模型不给 uncertain 时识别必须成功（B14 真冒烟抓到的降级 bug）', () async {
    // 真模型两次独立调用的实际返回形状：只有 text + confidence。
    final (source, key) = await sourceReturning({
      'text': '9 × 3 = 26\n答：一共 26 个。',
      'confidence': 0.95,
    });

    final result = await source.recognizeAnswer(imagePaths: [key]);

    // 修复前：_requireString 抛 schema violation → 走 fallback，
    // source 是 local、text 是编造的占位文案。修复后必须是云端原文。
    expect(result.source, AiAnswerSource.cloud);
    expect(result.text, '9 × 3 = 26\n答：一共 26 个。');
    expect(result.confidence, 0.95);
    expect(result.uncertain, isEmpty);
    expect(result.isUsable, isTrue);
  });

  test('模型给了 uncertain 字符串时原样带到调用方', () async {
    final (source, key) = await sourceReturning({
      'text': '大概是一个圆',
      'confidence': 0.6,
      'uncertain': '笔迹较淡，第二个字认不准',
    });

    final result = await source.recognizeAnswer(imagePaths: [key]);

    expect(result.source, AiAnswerSource.cloud);
    expect(result.uncertain, '笔迹较淡，第二个字认不准');
    expect(result.needsReview, isTrue);
  });

  test('置信度按百分比给（95）时夹回 [0,1]', () async {
    final (source, key) = await sourceReturning({
      'text': '9 × 3 = 26',
      'confidence': 95,
    });

    final result = await source.recognizeAnswer(imagePaths: [key]);

    expect(result.confidence, 1.0);
  });
}
