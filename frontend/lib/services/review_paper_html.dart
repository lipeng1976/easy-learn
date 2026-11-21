import 'dart:convert';
import 'dart:typed_data';

import '../models/review_model.dart';
import '../utils/plain_math.dart';

/// 复习资料打印页（A4）生成。
///
/// **为什么还留着 HTML**（2026-10-21 起 PDF 已是主路径）：
/// 浏览器打印 HTML 是原生排版（分页、断行、字体都由浏览器算），质量比
/// 「把一份 PDF 塞给浏览器打印」更好。所以 **Web 端的「打印」继续用它**，
/// 而移动端走 `ReviewPaperPdf`（系统打印服务只吃 PDF）。
///
/// 另外 [buildText] 仍然是「转发」的保底内容（分享面板不可用时复制一段文字）。
///
/// ⚠️ 曾经这里是**唯一的**导出方式，落盘成 HTML 到应用私有目录 ——
/// 那个目录普通用户进不去，所以界面上只能报一串路径。现在不再如此：
/// 见 `review_exporter_io.dart` 顶部的说明。
///
/// 这个函数是**纯函数**：不碰文件系统、不碰平台通道。排版是最容易改坏、
/// 也最需要断言的东西（分页、留白、题号连续），所以它必须能单独测。
class ReviewPaperHtml {
  ReviewPaperHtml._();

  static String build({
    required ReviewPaper paper,
    required List<ReviewPaperItem> items,
    String studentName = '',
    bool includeAnswerPage = false,
    Map<String, List<Uint8List>> images = const {},
  }) {
    final sorted = [...items]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final questions = StringBuffer();
    for (var i = 0; i < sorted.length; i++) {
      questions.write(
        _questionBlock(
          i + 1,
          sorted[i],
          images[sorted[i].mistakeId] ?? const [],
        ),
      );
    }

    final answerPage = includeAnswerPage ? _answerPage(sorted) : '';

    return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>${_escape(plainMathText(paper.title))}</title>
<style>
  @page { size: A4; margin: 16mm 14mm; }
  * { box-sizing: border-box; }
  body {
    font-family: "PingFang SC", "Microsoft YaHei", "Hiragino Sans GB",
                 "Source Han Sans SC", "Noto Sans CJK SC", sans-serif;
    color: #1a1a1a; font-size: 13px; line-height: 1.7; margin: 0;
  }
  .cover { border: 1px solid #d0d0d0; border-radius: 6px; padding: 14px 16px; margin-bottom: 18px; }
  .cover h1 { font-size: 18px; margin: 0 0 10px; font-weight: 600; }
  .meta { display: flex; flex-wrap: wrap; gap: 6px 24px; font-size: 12.5px; color: #444; }
  .meta span { white-space: nowrap; }
  .tip { margin-top: 10px; padding-top: 8px; border-top: 1px dashed #d0d0d0;
         font-size: 12px; color: #666; }
  .q { border-bottom: 1px solid #e6e6e6; padding: 12px 0 14px; page-break-inside: avoid; }
  .q-head { display: flex; align-items: baseline; gap: 8px; margin-bottom: 6px; }
  .q-no { font-weight: 600; font-size: 14px; }
  .tag { font-size: 11.5px; color: #185fa5; border: 1px solid #b5d4f4;
         background: #e6f1fb; border-radius: 999px; padding: 1px 8px; }
  .q-body { white-space: pre-wrap; }
  .q-body .sub { color: #666; font-size: 12.5px; }
  .q-img { display: block; max-height: 132px; max-width: 100%; margin: 6px 0 2px; }
  .lines { margin-top: 10px; }
  .line { border-bottom: 1px solid #ececec; height: 26px; }
  .footer { margin-top: 16px; font-size: 12px; color: #666;
            display: flex; justify-content: space-between; }
  .answer-page { page-break-before: always; }
  .answer-page h2 { font-size: 15px; margin: 0 0 10px; font-weight: 600; }
  .ans { padding: 8px 0; border-bottom: 1px dashed #e6e6e6; page-break-inside: avoid; }
  .ans b { font-weight: 600; }
</style>
</head>
<body>
  <div class="cover">
    <h1>${_escape(plainMathText(paper.title))}</h1>
    <div class="meta">
      <span>学生：${_escape(studentName.isEmpty ? '________' : studentName)}</span>
      <span>卷编号：${_escape(paper.id)}</span>
      <span>生成时间：${_formatDate(paper.createdAt)}</span>
      <span>题量：${sorted.length} 道</span>
      ${paper.knowledgePoints.isEmpty ? '' : '<span>知识点：${_escape(plainMathText(paper.knowledgePoints.join('、')))}</span>'}
    </div>
    <div class="tip">
      做法：先不看课本独立完成，写清中间过程；做完后按附页答案自查，
      回到 App 逐题标记对错并提交检查。做对的题会从错题库移出。
    </div>
  </div>
  $questions
  <div class="footer">
    <span>共 ${sorted.length} 道题</span>
    <span>家长签字：____________</span>
  </div>
  $answerPage
</body>
</html>
''';
  }

  /// 纯文本版卷子 —— 用来**转发**。
  ///
  /// 为什么转发要单独做一份文本而不是把 HTML 发出去：微信里点开 HTML 附件
  /// 的体验很差（多半被当成陌生文件拦一下、还要跳浏览器），而一段文本
  /// 是直接可读、可复制、群里谁都能看的。学生真正会用的路径是
  /// 「转发给同学/家长看一眼」，那就该顺着这条路径做。
  ///
  /// 刻意不用 Markdown 符号：微信不渲染，`**` 只会原样出现。
  static String buildText({
    required ReviewPaper paper,
    required List<ReviewPaperItem> items,
    String studentName = '',
    bool includeAnswers = false,
  }) {
    final sorted = [...items]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final buffer = StringBuffer()
      ..writeln(paper.title)
      ..writeln(
        '学生：${studentName.isEmpty ? '（未填写）' : studentName}'
        ' · 共 ${sorted.length} 道题'
        ' · ${_formatShortDate(paper.createdAt)}',
      )
      ..writeln();

    for (var i = 0; i < sorted.length; i++) {
      final item = sorted[i];
      final lines = item.questionBody
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();
      if (lines.isEmpty) continue;
      // 知识点前置成方括号标签：收消息的人（多半是家长或同学）看到
      // 「[分数比较] 请重做这道题」才知道这道题在考什么。
      final tag = item.knowledgePoint.trim().isEmpty
          ? ''
          : '[${plainMathText(item.knowledgePoint.trim())}] ';
      // 原题可能是多行（选项、分步提问），全部按正文缩进输出。
      // 老卷子的题干里拼过提示，那部分用括号弱化 —— 见 [hasLegacyHints]。
      final legacy = item.hasLegacyHints;
      final body = legacy ? lines.take(1) : lines;
      buffer.writeln('${i + 1}. $tag${plainMathText(body.first.trim())}');
      for (final line in body.skip(1)) {
        buffer.writeln('   ${plainMathText(line.trim())}');
      }
      if (legacy) {
        for (final hint in lines.skip(1)) {
          buffer.writeln('   （${plainMathText(hint.trim())}）');
        }
      }
      buffer.writeln();
    }

    if (includeAnswers) {
      buffer
        ..writeln('—— 参考答案 ——')
        ..writeln();
      for (var i = 0; i < sorted.length; i++) {
        buffer.writeln(
          '${i + 1}. ${plainMathText(sorted[i].answerKey.trim())}',
        );
      }
      buffer.writeln();
    }

    buffer.writeln('（做完在伴学 App 里逐题回传批改，做对的题会自动移出错题库）');
    return buffer.toString().trimRight();
  }

  static String _questionBlock(
    int number,
    ReviewPaperItem item,
    List<Uint8List> images,
  ) {
    // ⚠️ 老卷子（2026-10-21 之前）把「上次的答案 / 错因」拼进了题干，
    // 那时约定第一行是正文、其余是提示。历史卷子是快照，按老格式排，
    // 否则同一段提示会被印两遍。见 [ReviewPaperItem.hasLegacyHints]。
    final legacy = item.hasLegacyHints;
    final lines = item.questionBody
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    final mainLines = legacy ? lines.take(1) : lines;
    final hintLines = <String>[
      if (legacy)
        ...lines.skip(1)
      else ...[
        if (item.originalAnswer.trim().isNotEmpty)
          '上次的答案：${item.originalAnswer.trim()}',
        if (item.wrongReason.trim().isNotEmpty)
          '上次的错误原因：${item.wrongReason.trim()}',
      ],
    ];

    // 纸上没有公式渲染器：`$x>20$` 必须清洗成 `x>20`，否则浏览器打印出来
    // 就是满纸美元符号和反斜杠。与 PDF 版共用 [plainMathText]。
    final main = mainLines
        .map((line) => _escape(plainMathText(line)))
        .join('<br>');
    final hints = hintLines
        .map((line) => '<div class="sub">${_escape(plainMathText(line))}</div>')
        .join();
    // 原题照片内联成 data URI：打印页是**独立文件**（Web 端会被写进 iframe），
    // 引用外部路径在打印窗口里取不到。最多两张，与 PDF 版同一口径。
    final imagesHtml = images
        .take(2)
        .map(
          (bytes) =>
              '<img class="q-img" src="data:${_imageMime(bytes)};base64,'
              '${base64Encode(bytes)}">',
        )
        .join();

    final blankLines = List.filled(5, '<div class="line"></div>').join();

    return '''
  <div class="q">
    <div class="q-head">
      <span class="q-no">$number.</span>
      ${item.knowledgePoint.isEmpty ? '' : '<span class="tag">${_escape(plainMathText(item.knowledgePoint))}</span>'}
    </div>
    <div class="q-body">$main$hints$imagesHtml</div>
    <div class="lines">$blankLines</div>
  </div>
''';
  }

  /// 从字节头判断图片类型。
  ///
  /// 错题照片可能是 JPEG 也可能是 PNG（相册里存的截图），而 data URI 的
  /// MIME 写错时浏览器**不报错、直接不显示** —— 那种失败在打印页上就是一片空白。
  static String _imageMime(Uint8List bytes) {
    if (bytes.length > 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    return 'image/jpeg';
  }

  static String _answerPage(List<ReviewPaperItem> items) {
    final blocks = StringBuffer();
    for (var i = 0; i < items.length; i++) {
      blocks.write(
        '<div class="ans"><b>${i + 1}.</b> ${_escape(plainMathText(items[i].answerKey))}</div>\n',
      );
    }
    return '''
  <div class="answer-page">
    <h2>参考答案与评分要点</h2>
    <div class="tip">此页供自查或家长批改使用，可按需不打印。</div>
    $blocks
  </div>
''';
  }

  static String _escape(String input) => input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _formatDate(DateTime value) {
    final local = value.toLocal();
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  /// 转发文本里不带时分：一条微信消息的抬头写「9月15日 20:10」比「2026-09-15」更自然，
  /// 而具体几点几分对收消息的人没有意义。
  static String _formatShortDate(DateTime value) {
    final local = value.toLocal();
    return '${local.month}月${local.day}日';
  }
}
