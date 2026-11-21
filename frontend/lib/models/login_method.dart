/// 一个账号可以用哪些方式登录。
///
/// 这个枚举存在的意义不是「列全今天支持的两种方式」，而是**给第三种留位置**：
/// 现在界面里到处是 `loginByPhone` / `loginByWechat` 这样的动词名，
/// 想接短信验证码就得再散着加一整套分支。有了它，新增方式 =
/// 枚举里加一行 + 在 [AuthService] 加一个用例，界面按枚举渲染。
///
/// ## 约束：`code` 是协议值，`index` 不是
///
/// `code` 会出现在持久化数据（「上次登录方式」）、网关请求体与审计记录里。
/// 它一旦发布就不能改，也**不能用 `index` 代替** ——
/// 枚举顺序是内部实现，将来在中间插入一个新方式会让所有历史记录的
/// `index` 全部错位，且错得毫无痕迹（1 从「微信」变成「验证码」）。
enum LoginMethod {
  /// 手机号 + 密码。今天可用。
  phone('phone', '手机号密码'),

  /// 微信授权。今天可用（客户端是本地实现，见 `AuthService.loginByWechat`）。
  wechat('wechat', '微信登录'),

  /// 手机号 + 短信验证码。**本期未启用**。
  ///
  /// 这里刻意**不写 `available: false` 这种字段**：一旦枚举自己声明可用性，
  /// 就出现了第二个真值来源，和 `SmsGateway.isConfigured` 迟早对不上
  /// （枚举说可用、网关没配 → 用户点了按钮，什么都没发生）。
  /// 可用性只从网关那一个地方推导，见 [requiresSmsGateway]。
  smsCode('sms_code', '验证码登录');

  const LoginMethod(this.code, this.label);

  /// 持久化 / 传输用的稳定标识。**不要改成 `name`**：`name` 会跟着
  /// Dart 标识符重命名一起漂移，而 `code` 是写进数据里的。
  final String code;

  /// 界面上显示的名字。
  final String label;

  /// 这条路是否依赖短信网关。
  ///
  /// 这是**结构性事实**（它就是要发短信），不是能力开关；
  /// 真正「能不能用」= `requiresSmsGateway ? gateway.isConfigured : true`。
  /// 分开写是为了让能力开关保持唯一。
  bool get requiresSmsGateway => this == LoginMethod.smsCode;

  /// 解析持久化值。认不出来时返回 `null`，**不要默认成 [phone]** ——
  /// 默认成手机号密码会让「读到一条脏数据」表现成「用户上次用的是密码登录」，
  /// 排查时会一路往错的方向找。
  static LoginMethod? tryParse(String? code) {
    if (code == null || code.isEmpty) return null;
    for (final method in LoginMethod.values) {
      if (method.code == code) return method;
    }
    return null;
  }
}
