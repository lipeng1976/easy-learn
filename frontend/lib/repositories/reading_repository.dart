import '../models/reading_models.dart';

/// 英文阅读的存取契约。
///
/// 服务端端点见 `serverless/data-service/src/routes/reading.js`：
///   · `GET  /data/reading/books/available` → ima `教学资料/English` 下可导入的 md
///   · `POST /data/reading/books/import`    → 下载 + 切课 + 入库
///   · `GET  /data/reading/books`           → 已导入的书
///   · `GET  /data/reading/lessons`         → 某本书的课目录（不含正文）
///   · `GET  /data/reading/lesson`          → 单课全文
///   · `GET  /data/reading/tasks`           → 任务与进度
///   · `POST /data/reading/tasks`           → 布置（一本书一个进行中任务）
///   · `POST /data/reading/tasks/read`      → 读了一篇（幂等 + 顺序校验）
///   · `POST /data/reading/tasks/cancel`    → 取消
///   · `GET  /data/reading/logs`            → 打卡记录（哪天读了第几篇）
///
/// ## 为什么「打卡」不叫 `checkin`
///
/// 工程里已经有 `checkin`（每日概念打卡：模型出题 + 判分）。阅读打卡是
/// 「读了一篇」这个动作，没有题、没有分数。两个都叫 checkin 的话，
/// 日志里、注释里、甚至表名上都会出现「到底是哪一个打卡」的歧义。
///
/// ## 没有「今日任务」
///
/// 任务是长期挂在书上的：读一篇算一次，没读就顺延，读完为止。
/// 所以这里**没有** `getTodayTask()` 之类的接口 —— 有它就等于把
/// 「今天该读哪篇」重新变成服务端要维护的状态。
/// 「这个家庭 / 这个部署没有 ima 书源」的内部信号，**不是错误**。
///
/// 服务端 `/data/reading/books/available` 回 2xx + `connected:false` 时由
/// HTTP 实现抛出，控制器据此把「从 ima 导入」整块藏起来。它刻意不是
/// [DataApiException]：可选功能不可用不该进页面级红色错误横幅。
class ImaBookSourceUnavailable implements Exception {
  const ImaBookSourceUnavailable([this.reason = 'ima_unavailable']);

  final String reason;

  @override
  String toString() => 'ImaBookSourceUnavailable($reason)';
}

abstract class ReadingRepository {
  /// 可导入的书（ima 侧）。
  ///
  /// 没开通 ima 时服务端回 `connected:false`（2xx），本方法抛
  /// [ImaBookSourceUnavailable] —— 这是「功能可以没有」的信号，不是故障。
  /// 调用方**不得**把它显示成红色错误；已导入的书与阅读任务照常可用。
  Future<List<ReadingAvailableBook>> listAvailableBooks({String? studentId});

  /// 导入一本书。同一个 `mediaId` 重复调用是幂等的。
  Future<ReadingImportResult> importBook({
    required String mediaId,
    String? studentId,
    String fileName = '',
    String title = '',
  });

  /// 已导入的书。
  Future<List<ReadingBook>> listBooks({String? studentId});

  /// 课目录。
  Future<List<ReadingLessonSummary>> listLessons({
    required String bookId,
    String? studentId,
  });

  /// 单课全文。
  Future<ReadingLesson> getLesson({
    required String bookId,
    required int lessonNo,
    String? studentId,
  });

  /// 任务列表（进行中的在前）。
  Future<List<ReadingTask>> listTasks({String? studentId});

  /// 布置任务。同一本书已有进行中任务时返回那一个（`created=false`）。
  Future<({ReadingTask task, bool created})> createTask({
    required String bookId,
    String? studentId,
  });

  /// 打卡：读了一篇。
  ///
  /// 重复读同一课不会报错（`already=true`），跳读会抛 `bad_request`
  /// 且消息里带「下一篇是第 N 课」。
  Future<ReadingReadResult> readLesson({
    required String taskId,
    required int lessonNo,
    required String day,
    String? studentId,
  });

  /// 取消任务（仅家长）。
  Future<ReadingTask> cancelTask({
    required String taskId,
    String? studentId,
  });

  /// 打卡记录，按天倒序。
  ///
  /// `from` / `to` 是**客户端本地日**（`yyyy-MM-dd`），都可选：
  /// 都不给 = 全部历史。刻意不提供「默认最近 N 天」—— 那会让更早的记录
  /// 从结果里消失，而列表看起来是完整的（用户会认为「那时候没读」）。
  ///
  /// `limit = 0` 表示不分页（「今天」这种小窗口用）。
  Future<ReadingLogPage> listLogs({
    String? studentId,
    String? from,
    String? to,
    int limit = 50,
    int offset = 0,
  });
}
