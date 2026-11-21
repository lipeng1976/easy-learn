import 'dart:io';

import 'package:easy_learn_app/constants/attachment_limits.dart';
import 'package:flutter_test/flutter_test.dart';

/// 附件上限的**双端对齐**判据。
///
/// ## 为什么要这个文件
///
/// 这组数字活在两份定义（`attachment_limits.dart` 与服务端
/// `attachments.js` 的 `DEFAULT_MAX_BYTES`）和**两个手抄副本**
/// （本文件的 `_EXPECTED_MB` 与服务端 `attachments.test.js` 的
/// `EXPECTED_MAX_BYTES`）里。任何一处单方面改动都会造成同一种静默失败：
/// 客户端拦的口子与服务端校验的口子不一样 —— 要么「界面上能选、
/// 提交时被服务端拒」（客户端小、服务端大），要么「绕过客户端
/// 能塞进一个配额根本装不下的文件」（客户端大、服务端小）。
///
/// Dart 与 JS 没法共享常量，所以这里用**读服务端源文件**的方式把两边
/// 钉在一起：本文件的手抄值变了而源文件没跟上（或反过来），立刻红。
void main() {
  // 手抄产品口径。改它必须是有意识的决定 —— 改了下面的对齐断言
  // 就会替你核对服务端那份跟没跟上。
  const int expectedVideoMB = 100;
  const int expectedImageMB = 8;
  const int expectedAudioMB = 20;

  test('Dart 侧上限 = 手抄产品口径', () {
    expect(
      AttachmentLimits.maxBytesOf(AttachmentKind.image),
      expectedImageMB * 1024 * 1024,
    );
    expect(
      AttachmentLimits.maxBytesOf(AttachmentKind.audio),
      expectedAudioMB * 1024 * 1024,
    );
    expect(
      AttachmentLimits.maxBytesOf(AttachmentKind.video),
      expectedVideoMB * 1024 * 1024,
      reason: '2026-10-06 由 50MB 放宽：50MB 配 5 分钟直传超时要求 '
          '有效上行 ≥170KB/s，弱网下必挂（见 doc/open-items.md B35）',
    );
  });

  test('服务端 attachments.js 的 DEFAULT_MAX_BYTES 与 Dart 侧逐字节相同', () {
    final source = File(
      'serverless/data-service/src/attachments.js',
    ).readAsStringSync();

    // 从源文件里抽出每个类型的字面量（`['video', 100 * 1024 * 1024],`）。
    // 不 import、不 eval —— 读源码就是判据本身，改了字面量就躲不过。
    int? serverMB(String kind) {
      final match = RegExp(
        "\\['$kind',\\s*(\\d+) \\* 1024 \\* 1024\\]",
      ).firstMatch(source);
      if (match == null) return null;
      return int.parse(match.group(1)!);
    }

    expect(serverMB('image'), expectedImageMB,
        reason: '服务端 image 上限没跟上（attachments.js 的 DEFAULT_MAX_BYTES）');
    expect(serverMB('audio'), expectedAudioMB,
        reason: '服务端 audio 上限没跟上（attachments.js 的 DEFAULT_MAX_BYTES）');
    expect(serverMB('video'), expectedVideoMB,
        reason: '服务端 video 上限没跟上（attachments.js 的 DEFAULT_MAX_BYTES）'
            '—— 客户端拦 100MB、服务端拦 50MB 的表现是「选得进、传上去、存不下」');
  });

  test('MAX_COUNT 也对齐（服务端 MAX_COUNT 是防呆口径）', () {
    final source = File(
      'serverless/data-service/src/attachments.js',
    ).readAsStringSync();

    int? serverCount(String kind) {
      final match = RegExp("\\['$kind',\\s*(\\d+)\\],").firstMatch(source);
      if (match == null) return null;
      return int.parse(match.group(1)!);
    }

    // MAX_COUNT 段在 DEFAULT_MAX_BYTES 之后；上面那条 video 的正则会先
    // 命中上限表，所以这里逐个对计数表再抽一次 —— 数量上限漂了同样
    // 是「界面能选 N 张、服务端只收 M 张」的静默失败。
    expect(serverCount('image'), AttachmentLimits.maxCountOf(AttachmentKind.image));
    expect(serverCount('audio'), AttachmentLimits.maxCountOf(AttachmentKind.audio));
    expect(serverCount('video'), AttachmentLimits.maxCountOf(AttachmentKind.video));
  });
}
