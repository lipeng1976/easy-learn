import '../models/checkin_models.dart';

/// 打卡的存取契约（服务端出题 + 题目快照 + 作答结果）。
///
/// ## 出题为什么也在这一层
///
/// 出题曾经走 AI 数据源（`AiDataSource.generateCheckinQuestions`），
/// 客户端拿到题目再 POST 给服务端存。搬进数据服务是为了**链路短**：
/// 错题聚合、调模型、落库一次完成，客户端不用先有本地错题本。
///
/// 题目是**带答案**回来的 —— 交卷时客户端要在本机立刻判对错。
/// 「看不到答案」由渲染层保证（见 `CheckinQuestion.answer` 的说明）。
///
/// `saveQuiz`（客户端出好题送来）**刻意删掉了**：出题已经只有一条路，
/// 留着它等于给「客户端自己编题」留一扇后门，而没有调用方会提醒后来的人。
abstract class CheckinRepository {
  /// 取打卡记录 —— **跨天**，可按「未完成 / 已完成」分开取，可翻页。
  ///
  /// ## 为什么不再按天取（2026-10-29）
  ///
  /// 原来是 `quizDate: 今天`，家长头天晚上出的题，孩子第二天打开一份也
  /// 看不到；而计划页入口卡按「今天没题」亮着绿标「待完成」——两处口径
  /// 打架，用户看到的就是「有未完成、点进去没有」。现在出题与做题解耦：
  /// 出的卷子一直等着孩子，直到他做完。
  ///
  /// [status] 过滤按**成绩行在不在**判，不看 `status` 字段（与渲染同口径）。
  /// [subject] 非空时只看这一科（学生端已完成区点进某个科目后的列表）。
  /// [limit] 为 0 表示不限（未完成那份要一次拿全）；已完成按 10 条一页翻。
  /// 排序由服务端定：未完成按出题时间正序、已完成按交卷时间倒序。
  Future<CheckinQuizPage> getQuizzes({
    String? studentId,
    CheckinQuizStatus status = CheckinQuizStatus.all,
    String subject = '',
    int limit = 0,
    int offset = 0,
  });

  /// 每科**已交卷**的份数与最近一次成绩（学生端已完成区的科目色块）。
  ///
  /// 与 [getQuizzes] 分开是因为口径不同：那个返回题目快照，这个只回计数。
  /// 用列表接口自己数的话，要么数到的是已加载的那一页（数字会骗人），
  /// 要么得 `limit=0` 把几十份带答案的题全拉下来。
  Future<List<CheckinSubjectSummary>> subjectSummaries({String? studentId});

  /// 出题候选：从云端错题本聚合出的知识点（按累计错次降序）。
  ///
  /// 供家长挑知识点用。**它只反映「已经错过什么」**，不含知识树 ——
  /// 工程里没有教材目录，家长能选的就是孩子错过的那些 + 自己输入的。
  ///
  /// [subject] 非空时只给这一科的候选。家长在发起页切到「语文」却看到
  /// 「整式化简」，勾上之后出的是一份语文题里夹着数学知识点 —— 界面看不出
  /// 错，孩子做起来完全对不上。空串 = 不分科（老调用点保持原样）。
  Future<List<CheckinSeed>> loadSeeds({String? studentId, String? subject});

  /// 让服务端出今天的题并落库，返回题目（含答案，供本机判分）。
  ///
  /// [knowledgePoints] 是**家长给出的范围**：非空就按它出题（顺序即优先级），
  /// 空则由服务端从错题本自动聚合。最多 6 个 —— 与网关的 `MAX_CHECKIN_ITEMS`
  /// 同一个数，超了服务端直接 400，不会悄悄砍掉几个。
  ///
  /// [difficulty] 取 [kCheckinDifficulties]；空串表示没要求。
  ///
  /// 失败分两种，客户端都该如实说：
  ///   · `bad_request` + `details.reason == 'no_seed'` → 错题本是空的，先录错题；
  ///   · `schema_violation` / `model_unavailable` / `model_timeout` → 模型这次没给出合格题目，可重试。
  Future<CheckinQuiz> generate({
    String? studentId,
    required String quizDate,
    String subject,
    int count,
    List<String> knowledgePoints,
    String difficulty,
  });

  /// 提交作答存档。客户端只送「第几题选了什么」。
  ///
  /// 服务端会复算分数 —— 与客户端本机算的那份必须一致（不一致时
  /// `CheckinController.syncConflict` 会亮，那是两处规则漂移的唯一信号）。
  Future<CheckinSubmitResult> submit({
    required String quizId,
    required Map<int, String> picked,
  });
}
