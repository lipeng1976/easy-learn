import '../models/relationship_model.dart';
import '../models/study_plan_model.dart';
import 'data_api_client.dart';

/// 跨端**状态词**的翻译层（客户端一侧）。服务端那一份在
/// `serverless/data-service/src/vocab.js`，两份要对着看。
///
/// ## 为什么还需要一个翻译层（而不是直接上行 `.name`）
///
/// 「一个语义一个词、两侧逐字相同」是目标，能做到的部分**就不该有翻译**。
/// 所以留在这里的只剩两类：
///
///   ① **对面没有的值** —— 客户端独有 `withdrawn`（家长撤回）/ `removed`（本地删好友），
///      服务端独有 `expired`（到期自动失效）。这些是**动作不同**，不是叫法不同，
///      凑成一个词会把「谁把它结束的」这条信息丢掉。
///   ② **语义相同、词不同** —— 服务端的 `pending` 与客户端的 `pendingStudentConfirm`。
///      合并要动客户端的落库值（枚举 `.name` 直接进本地 SQLite），
///      所以暂时保留一对一映射。
///
/// 等两侧枚举真的一样了，**这个文件应该被删掉**。它不是长期架构的一部分。
///
/// ## 为什么值得单独一个文件 + 一份单测
///
/// 关系那条路上真出过事：服务端的 `accepted` 落到 `default` 分支被当成 `pending`，
/// 而家长端筛的是 `active` —— 于是**家长端永远显示「尚未与任何学生结伴」**，
/// 同时 `/data/homework` 那条路完全是好的（它不经过这个枚举）。两个功能各说各话，
/// 看起来像「结伴没成功」，其实关系在库里好好的。
///
/// 那次的根因不是「代码写错了」，而是**这类映射没有任何测试盯着** ——
/// 它当时是仓库类的私有静态方法，测试够不着。所以这次两件事一起做：
/// 集中到这里 + 可测。`test/wire_status_test.dart` 就是它的判据。
///
/// ## 读取宽容、写入严格
///
/// - **读**（`*FromWire`）：认不出的词**不抛**，退到最保守的「未完成」态。
///   一行脏数据不该让整个列表解析失败 —— 白屏比显示错状态严重得多。
/// - **写**（`*ToWire`）：服务端没有对应值时**抛**（或返回 null 让调用方抛），
///   不猜。猜一个近似词的后果是状态悄悄变成另一个意思，而且没有任何地方记下这次偏离。

/// 服务端关系状态词 → 客户端枚举。
///
/// 服务端现行词表（`vocab.js`）：`pending / active / rejected`，
/// 与客户端枚举名**逐字相同**（2026-09-20 服务端由 `accepted` 统一过来）。
///
/// `accepted` 仍然被接受，是**为读旧数据留的一支**：它是统一之前服务端用的词。
/// 留着它的收益很具体 —— 一个还没跑迁移 `007_status_vocab_active.sql` 的库
/// 表现为「照样读得到」，而**不是**退化成 `pending`。那个退化正是文件头
/// 描述的那个 bug，不值得再撞一次。
///
/// 客户端多出的 `removed`：**2026-09-26 起服务端也会产生它了**
/// （家长解除结伴，`routes/relationship.js: revoke`）。
///
/// 这一支仍然留着的理由从「对面没有这个词」变成了「**读旧数据 + 读新数据都要认**」：
/// 一个还没跑 `revoke`、库里的值仍是本地写下的 `removed` 的账号，
/// 与云上解除后的账号，在客户端看到的是同一个状态 —— 这正是我们想要的。
RelationshipStatus relationshipStatusFromWire(String raw) {
  switch (raw) {
    case 'pending':
      return RelationshipStatus.pending;
    // ← 服务端现行词
    case 'active':
    // ← 统一之前的服务端词，仅为读旧数据保留
    case 'accepted':
      return RelationshipStatus.active;
    case 'rejected':
      return RelationshipStatus.rejected;
    case 'removed':
      return RelationshipStatus.removed;
    default:
      // 认不出的词按「未完成」处理：最保守，且不会让整行解析崩掉。
      return RelationshipStatus.pending;
  }
}

/// 客户端枚举 → 服务端关系状态词（**只给 `/data/relationship/status` 用**）。
///
/// **只支持「接受 / 拒绝」**：那条路只认 `pending → active|rejected`，
/// 把别的态发过去只会换来一次 400，而文案是「status 只能是…」——
/// 看起来像参数写错了。所以这里如实抛，不猜用户的意图。
///
/// ⚠️ `removed` 在这里**依然抛**，而它现在确实是服务端的合法状态词了 ——
/// 这不是遗漏：解除走的是**另一个端点**（`POST /data/relationship/revoke`），
/// 根本不经过这个函数。解除与「接受/拒绝」的前置状态、权限、语义三样都不同
/// （见 `repositories/relationship_repository.dart: revokeRelationship`）。
///
/// 所以：**别为了「支持 removed」而把这个函数放开**。放开之后的症状是
/// 解除请求打到 `/status` 上 —— 服务端的白名单会 400 拒掉它，
/// 而错误文案（「status 只能是 active 或 rejected」）会让调用方以为自己传错了参数，
/// 找不到真正的问题（该调 revoke）。
String relationshipStatusToWire(RelationshipStatus status) {
  switch (status) {
    case RelationshipStatus.active:
      return 'active';
    case RelationshipStatus.rejected:
      return 'rejected';
    case RelationshipStatus.pending:
      throw DataApiException(
        code: 'bad_request',
        message: '云端只支持「接受」或「拒绝」一个待确认的邀请（收到 ${status.name}）',
      );
    case RelationshipStatus.removed:
      // **单独一条文案**，因为这条错误最容易被误读：看到「status 只能是…」
      // 的人会去检查参数拼写，而真正的原因是**调错了端点**（解除要走 revoke）。
      throw DataApiException(
        code: 'bad_request',
        message: '解除结伴不走这个端点，请调 revokeRelationship（收到 ${status.name}）',
      );
  }
}

/// 服务端学习计划状态词 → 客户端枚举。
///
/// 服务端：`pending / active / rejected / completed / expired`（`vocab.js`）。
/// 客户端：`pendingStudentConfirm / active / rejected / withdrawn / completed`。
///
/// ⚠️ 两处**不是命名差异**：
///   - 服务端 `pending` ↔ 客户端 `pendingStudentConfirm`：同一个语义、两个词，
///     合并要动客户端落库值，暂时保留映射。
///   - 服务端 `expired`（到期自动失效）在客户端**没有对应值**，回落到 `withdrawn`
///     只是「不崩」的兜底，**不是语义等价**。真正该做的是客户端补一个 `expired`，
///     而不是把两个不同的结束原因混成一个。
StudyPlanStatus studyPlanStatusFromWire(String? value) {
  switch (value) {
    case 'pending':
      return StudyPlanStatus.pendingStudentConfirm;
    // ← 服务端现行词
    case 'active':
    // ← 统一之前的服务端词，仅为读旧数据保留
    case 'accepted':
      return StudyPlanStatus.active;
    case 'rejected':
      return StudyPlanStatus.rejected;
    case 'completed':
      return StudyPlanStatus.completed;
    case 'expired':
    default:
      return StudyPlanStatus.withdrawn;
  }
}

/// 客户端枚举 → 服务端学习计划状态词。
///
/// `withdrawn`（家长撤回）返回 **null**：服务端词表里没有它，而且不能硬塞成
/// `expired`（那是「到期自动失效」，两件事的发起方不同）。
/// 返回 null 是让调用方**显式失败**，而不是静默改写成另一个状态。
String? studyPlanStatusToWire(StudyPlanStatus status) {
  switch (status) {
    case StudyPlanStatus.pendingStudentConfirm:
      return 'pending';
    case StudyPlanStatus.active:
      return 'active';
    case StudyPlanStatus.rejected:
      return 'rejected';
    case StudyPlanStatus.completed:
      return 'completed';
    case StudyPlanStatus.withdrawn:
      return null;
  }
}
