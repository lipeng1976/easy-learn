import 'login_method.dart';

class UserModel {
  final String id;
  final String name;
  final String phone;
  final String role; // student | parent
  final String avatar;
  final String gender;
  final String grade;

  /// 学期：`上` / `下` / 空串（未填写）。
  ///
  /// 与 [grade] 分开：升学期只改这一个字段，历史错题里存的年级学期快照
  /// 不会被连带改掉。
  final String term;
  final List<String> hobbies;
  final String bio;

  /// 这个账号**是否设置过密码**。
  ///
  /// 只向上传布尔结论、不传密码本身：`UserModel` 会一路飘到界面层
  /// （`AuthController.currentUser`），把明文口令放在那里，
  /// 迟早有人图省事拿它去显示「当前密码」或者塞进日志。
  ///
  /// 微信登录创建的账号 `password` 是 `null`，于是 `hasPassword == false`。
  /// 界面据此把「找回/重置密码」的文案改成「设置密码」——
  /// 对没设过密码的人说「重置」是错的，他会以为自己忘了什么。
  final bool hasPassword;

  /// 密码最后一次被设置 / 修改的时间。`null` = 从未设置过。
  ///
  /// **本期只写不判**：注册时写入、微信建号时不写、资料编辑不得覆盖它
  /// （`updateUserProfile` 是先读整行再回写，天然保住）。
  /// 留着它是为了后续两件事不用再走一次数据库迁移：
  /// 1. 「改密之后让其它设备上的旧登录态失效」需要一个时间依据；
  /// 2. 「记住密码」里存的那份口令什么时候过期，也要拿它作参照。
  final DateTime? passwordUpdatedAt;

  UserModel({
    required this.id,
    required this.name,
    required this.phone,
    required this.role,
    required this.avatar,
    this.gender = '',
    this.grade = '',
    this.term = '',
    this.hobbies = const [],
    this.bio = '',
    this.hasPassword = false,
    this.passwordUpdatedAt,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      phone: json['phone'] ?? '',
      role: json['role'] ?? 'student',
      avatar: json['avatar'] ?? '👦',
      gender: json['gender'] ?? '',
      grade: json['grade'] ?? '',
      term: json['term'] ?? '',
      hobbies: parseHobbies(json['hobbies']),
      bio: json['bio'] ?? '',
      // 「设没设过密码」有两个判据，**缺一不可**：
      //
      // · 本地实现把口令明文放在行里，所以看得到 `password`；
      // · 服务端**永远不返回口令**（只返回 `passwordUpdatedAt`），
      //   所以在云端只能靠凭证时间戳判断。
      //
      // 只看第一个判据的后果是：云端登录拿到的账号 `hasPassword == false`，
      // 于是 `canUse(LoginMethod.phone)` 为假 —— 登录页会把「手机号登录」
      // 这个入口关掉，而用户手里明明有密码。症状是「登录按钮点不动」。
      hasPassword: ((json['password'] as String?) ?? '').isNotEmpty ||
          json['passwordUpdatedAt'] != null,
      passwordUpdatedAt: DateTime.tryParse(
        (json['passwordUpdatedAt'] as String?) ?? '',
      ),
    );
  }

  /// 是否绑定了手机号。短信相关的一切（验证码登录、重置密码）
  /// 都以它为前置条件 —— 没有手机号就没有收码的地方。
  bool get hasPhone => phone.isNotEmpty;

  /// 这个账号**自身的数据状态**能否支持某条登录路径。
  ///
  /// 返回值只代表「账号这侧具备条件」，**不代表功能已开通**：
  /// 短信是否接入由 `SmsGateway.isConfigured` 说了算，两者都成立才能走。
  /// 合成一个方法返回最终结论是刻意的——分开判断的地方迟早会漏掉一个。
  bool canUse(LoginMethod method) => switch (method) {
    LoginMethod.phone => hasPhone && hasPassword,
    LoginMethod.wechat => true,
    LoginMethod.smsCode => hasPhone,
  };

  /// 手机号打码，用于「验证码将发送至 138****0001」这类提示。
  ///
  /// 验证码页面上要显示它，是为了让用户确认**号码是自己填的那个** ——
  /// 填错一位而界面不回显，用户会一直等一条发给陌生人的短信。
  /// 但也不能全量回显：那是把 PII 印在屏幕上给人看。
  static String maskPhone(String phone) {
    final value = phone.trim();
    if (value.length < 7) return value;
    return '${value.substring(0, 3)}****${value.substring(value.length - 4)}';
  }

  /// 解析 `hobbies`，兼容三种形态：数据库列里的逗号分隔字符串、
  /// Web 内存存储里的真正列表、以及空串 / 整列缺失。
  ///
  /// **空串必须走字符串分支**：`List.from('')` 会抛
  /// `type 'String' is not a subtype of type 'Iterable<dynamic>'`，
  /// 而空串恰恰是演示账号的常态值 —— `_ensureDefaultUsers` 按需插入时
  /// 没有写 `hobbies`，列默认值就是 `''`；Web 端种子写的是 `'阅读,跑步'`，
  /// 于是这个分支**只在原生上被踩到**。症状极具迷惑性：
  /// 手机号登录直接失败（提示「手机号、密码或身份不正确」），
  /// 而微信登录一切正常 —— 后者构造的 map 里根本没有这个键。
  static List<String> parseHobbies(Object? raw) {
    if (raw is List) {
      return raw.map((e) => '$e').where((e) => e.isNotEmpty).toList();
    }
    if (raw is String) {
      return raw
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return const <String>[];
  }
}
