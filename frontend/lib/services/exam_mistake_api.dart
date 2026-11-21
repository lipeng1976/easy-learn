import 'data_api_client.dart';

/// 试卷错题：ima `教学资料/试卷错题/` 下的 MD → `review_mistake`。
///
/// 与教材 / 词表导入同一套「读降级、写响亮」口径：
/// - `listFiles` 恒 2xx：没开通 ima 回 `connected:false`，入口整块藏起来，
///   **不弹红条、不抛异常**（可选能力硬规矩）。
/// - `importFile` / `revoke` 是家长主动点了按钮，失败必须抛。
class ExamMistakeFile {
  const ExamMistakeFile({
    required this.mediaId,
    required this.fileName,
    required this.importedCount,
  });

  final String mediaId;
  final String fileName;
  final int importedCount;

  factory ExamMistakeFile.fromJson(Map<String, dynamic> json) => ExamMistakeFile(
        mediaId: (json['mediaId'] ?? '').toString(),
        fileName: (json['fileName'] ?? '').toString(),
        importedCount: (json['importedCount'] as num?)?.toInt() ?? 0,
      );
}

class ExamMistakeLibrary {
  const ExamMistakeLibrary({
    required this.connected,
    required this.folderPath,
    required this.files,
    this.reason = '',
  });

  static final ExamMistakeLibrary empty = ExamMistakeLibrary(
    connected: false,
    folderPath: '教学资料/试卷错题',
    files: const <ExamMistakeFile>[],
    reason: 'ima_unavailable',
  );

  final bool connected;
  final String folderPath;
  final List<ExamMistakeFile> files;
  final String reason;

  factory ExamMistakeLibrary.fromJson(Map<String, dynamic> json) {
    final raw = json['files'];
    return ExamMistakeLibrary(
      connected: json['connected'] == true,
      folderPath: (json['folderPath'] ?? '教学资料/试卷错题').toString(),
      files: raw is List
          ? raw
              .whereType<Map>()
              .map((one) => ExamMistakeFile.fromJson(Map<String, dynamic>.from(one)))
              .toList()
          : const <ExamMistakeFile>[],
      reason: (json['reason'] ?? '').toString(),
    );
  }
}

class ExamMistakeImportResult {
  const ExamMistakeImportResult({
    required this.imported,
    required this.removed,
    required this.examTitle,
  });

  final int imported;
  final int removed;
  final String examTitle;

  factory ExamMistakeImportResult.fromJson(Map<String, dynamic> json) =>
      ExamMistakeImportResult(
        imported: (json['imported'] as num?)?.toInt() ?? 0,
        removed: (json['removed'] as num?)?.toInt() ?? 0,
        examTitle: (json['examTitle'] ?? '').toString(),
      );
}

abstract class ExamMistakeRepository {
  Future<ExamMistakeLibrary> listFiles({required String studentId});

  /// 同一份 MD 重复导入 = 先删旧行再写，不会翻倍。
  Future<ExamMistakeImportResult> importFile({
    required String studentId,
    required String mediaId,
  });

  /// 撤销这份 MD 导入的错题。返回删掉的行数；没导入过返回 0。
  Future<int> revoke({required String studentId, required String mediaId});
}

class HttpExamMistakeRepository implements ExamMistakeRepository {
  const HttpExamMistakeRepository(this._api);

  final DataApiClient _api;

  @override
  Future<ExamMistakeLibrary> listFiles({required String studentId}) async {
    final data = await _api.getJson(
      '/data/exam/mistakes/files',
      query: <String, Object?>{'studentId': studentId},
    );
    return ExamMistakeLibrary.fromJson(data);
  }

  @override
  Future<ExamMistakeImportResult> importFile({
    required String studentId,
    required String mediaId,
  }) async {
    final data = await _api.postJson(
      '/data/exam/mistakes/import',
      body: <String, Object?>{'studentId': studentId, 'mediaId': mediaId},
    );
    return ExamMistakeImportResult.fromJson(data);
  }

  @override
  Future<int> revoke({
    required String studentId,
    required String mediaId,
  }) async {
    final data = await _api.postJson(
      '/data/exam/mistakes/revoke',
      body: <String, Object?>{'studentId': studentId, 'mediaId': mediaId},
    );
    return (data['removed'] as num?)?.toInt() ?? 0;
  }
}

/// 没连数据服务：读返回「未开通」，写响亮失败。
class UnavailableExamMistakeRepository implements ExamMistakeRepository {
  const UnavailableExamMistakeRepository();

  @override
  Future<ExamMistakeLibrary> listFiles({required String studentId}) async =>
      ExamMistakeLibrary.empty;

  @override
  Future<ExamMistakeImportResult> importFile({
    required String studentId,
    required String mediaId,
  }) async {
    throw StateError('没有连接数据服务，试卷错题导入不了');
  }

  @override
  Future<int> revoke({required String studentId, required String mediaId}) async {
    throw StateError('没有连接数据服务，试卷错题撤销不了');
  }
}
