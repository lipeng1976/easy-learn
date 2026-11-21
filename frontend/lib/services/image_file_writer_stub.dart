import 'dart:typed_data';

Future<String> writeImageFile(
  String studentId,
  String fileName,
  Uint8List bytes,
) async {
  throw UnsupportedError(
    'Native file storage is unavailable on this platform.',
  );
}

Uint8List? readImageFile(String storageKey) {
  throw UnsupportedError(
    'Native file storage is unavailable on this platform.',
  );
}

void deleteImageFile(String storageKey) {
  throw UnsupportedError(
    'Native file storage is unavailable on this platform.',
  );
}
