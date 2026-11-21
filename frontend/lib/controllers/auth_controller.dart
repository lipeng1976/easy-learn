import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../models/login_method.dart';
import '../models/user_model.dart';
import '../services/auth_service.dart';
import '../services/credential_store.dart';
import '../services/sms_gateway.dart';
// 退出登录时要清掉这两个控制器持有的账号级缓存，理由见
// `_resetAccountScopedState`。这两个 import 构成一个环
// （`notification_controller` 也要读 `AuthController` 拿当前用户），
// Dart 允许 import 环 —— 只要环里没有互相依赖的顶层 `const` 求值。
import 'notification_controller.dart';
import 'point_controller.dart';

class AuthController extends GetxController {
  AuthController({
    AuthService? authService,
    UserModel? initialUser,
    CredentialStore? credentials,
  }) : _authService = authService ?? AuthService(),
       _credentials = credentials ?? credentialStore {
    // 冷启动时把落盘的登录态接回来（见 `cloud_runtime.dart` 的 `restoreSession`）。
    //
    // 没有这一步，浏览器刷新一次就等于被登出 —— 而上云之后「刷新」会变成常态
    // （换个页面、切回来、点一下浏览器的刷新），用户会把每一次都当成掉线。
    if (initialUser != null) currentUser.value = initialUser;
  }

  final AuthService _authService;

  /// 凭证落盘处。默认是全局单例（`main` 里已 `initialize` 过）。
  ///
  /// ⚠️ **可注入不是为了好看，是为了判据能成立**：那个单例带内存缓存
  /// 与文件路径缓存（`_loaded` / `_file`），一个测试实例跑完留下的值会
  /// **渗进下一个测试**（换了临时目录它也不重读）。于是「没存过就该是空」
  /// 这条断言会红 —— 红的理由却是测试自己脏了，而不是功能坏了。
  /// 与 `authService` 同一个注入口，用法见 `test/remember_password_test.dart`。
  final CredentialStore _credentials;

  final Rx<UserModel?> currentUser = Rx<UserModel?>(null);
  final RxBool rememberMe = false.obs;
  final RxBool isLoading = false.obs;

  static const _kLastLoginKey = CredentialKeys.lastLogin;
  static const _kRememberKey = CredentialKeys.password;
  String _savedPhone = '';
  String _savedPassword = '';
  String _savedRole = 'student';
  LoginMethod? _savedMethod;

  String get savedPhone => _savedPhone;
  String get savedPassword => _savedPassword;
  String get savedRole => _savedRole;

  /// 上次用的登录方式。`null` = 还没有记录（首次使用）。
  ///
  /// **必须可空**：默认成「手机号密码」会让新用户第一次打开就看见
  /// 「上次使用：手机号密码」——一句不存在的事实。
  ///
  /// 它只是**展示用的偏好**，不能拿它决定按钮可用性：可用性归
  /// [isLoginMethodAvailable]（短信没接入时，那个入口仍然是关的）。
  LoginMethod? get savedMethod => _savedMethod;

  /// 短信是否已开通。**界面只认它**，不要自己判断环境或藏按钮。
  bool get smsEnabled => _authService.smsEnabled;

  /// 某个登录方式现在能不能用。
  ///
  /// 两个条件都要成立，缺一不可：
  /// 1. 方式本身已开通 —— 只有依赖短信网关的方式受这一条约束；
  /// 2. 账号侧具备条件（[UserModel.canUse]）—— 没有手机号就收不到码。
  ///
  /// 合成一个方法返回最终结论是刻意的：分开判断的地方迟早会漏掉一条，
  /// 而漏掉第 1 条的后果是「按钮能点、点了没反应」。
  bool isLoginMethodAvailable(LoginMethod method, {UserModel? account}) {
    if (method.requiresSmsGateway && !smsEnabled) return false;
    if (account == null) return true;
    return account.canUse(method);
  }

  void _safeSnackbar(String title, String message) {
    if (Get.overlayContext == null) return;
    try {
      Get.snackbar(title, message);
    } catch (_) {}
  }

  @override
  void onInit() {
    super.onInit();
    // ⚠️ **刻意不在这里读**：`onInit` 是同步的，而读密文口令是异步的
    // （`credentialStore.readSecret` 要先 decrypt）。在这里起一个
    // fire-and-forget 的 `_loadSavedCredentials()` 会得到一个**竞态**：
    // 登录页在它完成之前就 `initState` 了，于是「密码框偶尔是空的」——
    // 比现在这个 bug 更难查，因为它时好时坏。
    //
    // 载入由 [hydrate] 在 `main` 里 await（见 `main.dart`）。
    // 这里是「没 await 也要能用」的兜底：本地模式下没人调 hydrate，
    // 至少把明文那份（手机号）同步读出来。
    if (!_hydrated) _loadSavedCredentialsSync();
  }

  /// 是否已经完成异步载入（由 [hydrate] 置位）。
  bool _hydrated = false;

  /// 把落盘的凭证读进内存。**必须在首屏渲染之前 await**。
  ///
  /// 调用点在 `main.dart`，紧挨着 `CloudRuntime.initialize()` ——
  /// 两者是同一条规矩：异步读落盘 → 再 `runApp`，
  /// 否则用户会看到「先空一下、再填上」的闪烁（`main.dart` 注释里那段）。
  Future<void> hydrate() async {
    if (_hydrated) return;
    _hydrated = true;
    // 存储本身要先载入（移动端要读文件；Web 上是空操作）。
    try {
      await _credentials.initialize();
    } catch (_) {
      // 存储初始化失败不该拦住启动：下面的同步读会得到空值，
      // 用户重填一次而已。
    }
    await _loadSavedCredentials();
  }

  /// 同步的那一半（手机号 / 角色 / 登录方式）。
  ///
  /// 单独抽出来是因为 [onInit] 也可能在没 hydrate 的情况下被用到
  /// （测试、纯本地模式），那时至少把不加密的部分读出来。
  void _loadSavedCredentialsSync() {
    try {
      final lastRaw = _credentials.read(_kLastLoginKey);
      if (lastRaw != null && lastRaw.isNotEmpty) {
        final data = jsonDecode(lastRaw) as Map<String, dynamic>;
        _savedPhone = data['phone'] as String? ?? '';
        _savedRole = data['role'] as String? ?? 'student';
        // `tryParse` 认不出来时不动默认值。旧版本写的记录里没有 method 这个键，
        // 落到这里就是「保持手机号密码」——这正是那些记录当时的真实情况。
        _savedMethod =
            LoginMethod.tryParse(data['method'] as String?) ?? LoginMethod.phone;
      }
    } catch (_) {}
  }

  Future<void> _loadSavedCredentials() async {
    _loadSavedCredentialsSync();
    try {
      // 「记住密码」那份口令是**密文**（见 credential_store_io 的取舍说明）。
      // 解密失败返回 null —— 那是合法结局（换过密钥 / 文件损坏），
      // 此时当作「没记住」，而不是塞一个空串进去。
      final password = await _credentials.readSecret(_kRememberKey);
      if (password != null && password.isNotEmpty) {
        _savedPassword = password;
        rememberMe.value = true;
      }
    } catch (_) {}
  }

  void _saveLastLogin(String phone, String role, LoginMethod method) {
    try {
      _credentials.write(
        _kLastLoginKey,
        jsonEncode({
          'phone': phone,
          'role': role,
          // 存 `code` 而不是枚举序号：见 LoginMethod 的说明。
          'method': method.code,
        }),
      );
    } catch (_) {}
  }

  void _saveRememberPassword(String password) {
    try {
      // ⚠️ `secret: true` —— 口令必须**加密落盘**（见 credential_store.dart）。
      // 漏了这个参数不会报错，只会在设备上留一份明文。
      _credentials.write(_kRememberKey, password, secret: true);
    } catch (_) {}
  }

  Future<void> _clearRememberPassword() async {
    _savedPassword = '';
    try {
      await _credentials.remove(_kRememberKey);
    } catch (_) {}
  }

  Future<void> login(String phone, String password, String role) async {
    await _runAuth(
      () => _authService.loginByPhone(
        phone: phone.trim(),
        password: password,
        role: role,
      ),
      onSuccess: () {
        // 始终保存最后登录的手机号和角色
        _saveLastLogin(phone.trim(), role, LoginMethod.phone);
        // 仅勾选记住密码时保存密码
        if (rememberMe.value) {
          _saveRememberPassword(password);
        } else {
          _clearRememberPassword();
        }
      },
    );
  }

  Future<void> loginWithWechat(String role) async {
    await _runAuth(
      () => _authService.loginByWechat(role: role),
      // 微信登录没有手机号，**沿用已存的那个**而不是写成空串：
      // 否则用微信登过一次，之前填好的手机号就被抹掉了。
      onSuccess: () => _saveLastLogin(_savedPhone, role, LoginMethod.wechat),
    );
  }

  /// 验证码登录。**不需要传身份** —— 手机号唯一确定账号，
  /// 身份由账号自己决定。理由见 [AuthService.loginBySmsCode]。
  Future<void> loginBySmsCode(SmsVerification verification) async {
    await _runAuth(
      () => _authService.loginBySmsCode(verification: verification),
      onSuccess: () => _saveLastLogin(
        verification.phone.trim(),
        currentUser.value?.role ?? 'student',
        LoginMethod.smsCode,
      ),
    );
  }

  /// 通过短信验证码重置密码，成功后直接登录。
  ///
  /// 重置完要求用户再手动输一遍新密码是多余的：他刚刚用验证码证明了
  /// 「这个号是我的」，而且新密码正是他自己定的。
  Future<void> resetPasswordBySmsCode(
    SmsVerification verification,
    String newPassword,
  ) async {
    await _runAuth(
      () => _authService.resetPasswordBySmsCode(
        verification: verification,
        newPassword: newPassword,
      ),
      failureTitle: '重置失败',
      onSuccess: () {
        _saveLastLogin(
          verification.phone.trim(),
          currentUser.value?.role ?? 'student',
          LoginMethod.smsCode,
        );
        // 悄悄把「记住密码」里那份旧口令清掉：
        // 不清的话下次登录会自动填上**已经被换掉的那个密码**，
        // 用户看到的是一串对的密码和一个「不正确」的提示。
        _clearRememberPassword();
        rememberMe.value = false;
      },
    );
  }

  /// 请求发送验证码。**未接入时如实返回 unavailable，不伪造成功。**
  Future<SmsSendResult> sendSmsCode(
    String phone,
    SmsPurpose purpose,
  ) {
    return _authService.sendSmsCode(phone: phone, purpose: purpose);
  }

  /// 把验证码交给服务端校验，换回一次性凭证。
  ///
  /// 界面**不要**自己判断验证码对不对 —— 校验在服务端。
  /// 这里只做转交，失败以 [AuthException] 抛出。
  Future<SmsVerification> verifySmsCode({
    required String phone,
    required String code,
    required SmsPurpose purpose,
  }) {
    return _authService.verifySmsCode(
      phone: phone,
      code: code,
      purpose: purpose,
    );
  }

  Future<void> register(String phone, String password, String role) async {
    await _runAuth(
      () => _authService.register(
        phone: phone.trim(),
        password: password,
        role: role,
      ),
      failureTitle: '注册失败',
    );
  }

  /// 角色 → 首页路由。**只有这一处**回答「学生去哪儿、家长去哪儿」。
  ///
  /// 两个调用点必须给出同一个答案：**登录成功之后**的跳转，以及
  /// **冷启动带着已恢复的会话启动时**的首屏（见 `app.dart` 的 `_firstScreen`）。
  /// 各写一遍的话，漏改一处的结果是「登录进去是学生首页，刷新一下变成家长首页」——
  /// 而它只在特定的角色上出现，很容易被当成偶发。
  static String homeRouteFor(String? role) =>
      role == 'student' ? '/student-home' : '/parent-home';

  /// 当前登录态该落在哪个首页。
  String get homeRoute => homeRouteFor(currentUser.value?.role);

  Future<void> _runAuth(
    Future<UserModel> Function() action, {
    String failureTitle = '登录失败',
    VoidCallback? onSuccess,
  }) async {
    if (isLoading.value) return;
    isLoading.value = true;
    try {
      currentUser.value = await action();
      onSuccess?.call();
      Get.offAllNamed(homeRoute);
    } on AuthException catch (error) {
      _safeSnackbar(failureTitle, error.message);
    } catch (_) {
      _safeSnackbar(failureTitle, '暂时无法连接认证服务，请稍后重试');
    } finally {
      isLoading.value = false;
    }
  }

  /// 退出登录。
  ///
  /// 三件事都得做，**少一件都表现为「安静地没退干净」**：
  ///
  /// 1. **吊销服务端会话 + 清本地凭证** —— 走 [AuthService.logout]。
  ///    只清内存的话，下次冷启动 `restoreSession` 会把这个人**又登回来**，
  ///    用户以为自己点错了；而服务端那个 token 一直有效，谁拿着它都能继续
  ///    读到全部数据。顺序由 `HttpAuthApi.logout` 保证：它先抓住 token 再清
  ///    本地，然后用这个 token 去吊销服务端会话 —— 反过来发就是一次未认证
  ///    的请求，401 被吞掉，会话一直活着。
  /// 2. **清内存身份** —— 界面上的 `Obx` 都盯着它。
  /// 3. **清账号级缓存** —— 见 [_resetAccountScopedState]。
  ///
  /// 服务端那一步**失败也要继续登出**（断网、服务正在重启）。用户已经明确
  /// 表示不想再用这个账号了，把他留在一个走不掉的登录态里，他能做的只有
  /// 卸载重装 —— 那比「服务端会话晚一点过期」坏得多。
  Future<void> logout() async {
    try {
      await _authService.logout();
    } catch (_) {
      // 本地凭证已由 `HttpAuthApi.logout` 清掉；服务端会话有自己的 TTL。
    }
    currentUser.value = null;
    // 顺序刻意是「清身份 → 清账号级缓存 → 跳转」，而且**跳转不 await**。
    //
    // ⚠️ `Get.offAllNamed` 返回的不是「跳完了」，而是
    // `Navigator.pushNamedAndRemoveUntil` 的 Future —— 它在**登录页被弹出时**
    // 才完成（GetX 4.7.3 `extension_navigation.dart`）。`await` 它等于在
    // 这一行一直等下去，**后面的代码永远不会执行**。
    //
    // 第一版就是这么写的，后果非常安静：退出登录本身看起来完全正常
    // （跳到了登录页、身份也清了），只有「账号级缓存从来没被清过」——
    // 下一个登录者于是看到上一个人的余额。是靠 `logout_entry_test.dart`
    // 断言缓存内容才暴露出来的。
    _resetAccountScopedState();
    unawaited(Get.offAllNamed('/login'));
  }

  /// 清掉**不属于任何路由**的账号级缓存。
  ///
  /// 为什么不能只靠 GetX 自动回收：默认的 `SmartManagement.full` 只回收
  /// 「注册时挂在当前路由上」的控制器。下面两处都不是 ——
  ///
  /// - [PointController] 是 `permanent: true`（积分账本要跨页共享），
  ///   它把 `studentId` 和余额一起留着；
  /// - [NotificationController] 在 `app.dart` 的 `build()` 里注册，那一刻
  ///   还没有任何路由，所以它也不随首页消失。
  ///
  /// 不清的后果是**换了账号却看到上一个账号的数字**：积分余额、通知列表。
  /// 它们都属于「界面完全正常、只是内容是别人的」那一类。
  ///
  /// ## 为什么是「让它们自己清」而不是在这里 `Get.delete`
  ///
  /// 第一版写的是 `Get.delete<T>(force: true)`，**实测删不掉**：这两个控制器
  /// 都被还活着的页面引用（个人信息页那张积分卡是 `Obx(() =>
  /// PointController.to)`），退出登录的过场动画期间页面仍在树上，下一次
  /// rebuild 就把它重新建了出来 —— 删完立刻查 `isRegistered` 仍是 true。
  /// 清内容不依赖任何生命周期时序。
  ///
  /// 读缓存不用管：它的键里带了 `userId`（见 `DataApiClient._cacheKey`），
  /// 换账号自然是另一批键，命不中上一个人的那份。
  void _resetAccountScopedState() {
    if (Get.isRegistered<PointController>()) {
      Get.find<PointController>().resetForAccountSwitch();
    }
    if (Get.isRegistered<NotificationController>()) {
      Get.find<NotificationController>().resetForAccountSwitch();
    }
  }
}
