import 'package:easy_learn_app/controllers/notification_controller.dart';
import 'package:easy_learn_app/models/daily_comment_model.dart';
import 'package:easy_learn_app/models/notification_model.dart';
import 'package:easy_learn_app/pages/shared/notifications_page.dart';
import 'package:easy_learn_app/repositories/notification_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 消息通知的「全部已读」。
///
/// 守两件事，两件都不会报错、只会表现为「点了没反应」：
///
///  1. **一次请求**，不是循环单条（本地库上看不出来，云端就是几十个串行 HTTP）；
///  2. 失败要**回滚内存**并如实返回 false —— 否则界面显示「已全部已读」，
///     库里一条没改，下次进来红点原样回来。
///
/// 页面侧守按钮显隐：未读为 0 时还留着按钮，点一下什么都不发生。

class _FakeNotificationRepo implements NotificationRepository {
  _FakeNotificationRepo({required this.items, this.failMarkAll = false});

  final List<AppNotificationModel> items;
  final bool failMarkAll;

  int markAllCalls = 0;
  int markOneCalls = 0;

  @override
  Future<List<AppNotificationModel>> queryNotifications({String? userId}) async =>
      List.of(items);

  @override
  Future<void> insertNotification(AppNotificationModel notification) async {}

  @override
  Future<void> markNotificationRead(String id) async {
    markOneCalls += 1;
  }

  @override
  Future<int> markAllNotificationsRead({String? userId}) async {
    markAllCalls += 1;
    if (failMarkAll) throw StateError('network down');
    var marked = 0;
    for (var i = 0; i < items.length; i++) {
      if (!items[i].isRead) {
        items[i] = items[i].copyWith(isRead: true);
        marked += 1;
      }
    }
    return marked;
  }

  @override
  Future<void> insertDailyComment(DailyCommentModel comment) async {}

  @override
  Future<List<DailyCommentModel>> queryDailyComments() async => const [];
}

AppNotificationModel _notice(String id, {bool read = false}) {
  return AppNotificationModel(
    id: id,
    title: '标题 $id',
    body: '内容 $id',
    createdAt: DateTime(2026, 11, 16, 20),
    isRead: read,
    type: NotificationType.system,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  tearDown(() {
    if (Get.isRegistered<NotificationController>()) {
      Get.delete<NotificationController>(force: true);
    }
  });

  group('控制器', () {
    test('一次批量调用，不是逐条循环', () async {
      final repo = _FakeNotificationRepo(
        items: [_notice('a'), _notice('b'), _notice('c')],
      );
      final controller = NotificationController(database: repo);
      await controller.loadNotifications();
      expect(controller.unreadCount, 3);

      final ok = await controller.markAllAsRead();

      expect(ok, isTrue);
      expect(repo.markAllCalls, 1);
      // 逐条循环会把 markOneCalls 顶到 3 —— 那正是本次要防的写法。
      expect(repo.markOneCalls, 0);
      expect(controller.unreadCount, 0);
      expect(controller.notifications.every((n) => n.isRead), isTrue);
    });

    test('仓库失败时回滚内存，并把 false 交回去', () async {
      final repo = _FakeNotificationRepo(
        items: [_notice('a'), _notice('b')],
        failMarkAll: true,
      );
      final controller = NotificationController(database: repo);
      await controller.loadNotifications();

      final ok = await controller.markAllAsRead();

      expect(ok, isFalse);
      // 不回滚的话这里会是 0，而库里还是两条未读 —— 界面说了谎。
      expect(controller.unreadCount, 2);
    });

    test('没有未读时不发请求', () async {
      final repo = _FakeNotificationRepo(items: [_notice('a', read: true)]);
      final controller = NotificationController(database: repo);
      await controller.loadNotifications();

      final ok = await controller.markAllAsRead();

      expect(ok, isTrue);
      expect(repo.markAllCalls, 0);
    });
  });

  group('页面', () {
    Future<NotificationController> pump(
      WidgetTester tester,
      _FakeNotificationRepo repo,
    ) async {
      final controller = NotificationController(database: repo);
      Get.put(controller, permanent: true);
      await controller.loadNotifications();
      await tester.pumpWidget(
        const GetMaterialApp(home: NotificationsPage()),
      );
      await tester.pump();
      return controller;
    }

    testWidgets('有未读时出现「全部已读」，点一下清零', (tester) async {
      final repo = _FakeNotificationRepo(items: [_notice('a'), _notice('b')]);
      final controller = await pump(tester, repo);

      expect(find.text('全部已读'), findsOneWidget);
      expect(find.text('2 未读'), findsOneWidget);

      await tester.tap(find.text('全部已读'));
      await tester.pumpAndSettle();

      expect(repo.markAllCalls, 1);
      expect(controller.unreadCount, 0);
      expect(find.text('0 未读'), findsOneWidget);
      // 清零后按钮自己消失 —— 留着它只会让人点一下、然后什么都没有发生。
      expect(find.text('全部已读'), findsNothing);
      expect(find.text('已全部标为已读'), findsOneWidget);
    });

    testWidgets('全部已读时没有按钮', (tester) async {
      final repo = _FakeNotificationRepo(items: [_notice('a', read: true)]);
      await pump(tester, repo);

      expect(find.text('全部已读'), findsNothing);
      expect(find.text('0 未读'), findsOneWidget);
    });
  });
}
