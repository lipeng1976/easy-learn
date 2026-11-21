import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/services/review_paper_pdf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;

/// 1×1 的 JPEG。判据只需要「这是一张能被解码的图」，不需要它好看。
const String _tinyJpegBase64 =
    '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRof'
    'Hh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAAB'
    'AAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==';

Uint8List _tinyJpeg() => base64Decode(_tinyJpegBase64);

/// 复习资料 PDF 生成。
///
/// 盯三件**不报错但会让纸上是废纸**的事：
///   1. 生成了 PDF（而不是退回到 HTML 或空文件）；
///   2. 字体**内嵌**进 PDF（没内嵌的话，别人的设备打开是整页方块）；
///   3. 答案页真的另起一页（否则学生打印时把答案一起印给做题的人）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late pw.Font font;

  setUpAll(() {
    final bytes = File(ReviewPaperPdf.fontAsset).readAsBytesSync();
    font = pw.Font.ttf(ByteData.sublistView(bytes));
  });

  ReviewPaper paper() => ReviewPaper(
    id: 'paper_1',
    studentId: 'stu_001',
    title: '错题重做卷 · 一元一次方程',
    subject: '数学',
    status: PaperStatus.printed,
    createdAt: DateTime(2026, 10, 20, 9, 30),
    itemCount: 3,
    knowledgePoints: const ['一元一次方程', '列代数式'],
  );

  List<ReviewPaperItem> items() => [
    ReviewPaperItem(
      id: 'i1',
      paperId: 'paper_1',
      mistakeId: 'm1',
      questionTitle: '解方程',
      questionBody: '解方程：\$2x+3=11\$，写清步骤。\n上次的答案：\$2x=8\$',
      answerKey: 'x=4',
      knowledgePoint: '一元一次方程',
      sortOrder: 1,
    ),
    ReviewPaperItem(
      id: 'i2',
      paperId: 'paper_1',
      mistakeId: 'm2',
      questionTitle: '列代数式',
      questionBody: '列代数式：当 \$x>20\$ 时，水费是多少？',
      answerKey: r'$2.6x-12$',
      knowledgePoint: '列代数式',
      sortOrder: 2,
    ),
    ReviewPaperItem(
      id: 'i3',
      paperId: 'paper_1',
      mistakeId: 'm3',
      questionTitle: '计算',
      questionBody: '计算：\$ \frac{1}{2}+\frac{1}{3} \$',
      answerKey: r'$\frac{5}{6}$',
      knowledgePoint: '',
      sortOrder: 3,
    ),
  ];

  Future<Uint8List> build({bool withAnswers = true}) => ReviewPaperPdf.buildWithFont(
    paper: paper(),
    items: items(),
    studentName: '林小宇',
    includeAnswerPage: withAnswers,
    font: font,
  );

  String raw(Uint8List bytes) => String.fromCharCodes(bytes);

  test('生成的是真 PDF，不是空的占位文件', () async {
    final bytes = await build();
    expect(bytes.length, greaterThan(8000), reason: '文件太小，多半只写了个空壳');
    expect(
      raw(bytes).substring(0, 5),
      '%PDF-',
      reason: '文件头不是 PDF —— 保存下来的东西打不开',
    );
  });

  test('中文字体被内嵌（否则别人的设备上是整页方块）', () async {
    final text = raw(await build());
    // 内嵌 TrueType 字体在 PDF 里是 FontFile2；子集化后通常还会带前缀标记。
    expect(
      text.contains('/FontFile2') || text.contains('/FontFile3'),
      isTrue,
      reason: 'PDF 里没有字体文件 —— 换台设备打开就是方块',
    );
    // 字体名出现在资源字典里，能进一步确认用的是我们那份 Noto。
    expect(text.contains('NotoSansSC') || text.contains('NotoSans'), isTrue);
  });

  test('答案页另起一页；不带答案时只有一页', () async {
    int pages(Uint8List bytes) =>
        RegExp(r'/Type\s*/Page[^s]').allMatches(raw(bytes)).length;

    final withAnswers = pages(await build());
    final withoutAnswers = pages(await build(withAnswers: false));

    expect(
      withAnswers,
      greaterThan(withoutAnswers),
      reason: '答案没有另起一页 —— 学生打印题目时会把答案一起印出来',
    );
    expect(withoutAnswers, greaterThanOrEqualTo(1));
  });

  // `pdf` 包写的是 `/Subtype/Image`（无空格），不同版本又可能带空格 ——
  // 判据盯「有没有这个类型」，别盯排版。
  final imageObject = RegExp(r'/Subtype\s*/\s*Image');

  test('传了原题照片，纸面上就真有这张图（图形题不能只剩文字）', () async {
    // `compress: false` 是给判据留的入口：压缩后图片字典会被塞进对象流，
    // 断言只能靠猜。这里关掉压缩，直接看有没有图片 XObject。
    final withImage = await ReviewPaperPdf.buildWithFont(
      paper: paper(),
      items: items(),
      studentName: '林小宇',
      images: {
        'm1': [_tinyJpeg()],
      },
      font: font,
      compress: false,
    );
    expect(
      imageObject.hasMatch(raw(withImage)),
      isTrue,
      reason: '传了照片却没有图片对象 —— 卷面上图形题只剩一行文字，学生不知道题长什么样',
    );
  });

  test('反面对照：没传照片就没有图片对象（上一条断言不是恒真）', () async {
    final without = await ReviewPaperPdf.buildWithFont(
      paper: paper(),
      items: items(),
      studentName: '林小宇',
      font: font,
      compress: false,
    );
    expect(
      imageObject.hasMatch(raw(without)),
      isFalse,
      reason: '没图也出现图片对象，说明上一条的判据抓不到「图没了」这件事',
    );
  });

  test('题目再多也不会因为一页装不下而炸', () async {
    final many = [
      for (var i = 0; i < 40; i++)
        ReviewPaperItem(
          id: 'x$i',
          paperId: 'paper_1',
          mistakeId: 'm$i',
          questionTitle: '计算',
          questionBody: '第 $i 题：解方程 \$x+$i=0\$。',
          answerKey: 'x=-$i',
          knowledgePoint: '一元一次方程',
          sortOrder: i,
        ),
    ];
    final bytes = await ReviewPaperPdf.buildWithFont(
      paper: paper(),
      items: many,
      font: font,
    );
    expect(bytes.length, greaterThan(8000));
    expect(
      RegExp(r'/Type\s*/Page[^s]').allMatches(raw(bytes)).length,
      greaterThan(1),
      reason: '40 道题挤在一页 —— 分页没生效',
    );
  });
}
