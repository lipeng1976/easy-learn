import 'package:easy_learn_app/services/auth_service.dart';
import 'package:easy_learn_app/services/auth_data_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AuthService', () {
    final service = AuthService(database: _FakeAuthDataSource());

    test('logs in seeded student by phone and password', () async {
      final user = await service.loginByPhone(
        phone: '13800000001',
        password: 'abc123',
        role: 'student',
      );

      expect(user.id, 'stu_001');
      expect(user.role, 'student');
    });

    test('rejects invalid phone credentials', () async {
      expect(
        () => service.loginByPhone(
          phone: '13800000001',
          password: 'wrong-password',
          role: 'student',
        ),
        throwsA(isA<AuthException>()),
      );
    });

    test('supports mock WeChat login through the same auth service', () async {
      final user = await service.loginByWechat(role: 'parent');

      expect(user.role, 'parent');
      expect(user.id, 'par_001');
    });
  });
}

class _FakeAuthDataSource implements AuthDataSource {
  final users = <Map<String, dynamic>>[
    {
      'id': 'stu_001',
      'name': '林小宇',
      'phone': '13800000001',
      'role': 'student',
      'avatar': 'student',
      'password': 'abc123',
      'wechatOpenId': null,
    },
    {
      'id': 'par_001',
      'name': '王老师',
      'phone': '13800000002',
      'role': 'parent',
      'avatar': 'parent',
      'password': 'abc123',
      'wechatOpenId': 'mock-wechat-parent',
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
