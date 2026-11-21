import '../models/chat_message_model.dart';
import '../models/relationship_model.dart';
import '../repositories/relationship_repository.dart';
import 'data_api_client.dart';
import 'data_row_values.dart';
import 'wire_status.dart';

/// 结伴关系与聊天的**服务端实现**（`RelationshipRepository` 的第二个实现）。
///
/// 本地那份在 `local_database_service.dart`。两者实现同一个契约，所以相关控制器
/// 一行都不用改 —— 这正是当初抽 L2 接口的目的。
///
/// ## 三处「照搬本地写法就会错」的地方
///
/// **① 身份来自 token，不在参数里。** 本地实现里 `senderId` 是你传什么就是什么
/// （单机同库下这没问题）。服务端从 token 推导身份，所以 `createRelationshipInvitation`
/// 的 `senderId`、`queryRelationships` 的 `userId` 在云端**一概不读** —— 留着只为
/// 让签名不变。硬要转发反而会错：服务端认 `ctx.userId` 为发送方，客户端以为能替别人
/// 发起邀请。
///
/// **② 名字曾经取不到，现在有了。** 2026-09-20 之前服务端 `listRelationships`
/// 只回 `id/studentId/parentId/senderId/status/createdAt`，不含名字，而模型这两个
/// 字段是 `required` —— 这里只能填空串，症状是**结伴成功、状态也对，界面上对方名字却是空的**，
/// 且不报任何错。现在服务端 LEFT JOIN 出 `studentName` / `parentName`
/// （配合 `sql/008_relationship_peer_name.sql` 放开「结伴对端」的读）。
///
/// 仍然可能是空串的两种情形，都属正常：
///   · `pending` 的邀请 —— 对方还没确认，按设计读不到名字；
///   · 本地实现 —— 它从本机库取名字，云端模式下本机没有对方那一行。
///
/// **③ 聊天曾经没有端点，现在有了（2026-09-22 补）。** 服务端一直有 `chat_message`
/// 表 / 索引 / RLS，**只缺路由**，这里只能抛 `not_implemented`。症状是云端模式下
/// 「伴学消息」这一页点发送**毫无反应** —— 而 `chat_page.dart` 当时也没接异常，
/// 于是异常被静默吞掉、输入框照样清空，用户以为发出去了。现在走
/// `GET/POST /data/chat/messages`（`serverless/data-service/src/routes/chat.js`）。
///
/// 补端点后仍要注意的两点：
///   · **`senderId` 一概不读**（同 ①），发送方由 token 决定；
///   · **收信人也不由客户端指定**，服务端按关系反推（我是学生就发给家长，反之亦然）——
///     否则可以把消息塞进一段与自己无关的对话里。
class HttpRelationshipRepository implements RelationshipRepository {
  HttpRelationshipRepository(this._api);

  final DataApiClient _api;

  /// 取我参与的全部关系（含 pending）。
  ///
  /// [userId] 被**刻意忽略**：可见范围由 token 推导（学生看自己、家长看自己待确认
  /// 的邀请也一并算上）。直接打 `GET /data/relationship`，服务端下推了
  /// `student_id = ANY(ctx.students) or parent_id = 我` 的过滤，不需要客户端传任何筛选。
  @override
  Future<List<RelationshipModel>> queryRelationships(String userId) async {
    final items = await _api.getItems('/data/relationship');
    return items.map(_fromRow).toList();
  }

  /// 发出结伴邀请。
  ///
  /// 只上行 `targetPhone`：发送方是谁由 token 决定，`senderId` **刻意忽略**（见类注释 ①）。
  /// 服务端拿到手机号后走 `lookupUserByPhone` 在鉴权连接上等值查找，再校验角色互补、
  /// 不重复结伴 —— 这些约束原本由本地实现承担，云端收归服务端。
  /// 返回的新关系行映射成 `RelationshipModel` 交回调用方（id 由服务端生成）。
  @override
  Future<RelationshipModel> createRelationshipInvitation({
    required String senderId,
    required String targetPhone,
  }) async {
    final data = await _api.postJson('/data/relationship/invite', body: {
      'targetPhone': targetPhone,
    });
    final rel = data['relationship'];
    if (rel is! Map) {
      // 协议保证返回 {relationship}，缺失即服务端 bug，不当空对象糊弄过去。
      throw DataApiException(code: 'bad_response', message: '结伴邀请未返回关系行');
    }
    return _fromRow(Map<String, dynamic>.from(rel));
  }

  /// 接受 / 拒绝邀请。
  ///
  /// body 只带 `id` 与 `status`。服务端只认 `active` / `rejected`（词表见
  /// `serverless/data-service/src/vocab.js`）；`pending` / `removed` 会被它 400 拒掉 ——
  /// 这正是我们想要的显式失败（契约语义本就是「接受 / 拒绝」），
  /// 不要在前端把枚举降级成别的再发。
  ///
  /// 2026-09-20 之前这里必须翻译（服务端叫 `accepted`、客户端叫 `active`），
  /// 现在两侧**逐字相同**，所以 `active` / `rejected` 直传即可。
  /// 留下的一层（[relationshipStatusToWire]）只为了拦住 `pending` / `removed`。
  @override
  Future<void> updateRelationshipStatus({
    required String id,
    required RelationshipStatus status,
  }) async {
    await _api.postJson('/data/relationship/status', body: {
      'id': id,
      'status': relationshipStatusToWire(status),
    });
  }

  /// 解除结伴（**家长单方，立即生效**）。
  ///
  /// body 只有 `id` —— **谁能解除由服务端按 token 判定**，客户端没有机会自报身份。
  /// 非家长账号会被 403 拒掉（文案「只有家长可以解除结伴」）。
  ///
  /// ⚠️ 走的是 `/revoke` 而**不是** `/status`：解除与「接受/拒绝」的前置状态
  /// 与权限都不同（`vocab.js: RELATIONSHIP_APPROVAL_STATUSES` 有对照表）。
  /// 所以这里也**不经过** [relationshipStatusToWire] —— 那个函数会为 `removed` 抛错。
  ///
  /// 返回 `void` 而不是新的关系行：调用方（`binding_page`）随后会整页重拉
  /// （`ProfileController.load`），从列表里拿到 `removed` 那一行。
  /// 把服务端返回的行塞回内存列表等于多出一份要维护的真相。
  @override
  Future<void> revokeRelationship({required String id}) async {
    await _api.postJson('/data/relationship/revoke', body: {'id': id});
  }

  /// 读一段会话。
  ///
  /// 取一段对话的消息。
  ///
  /// `requesterId` **刻意忽略**（同 ①）：服务端按 token 推导「我是谁」，
  /// 再校验我确实是这段关系的成员、且关系 `active` —— 两道校验都在服务端，
  /// 客户端这边无从绕过，这正是把端点放服务端的意义。
  @override
  Future<List<ChatMessageModel>> queryChatMessages({
    required String relationshipId,
    required String requesterId,
  }) async {
    final items = await _api.getItems(
      '/data/chat/messages',
      query: {'relationshipId': relationshipId},
    );
    return items.map(_chatFromRow).toList();
  }

  /// 发一条消息，返回**服务端存下来的那一行**。
  ///
  /// 上行只有 `relationshipId` + `content`：发送方由 token 定，**收信人由服务端
  /// 按关系反推**（我是学生就发给家长，反之亦然）。客户端连"想指定收信人"
  /// 的机会都没有 —— 那不是它能决定的事。
  ///
  /// 返回真行而不是 void，与作业/照片同一条纪律（迁移规则 R2）：
  /// 内存里那份必须是服务端那行，否则后续按 id 的读会全部落空。
  @override
  Future<ChatMessageModel> sendChatMessage({
    required String relationshipId,
    required String senderId,
    required String content,
  }) async {
    final data = await _api.postJson('/data/chat/messages', body: {
      'relationshipId': relationshipId,
      'content': content,
    });
    final msg = data['message'];
    if (msg is! Map) {
      // 协议保证返回 {message}，缺失即服务端 bug，不当空对象糊弄过去。
      throw DataApiException(code: 'bad_response', message: '发送消息未返回消息行');
    }
    return _chatFromRow(Map<String, dynamic>.from(msg));
  }

  /// 服务端的关系行 → [RelationshipModel]。
  ///
  /// 与本地那份形状一致，差别在**取值方式**（时间转本地时区）和**缺名字**
  /// （见类注释 ②：服务端不返回 `studentName` / `parentName`，只能填空串）。
  RelationshipModel _fromRow(Map<String, dynamic> row) {    return RelationshipModel(
      id: textOf(row['id']),
      studentId: textOf(row['studentId']),
      parentId: textOf(row['parentId']),
      senderId: textOf(row['senderId']),
      // 名字由服务端 LEFT JOIN 出来（见类注释 ②）。取不到时服务端给 null，
      // textOf 收敛成空串，与模型里 `required` 的形状对齐。
      studentName: textOf(row['studentName']),
      parentName: textOf(row['parentName']),
      status: relationshipStatusFromWire(textOf(row['status'])),
      // 本地那套 `createdAt` 是普通列，服务端给的是带 Z 的 UTC，必须转本地。
      // 模型没有这个字段，但若有需要按同样方式处理——此处仅保留解析习惯一致。
      // （RelationshipModel 当前无 createdAt 字段，故不映射。）
    );
  }

  // 状态词的翻译不在这里，在 `wire_status.dart`。
  //
  // 搬出去的直接原因是**可测**：这层映射历史上漏过一个词 —— 服务端的 `accepted`
  // 落到 `default` 被当成 `pending`，而家长端筛的是 `active`，于是家长端永远显示
  // 「尚未与任何学生结伴」，同时作业那条路完全是好的（它不经过这个枚举）。
  // 两个功能各说各话，看起来像「结伴没成功」，其实关系在库里好好的。
  //
  // 当时它是私有静态方法，测试够不着。**没有测试盯着的映射，第二次出错只是时间问题。**

  /// 服务端的消息行 → [ChatMessageModel]。
  ///
  /// 三个字段的取值方式与本地那份不同，全都踩过同族的坑（见 `data_row_values.dart`）：
  ///   · `isRead` —— 服务端是 `true`/`false`，本地是 `1`/`0`，用 [boolOf] 归一；
  ///   · `createdAt` —— 服务端给带 `Z` 的 UTC，**必须 `.toLocal()`**，
  ///     否则同一句话在两端显示差一个时区；
  ///   · `content` 等文本列 —— 用 [textOf] 兜住 null（服务端的列都是 NOT NULL，
  ///     但映射层不该假设「服务端永远不犯错」）。
  ChatMessageModel _chatFromRow(Map<String, dynamic> row) {
    return ChatMessageModel(
      id: textOf(row['id']),
      relationshipId: textOf(row['relationshipId']),
      senderId: textOf(row['senderId']),
      receiverId: textOf(row['receiverId']),
      content: textOf(row['content']),
      createdAt: timeOr(row['createdAt'], DateTime.now()),
      isRead: boolOf(row['isRead'], fallback: false),
    );
  }
}
