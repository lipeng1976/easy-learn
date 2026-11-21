import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

Future<String> writeImageFile(
  String studentId,
  String fileName,
  Uint8List bytes,
) async {
  // 必须落在「文稿目录」而不是「临时目录」：
  // 临时目录会被系统在空间紧张或重启后清理，而作业照片要长期保留，
  // 家长随时可能要打开查看。用临时目录会表现为「家长端图片不可用」。
  final directory = await getApplicationDocumentsDirectory();
  final homeworkDirectory = Directory(
    path.join(directory.path, 'easy_learn', 'homework', studentId),
  );
  await homeworkDirectory.create(recursive: true);
  final file = File(path.join(homeworkDirectory.path, fileName));
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

Uint8List? readImageFile(String storageKey) {
  try {
    // 兼容早期把图片写到临时目录的历史数据
    final file = File(storageKey);
    if (file.existsSync()) return file.readAsBytesSync();
    final migrated = _fromLegacyTempPath(storageKey);
    if (migrated != null && migrated.existsSync()) {
      return migrated.readAsBytesSync();
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// 历史版本把图片写在临时目录下，这里做一次路径回溯读取，
/// 避免升级后老用户看不到之前提交的作业照片。
File? _fromLegacyTempPath(String storageKey) {
  final marker = path.join('easy_learn', 'homework');
  final index = storageKey.indexOf(marker);
  if (index < 0) return null;
  final suffix = storageKey.substring(index);
  return File(path.join(Directory.systemTemp.path, suffix));
}

void deleteImageFile(String storageKey) {
  try {
    final file = File(storageKey);
    if (file.existsSync()) file.deleteSync();
  } catch (_) {}
}
