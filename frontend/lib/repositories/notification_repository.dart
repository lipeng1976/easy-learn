import '../models/daily_comment_model.dart';
import '../models/notification_model.dart';

/// 通知与每日点评的数据访问契约（L2）。
///
/// ## ⚠️ 通知是**唯一一个「照现在的形态上云，功能直接不成立」**的领域
///
/// 现在的通知是**哪台设备显示、就由哪台设备生成**：
/// `NotificationController.addNotification` 把通知写进**本机**的库
/// （`database_service.dart:3913`）。
///
/// 单机演示下这是通的——学生提交作业后家长确实能看到，因为**两个角色共用同一个库**。
/// 换成两台手机后，学生手机写进的通知在家长手机上**根本不存在**，
/// `targetUserId` 填得再准也换不来一条记录。这不是配置问题，
/// 是「通知的产生位置错了」。
///
/// **上云后必然要改成：服务端在事件发生时生成通知（提交作业 / 批改完成 /
/// 打卡 / 心愿申请…），客户端只读。** 到那时 [insertNotification] 会退化成
/// 服务端内部调用，客户端侧甚至不该暴露这个能力——现在留着它只是为了本地实现自洽。
abstract class NotificationRepository {
  /// 新增通知。
  ///
  /// [AppNotificationModel.targetUserId] 留空表示**广播**（所有角色可见），
  /// 非空表示只发给该用户。这个「空串 = 广播」的约定由
  /// `AppNotificationModel.isVisibleTo` 判定，读端与写端必须一致。
  ///
  /// 见类注释：上云后本方法不应由客户端调用。
  Future<void> insertNotification(AppNotificationModel notification);

  /// 标记已读。
  ///
  /// **本方法只按 id 改 `isRead`，不校验调用者身份**。
  /// 服务端实现必须补上「这条通知是发给你的」，否则改包就能把别人的通知标已读
  /// （症状很隐蔽：别人的红点自己消失了）。
  Future<void> markNotificationRead(String id);

  /// 把**当前用户能看见的**未读通知一次全标已读。
  ///
  /// 为什么要有它，而不是在控制器里循环调 [markNotificationRead]：
  /// 云端一次调用就是一次 HTTP。几十条未读会变成几十个串行请求，
  /// 家长点一下要转好几秒 —— 而且中途失败会留下一半已读、一半没读的状态。
  ///
  /// 可见范围必须由实现自己定：本地按 [queryNotifications] 同一套
  /// `isVisibleTo` 规则筛；服务端按 token 推导（`target_user_id = 我` 或广播）。
  /// **不接受调用方传入 id 列表** —— 那等于让客户端决定能标记谁的通知。
  ///
  /// [userId] 与 [queryNotifications] 同构：本地实现靠它筛「这个人看得见的」，
  /// 云端实现**刻意忽略**（收件人由 token 决定，客户端传什么都没用）。
  ///
  /// 返回实际被标记的条数（用于界面反馈）。
  Future<int> markAllNotificationsRead({String? userId});

  /// 取 [userId] 可见的通知（本人专属 + 广播），按时间倒序。
  ///
  /// ## 两个必须改掉的地方
  ///
  /// 1. **过滤发生在内存里，不在查询里**：当前实现先取全表
  ///    （`_queryAllNotifications` 无 where），再按 `isVisibleTo` 过滤。
  ///    上云后这就是「每个客户端拉走全库通知，含别人的专属通知」——
  ///    既浪费带宽，也是越权。必须下推成服务端条件。
  /// 2. **`userId` 为空时返回全部**（为了兼容「登录前/无身份」场景）。
  ///    服务端**不应保留**这个分支：没有身份就不该拿到任何人的通知。
  ///
  /// ## 另有一处只在多用户下才暴露的缺陷（本次刻意不改）
  ///
  /// 广播通知（`targetUserId == ''`）**只有一列 `isRead`**，而广播行是
  /// 所有角色共用的**同一行**。所以：**学生点掉一条广播，家长端的未读数也一起消失**。
  /// 单机演示（两角色同库）下这个缺陷已经存在，只是不容易被注意到。
  ///
  /// 正解是**每用户一份已读状态**（`notification_read(userId, notificationId)`
  /// 关联表），而不是把 `isRead` 放在通知行上。上云时必须一并改掉——
  /// 否则多设备下「谁看过了」永远是错的。
  Future<List<AppNotificationModel>> queryNotifications({String? userId});

  /// 新增一条每日点评（家长写给孩子的）。
  ///
  /// `DailyCommentModel.studentId` 记录这条点评是写给谁的；
  /// 身份归属靠它，不靠调用者。
  Future<void> insertDailyComment(DailyCommentModel comment);

  /// 取全部点评，按时间倒序，**无过滤**。
  ///
  /// 调用方（`ParentController`）拿到后自己按 `studentId` 过滤成
  /// 「我结对的孩子」。上云后必须在服务端按「家长 ↔ 结伴孩子」过滤，
  /// 否则家长会读到别人家孩子的点评。
  Future<List<DailyCommentModel>> queryDailyComments();
}
