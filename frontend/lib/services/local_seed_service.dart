import '../models/homework_model.dart';
import '../models/review_model.dart';
import '../models/study_plan_model.dart';
import '../models/wish_model.dart';
import '../models/workout_model.dart';
import 'database_service.dart';
import 'judgement_ab.dart';

class LocalSeedService {
  static Future<void> init() async {
    await DatabaseService.instance.seedIfEmpty();
  }

  static Future<List<HomeworkItem>> studentHomework() async {
    await init();
    final rows = await DatabaseService.instance.queryHomework('student');
    return rows;
  }

  static Future<List<WorkoutPlan>> studentWorkoutPlans() async {
    await init();
    return DatabaseService.instance.queryWorkoutPlans();
  }

  static Future<List<WorkoutPlan>> parentWorkoutPlans() async {
    await init();
    return DatabaseService.instance.queryWorkoutPlans();
  }

  static Future<List<WorkoutRecord>> studentWorkoutRecords() async {
    await init();
    return DatabaseService.instance.queryWorkoutRecords();
  }

  static Future<List<ReviewMistake>> studentMistakes() async {
    await init();
    return DatabaseService.instance.queryReviewMistakes();
  }

  /// 一次作业产出的错题（批改结果页 → 「错题 N 道」点进去）。
  ///
  /// 走仓储已有的 `queryReviewMistakesByHomeworkId`，而不是在页面里
  /// 过滤 `studentMistakes()`：后者依赖「内存里那份列表恰好是最新的」，
  /// 而批改刚完成时它可能还没刷新 —— 那会表现为「点进去说没有错题」。
  static Future<List<ReviewMistake>> mistakesByHomework(
    String homeworkId,
  ) async {
    await init();
    return DatabaseService.instance.queryReviewMistakesByHomeworkId(homeworkId);
  }

  static Future<List<ReviewMistake>> parentMistakes() async {
    await init();
    return DatabaseService.instance.queryReviewMistakes();
  }

  static Future<List<ReviewPaper>> studentReviewPapers() async {
    await init();
    return DatabaseService.instance.queryReviewPapers();
  }

  static Future<List<ReviewPaperItem>> reviewPaperItems(String paperId) async {
    await init();
    return DatabaseService.instance.queryReviewPaperItems(paperId);
  }

  /// 某道错题的原题照片（家长端卷内预览用）。
  ///
  /// 家长端没有注入 `ReviewController`，所以这里直接读库 —— 但**渲染组件
  /// 与学生端共用**（`ReviewItemPhotos`），免得两边各写一套、只修一边。
  static Future<List<ReviewMistakeImage>> reviewMistakeImages(
    String mistakeId,
  ) async {
    await init();
    return DatabaseService.instance.queryMistakeImages(mistakeId);
  }

  static Future<List<ReviewAttempt>> reviewAttempts({String? mistakeId}) async {
    await init();
    return DatabaseService.instance.queryReviewAttempts(mistakeId: mistakeId);
  }

  static Future<List<AiPracticeQuestion>> practiceQuestions({
    String? sourceMistakeId,
  }) async {
    await init();
    return DatabaseService.instance.queryPracticeQuestions(
      sourceMistakeId: sourceMistakeId,
    );
  }

  static Future<List<ExplainRecord>> explainRecords({String? mistakeId}) async {
    await init();
    return DatabaseService.instance.queryExplainRecords(mistakeId: mistakeId);
  }

  static Future<List<ReviewSummary>> reviewSummaries() async {
    await init();
    return DatabaseService.instance.queryReviewSummaries();
  }

  /// 判定影子比对明细。运维观察页用它算一致率。
  ///
  /// **没有对应的种子数据，这是刻意的**：比对记录是真实运行留下的痕迹，
  /// 造一批演示数据会让「一致率」看起来有样本 —— 而它恰恰是一个
  /// 必须靠真实调用才站得住的数字。演示环境里它就该是「暂无样本」。
  static Future<List<JudgementABRecord>> judgementABRecords({
    String? studentId,
  }) async {
    await init();
    return DatabaseService.instance.queryJudgementAB(studentId: studentId);
  }

  static Future<List<WishModel>> studentWishes() async {
    await init();
    return DatabaseService.instance.queryWishes('student');
  }

  static Future<List<WishModel>> publicWishes() async {
    await init();
    return DatabaseService.instance.queryPublicWishes();
  }

  static Future<List<StudyPlanModel>> studentStudyPlans() async {
    await init();
    return DatabaseService.instance.queryStudyPlans('student');
  }

  static Future<List<StudyPlanModel>> parentStudyPlans() async {
    await init();
    return DatabaseService.instance.queryStudyPlans('parent');
  }
}
