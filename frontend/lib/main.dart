import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'app.dart';
import 'controllers/auth_controller.dart';
import 'models/user_model.dart';
import 'services/cloud_runtime.dart';
import 'services/credential_store.dart';
import 'services/database_service.dart';

Future<void> main() async {
  // 装配要在 `runApp` **之前**完成，理由有二：
  //
  // 1. 读一次落盘的会话是异步的（原生端要读文件），而「有没有登录」决定了
  //    首屏是登录页还是首页 —— 放在 `runApp` 之后，用户会先看到登录页闪一下；
  // 2. `AuthService` 在构造时就要拿到云端端点，而它是随 `AuthController`
  //    一起在 `app.dart` 的 `build()` 里建的。
  //
  // 没配 `DATA_API_BASE_URL` 时这一切是空操作，行为与上云之前一样。
  WidgetsFlutterBinding.ensureInitialized();

  // ⚠️ **第 3 件事，2026-10-06 补（B37）**：把「上次登录的手机号 / 记住的密码」
  //    也在这之前读出来。它与上面两条是**同一条规矩** —— 首屏要用到的东西，
  //    异步载入必须发生在 `runApp` 之前。
  //
  //    以前它读的是一份只在 Web 有实现的 `webStorage`，安卓上落到 stub
  //    （`read => null`），于是「记住密码」在手机上永远失效、且零报错。
  //    放到 `runApp` 之后（比如在登录页里 await）会得到另一种坏形态：
  //    密码框先空后闪一下填上 —— 那比原来更难查，因为它时好时坏。
  await credentialStore.initialize();

  final runtime = CloudRuntime.fromEnvironment();
  if (runtime != null) {
    // 载入读缓存 + 恢复会话，顺序由 `initialize()` 内部保证。
    await runtime.initialize();
    DatabaseService.useCloudRuntime(runtime);
  }

  // ⚠️ **在 `runApp` 之前把 AuthController 建好并载入凭证**，而不是留给
  //    `app.dart` 的 `build()` —— `build()` 是同步的，没有 await 的位置；
  //    在那里起一个 fire-and-forget 的载入，登录页就会在它完成前 `initState`
  //    （「密码框偶尔是空的」，比原来更难查）。
  //
  //    `app.dart` 会复用这里注册的实例（它判 `Get.isRegistered`），
  //    所以登录页拿到的 `savedPhone` / `savedPassword` 一定是已经载好的。
  final restored = _restoredUser(runtime);
  final auth = AuthController(initialUser: restored);
  await auth.hydrate();
  Get.put(auth);

  runApp(const EasyLearnApp());
}

/// 冷启动时把落盘的会话接回来（云端模式）；纯本地模式返回 null。
///
/// 从 `app.dart` 的 `build()` 里挪出来（2026-10-06）：那边现在是「复用
/// `main` 建好的那个」，而**谁建谁负责载入** —— 拆成两处会让
/// 「有没有 hydrate」变成看运气的事。
///
/// ⚠️ 判断条件与原来那份**逐字一致**（含 `isAuthenticated`）：漏掉它会把
/// 一个「有 user 但 token 已失效」的会话当成有效登录，首屏直接进首页、
/// 然后每个请求 401 —— 这正是 `SessionStore.isAuthenticated` 存在的理由。
UserModel? _restoredUser(CloudRuntime? runtime) {
  final session = DatabaseService.cloud?.api.session;
  final user = session?.user;
  if (session == null || user == null || !session.isAuthenticated) return null;
  return UserModel.fromJson(user);
}
