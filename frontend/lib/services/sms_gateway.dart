/// 短信验证码网关的**端口**。
///
/// 与 `ReviewExporter`、`AiDataSource` 同一套做法：业务只认这个抽象，
/// 接哪家运营商（阿里云 / 腾讯云 / 容联…）是适配器的事。
/// 本期没有短信网关，所以只有一个 [UnconfiguredSmsGateway]，
/// 它**什么也不做**——这正是「预留」的含义：结构先立起来，
/// 接的时候补一个实现即可，业务代码一行不改。
///
/// ## 唯一能力开关
///
/// [SmsGateway.isConfigured] 是「短信能不能用」的**唯一真值来源**。
/// 界面不要自己判断环境（`kReleaseMode`、有没有配 URL…），
/// 更不要把按钮藏起来——藏起来的结果是接入时没人记得它存在。
/// 见 `doc/auth-extension-seams.md` 的启用清单。
library;

/// 验证码的用途。
///
/// **必须区分**，不能只用一个泛化的「短信验证码」：服务端按用途分别存码，
/// 一次「登录」用的码不该能通过「重置密码」的校验 ——
/// 否则拿到登录码的人就等于拿到了改密权，而改密之后原主人就再也进不来了。
/// 这是权限提升，不是体验问题。
enum SmsPurpose {
  /// 验证码登录。
  login('sms_login', '登录'),

  /// 忘记密码 → 重置密码。**比登录更强的一次授权**，因此单独一个用途。
  resetPassword('reset_password', '重置密码');

  const SmsPurpose(this.code, this.label);

  /// 与网关路由 / 审计记录对齐的稳定标识。规则同 `LoginMethod.code`。
  final String code;

  final String label;
}

/// 一次「请发验证码」的结果。
///
/// 刻意分成三态而不是 `bool`：三者的**用户处置完全不同** ——
/// 未接入要去催运维，被拒要先看是不是自己点太快，只有成功才该等短信。
/// 压成 bool 的话「网关没接」会显示成「发送失败，请重试」，
/// 用户会一直点、一直失败，而真正的原因（没接网关）永远不会被说出来。
enum SmsSendStatus {
  /// 短信服务已受理。**只有这一种状态可以显示「验证码已发送」**。
  sent,

  /// 短信网关尚未接入 / 未配置。本期唯一会走到的状态。
  unavailable,

  /// 服务端明确拒绝：频控、号码不合法、短信模板未过审。
  rejected,
}

class SmsSendResult {
  const SmsSendResult._(this.status, this.message, {this.retryAfterSeconds});

  /// 已受理。`retryAfterSeconds` 是服务端给的冷却时长，客户端倒计时以它为准，
  /// 不要各写一个 60 —— 两边对不上时用户会看到「按钮亮了但发不出去」。
  const SmsSendResult.sent({int? retryAfterSeconds})
    : this._(
        SmsSendStatus.sent,
        '验证码已发送',
        retryAfterSeconds: retryAfterSeconds,
      );

  const SmsSendResult.unavailable([
    String message = '短信服务尚未接入，暂时无法发送验证码',
  ]) : this._(SmsSendStatus.unavailable, message);

  const SmsSendResult.rejected(String message, {int? retryAfterSeconds})
    : this._(
        SmsSendStatus.rejected,
        message,
        retryAfterSeconds: retryAfterSeconds,
      );

  final SmsSendStatus status;

  /// 给人看的中文说明。
  final String message;

  /// 距离下次可重发还有多少秒。`null` = 服务端没说，客户端可以不倒计时。
  final int? retryAfterSeconds;

  bool get isSent => status == SmsSendStatus.sent;
}

/// 短信失败的原因。
///
/// **必须是枚举，不能只有一句文案** —— 理由和 `OcrFailureKind` 完全一样：
/// 「验证码错了」要引导用户重新输入，「服务没接」得去找运维，
/// 「太频繁了」要让他等一会儿再来。三种处置互不相干，
/// 合成一句「操作失败，请重试」的结果是用户永远在错的方向上重试。
enum SmsFailureKind {
  /// 网关未接入 / 未配置。**本期唯一会走到的失败原因。**
  unavailable,

  /// 验证码不对或已过期。可以让用户改一改再试。
  invalidCode,

  /// 触发频控。等 `retryAfterSeconds` 秒再来。
  rateLimited,
}

/// 短信链路自己的异常。
///
/// 与 `AuthException` 分开，是因为失败的**归属**不同：
/// `AuthException` 是「本地这份数据不允许这么做」（号码格式、密码强度、
/// 账号不存在），`SmsException` 是「远程那条链路没走通」。
/// 混成一个类之后，调用方就没法只对其中一类做处理了。
class SmsException implements Exception {
  const SmsException(this.kind, this.message, {this.retryAfterSeconds});

  final SmsFailureKind kind;

  /// 给人看的中文说明。
  final String message;

  final int? retryAfterSeconds;

  @override
  String toString() => message;
}

/// 服务端校验通过后签发的一次性凭证。
///
/// 客户端**拿不到验证码本身**（见 [SmsGateway] 的说明），拿到的是这个：
/// 「服务端已经确认这个号码刚才通过了 [purpose] 的验证」。
class SmsVerification {
  const SmsVerification({
    required this.phone,
    required this.token,
    required this.purpose,
    required this.expiresAt,
  });

  final String phone;

  /// 服务端签发的凭证。客户端**不校验它的真伪**（没有密钥、也不该有）。
  final String token;

  final SmsPurpose purpose;
  final DateTime expiresAt;

  /// **形制校验**，不是真伪校验。
  ///
  /// 客户端能做到的只有：这三件事是不是自洽（用途对得上、没过期、token 非空）。
  /// 真伪必须由服务端在用它换登录态时再验一次 ——
  /// 客户端一旦自己「补」一个校验，就会有人把它当成安全边界，
  /// 而它挡得住的是笔误，不是攻击。
  ///
  /// 用途不匹配（拿登录凭证去改密码）**必须在这里就拒**：
  /// 这一条不是防攻击，是防我们自己把两个流程的参数接错线 ——
  /// 接错线的后果是用户在「忘记密码」里点了一下，密码被换成了别人的新密码。
  bool isWellFormedFor(SmsPurpose expected, DateTime now) {
    return purpose == expected && token.isNotEmpty && expiresAt.isAfter(now);
  }
}

/// 短信网关端口。
///
/// 注意这里**没有把验证码带回来的地方**：校验必须发生在服务端。
/// 客户端一旦能拿到码、或者能自己比对，「改密码」这件事就退化成了
/// 「本地存一个字符串」。所以：
/// - 请求下发：拿不到码，只拿到「发出了没有」；
/// - 校验：把用户输入的码发给服务端，拿回 [SmsVerification]。
abstract class SmsGateway {
  /// 是否已接入。**界面上的按钮可用性只看这一个值。**
  ///
  /// 用 `bool get` 而不是常量，是为了将来能做成「运行时探测」：
  /// 比如服务端 `/auth/sms/capability` 返回 false（短信模板未过审）时，
  /// 入口应当同样禁用，而不是让用户点进一条注定失败的链路。
  bool get isConfigured;

  /// 请求发送验证码。**实现方必须拒绝伪造成功**：
  /// 没接网关就返回 [SmsSendStatus.unavailable]，不要为了「流程跑通」
  /// 假装发了一条 —— 用户会一直等一条永远不来的短信。
  Future<SmsSendResult> sendVerificationCode({
    required String phone,
    required SmsPurpose purpose,
  });

  /// 把用户输入的验证码交给服务端校验。
  ///
  /// 校验不通过时**抛 [SmsException] 而不是返回 null**：
  /// 调用方必须显式处理失败，返回 null 太容易被 `??` 顺手兜成
  /// 一个「合法」的默认值 —— 而那正好是一条绕过校验的路。
  Future<SmsVerification> verifyCode({
    required String phone,
    required String code,
    required SmsPurpose purpose,
  });
}

/// 没有短信网关时的实现。**这是当前的默认值。**
///
/// 行为被刻意限制到最小：不发网络请求、不落库、不产生随机数、
/// 不返回任何验证码。它唯一做的事就是如实报告「没接」。
class UnconfiguredSmsGateway implements SmsGateway {
  const UnconfiguredSmsGateway();

  @override
  bool get isConfigured => false;

  @override
  Future<SmsSendResult> sendVerificationCode({
    required String phone,
    required SmsPurpose purpose,
  }) async {
    // 用途不同，文案也不同：重置密码的失败要引导用户「先用密码登录」，
    // 而登录失败只能引导「去注册或者用密码登录」。共用一句会指错路。
    return switch (purpose) {
      SmsPurpose.login => const SmsSendResult.unavailable(
        '短信验证码登录尚未开通，请使用密码或微信登录',
      ),
      SmsPurpose.resetPassword => const SmsSendResult.unavailable(
        '短信服务尚未接入，暂时无法通过短信重置密码',
      ),
    };
  }

  @override
  Future<SmsVerification> verifyCode({
    required String phone,
    required String code,
    required SmsPurpose purpose,
  }) async {
    // 刻意不「返回一个能过的凭证」：那会让整条链路看起来是通的，
    // 而实际上一次短信都没发出去。
    throw const SmsException(
      SmsFailureKind.unavailable,
      '短信服务尚未接入，暂时无法校验验证码',
    );
  }
}

/// 默认网关。**接入短信服务时只需要改这一处返回值。**
///
/// 之所以留一个函数而不是让各处直接 `const UnconfiguredSmsGateway()`：
/// 那样以后要换实现就得全局搜替换，而漏掉的那一处会静默地退化成
/// 「永远没接」——又回到「点了没反应」。一个函数就是一处开关。
SmsGateway defaultSmsGateway() => const UnconfiguredSmsGateway();
