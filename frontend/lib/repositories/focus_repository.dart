import '../models/focus_session_model.dart';

/// 专注流水的存储契约。
///
/// 只有两个方法，是刻意的：这一份数据的用途只有「写一段」和「按天读回来」。
/// 没有 `update`、`delete` —— 一段已经过去的时间不该被改，
/// 而「删掉一条记录」在家长端表现为「孩子今天没学习」。
abstract class FocusRepository {
  /// 写（或更新）一段专注。
  ///
  /// [FocusSession.id] 是幂等键：一次会话的检查点、暂停、结束
  /// 都写同一个 id，服务端按主键 upsert。
  Future<void> saveFocusSession(FocusSession session);

  /// 取某个学生在 [from] ~ [to]（含）之间的流水。
  ///
  /// 日期按 `yyyy-MM-dd` 文本比较，两端都是**本地日**。
  /// 不传则取全部（客户端会自己按学生过滤）。
  Future<List<FocusSession>> queryFocusSessions({
    required String studentId,
    required String from,
    required String to,
  });
}
