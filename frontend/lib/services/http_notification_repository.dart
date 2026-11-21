import '../models/daily_comment_model.dart';
import '../models/notification_model.dart';
import '../repositories/notification_repository.dart';
import 'data_api_client.dart';
import 'data_row_values.dart';

/// 通知与每日点评的**服务端实现**（`NotificationRepository` 的第二个实现）。
///
/// 本地那份在 `local_database_service.dart`。两者实现同一个契约，所以
/// `NotificationController` 一行都不用改 —— 这正是当初抽 L2 接口的目的。
///
/// ## 四处「照搬本地写法就会错」的地方
///
/// **① `insertNotification` 在云端根本没有对应端点。** 本地实现把通知写进
/// **本机**库；上云后通知改由服务端在事件发生时生成（`routes/notify.js` 的
/// `notifyBoundPartners`），客户端只负责读。`app.js` 的 ROUTES 里**刻意没有**
/// `POST /data/notifications` —— 让接口「不存在」比「存在但返回 403」更能表达
/// 「这件事不是客户端能做的」。见 `insertNotification` 的注释，那里是**静默忽略**
/// 并写清原因，不是漏写。
///
/// **② 已读不再读行上的 `is_read`。** 本地实现按 id 改行里那一列；服务端落到
/// `app_notification_read(user_id, notification_id)` 关联表 —— 这样「谁读过了」
/// 才在多设备下成立（广播行是所有角色共用的同一行，行上 `is_read` 会导致
/// 「学生点掉、家长端红点也消失」）。所以 `markNotificationRead` 打的是
/// `POST /data/notifications/read`，且服务端会先校验「这条通知是发给你的」，
/// 改个包不能把别人的通知标已读。
///
/// **③ `queryNotifications` 的过滤下推到了服务端。** 本地是「取全表再内存过滤」，
/// 上云后那就是「每个客户端拉走全库通知（含别人的）」——越权。服务端按 token
/// 推导可见范围。契约签名里那个 `userId` 参数**云端没有可信来源**（身份来自
/// token），所以这里**一概不读**它；而且 `userId` 为空时「返回全部」这个本地分支
/// 服务端**刻意不保留**（没有身份就不该拿到任何人的通知，由 RLS fail-closed 兜住）。
///
/// **④ `queryDailyComments` 不再是「全部、无过滤」。** 本地靠 `ParentController`
/// 拿到后自己按 `studentId` 筛；上云后那等于「家长会读到别人家孩子的点评」。
/// 服务端按「家长 ↔ 结伴孩子」下推过滤（SQL 里的 `student_id = ANY(ctx.students)`）。
class HttpNotificationRepository implements NotificationRepository {
  HttpNotificationRepository(this._api);

  final DataApiClient _api;

  /// 静默忽略：云端不存在「客户端生成通知」这一步。
  ///
  /// 见 `routes/notify.js` 文件头与契约类注释：通知由服务端在事件发生时生成
  /// （提交作业 / 批改 / 点评…），`insertNotification` 在本地实现里是「写进本机库」，
  /// 上云后这一动作整体消失，路由表里也没有 `POST /data/notifications`。
  ///
  /// 这里**不抛错**也不假装发出 —— 调用方 `NotificationController.addNotification`
  /// 的语义在云端已不成立，但让它因为「没有这个能力」而抛异常，会让上层以为
  /// 「通知存储失败」，而真实情况是「这件事本就不该由客户端做」。让通知存储「失败」
  /// 比让它「静默成功」更糟：前者会让上层逻辑在每次提交/批改后都走错误处理分支。
  ///
  /// 真正需要通知的地方，改走服务端事件（`notifyBoundPartners`），客户端只负责
  /// 读（`queryNotifications` / `markNotificationRead`）。若将来要支持「用户手动
  /// 发通知」之类，需要新增端点，而非复活这个方法。
  @override
  Future<void> insertNotification(AppNotificationModel notification) async {
    // 故意留空：不是漏实现，而是云端没有对应的能力（端点根本不存在）。
  }

  /// 标记已读。
  ///
  /// 打 `POST /data/notifications/read`，body 只带 `id`。服务端自己把
  /// 「当前用户」写进 `app_notification_read`，并先校验这条通知对你是可见的
  /// （不可见的 id 会拿 `forbidden` 回绝，而不是默默塞一行垃圾已读记录）。
  /// 返回值里的 `marked` / `read` 我们这里用不到（契约是 `void`），不解析，
  /// 但**不吞**异常：校验失败该冒泡就冒泡。
  @override
  Future<void> markNotificationRead(String id) async {
    await _api.postJson('/data/notifications/read', body: {'id': id});
  }

  /// 全部标记已读：一次请求搞定。
  ///
  /// [userId] **一概不传** —— 能与不能标，由服务端按 token 推导；
  /// 客户端传个 id 就能标别人的通知，那正是 `markNotificationRead` 注释里
  /// 说的那个漏洞的批量版。
  ///
  /// 服务端返回 `{marked: n}`，n 是本次实际写入的条数（已经在已读表里的
  /// 不计入）。解析失败时回 0 而不是抛错：这一次点击的**结果**已经发生了，
  /// 让界面因为「数不出来」再弹一次失败，等于把成功报成失败。
  @override
  Future<int> markAllNotificationsRead({String? userId}) async {
    final data = await _api.postJson(
      '/data/notifications/read-all',
      body: const <String, Object?>{},
    );
    return (data['marked'] as num?)?.toInt() ?? 0;
  }

  /// 取当前用户可见的通知（本人专属 + 广播），按时间倒序。
  ///
  /// [userId] 被**刻意忽略**：收件人只能是 token 里的那个人，否则改个包就能读
  /// 别人的通知。可见范围完全由服务端按 token 推导，客户端传什么都没用。
  /// 服务端返回的 `isRead` 已经是「**我**读过了」（来自 `app_notification_read`
  /// 的 JOIN），不是行上的历史列，所以直接 `boolOf` 即可。
  @override
  Future<List<AppNotificationModel>> queryNotifications({String? userId}) async {
    final items = await _api.getItems('/data/notifications');
    return items.map(_fromRow).toList();
  }

  /// 新增一条每日点评（家长写给孩子的）。
  ///
  /// [DailyCommentModel.id] / [DailyCommentModel.studentId] / [DailyCommentModel.createdAt]
  /// 一律由服务端定：`id` 服务端生成、`createdAt` 是记录时间（R3）、`studentId` 决定
  /// 归属且必须落在当前用户的可见集合里（越界会被服务端 400/403 拒掉）。
  /// 所以这里只上行 `rating` / `content` / `studentId` 三项，绝不代传 `id` 与 `createdAt`
  /// —— 原样转发 `toMap()` 会多出服务端不认的字段，得到一次 400。
  @override
  Future<void> insertDailyComment(DailyCommentModel comment) async {
    await _api.postJson('/data/daily-comments', body: {
      'rating': comment.rating,
      'content': comment.content,
      'studentId': comment.studentId,
    });
  }

  /// 取点评，按时间倒序。
  ///
  /// 注意：服务端**已经按「我结伴的孩子」过滤**了（`student_id = ANY(ctx.students)`），
  /// 不再像本地那样「全部拉回来再内存筛」。所以这里拿到的就是我能看的那部分，
  /// 直接映射即可，不要再按 `studentId` 二次过滤 —— 那样只会把别人家孩子之外的
  /// 一部分也误删（本地那份靠调用方过滤，云端那份靠服务端，二者语义在此处不同）。
  @override
  Future<List<DailyCommentModel>> queryDailyComments() async {
    final items = await _api.getItems('/data/daily-comments');
    return items.map(_dailyCommentFromRow).toList();
  }

  /// 服务端的通知行 → [AppNotificationModel]。
  ///
  /// 与本地 `_notificationFromMap` 形状一致，差别只在**取值方式**：布尔认
  /// `true/false`、时间要从 UTC 转到本地时区。`targetUserId` 空串即广播，
  /// 由 `isVisibleTo` 的约定决定，这里原样取即可。
  AppNotificationModel _fromRow(Map<String, dynamic> row) {
    return AppNotificationModel(
      id: textOf(row['id']),
      title: textOf(row['title']),
      body: textOf(row['body']),
      // 服务端给带 Z 的 UTC，不转会差一个时区（界面上「今晚 8 点的通知」变「中午」）。
      createdAt: timeOr(row['createdAt'], DateTime.now()),
      // 已是「我读过了」的语义，直接取布尔即可。
      isRead: boolOf(row['isRead']),
      // 空串 = 广播，原样保留；模型里 `isVisibleTo` 负责解释。
      targetUserId: textOf(row['targetUserId']),
      // 服务端用的就是展示域字符串（homework/review/…），与枚举逐字对齐；
      // 对不上会静默回落到 system（只是图标变铃铛），不会报错。
      type: NotificationType.parse(row['type'] as String?),
      relatedBizId: textOf(row['relatedBizId']),
    );
  }

  DailyCommentModel _dailyCommentFromRow(Map<String, dynamic> row) {
    return DailyCommentModel(
      id: textOf(row['id']),
      rating: textOf(row['rating']),
      content: textOf(row['content']),
      createdAt: timeOr(row['createdAt'], DateTime.now()),
      studentId: textOf(row['studentId']),
    );
  }
}
