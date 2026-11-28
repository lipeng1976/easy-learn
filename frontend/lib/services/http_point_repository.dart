import '../models/point_model.dart';
import '../repositories/point_repository.dart';
import 'data_api_client.dart';
import 'data_row_values.dart';

/// 积分账本与分值配置的**服务端实现**（`PointRepository` 的第二个实现）。
///
/// 本地那份在 `local_database_service.dart`。两者实现同一个契约，所以
/// `PointController` 一行都不用改 —— 这正是当初抽 L2 接口的目的。
///
/// ## 几处「照搬本地写法就会错」的地方
///
/// **① 归属不再由客户端声明。** 本地实现里 `studentId` 是行里的一列，写什么就是什么。
/// 服务端从 token 推导可见集合，body / 查询里的 `studentId` 只是**在这个集合里挑一个**
/// （`narrowToVisible`），越界直接 403。所以这里不必（也不能）自己判断权限。
///
/// **② 幂等的最终裁决在服务端。** 本地实现靠 `ConflictAlgorithm.ignore` +
/// 部分唯一索引（`idx_point_ledger_active_key`）在 SQLite 里原子地完成「不重复写入」。
/// 服务端换成 `ON CONFLICT … DO NOTHING` + 回查，并**显式把 `{created: true/false}`
/// 返出来**。这份 `false` 是「因为幂等键冲突，这次没有写入」的唯一可信信号，
/// 所以 `insertPointLedger` 必须把 `created` 映射成 `bool` 返回 —— 不能忽略，
/// 否则调用方会以为「写进去了」而真的去发分（重复发分不报错，只表现为「分不对」）。
///
/// **③ 撤销是原子的 `revokePoints`，返回形状要把「本来就已撤销」和「失败」分开。**
/// 服务端命中 `already_reversed` 时回的是 `{revoked: false}`（**不是异常**），
/// 因为「撤一个已经撤过的东西」不是错误（本地实现同样不抛）。所以这里不能把
/// `revoked:false` 当成失败 —— 直接 `return`，由异常通道去承接真正的 403/404。
///
/// **④ 时间上行 UTC（`utcTimeText`）、下行转本地（`timeOf`）。** 见
/// `data_row_values.dart`：账本 `createdAt` / `reversedAt` 服务端给的是带 `Z` 的 UTC，
/// 不 `.toLocal()` 每个时间都会差一个时区。`markPointEntryReversed` 的 `reversedAt`
/// 参数**刻意不往上送** —— 那是审计时间，服务端一律用 `now()` 记，送了也不采用。
///
/// **⑤ `findActivePointEntry` 没有对应端点。** 它只是「给出重复结论」的辅助，
/// 不承担正确性（契约注释明说调用方不能靠它防重）。服务端没有「按幂等键查活记录」
/// 的接口，所以这里用 `queryPointLedger` 拉回账本后在内存里筛 —— 是**尽力而为**，
/// 不是权威判定；真正的防重只看 `insertPointLedger` 的返回值。
class HttpPointRepository implements PointRepository {
  HttpPointRepository(this._api);

  final DataApiClient _api;

  /// 某个孩子的全部流水，最新在前。
  ///
  /// `studentId` 只用于下推成服务端可见集合里的挑选（越界会 403，正是我们要的
  /// **显式失败**）；不传则拉回当前身份可见的全部孩子，不符合契约「某个人」的语义。
  @override
  Future<List<PointLedgerEntry>> queryPointLedger(String studentId) async {
    final items = await _api.getItems('/data/points/ledger', query: {'studentId': studentId});
    return items.map(_fromRow).toList();
  }

  /// 家长配过的分值。**没配过的动作在这里没有行**，由调用方回退默认值。
  ///
  /// 服务端刻意不预生成一堆行（`listRules` 注释）：默认值属于 L1 业务规则，
  /// 写回服务端只会让默认值有两个来源。所以空列表是合法结果，不是「读不到」。
  @override
  Future<List<PointRule>> queryPointRules(String studentId) async {
    final items = await _api.getItems('/data/points/rules', query: {'studentId': studentId});
    final rules = <PointRule>[];
    for (final row in items) {
      final rule = _ruleFromRow(row);
      // 不认识的 action 跳过：服务端只存契约里有的 action，走到这里基本不会发生；
      // 与本地 `PointRule.fromMap` 返回 null 被过滤掉的行为一致，不抛、不占位。
      if (rule != null) rules.add(rule);
    }
    return rules;
  }

  /// 覆盖式写入一条规则。
  ///
  /// `updatedAt` **不送**：服务端用 `now()` 自己记（R3，记录时间服务端说了算，
  /// 原样转发会把客户端的本地时钟当真相）。`action` 用落库用的稳定标识
  /// `rule.action.code`，而不是枚举的展示名。
  @override
  Future<void> upsertPointRule(PointRule rule) async {
    await _api.postJson('/data/points/rules', body: {
      'studentId': rule.studentId,
      'action': rule.action.code,
      'points': rule.points,
      'enabled': rule.enabled,
    });
  }

  /// 「还活着」的流水查重 —— **尽力而为，不能当防重用**。
  ///
  /// 服务端没有「按幂等键查活记录」的端点，这里拉回账本后内存筛选
  /// （`reversedAt` 为空 + `idempotencyKey` 命中）。空 `idempotencyKey` 不参与防重，
  /// 直接判无；账本超过服务端单页上限（默认 50、上限 200）时可能筛不到，
  /// 所以这里只给「明确的重复结论」，权威裁决仍以 [insertPointLedger] 为准。
  @override
  Future<PointLedgerEntry?> findActivePointEntry({
    required String studentId,
    required String idempotencyKey,
  }) async {
    if (idempotencyKey.isEmpty) return null;
    final items = await _api.getItems(
      '/data/points/ledger',
      query: {'studentId': studentId, 'limit': 200},
    );
    for (final row in items) {
      final entry = _fromRow(row);
      if (entry.idempotencyKey == idempotencyKey && entry.reversedAt == null) {
        return entry;
      }
    }
    return null;
  }

  /// 记一笔流水。
  ///
  /// ⚠️ 返回值就是幂等的最终裁决：服务端 `POST /data/points/earn` 返回
  /// `{created: true/false, entry}` —— `false` 表示「因为幂等键冲突，这次没有写入」。
  /// 必须**原样映射**成这个 `bool`，调用方据此判断是否真的发分。
  ///
  /// `id` / `createdAt` / `createdBy` 都**不送**：服务端自己生成 id（`newId()`）、
  /// 用 `now()` 记时间、`ctx.userId` 记操作者。本地那套「客户端拼 id」在这里不成立。
  @override
  Future<bool> insertPointLedger(PointLedgerEntry entry) async {
    final data = await _api.postJson('/data/points/earn', body: {
      'studentId': entry.studentId,
      'action': entry.action,
      'points': entry.points,
      'reason': entry.reason,
      'idempotencyKey': entry.idempotencyKey,
      'refType': entry.refType,
      'refId': entry.refId,
    });
    // `created` 是布尔，但走 `boolOf` 兜底更稳（字段万一缺失不当成「写进去了」）。
    return boolOf(data['created']);
  }

  /// 把一笔标记为已撤销（标原记录 + 补一笔相反数，服务端一次事务完成）。
  ///
  /// 只送 `entryId`：服务端按 id 找、RLS 决定看不看得到（看不到就是「别人的流水」，
  /// 不泄露是否存在）。`reversedAt` 参数**刻意不送** —— 撤销时间是审计事实，
  /// 服务端用 `now()` 记，送什么来都不采用。
  ///
  /// 服务端命中 `already_reversed` / `not_found` 时回 `{revoked: false}`（**非异常**），
  /// 这里直接 `return`，不把它当失败 —— 与本地「撤已撤过的东西不抛」一致。
  /// 真正的权限/不存在错误（403 / 404）由 `DataApiException` 原样抛出。
  @override
  Future<void> markPointEntryReversed(String id, DateTime reversedAt) async {
    await _api.postJson('/data/points/reverse', body: {'entryId': id});
  }

  @override
  Future<List<PointBehavior>> queryPointBehaviors(String studentId) async {
    final items = await _api.getItems(
      '/data/points/behaviors',
      query: {'studentId': studentId},
    );
    return items.map(PointBehavior.fromMap).toList();
  }

  @override
  Future<void> upsertPointBehavior(PointBehavior behavior) async {
    // updatedAt 不送：服务端用 now() 自己记（R3）。
    await _api.postJson('/data/points/behaviors', body: behavior.toMap()
      ..remove('updatedAt'));
  }

  @override
  Future<void> deletePointBehavior(String studentId, String id) async {
    await _api.postJson(
      '/data/points/behaviors/delete',
      body: {'studentId': studentId, 'id': id},
    );
  }

  /// 服务端的行 → [PointLedgerEntry]。
  ///
  /// 与本地 `PointLedgerEntry.fromMap` 读同样的键，差别只在**取值方式**：
  /// 时间要 `.toLocal()`（服务端给 UTC 带 `Z`），数值/布尔用归一化工具。
  /// `action` 在本模型里是 `String`，原样取。
  PointLedgerEntry _fromRow(Map<String, dynamic> row) {
    return PointLedgerEntry(
      id: textOf(row['id']),
      studentId: textOf(row['studentId']),
      action: textOf(row['action']),
      points: intOf(row['points']),
      reason: textOf(row['reason']),
      idempotencyKey: textOf(row['idempotencyKey']),
      reversalOf: textOf(row['reversalOf']),
      refType: textOf(row['refType']),
      refId: textOf(row['refId']),
      createdAt: timeOr(row['createdAt'], DateTime.fromMillisecondsSinceEpoch(0)),
      createdBy: textOf(row['createdBy']),
      // 空串/NULL 都映射成「未撤销」；`timeOf` 已把 UTC 转到本地时区。
      reversedAt: timeOf(row['reversedAt']),
    );
  }

  /// 服务端的行 → [PointRule]。
  ///
  /// 与本地 `PointRule.fromMap` 读同样的键；`enabled` 服务端回 `true/false`，
  /// 用 `boolOf` 归一化（本地那套 `(row['enabled'] as num?)?.toInt() == 1` 在
  /// 真值上会静默把 `false` 读成 `true`）。不认识的 `action` 返回 null，由调用方过滤。
  PointRule? _ruleFromRow(Map<String, dynamic> row) {
    final action = pointActionFromCode(textOf(row['action']));
    if (action == null) return null;
    return PointRule(
      studentId: textOf(row['studentId']),
      action: action,
      points: intOf(row['points']),
      enabled: boolOf(row['enabled']),
      updatedAt: timeOr(row['updatedAt'], DateTime.fromMillisecondsSinceEpoch(0)),
    );
  }
}
