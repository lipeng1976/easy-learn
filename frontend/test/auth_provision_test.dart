import 'package:easy_learn_app/app.dart';
import 'package:easy_learn_app/models/login_method.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/services/auth_data_source.dart';
import 'package:easy_learn_app/services/auth_service.dart';
import 'package:easy_learn_app/services/sms_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「登录方式 / 忘记密码」预留设计的护栏测试。
///
/// 这套测试盯的不是「功能能跑」，而是**功能没跑起来时会不会说谎**：
/// 本期没有短信网关，所以任何一条会把「没接」包装成「成功」的代码路径
/// 都是 bug，而不是「演示需要」。
///
/// 另一半盯的是**可无缝启用**：把 `isConfigured` 翻成 true 之后，
/// 发送 → 校验 → 登录 / 改密 应该整条通，且业务代码一行不改。
/// 只有这一半在，另一半（如实失败）才只是「暂时关着」而不是「其实没写」。
void main() {
  group('LoginMethod：稳定标识', () {
    test('持久化用的是 code，不是枚举下标', () {
      expect(
        LoginMethod.values.map((item) => item.code).toList(),
        ['phone', 'wechat', 'sms_code'],
      );
      // 这一条是核心：将来在枚举中间插入一个方式时，
      // 历史记录里的 'sms_code' 仍然要解析成同一个东西。
      expect(LoginMethod.tryParse('sms_code'), LoginMethod.smsCode);
      expect(LoginMethod.tryParse('wechat'), LoginMethod.wechat);
    });

    test('认不出来时返回 null，不默认成手机号密码', () {
      expect(LoginMethod.tryParse(null), isNull);
      expect(LoginMethod.tryParse(''), isNull);
      expect(LoginMethod.tryParse('telepathy'), isNull);
    });

    test('只有短信方式依赖短信网关（网关是唯一的可用性来源）', () {
      expect(LoginMethod.phone.requiresSmsGateway, isFalse);
      expect(LoginMethod.wechat.requiresSmsGateway, isFalse);
      expect(LoginMethod.smsCode.requiresSmsGateway, isTrue);
    });
  });

  group('UserModel：账号自身具备哪些条件', () {
    test('有手机号有密码 → 手机号密码与验证码登录都具备条件', () {
      final user = UserModel.fromJson({
        'id': 'u1',
        'phone': '13800000001',
        'password': 'abc123',
      });

      expect(user.hasPhone, isTrue);
      expect(user.hasPassword, isTrue);
      expect(user.canUse(LoginMethod.phone), isTrue);
      expect(user.canUse(LoginMethod.smsCode), isTrue);
    });

    test('微信建号没有手机号也没有密码 → 只能走微信', () {
      final user = UserModel.fromJson({
        'id': 'w1',
        'phone': null,
        'password': null,
        'wechatOpenId': 'mock-wechat-student',
      });

      expect(user.hasPhone, isFalse);
      expect(user.hasPassword, isFalse);
      expect(user.canUse(LoginMethod.phone), isFalse);
      expect(user.canUse(LoginMethod.smsCode), isFalse);
      expect(user.canUse(LoginMethod.wechat), isTrue);
    });

    test('passwordUpdatedAt 缺失时为 null（语义：从未设置过密码）', () {
      final user = UserModel.fromJson({
        'id': 'u1',
        'password': 'abc123',
        'passwordUpdatedAt': '2026-09-17T10:00:00.000',
      });

      expect(user.passwordUpdatedAt, DateTime(2026, 9, 17, 10));
      expect(UserModel.fromJson({'id': 'u2'}).passwordUpdatedAt, isNull);
    });

    test('手机号打码后仍能让人认出是自己的号，但不全量暴露', () {
      expect(UserModel.maskPhone('13800000001'), '138****0001');
      expect(UserModel.maskPhone(' 13800000001 '), '138****0001');
      // 太短的串原样返回，不要越界 —— 这里崩一次就是登录页打不开。
      expect(UserModel.maskPhone('12345'), '12345');
      expect(UserModel.maskPhone(''), '');
    });
  });

  group('未接入短信时，默认网关只允许如实失败', () {
    const gateway = UnconfiguredSmsGateway();

    test('isConfigured 是 false（唯一能力开关）', () {
      expect(gateway.isConfigured, isFalse);
    });

    test('任何用途都不伪造「已发送」，且文案按用途区分', () async {
      final forLogin = await gateway.sendVerificationCode(
        phone: '13800000001',
        purpose: SmsPurpose.login,
      );
      final forReset = await gateway.sendVerificationCode(
        phone: '13800000001',
        purpose: SmsPurpose.resetPassword,
      );

      expect(forLogin.status, SmsSendStatus.unavailable);
      expect(forLogin.isSent, isFalse);
      expect(forReset.status, SmsSendStatus.unavailable);
      // 两句引导不同：登录失败可以建议去注册，重置失败只能建议先用密码登录。
      expect(forLogin.message, isNot(forReset.message));
    });

    test('校验不给任何凭证，且原因是 unavailable 而不是「验证码错了」', () async {
      expect(
        () => gateway.verifyCode(
          phone: '13800000001',
          code: '123456',
          purpose: SmsPurpose.login,
        ),
        throwsA(
          isA<SmsException>().having(
            (error) => error.kind,
            'kind',
            SmsFailureKind.unavailable,
          ),
        ),
      );
    });
  });

  group('AuthService：未接入时只允许如实失败', () {
    late _MemoryAuthDataSource db;
    late AuthService service;

    setUp(() {
      db = _MemoryAuthDataSource();
      service = AuthService(database: db, now: _clock);
    });

    test('sendSmsCode 返回 unavailable，不抛假异常也不假装成功', () async {
      final result = await service.sendSmsCode(
        phone: '13800000001',
        purpose: SmsPurpose.login,
      );

      expect(result.status, SmsSendStatus.unavailable);
      expect(result.isSent, isFalse);
      expect(result.retryAfterSeconds, isNull);
    });

    test('号码格式不对时判 rejected，不把锅推给「没接」', () async {
      final result = await service.sendSmsCode(
        phone: '138',
        purpose: SmsPurpose.login,
      );

      // 这两种失败要分开：一个让用户改号码，一个让运维去接网关。
      expect(result.status, SmsSendStatus.rejected);
    });

    test('loginBySmsCode 未接入时抛 AuthException', () async {
      expect(
        () => service.loginBySmsCode(
          verification: _verification(SmsPurpose.login),
        ),
        throwsA(isA<AuthException>()),
      );
    });

    test('resetPasswordBySmsCode 未接入时抛异常，且密码一个字节都没动', () async {
      await expectLater(
        () => service.resetPasswordBySmsCode(
          verification: _verification(SmsPurpose.resetPassword),
          newPassword: 'new123',
        ),
        throwsA(isA<AuthException>()),
      );

      // 这是本组最重要的一条：失败路径**不允许**有任何副作用。
      // 改了密码却报失败，用户会以为没改，然后发现旧密码登不上。
      expect(db.users.first['password'], _originalPassword);
      expect(db.users.first['passwordUpdatedAt'], _originalPasswordAt);
    });
  });

  group('无缝启用：把 isConfigured 翻成 true，业务代码一行不改', () {
    late _MemoryAuthDataSource db;
    late _FakeSmsGateway gateway;
    late AuthService service;

    setUp(() {
      db = _MemoryAuthDataSource();
      gateway = _FakeSmsGateway();
      service = AuthService(database: db, smsGateway: gateway, now: _clock);
    });

    test('smsEnabled 跟着网关走', () {
      expect(service.smsEnabled, isTrue);
      expect(
        AuthService(database: db, smsGateway: const UnconfiguredSmsGateway())
            .smsEnabled,
        isFalse,
      );
    });

    test('发送 → 校验 → 登录 整条链路可跑通', () async {
      final sent = await service.sendSmsCode(
        phone: '13800000001',
        purpose: SmsPurpose.login,
      );
      expect(sent.status, SmsSendStatus.sent);
      // 冷却时长以服务端给的为准，客户端不写死 60。
      expect(sent.retryAfterSeconds, 45);

      final verification = await service.verifySmsCode(
        phone: '13800000001',
        code: '123456',
        purpose: SmsPurpose.login,
      );
      final user = await service.loginBySmsCode(verification: verification);

      expect(user.id, 'stu_001');
      expect(user.role, 'student');
    });

    test('重置密码真的落库：新密码能登、旧密码不能', () async {
      final verification = await service.verifySmsCode(
        phone: '13800000001',
        code: '123456',
        purpose: SmsPurpose.resetPassword,
      );
      final user = await service.resetPasswordBySmsCode(
        verification: verification,
        newPassword: 'new123',
      );

      expect(user.id, 'stu_001');
      expect(db.users.first['password'], 'new123');
      expect(
        db.users.first['passwordUpdatedAt'],
        '2026-09-17T12:00:00.000',
      );

      final loggedIn = await service.loginByPhone(
        phone: '13800000001',
        password: 'new123',
        role: 'student',
      );
      expect(loggedIn.id, 'stu_001');
      await expectLater(
        () => service.loginByPhone(
          phone: '13800000001',
          password: _originalPassword,
          role: 'student',
        ),
        throwsA(isA<AuthException>()),
      );
    });

    test('拿登录凭证去改密码必须被拒（用途不允许串用）', () async {
      final loginVerification = await service.verifySmsCode(
        phone: '13800000001',
        code: '123456',
        purpose: SmsPurpose.login,
      );

      await expectLater(
        () => service.resetPasswordBySmsCode(
          verification: loginVerification,
          newPassword: 'new123',
        ),
        throwsA(isA<AuthException>()),
      );
      expect(db.users.first['password'], _originalPassword);
    });

    test('过期凭证被拒', () async {
      final stale = SmsVerification(
        phone: '13800000001',
        token: 'tok_stale',
        purpose: SmsPurpose.login,
        // 注入时钟是 12:00，这里 11:59 已经过期。
        expiresAt: DateTime(2026, 9, 17, 11, 59),
      );

      expect(
        () => service.loginBySmsCode(verification: stale),
        throwsA(isA<AuthException>()),
      );
    });

    test('凭证为空串被拒（形制校验，不是真伪校验）', () async {
      final emptyToken = SmsVerification(
        phone: '13800000001',
        token: '',
        purpose: SmsPurpose.login,
        expiresAt: DateTime(2026, 9, 17, 12, 5),
      );

      expect(
        () => service.loginBySmsCode(verification: emptyToken),
        throwsA(isA<AuthException>()),
      );
    });

    test('重置密码走的是和注册同一套强度校验', () async {
      final verification = await service.verifySmsCode(
        phone: '13800000001',
        code: '123456',
        purpose: SmsPurpose.resetPassword,
      );

      // 'abc' 是弱口令：长度不够、也没有数字。
      await expectLater(
        () => service.resetPasswordBySmsCode(
          verification: verification,
          newPassword: 'abc',
        ),
        throwsA(isA<AuthException>()),
      );
      expect(db.users.first['password'], _originalPassword);
    });

    test('失败原因带得出「等多久」，而不是只有一句文案', () async {
      gateway.failure = const SmsException(
        SmsFailureKind.rateLimited,
        '请求过于频繁，请稍后再试',
        retryAfterSeconds: 30,
      );

      expect(
        () => service.verifySmsCode(
          phone: '13800000001',
          code: '123456',
          purpose: SmsPurpose.login,
        ),
        throwsA(
          isA<SmsException>()
              .having(
                (error) => error.kind,
                'kind',
                SmsFailureKind.rateLimited,
              )
              .having(
                (error) => error.retryAfterSeconds,
                'retryAfterSeconds',
                30,
              ),
        ),
      );
    });

    test('号码格式 / 空验证码在本地就拦下，不发请求', () async {
      await expectLater(
        () => service.verifySmsCode(
          phone: '138',
          code: '123456',
          purpose: SmsPurpose.login,
        ),
        throwsA(isA<AuthException>()),
      );
      await expectLater(
        () => service.verifySmsCode(
          phone: '13800000001',
          code: '   ',
          purpose: SmsPurpose.login,
        ),
        throwsA(isA<AuthException>()),
      );
      expect(gateway.verifyCalls, 0);
    });
  });

  group('密码时间戳：本期就写，别等改密功能上线才补', () {
    test('注册时写入 passwordUpdatedAt', () async {
      final db = _MemoryAuthDataSource();
      final service = AuthService(database: db, now: _clock);

      final user = await service.register(
        phone: '13900000009',
        password: 'pass123',
        role: 'student',
      );

      expect(user.hasPassword, isTrue);
      expect(user.passwordUpdatedAt, DateTime(2026, 9, 17, 12));
    });

    test('微信建号刻意不写（语义是「从未设置过密码」）', () async {
      final db = _MemoryAuthDataSource();
      final service = AuthService(database: db, now: _clock);

      final user = await service.loginByWechat(role: 'student');

      expect(user.hasPassword, isFalse);
      expect(user.hasPhone, isFalse);
      expect(user.passwordUpdatedAt, isNull);
    });
  });

  group('界面入口：留出来并标注，而不是藏起来', () {
    testWidgets('登录页保留验证码登录入口并标注未开通', (tester) async {
      await tester.pumpWidget(const EasyLearnApp());

      // 藏起来的结果是接入那天没人记得它存在。
      expect(find.text('验证码登录（未开通）'), findsOneWidget);
      expect(find.text('忘记密码'), findsOneWidget);
    });

    testWidgets('点「忘记密码」进预留页，页面说清为什么现在用不了', (tester) async {
      await tester.pumpWidget(const EasyLearnApp());
      final entry = find.text('忘记密码');
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();

      expect(find.textContaining('短信服务尚未接入'), findsOneWidget);

      // 未接入时按钮必须真的是禁用的：
      // 「能点但点了没反应」比「灰着」糟糕得多 —— 用户会一直点。
      final sendButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '获取验证码'),
      );
      expect(sendButton.onPressed, isNull);

      final submitButton = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, '重置密码'),
      );
      expect(submitButton.onPressed, isNull);
    });

    testWidgets('验证码登录页同样带说明横幅', (tester) async {
      await tester.pumpWidget(const EasyLearnApp());
      // 登录卡片比默认的 600px 测试视口高，入口在折叠线以下 ——
      // 真机上也要滑一下才看得到，所以这里必须 ensureVisible 再点。
      final entry = find.text('验证码登录（未开通）');
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();

      expect(find.textContaining('短信服务尚未接入'), findsOneWidget);
      final submitButton = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, '验证码登录'),
      );
      expect(submitButton.onPressed, isNull);
    });
  });
}

const _originalPassword = 'abc123';
const _originalPasswordAt = '2026-08-18T09:00:00.000';

/// 注入时钟。测试涉及时间一律注入，见 `AuthService` 的 `now` 参数。
DateTime _clock() => DateTime(2026, 9, 17, 12);
SmsVerification _verification(SmsPurpose purpose) => SmsVerification(
  phone: '13800000001',
  token: 'tok_${purpose.code}',
  purpose: purpose,
  // 注入时钟是 12:00，五分钟有效期。
  expiresAt: DateTime(2026, 9, 17, 12, 5),
);

class _MemoryAuthDataSource implements AuthDataSource {
  final users = <Map<String, dynamic>>[
    {
      'id': 'stu_001',
      'name': '林小宇',
      'phone': '13800000001',
      'role': 'student',
      'avatar': 'student',
      'password': _originalPassword,
      'wechatOpenId': null,
      'passwordUpdatedAt': _originalPasswordAt,
    },
  ];

  @override
  Future<Map<String, dynamic>?> findUserByPhone(String phone) async {
    for (final user in users) {
      if (user['phone'] == phone) return Map<String, dynamic>.from(user);
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>?> findUserByWechat(String openId) async {
    for (final user in users) {
      if (user['wechatOpenId'] == openId) {
        return Map<String, dynamic>.from(user);
      }
    }
    return null;
  }

  @override
  Future<void> saveUser(Map<String, dynamic> user) async {
    users.add(Map<String, dynamic>.from(user));
  }

  @override
  Future<void> updatePassword({
    required String userId,
    required String newPassword,
    required String updatedAt,
  }) async {
    for (final user in users) {
      if (user['id'] == userId) {
        user['password'] = newPassword;
        user['passwordUpdatedAt'] = updatedAt;
        return;
      }
    }
    throw StateError('用户不存在：$userId');
  }
}

/// 一个「已接入」的假网关：**只用于证明业务代码不需要改**。
///
/// 它刻意不放在 lib 下 —— 真实现里绝不允许出现「本地把码比出来」这段逻辑。
class _FakeSmsGateway implements SmsGateway {
  /// 收到的校验请求次数，用来断言「本地能拦下的不该发请求」。
  int verifyCalls = 0;

  /// 让某一次校验按指定原因失败。
  SmsException? failure;

  @override
  bool get isConfigured => true;

  @override
  Future<SmsSendResult> sendVerificationCode({
    required String phone,
    required SmsPurpose purpose,
  }) async {
    return const SmsSendResult.sent(retryAfterSeconds: 45);
  }

  @override
  Future<SmsVerification> verifyCode({
    required String phone,
    required String code,
    required SmsPurpose purpose,
  }) async {
    verifyCalls += 1;
    final forced = failure;
    if (forced != null) throw forced;
    if (code != '123456') {
      throw const SmsException(
        SmsFailureKind.invalidCode,
        '验证码不正确或已过期',
      );
    }
    return SmsVerification(
      phone: phone,
      token: 'tok_${purpose.code}',
      purpose: purpose,
      expiresAt: DateTime(2026, 9, 17, 12, 5),
    );
  }
}
