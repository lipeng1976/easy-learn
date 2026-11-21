import 'dart:convert';

import '../../config/api_endpoints.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../models/attachment.dart';

/// 附件仓储：客户端只传 id / 元数据 / 字节，**从不传路径**。
/// 生成相对键、拼绝对路径、查库都在服务端。
class AttachmentRepository {
  const AttachmentRepository(this._client);

  final ApiClient _client;

  Future<List<Attachment>> list(String studentId) async {
    final response = await _client.getJson(
      ApiEndpoints.attachments,
      query: <String, String>{'studentId': studentId},
    );
    final data = response['data'];
    if (data is! List) return <Attachment>[];
    return data
        .whereType<Map<String, dynamic>>()
        .map(Attachment.fromJson)
        .toList(growable: false);
  }

  Future<Attachment> upload({
    required String studentId,
    required String fileName,
    required String mimeType,
    required List<int> bytes,
    String? homeworkId,
  }) async {
    final response = await _client.postJson(
      ApiEndpoints.attachments,
      <String, dynamic>{
        'studentId': studentId,
        'fileName': fileName,
        'mimeType': mimeType,
        'contentBase64': base64Encode(bytes),
        if (homeworkId != null) 'homeworkId': homeworkId,
      },
    );
    final data = response['data'];
    if (data is! Map<String, dynamic>) {
      throw const ApiException(
        status: 0,
        code: 'internal',
        message: '上传接口未返回附件行（写接口返回的那行必须被采纳）',
        retryable: false,
      );
    }
    // ⚠️ 采纳服务端 RETURNING 的那一行，不用本地占位 id。
    return Attachment.fromJson(data);
  }

  Future<List<int>> bytes(String id) =>
      _client.getBytes(ApiEndpoints.attachment(id));
}
