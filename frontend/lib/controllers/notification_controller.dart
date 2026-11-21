import 'package:get/get.dart';

import 'auth_controller.dart';
import '../models/notification_model.dart';
import '../repositories/notification_repository.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';

class NotificationController extends GetxController {
  /// 数据源。默认走本地库 —— **换云端实现时只改这一处默认值**。
  NotificationController({NotificationRepository? database})
    : _database = database ?? DatabaseService.instance;

  final NotificationRepository _database;

  /// 当前用户可见的通知（本人专属 + 广播），按时间倒序。
  final RxList<AppNotificationModel> notifications =
      <AppNotificationModel>[].obs;

  @override
  void onInit() {
    super.onInit();
    // 先用演示数据把列表填上：数据库读取是异步的，消息中心不该首帧空白。
    // 演示通知的 targetUserId 为空（广播），不会串到别的角色。
    notifications.value = NotificationService.mockNotifications()
        .where((n) => n.isVisibleTo(_currentUserId))
        .toList();
    loadNotifications();
  }

  /// 换账号时清空已加载的通知。
  ///
  /// 与 `PointController.resetForAccountSwitch` 同一个理由（见那里的说明）：
  /// 这个控制器注册在 `app.dart`，**不属于任何路由**，GetX 不会随首页回收它。
  /// 不清的话，下一个登录者在自己的通知拉回来之前，看到的是上一个人的列表 ——
  /// 而「列表里有内容」这件事本身会让人以为已经加载完了。
  void resetForAccountSwitch() {
    notifications.clear();
  }

  String get _currentUserId => Get.isRegistered<AuthController>()
      ? Get.find<AuthController>().currentUser.value?.id ?? ''
      : '';

  Future<void> loadNotifications() async {
    try {
      final stored = await _database.queryNotifications(userId: _currentUserId);
      notifications.value = stored;
    } catch (_) {
      // 数据库不可用（例如 Web 首次运行）时退化为演示数据，
      // 而不是让消息中心变成空白页。
      notifications.value = NotificationService.mockNotifications()
          .where((n) => n.isVisibleTo(_currentUserId))
          .toList();
    }
  }

  /// 新增通知。
  ///
  /// [targetUserId] 决定这条通知谁能看到：留空表示广播给所有角色。
  /// 学生提交作业时必须显式指定家长 ID，否则家长收不到，
  /// 学生自己反而会收到「你的孩子提交了作业」。
  Future<void> addNotification({
    required String title,
    required String body,
    String targetUserId = '',
    NotificationType type = NotificationType.system,
    String relatedBizId = '',
  }) async {
    final notification = AppNotificationModel(
      id: 'n_${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      body: body,
      createdAt: DateTime.now(),
      isRead: false,
      targetUserId: targetUserId,
      type: type,
      relatedBizId: relatedBizId,
    );

    // 只把当前用户看得见的通知插进内存列表，
    // 避免别的角色的通知先出现再被过滤掉造成闪烁。
    if (notification.isVisibleTo(_currentUserId)) {
      notifications.insert(0, notification);
    }
    await _safePersist(() => _database.insertNotification(notification));
  }

  Future<void> markAsRead(String id) async {
    final index = notifications.indexWhere((item) => item.id == id);
    if (index >= 0) {
      notifications[index] = notifications[index].copyWith(isRead: true);
      await _safePersist(() => _database.markNotificationRead(id));
    }
  }

  /// 全部标已读：**一次请求**，不是循环。
  ///
  /// 循环单条在本地库上没人看得出来，上云后就是几十个串行 HTTP ——
  /// 家长点一下要转好几秒，中途断网还会留下「一半已读」。
  ///
  /// 先乐观改内存、失败再整体回滚：不回滚的话界面会显示「全部已读」而库里
  /// 一条都没变，下次进来红点原样回来 —— 那是最讨厌的一种「界面说了谎」。
  /// 返回值给界面做反馈，**不要吞**。
  Future<bool> markAllAsRead() async {
    if (unreadCount == 0) return true;

    final snapshot = notifications.toList(growable: false);
    notifications.assignAll(
      notifications
          .map((item) => item.copyWith(isRead: true))
          .toList(growable: false),
    );

    try {
      await _database.markAllNotificationsRead(userId: _currentUserId);
      return true;
    } catch (_) {
      notifications.assignAll(snapshot);
      return false;
    }
  }

  int get unreadCount => notifications.where((item) => !item.isRead).length;

  Future<void> _safePersist(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {}
  }
}
