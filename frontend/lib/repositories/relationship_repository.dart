import '../models/chat_message_model.dart';
import '../models/relationship_model.dart';

/// 结伴关系与聊天的数据访问契约（L2）。
///
/// ⚠️ 这一层里混着一件**本来不属于数据访问**的事：鉴权。
/// [queryChatMessages] / [sendChatMessage] 的 `requesterId` / `senderId`
/// 不是过滤条件，是**鉴权主体** —— 实现必须校验「请求方是这段关系的成员，
/// 且关系处于 active」，否则抛错。
///
/// 本地实现查的是同一台设备上的库，所以这个校验在单机下是成立的；
/// **上云后请求方在远端，这段校验必须移到服务端** ——
/// 留在客户端等于让请求方自己声称自己有权限。
abstract class RelationshipRepository {
  /// 某人参与的全部结伴关系（含 `pending`）。
  ///
  /// 这是**横切**调用：多个控制器都用它来解析「当前用户关联的孩子是谁」。
  Future<List<RelationshipModel>> queryRelationships(String userId);

  /// 发出结伴邀请。
  ///
  /// 约束（当前由本地实现承担，上云后应由服务端承担）：双方角色必须互补、
  /// 不能重复邀请、已结伴的不能再邀。
  ///
  /// ⚠️ 本地实现要求**对方账号已经在本机库里**（内部走 `findUserByPhone`），
  /// 所以家长在自己手机上邀请孩子会抛「手机号对应的用户不存在」——
  /// 这是单机架构的必然结果，不是 bug。见 `doc/multi-device-architecture.md`。
  Future<RelationshipModel> createRelationshipInvitation({
    required String senderId,
    required String targetPhone,
  });

  /// 改关系状态（接受 / 拒绝）。
  Future<void> updateRelationshipStatus({
    required String id,
    required RelationshipStatus status,
  });

  /// 解除结伴（**家长单方，立即生效**，2026-09-26 新增）。
  ///
  /// 与 [updateRelationshipStatus] 分开，不是为了命名好看 —— 两件事在三个维度上都不同：
  ///   · **前置状态**：接受/拒绝作用在 `pending` 上；解除作用在 `active` 上；
  ///   · **谁能做**：接受/拒绝由「被邀请的那一方」做；解除**只有家长**（产品决定）；
  ///   · **语义**：一个是回应邀请，一个是撤销一段已成立的关系。
  ///
  /// ⚠️ 解除**不会删除任何数据**，它只改关系状态：
  ///   · 家长**立刻**看不到孩子的数据（服务端的可见集合只算 `active`，
  ///     表现是列表静默变空，不是报错）；
  ///   · 聊天双向关闭（历史消息留在库里，不删）；
  ///   · **孩子那侧一行都不动** —— 而重新结伴后家长又能看到**全部历史**，
  ///     包括解除期间孩子自己产生的打卡 / 作业。这是确认过的产品决定（不是遗漏）：
  ///     数据按 `studentId` 存，行上没有「属于哪一段结伴期」的标记。
  ///
  /// 不传 `requesterId`：**谁能解除由服务端按 token 判定**。本地实现没有「请求方」
  /// 这个概念，它靠「UI 只在家长端显示入口」保证一致 —— 这也是两侧唯一的不对称处。
  Future<void> revokeRelationship({required String id});

  /// 读一段会话。[requesterId] 是**鉴权主体**，校验不通过必须抛错而不是返回空。
  Future<List<ChatMessageModel>> queryChatMessages({
    required String relationshipId,
    required String requesterId,
  });

  /// 发一条消息。**接收方由关系反推，不由调用方指定** ——
  /// 让调用方指定接收方，就等于允许给任意人发消息。
  Future<ChatMessageModel> sendChatMessage({
    required String relationshipId,
    required String senderId,
    required String content,
  });
}
