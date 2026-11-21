import '../../core/storage/relative_path.dart';

/// 附件元数据。
/// ⚠️ relativePath 是**相对路径**（相对服务端 STORAGE_ROOT），不是绝对路径；
///    从服务端反序列化时立刻校验，避免绝对路径悄悄流进客户端状态。
class Attachment {
  const Attachment({
    required this.id,
    required this.studentId,
    required this.relativePath,
    required this.fileName,
    required this.mimeType,
    required this.fileSize,
    this.createdAt,
  });

  final String id;
  final String studentId;
  final String relativePath;
  final String fileName;
  final String mimeType;
  final int fileSize;
  final DateTime? createdAt;

  bool get hasFile => relativePath.isNotEmpty;

  factory Attachment.fromJson(Map<String, dynamic> json) {
    return Attachment(
      id: json['id']?.toString() ?? '',
      studentId: json['student_id']?.toString() ?? '',
      relativePath:
          RelativePath.assertRelative(json['relative_path']?.toString() ?? ''),
      fileName: json['file_name']?.toString() ?? '',
      mimeType: json['mime_type']?.toString() ?? '',
      fileSize: (json['file_size'] is num) ? (json['file_size'] as num).toInt() : 0,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'student_id': studentId,
        'relative_path': relativePath,
        'file_name': fileName,
        'mime_type': mimeType,
        'file_size': fileSize,
        if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
      };
}
