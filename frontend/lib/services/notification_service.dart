import '../models/notification_model.dart';

class NotificationService {
  static List<AppNotificationModel> mockNotifications() {
    final now = DateTime.now();
    return [
      AppNotificationModel(
        id: 'n_001',
        title: '作业提醒',
        body: '数学作业还未完成，距离截止时间仅剩 2 小时。',
        createdAt: now,
        isRead: false,
      ),
      AppNotificationModel(
        id: 'n_002',
        title: '复习完成',
        body: '英语单词复习已完成并记录在错题库中。',
        createdAt: now.subtract(const Duration(hours: 3)),
        isRead: true,
      ),
    ];
  }
}
