import 'dart:io';

import 'package:easy_learn_app/models/notification_model.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/db_test_helper.dart';

/// 「全部已读」在**本地真库**上的行为。
///
/// 为什么要跑真 SQLite 而不只是假仓库：这一层真正会错的地方是「update 了谁」。
/// 单机上家长和学生共用一个库，`update app_notification set isRead = 1`
/// 不带条件的话会把**学生专属的通知**一起标掉 —— 而这件事没有任何报错，
/// 只是孩子的红点莫名其妙消失了。假仓库复刻不出这条。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await setUpTestDatabase();
  });

  tearDown(() async {
    await tearDownTestDatabase(dir);
  });

  Future<void> seed(String id, {required String target}) async {
    await DatabaseService.instance.insertNotification(
      AppNotificationModel(
        id: id,
        title: '标题 $id',
        body: '内容 $id',
        createdAt: DateTime(2026, 11, 16, 20),
        isRead: false,
        // 用未来时间保证排在最前，不与演示数据混在一起判断。
        targetUserId: target,
        type: NotificationType.system,
      ),
    );
  }

  Future<Map<String, bool>> readStates(List<String> ids) async {
    final all = await DatabaseService.instance.queryNotifications();
    return {
      for (final item in all)
        if (ids.contains(item.id)) item.id: item.isRead,
    };
  }

  /// 这个人当前有幾条未读。
  ///
  /// ⚠️ 不用固定数字断言：演示种子库里本来就有未读通知，写死「应该是 2」
  /// 会把「种子数据多了一条」误报成「批量标记坏了」。
  Future<int> unreadCountFor(String userId) async {
    final visible = await DatabaseService.instance.queryNotifications(
      userId: userId,
    );
    return visible.where((n) => !n.isRead).length;
  }

  test('只标「这个人看得见的」，别人的专属通知不动', () async {
    const mine = 'n_test_mine';
    const broadcast = 'n_test_broadcast';
    const others = 'n_test_others';
    await seed(mine, target: 'user_parent');
    await seed(broadcast, target: '');
    await seed(others, target: 'user_student');

    final before = await unreadCountFor('user_parent');
    final marked = await DatabaseService.instance.markAllNotificationsRead(
      userId: 'user_parent',
    );

    expect(marked, before);
    expect(before, greaterThanOrEqualTo(2));

    final states = await readStates([mine, broadcast, others]);
    expect(states[mine], isTrue);
    expect(states[broadcast], isTrue);
    // 这条是孩子的专属通知：家长点「全部已读」不该顺手把它标掉。
    expect(states[others], isFalse);
  });

  test('重复调用不会重复计数（已读的不再算）', () async {
    const mine = 'n_test_mine2';
    await seed(mine, target: 'user_parent');

    final first = await DatabaseService.instance.markAllNotificationsRead(
      userId: 'user_parent',
    );
    expect(first, greaterThanOrEqualTo(1));
    // 第一次之后，这个人名下不该再有未读。
    expect(await unreadCountFor('user_parent'), 0);

    // 第二次没有可标记的行 —— 这条是幂等的真正判据。
    expect(
      await DatabaseService.instance.markAllNotificationsRead(
        userId: 'user_parent',
      ),
      0,
    );
  });
}
