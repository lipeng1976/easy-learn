import 'dart:js_interop';

import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

import 'review_exporter.dart';

ReviewExporter createPlatformExporter() => const _WebExporter();

/// PDF 的 MIME 类型。下载与分享都要用它，写两份迟早会不一致。
const String _pdfMime = 'application/pdf';

/// Web 端的三种去向。
///
/// 与移动端有一处刻意的不同：**打印用的是 HTML，不是 PDF**。
/// 浏览器打印 HTML 是原生排版（分页、字体、断行都由浏览器算），
/// 比「把 PDF 塞给浏览器打印」质量更好；而移动端没有这条通道，
/// 只能走系统打印服务。所以接口同时收两份产物，各取所长。
class _WebExporter implements ReviewExporter {
  const _WebExporter();

  /// 打印用的隐藏 iframe。复用同一个实例：每次导出都新建会不断往 DOM 里堆节点。
  static web.HTMLIFrameElement? _frame;

  @override
  Future<ExportResult> printPaper({
    required Uint8List pdf,
    required String html,
    required String fileName,
  }) async {
    try {
      final frame = _ensureFrame();
      final document = frame.contentDocument;
      final window = frame.contentWindow;
      if (document == null || window == null) {
        return const ExportResult(
          ok: false,
          message: '浏览器拒绝了打印页创建，可改用「保存 PDF」。',
        );
      }

      document.open();
      document.write(html.toJS);
      document.close();

      // 等样式与字体树应用完再唤起打印，否则可能印出未排版的版本。
      await Future<void>.delayed(const Duration(milliseconds: 260));
      window.focus();
      window.print();

      return const ExportResult(
        ok: true,
        message: '已唤起打印，可直接打印或「另存为 PDF」。',
      );
    } catch (error) {
      return ExportResult(ok: false, message: '导出打印页失败：$error');
    }
  }

  @override
  Future<ExportResult> savePdf(
    Uint8List pdf, {
    required String fileName,
  }) async {
    try {
      _triggerDownload(pdf, fileName, _pdfMime);
      return ExportResult(
        ok: true,
        message: '已开始下载 $fileName —— 这是一份 PDF，能直接打印或转发。',
      );
    } catch (error) {
      return ExportResult(ok: false, message: '下载失败：$error');
    }
  }

  @override
  Future<ExportResult> sharePdf(
    Uint8List pdf, {
    required String fileName,
    required String text,
  }) async {
    final navigator = web.window.navigator;

    // 一档：把 PDF 文件本身分享出去 —— 对方收到的是能直接打开打印的卷子。
    try {
      final file = web.File(
        <JSAny>[pdf.toJS].toJS,
        fileName,
        web.FilePropertyBag(type: _pdfMime),
      );
      final payload = web.ShareData(
        files: <web.File>[file].toJS,
        title: fileName,
        text: text,
      );
      // canShare 是必须的：桌面浏览器大多不支持分享文件，
      // 直接调 share 会抛 DataError，用户看到的是「分享失败」而不是「换个方式」。
      if (navigator.canShare(payload)) {
        await navigator.share(payload).toDart;
        return const ExportResult(ok: true, message: '已打开分享面板，选「微信」即可发送。');
      }
    } catch (error) {
      if (_isAbort(error)) return const ExportResult(ok: false, message: '已取消转发。');
    }

    // 二档：纯文本分享。
    try {
      final payload = web.ShareData(title: fileName, text: text);
      if (navigator.canShare(payload)) {
        await navigator.share(payload).toDart;
        return const ExportResult(ok: true, message: '已打开分享面板，选「微信」即可发送。');
      }
    } catch (error) {
      if (_isAbort(error)) return const ExportResult(ok: false, message: '已取消转发。');
    }

    // 三档：复制。走到这里说明这个环境压根没有分享能力，不是出错。
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (error) {
      return ExportResult(
        ok: false,
        message: '当前浏览器不支持分享，复制也没能成功（$error）。可改用「保存 PDF」。',
      );
    }
    return const ExportResult(
      ok: true,
      copiedToClipboard: true,
      message: '当前浏览器不支持直接分享，卷子内容已复制 —— 粘贴到微信发送即可。',
    );
  }

  void _triggerDownload(Uint8List bytes, String fileName, String mime) {
    final blob = web.Blob(
      <JSAny>[bytes.toJS].toJS,
      web.BlobPropertyBag(type: mime),
    );
    final url = web.URL.createObjectURL(blob);
    final anchor = web.document.createElement('a') as web.HTMLAnchorElement
      ..href = url
      ..download = fileName;
    // 必须先挂进文档再点：游离节点上的 click 在部分浏览器里不触发下载。
    web.document.body?.appendChild(anchor);
    anchor.click();
    anchor.remove();
    // 立即 revoke 会把正在进行的下载掐掉，延后回收。
    Future<void>.delayed(
      const Duration(seconds: 30),
      () => web.URL.revokeObjectURL(url),
    );
  }

  /// 用户在分享面板上点「取消」时，`share()` 抛 AbortError。
  /// 那不是故障，不能报成失败 —— 但也不能算成功。
  bool _isAbort(Object error) => error.toString().toLowerCase().contains('abort');

  web.HTMLIFrameElement _ensureFrame() {
    final existing = _frame;
    if (existing != null && existing.isConnected == true) return existing;

    final frame =
        web.document.createElement('iframe') as web.HTMLIFrameElement;
    frame.style
      ..border = 'none'
      ..position = 'fixed'
      ..right = '0'
      ..bottom = '0'
      ..width = '0'
      ..height = '0';
    frame.setAttribute('aria-hidden', 'true');
    web.document.body?.appendChild(frame);
    _frame = frame;
    return frame;
  }
}
