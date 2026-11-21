class HomeworkImageModel {
  final String id;
  final String studentId;
  final String? homeworkId;
  final String storageKey;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final String ocrStatus;
  final String ocrText;
  final DateTime createdAt;

  /// 本次提交的批次号。一次「提交作业」写入的图片共享同一 batchId，
  /// 便于家长端按批展示，也便于学生端区分首交与更正后重交。
  final String batchId;

  /// 同一批次内的展示顺序（0 起）。
  final int sortOrder;

  const HomeworkImageModel({
    required this.id,
    required this.studentId,
    required this.homeworkId,
    required this.storageKey,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.ocrStatus,
    required this.ocrText,
    required this.createdAt,
    this.batchId = '',
    this.sortOrder = 0,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'studentId': studentId,
      'homeworkId': homeworkId,
      'storageKey': storageKey,
      'fileName': fileName,
      'fileSize': fileSize,
      'mimeType': mimeType,
      'ocrStatus': ocrStatus,
      'ocrText': ocrText,
      'createdAt': createdAt.toIso8601String(),
      'batchId': batchId,
      'sortOrder': sortOrder,
    };
  }

  factory HomeworkImageModel.fromMap(Map<String, dynamic> map) {
    return HomeworkImageModel(
      id: map['id'] as String,
      studentId: (map['studentId'] as String?) ?? '',
      homeworkId: map['homeworkId'] as String?,
      storageKey: map['storageKey'] as String,
      fileName: (map['fileName'] as String?) ?? '',
      fileSize: (map['fileSize'] as num?)?.toInt() ?? 0,
      mimeType: (map['mimeType'] as String?) ?? 'image/jpeg',
      ocrStatus: (map['ocrStatus'] as String?) ?? 'pending',
      ocrText: (map['ocrText'] as String?) ?? '',
      createdAt:
          DateTime.tryParse((map['createdAt'] as String?) ?? '') ??
          DateTime.now(),
      batchId: (map['batchId'] as String?) ?? '',
      sortOrder: (map['sortOrder'] as num?)?.toInt() ?? 0,
    );
  }

  HomeworkImageModel copyWith({
    String? id,
    String? studentId,
    String? homeworkId,
    String? storageKey,
    String? fileName,
    int? fileSize,
    String? mimeType,
    String? ocrStatus,
    String? ocrText,
    DateTime? createdAt,
    String? batchId,
    int? sortOrder,
  }) {
    return HomeworkImageModel(
      id: id ?? this.id,
      studentId: studentId ?? this.studentId,
      homeworkId: homeworkId ?? this.homeworkId,
      storageKey: storageKey ?? this.storageKey,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      mimeType: mimeType ?? this.mimeType,
      ocrStatus: ocrStatus ?? this.ocrStatus,
      ocrText: ocrText ?? this.ocrText,
      createdAt: createdAt ?? this.createdAt,
      batchId: batchId ?? this.batchId,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}
