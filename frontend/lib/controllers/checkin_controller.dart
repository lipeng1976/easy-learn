import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../models/checkin_models.dart';
import '../models/point_model.dart';
import '../repositories/checkin_repository.dart';
import '../services/data_api_client.dart';
import '../services/database_service.dart';
import '../utils/checkin_label.dart';
import 'auth_controller.dart';
import 'checkin_entry_state.dart';
import 'parent_controller.dart';
import 'point_controller.dart';

/// 一份打卡在界面上的**运行态**：题目快照 + 作答 + 判定结果。
///
/// ## 为什么不是控制器里几张大 Map
///
/// 一天可以有多份打卡（家长分科目出题，2026-10-27 起）。把 `picked`、
/// `result`、`syncError` 摊成几张按 quizId 索引的 Map 的话，每处读取都要
/// 「先取内层、再读值」两层记账，漏一层就是又一次「改了 Rx 没人看」
/// （10-27 真机刚修过一例）。收成一个对象，每份打卡的状态天然隔离：
/// 数学卷交了、英语卷还在答，互不可见。
class CheckinRun {
  CheckinRun(CheckinQuiz initial)
      : quiz = Rx<CheckinQuiz>(initial),
        // ⚠️ 已交过卷的快照（`submittedResult`）必须带进 `result`，
        // 否则 `submitted`（= result.value != null）会是 false —— 家长打开
        // 历史成绩时控制器说「还没答」、页面却要它显示结果态，自相矛盾。
        result = Rxn<CheckinSubmitResult>(initial.submittedResult);

  final Rx<CheckinQuiz> quiz;
  final picked = <int, String>{}.obs;
  final Rxn<CheckinSubmitResult> result;
  final syncError = RxnString();
  final syncConflict = RxBool(false);
  final busy = RxBool(false);

  bool get submitted => result.value != null;
  int get answeredCount => picked.length;
  bool get allAnswered =>
      quiz.value.total > 0 && picked.length >= quiz.value.total;
}

/// 每日概念打卡的状态机。
///
/// ## 出题在服务端，判分**本机先出、服务端再复算**
///
///  ① **出题**：错题聚合、调模型、落库全在数据服务
///     （`POST /data/checkin/generate`）。客户端一次请求拿到当天那一份题。
///  ② **判分**：交卷瞬间在本机判（`CheckinSubmitResult.judge`），立刻出分；
///     同时把作答送去服务端复算入库。存不上**不撤销**已经显示的结果，
///     改为标「未同步」并允许重试（见 [CheckinRun.syncError]）。
///
/// 为什么答案可以到孩子端：判定依据必须在本机，否则弱网下交完卷只能干等。
/// 「看不到答案」由渲染层保证 —— 答题态只画题干和选项，绝不碰
/// `answer` / `analysis`，这条由 `test/checkin_question_card_test.dart` 盯着。
///
/// ## 一天可以有多份（不按科目排他）
///
/// 日期用**本地日**（`yyyy-MM-dd`）。家长每出一次题就是一份独立试卷：
/// 同一天、同一科目也可以并存好几套（2026-10-27 起取消了
/// 「一天一科目只许一份」），每套各自的题、作答与成绩互不干扰。
/// 学生自发起仍固定走数学（兜底路径，没有选范围的界面）。
class CheckinController extends GetxController {
  CheckinController({
    CheckinRepository? repository,
    DateTime Function()? clock,
    PointController? points,
  })  : _repo = repository ?? DatabaseService.checkin,
        // 命名参数不能以 `_` 开头，所以没法用 initializing formal。
        // 用静态函数 `_defaultClock` 的 tear-off 而不是 `DateTime.now`：
        // 后者在初始化列表的 `??` 表达式里会被推断成 Object。
        _clock = clock ?? _defaultClock,
        // 命名参数不能以 `_` 开头，所以这里用不了 initializing formal
        // （lint 建议的 `this._points` 在本语言里写不出来）。
        // ignore: prefer_initializing_formals
        _points = points;

  /// 默认时钟（可测）：返回当前时刻。
  static DateTime _defaultClock() => DateTime.now();

  final CheckinRepository _repo;
  final DateTime Function() _clock;

  /// 记分发分用的控制器。
  ///
  /// 默认 **null**，真正用到时才 `Get.find`/`Get.put`：构造期可能还没有
  /// 任何页面把 `PointController` 注册进 GetX，直接 `Get.find` 会抛
  /// 「not found」—— 而那个异常会发生在 `initState` 里，表现为整页白屏。
  ///
  /// 显式传入时（测试、家长端代做场景）就用传进来的那个，不碰全局。
  final PointController? _points;

  PointController get _pointController => _points ?? PointController.to;

  /// 已完成分页的每页条数。
  ///
  /// 10 是「往回翻」的量：再少就要连点好几次，再多会把上面的未完成挤下去。
  static const int donePageSize = 10;

  /// **未完成** —— 跨天、全量、按出题时间正序。
  ///
  /// 为什么不限日期：家长头天晚上出的题，孩子第二天打开就该还在（2026-10-29
  /// 用户报的「看得到未完成、点进去没有」就是按天过滤造成的）。也不分页：
  /// 通常一两份，而漏掉最老的那份恰好是孩子最该补的。
  final RxList<CheckinRun> pendingRuns = <CheckinRun>[].obs;

  /// **已完成** —— 按交卷时间倒序，每页 [donePageSize] 条。
  final RxList<CheckinRun> doneRuns = <CheckinRun>[].obs;

  /// 已完成的总条数（服务端给的，不是 `doneRuns.length` —— 后者只是已加载的部分）。
  final RxInt doneTotal = 0.obs;

  /// 每科**已交卷**的份数（学生端已完成区的科目色块）。
  ///
  /// 与 [doneRuns] 是两种口径，别互相替代：`doneRuns` 只有已加载的那一页，
  /// 用它数「数学几份」在翻页前永远是错的且不报错；这里来自服务端
  /// `group by`，是**真数**。
  ///
  /// 读不到（老服务端 404 / 断网）时留空 —— 页面据此退回平铺列表，
  /// 而不是显示一块「已完成 12 份」却没有任何色块的空区。
  final RxList<CheckinSubjectSummary> subjectSummaries =
      <CheckinSubjectSummary>[].obs;

  final RxBool doneHasMore = false.obs;
  final RxBool loadingMore = false.obs;

  /// 出题候选：家长挑知识点时看到的列表（按累计错次降序）。
  ///
  /// 空列表有两种可能：错题本真的空，或者还没加载完 —— 所以另有一个
  /// [seedsLoading]。用「列表空 = 加载完且没数据」会让配置页在加载的那一瞬
  /// 显示「你还没有错题」，然后跳一下变成十几条。
  final RxList<CheckinSeed> seeds = <CheckinSeed>[].obs;

  final RxBool seedsLoading = false.obs;

  /// 发起出题进行中（页面空态卡的转圈）。
  final RxBool busy = false.obs;

  final RxBool loading = false.obs;

  /// 页面级失败原因（出题 / 读题失败，已是可直接展示的中文）。null = 没错。
  ///
  /// 它存在而不是用 Snackbar 的原因：出题失败时页面会停在「还没有今天的题」，
  /// 如果错误只在一次性的浮层里，用户回头就不知道刚才为什么没成功。
  final RxnString error = RxnString();

  String get today => formatDate(_clock());

  /// 一份都还没有（既没做完的、也没有历史）。
  bool get isEmpty => pendingRuns.isEmpty && doneRuns.isEmpty && doneTotal.value == 0;

  /// 未完成 + 已加载的已完成，合并视图。
  ///
  /// ⚠️ **只给「这一份还在不在」这类查询和测试用，别用它做渲染**：
  /// 每次调用都新建一个 List，拿不到服务端总数，也把「未完成 / 已完成」
  /// 这个分区信息抹平了 —— 页面要分别读 [pendingRuns] / [doneRuns]。
  List<CheckinRun> get runs => [...pendingRuns, ...doneRuns];

  CheckinRun? runFor(String quizId) {
    for (final run in pendingRuns) {
      if (run.quiz.value.id == quizId) return run;
    }
    for (final run in doneRuns) {
      if (run.quiz.value.id == quizId) return run;
    }
    return null;
  }

  /// 静态可测的日期格式。真值在 `checkinDateKey`，别在页面里再拼一次。
  static String formatDate(DateTime at) => checkinDateKey(at);

  /// 这份打卡挂在谁名下：学生是自己，家长是第一个结伴孩子。
  ///
  /// ⚠️ 两个端点（`GET /data/checkin/quiz` 与 `POST /data/checkin/quiz`）
  /// 都靠 `requireVisibleStudent` 校验 studentId，**空值直接 400**。
  /// 所以这里必须给出具体 id，不能「不传让服务端自己猜」。
  ///
  /// 收成**静态单点**是因为它有多处消费者（打卡页、入口卡
  /// `CheckinEntryState`）：各写一份的话，哪天家长端改成「选中的孩子」，
  /// 只改一处就会出现「卡查的是 A、交卷记在 B 名下」—— 两边都不报错。
  /// 多孩子切换 UI 落地时，只改这一个方法。
  static String? targetStudentId() {
    // 未登录（AuthController 还没注册）谈不上「挂在谁名下」——入口卡在
    // 启动早期就会调这里，不能在这里抛。
    if (!Get.isRegistered<AuthController>()) return null;
    final user = Get.find<AuthController>().currentUser.value;
    if (user == null) return null;
    if (user.role != 'parent') return user.id;
    final parent =
        Get.isRegistered<ParentController>() ? Get.find<ParentController>() : null;
    final bound = parent?.boundStudents ?? const [];
    return bound.isEmpty ? null : bound.first.id;
  }

  /// 读打卡：**未完成全量 + 已完成第一页**，两路并行。
  ///
  /// 并行是有意的：弱网下两次串行就是两份 RTT，页面会白等一倍时间。
  /// 两路都失败才算失败 —— 任一路成功都能让页面显示点东西，比整片报错好。
  Future<void> load({String? studentId}) async {
    loading.value = true;
    error.value = null;
    try {
      // 汇总那一路先发出去，与列表并行：弱网下多一次串行就是多一份 RTT。
      // 它自己吞错（见方法内），所以不用 await 在这里 —— 两路列表先出。
      final summaries = _loadSubjectSummaries(studentId);
      final pages = await Future.wait([
        _repo.getQuizzes(studentId: studentId, status: CheckinQuizStatus.pending),
        _repo.getQuizzes(
          studentId: studentId,
          status: CheckinQuizStatus.done,
          limit: donePageSize,
        ),
      ]);
      pendingRuns.assignAll([for (final quiz in pages[0].items) CheckinRun(quiz)]);
      doneRuns.assignAll([for (final quiz in pages[1].items) CheckinRun(quiz)]);
      doneTotal.value = pages[1].total;
      doneHasMore.value = pages[1].hasMore;
      await summaries;
      _syncEntryState(studentId);
    } on DataApiException catch (e) {
      error.value = e.userMessage;
    } finally {
      loading.value = false;
    }
  }

  /// 拉每科已完成的汇总。**自己吞错**：这是页面上的附加信息，
  /// 拿不到时退回平铺列表即可，不该让整页变成红条。
  Future<void> _loadSubjectSummaries(String? studentId) async {
    try {
      final list = await _repo.subjectSummaries(studentId: studentId);
      subjectSummaries.assignAll(list);
    } catch (_) {
      subjectSummaries.clear();
    }
  }

  /// 已完成列表「加载更多」。
  ///
  /// pending 全量、done 分页 —— 这个不对称是刻意的：没做的要做完才知道，
  /// 做过的只是往回翻，翻到哪儿算哪儿。
  Future<void> loadMoreDone({String? studentId}) async {
    if (loadingMore.value || !doneHasMore.value) return;
    loadingMore.value = true;
    error.value = null;
    try {
      final page = await _repo.getQuizzes(
        studentId: studentId,
        status: CheckinQuizStatus.done,
        limit: donePageSize,
        offset: doneRuns.length,
      );
      // 去重：这期间可能有别的路径（交卷）已经把它插进来了，
      // 重复的 key 会让列表在滚动时跳一下，且谁也说不清为什么。
      final seen = {for (final run in doneRuns) run.quiz.value.id};
      doneRuns.addAll([
        for (final quiz in page.items)
          if (!seen.contains(quiz.id)) CheckinRun(quiz),
      ]);
      doneTotal.value = page.total;
      doneHasMore.value = page.hasMore;
    } on DataApiException catch (e) {
      error.value = e.userMessage;
    } finally {
      loadingMore.value = false;
    }
  }

  /// 拉出题候选（家长挑知识点用）。
  ///
  /// 失败只写 [error]，**不抛** —— 配置页在主线程等它，抛出去会让
  /// 「候选取不到」变成一次白屏；而且候选取不到时家长仍然可以手输知识点。
  Future<void> loadSeeds({String? studentId}) async {
    seedsLoading.value = true;
    try {
      seeds.value = await _repo.loadSeeds(studentId: studentId);
    } on DataApiException catch (e) {
      error.value = e.userMessage;
    } catch (e) {
      error.value = '读错题知识点失败：$e';
    } finally {
      seedsLoading.value = false;
    }
  }

  /// 发起一份**新的**打卡试卷：**服务端**出题、落库，把题返回。
  ///
  /// [knowledgePoints] 是家长给出的范围（非空即手动，空则服务端自动聚合）。
  /// [difficulty] 空串表示不指定，别塞「基础」—— 那会让统计里多出
  /// 一批没人指定过的「基础」题。
  ///
  /// 答案随题下来是刻意的：交卷那一刻要在本机判对错，不等网络。
  ///
  /// 返回 true 表示题目已经存好、可以直接开始答。
  ///
  /// ## 出题的语义：每次都是一份**新卷**（不覆盖任何旧卷）
  ///
  /// 2026-10-27 起取消「一天一科目只许一份」：家长每发起一次就 add 一份
  /// 新的 [CheckinRun]，同一天同一科目也可以并存多份，旧的题与成绩一律
  /// 原样保留。所以这里**没有** `removeWhere` —— 有它的话家长再出一套
  /// 就会把界面上的旧那一套（连同刚看到的成绩）从列表里抹掉，孩子正在
  /// 做的那套还会当场消失。
  ///
  /// 入口卡的 done/total 由 [_syncEntryState] 按新列表重算：多出一份
  /// 「待完成」，总数自然加一，不会出现「重出数学后已完成退回待完成」
  /// 那种状态错乱（旧语义下是必然发生，因为旧卷被删了）。
  Future<bool> start({
    String? studentId,
    String subject = '数学',
    int count = 5,
    List<String> knowledgePoints = const [],
    String difficulty = kCheckinDifficultyNone,
  }) async {
    if (busy.value) return false;
    busy.value = true;
    error.value = null;
    try {
      final saved = await _repo.generate(
        studentId: studentId,
        quizDate: today,
        subject: subject,
        count: count,
        knowledgePoints: knowledgePoints,
        difficulty: difficulty,
      );
      // 只 add、不删旧的 —— 见方法注释。新卷排在未完成末尾：
      // 那份列表按出题时间正序，家长先出的先做。
      pendingRuns.add(CheckinRun(saved));
      _syncEntryState(studentId);
      return true;
    } on DataApiException catch (e) {
      error.value = e.userMessage;
      return false;
    } catch (e) {
      // 走到这里说明是客户端/装配问题（比如仓库实现没接上），
      // 说清是哪一步，别让它伪装成「模型没出题」。
      error.value = '发起打卡失败：$e';
      return false;
    } finally {
      busy.value = false;
    }
  }

  /// 选中某卷某题的某个选项。判断题传 'T' / 'F'。
  void pick(CheckinRun run, int index, String value) {
    run.picked[index] = value;
  }

  /// 交卷：**先在本机判出对错**，再把作答送去存档。
  ///
  /// 顺序很重要。如果先请求再判分，交卷那一下要等一个来回；弱网时就卡在
  /// 「提交中」，而其实判定依据就在手上。所以：
  ///
  ///   ① [CheckinSubmitResult.judge] 同步算出结果，立刻显示；
  ///   ② 再提交服务端复算 + 入库，回来后换成服务端那份（带 ima 状态）；
  ///   ③ 存不上也**不撤销**已显示的结果 —— 判分和落盘是两件事。
  ///
  /// 返回值表示「是否已存到服务端」，不是「是否判出了结果」。
  /// 要判断后者看 [CheckinRun.submitted]。
  Future<bool> submit(CheckinRun run) async {
    if (run.submitted) return true;
    if (run.quiz.value.total == 0) {
      error.value = '今天还没有打卡内容，先发起一组。';
      return false;
    }
    if (!run.allAnswered) {
      // 明确说还差几题：只说「请完成全部题目」时，学生要自己数。
      error.value =
          '还有 ${run.quiz.value.total - run.answeredCount} 题没选，做完再交。';
      return false;
    }
    if (run.busy.value) return false;

    run.busy.value = true;
    error.value = null;
    run.syncError.value = null;
    run.syncConflict.value = false;

    run.result.value = CheckinSubmitResult.judge(
      quizId: run.quiz.value.id,
      questions: run.quiz.value.questions,
      picked: Map.of(run.picked),
      // 交卷就发生在这一刻。提交接口不回 submitted_at，留着这个时刻
      // 才能让「昨天出题、今天做完」的那份进今天的框。
      submittedAt: _clock(),
    );

    try {
      return await _store(run);
    } finally {
      run.busy.value = false;
    }
  }

  /// 重试存档：只把刚才那份作答再送一次，**不重新判分**。
  ///
  /// 不重判是因为重判会把孩子已经看到的分数改一遍 —— 同一份作答在两次
  /// 点击之间变成不同的分数，没有任何解释说得通。
  Future<bool> retrySync(CheckinRun run) async {
    if (run.quiz.value.total == 0 || !run.allAnswered || run.busy.value) {
      return false;
    }
    run.busy.value = true;
    run.syncError.value = null;
    try {
      return await _store(run);
    } finally {
      run.busy.value = false;
    }
  }

  /// 真正落盘的那一步。失败只写 [CheckinRun.syncError]，不碰判定结果。
  Future<bool> _store(CheckinRun run) async {
    try {
      final submitted = await _repo.submit(
        quizId: run.quiz.value.id,
        picked: Map.of(run.picked),
      );
      final local = run.result.value;
      if (local != null &&
          (submitted.score != local.score || submitted.total != local.total)) {
        run.syncConflict.value = true;
      }
      // 以服务端为准：它是存档真值，还带着逐题明细与 ima 同步结果。
      // `POST /data/checkin/submit` 不回交卷时刻，用本机刚记下的那个补上；
      // 否则这一份会因为没有 submittedAt 被按出题日分组，跨天时漏出今天的框。
      final localAt = local?.submittedAt;
      run.result.value = submitted.submittedAt == null && localAt != null
          ? submitted.copyWith(submittedAt: localAt)
          : submitted;
      run.syncError.value = null;
      // 交完这份，它就该从「未完成」挪到「已完成」顶部 —— 已完成按交卷
      // 时间倒序，刚交的排最前。不挪的话孩子交完卷还看见它躺在未完成里。
      _promoteToDone(run);
      // 入口卡的「还有几份没做」在这里重算——不推的话，做完返回计划页
      // 看到的还是旧状态（tab 常驻，卡不会自己重查）。
      _syncEntryState(null);
      // 已完成区的科目份数也要 +1：汇总是一次 group by 的结果，不重拉
      // 就会一直显示交卷前的数字（页面上写着「数学 11 份」，其实已经 12）。
      await _loadSubjectSummaries(targetStudentId());
      // 分在**存档成功之后**发：先发分再存档的话，弱网下孩子会看到
      // 「+5」而库里根本没有这份卷，家长端的账本也对不上任何一次练习。
      // 分与卷用同一个 quizId 做幂等键，所以重试存档不会重复记账。
      await _awardCheckinPoints(run);
      return true;
    } on DataApiException catch (e) {
      // 404 = 手里这份卷已经不在了（家长重新出题后服务端换新 id，
      // 2026-10-27 串题修复）。这时必须丢卷重拉 —— 留着旧卷只会
      // 每次交卷都失败，孩子还对着一份再也交不上去的题。
      if (e.code == 'not_found') {
        // ⚠️ 先重拉再写消息：`load()` 开头会清 `error`，先写会被自己冲掉。
        await load(studentId: targetStudentId());
        error.value = '题目已更新，请重新作答。';
        return false;
      }
      run.syncError.value = e.userMessage;
      return false;
    }
  }

  /// 交完卷记录积分：完成一笔 + 全对再一笔。
  ///
  /// ## 为什么分两笔，而不是「全对给 10 分」
  ///
  /// 家长要能分别定价。合成一笔的话，「完成」这件事的分值就藏进了
  /// 「全对」里 —— 孩子做错一道就一分没有，那会把「做完」的激励直接抹掉。
  ///
  /// ## 全对的判据用**服务端存档那份**
  ///
  /// 不是本机 `judge` 的结果：两边冲突时（[CheckinRun.syncConflict]）
  /// 以服务端为准是这整条链路既有约定，积分不能另立一套。
  ///
  /// ## 任何失败都不影响交卷
  ///
  /// 积分是奖励，不是账目真相。分值表读不到、积分仓库没接上、
  /// 云端 402 配额 —— 都不该让「已经存好的卷」变成一次失败。
  /// 这里**不静默吞到底**：写一条 debug 日志，排查时至少看得见。
  Future<void> _awardCheckinPoints(CheckinRun run) async {
    final result = run.result.value;
    if (result == null) return;
    final quiz = run.quiz.value;
    if (quiz.studentId.isEmpty) return;

    final label = quiz.subject.isEmpty ? '每日练习' : '${quiz.subject}练习';
    try {
      await _pointController.award(
        action: PointAction.checkinCompleted,
        studentId: quiz.studentId,
        reason: '完成$label',
        idempotencyKey: PointController.checkinKey(result.quizId),
        refType: 'checkin',
        refId: result.quizId,
        createdBy: quiz.studentId,
      );
      if (result.total > 0 && result.score == result.total) {
        await _pointController.award(
          action: PointAction.checkinAllCorrect,
          studentId: quiz.studentId,
          reason: '$label全对',
          idempotencyKey: PointController.checkinCorrectKey(result.quizId),
          refType: 'checkin',
          refId: result.quizId,
          createdBy: quiz.studentId,
        );
      }
    } catch (e) {
      debugPrint('每日练习记账失败（不影响交卷）：$e');
    }
  }

  /// 交完卷把它从 [pendingRuns] 挪到 [doneRuns] 顶部。
  ///
  /// 幂等：`retrySync`（存档重试）也会走 [_store]，那时它已经不在
  /// pendingRuns 里了 —— 不能因此把它又插一份，否则列表里会出现两个同 id 的
  /// item（Flutter 会报 duplicate key，且用户看到的是"交了两遍"）。
  void _promoteToDone(CheckinRun run) {
    final wasPending = pendingRuns.remove(run);
    if (!wasPending) return;
    doneRuns.insert(0, run);
    doneTotal.value = doneTotal.value + 1;
  }

  /// 把「还有几份没做 / 一共几份」同步给入口卡（[CheckinEntryState]）。
  ///
  /// 三处都要同步：[load]（别页改了数据回来）、[start]（多出一份，
  /// pending 加一）、[_store]（交卷成功往前走）。
  /// 只在交卷时往前推、从不回退的话，就是「已完成点进去还能答」那个 bug。
  void _syncEntryState(String? studentId) {
    final id = studentId ?? targetStudentId();
    if (id == null) return;
    if (Get.isRegistered<CheckinEntryState>()) {
      Get.find<CheckinEntryState>().applyCounts(
            id,
            pending: pendingRuns.length,
            total: pendingRuns.length + doneTotal.value,
            // 明细一起推：计划页把「刚出的题」直接列出来，只推计数的话
            // 孩子出完题回到计划页还是看不到那一行。
            pendingQuizzes: [for (final run in pendingRuns) run.quiz.value],
          );
    }
  }
}
