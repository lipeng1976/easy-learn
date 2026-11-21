import 'dart:convert';
import 'dart:io';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/models/login_method.dart';
import 'package:easy_learn_app/services/credential_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';

/// 「记住密码 / 上次登录的手机号」。
///
/// ## 为什么会有这个文件（2026-10-06，B37）
///
/// 这个功能在**安卓上从来没生效过**，而且零报错 —— 它读写的 `webStorage`
/// 只有 Web 有真实实现：移动端落到 `web_storage_stub.dart`，那份是
/// `read => null` / `write => true`（**写假装成功、读恒为空**）。
///
/// 它能坏这么久，直接原因是**这里一条判据都没有**：
/// `savedPassword` / `savedPhone` / `rememberMe` 在全仓测试里零覆盖。
/// 所以这个文件的第一要务不是「测功能」，是**让这类失效无法再安静地发生**。
///
/// ## 判据刻意写成「跨实例」
///
/// 同一个 store 实例有内存缓存，于是「写进去读得回来」在**恒空的 stub 上
/// 也可能通过**（`write` 返回 true、值进内存）。所以这里每次都**新建一个
/// 实例再读** —— 只有真落了盘才过得去。这是原 bug 的机制签名，
/// 而不是一个泛泛的冒烟测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  Directory? tempDir;

  setUp(() async {
    tempDir = await createIsolatedTestDir('easy_learn_cred_');
    // 与本应用一致：path_provider 指向临时目录，
    // 于是凭证文件落在 `<temp>/easy_learn/credentials*.{json,key}`。
    pointPathProviderTo(tempDir!);
  });

  tearDown(() async {
    Get.reset();
    try {
      if (tempDir != null && tempDir!.existsSync()) {
        tempDir!.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  /// 每次都新建：绕开内存缓存，逼着走一遍落盘。
  Future<CredentialStore> freshStore() async {
    final store = createCredentialStore();
    await store.initialize();
    return store;
  }

  group('CredentialStore 真的落盘（跨实例可读）', () {
    test('明文键与密文键，换一个实例都能读回来', () async {
      final first = await freshStore();
      await first.write('plain_key', 'value-1');
      await first.write('secret_key', 'p@ssw0rd', secret: true);

      final second = await freshStore();
      expect(second.read('plain_key'), 'value-1');
      expect(
        await second.readSecret('secret_key'),
        'p@ssw0rd',
        reason: '⭐ 密文键必须能解密回来 —— 这是本次修复的核心判据',
      );
    });

    test('口令不以明文形式出现在盘上', () async {
      final store = await freshStore();
      await store.write('secret_key', 'MySecret123', secret: true);

      final files = tempDir!
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.contains('credentials'))
          .toList();
      expect(files, isNotEmpty, reason: '必须真落了盘，否则这个判据是空转的');

      for (final file in files) {
        expect(
          file.readAsStringSync().contains('MySecret123'),
          isFalse,
          reason: '${file.path} 里出现了明文口令',
        );
      }
    });

    test('密文被篡改 ⇒ 解不出来（而不是返回乱码口令）', () async {
      final store = await freshStore();
      await store.write('secret_key', 'OriginalPwd', secret: true);

      final file = tempDir!
          .listSync(recursive: true)
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('credentials.json'));
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final bytes = base64Decode(data['secret_key'] as String);
      bytes[bytes.length - 1] ^= 0x01; // 翻最后一位（MAC 覆盖到了它）
      data['secret_key'] = base64Encode(bytes);
      file.writeAsStringSync(jsonEncode(data));

      final reopened = await freshStore();
      expect(
        await reopened.readSecret('secret_key'),
        isNull,
        reason: '篡改过的密文必须解不出来 —— 返回乱码会让用户看到「自动填了个错密码」',
      );
    });

    test('remove 之后跨实例读不到', () async {
      final store = await freshStore();
      await store.write('secret_key', 'pwd', secret: true);
      // ⚠️ 必须 await：`remove` 是异步落盘。不 await 就立刻新建实例去读，
      // 读到的是**还没删掉的旧值** —— 那条断言会偶发地红，
      // 而红的是竞态，不是「删不掉」。
      await store.remove('secret_key');

      final second = await freshStore();
      expect(second.read('secret_key'), isNull);
      expect(await second.readSecret('secret_key'), isNull);
    });
  });

  group('AuthController 启动时把凭证接回来（原 bug 的正面判据）', () {
    test('已存凭证 ⇒ hydrate 后手机号/密码/勾选都到位', () async {
      final seed = await freshStore();
      await seed.write(
        CredentialKeys.lastLogin,
        jsonEncode({'phone': '13800000009', 'role': 'parent', 'method': 'phone'}),
      );
      await seed.write(CredentialKeys.password, 'abc123', secret: true);

      // ⚠️ 必须显式注入一份**独立的** store，不能让它落到全局单例：
      // 那个单例带内存缓存与文件路径缓存，前一个测试写进去的值会渗进来，
      // 于是「没存过就该是空的」会红 —— 红的是测试自己脏了，不是功能坏了。
      final auth = AuthController(credentials: await freshStore());
      await auth.hydrate();

      expect(auth.savedPhone, '13800000009');
      expect(auth.savedRole, 'parent');
      expect(auth.savedMethod, LoginMethod.phone);
      expect(
        auth.savedPassword,
        'abc123',
        reason: '⭐ 修复前这一条**必然失败**（那时读到的恒是 null）',
      );
      expect(
        auth.rememberMe.value,
        isTrue,
        reason: '有存下来的口令 ⇒ 勾选框要自动勾上，否则用户会以为没记住',
      );
    });

    test('没存过 ⇒ 三个都是空的（不能凭空造出历史）', () async {
      // ⚠️ 必须显式注入一份**独立的** store，不能让它落到全局单例：
      // 那个单例带内存缓存与文件路径缓存，前一个测试写进去的值会渗进来，
      // 于是「没存过就该是空的」会红 —— 红的是测试自己脏了，不是功能坏了。
      final auth = AuthController(credentials: await freshStore());
      await auth.hydrate();

      expect(auth.savedPhone, '');
      expect(auth.savedPassword, '');
      expect(auth.rememberMe.value, isFalse);
      expect(auth.savedMethod, isNull, reason: '首次使用不该显示「上次使用：…」');
    });

    test('只存手机号（没勾记住密码）⇒ 手机号回填、密码仍空、不勾选', () async {
      final seed = await freshStore();
      await seed.write(
        CredentialKeys.lastLogin,
        jsonEncode({'phone': '13800000001', 'role': 'student', 'method': 'phone'}),
      );

      // ⚠️ 必须显式注入一份**独立的** store，不能让它落到全局单例：
      // 那个单例带内存缓存与文件路径缓存，前一个测试写进去的值会渗进来，
      // 于是「没存过就该是空的」会红 —— 红的是测试自己脏了，不是功能坏了。
      final auth = AuthController(credentials: await freshStore());
      await auth.hydrate();

      expect(auth.savedPhone, '13800000001');
      expect(auth.savedPassword, '');
      expect(
        auth.rememberMe.value,
        isFalse,
        reason: '没存口令就不能勾上 —— 勾了会让人以为密码已经填好了',
      );
    });
  });
}
