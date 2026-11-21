import '../models/user_model.dart';
import 'auth_data_source.dart';
import 'data_api_client.dart';
import 'database_service.dart';
import 'http_auth_api.dart';
import 'sms_gateway.dart';

class AuthService {
  AuthService({
    AuthDataSource? database,
    SmsGateway? smsGateway,
    DateTime Function()? now,
    HttpAuthApi? remote,
  }) : _database = database ?? DatabaseService.instance,
       _smsGateway = smsGateway ?? defaultSmsGateway(),
       _now = now ?? DateTime.now,
       // 默认取门面里装配好的那一份（见 `DatabaseService.cloud`）。
       // 没配数据服务地址时它是 null，于是整条路径与上云之前**逐字相同**。
       //
       // ⚠️ 读的是 `DatabaseService.cloud` 而不是另存一份全局：数据走哪条路
       // 与登录走哪条路**必须由同一个事实决定**，否则会出现「数据上了云、
       // 登录还在本地」的半上云 —— 详见 `DatabaseService.cloud` 的说明。
       _remote = remote ?? DatabaseService.cloud?.auth;

  final AuthDataSource _database;

  /// 云端账号端点。为 null 表示当前是**纯本地**模式。
  ///
  /// 两条路径的差别不是「实现不同」，而是**动作不同**：本地是「读一行、
  /// 自己比口令」；云端是「把口令交给服务端、换回一个会话」。
  /// 合成一个接口只会让后者伪装成前者（见 `http_auth_api.dart`）。
  final HttpAuthApi? _remote;

  bool get isCloud => _remote != null;

  /// 短信网关。默认是 [UnconfiguredSmsGateway]（**没接**），
  /// 见 `doc/auth-extension-seams.md`。
  final SmsGateway _smsGateway;

  /// 注入时钟。测试里要断言 `passwordUpdatedAt` / 凭证过期，
  /// 实现里偷偷取一次 `DateTime.now()` 就没法断言了。
  final DateTime Function() _now;

  static final _phonePattern = RegExp(r'^1\d{10}$');
  static final _passwordPattern = RegExp(r'^(?=.*[A-Za-z])(?=.*\d)[A-Za-z\d]{6,16}$');

  /// 短信功能是否已开通。**界面上的按钮可用性只看它。**
  bool get smsEnabled => _smsGateway.isConfigured;

  Future<UserModel> register({
    required String phone,
    required String password,
    required String role,
  }) async {
    final normalizedPhone = phone.trim();
    if (!_phonePattern.hasMatch(normalizedPhone)) {
      throw const AuthException('请输入有效的11位手机号');
    }
    if (!_passwordPattern.hasMatch(password)) {
      throw const AuthException('密码需为6-16位数字和字母组合');
    }
    if (role != 'student' && role != 'parent') {
      throw const AuthException('请选择学生或家长身份');
    }

    // 云端：校验交给服务端（同一套规则），客户端这几次校验留着是为了
    // **即时反馈**（一次本地正则比一次往返快得多，而且断网时也能说清哪里填错了）。
    if (_remote != null) {
      final account = await _guard(
        () => _remote.register(
          phone: normalizedPhone,
          password: password,
          role: role,
        ),
        fallback: '注册失败，请稍后重试',
      );
      return UserModel.fromJson(account.user);
    }

    if (await _database.findUserByPhone(normalizedPhone) != null) {
      throw const AuthException('该手机号已注册，请直接登录');
    }

    final user = <String, dynamic>{
      'id': 'user_${DateTime.now().millisecondsSinceEpoch}',
      'name': role == 'student' ? '新学生' : '新家长',
      'phone': normalizedPhone,
      'role': role,
      'avatar': role == 'student' ? 'student' : 'parent',
      'password': password,
      'wechatOpenId': null,
      // 「密码什么时候设的」在注册这一刻就成立，现在就写。
      // 留到「改密」功能上线才记，会导致新功能上线时所有历史账号都缺这一项。
      'passwordUpdatedAt': _now().toIso8601String(),
    };
    await _database.saveUser(user);
    return UserModel.fromJson(user);
  }

  Future<UserModel> loginByPhone({
    required String phone,
    required String password,
    required String role,
  }) async {
    // 云端：口令校验在服务端，客户端拿回的是一个**会话**（token + 用户行）。
    // 这里刻意不复用本地那几个校验 —— 它们的前提（库里存着明文口令）在云端不成立。
    if (_remote != null) {
      final account = await _guard(
        () => _remote.login(
          phone: phone.trim(),
          password: password,
          role: role,
        ),
        fallback: '登录失败，请稍后重试',
      );
      return UserModel.fromJson(account.user);
    }

    final user = await _database.findUserByPhone(phone);
    if (user == null || user['password'] != password || user['role'] != role) {
      throw const AuthException('手机号、密码或身份不正确');
    }
    return UserModel.fromJson(user);
  }

  /// 微信登录。
  ///
  /// 本地实现直接用一个固定 openId 建号 —— **它没有密码**
  /// （`password: null`，因此 `UserModel.hasPassword == false`）。
  /// 「忘记密码」的入口对这类账号要改说「设置密码」，
  /// 见 `UserModel.hasPassword` 的说明。
  Future<UserModel> loginByWechat({required String role}) async {
    // 云端模式下这条路径**必须如实失败**。
    //
    // 服务端为它预留了 `POST /auth/login-wechat`，但返回的是 501
    // （`not_implemented`）—— 因为微信开放平台的应用还没申请。
    // 这时若继续走本地实现（建一个 `mock-wechat-student` 的本地账号），
    // 用户会拿到一个**在云端不存在**的身份：能进首页，但每条数据都是空的，
    // 而没有任何一处报错。宁可在这里说清「还没接入」。
    if (_remote != null) {
      throw const AuthException('微信登录尚未接入，请使用手机号登录');
    }

    final openId = 'mock-wechat-$role';
    final existing = await _database.findUserByWechat(openId);
    if (existing != null && existing['role'] == role) {
      return UserModel.fromJson(existing);
    }

    final user = <String, dynamic>{
      'id': 'wechat_${DateTime.now().millisecondsSinceEpoch}',
      'name': role == 'student' ? '微信学生' : '微信家长',
      'phone': null,
      'role': role,
      'avatar': role == 'student' ? 'student' : 'parent',
      'password': null,
      'wechatOpenId': openId,
      // 刻意不写 passwordUpdatedAt：语义是「从未设置过密码」。
      // 写上进来说明这里有人图省事把整行填满，而那会让
      // 「这是不是一个有密码的账号」这个判断失效。
    };
    await _database.saveUser(user);
    return UserModel.fromJson(user);
  }

  // ===== 短信验证码（本期未启用，接口与数据模型已就位）=====
  //
  // 三条用例的启用条件完全相同：`SmsGateway.isConfigured == true`。
  // 在那之前它们会**如实失败**，而不是伪造一条成功路径 ——
  // 伪造的后果不是「演示不好看」，而是接入短信后没人知道
  // 哪一段代码其实是假的。

  /// 请求下发验证码。
  ///
  /// 返回三态结果而不是抛 [AuthException]：失败要能带出
  /// `retryAfterSeconds`（服务端给的冷却时长），而异常里只有一个字符串，
  /// 硬塞进去就得把秒数拼进文案、界面再解析文案回来 —— 那是错的。
  ///
  /// ⚠️ **不校验号码是否已注册**。校验了的话，这个接口就变成了一个
  /// 「查这个手机号在不在我们库里」的查询器。要拦注册状态，
  /// 留给服务端在审计维度上做（同一号码高频试探 → 风控），
  /// 而不是在这里回一句「该手机号未注册」。
  Future<SmsSendResult> sendSmsCode({
    required String phone,
    required SmsPurpose purpose,
  }) async {
    final normalized = phone.trim();
    if (!_phonePattern.hasMatch(normalized)) {
      return const SmsSendResult.rejected('请输入有效的11位手机号');
    }
    return _smsGateway.sendVerificationCode(
      phone: normalized,
      purpose: purpose,
    );
  }

  /// 把用户输入的验证码交给服务端校验，换回一次性凭证。
  ///
  /// 「校验」这一步**必须走服务端**，所以它只是把请求转给网关，
  /// 客户端这里没有一行比对逻辑 —— 有的话，验证码就退化成了一个
  /// 本地字符串常量。见 [SmsGateway] 的说明。
  ///
  /// 失败分两类，**刻意分开抛**：
  /// - [AuthException]：本地输入就不对（号码格式、空验证码），压根没发请求；
  /// - [SmsException]：远程链路没走通（未接入 / 码错 / 限流），且自带原因枚举。
  /// 合成一类之后，调用方就没法只对其中一类做处理了。
  Future<SmsVerification> verifySmsCode({
    required String phone,
    required String code,
    required SmsPurpose purpose,
  }) async {
    _requireSmsEnabled();
    final normalized = phone.trim();
    if (!_phonePattern.hasMatch(normalized)) {
      throw const AuthException('请输入有效的11位手机号');
    }
    final trimmedCode = code.trim();
    if (trimmedCode.isEmpty) {
      throw const AuthException('请输入验证码');
    }
    return _smsGateway.verifyCode(
      phone: normalized,
      code: trimmedCode,
      purpose: purpose,
    );
  }

  /// 验证码登录。
  ///
  /// **不需要 `role`**：手机号在 `app_user` 上是 UNIQUE 的，
  /// 一个号码只对应一个账号，身份由账号自己决定。
  /// 让用户在验证码登录时再选一次身份，只会多出一种失败：
  /// 账号是家长、手滑选了学生，然后被拒 —— 而他并没有做错什么。
  Future<UserModel> loginBySmsCode({
    required SmsVerification verification,
  }) async {
    _requireSmsEnabled();
    // 用途必须对得上，见 [SmsVerification.isWellFormedFor]。
    if (!verification.isWellFormedFor(SmsPurpose.login, _now())) {
      throw const AuthException('验证码校验未通过，请重新获取');
    }

    final user = await _database.findUserByPhone(verification.phone.trim());
    if (user == null) {
      throw const AuthException('该手机号尚未注册，请先注册账号');
    }
    return UserModel.fromJson(user);
  }

  /// 通过短信验证码重置密码。
  ///
  /// `newPassword` 走的是**和注册完全相同的强度校验**（同一个正则）。
  /// 两处各写一套的后果是「重置出来的密码比注册的弱」——
  /// 而这条路径平时不用，等发现时已经有人这么改过密码了。
  Future<UserModel> resetPasswordBySmsCode({
    required SmsVerification verification,
    required String newPassword,
  }) async {
    _requireSmsEnabled();
    if (!verification.isWellFormedFor(SmsPurpose.resetPassword, _now())) {
      throw const AuthException('验证码校验未通过，请重新获取');
    }
    if (!_passwordPattern.hasMatch(newPassword)) {
      throw const AuthException('密码需为6-16位数字和字母组合');
    }

    final normalized = verification.phone.trim();
    final user = await _database.findUserByPhone(normalized);
    if (user == null) {
      throw const AuthException('该手机号尚未注册，请先注册账号');
    }

    await _database.updatePassword(
      userId: user['id'] as String,
      newPassword: newPassword,
      updatedAt: _now().toIso8601String(),
    );

    // 回读一次，而不是拿旧的 map 拼一个新 UserModel：
    // 「改成功了没有」必须由数据源回答。拼出来的对象永远是成功的样子。
    final updated = await _database.findUserByPhone(normalized);
    return UserModel.fromJson(updated ?? user);
  }

  /// 登出。
  ///
  /// 纯本地模式下是空操作：本地那份「登录态」只在内存里（`AuthController`），
  /// 没有服务端会话可吊销。
  ///
  /// 云端模式下会**先清本地凭证、再打服务端**（理由见 `HttpAuthApi.logout`）。
  Future<void> logout() async {
    await _remote?.logout();
  }

  /// 改密码。
  ///
  /// ⚠️ 服务端改密会**吊销全部旧会话并返回新 token**，`HttpAuthApi` 已经用
  /// 新 token 覆盖了本地那一份；这里不必（也不该）再做一次。
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final remote = _remote;
    if (remote == null) {
      throw const AuthException('修改密码需要连接服务端，当前是本地模式');
    }
    await _guard(
      () => remote.changePassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      ),
      fallback: '修改密码失败，请稍后重试',
    );
  }

  /// 把传输层的失败翻译成 [AuthException]。
  ///
  /// 为什么保留服务端文案：它比一句「登录失败」精确得多 ——
  /// 「手机号、密码或身份不正确」与「该手机号已注册」指向完全不同的下一步动作。
  /// 唯一要改写的是**连不上**这一类：那与账号无关，说「密码不对」会把人带偏。
  Future<T> _guard<T>(
    Future<T> Function() action, {
    required String fallback,
  }) async {
    try {
      return await action();
    } on DataApiException catch (e) {
      throw AuthException(
        e.isOffline
            ? '连不上服务器，请检查网络后重试'
            : (e.message.isEmpty ? fallback : e.message),
      );
    }
  }

  /// 短信未接入时，两条消费凭证的路径都必须关着。
  ///
  /// 别以为「没有凭证就进不来」：`SmsVerification` 是个普通值对象，
  /// 谁都能 `const` 一个出来。关闭的理由不是防攻击（本地库本来就在用户手里），
  /// 而是**防止接错线**：将来有人把某个演示入口直接连到
  /// `resetPasswordBySmsCode` 上，没有这道闸就会「看起来能用」。
  void _requireSmsEnabled() {
    if (!_smsGateway.isConfigured) {
      throw const AuthException('短信服务尚未接入，暂时无法使用该功能');
    }
  }
}

class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
