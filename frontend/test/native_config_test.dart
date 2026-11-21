import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 原生工程配置的护栏测试。
///
/// 为什么需要它：AndroidManifest.xml 与 Info.plist 是**平台配置**，
/// 少了关键条目时 Dart 编译完全正常、`flutter analyze` 也零问题、
/// 单元测试全绿 —— 只有在真机上才会以「AI 全离线」或「一拍照就闪退」
/// 的形式暴露，而那时人已经在手机前面，排查成本极高。
/// 这两类条目还特别容易在 `flutter create` 重建工程、合并冲突时被悄悄回退。
///
/// 这里只断言「必需的在不在了」，不追求解析完整 XML —— 
/// 靠字符串匹配足够抓住回退，且不引入新依赖。
void main() {
  group('Android 原生配置', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml');

    test('main 变体存在（而不是只有 debug / profile）', () {
      expect(
        manifest.existsSync(),
        isTrue,
        reason: '找不到 ${manifest.path}，工程结构可能被重建过',
      );
    });

    test('release 包带 INTERNET 权限', () {
      final source = manifest.readAsStringSync();
      expect(
        source.contains('android.permission.INTERNET'),
        isTrue,
        reason:
            'INTERNET 必须写在 main 变体里。Flutter 模板只把它放进 debug / profile '
            '（那是给 hot reload 用的），所以漏掉时 release 包一条联网权限都没有，'
            '而症状不会说「缺权限」，只会表现成「AI 全部离线」。',
      );
    });

    test('不声明 CAMERA 权限（image_picker 不需要，声明了反而有害）', () {
      final source = manifest.readAsStringSync();
      expect(
        source.contains('android.permission.CAMERA'),
        isFalse,
        reason:
            'image_picker 走系统的 ACTION_IMAGE_CAPTURE，Android 侧是零配置。'
            '一旦声明了 CAMERA，这条路径就开始走权限检查：没做运行时申请的话，'
            '拍照会在原生层抛 SecurityException。若真为别的功能加了它，'
            '必须同时做运行时申请，并删掉这条断言。',
      );
    });
  });

  group('iOS 原生配置', () {
    final plist = File('ios/Runner/Info.plist');

    test('Info.plist 存在', () {
      expect(
        plist.existsSync(),
        isTrue,
        reason: '找不到 ${plist.path}，工程结构可能被重建过',
      );
    });

    test('相机与相册的用途说明都在', () {
      final source = plist.readAsStringSync();
      // 缺这两个 key 时 iOS 不是抛 Dart 异常，而是在原生层直接终止进程（闪退），
      // 所以 Flutter 侧抓不到任何报错栈，最难排查。
      expect(
        source.contains('NSCameraUsageDescription'),
        isTrue,
        reason: '缺 NSCameraUsageDescription：一调用相机就闪退。',
      );
      expect(
        source.contains('NSPhotoLibraryUsageDescription'),
        isTrue,
        reason: '缺 NSPhotoLibraryUsageDescription：从相册选图就闪退。',
      );
    });

    test('文案不是空串（空串会被 App Store 拒）', () {
      final source = plist.readAsStringSync();
      for (final key in const [
        'NSCameraUsageDescription',
        'NSPhotoLibraryUsageDescription',
      ]) {
        final index = source.indexOf(key);
        if (index < 0) continue; // 上一条断言负责报缺失
        final after = source.substring(index);
        final match = RegExp(r'<string>(.*?)</string>', dotAll: true)
            .firstMatch(after);
        expect(
          match?.group(1)?.trim().isNotEmpty,
          isTrue,
          reason: '$key 的说明不能为空 —— 系统弹窗会把它原样显示给家长。',
        );
      }
    });
  });
}
