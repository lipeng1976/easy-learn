import 'dart:typed_data';

import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'web-safe local storage returns image metadata without database blob data',
    () async {
      final service = LocalImageStorageService(useMemory: true);
      final image = await service.saveHomeworkImage(
        studentId: 'stu_test',
        fileName: 'math-homework.jpg',
        bytes: Uint8List.fromList([1, 2, 3, 4]),
        ocrStatus: 'completed',
        ocrText: '完成数学练习',
      );

      expect(image.storageKey, startsWith('memory://'));
      expect(image.fileSize, 4);
      expect(image.mimeType, 'image/jpeg');
      expect(image.ocrStatus, 'completed');
      expect(image.ocrText, '完成数学练习');
    },
  );
}
