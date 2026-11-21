import 'dart:typed_data';

import 'review_exporter_io.dart'
    if (dart.library.html) 'review_exporter_html.dart';

/// 一次导出动作的结果。
class ExportResult {
  const ExportResult({
    required this.ok,
    required this.message,
    this.path = '',
    this.copiedToClipboard = false,
  });

  final bool ok;
  final String message;

  /// 落盘路径。Web 端恒为空字符串 —— 浏览器不允许脚本知道用户把文件存到了哪，
  /// 编一个路径出来只会让人以为文件在某个确定的位置。
  final String path;

  /// 「转发」退回到了复制内容（系统分享面板不可用）。
  ///
  /// 单独立一个字段而不是靠读 [message]：界面要据此换一个图标和后续提示，
  /// 而文案随时会改，用文案当状态判断条件是最容易在改字时静默失效的做法。
  final bool copiedToClipboard;
}

/// 复习资料的三种去向。
///
/// 三者语义不同，**不能互相顶替**：
/// - [print] 出纸（或浏览器里另存为 PDF）——家里有打印机时用
/// - [download] 存成文件 —— 留档，或拿到别的设备上再打印
/// - [share] 发出去 —— 手机上直接进微信发给老师/同学/家长，最常用
///
/// 之所以拆开而不是「打印时顺便下载」：学生点「打印」时想要的是纸，
/// 多弹一个下载框会让他怀疑自己点错了按钮。意图必须一一对应。
enum ExportTarget {
  print,
  download,
  share,
}

/// 复习资料导出端口。
///
/// 只关心「把一份卷子交到学生手里」，不关心卷子怎么生成 ——
/// 生成部分是纯函数（`ReviewPaperPdf` / `ReviewPaperHtml`），因此排版逻辑
/// 可以脱离平台被测试，这里只剩一点点平台差异。
///
/// ## 为什么交出去的是 PDF 而不是 HTML
///
/// 2026-10-21 之前这里交的是 HTML 文件，落在**应用私有目录**
/// （`/data/user/0/<包名>/app_flutter/review_papers/`）。那个目录用户既看不到、
/// 也进不去，所以界面上只能报一串路径 —— 学生记不住，也没法把文件发出去。
///
/// 现在一律给 PDF：[savePdf] 走系统「另存为」让用户自己挑位置，
/// [sharePdf] 走系统分享面板直接进微信。[printPaper] 仍然收一份 HTML：
/// 浏览器打印 HTML 的排版质量比打印 PDF 更好，而 Android 没有这条通道，
/// 用它自己的打印服务（可选「另存为 PDF」）。
abstract class ReviewExporter {
  /// 出纸。
  ///
  /// Web 用 [html]（浏览器原生排版 + `window.print()`）；
  /// 桌面/移动端用 [pdf]（系统打印服务，里面可「另存为 PDF」）。
  ///
  /// 两个产物都收，是因为**两端的「打印」根本不是同一件事**：
  /// 浏览器打印的是一张网页，手机打印的是一份 PDF。
  Future<ExportResult> printPaper({
    required Uint8List pdf,
    required String html,
    required String fileName,
  });

  /// 存成 PDF 文件。桌面/移动端应弹系统「另存为」，让用户自己选位置。
  Future<ExportResult> savePdf(Uint8List pdf, {required String fileName});

  /// 发出去：系统分享面板，带上 PDF 附件。
  ///
  /// [text] 是**纯文本版卷子**（`ReviewPaperHtml.buildText`）—— 它才是保底路径：
  /// 分享面板不可用时会被复制到剪贴板，粘到微信里就能发。
  /// 只带文件不带文本的话，保底路径就没东西可复制了。
  Future<ExportResult> sharePdf(
    Uint8List pdf, {
    required String fileName,
    required String text,
  });
}

/// 当前平台可用的导出实现。
ReviewExporter createReviewExporter() => createPlatformExporter();
