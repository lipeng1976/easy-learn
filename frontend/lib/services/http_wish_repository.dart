import '../models/wish_model.dart';
import '../repositories/wish_repository.dart';
import 'data_api_client.dart';
import 'data_row_values.dart';

/// 心愿的**服务端实现**（`WishRepository` 的第二个实现）。
///
/// 本地那份在 `local_database_service.dart`。两者实现同一个契约，所以
/// `WishController` 一行都不用改 —— 这正是当初抽 L2 接口的目的。
///
/// ## 几处「照搬本地写法就会错」的地方
///
/// **① `userRole` 被**刻意忽略**（见 `queryWishes` / `insertWish`）。**
/// 本地实现直接拿它当 SQL 条件（`where userRole = ?`）。上云后这是**权限声明由
/// 客户端自报**——改个包写成对方角色就能读到对方的心愿。服务端从 token 推导身份：
/// `listWishes` 用 `ctx.role`、`insertWish` 用 `ctx.role` 写 `user_role` 列，
/// 请求体里的 `user_role` 一概不读。这个参数留在签名上只是为了本地实现继续可用，
/// 它**不是契约的一部分**（见 `wish_repository.dart` 文件头）。
///
/// **② 范围统一成一个 `scope` 参数，永远来自 token。** 本地四个读方法
/// （`queryWishes` / `queryPublicWishes` / `queryPublicWishesByStudent` /
/// `queryUnfulfilledWishes`）差别只在「按什么筛」；服务端用 `scope=created /
/// public / unfulfilled` + 可选的 `studentId` 表达，`studentId` 只在可见集合内挑选。
/// 所以这里四个方法只是往同一个端点填不同的 `scope`，不各自发明一套过滤。
///
/// **③ 清空用显式 `clear*` 标志，不是 `null`。** 这是 `updateHomework` 踩过的坑：
/// `{"a": null}` 与「`a` 键不存在」在 JSON 里是同一回事。服务端 `redeemWish` 对
/// `redeemRequestedAt` / `redeemRejectedAt` 的处理是「`clear*` 为真 → 置 NULL；
/// 否则若键出现 → 写入值」。所以 `clearRedeemRequest = false` 这种**假值绝不能发上去**
/// （会被当成一次真实写入）；只有真为 `true` 才发 `clearRedeemRequest: true`。
/// `redeemedAt` 只能设不能清（没有 clear 标志），送 `null` 服务端会 400。
///
/// **④ 时间上行 UTC（`utcTimeText`）、下行转本地（`timeOf`）。** 见
/// `data_row_values.dart`：`expectedDate` / 三个兑换时间戳服务端给带 `Z` 的 UTC，
/// 不 `.toLocal()` 会差一个时区。
class HttpWishRepository implements WishRepository {
  HttpWishRepository(this._api);

  final DataApiClient _api;

  /// 按**发起角色**取心愿。
  ///
  /// `userRole` 被**刻意忽略**：服务端从 token 取 `ctx.role`（学生许的 / 家长替孩子许的），
  /// 对应服务端 `scope=created`。请求体里的 `user_role` 服务端不读 —— 留着只为让签名不变。
  @override
  Future<List<WishModel>> queryWishes(String userRole) async {
    final items = await _api.getItems('/data/wishes', query: {'scope': 'created'});
    return items.map(_fromRow).toList();
  }

  /// 全部公开心愿（`isPublic = true`），不分角色。对应 `scope=public`。
  @override
  Future<List<WishModel>> queryPublicWishes() async {
    final items = await _api.getItems('/data/wishes', query: {'scope': 'public'});
    return items.map(_fromRow).toList();
  }

  /// 某个学生的公开心愿（家长端「孩子的心愿墙」）。`scope=public` + `studentId` 下推成挑选。
  @override
  Future<List<WishModel>> queryPublicWishesByStudent(String studentId) async {
    final items = await _api.getItems(
      '/data/wishes',
      query: {'scope': 'public', 'studentId': studentId},
    );
    return items.map(_fromRow).toList();
  }

  /// 「未闭环」的心愿：没归档且双方没都确认。对应 `scope=unfulfilled`。
  ///
  /// 口径与本地逐字一致：不是「没兑现」——`isArchived` 与两个 confirmed 是独立字段，
  /// 只按组合判断。改这个口径会同时影响学生端与家长端的待办提醒。
  @override
  Future<List<WishModel>> queryUnfulfilledWishes() async {
    final items = await _api.getItems('/data/wishes', query: {'scope': 'unfulfilled'});
    return items.map(_fromRow).toList();
  }

  /// 新建心愿。
  ///
  /// `userRole` 被**刻意忽略**：服务端用 `ctx.role` 写 `user_role` 列（谁发起的心愿，
  /// 是业务事实不是权限声明）。`id` 也由服务端生成（R2），原样转发会被忽略。
  /// 时间字段上行 UTC；`expectedDate` 等可空，空则送 `null`（不送时区串服务端按缺省处理）。
  @override
  Future<void> insertWish(WishModel wish, String userRole) async {
    await _api.postJson('/data/wishes', body: {
      'studentId': wish.studentId,
      'title': wish.title,
      'description': wish.description,
      'isPublic': wish.isPublic,
      'parentConfirmed': wish.parentConfirmed,
      'studentConfirmed': wish.studentConfirmed,
      'isArchived': wish.isArchived,
      'expectedDate': utcTimeText(wish.expectedDate),
      'pointCost': wish.pointCost,
      'redeemRequestedAt': utcTimeText(wish.redeemRequestedAt),
      'redeemedAt': utcTimeText(wish.redeemedAt),
      'redeemRejectedAt': utcTimeText(wish.redeemRejectedAt),
    });
  }

  /// 改确认状态。`null` = 本次不改这个字段。
  ///
  /// 两个参数都 null 时**静默返回**（契约要求，不是错误）。服务端用「键出现即写」的
  /// 掩码表达同一件事，所以这里只把非 null 的键放进去——两个都没给就直接返回，
  /// 不浪费一次请求（`confirmWish` 收到空掩码也会回 `{updated:false}` 但不报错）。
  @override
  Future<void> updateWishConfirmation({
    required String id,
    bool? parentConfirmed,
    bool? studentConfirmed,
  }) async {
    if (parentConfirmed == null && studentConfirmed == null) return;
    await _api.postJson('/data/wishes/confirm', body: {
      'id': id,
      'parentConfirmed': ?parentConfirmed,
      'studentConfirmed': ?studentConfirmed,
    });
  }

  /// 归档 / 取消归档。传的是**目标值**（重复调用结果相同）。
  @override
  Future<void> updateWishArchived(String id, bool isArchived) async {
    await _api.postJson('/data/wishes/archive', body: {
      'id': id,
      'isArchived': isArchived,
    });
  }

  /// 心愿的兑换状态：定价 / 申请 / 兑现 / 拒绝。
  ///
  /// ## `clear*` 标志的发送纪律（见类注释 ③）
  ///
  /// `clearRedeemRequest` / `clearRedeemRejected` 在契约里是**非空的布尔**（默认 false）。
  /// 只有真为 `true` 才发 `clearXxx: true`；为 `false` 时**不发送该键**，否则服务端会把它
  /// 当成一次真实写入（把时间戳清掉）。值字段（非 null）在「没清」时才发；
  /// `redeemedAt` 只能设不能清——按契约它不接受 clear，且这里只在非 null 时发，绝不发 null。
  ///
  /// `pointCost` 可空：非 null 才发（服务端把「键出现」当成「这次要写定价」）。
  @override
  Future<void> updateWishRedeemState({
    required String id,
    int? pointCost,
    DateTime? redeemRequestedAt,
    DateTime? redeemedAt,
    DateTime? redeemRejectedAt,
    bool clearRedeemRequest = false,
    bool clearRedeemRejected = false,
  }) async {
    await _api.postJson('/data/wishes/redeem', body: {
      'id': id,
      'pointCost': ?pointCost,
      // 清空优先于设值：与本地 `if (clearRedeemRequest) … else if (redeemRequestedAt != null)` 顺序一致。
      if (clearRedeemRequest)
        'clearRedeemRequest': true
      else if (redeemRequestedAt != null)
        'redeemRequestedAt': utcTimeText(redeemRequestedAt),
      if (clearRedeemRejected)
        'clearRedeemRejected': true
      else if (redeemRejectedAt != null)
        'redeemRejectedAt': utcTimeText(redeemRejectedAt),
      if (redeemedAt != null) 'redeemedAt': utcTimeText(redeemedAt),
    });
  }

  /// 服务端的行 → [WishModel]。
  ///
  /// `WishModel` 没有 `fromMap`（无不可空的 `fromMap` 入口），照构造函数拼。
  /// 布尔用 `boolOf`（服务端回 `true/false`，本地那套 `as num?` 在真值上会静默错）；
  /// 时间用 `timeOf`（UTC 转到本地）；`pointCost` 走 `intOf`（NUMERIC 经 JSON 可能是字符串）。
  /// 响应里的 `userRole` 列是本实现不关心的字段，直接丢弃。
  WishModel _fromRow(Map<String, dynamic> row) {
    return WishModel(
      id: textOf(row['id']),
      title: textOf(row['title']),
      description: textOf(row['description']),
      isPublic: boolOf(row['isPublic']),
      parentConfirmed: boolOf(row['parentConfirmed']),
      studentConfirmed: boolOf(row['studentConfirmed']),
      isArchived: boolOf(row['isArchived']),
      studentId: textOf(row['studentId']),
      expectedDate: timeOf(row['expectedDate']),
      pointCost: intOf(row['pointCost']),
      redeemRequestedAt: timeOf(row['redeemRequestedAt']),
      redeemedAt: timeOf(row['redeemedAt']),
      redeemRejectedAt: timeOf(row['redeemRejectedAt']),
    );
  }
}
