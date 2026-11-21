import 'dart:io';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/shared/profile_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';

/// 「朗读设置」的**入口**在个人资料页，不在讲解页。
///
/// 为什么这条要单独一个文件、还要起真库：入口本身是一个
/// `TtsSettingsTile`，它能渲染、能弹面板，**都不代表资料页真的用了它**。
/// [B38] 那次栽的就是这个 —— 机制建好了、也有测试，但调用点一处没接上，
/// 界面上什么都不会发生。所以判据必须从**资料页**点进去。
///
/// 测试进程里没有 Android，真正的音色枚举走不到；这里只验
/// 「入口存在 + 点开能说话」，音色列表本身仍由 `tts_settings_test.dart`
/// 用 mock 通道锁住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const catalogName = 'cn.easylearn.app/tts-catalog';
  const speechName = 'cn.easylearn.app/tts';

  Directory? tempDir;

  setUpAll(() async {
    // 库在整个文件期间保持打开：`ProfilePage.initState` 会拉档案与积分，
    // 每例关库会让这些未 await 的加载撞上 `database_closed`。
    tempDir = await setUpTestDatabase();
  });

  tearDownAll(() async {
    final dir = tempDir;
    if (dir != null) await tearDownTestDatabase(dir);
  });

  setUp(() {
    Get.testMode = true;
    Get.put(AuthController()).currentUser.value = UserModel(
      id: 'stu_001',
      name: '小明',
      phone: '13800000001',
      role: 'student',
      avatar: '',
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(catalogName), (
          call,
        ) async {
          switch (call.method) {
            case 'status':
              return <String, Object?>{
                'ready': true,
                'engine': '',
                'voice': 'zh-cn-x-ccc-local',
                'rate': 0.95,
              };
            case 'engines':
              return <Object?>[
                <String, Object?>{
                  'name': 'com.google.android.tts',
                  'label': 'Google 语音服务',
                  'isDefault': true,
                },
              ];
            case 'voices':
              return <Object?>[
                <String, Object?>{
                  'name': 'zh-cn-x-ccc-local',
                  'quality': 400,
                  'network': false,
                  'locale': 'zh_CN',
                },
              ];
            default:
              return null;
          }
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(speechName),
          (call) async => null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(catalogName), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(speechName), null);
    Get.reset();
  });

  testWidgets('个人资料页上有「朗读设置」，点开就是朗读面板', (tester) async {
    // 资料页正文是长表单，朗读设置排在账号与安全前面 —— 视口太矮会
    // 压根不构建它（`ListView` 懒构建），滚过去才看得见。
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: ProfilePage()));
    await tester.pumpAndSettle();

    final entry = find.text('朗读设置');
    await tester.scrollUntilVisible(
      entry,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(entry, findsOneWidget, reason: '朗读设置的入口应该在个人资料里');
    expect(find.textContaining('设一次就记住'), findsOneWidget);

    await tester.tap(entry);
    await tester.pumpAndSettle();

    // 打开的是同一块面板：引擎真的列出来了，不是转圈或空壳。
    expect(find.text('语音引擎'), findsOneWidget);
    expect(find.text('Google 语音服务'), findsOneWidget);

    // sqflite 的事务锁会挂一颗 10 秒的定时器，`pumpAndSettle` 不推进假时钟；
    // 放着不管会在收尾时报「A Timer is still pending」，那条跟被测行为无关。
    await tester.pump(const Duration(seconds: 11));
  });
}
