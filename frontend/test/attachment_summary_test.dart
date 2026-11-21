import 'package:easy_learn_app/models/homework_image_model.dart';
import 'package:easy_learn_app/utils/attachment_summary.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一行附件。只关心 `mimeType` 与 `fileSize`，其余给最小合法值。
HomeworkImageModel _row(String mimeType, {int bytes = 1024}) {
  return HomeworkImageModel(
    id: 'img_${mimeType.hashCode}_$bytes',
    studentId: 'stu_001',
    homeworkId: 'hw_001',
    storageKey: '20261018/stu_001/${mimeType.hashCode}.bin',
    fileName: 'file',
    fileSize: bytes,
    mimeType: mimeType,
    ocrStatus: 'pending',
    ocrText: '',
    createdAt: DateTime(2026, 10, 18),
  );
}

void main() {
  group('attachmentSummary', () {
    test('没有附件时是空串（调用方据此显示「未上传附件」）', () {
      expect(attachmentSummary(const []), '');
    });

    test('只有照片', () {
      final text = attachmentSummary([
        _row('image/jpeg'),
        _row('image/png'),
      ]);
      expect(text, '2 张照片');
    });

    // ⭐ 这条是本次 bug 的正题：孩子交视频时，家长端曾显示「1 张照片」。
    test('视频不会被说成照片', () {
      final text = attachmentSummary([_row('video/mp4', bytes: 3792662)]);
      expect(text, '1 个视频');
      // 反面判据：只要出现「照片」，就说明又被按行数统称了。
      expect(text.contains('照片'), isFalse);
    });

    test('音频按「个」计，不会混进照片里', () {
      final text = attachmentSummary([_row('audio/mp4', bytes: 800000)]);
      expect(text, '1 个音频');
      expect(text.contains('照片'), isFalse);
    });

    test('混合类型按 照片→音频→视频 固定顺序拼接', () {
      final text = attachmentSummary([
        _row('video/mp4'),
        _row('image/jpeg'),
        _row('audio/mpeg'),
        _row('image/png'),
      ]);
      expect(text, '2 张照片 · 1 个音频 · 1 个视频');
    });

    test('认不出的类型也要计入，不能凭空少一个', () {
      final text = attachmentSummary([_row('application/pdf')]);
      expect(text, '1 个未知附件');
    });

    test('mimeType 为空按未知处理（不兜底成照片）', () {
      // ⚠️ 兜底成照片的表现是：一段音频被当图片送进视觉模型、然后被静默丢弃。
      // 这里守住「不猜」这条线。
      expect(attachmentSummary([_row('')]), '1 个未知附件');
    });
  });
}
