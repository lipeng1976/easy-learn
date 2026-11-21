import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/review_model.dart';
import '../utils/plain_math.dart';

/// 复习资料 → A4 PDF。
///
/// ── 为什么现在真的出 PDF 了 ──────────────────────────────────────────────
///
/// 之前导出的是 **HTML 文件**，落在应用私有目录
/// （`/data/user/0/<包名>/app_flutter/review_papers/`）—— 普通用户既看不到
/// 也进不去，所以界面上只能给一句「已保存到：<一长串路径>」。
/// 那等于什么都没交到学生手里。
///
/// 现在：`pdf` 包直接排版成 PDF，再交给系统去打印 / 另存 / 分享。
/// 中文字体必须内嵌，否则整页方块 —— 见 `assets/fonts/` 里的子集字体。
///
/// ⚠️ 这里是**纯函数**（只依赖传入的字体字节），不碰文件系统、不碰平台通道：
/// 排版是最容易改坏的东西（分页、题号连续、答案页独立起页），必须能单独测。
class ReviewPaperPdf {
  ReviewPaperPdf._();

  /// 内嵌字体资源。子集只覆盖 GB2312 + 常用符号，见 `tools/make_pdf_charset.py`。
  static const String fontAsset = 'assets/fonts/NotoSansSC-Regular.ttf';

  static pw.Font? _cachedFont;

  /// 生成 PDF 字节。
  ///
  /// [includeAnswerPage] 为 true 时，答案**另起一页**（方便只印题目那几页）。
  /// [images] 是「错题 id → 原题照片字节」，用于把题目里没法用文字表达的部分
  /// （几何图、表格、手写的原题）一起印出来。
  static Future<Uint8List> build({
    required ReviewPaper paper,
    required List<ReviewPaperItem> items,
    String studentName = '',
    bool includeAnswerPage = false,
    Map<String, List<Uint8List>> images = const {},
  }) async {
    final font = await _loadFont();
    return buildWithFont(
      paper: paper,
      items: items,
      studentName: studentName,
      includeAnswerPage: includeAnswerPage,
      images: images,
      font: font,
    );
  }

  /// 字体只解析一次：`Font.ttf` 会把整个字体读进内存并建表，
  /// 每次导出都做一遍会让点了导出要等一下才弹面板。
  static Future<pw.Font> _loadFont() async {
    final cached = _cachedFont;
    if (cached != null) return cached;
    final data = await rootBundle.load(fontAsset);
    final font = pw.Font.ttf(data);
    _cachedFont = font;
    return font;
  }

  /// 判据入口：字体由调用方给，避免依赖 `rootBundle`。
  ///
  /// [compress] 只给判据用：关掉之后 PDF 的对象字典是明文，能直接断言
  /// 「里面有没有图片 XObject」。生产必须开着（体积差好几倍）。
  static Future<Uint8List> buildWithFont({
    required ReviewPaper paper,
    required List<ReviewPaperItem> items,
    required pw.Font font,
    String studentName = '',
    bool includeAnswerPage = false,
    Map<String, List<Uint8List>> images = const {},
    bool compress = true,
  }) {
    final sorted = [...items]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final document = pw.Document(
      compress: compress,
      title: paper.title,
      author: '伴学',
      creator: '伴学',
    );

    // 只有一个字重：把 bold 也指向它，否则 pdf 包会找不到字体而回落到
    // 内置的 Helvetica —— 中文立刻变成方块。
    final theme = pw.ThemeData.withFont(base: font, bold: font);

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(
          14 * PdfPageFormat.mm,
          15 * PdfPageFormat.mm,
          14 * PdfPageFormat.mm,
          15 * PdfPageFormat.mm,
        ),
        theme: theme,
        footer: (context) => _footer(context, total: sorted.length),
        build: (context) => [
          _cover(paper: paper, studentName: studentName, count: sorted.length),
          pw.SizedBox(height: 14),
          for (var i = 0; i < sorted.length; i++)
            _question(
              number: i + 1,
              item: sorted[i],
              images: images[sorted[i].mistakeId] ?? const [],
            ),
          if (includeAnswerPage) ...[
            // 答案必须独立起页：学生打印时常常只印题目那几页。
            pw.NewPage(),
            _answerPage(sorted),
          ],
        ],
      ),
    );

    return document.save();
  }

  static pw.Widget _cover({
    required ReviewPaper paper,
    required String studentName,
    required int count,
  }) {
    final meta = <String>[
      '学生：${studentName.isEmpty ? '________' : studentName}',
      '卷编号：${paper.id}',
      '生成时间：${_formatDate(paper.createdAt)}',
      '题量：$count 道',
      if (paper.knowledgePoints.isNotEmpty)
        '知识点：${paper.knowledgePoints.join('、')}',
    ];

    return pw.Container(
      padding: const pw.EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey400, width: 0.8),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            plainMathText(paper.title),
            style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.Wrap(
            spacing: 18,
            runSpacing: 3,
            children: [
              for (final line in meta)
                pw.Text(
                  plainMathText(line),
                  style: const pw.TextStyle(
                    fontSize: 9.5,
                    color: PdfColors.grey800,
                  ),
                ),
            ],
          ),
          pw.SizedBox(height: 7),
          pw.Container(
            padding: const pw.EdgeInsets.only(top: 6),
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                top: pw.BorderSide(color: PdfColors.grey400, width: 0.6),
              ),
            ),
            child: pw.Text(
              '做法：先不看课本独立完成，写清中间过程；做完后按附页答案自查，'
              '回到 App 逐题标记对错并提交检查。做对的题会从错题库移出。',
              style: const pw.TextStyle(
                fontSize: 9,
                color: PdfColors.grey700,
                lineSpacing: 2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _question({
    required int number,
    required ReviewPaperItem item,
    List<Uint8List> images = const [],
  }) {
    // 题干按**原题**完整排：选项、分步提问都要保留，所以多行全部按正文处理。
    //
    // ⚠️ 老卷子（2026-10-21 之前）把「上次的答案 / 错因」拼进了题干，
    // 那时约定「第一行是正文、其余是提示」。历史卷子是快照，不会重写，
    // 所以这里按 [ReviewPaperItem.hasLegacyHints] 分支处理 —— 否则同一段
    // 提示会被印两遍（题干里一遍、下面单独排一遍）。
    final lines = item.questionBody
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    final legacy = item.hasLegacyHints;
    final main = lines.isEmpty
        ? ''
        : legacy
        ? lines.first
        : lines.join('\n');
    final hints = <String>[
      if (legacy)
        ...lines.skip(1)
      else ...[
        if (item.originalAnswer.trim().isNotEmpty)
          '上次的答案：${item.originalAnswer.trim()}',
        if (item.wrongReason.trim().isNotEmpty)
          '上次的错误原因：${item.wrongReason.trim()}',
      ],
    ];

    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 10, bottom: 12),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.6),
        ),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(
                width: 20,
                child: pw.Text(
                  '$number.',
                  style: pw.TextStyle(
                    fontSize: 11.5,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              if (item.knowledgePoint.trim().isNotEmpty)
                pw.Container(
                  margin: const pw.EdgeInsets.only(right: 6),
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: pw.BoxDecoration(
                    color: PdfColors.blue50,
                    borderRadius: pw.BorderRadius.circular(8),
                  ),
                  child: pw.Text(
                    plainMathText(item.knowledgePoint),
                    style: const pw.TextStyle(
                      fontSize: 8,
                      color: PdfColors.blue800,
                    ),
                  ),
                ),
              pw.Expanded(
                child: pw.Text(
                  plainMathText(main),
                  style: const pw.TextStyle(fontSize: 10.5, lineSpacing: 3),
                ),
              ),
            ],
          ),
          if (hints.isNotEmpty) ...[
            pw.SizedBox(height: 3),
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 20),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  for (final hint in hints)
                    pw.Text(
                      plainMathText(hint),
                      style: const pw.TextStyle(
                        fontSize: 9,
                        color: PdfColors.grey600,
                        lineSpacing: 2,
                      ),
                    ),
                ],
              ),
            ),
          ],
          // 原题照片：题干里的几何图、表格、手写内容文字表达不了，
          // 没有它学生根本不知道题目长什么样。最多两张、限高，
          // 免得一张竖拍的照片把整页撑成一屏。
          if (images.isNotEmpty) ...[
            pw.SizedBox(height: 5),
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 20),
              child: pw.Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final bytes in images.take(2))
                    pw.Image(
                      pw.MemoryImage(bytes),
                      height: 132,
                      fit: pw.BoxFit.contain,
                    ),
                ],
              ),
            ),
          ],
          pw.SizedBox(height: 6),
          // 作答区：5 条横线。高度固定，题与题之间的空白才一致。
          for (var i = 0; i < 5; i++)
            pw.Container(
              height: 22,
              decoration: const pw.BoxDecoration(
                border: pw.Border(
                  bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.5),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static pw.Widget _answerPage(List<ReviewPaperItem> items) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          '参考答案与评分要点',
          style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 5),
        pw.Text(
          '此页供自查或家长批改使用，可按需不打印。',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
        ),
        pw.SizedBox(height: 8),
        for (var i = 0; i < items.length; i++)
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(vertical: 5),
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.5),
              ),
            ),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.SizedBox(
                  width: 20,
                  child: pw.Text(
                    '${i + 1}.',
                    style: pw.TextStyle(
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
                pw.Expanded(
                  child: pw.Text(
                    plainMathText(
                      items[i].answerKey.trim().isEmpty
                          ? '（未提供答案）'
                          : items[i].answerKey,
                    ),
                    style: const pw.TextStyle(fontSize: 10, lineSpacing: 2),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static pw.Widget _footer(pw.Context context, {required int total}) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 8),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            '共 $total 道题',
            style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey600),
          ),
          pw.Text(
            '家长签字：____________',
            style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey600),
          ),
          pw.Text(
            '第 ${context.pageNumber} / ${context.pagesCount} 页',
            style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey600),
          ),
        ],
      ),
    );
  }

  static String _formatDate(DateTime value) {
    final local = value.toLocal();
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
