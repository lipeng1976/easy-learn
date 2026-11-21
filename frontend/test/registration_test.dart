import 'package:easy_learn_app/services/auth_data_source.dart';
import 'package:easy_learn_app/services/auth_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registers a student account with phone, password, and role', () async {
    final source = _MemoryAuthDataSource();
    final service = AuthService(database: source);

    final user = await service.register(
      phone: '13900000001',
      password: 'pass123',
      role: 'student',
    );

    expect(user.phone, '13900000001');
    expect(user.role, 'student');
    expect(source.savedUsers.single['password'], 'pass123');
  });

  test('rejects duplicate phone numbers', () async {
    final source = _MemoryAuthDataSource();
    final service = AuthService(database: source);

    await service.register(
      phone: '13900000002',
      password: 'pass123',
      role: 'parent',
    );

    expect(
      () => service.register(
        phone: '13900000002',
        password: 'pass456',
        role: 'student',
      ),
      throwsA(isA<AuthException>()),
    );
  });

  test('rejects invalid registration fields', () async {
    final service = AuthService(database: _MemoryAuthDataSource());

    expect(
      () => service.register(phone: '123', password: 'abc', role: 'student'),
      throwsA(isA<AuthException>()),
    );
  });
}

class _MemoryAuthDataSource implements AuthDataSource {
  final List<Map<String, dynamic>> savedUsers = [];

  @override
  Future<Map<String, dynamic>?> findUserByPhone(String phone) async {
    for (final user in savedUsers) {
      if (user['phone'] == phone) return Map<String, dynamic>.from(user);
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>?> findUserByWechat(String openId) async => null;

  @override
  Future<void> saveUser(Map<String, dynamic> user) async {
    savedUsers.add(Map<String, dynamic>.from(user));
  }

  @override
  Future<void> updatePassword({
    required String userId,
    required String newPassword,
    required String updatedAt,
  }) async {
    for (final user in savedUsers) {
      if (user['id'] == userId) {
        user['password'] = newPassword;
        user['passwordUpdatedAt'] = updatedAt;
        return;
      }
    }
    throw StateError('用户不存在：$userId');
  }
}
