import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/services/review_paper_html.dart';
import 'package:easy_learn_app/services/review_paper_pdf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;

/// 卷面**内容**的判据：原题、原题照片、以及「上次的答案」不重复。
///
/// 为什么要单开一个文件：`review_paper_pdf_test.dart` 盯的是「PDF 本身对不对」
/// （是不是真 PDF、字体有没有内嵌、答案页有没有另起一页）。这里盯的是
/// **纸上印的是不是那道题** —— 2026-10-21 之前，卷子上只有一句
/// 「重新独立完成这道题」，学生根本不知道自己要做哪道题。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 1×1 的 JPEG。判据只需要「这是一张能被解码的图」，不需要它好看。
  final tinyJpeg = base64Decode(
    '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRof'
    'Hh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAAB'
    'AAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==',
  );

  ReviewPaper paper() => ReviewPaper(
    id: 'paper_content',
    studentId: 'stu_001',
    title: '数学错题重做卷 · 第7轮',
    createdAt: DateTime(2026, 10, 21, 10),
    itemCount: 1,
    knowledgePoints: const ['有理数混合运算'],
  );

  ReviewPaperItem item({
    String body = r'计算：$(-1)\times(-4)+12\div(-3)$，写出每一步。',
    String originalAnswer = '-63',
    String wrongReason = r'第一步 $(-1)\times(-4)$ 应得 +4，写成了 -4。',
  }) => ReviewPaperItem(
    id: 'it_1',
    paperId: 'paper_content',
    mistakeId: 'rm_1',
    questionTitle: '十月月考 · 有理数混合运算',
    questionBody: body,
    originalAnswer: originalAnswer,
    wrongReason: wrongReason,
    answerKey: '-8',
    knowledgePoint: '有理数混合运算',
    sortOrder: 1,
  );

  group('HTML 打印页', () {
    test('印的是原题，不是「重新独立完成这道题」', () {
      final html = ReviewPaperHtml.build(
        paper: paper(),
        items: [item()],
        studentName: '李雨霏',
      );

      expect(
        html.contains('重新独立完成这道题'),
        isFalse,
        reason: '卷面上没有题目，学生不知道要做哪道题',
      );
      expect(
        html.contains(r'(-1)'),
        isTrue,
        reason: '原题正文没进卷面',
      );
      // 公式标记不能原样出现在纸上（浏览器打印会显示成 `$...$`）。
      expect(html.contains(r'$(-1)'), isFalse);
    });

    test('「上次的答案」只出现一次（提示不与题干重复）', () {
      final html = ReviewPaperHtml.build(
        paper: paper(),
        items: [item()],
      );

      final occurrences = '上次的答案'.allMatches(html).length;
      expect(occurrences, 1, reason: '同一段提示被印了两遍');
      expect(html.contains('上次的错误原因'), isTrue);
    });

    test('老卷子的题干里已经拼过提示时，不重复印', () {
      // 2026-10-21 之前的格式：题干末尾带着这两行。
      final legacy = item(
        body: '重新独立完成这道题，写出完整过程。\n上次的答案：-63\n'
            '上次的错误原因：第一步写反了。',
      );
      expect(legacy.hasLegacyHints, isTrue);

      final html = ReviewPaperHtml.build(paper: paper(), items: [legacy]);
      expect('上次的答案'.allMatches(html).length, 1);
    });

    test('原题照片内联成 data URI（打印页是独立文件，外链取不到）', () {
      final html = ReviewPaperHtml.build(
        paper: paper(),
        items: [item()],
        images: {
          'rm_1': [tinyJpeg],
        },
      );
      expect(
        html.contains('src="data:image/jpeg;base64,'),
        isTrue,
        reason: '原题照片没进打印页',
      );
    });
  });

  group('PDF', () {
    late pw.Font font;
    setUpAll(() {
      font = pw.Font.ttf(
        ByteData.sublistView(File(ReviewPaperPdf.fontAsset).readAsBytesSync()),
      );
    });

    Future<Uint8List> build({
      Map<String, List<Uint8List>> images = const {},
    }) => ReviewPaperPdf.buildWithFont(
      paper: paper(),
      items: [item()],
      font: font,
      compress: false, // 关压缩才能读到对象字典
      images: images,
    );

    test('原题照片真的嵌进了 PDF', () async {
      final bytes = await build(
        images: {
          'rm_1': [tinyJpeg],
        },
      );
      expect(
        String.fromCharCodes(bytes).contains('/Subtype/Image'),
        isTrue,
        reason: 'PDF 里没有图片对象 —— 原题图没印出来',
      );
    });

    test('没有照片时不凭空多出图片对象（防止上一条恒绿）', () async {
      final bytes = await build();
      expect(String.fromCharCodes(bytes).contains('/Subtype/Image'), isFalse);
    });
  });
}
