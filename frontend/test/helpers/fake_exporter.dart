import 'dart:typed_data';

import 'package:easy_learn_app/services/review_exporter.dart';

/// 导出端口的测试替身。
///
/// 三个动作分别计数，而不是合成一个 `calls`：
/// 「打印」和「转发」在测试里必须是**可区分**的 —— 否则把实现改成
/// 「不管选什么都弹打印」也照样全绿，而这正是要防的回归。
///
/// 三个测试文件共用这一份：它已经承载了完整接口，各写一份的话，
/// 以后接口加一个方法就要改三处，漏一处就是编译错。
class FakeExporter implements ReviewExporter {
  int printCalls = 0;
  int saveCalls = 0;
  int shareCalls = 0;

  /// 最近一次交出去的 PDF 字节。
  ///
  /// ⚠️ 必须断言它**不是空的**：这条链路最容易出的坏法是「界面报已保存，
  /// 实际写了个 0 字节文件」—— 那种失败在消息里看不出来。
  Uint8List? lastPdf;

  /// 打印时同时给的 HTML（只有打印用得上：浏览器排版比 PDF 更好）。
  String lastHtml = '';
  String lastText = '';
  String lastName = '';

  /// 下一次导出的返回值。用来构造失败 / 取消场景。
  ExportResult? nextResult;

  ExportResult _result(String what) =>
      nextResult ??
      ExportResult(ok: true, message: '$what（测试替身）', path: '/tmp/$lastName');

  void _remember(Uint8List pdf, String fileName) {
    lastPdf = pdf;
    lastName = fileName;
  }

  @override
  Future<ExportResult> printPaper({
    required Uint8List pdf,
    required String html,
    required String fileName,
  }) async {
    printCalls++;
    _remember(pdf, fileName);
    lastHtml = html;
    return _result('已交给打印');
  }

  @override
  Future<ExportResult> savePdf(
    Uint8List pdf, {
    required String fileName,
  }) async {
    saveCalls++;
    _remember(pdf, fileName);
    return _result('已保存 PDF');
  }

  @override
  Future<ExportResult> sharePdf(
    Uint8List pdf, {
    required String fileName,
    required String text,
  }) async {
    shareCalls++;
    _remember(pdf, fileName);
    lastText = text;
    return nextResult ??
        const ExportResult(
          ok: true,
          copiedToClipboard: true,
          message: '卷子内容已复制（测试替身）',
        );
  }
}
