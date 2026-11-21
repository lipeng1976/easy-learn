import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import 'review_exporter.dart';

ReviewExporter createPlatformExporter() => const _IoExporter();

/// 桌面 / 移动端导出。
///
/// ── 2026-10-21 改版：从「写个 HTML 到私有目录」改成「真的交一份 PDF」──
///
/// 旧实现只能 `File.writeAsString(html)` 到应用私有目录，然后报一串路径。
/// 那个目录在 Android 上是 `/data/user/0/<包名>/app_flutter/…`，
/// **用户既看不到也进不去** —— 于是「导出」这个动作等于什么都没发生，
/// 界面上那句「已保存到：…」反而让人以为文件丢了。
///
/// 现在三条路都落到系统能力上：
///   · 打印 → `Printing.layoutPdf` 走 Android 打印服务（里面能选「另存为 PDF」）
///   · 保存 → `FilePicker.saveFile` 弹**系统另存为**，位置由用户自己挑
///   · 转发 → `Printing.sharePdf` 调系统分享面板（微信、QQ、邮件都在里面）
///
/// ⚠️ 三条路都要如实回报「用户取消」：取消不是成功。
///    卷子状态里的「已导出」只在真的交出去之后才写（见 `exportPaper`）。
class _IoExporter implements ReviewExporter {
  const _IoExporter();

  @override
  Future<ExportResult> printPaper({
    required Uint8List pdf,
    required String html,
    required String fileName,
  }) async {
    try {
      // `layoutPdf` 在用户选完打印机（或取消）之后才返回。
      final handled = await Printing.layoutPdf(
        name: fileName,
        onLayout: (PdfPageFormat format) async => pdf,
      );
      if (!handled) {
        return const ExportResult(ok: false, message: '已取消打印。');
      }
      return const ExportResult(
        ok: true,
        message: '已交给系统打印，可以在里面选打印机，或「另存为 PDF」。',
      );
    } catch (error) {
      // 没有打印服务（部分精简 ROM）时不要报「已打印」。
      // 给一条能走通的替代路径，而不是让学生对着一个失败提示发呆。
      return ExportResult(
        ok: false,
        message: '这台设备没有可用的打印服务，可以改用「保存 PDF」或「转发」。'
            '（$error）',
      );
    }
  }

  @override
  Future<ExportResult> savePdf(
    Uint8List pdf, {
    required String fileName,
  }) async {
    try {
      // file_picker 13 起是静态方法、且返回 `Uri?`（不是路径字符串）：
      // Android 走 SAF，拿到的是 `content://` URI —— 用户选的目录可能是
      // 云盘或 U 盘，本来就没有 `file://` 路径。
      final uri = await FilePicker.saveFile(
        dialogTitle: '保存试卷 PDF',
        fileName: fileName,
        bytes: pdf,
        mimeType: 'application/pdf',
      );
      if (uri == null) {
        return const ExportResult(ok: false, message: '已取消保存。');
      }
      // 位置是用户刚刚自己选的，报出来有意义（他能照着找到）。
      final shown = uri.path.isNotEmpty ? uri.path : uri.toString();
      return ExportResult(ok: true, path: shown, message: '已保存到：$shown');
    } catch (error) {
      // 极少数设备没有系统文件选择器。退回到应用目录，但**必须说清楚**
      // 这个位置不好找 —— 假装存到了「下载」里更坏。
      final fallback = await _writeToAppDir(pdf, fileName);
      if (fallback == null) {
        return ExportResult(ok: false, message: '保存失败：$error');
      }
      return ExportResult(
        ok: true,
        path: fallback,
        message: '系统文件选择器不可用，已存到应用目录：$fallback',
      );
    }
  }

  @override
  Future<ExportResult> sharePdf(
    Uint8List pdf, {
    required String fileName,
    required String text,
  }) async {
    try {
      await Printing.sharePdf(bytes: pdf, filename: fileName);
      return const ExportResult(
        ok: true,
        message: '已打开系统分享面板，选「微信」即可发送 PDF。',
      );
    } catch (error) {
      // 分享面板不可用（或被取消）时退回复制文本。复制是确定能用的能力，
      // 粘到微信里一样能把题目发出去。
      try {
        await Clipboard.setData(ClipboardData(text: text));
      } catch (_) {
        return ExportResult(
          ok: false,
          message: '分享失败，复制也没成功。可以改用「保存 PDF」。（$error）',
        );
      }
      return const ExportResult(
        ok: true,
        copiedToClipboard: true,
        message: '系统分享面板不可用，卷子内容已复制 —— 粘贴到微信发送即可。',
      );
    }
  }

  Future<String?> _writeToAppDir(Uint8List pdf, String fileName) async {
    try {
      final documents = await getApplicationDocumentsDirectory();
      final directory = Directory(p.join(documents.path, 'review_papers'));
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      final file = File(p.join(directory.path, fileName));
      await file.writeAsBytes(pdf, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }
}
