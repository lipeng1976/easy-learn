import 'package:easy_learn_app/controllers/notification_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('notification controller tracks unread count and mark-as-read', () {
    final controller = NotificationController();
    controller.onInit();

    expect(controller.notifications.length, greaterThanOrEqualTo(1));
    expect(controller.unreadCount, greaterThan(0));

    final firstId = controller.notifications.first.id;
    controller.markAsRead(firstId);

    expect(
      controller.notifications.firstWhere((item) => item.id == firstId).isRead,
      isTrue,
    );
    expect(
      controller.unreadCount,
      controller.notifications.where((item) => !item.isRead).length,
    );
  });
}
