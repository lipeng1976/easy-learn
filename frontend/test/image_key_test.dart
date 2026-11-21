import 'dart:io';

import 'package:easy_learn_app/services/image_key.dart';
import 'package:flutter_test/flutter_test.dart';

/// 照片键形态的**跨栈对照**。
///
/// ## 为什么这条测试必须存在
///
/// `storageKey` 有两种形态，客户端靠它决定「走网络」还是「读本地」。
/// 两边判反的代价是：**症状完全相同**（照片位置一片空白、没有任何报错），
/// 但处置完全相反 —— 该回退本地读的（改动之前写进库的旧数据）
/// 若被当成服务端键去请求，那些照片就永远看不到了。
///
/// 服务端的权威定义在 `serverless/data-service/src/imagestore.js`，
/// 客户端那份在 `lib/services/image_key.dart`。两份必须给出同一个判断，
/// 所以这里不只跑样本 —— 还**直接读服务端源文件**，把它的正则抠出来
/// 在 Dart 里再跑一遍同样的样本。服务端改了规则，这条会当场红，
/// 而不是等某天在手机上发现「有几张老照片突然看不见了」。
void main() {
  /// 与服务端 `test/images.test.js` **同一组样本**。
  /// 两边用同一组值，是为了让「一侧改了规则」立刻表现为一次对照失败。
  const samples = <String>[
    // 服务端相对键（日期 / 学生 / 文件）
    '20260920/36e392cd-ab12/f3a1c2d4.jpg',
    '20260101/abc/9f.webp',
    // 旧的设备本地标识三种写法
    'memory://students/x/homework/img_1.jpg',
    '/data/user/0/com.x/files/img.jpg',
    r'C:\Users\me\Documents\img.jpg',
    // `..` 段：正则匹得到，必须靠段级收口挡掉
    '20260920/abc/..',
    '20260920/../../etc/passwd',
    // 空
    '',
  ];

  group('isServerImageKey', () {
    test('认服务端相对键', () {
      expect(isServerImageKey('20260920/36e392cd-ab12/f3a1c2d4.jpg'), isTrue);
    });

    test('不认旧的设备本地标识（它们只能回退本地读）', () {
      expect(isServerImageKey('memory://students/x/homework/img_1.jpg'), isFalse);
      expect(isServerImageKey('/data/user/0/com.x/files/img.jpg'), isFalse);
      expect(isServerImageKey(r'C:\Users\me\Documents\img.jpg'), isFalse);
    });

    test('挡掉 .. 段', () {
      expect(isServerImageKey('20260920/abc/..'), isFalse);
      expect(isServerImageKey('20260920/../../etc/passwd'), isFalse);
    });

    test('空键不是服务端键', () {
      expect(isServerImageKey(''), isFalse);
    });
  });

  test('跨栈对照：服务端 imagestore.js 的正则与客户端判断逐样本一致', () {
    final file = File('serverless/data-service/src/imagestore.js');
    expect(
      file.existsSync(),
      isTrue,
      reason: '读不到服务端 imagestore.js —— 这个测试的路径假设变了',
    );
    final source = file.readAsStringSync();

    // 抠出 `const SERVER_KEY_PATTERN = /…/;` 里的正则本体。
    final match = RegExp(r'const SERVER_KEY_PATTERN = /(.+)/;').firstMatch(source);
    expect(
      match,
      isNotNull,
      reason: '在 imagestore.js 里找不到 SERVER_KEY_PATTERN —— '
          '若它被改名或换写法，请同步更新这条测试的提取方式（而不是删掉它）',
    );
    final serverPattern = RegExp(match!.group(1)!);

    for (final sample in samples) {
      // 服务端的判断 = 正则 + 「任何一段是 . 或 .. 就不算」那次段级收口。
      // 两步都要照着做，否则对照本身就不等价于服务端的行为。
      final serverSays = serverPattern.hasMatch(sample) &&
          !sample.split('/').any((seg) => seg == '.' || seg == '..');
      expect(
        isServerImageKey(sample),
        serverSays,
        reason: '样本 `$sample` 两侧判断不一致：'
            '客户端说 ${isServerImageKey(sample)}，服务端正则说 $serverSays',
      );
    }
  });
}
