/// 作业状态机（需求 5.1）。
///
/// 流转路径：
///   pending  ──学生提交──▶ checking ──AI批改──▶ finished（无错题）
///                                    └────────▶ needFix（有待更正错题）
///   needFix  ──更正后重新提交──▶ checking ──▶ …
///
/// 说明：旧版本里还有一个 `submitted` 状态，语义是「学生传了照片」。
/// 它把「交材料」和「作业完成度」混成一个状态，导致「已上传图片」的作业
/// 被人为当成已提交，AI 结果与图片脱节。现在图片是否存在由
/// [HomeworkItem.imageCount] 表达，状态只描述作业本身的推进阶段。
///
/// **`timeout`（已超时）也删掉了（2026-09-28）**，理由与 `submitted` 同族：
/// 它不是一个独立的推进阶段，而是「还没做」的另一种说法。当时它的触发条件是
/// `now > dueAt`，而 `dueAt` 取的是**打开作业页那一刻**（录入界面里根本没有
/// 时间输入框）⇒ **每一条刚录入的作业都当场满足「已超时」**，卡片立刻挂红。
/// 更糟的是家长端据此报「已超时 N 项」，把「还没做」说成一个负面事实。
///
/// 现在的口径：**作业上不再有超时这个概念**；家长端看「已提交（含提交时间）/
/// 尚未提交」。历史库里存着的 `'timeout'` 字符串由 [HomeworkStatus.parse]
/// 兜底成 [HomeworkStatus.pending]（不迁移、不改库版本，见它的注释）。
/// 完整记录见 `doc/open-items.md` 的 B26。
enum HomeworkStatus {
  pending('待完成'),
  checking('批改中'),
  needFix('待更正'),
  finished('已完成');

  const HomeworkStatus(this.label);

  /// 中文展示名，避免各页面各自 switch 一遍导致文案不一致。
  final String label;

  /// 是否为终态（不再需要学生动作）。
  bool get isTerminal => this == HomeworkStatus.finished;

  /// 从历史持久化值解析，兼容旧枚举。
  static HomeworkStatus parse(String? raw) {
    // 两个已废弃的值都归到「待完成」：
    // - `submitted`：旧版本表示「已上传照片但未走批改」，语义上仍是待完成；
    // - `timeout`（2026-09-28 废弃）：表示「从未提交且已过截止时间」——
    //   它想说的本来就是「还没做」，与待完成是同一件事。
    //
    // ⚠️ 下面的兜底 `return pending` 对这两个值也成立，但仍然**显式写出来**：
    // 「废弃值怎么办」需要一个能被读到的答案，而不是靠读者自己推。
    // 而且老设备的库里就存着 `'timeout'`（那次写入发生在今天之前），
    // 这条路径不是假想的。判据见 `test/homework_overdue_test.dart`。
    if (raw == 'submitted' || raw == 'timeout') return HomeworkStatus.pending;
    for (final value in HomeworkStatus.values) {
      if (value.name == raw) return value;
    }
    return HomeworkStatus.pending;
  }
}

/// 批改来源的持久化取值。
///
/// 用字符串常量而不是枚举，理由与 `status` 用文本存一样：它要进库、要能被
/// 家长端另一个会话读到，而枚举改名会让历史行静默失配。
/// 空串的语义是「尚未批改」，与 [HomeworkItem.gradedLocally] 的默认值一致。
abstract final class GradingSource {
  /// 尚未批改，或批改结果已被清空（重新提交时）。
  static const String none = '';

  /// 云端模型产出。
  static const String cloud = 'cloud';

  /// 本地兜底产出（离线、模型故障、能力未开通）。
  static const String local = 'local';
}

/// 一份作业的批改口径 —— 界面文案的唯一来源。
///
/// 「要不要批改」这件事在系统里其实有**三个**答案，不是一个布尔：
/// 朗读/背诵/默写/抄写这类没有可判的产出；书面作业有对错但当前环境用不了 AI。
/// 两者的共同点是「都不会有批改结果」，但**对家长的意义完全相反** ——
/// 前者是正常的，后者是能力缺失。合成一个 bool 之后，
/// 家长看到「没有批改」就再也分不出该不该问一句。
///
/// 不落库：由 [HomeworkItem.needsGrading] 与 `aiEnabled` 现算。
/// 落一份副本就会有两个真相，而界面上显示的是哪一份没人说得清。
enum HomeworkGradingMode {
  /// 有对错可判，且 AI 批改可用 —— 提交后走批改。
  auto('需要批改'),

  /// 这类作业交上来就算完成，没有可判的产出
  /// （朗读、背诵、预习的过程型，以及默写、抄写、字帖这种答案不在照片里的）。
  notRequired('无需批改'),

  /// 有对错可判，但当前环境用不了 AI 批改。
  unavailable('批改未开启');

  const HomeworkGradingMode(this.label);

  /// 短标签，用于信息行与徽章。
  final String label;

  /// 提交之后会不会真的去批。
  ///
  /// 所有分流判断都必须走这里，不要在各处自己写
  /// `needsGrading && aiEnabled` —— 抄三遍之后就会有一处漏掉 `aiEnabled`，
  /// 而那种漏法表现为「点了提交，界面卡在批改中」。
  bool get willGrade => this == HomeworkGradingMode.auto;

  static HomeworkGradingMode of({
    required bool needsGrading,
    required bool aiEnabled,
  }) {
    if (!needsGrading) return HomeworkGradingMode.notRequired;
    return aiEnabled
        ? HomeworkGradingMode.auto
        : HomeworkGradingMode.unavailable;
  }
}

class HomeworkItem {
  final String id;
  final String title;
  final String subject;

  /// 首图存储键（保留旧字段以兼容历史数据与家长端列表）。
  final String imageUrl;
  /// 这份作业的日期。
  ///
  /// ⚠️ **名字（`dueAt` = 到期）与实际用法不一致**，这是历史遗留：
  /// 系统里所有真正用它的地方都是「这份作业属于哪一天」—— 学生端列表按天过滤、
  /// 日期条上的打点、家长端「9月28日的作业情况」。而录入时它的取值是
  /// **打开作业页那一刻**（录入表单里没有时间输入框）。
  ///
  /// 🔴 **不要再拿它算「超时」** —— 那正是 2026-09-28 去掉 `timeout` 状态的原因
  /// （录入即「已超时」，见 `doc/open-items.md` B26）。将来若真要引入截止时间，
  /// 前提是先有一个**学生自己填的**时间字段，而不是复用这个。
  final DateTime dueAt;
  final double estimatedMinutes;

  /// 实际用时（**秒**，只算学生在专注计时里真正在学的时间）。
  ///
  /// - `0` 表示从来没计过时，**不是**「用了 0 秒」—— 界面上两者要分开说
  ///   （「还没计时」 vs 「用时不足 1 分钟」）。
  /// - 为什么存秒而不是分钟：计时界面按秒走，按分钟存会把 59 秒记成 0 分钟，
  ///   而「用了 0 分钟」看上去像没开始；`estimatedMinutes` 是**计划值**，
  ///   带小数无妨，实际值是**测量值**，一个整数秒就够准。
  /// - 暂停期间**不计入**（见 `FocusTimerService`）：学生要的是「我学了多久」，
  ///   不是「这个页面开了多久」。
  final int actualSeconds;
  final HomeworkStatus status;

  /// 本次批改发现、且已写入错题本的错题数量。
  final int wrongCount;
  final bool aiEnabled;

  /// 这份作业**要不要批改**。
  ///
  /// 与 [aiEnabled] 是两件事，必须分开放：
  /// - `aiEnabled` 是**能力**：这台设备、这个账号能不能用 AI 批改；
  /// - `needsGrading` 是**这次要不要批**：默认按类型推（判据是
  ///   「答案在不在照片里」，见 `HomeworkKind.needsGrading`），
  ///   学生可以在录入时或提交前改。
  ///
  /// 注意它是**选择**而不是「这类作业的性质」：默写、字帖这类确实有对错，
  /// 但题干（词表、范字）根本没被拍进照片，系统也没有可判的东西 ——
  /// 所以它们默认不批，而这和「朗读没法批」是两条不同的理由。
  ///
  /// 合起来才是 [gradingMode]。合成一个字段的话，「朗读作业不必批」
  /// 与「AI 没开通只能不批」会长得一模一样，而家长有权知道区别。
  ///
  /// 落库（DB v21 新增列，历史行回填为 1 = 需要批改）：
  /// 它是学生的选择，选择必须活过重启 —— 只在内存里的话，
  /// 学生每次进来都会看到系统把「不批改」又改回「批改」。
  final bool needsGrading;

  final String userRole;
  final String studentId;

  // ===== 提交与批改链路（本次增强新增） =====

  /// 学生提交时间。为 null 表示从未提交过。
  final DateTime? submittedAt;

  /// AI 批改完成时间。
  final DateTime? checkedAt;

  /// AI 评分（0-100）。未批改或未开启 AI 时为 null。
  final int? score;

  /// AI 批改总结。
  final String summary;

  /// 已提交的作业照片数量（冗余字段，列表页免查子表）。
  final int imageCount;

  /// 最近一次提交的批次号，用于区分「首次提交」与「更正后重交」。
  final String submitBatchId;

  /// 这份批改结果的来源。见 [GradingSource]。
  ///
  /// **为什么要落库**：本地兜底给出的是通用模板，读起来和模型输出没有区别。
  /// 学生这边降级了，家长那边是另一个会话（另一台设备、另一次启动），
  /// 它拿到的只有库里这条记录 —— 来源不跟着数据走的话，家长看到的就是
  /// 一份模板被当成 AI 批改结论，而这恰恰是最不能糊弄的一头。
  final String gradingSource;

  HomeworkItem({
    required this.id,
    required this.title,
    required this.subject,
    required this.imageUrl,
    required this.dueAt,
    required this.estimatedMinutes,
    this.actualSeconds = 0,
    required this.status,
    required this.wrongCount,
    required this.aiEnabled,
    this.needsGrading = true,
    required this.userRole,
    this.studentId = '',
    this.submittedAt,
    this.checkedAt,
    this.score,
    this.summary = '',
    this.imageCount = 0,
    this.submitBatchId = '',
    this.gradingSource = GradingSource.none,
  });

  /// 这份作业的批改口径（需要批 / 无需批 / 批不了）。
  ///
  /// 界面上一律走这个 getter，不要自己组合两个 bool。
  HomeworkGradingMode get gradingMode =>
      HomeworkGradingMode.of(needsGrading: needsGrading, aiEnabled: aiEnabled);

  /// 本次结果是不是**本地兜底**产出的。
  ///
  /// 界面上要据此把它标成「离线参考结果」，而不是让它冒充 AI 批改。
  bool get gradedLocally => gradingSource == GradingSource.local;

  /// 是否已经计过时。
  ///
  /// 与 `actualSeconds == 0` 分开叫，是因为 UI 要说的不是同一个意思：
  /// 「还没计时」和「计时过但不到 1 秒」在数据上都是 0，而前者才需要
  /// 显示一个开始入口，后者显示 0 秒只会让学生以为计数坏了。
  bool get hasActualTime => actualSeconds > 0;

  /// 学生是否可以（重新）提交。
  ///
  /// - 批改中拒绝重复提交，避免同一作业触发多个并发批改任务。
  /// - 已完成不再走这里 —— 已完成的作业走 [canSupplement]（补充提交）。
  ///
  /// 注：原来这里还有一条「已超时允许补交」。`timeout` 废弃之后，
  /// 「没交的作业随时能交」直接由 [HomeworkStatus.pending] 表达 ——
  /// 不需要第二个状态来说同一件事。
  bool get canSubmit =>
      status == HomeworkStatus.pending ||
      status == HomeworkStatus.needFix;

  /// 已完成的作业能否**补充提交**（2026-10-06 新增）。
  ///
  /// 场景：一份作业有多页/多种内容，第一次提交漏了一部分 ——
  /// 把「已完成」当成绝对终态，学生就只剩「删掉重录」一条路，
  /// 而那会把已有的批改结果、错题、家长的可见记录全部作废。
  ///
  /// 口径：
  /// - **旧附件全部保留**（补交是追加，不是替换 —— 谁也不会为了补一页
  ///   把交过的 5 页重新拍一遍）。
  /// - **重新批改**：漏掉的那页可能有错题，旧的批改结果对它一无所知；
  ///   新结果覆盖旧的（分数、错题、summary），这是「补交」的应有之义，
  ///   界面上必须明说（见提交面板的提示条）。
  /// - 只在 `finished` 成立：`checking` 被并发守卫挡住，`needFix` /
  ///   `pending` 走 [canSubmit]。
  bool get canSupplement => status == HomeworkStatus.finished;

  /// 是否已经提交过（用于家长端「孩子交了没有」的判断）。
  bool get hasSubmission => submittedAt != null;

  /// 是否已经出过批改结果。
  bool get hasResult =>
      checkedAt != null && (score != null || summary.isNotEmpty);

  HomeworkItem copyWith({
    String? id,
    String? title,
    String? subject,
    String? imageUrl,
    DateTime? dueAt,
    double? estimatedMinutes,
    int? actualSeconds,
    HomeworkStatus? status,
    int? wrongCount,
    bool? aiEnabled,
    bool? needsGrading,
    String? userRole,
    String? studentId,
    DateTime? submittedAt,
    DateTime? checkedAt,
    int? score,
    String? summary,
    int? imageCount,
    String? submitBatchId,
    String? gradingSource,

    /// 显式清空上一次的批改结果（`checkedAt` / `score` / `summary`）。
    ///
    /// 为什么非得有这个参数：[checkedAt] 与 [score] 是可空字段，
    /// 而上面每个都是「传 null = 本次不改」，于是**没法把已有结果清掉**。
    /// 重新提交时必须清 —— 不清的话，一份刚改完重交、还在批改中的作业
    /// 会在当前会话里继续挂着上次的分数（`hasResult` 仍为真），
    /// 看上去像是新结果已经出来了。
    ///
    /// 落库那边早有对称的 `clearResult`（见 `DatabaseService.updateHomework`），
    /// 这里是内存侧的同一件事：漏掉它，内存与库里会短暂地各说各话。
    bool clearResult = false,
  }) {
    return HomeworkItem(
      id: id ?? this.id,
      title: title ?? this.title,
      subject: subject ?? this.subject,
      imageUrl: imageUrl ?? this.imageUrl,
      dueAt: dueAt ?? this.dueAt,
      estimatedMinutes: estimatedMinutes ?? this.estimatedMinutes,
      actualSeconds: actualSeconds ?? this.actualSeconds,
      status: status ?? this.status,
      wrongCount: wrongCount ?? this.wrongCount,
      aiEnabled: aiEnabled ?? this.aiEnabled,
      needsGrading: needsGrading ?? this.needsGrading,
      userRole: userRole ?? this.userRole,
      studentId: studentId ?? this.studentId,
      submittedAt: submittedAt ?? this.submittedAt,
      checkedAt: clearResult ? null : (checkedAt ?? this.checkedAt),
      score: clearResult ? null : (score ?? this.score),
      summary: clearResult ? '' : (summary ?? this.summary),
      imageCount: imageCount ?? this.imageCount,
      submitBatchId: submitBatchId ?? this.submitBatchId,
      // 与 `summary` 同理：字符串字段可以显式传 `''` 清空，
      // 所以「本次不改」和「置空」不会像 bool 那样纠缠在一起。
      gradingSource: gradingSource ?? this.gradingSource,
    );
  }
}
