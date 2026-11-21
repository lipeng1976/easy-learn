import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../constants/grades.dart';
import '../models/homework_image_model.dart';
import '../models/mistake_figure.dart';
import '../models/notification_model.dart';
import '../models/op_result.dart';
import '../models/point_model.dart';
import '../models/relationship_model.dart';
import '../models/review_model.dart';
import '../services/ai_data_source.dart';
import '../repositories/homework_repository.dart';
import '../repositories/relationship_repository.dart';
import '../repositories/review_repository.dart';
import '../services/database_service.dart';
import '../services/image_storage_service.dart';
import '../services/judgement_ab.dart';
import '../services/local_seed_service.dart';
import '../services/review_exporter.dart';
import '../services/review_paper_html.dart';
import '../services/review_paper_pdf.dart';
import '../services/review_service.dart';
import '../services/simulated_ai_data_source.dart';
import '../widgets/homework_image_viewer.dart';
import '../utils/practice_question_rules.dart';
import 'auth_controller.dart';
import 'notification_controller.dart';
import 'point_controller.dart';
import 'student_controller.dart';

/// 一道题的一次拍照作答：拍到的原始字节。
///
/// 做成值对象而不是把 `Uint8List` 直接当参数传，是为了在签名上
/// 就带住文件名 —— `saveHomeworkImage` 需要它来决定 MIME，
/// 少一个字段就会让所有照片按默认类型存，而**读回来的 Content-Type 是错的**
/// 恰恰会让家长端打不开图。
class PracticeAnswerPhoto {
  const PracticeAnswerPhoto({required this.fileName, required this.bytes});

  final String fileName;
  final Uint8List bytes;
}

/// 录入错题时拍到的一张照片。
///
/// 与 [PracticeAnswerPhoto] 形状相同但**语义不同**：那个是「这道练习题的作答」，
/// 这个是「错题的原题照片」。分成两个类型是为了让调用点读起来不会混——
/// 两者的去向完全不同（一个进 `ai_practice_question` 的判定，一个进错题档案）。
class MistakeIntakePhoto {
  const MistakeIntakePhoto({
    required this.fileName,
    required this.bytes,
    this.mimeType = 'image/jpeg',
  });

  final String fileName;
  final Uint8List bytes;
  final String mimeType;
}

/// 一次「拍照识别题目」的结果。
///
/// 除了提取到的题目，还要把照片在存储里的位置带回去：识别必须先让照片
/// 落到 `ImageStorageService`（网关靠 storageKey 取图），而保存错题时
/// 用的是同一批字节。不复用的话，同一组照片会在「识别」和「保存」
/// 各上传一遍 —— 六张手机照片就是几十 MB 传两次，学生看到的是
/// 保存按钮转很久。
class MistakeIntakeScan {
  const MistakeIntakeScan({
    required this.extraction,
    this.storageKeys = const [],
    this.failure = '',
  });

  /// 提取结果（可能是空候选：照片糊了 / 离线）。
  final MistakeExtraction extraction;

  /// 与传入照片**按位置一一对应**的存储键。
  ///
  /// 照片上传失败时是空列表 —— 那时 [failure] 非空，调用方不该再保存。
  /// 识别失败但照片已上传时**仍然返回**这些键：学生手填题干后，
  /// 照片还是要跟着这条错题存下去的。
  final List<String> storageKeys;

  /// 没能走到识别的原因。空串表示流程正常。
  final String failure;

  bool get ok => failure.isEmpty;
}

/// 回传批改的结果摘要。
class PaperGradingResult {
  const PaperGradingResult({
    required this.op,
    this.passCount = 0,
    this.failCount = 0,
    this.graduatedCount = 0,
    this.backToPoolCount = 0,
    this.summary,
  });

  final OpResult op;
  final int passCount;
  final int failCount;
  final int graduatedCount;
  final int backToPoolCount;
  final ReviewSummary? summary;
}

/// 取一张错题原题照片的字节。
///
/// 形状与 `HomeworkImageReader.load` 一致，只在测试里换成假的 —— 真实现会打网络，
/// 判据里不能依赖它（同「widget 判据别碰真库」那条规矩）。
typedef MistakeImageLoader =
    Future<Uint8List?> Function(
      HomeworkImageModel image, {
      String endpoint,
    });

/// 复习闭环控制器：**组卷 → 打印 → 回传 → 批改分流 → 讲解 / 举一反三 → 报告**。
///
/// 错题池仍然由 [StudentController] 持有（作业提交写入它），这里通过共享同一个
/// `RxList` 来读写，而不是再维护一份副本 —— 两份列表迟早会不一致，
/// 而「错题库说 3 道、复习页说 5 道」这种 bug 最难查。
class ReviewController extends GetxController {
  /// 三个依赖都可注入：[student] 用于测试里直接绑一个错题池，
  /// [exporter] 用于测试里替换掉平台导出（否则会真的去调浏览器 / 写磁盘），
  /// [ai] 用于测试里替换 AI 能力。
  factory ReviewController({
    StudentController? student,
    ReviewExporter? exporter,
    AiDataSource? ai,
    JudgementShadow? shadow,
    ReviewRepository? review,
    RelationshipRepository? relationships,
    ImageStorageService? imageStorage,
    HomeworkRepository? homework,
    MistakeImageLoader? imageLoader,
  }) => ReviewController._(
    student,
    exporter ?? createReviewExporter(),
    ai,
    shadow ?? const JudgementShadow(),
    review ?? DatabaseService.instance,
    relationships ?? DatabaseService.instance,
    imageStorage,
    homework ?? DatabaseService.instance,
    imageLoader ?? HomeworkImageReader.load,
  );

  ReviewController._(
    this._student,
    this._exporter,
    this._ai,
    this._shadow,
    this._review,
    this._relationships,
    this._imageStorage,
    this._homework,
    this._imageLoader,
  );

  final StudentController? _student;
  final ReviewExporter _exporter;
  final AiDataSource? _ai;
  final JudgementShadow _shadow;

  /// 复习闭环的持久化。默认走本地库，将来换云端只改工厂里那处默认值。
  final ReviewRepository _review;
  final RelationshipRepository _relationships;

  /// 拍照作答的照片落盘口。
  ///
  /// ⚠️ 与 [StudentController] 共用**同一个**存储实现（接线时传同一份），
  /// 不是各建一个：图片存储决定「本地盘 / 远端」这件事，
  /// 两个实例会各自读一次 `DatabaseService.cloud`，在云端刚接上、
  /// 或刚掉线的那个瞬间读到不同的结果 —— 于是同一张照片一边存了、
  /// 另一边读不到。
  final ImageStorageService? _imageStorage;

  /// 照片**写行**的口。
  ///
  /// ⚠️ 它与 [imageStorage] 是**两步**，不是同一件事（见
  /// `RemoteImageStorageService` 的说明）：`imageStorage` 只把字节放进存储，
  /// 返回的那一行带着**本地占位 id**；把这一行登记进库、换回服务端那个
  /// 真 id，是 [HomeworkRepository.saveHomeworkImage] 的事。
  ///
  /// 少做第二步的后果**没有任何报错**：字节在、图也读得出来、识别照常，
  /// 但 `queryHomeworkImages` 查不到这一行 —— 家长端翻孩子的作答记录时
  /// 就是一片空白。所以它和 [imageStorage] 一样是**必需**的。
  final HomeworkRepository _homework;

  /// 读错题原题照片字节。默认 `HomeworkImageReader.load`（带内存缓存与去重）。
  ///
  /// 单独抽成字段是为了**能被判决据**：真实现要打网络，而「导出的 PDF 里
  /// 到底有没有那张图」必须是一条不依赖网络的判据。
  final MistakeImageLoader _imageLoader;

  /// 拍照作答要落盘，所以这里必须有实现。
  ///
  /// 刻意用 `Get.find` 而不是静默新建一个：新建出来的实现在 Web 端
  /// 会走内存存储（刷新即丢），而学生看不到任何异常 ——
  /// 「照片拍完识别了、提交后没了」。找不到就明确报错，
  /// 好过一个永远存不进去的假实现。
  ImageStorageService get imageStorage =>
      _imageStorage ?? Get.find<ImageStorageService>();

  /// AI 能力。默认与 [student] 共用同一个数据源 —— 两处各持一份实现的话，
  /// 「批改说错 3 处、复习页判出 2 处」这类不一致迟早会出现。
  ///
  /// 最后那个兜底分支在「既没注入 ai 也没注入 student」时才命中。
  /// 这里刻意不走 [student] getter（它会 `Get.find`，找不到就抛），
  /// 否则接线问题会被伪装成空指针，反而更难查。
  AiDataSource get ai =>
      _ai ?? _student?.ai ?? const SimulatedAiDataSource();

  StudentController get student => _student ?? Get.find<StudentController>();

  /// 与 StudentController 共享的错题池。
  RxList<ReviewMistake> get mistakes => student.mistakes;

  /// 积分账本。和 StudentController 里同一个实例（`PointController.to`
  /// 取不到就现建，且是 permanent 的），复习赚的分与学生端看到的余额是同一条。
  PointController get points => PointController.to;

  /// 影子比对：模型判完之后再跑一遍本地规则，**只为观察**。
  ///
  /// 返回 null 表示这次不该记 —— 结论不是模型给的（离线运行、或云端刚降级）。
  /// 那种情况下比出来的是「规则 vs 规则」，一致率会恒等于 100%：
  /// 一个看起来完美、实际毫无信息量的数字，比没有数字更坏。
  ///
  /// 整段包在 try 里是刻意的：比对是**旁路**，它出问题的正确表现是
  /// 「少一条样本」，而不是让学生这次判定失败。观测手段把业务拖下水，
  /// 是这类埋点最常见、也最没必要的故障。
  Future<JudgementABRecord?> _compareWithRules({
    required AnswerJudgement judgement,
    required ReviewMistake mistake,
    required AttemptChannel channel,
    required String studentAnswer,
    required String referenceAnswer,
    String subject = '',
    String knowledgePoint = '',
    String questionContent = '',
  }) async {
    try {
      final comparison = await _shadow.compare(
        judgement: judgement,
        studentAnswer: studentAnswer,
        referenceAnswer: referenceAnswer,
        subject: subject,
        knowledgePoint: knowledgePoint,
        questionContent: questionContent,
      );
      if (comparison == null) return null;

      return JudgementABRecord(
        id: ReviewService.newId('ab'),
        studentId: mistake.studentId,
        mistakeId: mistake.id,
        channel: channel,
        // 题目自带的科目 / 知识点优先，缺了才退回错题上的。
        subject: subject.isEmpty ? mistake.subject : subject,
        knowledgePoint: knowledgePoint.isEmpty
            ? mistake.knowledgePoint
            : knowledgePoint,
        modelVerdict: comparison.modelVerdict,
        ruleVerdict: comparison.ruleVerdict,
        createdAt: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  final RxList<ReviewPaper> papers = <ReviewPaper>[].obs;
  final RxList<ReviewAttempt> attempts = <ReviewAttempt>[].obs;
  final RxList<AiPracticeQuestion> practiceQuestions =
      <AiPracticeQuestion>[].obs;
  final RxList<ReviewSummary> summaries = <ReviewSummary>[].obs;

  /// 讲解记录。报告要统计「期内看讲解次数」，而讲解是按错题一条条查的，
  /// 每次出报告都逐题查一遍数据库没有必要，所以随复习数据一起载入。
  final RxList<ExplainRecord> explanations = <ExplainRecord>[].obs;

  /// 报告页当前选中的周期。
  final Rx<SummaryScope> reportScope = SummaryScope.week.obs;

  /// 当前打开的资料与卷内题目。
  final Rxn<ReviewPaper> activePaper = Rxn<ReviewPaper>();
  final RxList<ReviewPaperItem> activePaperItems = <ReviewPaperItem>[].obs;

  /// 当前讲解的错题与讲解内容。
  final RxString activeMistakeId = ''.obs;
  final Rxn<MistakeExplanation> activeExplanation = Rxn<MistakeExplanation>();

  final RxString selectedSubject = '全部'.obs;
  final RxBool isBusy = false.obs;

  /// 变式题正在判定中。
  ///
  /// 与 [isBusy]（组卷）**分开**：两者可以同时存在，共用一个标志会让
  /// 「生成错题资料」在判卷时也变灰，反过来也一样。
  ///
  /// 存在的理由不是好看 —— 三道题是**串行**送模型的，实测一次十几秒。
  /// 没有这个标志时按钮照旧可点、界面毫无变化，学生会以为点空了，
  /// 于是再点一次、再改一改 —— 重复提交正是「输入被清」的来源之一。
  final RxBool submittingPractice = false.obs;

  /// 正在识别一张拍照作答的照片。
  ///
  /// 与 [submittingPractice] **分开**：识别与判定是两个动作，
  /// 而且识别跑在判定之前。共用一个标志会让「拍照」和「提交检查」
  /// 互相把对方的按钮变灰 —— 学生看到的是一张卡住不动的卡片。
  ///
  /// 它存在的理由与 [submittingPractice] 相同：识别要过视觉模型，
  /// 真机上按 30s 窗口算。没有这个标志时按钮照旧可点、界面毫无变化。
  final RxBool capturingAnswer = false.obs;

  @override
  void onInit() {
    super.onInit();
    loadReviewData();
  }

  Future<void> loadReviewData() async {
    final myId = _currentStudentId;
    bool isOwn(String studentId) =>
        myId.isNotEmpty &&
        (studentId == myId || (myId == 'stu_001' && studentId.isEmpty));

    try {
      papers.value = (await LocalSeedService.studentReviewPapers())
          .where((paper) => isOwn(paper.studentId))
          .toList();
      attempts.value = (await LocalSeedService.reviewAttempts())
          .where((attempt) => isOwn(attempt.studentId))
          .toList();
      // 变式题的作答同时存在两份：库里的（上次落库的快照）与内存里的
      // （学生此刻正在敲、还没提交的）。`answerPractice` 刻意不落库，
      // 所以这里直接整组替换会把还没提交的作答**静默抹掉** ——
      // 学生看到的就是「输入框突然空了」。
      // 库里那份只提供题目与已提交的状态，作答以内存为准。
      final pending = <String, String>{
        for (final question in practiceQuestions)
          if (question.studentAnswer.trim().isNotEmpty)
            question.id: question.studentAnswer,
      };
      practiceQuestions.value = (await LocalSeedService.practiceQuestions())
          .where((question) => isOwn(question.studentId))
          .map(
            (question) => pending.containsKey(question.id)
                ? question.copyWith(studentAnswer: pending[question.id]!)
                : question,
          )
          .toList();
      summaries.value = (await LocalSeedService.reviewSummaries())
          .where((summary) => isOwn(summary.studentId))
          .toList();
      explanations.value = (await LocalSeedService.explainRecords())
          .where((record) => isOwn(record.studentId) || record.studentId.isEmpty)
          .toList();
    } catch (_) {
      // 复习数据不可用不应让首页崩掉；错题池本身来自 StudentController。
    }
  }

  // ===== 池视图 =====

  /// 待复习池（含复习中、待批改；不含已掌握）。
  List<ReviewMistake> get poolMistakes => _bySubject(
    mistakes.where((item) => item.state == ReviewState.pending).toList(),
  );

  /// 已印在卷子上、等待线下完成的题。
  List<ReviewMistake> get reviewingMistakes => _bySubject(
    mistakes.where((item) => item.state == ReviewState.reviewing).toList(),
  );

  /// 已回传、等待批改的题。
  List<ReviewMistake> get verifyingMistakes => _bySubject(
    mistakes.where((item) => item.state == ReviewState.verifying).toList(),
  );

  /// 已掌握档案。
  List<ReviewMistake> get masteredMistakes => _bySubject(
    mistakes.where((item) => item.state == ReviewState.mastered).toList(),
  );

  List<ReviewMistake> _bySubject(List<ReviewMistake> source) {
    final subject = selectedSubject.value;
    if (subject == '全部') return source;
    return source.where((item) => item.subject == subject).toList();
  }

  // ===== 学期归档筛选 =====
  //
  // 默认只看「当前学期 + 未归档」。为什么要带未归档：升级前已有 100+ 道错题，
  // 它们没有年级快照；只显示当前学期会让用户以为错题被清空了 —— 这是最不能
  // 接受的失败形态。空档案（没设年级）则显示全部，并在界面上提示去设置。

  /// 未归档的键。`grade` 与 `term` 都为空时用它。
  static const String unarchivedTermKey = '::';

  final RxBool termFilterAll = true.obs;
  final RxSet<String> selectedTermKeys = <String>{}.obs;
  bool _termFilterReady = false;

  String termKeyOf(ReviewMistake mistake) =>
      '${mistake.grade}::${mistake.term}';

  ({String grade, String term})? get profileTerm {
    if (!Get.isRegistered<AuthController>()) return null;
    final user = Get.find<AuthController>().currentUser.value;
    if (user == null || user.grade.isEmpty) return null;
    return (grade: user.grade, term: user.term);
  }

  /// 首次进入复习页时确定默认筛选。只做一次，避免用户手动切到「全部」
  /// 之后又被某次重建拉回当前学期。
  void ensureTermFilter() {
    if (_termFilterReady) return;
    _termFilterReady = true;
    final profile = profileTerm;
    if (profile == null) {
      termFilterAll.value = true;
      return;
    }
    termFilterAll.value = false;
    selectedTermKeys.assignAll({
      '${profile.grade}::${profile.term}',
      unarchivedTermKey,
    });
  }

  bool matchesTerm(ReviewMistake mistake) {
    if (termFilterAll.value) return true;
    return selectedTermKeys.contains(termKeyOf(mistake));
  }

  List<ReviewMistake> filterByTerm(List<ReviewMistake> source) =>
      source.where(matchesTerm).toList();

  void showAllTerms() => termFilterAll.value = true;

  void showCurrentTerm() {
    final profile = profileTerm;
    termFilterAll.value = profile == null;
    if (profile == null) return;
    selectedTermKeys.assignAll({
      '${profile.grade}::${profile.term}',
      unarchivedTermKey,
    });
  }

  void selectTermKeys(Set<String> keys) {
    if (keys.isEmpty) {
      showAllTerms();
      return;
    }
    termFilterAll.value = false;
    selectedTermKeys.assignAll(keys);
  }

  /// 题库里实际出现过的「年级 + 学期」组合，带数量。
  List<({String key, String label, int count})> get termOptions {
    final counts = <String, int>{};
    final labels = <String, String>{};
    for (final mistake in mistakes) {
      final key = termKeyOf(mistake);
      counts[key] = (counts[key] ?? 0) + 1;
      if (!labels.containsKey(key)) {
        labels[key] = mistake.grade.isEmpty
            ? '未归档'
            : '${mistake.grade}${switch (mistake.term) {
                '上' => ' · 上学期',
                '下' => ' · 下学期',
                _ => '',
              }}';
      }
    }
    final keys = counts.keys.toList()
      ..sort((a, b) {
        // 未归档排最后；其余按年级顺序 + 上/下。
        if (a == unarchivedTermKey) return 1;
        if (b == unarchivedTermKey) return -1;
        final ga = _gradeOrder(a.split('::').first);
        final gb = _gradeOrder(b.split('::').first);
        if (ga != gb) return ga.compareTo(gb);
        return a.split('::').last.compareTo(b.split('::').last);
      });
    return [
      for (final key in keys)
        (key: key, label: labels[key] ?? key, count: counts[key] ?? 0),
    ];
  }

  int _gradeOrder(String grade) {
    // 顺序与档案页 / 导入弹窗共用 [kGradeOptions]；历史快照里的
    // 「七年级」别名先归一，否则会被排到末尾（99）。
    final index = kGradeOptions.indexOf(canonicalGrade(grade));
    return index < 0 ? 99 : index;
  }

  /// 当前筛选的可读描述，给列表顶部那行用。
  String get termFilterLabel {
    if (termFilterAll.value) return '全部年级';
    final profile = profileTerm;
    if (profile != null &&
        selectedTermKeys.length == 2 &&
        selectedTermKeys.contains(unarchivedTermKey)) {
      final term = switch (profile.term) {
        '上' => '上学期',
        '下' => '下学期',
        _ => '',
      };
      return '${profile.grade}$term';
    }
    return '已选 ${selectedTermKeys.length} 个学期';
  }

  List<String> get mistakeSubjects {
    final subjects = <String>{};
    for (final mistake in mistakes) {
      if (mistake.subject.isNotEmpty) subjects.add(mistake.subject);
    }
    return ['全部', ...subjects];
  }

  int countForSubject(String subject) => subject == '全部'
      ? mistakes.where((item) => item.state.inPool).length
      : mistakes
            .where((item) => item.state.inPool && item.subject == subject)
            .length;

  void setSelectedSubject(String subject) {
    selectedSubject.value =
        (subject == '全部' || mistakeSubjects.contains(subject))
        ? subject
        : '全部';
  }

  /// 掌握率：**跟当前筛选（科目 + 学期）**。
  ///
  /// 原来按全库算，于是选了「英语」之后，头上那个百分比还是数学撑起来的 ——
  /// 一个数字和它下面那一屏毫无关系。
  double get filteredMasteryRate =>
      ReviewService.masteryRate(filterByTerm(_bySubject(mistakes)));

  int get masteredCount =>
      mistakes.where((item) => item.state == ReviewState.mastered).length;

  /// 还没掌握的题（= 待复习 + 复习中 + 待批改）。
  ///
  /// ⚠️ 它**不是**「待复习」。这个数原来叫 `poolCount` 并被当成「待复习」
  /// 摆在概览卡上，而分段那个「待复习」数的是 [ReviewState.pending] ——
  /// 同一个词两个定义，于是同一屏出现「待复习 45」和「待复习 0」。
  /// 名字必须把「未掌握」和「待复习」分开，否则下一个人还会接错。
  int get unmasteredCount =>
      mistakes.where((item) => item.state.inPool).length;

  /// 某个状态在当前筛选下的题。
  ///
  /// ⭐ **页面上每一个数字、每一张卡片都走这里** —— 这是「一套过滤」的单点。
  /// 之前概览卡全量、分段按科目+学期、资料段全量，三套口径同屏，
  /// 「数字和列表对不上」就成了常态而不是偶发。
  List<ReviewMistake> viewOf(ReviewState state) => filterByTerm(
    _bySubject(mistakes.where((item) => item.state == state).toList()),
  );

  List<WeakKnowledgePoint> get weakPoints => ReviewService.weakPoints(mistakes);

  /// 当前科目下的全部资料（含已批改的历史卷）。
  ///
  /// 学期这一维卷子没有 —— `review_paper` 只存 subject，没有年级/学期快照。
  /// 所以资料只参与科目筛选；界面上标清楚，比假装它也跟着学期走要好。
  List<ReviewPaper> get visiblePapers {
    final subject = selectedSubject.value;
    if (subject == '全部') return papers;
    return papers.where((paper) => paper.subject == subject).toList();
  }

  /// 还没闭合的资料（草稿 / 待作答 / 待批改）。
  List<ReviewPaper> get openPapers => visiblePapers
      .where(
        (paper) =>
            paper.status == PaperStatus.draft ||
            paper.status == PaperStatus.printed ||
            paper.status == PaperStatus.submitted,
      )
      .toList();

  /// 某道错题的全部历史作答（按时间升序）。
  List<ReviewAttempt> attemptsOf(String mistakeId) {
    final list = attempts
        .where((attempt) => attempt.mistakeId == mistakeId)
        .toList();
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  List<AiPracticeQuestion> questionsOf(String mistakeId) => practiceQuestions
      .where((question) => question.sourceMistakeId == mistakeId)
      .toList();

  ReviewPaper? paperById(String paperId) {
    for (final paper in papers) {
      if (paper.id == paperId) return paper;
    }
    return null;
  }

  ReviewSummary? summaryOfPaper(String paperId) {
    for (final summary in summaries) {
      if (summary.scope == SummaryScope.paper && summary.scopeKey == paperId) {
        return summary;
      }
    }
    return null;
  }

  ReviewMistake? mistakeById(String mistakeId) {
    for (final mistake in mistakes) {
      if (mistake.id == mistakeId) return mistake;
    }
    return null;
  }

  // ===== 组卷与导出 =====

  /// 组卷，并按 [exportAfterCompose] 决定是否立刻导出。
  ///
  /// 顺序很重要：**先落库、再改错题状态、最后导出**。
  /// 如果先把题标成「复习中」却写盘失败，这些题会从待复习列表里消失，
  /// 用户既看不到也找不到，只能当成数据丢失。
  ///
  /// [exportAfterCompose] 默认 **false**：组好卷之后该用哪种方式取走（打印 /
  /// 下载 / 转发）是学生的选择，不该由这里替他决定 —— 直接唤起打印会让
  /// 没有打印机的人卡在一个他没打算打开的对话框里。传 true 的是自动化路径
  /// （例如测试要验证导出链路）。
  Future<OpResult> composeAndPrintPaper({
    List<String>? mistakeIds,
    String subject = '',
    int limit = ReviewService.defaultPaperLimit,
    bool includeAnswerPage = true,
    bool exportAfterCompose = false,
  }) async {
    if (isBusy.value) return const OpResult.fail('正在生成资料，请稍候');

    final explicit = mistakeIds != null && mistakeIds.isNotEmpty;
    final now = DateTime.now();
    final pool = mistakes.where((item) {
      if (explicit) return mistakeIds.contains(item.id);
      if (item.state != ReviewState.pending) return false;
      final target = subject.isEmpty || subject == '全部'
          ? selectedSubject.value
          : subject;
      return target == '全部' || item.subject == target;
    }).toList();

    if (pool.isEmpty) {
      return const OpResult.fail('没有可组卷的错题。先完成作业批改，错题会自动进错题库。');
    }

    isBusy.value = true;
    try {
      final paperId = ReviewService.newId('rp');
      final composed = await ReviewService.compose(
        pool: mistakes,
        studentId: _currentStudentId,
        paperId: paperId,
        now: now,
        ai: ai,
        mistakeIds: explicit ? mistakeIds : null,
        subject: explicit ? '' : subject,
        round: papers.length + 1,
        limit: limit,
      );
      if (composed.items.isEmpty) {
        return const OpResult.fail('没有符合条件的错题。');
      }

      // 同一天、同科目生成第二份时，卷名会撞成同一个。列表里两条一模一样
      // 的标题，学生分不清哪份是哪份 —— 撞了就加「（二）」「（三）」。
      final paper = _withUniqueTitle(composed.paper);

      // ⭐ 采纳服务端返回的那一行：卷与题目的 id 都以服务端为准。
      // 用占位 id 的后果是「刚生成的资料点进去说没有题目，过一会儿又好了」
      // （服务端按自己的 id 存了题，客户端却拿占位 id 去查）。
      final saved = await _review.insertReviewPaperWithItems(
        paper,
        composed.items,
      );
      papers.insert(0, saved.paper);
      activePaper.value = saved.paper;
      activePaperItems.value = saved.items;

      await _moveMistakesTo(
        saved.items.map((item) => item.mistakeId).toList(),
        ReviewState.reviewing,
        now,
      );

      if (!exportAfterCompose) {
        return OpResult.success(
          '已生成 ${composed.items.length} 道题的重做卷，选个方式取走它。',
        );
      }
      final exported = await exportPaper(
        saved.paper.id,
        target: ExportTarget.print,
        includeAnswerPage: includeAnswerPage,
      );
      if (!exported.ok) {
        // 导出失败不等于组卷失败：卷子已经生成，用户可以重试导出。
        return OpResult.success(
          '已生成 ${composed.items.length} 道题的重做卷，但导出失败：${exported.message}',
        );
      }
      return OpResult.success(
        '已生成 ${composed.items.length} 道题的重做卷。${exported.message}',
      );
    } finally {
      isBusy.value = false;
    }
  }

  /// 给卷名去重：同名的第 2 份起加「（二）」「（三）」「（四）」…
  ///
  /// 卷名改成了「科目 + 日期」之后，同一天生成两份同科目的卷子必然撞名。
  /// 撞名不只是难看 —— 学生在列表里要「做昨天那份」时，两条一样的标题
  /// 根本选不出来。这里只加后缀、不改基础名，日期信息保持不变。
  ReviewPaper _withUniqueTitle(ReviewPaper paper) {
    final base = paper.title;
    var sameBase = 0;
    for (final existing in papers) {
      final title = existing.title;
      if (title == base || title.startsWith('$base（')) sameBase++;
    }
    if (sameBase == 0) return paper;
    // 第 N 份（N = 已有同名前缀数 + 1）。中文数字到 10 为止，再多就用阿拉伯数字：
    // 一天生成 11 份同科目卷子极罕见，没必要为它写一整套中文数字。
    final ordinal = sameBase + 1;
    const cn = ['', '', '二', '三', '四', '五', '六', '七', '八', '九', '十'];
    final suffix = ordinal < cn.length ? cn[ordinal] : '$ordinal';
    return paper.copyWith(title: '$base（$suffix）');
  }


  /// 把一份资料交给学生：打印、下载、或转发出去。
  ///
  /// 三种去向共用这一条路径，而不是各写一份 —— 它们都要「取卷 → 生成内容 →
  /// 落状态」这三步，分开写迟早会出现「下载成功但导出时间没更新」这种
  /// 只发生在一半路径上的 bug，而且只在用户走了那条路径时才被发现。
  Future<ExportResult> exportPaper(
    String paperId, {
    ExportTarget target = ExportTarget.print,
    bool includeAnswerPage = true,
  }) async {
    final paper = paperById(paperId) ?? await _reloadPaper(paperId);
    if (paper == null) {
      return const ExportResult(ok: false, message: '资料不存在');
    }
    final items =
        activePaper.value?.id == paperId && activePaperItems.isNotEmpty
        ? activePaperItems.toList()
        : await _review.queryReviewPaperItems(paperId);
    if (items.isEmpty) {
      return const ExportResult(ok: false, message: '这份资料还没有题目');
    }

    final studentName = _currentStudentName;
    final fileName = 'review_paper_${paper.id}.pdf';

    // 原题照片：题干里的几何图、表格、手写内容文字表达不了，
    // 没有它学生根本不知道题目长什么样。
    final images = await _mistakeImageBytes(items);

    // 先出 PDF 字节：三条去向都要它。渲染失败（字体缺失、排版异常）
    // 必须在这里就失败，而不是让用户点了「保存」之后拿到一个空文件。
    final Uint8List pdf;
    try {
      pdf = await ReviewPaperPdf.build(
        paper: paper,
        items: items,
        studentName: studentName,
        includeAnswerPage: includeAnswerPage,
        images: images,
      );
    } catch (error) {
      return ExportResult(ok: false, message: '生成 PDF 失败：$error');
    }

    String html() => ReviewPaperHtml.build(
      paper: paper,
      items: items,
      studentName: studentName,
      includeAnswerPage: includeAnswerPage,
      images: images,
    );

    final result = switch (target) {
      // Web 端打印用 HTML（浏览器原生排版更好），移动端打印用 PDF。
      // 两个产物都传，由平台实现各取所需。
      ExportTarget.print => await _exporter.printPaper(
        pdf: pdf,
        html: html(),
        fileName: fileName,
      ),
      ExportTarget.download => await _exporter.savePdf(pdf, fileName: fileName),
      ExportTarget.share => await _exporter.sharePdf(
        pdf,
        fileName: fileName,
        text: ReviewPaperHtml.buildText(
          paper: paper,
          items: items,
          studentName: studentName,
          includeAnswers: includeAnswerPage,
        ),
      ),
    };

    // 只有真的交到学生手上才标「已导出」。转发被取消、下载失败都不改状态 ——
    // 否则卷子上写着「已导出」，而学生手上什么都没有。
    if (result.ok) {
      final updated = paper.copyWith(
        status: paper.status == PaperStatus.draft
            ? PaperStatus.printed
            : paper.status,
        exportedAt: DateTime.now(),
        filePath: result.path.isEmpty ? paper.filePath : result.path,
      );
      await _persistPaper(updated);
    }
    return result;
  }

  /// 取每道错题的原题照片字节（导出卷子时用）。
  ///
  /// ## 为什么不能只调 `imageStorage.readImage`
  ///
  /// 远端实现的 `readImage` 是**同步**的（接口如此），它只能返回
  /// 「本进程刚上传过、还在那 6 张内存缓存里」的字节（见
  /// `RemoteImageStorageService.recentUpload`）。上周拍的原题照片走它**一律是
  /// null** —— 于是卷面上图形题只剩一行文字、连图都没有，而导出**成功**、
  /// 不报任何错。2026-10-23 用户就是撞在这上面（「图形题目的原题没有」）。
  ///
  /// 正确入口是 [HomeworkImageReader.load]：内存 → 直读 → 按 id 下载 → 本地兜底，
  /// 四条路都试过才算「这张图取不到」。同步那口仍先试一次（省一次往返）。
  ///
  /// ⚠️ 仍然**永不抛异常**：一张图取不到不该让整份卷子导不出来。但取不到的
  /// 数量会汇总成一条 `debugPrint`，不再像以前那样完全无声。
  Future<Map<String, List<Uint8List>>> _mistakeImageBytes(
    List<ReviewPaperItem> items,
  ) async {
    final result = <String, List<Uint8List>>{};
    var missing = 0;

    Future<void> loadItem(ReviewPaperItem item) async {
      if (item.mistakeId.isEmpty) return;
      try {
        final rows = await _review.queryMistakeImages(item.mistakeId);
        if (rows.isEmpty) {
          // 这道题本来就没存过原题照片（老数据、或从聊天里录进来的）。
          // 不是取失败，不必计入 missing。
          return;
        }
        final bytes = <Uint8List>[];
        for (final row in rows) {
          // 先走同步读：本进程刚上传的（远端实现的 `recentUpload`）与
          // 离线模式的本地盘都在这一口里，命中就不用打一次网络。
          final local = _imageStorage?.readImage(row.storageKey);
          if (local != null && local.isNotEmpty) {
            bytes.add(local);
            continue;
          }
          final data = await _imageLoader(
            _toImageModel(row),
            endpoint: _mistakeImageEndpoint,
          );
          if (data != null && data.isNotEmpty) {
            bytes.add(data);
          } else {
            missing++;
          }
        }
        if (bytes.isNotEmpty) result[item.mistakeId] = bytes;
      } catch (_) {
        // 单道题的照片取不到，不影响这份卷子其余部分。
        missing++;
      }
    }

    // 逐题并发：一份卷子通常 5~8 题，串行等待会让一次导出多花十几秒。
    await Future.wait(items.map(loadItem));

    if (missing > 0) {
      debugPrint('导出：有 $missing 张原题照片没取到（卷面上这几道题只有文字）');
    }
    return result;
  }

  /// 打开一份资料（供详情 / 批改页使用）。
  Future<List<ReviewPaperItem>> openPaper(String paperId) async {
    final paper = paperById(paperId) ?? await _reloadPaper(paperId);
    activePaper.value = paper;
    final items = await _review.queryReviewPaperItems(paperId);
    activePaperItems.value = items;
    return items;
  }

  void closePaper() {
    activePaper.value = null;
    activePaperItems.clear();
  }

  /// 学生点「我做完了」：把还在 reviewing 的题推进到 verifying，
  /// 让人一眼看出「这份卷子已经回传、等 AI 批改」。
  Future<OpResult> markPaperSubmitted(String paperId) async {
    final paper = paperById(paperId);
    if (paper == null) return const OpResult.fail('资料不存在');
    if (paper.status == PaperStatus.graded ||
        paper.status == PaperStatus.closed) {
      return const OpResult.fail('这份资料已经批改完成');
    }
    final items = await _review.queryReviewPaperItems(paperId);
    if (items.isEmpty) return const OpResult.fail('这份资料没有题目');

    await _moveMistakesTo(
      items.map((item) => item.mistakeId).toList(),
      ReviewState.verifying,
      DateTime.now(),
    );
    final updated = paper.copyWith(
      status: PaperStatus.submitted,
      submittedAt: DateTime.now(),
    );
    await _persistPaper(updated);
    return const OpResult.success('已回传，等待批改');
  }

  // ===== 批改与分流 =====

  /// 回传批改：逐题判定 → 通过则毕业移出，未通过则回炉。
  ///
  /// 判定口径（这是闭环最容易出错的地方，规则写死在这里）：
  /// - 学生填了答案 → 由 AI 按快照的参考答案判定，渠道记为「AI 判定」；
  /// - 学生没填答案 → 按学生的自评处理，渠道记为「自评」。
  ///
  /// 两者都写入 `review_attempt`，**毕业判定只看证据、不看走了哪条路**。
  /// 渠道分开记录的意义是：家长端能看出这个「掌握」是自评还是判定的。
  Future<PaperGradingResult> submitPaper({
    required String paperId,
    required Map<String, PaperItemResult> results,
    Map<String, String> answers = const {},
    Map<String, String> photoPaths = const {},
  }) async {
    final paper = paperById(paperId);
    if (paper == null) {
      return const PaperGradingResult(op: OpResult.fail('资料不存在'));
    }
    if (paper.status == PaperStatus.graded ||
        paper.status == PaperStatus.closed) {
      return const PaperGradingResult(op: OpResult.fail('这份资料已经批改过了'));
    }

    final items =
        activePaper.value?.id == paperId && activePaperItems.isNotEmpty
        ? activePaperItems.toList()
        : await _review.queryReviewPaperItems(paperId);
    if (items.isEmpty) {
      return const PaperGradingResult(op: OpResult.fail('这份资料没有题目'));
    }

    final unmarked = items
        .where((item) => !results.containsKey(item.id))
        .toList();
    if (unmarked.isNotEmpty) {
      return PaperGradingResult(
        op: OpResult.fail('还有 ${unmarked.length} 道题没有标记对错，请逐题完成后再提交。'),
      );
    }

    isBusy.value = true;
    try {
      final now = DateTime.now();
      final checkedItems = <ReviewPaperItem>[];
      final newAttempts = <ReviewAttempt>[];
      final abRecords = <JudgementABRecord>[];
      final decisions = <String, GraduationDecision>{};

      /// 本轮真正「做」过去且毕业了的题。
      final graduatedWithEvidence = <String>[];

      for (final item in items) {
        final selfMark = results[item.id]!;
        final answer = (answers[item.id] ?? '').trim();
        final hasAnswer = answer.isNotEmpty;

        final judged = hasAnswer
            ? await ai.judgeAnswer(
                studentAnswer: answer,
                referenceAnswer: item.answerKey,
                subject: item.subject,
                knowledgePoint: item.knowledgePoint,
                questionContent: item.questionBody,
              )
            : null;
        // inconclusive 表示「本地规则判不了」—— 保守按未通过处理。
        // 接入云端后这里要改成把 inconclusive 升级给模型再判一次。
        final correct = judged?.passed ?? (selfMark == PaperItemResult.correct);
        final comment =
            judged?.comment ??
            (correct ? '自评为正确。' : '自评为错误，已回到错题库。');

        checkedItems.add(
          item.copyWith(
            studentAnswer: answer,
            result: correct ? PaperItemResult.correct : PaperItemResult.wrong,
            photoPath: photoPaths[item.id] ?? item.photoPath,
            comment: comment,
            checkedAt: now,
          ),
        );

        final mistake = mistakeById(item.mistakeId);
        if (mistake == null) continue;

        // 历史必须取「本次之前」的作答，否则连续通过轮数会把自己算两次。
        final history = attemptsOf(mistake.id);
        final decision = ReviewService.judge(
          mistake: mistake,
          passed: correct,
          history: history,
        );
        decisions[mistake.id] = decision;

        final attempt = ReviewAttempt(
          id: ReviewService.newId('at'),
          studentId: mistake.studentId,
          mistakeId: mistake.id,
          paperId: paperId,
          itemId: item.id,
          channel: ReviewService.channelForAnswer(answer),
          round: ReviewService.nextRound(history),
          answer: answer,
          correct: correct,
          score: judged?.score ?? (correct ? 100 : 0),
          comment: comment,
          createdAt: now,
        );
        newAttempts.add(attempt);
        attempts.add(attempt);

        if (judged != null) {
          final ab = await _compareWithRules(
            judgement: judged,
            mistake: mistake,
            channel: attempt.channel,
            studentAnswer: answer,
            referenceAnswer: item.answerKey,
            subject: item.subject,
            knowledgePoint: item.knowledgePoint,
            questionContent: item.questionBody,
          );
          if (ab != null) abRecords.add(ab);
        }

        _replaceMistake(_applyDecision(mistake, decision, now));

        // 毕业能换分，但前提是这道题**真的做过**：录了答案才算。
        // 只标「对/错」的自评，项目里本来就不算掌握证据（掌握率都不认它），
        // 拿它换分等于把积分变成点两下的事。
        if (decision.mastered && hasAnswer) {
          graduatedWithEvidence.add(mistake.id);
        }
      }

      for (final item in checkedItems) {
        await _review.updateReviewPaperItem(item);
      }
      await _review.insertReviewAttempts(newAttempts);
      await _review.insertJudgementABRecords(abRecords);
      for (final mistake in mistakes) {
        if (!decisions.containsKey(mistake.id)) continue;
        await _review.updateReviewMistakeState(
          mistake.id,
          mistake.state,
          wrongCount: mistake.wrongCount,
          lastWrongAt: mistake.lastWrongAt,
          reviewRound: mistake.reviewRound,
          lastReviewedAt: mistake.lastReviewedAt,
          masteredAt: mistake.masteredAt,
          masteredBySelf: mistake.masteredBySelf,
        );
      }

      final passCount = checkedItems
          .where((item) => item.result == PaperItemResult.correct)
          .length;
      final failCount = checkedItems.length - passCount;
      final graduated = decisions.values.where((d) => d.mastered).length;

      final gradedPaper = paper.copyWith(
        status: PaperStatus.graded,
        submittedAt: paper.submittedAt ?? now,
        gradedAt: now,
        itemCount: checkedItems.length,
        passCount: passCount,
        failCount: failCount,
      );
      await _persistPaper(gradedPaper);
      activePaper.value = gradedPaper;
      activePaperItems.value = checkedItems;

      // 报告数字必须自洽：题量 = 通过 + 未通过。
      final summary = ReviewService.buildPaperReport(
        paper: gradedPaper,
        items: checkedItems,
        now: now,
      );
      await _review.insertReviewSummary(summary);
      summaries.insert(0, summary);

      // 记分。整轮的分要求「本轮至少有一道题写了答案」——
      // 全都只标对错的那一轮，和没做是一样的，不该换分。
      final answeredCount = checkedItems
          .where((item) => item.studentAnswer.trim().isNotEmpty)
          .length;
      if (answeredCount > 0) {
        await points.award(
          action: PointAction.reviewRound,
          studentId: paper.studentId,
          reason: '完成一轮复习：${paper.title}',
          // 一份资料只算一轮。反复提交同一份是防重挡住的，不是靠界面上藏按钮。
          idempotencyKey: PointController.reviewPaperKey(paperId),
          refType: 'review_paper',
          refId: paperId,
        );
      }
      for (final mistakeId in graduatedWithEvidence) {
        await points.award(
          action: PointAction.mistakeGraduated,
          studentId: paper.studentId,
          reason: '错题毕业',
          // 毕业是终态，一道题这辈子只会毕业一次 —— 这个键不会再用第二次，
          // 但它仍然必须有：它是「同一道题不会发两遍分」的唯一依据。
          idempotencyKey: PointController.mistakeKey(mistakeId),
          refType: 'mistake',
          refId: mistakeId,
        );
      }

      await _notifyGraded(gradedPaper, passCount, failCount, graduated);

      return PaperGradingResult(
        op: OpResult.success(summary.body),
        passCount: passCount,
        failCount: failCount,
        graduatedCount: graduated,
        backToPoolCount: failCount,
        summary: summary,
      );
    } finally {
      isBusy.value = false;
    }
  }

  /// 把判定结论落到错题上。
  ReviewMistake _applyDecision(
    ReviewMistake mistake,
    GraduationDecision decision,
    DateTime now,
  ) {
    if (decision.mastered) {
      return mistake.copyWith(
        state: ReviewState.mastered,
        masteredAt: now,
        masteredBySelf: false,
        reviewRound: mistake.reviewRound + 1,
        lastReviewedAt: now,
      );
    }
    if (decision.passed) {
      // 通过但没到毕业门槛（反复错的题要连续两轮）：回到待复习，等下一轮。
      return mistake.copyWith(
        state: ReviewState.pending,
        reviewRound: mistake.reviewRound + 1,
        lastReviewedAt: now,
      );
    }
    // 回炉：错误次数 +1 —— 这就是「薄弱度」累积的唯一来源。
    // 注意不覆盖原 wrongReason：新一次的归因记在 attempt 上，
    // 覆盖会把「第一次为什么错」这个最有价值的信息抹掉。
    return mistake.copyWith(
      state: ReviewState.pending,
      wrongCount: mistake.wrongCount + 1,
      lastWrongAt: now,
      reviewRound: mistake.reviewRound + 1,
      lastReviewedAt: now,
    );
  }

  // ===== 讲解 =====

  /// 打开单题讲解。讲解不构成毕业，只作为过程留痕。
  Future<MistakeExplanation?> explainMistake(String mistakeId) async {
    final mistake = mistakeById(mistakeId);
    if (mistake == null) return null;

    // 原题照片。图形题不带图，模型连「下图的面积」长什么样都不知道，
    // 只能给「横向切 / 竖向切 / 补形」这类通用套路 —— 2026-10-23 实测。
    // 取不到图时返回空列表，讲解照常生成（会笼统一些，但不会没有）。
    final images = await _sourceImages(mistake);

    final explanation = await ai.explainMistake(
      subject: mistake.subject,
      knowledgePoint: mistake.knowledgePoint,
      // `title` 是标签（「十月月考 · 分数比较」），`questionBody` 才是题目。
      // 两个都传：网关在没有题干时回落到 title，有题干时只对着题干讲。
      title: mistake.title,
      questionBody: mistake.questionBody,
      wrongReason: mistake.wrongReason,
      images: images,
      // 讲解要能指出「你这一步错了」，前提是它知道正确答案是什么、
      // 孩子当时写了什么。这两样在库里可能有、也可能没有（空串合法）。
      referenceAnswer: mistake.answerKey,
      studentProcess: mistake.studentProcess,
    );
    activeMistakeId.value = mistakeId;
    activeExplanation.value = explanation;

    final record = ExplainRecord(
      id: ReviewService.newId('ex'),
      studentId: mistake.studentId,
      mistakeId: mistakeId,
      knowledgePoint: mistake.knowledgePoint,
      channel: ExplainChannel.ai,
      summary: '${explanation.knowledgePoint} 讲解',
      createdAt: DateTime.now(),
    );
    await _review.insertExplainRecord(record);
    return explanation;
  }

  // ===== 讲解配图 =====

  /// 已经生成过的理解图，按错题 id 记。
  ///
  /// 只放内存、不落库：图是「按需生成」的附属品，一道题看过一次就够。
  /// 为它加一次 DB 迁移 + 三处版本同步，换来的只是「重开 App 不用再点一次」，
  /// 不划算 —— 真要持久化，先把「哪一类题值得画」这条判断稳定下来再说。
  ///
  /// ⚠️ 必须是 `RxMap` 而不是普通 Map：讲解页那段 `Obx` 只追踪它读到的
  /// 响应式对象。换成普通 Map，图生成完了页面**不会重建**，学生看到的是
  /// 转圈一直转下去 —— 而数据其实早就到了。
  final RxMap<String, MistakeFigure> _figures =
      <String, MistakeFigure>{}.obs;

  /// 这次没画成的原因（按 id 记）。空 = 还没有结论。
  ///
  /// 与 [_figures] 分开存，因为「没画成」有两种：服务端说这题不该画
  /// （结论，缓存了不再重试）和网络失败（不是结论，可以再点一次）。
  /// 合成一个字段的话，一次断网就会让这道题永远显示「不需要配图」。
  final RxMap<String, String> _figureFailures = <String, String>{}.obs;

  /// 正在生成配图的错题 id。null = 没有在跑。
  ///
  /// 用 Rx 是因为按钮要跟着它从「画一张图」变成转圈 —— 存在 State 里
  /// 也行，但那要求每个调用方自己 setState，而这里有两个入口（讲解页、
  /// 将来的家长端），总会漏掉一个。
  final Rxn<String> loadingFigureId = Rxn<String>();

  MistakeFigure? figureOf(String mistakeId) => _figures[mistakeId];

  String? figureFailureOf(String mistakeId) => _figureFailures[mistakeId];

  /// 生成（或取回）这道题的理解图。**点一下才调用**，进页面不预跑。
  ///
  /// ## 为什么不让网关自动带上
  ///
  /// 配图要 10~30 秒（它得先判断该不该画，再算坐标）。把它塞进讲解那条
  /// 请求里，学生每次打开讲解都要多等这么久，而六成题根本不需要图 ——
  /// 等来的只是一句「这题不用画」。
  Future<void> loadFigure(String mistakeId) async {
    final mistake = mistakeById(mistakeId);
    if (mistake == null) return;
    if (_figures.containsKey(mistakeId)) return;
    if (loadingFigureId.value == mistakeId) return;

    _figureFailures.remove(mistakeId);
    loadingFigureId.value = mistakeId;
    try {
      // 原题照片：面积题的「如图」全在照片里，不给图它只能凭想象画。
      final images = await _sourceImages(mistake);
      final figure = await ai.generateFigure(
        subject: mistake.subject,
        knowledgePoint: mistake.knowledgePoint,
        title: mistake.title,
        questionBody: mistake.questionBody,
        wrongReason: mistake.wrongReason,
        referenceAnswer: mistake.answerKey,
        studentProcess: mistake.studentProcess,
        images: images,
      );
      _figures[mistakeId] = figure;
    } catch (e) {
      debugPrint('[review] 讲解配图失败：$e');
      _figureFailures[mistakeId] = '这次没画成，检查网络后再点一次';
    } finally {
      // 只在还是自己的时候清：并发点了两道题，后一个不该被前一个清掉。
      if (loadingFigureId.value == mistakeId) loadingFigureId.value = null;
    }
  }

  // ===== 举一反三 =====

  /// 按知识点出同类型变式题（默认 3 道）。
  ///
  /// ## 为什么要带原题照片
  ///
  /// 只传知识点名时，模型**看不见原题**。实测（2026-10-23）：用「几何图形面积」
  /// 出题，回来的是「长方形长 8 宽 5」—— 它在主动避开需要配图的题，因为
  /// 它画不出来。学生看到的就是「举一反三只会出纯文字题」。
  ///
  /// 而 44 道数学错题里有 41 道 `questionBody` 是空的：原题的信息几乎全在
  /// 照片里。所以「把题干传过去」救不了，必须传图。
  Future<OpResult> generatePractice(
    String mistakeId, {
    String difficulty = '基础',
  }) async {
    final mistake = mistakeById(mistakeId);
    if (mistake == null) return const OpResult.fail('错题不存在');

    final images = await _sourceImages(mistake);
    final round = attemptsOf(mistakeId).length + 1;
    final generated = await ai.generatePractice(
      subject: mistake.subject,
      knowledgePoint: mistake.knowledgePoint,
      difficulty: difficulty,
      round: round,
      count: 3,
      images: images,
    );
    if (generated.isEmpty) return const OpResult.fail('暂时没有合适的变式题');

    final now = DateTime.now();
    final questions = generated
        .map(
          (item) => AiPracticeQuestion(
            id: ReviewService.newId('pq'),
            studentId: mistake.studentId,
            sourceMistakeId: mistakeId,
            knowledgePoint: mistake.knowledgePoint,
            subject: mistake.subject,
            title: item.title,
            content: item.content,
            answer: item.answer,
            difficulty: item.difficulty,
            round: round,
            createdAt: now,
            questionType: item.questionType,
            options: item.options,
            figure: item.figure,
          ),
        )
        .toList();

    await _review.replacePracticeQuestions(
      mistakeId,
      questions,
    );
    practiceQuestions.removeWhere(
      (question) => question.sourceMistakeId == mistakeId,
    );
    practiceQuestions.insertAll(0, questions);
    activeMistakeId.value = mistakeId;

    final label = mistake.knowledgePoint.isEmpty
        ? mistake.subject
        : mistake.knowledgePoint;
    return OpResult.success('已围绕「$label」生成 3 道变式题');
  }

  /// 暂存练习作答（不落库，提交检查时才写证据）。
  ///
  /// ⚠️ 「不落库」意味着这份作答只活在内存里 —— 因此 [loadReviewData]
  /// 必须把它带回来（见那里的注释），否则任何一次重新加载都会静默丢弃。
  void answerPractice(String questionId, String answer) {
    final index = practiceQuestions.indexWhere((q) => q.id == questionId);
    if (index < 0) {
      // 找不到题目，说明这张卡片对应的题已经不在列表里了
      // （换了一组、或被另一次刷新顶掉）。此时**必须留下痕迹**：
      // 否则学生的输入会像从未存在过一样消失，事后什么都查不到。
      debugPrint('[复习] 作答被丢弃：列表里已没有题目 $questionId');
      return;
    }
    practiceQuestions[index] = practiceQuestions[index].copyWith(
      studentAnswer: answer,
    );
  }

  /// 拍照作答：把学生拍的照片落盘，识别其中的手写内容，
  /// 并把文字**填进作答框**。
  ///
  /// ## 它是 [answerPractice] 的一种输入方式，不是替代品
  ///
  /// 识别出来的文字走的是**同一个** [answerPractice] 回写路径 —— 所以
  /// 学生看得见、改得了，之后走的是原来那条判定。这一点是刻意的：
  /// 如果拍照走一条自己的判定路径，同一份作答会因为「怎么输入的」
  /// 得到不同结论，而那种不一致没有任何办法解释给学生听。
  ///
  /// ## 照片为什么要**落盘**而不是只在内存里晃一圈
  ///
  /// 识别只是这条路的一半用途：照片本身是**作答证据**。
  /// 家长端要能看到孩子当时写的是什么，否则「系统说他错了」
  /// 就成了一句话而无法核对。只传字节给模型、不存下来，
  /// 会得到一条「有判定、没有证据」的记录 —— 而这种缺口
  /// 在事后补不回来（字节已经没了）。
  ///
  /// ## 为什么返回值要带 `recognition` 出去
  ///
  /// 调用方要拿 [AnswerRecognition.isUsable] 与
  /// [AnswerRecognition.needsReview] 决定提示文案。只回一个
  /// 「成功/失败」会让「识别出来了但没把握」和「识别出来了很确定」
  /// 在校验层就混成一个 —— 而前者恰恰是最需要提醒学生核一眼的情形。
  Future<OpResult> captureAnswer({
    required String questionId,
    required Uint8List bytes,
    String fileName = 'answer.jpg',
  }) async {
    return captureAnswers(
      questionId: questionId,
      photos: [PracticeAnswerPhoto(fileName: fileName, bytes: bytes)],
    );
  }

  /// [captureAnswer] 的批量版。
  ///
  /// 相机一次只能拍一张，但相册选图可以一次多张 —— 学生把一整页解答
  /// 分两张拍是常见情况。合成一次识别请求（而不是每张各发一次），
  /// 不只是省一次往返：**两张照片合起来才是一份完整作答**，
  /// 分开识别会得到两段各自残缺的文字，还要再去猜怎么拼。
  Future<OpResult> captureAnswers({
    required String questionId,
    required List<PracticeAnswerPhoto> photos,
  }) async {
    if (capturingAnswer.value) {
      return const OpResult.fail('上一张照片还在识别，稍等一下');
    }

    final index = practiceQuestions.indexWhere((q) => q.id == questionId);
    if (index < 0) {
      return const OpResult.fail('题目已不在列表里，请刷新后重试');
    }
    if (photos.isEmpty) {
      return const OpResult.fail('没有拿到照片，请重拍');
    }

    final question = practiceQuestions[index];
    // 学号取当前学生。拿不到就落不进库，而落不进库的照片在家长端
    // 是看不到的 —— 与其静默丢一张，不如在这里就拦住。
    final studentId = _currentStudentId;
    if (studentId.isEmpty) {
      return const OpResult.fail('当前没有登录中的学生，无法保存这张照片');
    }

    capturingAnswer.value = true;
    try {
      // 先落盘再识别。顺序是刻意的：如果识别超时或失败，
      // 照片已经存在了 —— 学生至少可以点开看自己拍了什么，
      // 而不是面对一个「什么都没有发生」的界面。
      final storageKeys = <String>[];
      for (var i = 0; i < photos.length; i++) {
        final saved = await imageStorage.saveHomeworkImage(
          studentId: studentId,
          fileName: photos[i].fileName,
          bytes: photos[i].bytes,
          // 照片挂在**题目**上，不挂在某次作业上：它属于「这道题的这次作答」。
          // 传 homeworkId 会让它出现在作业详情里，而学生其实是在复习页拍的。
          batchId: questionId,
          ocrStatus: 'pending',
          sortOrder: i,
        );
        // ⚠️ 上传字节与**写行**是两步（见 `RemoteImageStorageService`）。
        // 只做第一步时：字节在、图读得出来、识别也正常，唯独库里那一行没有 ——
        // `queryHomeworkImages` 查不到它，家长端就看不到这份作答证据，
        // 而全程不报任何错。这里与「提交作业」（`StudentController`）和
        // 「作业识别」（`OcrService`）两条链路保持同一口径。
        var stored = saved;
        try {
          final rows = await _homework.saveHomeworkImage(saved);
          if (rows.isNotEmpty) stored = rows.first;
        } catch (_) {
          // 落库失败不中断识别：字节已经在存储里（`RemoteImageStorageService`
          // 还留了一份内存，`HomeworkImageReader` 会先命中它），本次会话内
          // 照片仍然看得见。为一次登记失败把整次识别作废，学生面对的会是
          // 「拍了照、什么都没发生」—— 比少一行记录更糟。
        }
        storageKeys.add(stored.storageKey);
      }

      final recognition = await ai.recognizeAnswer(
        imagePaths: storageKeys,
        questionContent: question.content,
        knowledgePoint: question.knowledgePoint,
      );

      // 识别期间学生可能已经改了别的题、甚至这张卡片被刷掉了。
      // 回写前按 id 重新取**当前**那一条 —— 与 checkPractice 同一个理由：
      // 用进函数时的快照回写会覆盖掉这十几秒里学生的输入。
      final current = practiceQuestions.indexWhere((q) => q.id == questionId);
      if (current < 0) {
        return const OpResult.fail('题目已不在列表里，识别结果已丢弃');
      }

      // ⚠️ 本地兜底返回的是一段**编造的文字**（`source == local`）。
      // 把它填进作答框等于替学生写了一份他从没写过的答案，
      // 而他会以为那是系统认出来的。所以这一支**只提示、不填**。
      if (!recognition.isUsable) {
        return OpResult.fail(
          recognition.text.trim().isEmpty
              ? '这张照片里没看到手写作答，请重拍或直接输入'
              : '现在无法识别手写，请直接输入你的答案',
        );
      }

      answerPractice(questionId, recognition.text);

      final buffer = StringBuffer(
        recognition.needsReview ? '已填入识别结果，提交前请核对一遍' : '已填入识别结果',
      );
      if (recognition.uncertain.trim().isNotEmpty) {
        buffer.write('：${recognition.uncertain.trim()}');
      }
      return OpResult.success(buffer.toString());
    } catch (error) {
      // 存储写不进去（Web 端配额、磁盘满）是一条会静默丢照片的路，
      // 必须说出来。否则学生看到的是「识别失败」，而真相是照片没存下。
      return OpResult.fail('照片未能保存：$error');
    } finally {
      capturingAnswer.value = false;
    }
  }

  /// 判定一道变式题：**能本地判就不调模型**。
  ///
  /// 选择题与判断题的答案集合是封闭的（A–D / 正确-错误），比对即结论。
  /// 这不只是省一次调用 —— 模型判选择题会有概率性波动：同一个答案
  /// 两次得到不同结论，学生完全无法理解，而错题本里会多出一堆假错题。
  ///
  /// 填空与解答一律交给模型：`0.5` 与 `1/2` 在数学上等价，字符串比对
  /// 会把做对的学生判错。那种「省钱」是拿正确性换的，不做。
  Future<AnswerJudgement> _judgePractice(AiPracticeQuestion question) async {
    final local = gradeLocally(
      type: question.questionType,
      studentAnswer: question.studentAnswer,
      correctAnswer: question.answer,
      options: question.options,
    );

    if (local != LocalGrade.undecidable) {
      final correct = local == LocalGrade.correct;
      return AnswerJudgement(
        verdict: correct ? AnswerVerdict.correct : AnswerVerdict.wrong,
        score: correct ? 100 : 0,
        comment: correct
            ? '答对了。'
            : '答错了。正确答案是 ${question.answer}，'
                  '对照讲解再看一遍这一步。',
        source: AiAnswerSource.rule,
      );
    }

    return ai.judgeAnswer(
      studentAnswer: question.studentAnswer,
      referenceAnswer: question.answer,
      subject: question.subject,
      knowledgePoint: question.knowledgePoint,
      questionContent: question.content,
    );
  }

  /// 单题检查。
  Future<OpResult> checkPractice(String questionId) async {
    if (submittingPractice.value) {
      return const OpResult.fail('上一题还在检查，等它出结果再点');
    }
    final index = practiceQuestions.indexWhere((q) => q.id == questionId);
    if (index < 0) return const OpResult.fail('题目不存在');
    final question = practiceQuestions[index];
    if (question.studentAnswer.trim().isEmpty) {
      // ⚠️ 这条早退看的是**文字**。而作答现在有两条来路：手动输入与拍照。
      //    · 拍了照还没识别完 → 拦住是**对的**，但文案要说清是「正在识别」
      //      而不是「你没作答」——后者会让学生以为照片白拍了，再去拍一张。
      //    · 识别失败（本地兜底、图没送上去）→ 作答确实是空的，按未作答处理，
      //      但同样要指出「照片那条路没成」，否则他会一直重拍。
      // 两种情况都必须与「他就是没写」区分开，否则学生面对的是一个
      // 「我明明拍了照你却说我空白」的界面，而没有任何线索能解释为什么。
      if (capturingAnswer.value) {
        return const OpResult.fail('照片还在识别中，等识别结果出来再提交');
      }
      return const OpResult.fail('请先作答再提交检查');
    }

    submittingPractice.value = true;
    try {
      final judged = await _judgePractice(question);
      // 单题检查也算一次模型判定，一并记进影子比对。
      // 学生会先逐题「检查」再「提交」——同一道题因此被记两次，
      // 这是刻意的：口径是**模型判定了多少次**，不是「涉及多少道题」。
      // 按题去重会得到一个说不清的分母（一道题检查 3 次算 1 次还是 3 次？）。
      final mistake = mistakeById(question.sourceMistakeId);
      if (mistake != null) {
        final ab = await _compareWithRules(
          judgement: judged,
          mistake: mistake,
          channel: AttemptChannel.practice,
          studentAnswer: question.studentAnswer,
          referenceAnswer: question.answer,
          subject: question.subject,
          knowledgePoint: question.knowledgePoint,
          questionContent: question.content,
        );
        if (ab != null) {
          await _review.insertJudgementABRecords([ab]);
        }
      }
      // 判定期间学生可能还在改这一题。写回时按 id 重新取**当前**那条，
      // 而不是用判定开始时的快照 —— 快照会把这段输入一并覆盖掉。
      final current = practiceQuestions.indexWhere((q) => q.id == questionId);
      if (current < 0) return const OpResult.fail('题目已不在列表里');
      final correct = judged.passed;
      practiceQuestions[current] = practiceQuestions[current].copyWith(
        state: correct ? PracticeState.correct : PracticeState.wrong,
        checkedAt: DateTime.now(),
      );
      await _review.updatePracticeQuestion(
        practiceQuestions[current],
      );
      return OpResult.success(judged.comment);
    } finally {
      submittingPractice.value = false;
    }
  }

  /// 提交全部变式题：全对才算这道错题的练习通过。
  ///
  /// 全对之后仍走 [ReviewService.judge] 同一条毕业判定 —— 反复错的题
  /// 一样需要连续两轮，不会因为换了个练习形式就放宽。
  Future<OpResult> submitAllPractice(String mistakeId) async {
    if (submittingPractice.value) {
      return const OpResult.fail('正在检查中，不要重复点');
    }
    submittingPractice.value = true;
    try {
      return await _submitAllPractice(mistakeId);
    } finally {
      submittingPractice.value = false;
    }
  }

  /// [submitAllPractice] 的实际实现。
  ///
  /// 单独拆出来只是为了让提交态的复位进 finally —— 这个函数里早退分支
  /// 很多（没生成题、没作答、没通过、题目已不在列表里），
  /// 逐个补复位迟早会漏一个，而漏掉的那次会让按钮从此卡在灰色。
  Future<OpResult> _submitAllPractice(String mistakeId) async {
    final mistake = mistakeById(mistakeId);
    if (mistake == null) return const OpResult.fail('错题不存在');
    final questions = questionsOf(mistakeId);
    if (questions.isEmpty) return const OpResult.fail('还没有生成变式题');

    final unanswered = questions
        .where((q) => q.studentAnswer.trim().isEmpty)
        .length;
    if (unanswered > 0) {
      // 同上：把「照片还在识别」和「确实没作答」分开说。
      // 三道题一起提交时，学生很可能刚拍完最后一张 ——
      // 这时候报「还有 1 道没作答」会让他回头去改一道其实已经拍了的题。
      if (capturingAnswer.value) {
        return const OpResult.fail('有照片还在识别中，等全部识别完再提交');
      }
      return OpResult.fail('还有 $unanswered 道题没有作答');
    }

    final now = DateTime.now();
    var correctCount = 0;
    final abRecords = <JudgementABRecord>[];
    for (final question in questions) {
      final judged = await _judgePractice(question);
      final correct = judged.passed;
      if (correct) correctCount++;

      final ab = await _compareWithRules(
        judgement: judged,
        mistake: mistake,
        channel: AttemptChannel.practice,
        studentAnswer: question.studentAnswer,
        referenceAnswer: question.answer,
        subject: question.subject,
        knowledgePoint: question.knowledgePoint,
        questionContent: question.content,
      );
      if (ab != null) abRecords.add(ab);

      // 三道题是**串行**送模型的，整轮实测要十几秒。写回时按 id 重新取
      // **当前**那一条，而不是用进循环时的快照：这十几秒里学生很可能
      // 还在改后面的题，用快照回写会把那段输入抹掉 ——
      // 现象就是「点提交，某几题的输入没了」。
      final index = practiceQuestions.indexWhere((q) => q.id == question.id);
      if (index < 0) continue;
      practiceQuestions[index] = practiceQuestions[index].copyWith(
        state: correct ? PracticeState.correct : PracticeState.wrong,
        checkedAt: now,
      );
      await _review.updatePracticeQuestion(practiceQuestions[index]);
    }
    await _review.insertJudgementABRecords(abRecords);

    final allCorrect = correctCount == questions.length;
    final history = attemptsOf(mistakeId);
    final round = ReviewService.nextRound(history);
    final decision = ReviewService.judge(
      mistake: mistake,
      passed: allCorrect,
      history: history,
    );

    final attempt = ReviewAttempt(
      id: ReviewService.newId('at'),
      studentId: mistake.studentId,
      mistakeId: mistakeId,
      channel: AttemptChannel.practice,
      round: round,
      answer: '${questions.length} 道变式题答对 $correctCount 道',
      correct: allCorrect,
      score: (correctCount / questions.length * 100).round(),
      comment: allCorrect
          ? '3 道变式题全部正确。'
          : '变式题答对 $correctCount/${questions.length} 道。',
      createdAt: now,
    );
    attempts.add(attempt);
    await _review.insertReviewAttempt(attempt);

    _replaceMistake(_applyDecision(mistake, decision, now));
    final updated = mistakeById(mistakeId);
    if (updated != null) {
      await _review.updateReviewMistakeState(
        updated.id,
        updated.state,
        wrongCount: updated.wrongCount,
        lastWrongAt: updated.lastWrongAt,
        reviewRound: updated.reviewRound,
        lastReviewedAt: updated.lastReviewedAt,
        masteredAt: updated.masteredAt,
        masteredBySelf: updated.masteredBySelf,
      );
    }

    if (!allCorrect) {
      return OpResult.fail(
        '答对 $correctCount/${questions.length} 道，还没到毕业标准。${decision.reason}',
      );
    }
    return OpResult.success(decision.reason);
  }

  // ===== 自评掌握 =====

  /// 学生自评「标记掌握」。
  ///
  /// 记为 `masteredBySelf`，**不计入掌握率**：没有任何作答证据的掌握
  /// 不能和通过检查的掌握混在一个数字里，否则掌握率就不值得看了。
  Future<OpResult> markMasteredBySelf(String mistakeId) async {
    final mistake = mistakeById(mistakeId);
    if (mistake == null) return const OpResult.fail('错题不存在');
    if (mistake.state == ReviewState.mastered) {
      return const OpResult.fail('这道题已经移出错题库了');
    }

    final now = DateTime.now();
    final updated = mistake.copyWith(
      state: ReviewState.mastered,
      masteredAt: now,
      masteredBySelf: true,
      lastReviewedAt: now,
    );
    _replaceMistake(updated);
    await _review.updateReviewMistakeState(
      mistakeId,
      updated.state,
      masteredAt: now,
      masteredBySelf: true,
      lastReviewedAt: now,
    );
    return const OpResult.success('已标记为掌握（自评不计入掌握率）');
  }

  // ===== 时间线 =====

  Future<List<MistakeTimelineEntry>> timelineOf(String mistakeId) async {
    final mistake = mistakeById(mistakeId);
    if (mistake == null) return const [];
    List<ExplainRecord> explanations;
    try {
      explanations = await LocalSeedService.explainRecords(
        mistakeId: mistakeId,
      );
    } catch (_) {
      explanations = const [];
    }
    return ReviewService.timeline(
      mistake: mistake,
      attempts: attemptsOf(mistakeId),
      explanations: explanations,
    );
  }

  // ===== 手工录入错题 =====

  /// 已知科目（含「全部」以外的去重结果）。
  ///
  /// 录入表单用它做候选，但**不限制只能选这些**：历史错题可能来自
  /// 目前没有错题的科目，把输入框做成只读下拉，等于逼用户先伪造一道题。
  List<String> get knownSubjects {
    final subjects = <String>{};
    for (final mistake in mistakes) {
      if (mistake.subject.isNotEmpty) subjects.add(mistake.subject);
    }
    return subjects.toList()..sort();
  }

  /// 手工录入一道错题（历史错题、老师口头布置的题、拍照扫描都走这里）。
  ///
  /// 与作业批改产出的错题唯一的差别是 `homeworkId` 为空、来源由 [sourceType]
  /// 显式写明。这一点必须落库：家长端要能区分「系统批出来的」和
  /// 「孩子自己记下来的」，后者的可信度本来就不一样。
  ///
  /// [photos] 是**先上传字节、再写行**：任何一张传不上去就整条失败，
  /// 不会留下「题在、图没了」的半条记录（本地实现里题与图在一个事务里）。
  /// 从原题照片里提取题目，供录入页预填。
  ///
  /// ## 它只提取，不判定
  ///
  /// 学生主动提交的是**他认定的错题**，对错已经由他定下。所以这里既不
  /// 判断题目对错，也不往错题库里写任何东西 —— 写库仍然是
  /// [addMistakeManually] 的事，由学生看过识别结果之后触发。
  ///
  /// ## 为什么照片要先落存储
  ///
  /// 网关拿图靠的是 storageKey（见 `HomeworkImageUploader`），
  /// 所以识别之前必须先存一次。存完把键返回给页面，保存时回传复用 ——
  /// 否则同一批照片要传两遍。
  ///
  /// 失败**不抛异常**：识别不成功是常见状态（断网、离线版、照片太糊），
  /// 页面据此提示「请手动填写」即可。抛异常会让录入页在断网时整页报错，
  /// 而学生其实手打一遍就能提交。
  Future<MistakeIntakeScan> scanMistakePhotos({
    required List<MistakeIntakePhoto> photos,
    String hint = '',
  }) async {
    if (photos.isEmpty) {
      return const MistakeIntakeScan(
        extraction: MistakeExtraction(),
        failure: '还没有照片',
      );
    }
    if (photos.length > maxIntakePhotos) {
      return MistakeIntakeScan(
        extraction: const MistakeExtraction(),
        failure: '一次最多 $maxIntakePhotos 张照片',
      );
    }

    final keys = <String>[];
    for (var i = 0; i < photos.length; i++) {
      final photo = photos[i];
      try {
        final stored = await imageStorage.saveHomeworkImage(
          studentId: _currentStudentId,
          fileName: photo.fileName,
          bytes: photo.bytes,
          mimeType: photo.mimeType,
          sortOrder: i,
        );
        if (stored.storageKey.isEmpty) {
          return const MistakeIntakeScan(
            extraction: MistakeExtraction(),
            failure: '照片上传后没有返回存储键，换一张试试',
          );
        }
        keys.add(stored.storageKey);
      } catch (e) {
        return MistakeIntakeScan(
          extraction: const MistakeExtraction(),
          failure: '照片上传失败：$e',
        );
      }
    }

    try {
      final extraction = await ai.extractMistakes(
        imagePaths: keys,
        hint: hint,
      );
      return MistakeIntakeScan(extraction: extraction, storageKeys: keys);
    } catch (e) {
      // 照片已经传上去了：返回 keys 让学生手填后仍能带着原图入库。
      //
      // ⚠️ 面向学生的文案不带 `$e`：原始异常里是英文栈信息
      // （`AiRequestException.toString()` 含状态码与 URL），学生既看不懂，
      // 也没法据此做什么。原始异常留在日志里给排查用。
      debugPrint('[review] 错题识别失败：$e');
      return MistakeIntakeScan(
        extraction: const MistakeExtraction(),
        storageKeys: keys,
        failure: '识别失败，检查网络后重试，或直接手动填写题干',
      );
    }
  }

  Future<OpResult> addMistakeManually({
    required String subject,
    String title = '',
    String questionBody = '',
    String answerKey = '',
    String knowledgePoint = '',
    String originalAnswer = '',
    String wrongReason = '',
    MistakeSource sourceType = MistakeSource.manual,
    String grade = '',
    String term = '',
    List<MistakeIntakePhoto> photos = const [],
    List<String> preparedStorageKeys = const [],
  }) async {
    final trimmedSubject = subject.trim();
    final trimmedBody = questionBody.trim();
    // 标题可以是空的：扫描/抄题时最先有的是题干。用题干首行兜底成短标题，
    // 但**不要**把它写回 questionBody —— 两者语义不同（见 ReviewMistake.title）。
    final trimmedTitle = title.trim().isNotEmpty
        ? title.trim()
        : _titleFromBody(trimmedBody);
    if (trimmedTitle.isEmpty && trimmedBody.isEmpty) {
      return const OpResult.fail('请填写题目内容');
    }
    if (trimmedSubject.isEmpty) return const OpResult.fail('请选择科目');
    // 重复提交闸门（2026-10-21）：
    //
    // 实测过一次「一道题变成 4 条」—— 4 条题干 md5 完全相同、
    // 引用的是**同一张照片**（storage_key 相同），间隔 1~14 秒。
    // 也就是同一个编辑页被提交了 4 次，而界面每次都提示「已保存」。
    //
    // 光靠按钮上的 `_saving` 挡不住（页面没关掉时它会被重置），
    // 所以这里按**内容**判重：同样的话说第二遍，不该变成第二道题。
    //
    // ⚠️ 返回值是**成功**而不是失败：报失败会让人以为没存上，然后再点一次。
    final duplicate = _findRecentDuplicateMistake(trimmedBody);
    if (duplicate != null) {
      return OpResult.success(
        '这道题 ${_minutesAgoLabel(duplicate.createdAt)} 已经加过了，没有重复添加',
      );
    }
    if (photos.length > maxIntakePhotos) {
      return OpResult.fail('一次最多 $maxIntakePhotos 张照片');
    }

    final now = DateTime.now();
    final mistakeId = ReviewService.newId('rm');

    // 先把图片传上去。失败就整条中止：此时数据库里一行都没有。
    //
    // 识别过一次（`scanMistakePhotos`）就把那批 storageKey 一起带回来，
    // 这里直接复用：同一批字节再传一遍，在手机网络下就是保存按钮
    // 多转好几秒，而传上去的还是同一份东西。
    final canReuse = preparedStorageKeys.length == photos.length;
    final images = <ReviewMistakeImage>[];
    for (var i = 0; i < photos.length; i++) {
      final photo = photos[i];
      try {
        final reused = canReuse ? preparedStorageKeys[i] : '';
        if (reused.isNotEmpty) {
          images.add(
            ReviewMistakeImage(
              id: ReviewService.newId('rmi'),
              studentId: _currentStudentId,
              mistakeId: mistakeId,
              storageKey: reused,
              mimeType: photo.mimeType,
              fileSize: photo.bytes.length,
              sortOrder: i,
              createdAt: now,
            ),
          );
          continue;
        }

        final stored = await imageStorage.saveHomeworkImage(
          studentId: _currentStudentId,
          fileName: photo.fileName,
          bytes: photo.bytes,
          mimeType: photo.mimeType,
          sortOrder: i,
        );
        if (stored.storageKey.isEmpty) {
          return const OpResult.fail('照片上传后没有返回存储键，换一张试试');
        }
        images.add(
          ReviewMistakeImage(
            id: ReviewService.newId('rmi'),
            studentId: _currentStudentId,
            mistakeId: mistakeId,
            storageKey: stored.storageKey,
            mimeType: stored.mimeType,
            fileSize: stored.fileSize,
            sortOrder: i,
            createdAt: now,
          ),
        );
      } catch (e) {
        return OpResult.fail('照片上传失败：$e');
      }
    }

    final mistake = ReviewMistake(
      id: mistakeId,
      subject: trimmedSubject,
      title: trimmedTitle,
      questionBody: trimmedBody,
      answerKey: answerKey.trim(),
      sourceType: sourceType,
      grade: grade.trim(),
      term: term.trim(),
      imageCount: images.length,
      originalAnswer: originalAnswer.trim(),
      // 错因空着就空着。
      //
      // 以前这里拿 `sourceType.label`（「拍照录入」）顶上，于是卷面上
      // 印出「上次的错误原因：拍照录入」—— 一句没有任何信息量的话，
      // 还会让人以为这条错题已经写过错因了。
      wrongReason: wrongReason.trim(),
      createdAt: now,
      state: ReviewState.pending,
      studentId: _currentStudentId,
      knowledgePoint: knowledgePoint.trim(),
      wrongCount: 1,
      lastWrongAt: now,
      sourceHomeworkTitle: sourceType.label,
    );

    try {
      await _review.insertReviewMistakeWithImages(mistake, images);
    } catch (_) {
      return const OpResult.fail('保存失败，请稍后重试');
    }
    mistakes.insert(0, mistake);
    mistakes.refresh();
    return const OpResult.success('已加入错题库，可以参与组卷了');
  }

  /// 一次录入最多几张照片。与设计文档一致：先做单题 1–3 张，
  /// 多页试卷属于「整卷拆题」，需要单独的确认流程。
  static const int maxIntakePhotos = 6;

  /// 题干首行前 24 个字符作为短标题。
  String _titleFromBody(String body) {
    if (body.isEmpty) return '';
    final firstLine = body.split('\n').first.trim();
    final plain = firstLine.replaceAll(RegExp(r'\$+'), '');
    if (plain.isEmpty) return '';
    return plain.length <= 24 ? plain : '${plain.substring(0, 24)}…';
  }

  /// 「同一道题刚加过」的时间窗。
  ///
  /// 5 分钟：够覆盖「以为没存上，又点一次」，又不会挡住
  /// 「这道题过几天又错了、要再进一次错题库」这种真实情况。
  static const Duration duplicateWindow = Duration(minutes: 5);

  /// 找一条**内容相同、刚刚加过**的待复习错题。
  ///
  /// 只比题干、不看图片：解过同一张照片的两条记录，题干必然一样；
  /// 而「题干一样但图不同」也确实是同一道题，一样该拦。
  ReviewMistake? _findRecentDuplicateMistake(String body) {
    final normalized = _normalizeForDuplicate(body);
    if (normalized.isEmpty) return null;
    final now = DateTime.now();
    for (final mistake in mistakes) {
      // 只拦待复习的：已经掌握/已归档的题，再错一次是正常业务。
      if (mistake.state != ReviewState.pending) continue;
      if (now.difference(mistake.createdAt) > duplicateWindow) continue;
      if (_normalizeForDuplicate(mistake.questionBody) == normalized) {
        return mistake;
      }
    }
    return null;
  }

  /// 判重用的归一化。
  ///
  /// 空白和全半角标点不该影响「这是不是同一句话」：拍照识别出来的题干
  /// 换一次识别可能多一个空格、把 `,` 写成 `，` —— 那种差别不算新题。
  static String _normalizeForDuplicate(String text) => text
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('（', '(')
      .replaceAll('）', ')')
      .replaceAll('，', ',')
      .replaceAll('：', ':')
      .replaceAll('。', '.');

  static String _minutesAgoLabel(DateTime at) {
    final minutes = DateTime.now().difference(at).inMinutes;
    return minutes <= 0 ? '刚刚' : '$minutes 分钟前';
  }

  /// 某道错题的原题照片。
  ///
  /// 直接透传给仓库，不在控制器里缓存：详情页每次进入只查一次，
  /// 缓存反而会让「刚补传了一张图却看不到」变成一个需要手动刷新的问题。
  Future<List<ReviewMistakeImage>> loadMistakeImages(String mistakeId) =>
      _review.queryMistakeImages(mistakeId);

  /// 错题图片的读取端点（与详情页、快照页同一个）。
  static const String _mistakeImageEndpoint = '/data/review/mistake-images/file';

  /// 错题图片 → 作业图片模型。
  ///
  /// 两者字段几乎一样，但读图的那个类只认 `HomeworkImageModel`（它同时服务
  /// 作业照片和错题照片，端点由参数区分）。这里做一次显式转换，
  /// 而不是给错题图片模型加一个「看起来像作业图片」的方法 —— 那样以后
  /// 两个模型各自演进时，会有一堆默默失效的字段。
  HomeworkImageModel _toImageModel(ReviewMistakeImage image) {
    return HomeworkImageModel(
      id: image.id,
      studentId: image.studentId,
      homeworkId: null,
      storageKey: image.storageKey,
      fileName: '',
      fileSize: image.fileSize,
      mimeType: image.mimeType,
      ocrStatus: '',
      ocrText: '',
      createdAt: image.createdAt ?? DateTime.now(),
      sortOrder: image.sortOrder,
    );
  }

  /// 要送出去的**原题照片**（举一反三出题、错题讲解两处共用）。
  ///
  /// 取不到就返回空列表 —— **不抛异常**：出题和讲解这两件事都不能被一张
  /// 读不出来的照片整个毁掉。没有图时模型退回「按题干讲/按知识点出」，
  /// 结果会笼统，但仍然有用。这比「点了没反应」好得多，
  /// 但也不能静默：取图失败会留一条 debugPrint。
  Future<List<AiSourceImage>> _sourceImages(ReviewMistake mistake) async {
    if (mistake.imageCount <= 0) return const [];
    try {
      final stored = await loadMistakeImages(mistake.id);
      final out = <AiSourceImage>[];
      // 只取前两张：一道错题拍到两三张已经是极限，多传既贵又慢，
      // 而模型对「第 3 张图」的利用远不如对「第 2 张」。
      for (final image in stored.take(2)) {
        final bytes = await HomeworkImageReader.load(
          _toImageModel(image),
          endpoint: _mistakeImageEndpoint,
        );
        if (bytes == null || bytes.isEmpty) continue;
        out.add(AiSourceImage(bytes: bytes, mimeType: image.mimeType));
      }
      return out;
    } catch (error) {
      debugPrint('[复习] 取原题照片失败，本次按纯文字出题：$error');
      return const [];
    }
  }

  /// 编辑一道错题（补知识点、修正题干、补错因）。
  ///
  /// 知识点是组卷、讲解、举一反三三项能力的共同驱动键，手工录入时
  /// 填错的代价最大——空着还能兜底成「科目·未标注」，填错会把讲解
  /// 引到完全无关的知识点上，所以这里必须允许回头改。
  Future<OpResult> updateMistake({
    required String mistakeId,
    required String subject,
    required String title,
    String? questionBody,
    String? answerKey,
    String? sourceHomeworkTitle,
    String? grade,
    String? term,
    required String knowledgePoint,
    required String originalAnswer,
    required String wrongReason,
  }) async {
    final existing = mistakeById(mistakeId);
    if (existing == null) return const OpResult.fail('错题不存在');
    if (title.trim().isEmpty && (questionBody ?? existing.questionBody).trim().isEmpty) {
      return const OpResult.fail('请填写题目内容');
    }
    if (subject.trim().isEmpty) return const OpResult.fail('请选择科目');

    final updated = existing.copyWith(
      subject: subject.trim(),
      title: title.trim().isEmpty ? existing.title : title.trim(),
      questionBody: questionBody?.trim(),
      answerKey: answerKey?.trim(),
      sourceHomeworkTitle: sourceHomeworkTitle?.trim(),
      grade: grade?.trim(),
      term: term?.trim(),
      knowledgePoint: knowledgePoint.trim(),
      originalAnswer: originalAnswer.trim(),
      wrongReason: wrongReason.trim(),
    );
    try {
      await _review.updateReviewMistake(updated);
    } catch (_) {
      return const OpResult.fail('保存失败，请稍后重试');
    }
    _replaceMistake(updated);
    return const OpResult.success('已更新');
  }

  /// 删除一道错题。
  ///
  /// **在卷的题不允许删**：它已经印在纸上（或已回传等批改），
  /// 删掉主体会让卷内快照指向一道不存在的题，批改时这道题既判不了
  /// 也毕不了业，整份资料会卡在「待批改」再也走不完。
  Future<OpResult> removeMistake(String mistakeId) async {
    final mistake = mistakeById(mistakeId);
    if (mistake == null) return const OpResult.fail('错题不存在');
    if (mistake.state == ReviewState.reviewing ||
        mistake.state == ReviewState.verifying) {
      return OpResult.fail(
        '这道题在复习资料里（${mistake.state.label}），先完成资料批改再删除。',
      );
    }

    try {
      await _review.deleteReviewMistake(mistakeId);
    } catch (_) {
      return const OpResult.fail('删除失败，请稍后重试');
    }
    mistakes.removeWhere((item) => item.id == mistakeId);
    attempts.removeWhere((item) => item.mistakeId == mistakeId);
    practiceQuestions.removeWhere((item) => item.sourceMistakeId == mistakeId);
    explanations.removeWhere((item) => item.mistakeId == mistakeId);
    mistakes.refresh();
    return const OpResult.success('已删除');
  }

  // ===== 周期报告（周报 / 月报） =====

  void setReportScope(SummaryScope scope) => reportScope.value = scope;

  /// 计算当前周期的报告。
  ///
  /// 刻意做成**只计算、不落库**：报告页切来切去是高频动作，
  /// 每切一次写一条 summary 会让「报告列表」被同一周的十几份副本刷屏。
  /// 落库交给用户显式触发的 [saveReport]。
  PeriodReport buildReport(SummaryScope scope) => ReviewService.buildPeriodReport(
    scope: scope,
    now: DateTime.now(),
    pool: mistakes.toList(),
    papers: papers.toList(),
    attempts: attempts.toList(),
    explanations: explanations.toList(),
  );

  /// 把报告落库（同一周期覆盖，不产生副本）。
  Future<ReviewSummary> saveReport(SummaryScope scope) async {
    final now = DateTime.now();
    final summary = buildReport(
      scope,
    ).toSummary(studentId: _currentStudentId, now: now);
    await _review.insertReviewSummary(summary);
    summaries.removeWhere(
      (item) => item.scope == summary.scope && item.scopeKey == summary.scopeKey,
    );
    summaries.insert(0, summary);
    return summary;
  }

  /// 已落库的周期报告。
  ReviewSummary? storedReport(SummaryScope scope) {
    final key = ReviewService.periodKey(scope, DateTime.now());
    for (final summary in summaries) {
      if (summary.scope == scope && summary.scopeKey == key) return summary;
    }
    return null;
  }

  /// 把报告转成可复制分享的纯文本。
  ///
  /// 家长群里发一句「本周通过 8 次，还有 5 道在池里」，比截图好使。
  String reportPlainText(PeriodReport report) {
    final buffer = StringBuffer()
      ..writeln(report.body)
      ..writeln('')
      ..writeln('分科情况：');
    if (report.subjectAttempts.isEmpty) {
      buffer.writeln('  本周期暂无作答记录');
    } else {
      final subjects = report.subjectAttempts.keys.toList()..sort();
      for (final subject in subjects) {
        final attempts = report.subjectAttempts[subject] ?? 0;
        final passes = report.subjectPasses[subject] ?? 0;
        final rate = attempts == 0 ? 0 : (passes / attempts * 100).round();
        buffer.writeln('  ${subject.isEmpty ? '未标注科目' : subject}：通过 $passes/$attempts（$rate%）');
      }
    }
    if (report.suggestions.isNotEmpty) {
      buffer
        ..writeln('')
        ..writeln('下一步建议：');
      for (final item in report.suggestions) {
        buffer.writeln('  · $item');
      }
    }
    return buffer.toString().trim();
  }

  // ===== 内部工具 =====

  void _replaceMistake(ReviewMistake updated) {
    final index = mistakes.indexWhere((item) => item.id == updated.id);
    if (index < 0) return;
    mistakes[index] = updated;
    mistakes.refresh();
  }

  Future<void> _moveMistakesTo(
    List<String> ids,
    ReviewState state,
    DateTime now,
  ) async {
    for (final id in ids) {
      final index = mistakes.indexWhere((item) => item.id == id);
      if (index < 0) continue;
      // 已掌握的题不再被回卷子：它已经毕业，不该被新的复习状态降级。
      if (mistakes[index].state == ReviewState.mastered) continue;
      final updated = mistakes[index].copyWith(
        state: state,
        lastReviewedAt: now,
      );
      mistakes[index] = updated;
      await _review.updateReviewMistakeState(
        id,
        state,
        lastReviewedAt: now,
      );
    }
    mistakes.refresh();
  }

  Future<ReviewPaper?> _reloadPaper(String paperId) async {
    final all = await _review.queryReviewPapers();
    for (final paper in all) {
      if (paper.id == paperId) {
        final index = papers.indexWhere((p) => p.id == paperId);
        if (index >= 0) {
          papers[index] = paper;
        } else {
          papers.insert(0, paper);
        }
        return paper;
      }
    }
    return null;
  }

  Future<void> _persistPaper(ReviewPaper paper) async {
    await _review.updateReviewPaper(paper);
    final index = papers.indexWhere((p) => p.id == paper.id);
    if (index >= 0) {
      papers[index] = paper;
      papers.refresh();
    }
    if (activePaper.value?.id == paper.id) {
      activePaper.value = paper;
    }
  }

  /// 批改完成通知家长与本人。
  ///
  /// 家长端的价值不在「知道错了」，而在「知道孩子这一周真的坐下来复习了」，
  /// 所以通知里直接给通过数，而不是只报错题数。
  Future<void> _notifyGraded(
    ReviewPaper paper,
    int passCount,
    int failCount,
    int graduated,
  ) async {
    if (!Get.isRegistered<NotificationController>()) return;
    final studentId = _currentStudentId;
    if (studentId.isEmpty) return;

    final body =
        '《${paper.title}》已完成批改：通过 $passCount 道，未通过 $failCount 道，'
        '${graduated > 0 ? '$graduated 道已移出错题库' : '错题已回到待复习池'}。';

    try {
      final relationships = await _relationships.queryRelationships(
        studentId,
      );
      final parentIds = relationships
          .where((r) => r.status == RelationshipStatus.active)
          .map((r) => r.parentId)
          .toSet();
      final controller = Get.find<NotificationController>();
      for (final parentId in parentIds) {
        await controller.addNotification(
          title: '复习批改完成',
          body: body,
          targetUserId: parentId,
          type: NotificationType.review,
          relatedBizId: paper.id,
        );
      }
      await controller.addNotification(
        title: graduated > 0 ? '错题毕业' : '复习结果',
        body: body,
        targetUserId: studentId,
        type: NotificationType.review,
        relatedBizId: paper.id,
      );
    } catch (_) {
      // 通知失败不应该影响批改主流程。
    }
  }

  String get _currentStudentId => Get.isRegistered<AuthController>()
      ? Get.find<AuthController>().currentUser.value?.id ?? ''
      : '';

  String get _currentStudentName => Get.isRegistered<AuthController>()
      ? Get.find<AuthController>().currentUser.value?.name ?? ''
      : '';
}
