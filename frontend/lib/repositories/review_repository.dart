import '../models/review_model.dart';
import '../services/judgement_ab.dart';

/// 复习闭环的数据访问契约（L2）。
///
/// 覆盖「一池三路一个出口」的全部持久化：错题池（`review_mistake`）、
/// 组卷（`review_paper` / `review_paper_item`）、作答（`review_attempt`）、
/// AI 练习（`ai_practice_question`）、讲解（`explain_record`）、
/// 周期报告（`review_summary`），以及判定影子比对（`judgement_ab`）。
///
/// **状态机不在这里。** `pending → reviewing → verifying → mastered` 的流转规则、
/// 毕业分档、掌握率口径都在 `ReviewService` 与 `ReviewController`（L1）——
/// 这一层只负责把新状态写回去。
/// 建卷落库后**服务端认可的那一份**（卷 + 卷内题目）。
///
/// ⚠️ 为什么必须把返回值带回来：`id` 只有服务端说了算。服务端建卷时会
/// 自己生成 `id`（`crypto.randomUUID()`），客户端那份 `rp_...` 只是**请求里的
/// 占位**。以前这里返回 `void`，调用方继续用本地 id —— 现象是「刚生成的资料
/// 点进去说『这份资料还没有题目』，过一会儿又好了」：因为本地 id 在服务端
/// 查不到题，等列表刷新换成服务端 id 才恢复正常。
///
/// 同一条规矩在作业、照片、聊天上都栽过（R2）：**写接口返回的那行必须被采纳**。
class SavedPaper {
  const SavedPaper({required this.paper, required this.items});

  final ReviewPaper paper;
  final List<ReviewPaperItem> items;
}

abstract class ReviewRepository {
  // ===== 错题池 =====

  Future<List<ReviewMistake>> queryReviewMistakes();

  Future<List<ReviewMistake>> queryReviewMistakesByHomeworkId(
    String homeworkId,
  );

  Future<void> insertReviewMistake(ReviewMistake mistake);

  Future<void> insertReviewMistakes(List<ReviewMistake> mistakes);

  /// 新增一道错题并关联图片，**要么都成、要么都不留**。
  ///
  /// 默认实现只是顺序调用两个方法（给测试替身用）；本地与服务端实现都在
  /// 一个事务里完成，见各自的 override。
  Future<void> insertReviewMistakeWithImages(
    ReviewMistake mistake,
    List<ReviewMistakeImage> images,
  ) async {
    await insertReviewMistakes([mistake]);
    await insertMistakeImages(images);
  }

  /// 整体覆盖一条错题（非掩码更新）。
  Future<void> updateReviewMistake(ReviewMistake mistake);

  /// 删一道错题，**连同它的全部从属数据**。
  ///
  /// ⚠️ **一次删 5 张表**（陷阱 ③）：
  /// `review_mistake`、`review_attempt`、`judgement_ab`、
  /// `ai_practice_question`、`explain_record`。本地实现包在一个
  /// `db.transaction` 里。
  ///
  /// **上云后必须是服务端的单个原子端点**，不许让客户端编排 5 次调用：
  /// 中途失败会留下孤儿行，而孤儿行**不报错**、只是让统计数字悄悄偏掉 ——
  /// 残留的 `review_attempt` 会让毕业判定错乱，残留的 `judgement_ab`
  /// 会让一致率多出一个查不到题目的分母。
  Future<void> deleteReviewMistake(String id);

  /// 清掉某次作业带出来的全部错题（重新提交时重算，避免同一道题反复进错题本）。
  ///
  /// ⚠️ **与 [deleteReviewMistake] 不对称，这是当前的已知缺陷**：
  /// 本地实现**只删 `review_mistake`**，而 `review_attempt` / `judgement_ab` /
  /// `ai_practice_question` / `explain_record` 里的从属行会留下成为孤儿 ——
  /// 正是 [deleteReviewMistake] 的注释里明确说要避免的情况。
  ///
  /// 触发路径是真实存在的：批改写出错题与影子比对记录 → 学生重新提交 →
  /// 走本方法删掉旧错题 → 新错题再写一批 → **同一道题的判定被重复计入一致率**。
  ///
  /// 本期**刻意不改行为**（第 0 步的承诺是零行为变化），先把这个不对称
  /// 显式记下来。上云前必须统一：服务端按 `homeworkId` 做单端点级联删除。
  Future<void> deleteReviewMistakesByHomeworkId(String homeworkId);

  // ===== 错题图片 =====
  //
  // 默认实现**抛异常**而不是返回空列表：返回空会让「图片查询失败」长得和
  // 「这道题本来就没图」一模一样，而那正是最不该静默的一类失败。
  // 测试里的假实现不会被强制实现这三个方法，只有真的调用到才会炸。

  Future<List<ReviewMistakeImage>> queryMistakeImages(String mistakeId) {
    throw UnsupportedError('这个 ReviewRepository 实现没有错题图片读取能力');
  }

  Future<void> insertMistakeImages(List<ReviewMistakeImage> images) {
    throw UnsupportedError('这个 ReviewRepository 实现没有错题图片写入能力');
  }

  Future<void> deleteMistakeImage(String id) {
    throw UnsupportedError('这个 ReviewRepository 实现没有错题图片删除能力');
  }

  /// 更新错题状态及其随行字段。
  ///
  /// ⚠️ 这里的可选参数**同样是「`null` = 本次不改」语义**（陷阱 ② 的同一族）。
  /// 本地实现靠 `if (x != null)` 逐字段判断，在 Dart 里能工作；
  /// **云端实现必须把「哪些字段被显式传入」作为显式掩码转发**，
  /// 不能降级成「值为 null 就不写」的 JSON 对象，否则「清空某字段」会在
  /// 网络边界上被静默抹掉。这份契约尚未收敛成 [HomeworkPatch] 那样的显式掩码 ——
  /// 属于**待定项**，需与上云改造一起定死。
  Future<void> updateReviewMistakeState(
    String id,
    ReviewState state, {
    int? wrongCount,
    DateTime? lastWrongAt,
    int? reviewRound,
    DateTime? lastReviewedAt,
    DateTime? masteredAt,
    bool? masteredBySelf,
    String? knowledgePoint,
    String? wrongReason,
  });

  // ===== 组卷 =====

  Future<List<ReviewPaper>> queryReviewPapers();

  /// 取一份卷子的题目。
  ///
  /// `review_paper_item` 是**快照**：在卷的题不许删、不许改内容，
  /// 否则历史卷子会随着错题本变化而变形。
  Future<List<ReviewPaperItem>> queryReviewPaperItems(String paperId);

  Future<void> insertReviewPaper(ReviewPaper paper);

  /// 建卷并写入题目。**必须是一次原子写入** —— 只写进卷子没写进题目，
  /// 会得到一份点开就空的卷子。
  ///
  /// ⭐ 返回的 [SavedPaper] 是**服务端认可的那一份**，调用方必须用它替换
  /// 手里的占位对象（服务端可能重新生成 id，见 [SavedPaper] 的注释）。
  Future<SavedPaper> insertReviewPaperWithItems(
    ReviewPaper paper,
    List<ReviewPaperItem> items,
  );

  Future<void> updateReviewPaper(ReviewPaper paper);

  Future<void> updateReviewPaperItem(ReviewPaperItem item);

  // ===== 作答记录 =====

  /// 作答记录。不传 `mistakeId` 时返回全部（周期报告要按时间窗口聚合）。
  Future<List<ReviewAttempt>> queryReviewAttempts({String? mistakeId});

  Future<void> insertReviewAttempt(ReviewAttempt attempt);

  Future<void> insertReviewAttempts(List<ReviewAttempt> attempts);

  // ===== AI 练习 =====

  Future<List<AiPracticeQuestion>> queryPracticeQuestions({
    String? sourceMistakeId,
  });

  /// 用一批新题**替换**某道错题的练习题。
  ///
  /// 语义是「替换」不是「追加」：追加会让同一道错题越攒越多旧题。
  Future<void> replacePracticeQuestions(
    String sourceMistakeId,
    List<AiPracticeQuestion> questions,
  );

  Future<void> updatePracticeQuestion(AiPracticeQuestion question);

  // ===== 讲解 =====

  /// 讲解记录。**讲解不构成毕业** —— 它只是留痕，不参与掌握率。
  Future<List<ExplainRecord>> queryExplainRecords({String? mistakeId});

  Future<void> insertExplainRecord(ExplainRecord record);

  // ===== 周期报告 =====

  Future<List<ReviewSummary>> queryReviewSummaries();

  /// 写入周期报告，按 `scopeKey` 覆盖（同一周期重复生成只保留最新一份）。
  Future<void> insertReviewSummary(ReviewSummary summary);

  // ===== 判定影子比对（A/B） =====

  /// 影子比对记录。
  ///
  /// 它**跟着错题一起被删**（见 [deleteReviewMistake]），所以与错题同属一个
  /// 事务边界 —— 这是它放在本接口而不是单独一个接口的理由。
  ///
  /// ⚠️ **按 `studentId` 查询时不会校验错题是否还在**：孤儿行会直接进入
  /// 一致率的分母。上传实现若要按 `studentId` 聚合，需要自己在服务端做关联过滤。
  Future<List<JudgementABRecord>> queryJudgementAB({
    String? studentId,
    String? mistakeId,
  });

  /// 批量写入影子比对记录（**只观察、不改判定**）。
  Future<void> insertJudgementABRecords(List<JudgementABRecord> records);
}
