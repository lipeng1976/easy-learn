/// 通知的业务类型，用于列表图标与点击跳转。
enum NotificationType {
  homework('作业', 'assignment'),
  workout('运动', 'sports'),
  review('复习', 'menu_book'),
  studyPlan('学习计划', 'event_note'),
  wish('心愿', 'favorite'),
  dailyComment('家长点评', 'rate_review'),

  /// 结伴关系本身的通知（目前只有一种：家长解除结伴）。
  ///
  /// ⚠️ 它**不参与** `notifications_page.dart` 里那两个「类型 → 页签」的跳转
  /// （两处都落到 `_ => null`，只标已读）。这是有意的：学生端没有「结伴」这个 tab，
  /// 硬塞一个最接近的落点（比如心愿）会让他点进去看到一堆无关的东西。
  /// 真要直达得加一条到 `/binding` 的独立路由 —— 目前那句话在通知正文里已经说清了。
  relationship('结伴', 'link'),
  system('系统', 'notifications');

  const NotificationType(this.label, this.iconName);

  final String label;
  final String iconName;

  static NotificationType parse(String? raw) {
    for (final value in NotificationType.values) {
      if (value.name == raw) return value;
    }
    return NotificationType.system;
  }
}

class AppNotificationModel {
  final String id;
  final String title;
  final String body;
  final DateTime createdAt;
  final bool isRead;

  /// 通知归属人。为空表示「广播给所有人」（历史数据与系统消息）。
  ///
  /// 旧实现里通知表没有任何归属字段，学生端和家长端看到的是同一个列表，
  /// 于是「孩子提交了作业」这条通知会同时出现在孩子自己的消息中心里。
  final String targetUserId;

  final NotificationType type;

  /// 关联业务ID（作业ID / 计划ID / 心愿ID），点击通知可直达详情。
  final String relatedBizId;

  AppNotificationModel({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.isRead,
    this.targetUserId = '',
    this.type = NotificationType.system,
    this.relatedBizId = '',
  });

  /// 是否是发给指定用户的。空 targetUserId 视为广播。
  bool isVisibleTo(String userId) =>
      targetUserId.isEmpty || targetUserId == userId;

  AppNotificationModel copyWith({
    String? id,
    String? title,
    String? body,
    DateTime? createdAt,
    bool? isRead,
    String? targetUserId,
    NotificationType? type,
    String? relatedBizId,
  }) {
    return AppNotificationModel(
      id: id ?? this.id,
      title: title ?? this.title,
      body: body ?? this.body,
      createdAt: createdAt ?? this.createdAt,
      isRead: isRead ?? this.isRead,
      targetUserId: targetUserId ?? this.targetUserId,
      type: type ?? this.type,
      relatedBizId: relatedBizId ?? this.relatedBizId,
    );
  }
}
