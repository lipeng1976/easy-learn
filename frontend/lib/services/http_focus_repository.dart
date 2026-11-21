import '../models/focus_session_model.dart';
import '../repositories/focus_repository.dart';
import 'data_api_client.dart';
import 'data_row_values.dart';

/// 专注流水的**服务端实现**。
///
/// 与本地实现（`LocalDatabaseService`）唯一的语义差别是**幂等键归谁所有**：
/// 本地按主键 `replace`（客户端给的 id 直接生效），服务端同样接受客户端的 id，
/// 但会先确认那一行是不是这个学生的 —— 撞上别人的 id 是 403，不是静默改写。
class HttpFocusRepository implements FocusRepository {
  HttpFocusRepository(this._api);

  final DataApiClient _api;

  @override
  Future<void> saveFocusSession(FocusSession session) async {
    await _api.postJson('/data/focus-session/save', body: {
      // `studentId` 只用于在可见集合里挑一个（与复习仓库同形），缺失会 400。
      'studentId': session.studentId,
      'id': session.id,
      'kind': session.kind.wire,
      'sourceId': session.sourceId,
      'title': session.title,
      'date': session.date,
      'seconds': session.seconds,
      'startedAt': utcTimeText(session.startedAt),
    });
  }

  @override
  Future<List<FocusSession>> queryFocusSessions({
    required String studentId,
    required String from,
    required String to,
  }) async {
    final items = await _api.getItems(
      '/data/focus-session',
      query: {'from': from, 'to': to},
    );
    return items.map(_fromRow).toList();
  }

  /// 时间下行要转本地（服务端 `rowToApi` 回的是 UTC）。
  ///
  /// 不进 `FocusSession.fromMap` 的理由见 `http_review_repository` 的第 ③ 条：
  /// 模型自带的 `fromMap` 不 `.toLocal()`，直接用会让界面上的时间差一个时区。
  static FocusSession _fromRow(Map<String, dynamic> row) => FocusSession(
        id: textOf(row['id']),
        studentId: textOf(row['studentId']),
        kind: FocusTargetKindWire.fromWire(row['kind'] as String?),
        sourceId: textOf(row['sourceId']),
        title: textOf(row['title']),
        date: textOf(row['date']),
        seconds: intOf(row['seconds']),
        startedAt: timeOr(row['startedAt'], DateTime.fromMillisecondsSinceEpoch(0)),
        updatedAt: timeOr(row['updatedAt'], DateTime.fromMillisecondsSinceEpoch(0)),
      );
}
