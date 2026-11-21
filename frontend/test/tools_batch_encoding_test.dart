import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Windows 批处理文件的**编码判据**（2026-10-06）。
///
/// ## 为什么单独立一条
///
/// `tools/run-tests-outside-workbuddy.cmd` 是留给「WorkBuddy 沙箱钩子
/// （`CreateFile failed 231`）拦死 flutter 工具链」时用的。它 10-03 写出来，
/// 但**从没真被 cmd 执行过**（我跑不了、也没验过），10-06 一跑就炸：
///
/// ```
/// 'ot:' 不是内部或外部命令
/// 'onst{spawnSync}' 不是内部或外部命令
/// ```
///
/// `const{spawnSync}` 被从中间切开、`c` 不见了 —— 这是根因的签名：
/// cmd.exe 按**原始字节流**解析 .cmd，两件事会让它错位：
///
/// 1. **LF-only 换行**：cmd 丢失读取位置，相邻行会并到一起；
/// 2. **非 ASCII 字节**：UTF-8 中文在控制台 ANSI 代码页（中文 Windows 是
///    936/GBK）下被重新分组，双字节对不齐时会**吃掉后面的 CR/LF**，
///    把下一行并进当前行 —— 于是 `const...` 变成 `onst...` 被执行。
///    更糟的是乱码可能吐出 `&` `|` `>`，那就不只是报错，是**执行别的东西**。
///
/// 同期写的 `tools/build-apk-outside-workbuddy.cmd` 恰好是 CRLF + 纯 ASCII，
/// 所以它是好的 —— 两个文件、两种写法、一个能跑一个炸，对照很干净。
///
/// 规矩因此是硬的：**批处理文件必须纯 ASCII + CRLF**（顺带也排掉 BOM，
/// BOM 字节 > 127，同样被 cmd 误读成命令名的一部分）。
/// 这条约束以前只躺在注释里，而「没有测试盯着的约定，早晚会漂」。
void main() {
  final batchFiles =
      [
            Directory('tools'),
            Directory('.'), // 仓库根目录，防止以后有人往这儿丢一个
          ]
          .expand((dir) => dir.listSync())
          .whereType<File>()
          .where((f) {
            final lower = f.path.toLowerCase();
            return lower.endsWith('.cmd') || lower.endsWith('.bat');
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('扫到了批处理文件（否则下面两条是在空跑）', () {
    expect(
      batchFiles,
      isNotEmpty,
      reason: '一个 .cmd / .bat 都没扫到 —— 那两条断言等于没测（B33 的教训）',
    );
  });

  test('批处理文件是纯 ASCII（非 ASCII 会被 cmd 按 ANSI 代码页误读）', () {
    for (final file in batchFiles) {
      final bytes = file.readAsBytesSync();
      final offenders = <String>[];
      for (var i = 0; i < bytes.length && offenders.length < 6; i++) {
        if (bytes[i] > 127) {
          offenders.add('0x${bytes[i].toRadixString(16)}@offset$i');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '${file.path} 含非 ASCII 字节（${offenders.join('、')}）。'
            'cmd 会按 ANSI 代码页重分组这些字节，可能吃掉换行、甚至拼出 & | >',
      );
    }
  });

  test('批处理文件是 CRLF（LF-only 会让 cmd 丢位置、把行并起来）', () {
    for (final file in batchFiles) {
      final bytes = file.readAsBytesSync();
      var cr = 0;
      var lf = 0;
      for (final b in bytes) {
        if (b == 13) {
          cr++;
        } else if (b == 10) {
          lf++;
        }
      }
      expect(lf, greaterThan(0), reason: '${file.path} 没有任何换行符？');
      expect(
        cr,
        lf,
        reason: '${file.path}: CR=$cr / LF=$lf。LF-only 的 .cmd 在 cmd.exe 里会'
            '错位 —— 2026-10-06 曾把 `const{spawnSync}` 切成 `onst{spawnSync}`',
      );
    }
  });
}
