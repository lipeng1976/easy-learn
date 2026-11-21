import 'package:get/get.dart';

import '../data/drill_bank.dart';
import 'auth_controller.dart';
import '../models/drill_question.dart';
import '../models/op_result.dart';
import '../repositories/drill_repository.dart';
import '../services/database_service.dart';
import '../utils/drill_selector.dart';

/// 每日概念训练的控制器。
///
/// ## 「每天一组」的三个状态，以及它们为什么不能合并
///
///  · **未开始** —— 今天还没有记录：按「学生 + 日期 + 历史」选一组新题；
///  · **进行中** —— 同一天重复进页面：必须是**同一组题**（种子只由
///    学生和日期决定），否则「上午做的题下午不见了」；
///  · **已完成** —— 今天已提交：直接还原那天的一组题和作答，让她能回看解析。
///
/// 三者长得都像「一组题」，但来源不同（新选 / 重选 / 历史还原），
/// 合并成一条路的症状是静默的：题变了、记录串了，而界面一切正常。
class DrillController extends GetxController {
  DrillController({
    DrillRepository? repository,
    Future<Map<String, int>> Function()? mistakeWeightsLoader,
    DateTime Function()? now,
  })  : _repository = repository ?? DatabaseService.instance,
        _mistakeWeightsLoader =
            mistakeWeightsLoader ?? _loadMistakeWeightsFromDatabase,
        _now = now ?? DateTime.now;

  final DrillRepository _repository;
  final Future<Map<String, int>> Function() _mistakeWeightsLoader;

  /// 取「现在」。测试注入口，避免用例依赖真实时钟（跨午夜就会随机红）。
  final DateTime Function() _now;

  /// 今天的一组题。null = 还没加载（或加载失败）。
  final Rxn<DailyDrill> today = Rxn<DailyDrill>();

  /// 已提交时的逐题结果（含解析所需的一切）。
  final RxList<DrillAnswer> results = <DrillAnswer>[].obs;

  final RxMap<String, int> chosen = <String, int>{}.obs;
  final RxBool isLoading = false.obs;
  final RxBool submitted = false.obs;
  final RxnString failure = RxnString();

  /// 连续训练天数（含今天，若今天已完成）。
  final RxInt streak = 0.obs;

  String? get _studentId =>
      Get.isRegistered<AuthController>()
          ? Get.find<AuthController>().currentUser.value?.id
          : null;

  /// 今天是否已经练完。
  bool get isDoneToday => submitted.value && today.value != null;

  /// 已作答题数（进度条用）。
  int get answeredCount => chosen.length;

  /// 提交后答对的题数。
  int get correctCount => results.where((r) => r.correct).length;

  DrillQuestion? questionById(String id) {
    for (final q in today.value?.questions ?? const <DrillQuestion>[]) {
      if (q.id == id) return q;
    }
    return null;
  }

  DrillAnswer? resultOf(String questionId) {
    for (final r in results) {
      if (r.questionId == questionId) return r;
    }
    return null;
  }

  /// 加载（或还原）今天的一组题。
  Future<void> loadToday() async {
    final studentId = _studentId;
    if (studentId == null || studentId.isEmpty) {
      failure.value = '未登录，无法加载训练';
      return;
    }
    isLoading.value = true;
    failure.value = null;
    try {
      final now = _now();
      final dateKey = _dateKey(now);
      final history = await _repository.queryDrillAnswers(
        studentId: studentId,
      );

      // 今天已经练过：还原那天的一组题 + 作答，不再选新题。
      // 「同一天再打开页面题却变了」比「不能重练」更糟 —— 她会以为
      // 系统把她做过的题丢了。
      final todays = history.where((a) => a.date == dateKey).toList();
      if (todays.isNotEmpty) {
        final questions = <DrillQuestion>[];
        for (final a in todays) {
          for (final q in kDrillBank) {
            if (q.id == a.questionId) {
              questions.add(q);
              break;
            }
          }
        }
        today.value = DailyDrill(date: dateKey, questions: questions);
        results
          ..assignAll(todays)
          ..sort((a, b) => a.questionId.compareTo(b.questionId));
        for (final a in todays) {
          chosen[a.questionId] = a.chosenIndex;
        }
        submitted.value = true;
        _refreshStreak(history, dateKey);
        return;
      }

      final weights = await _mistakeWeightsLoader();
      // 已在答题中（同一天、未提交、已选了部分）：**不要重选** ——
      // 种子虽然相同（选出来还是同一组），但 chosen 会被清空，
      // 「答到第三题切了个 tab 回来，前两题白选了」。
      // 切换 tab / 回前台都会走到这里，没有这条守卫就是静默丢进度。
      final current = today.value;
      if (current != null &&
          current.date == dateKey &&
          !submitted.value &&
          chosen.isNotEmpty) {
        _refreshStreak(history, dateKey);
        return;
      }
      final drill = DrillSelector.pick(
        studentId: studentId,
        date: now,
        mistakeWeights: weights,
        history: history,
      );
      today.value = drill;
      chosen.clear();
      results.clear();
      submitted.value = false;
      _refreshStreak(history, dateKey);
    } catch (e) {
      failure.value = '训练加载失败：$e';
    } finally {
      isLoading.value = false;
    }
  }

  /// 选一个选项。提交后锁定（回看时不能再改）。
  void select(String questionId, int optionIndex) {
    if (submitted.value) return;
    chosen[questionId] = optionIndex;
  }

  /// 提交本组作答。
  ///
  /// 整组一个事务落库（见 `DrillRepository.insertDrillAnswers`）：
  /// 半组历史会让「最近一次做错」的判断落到残记录上。
  Future<OpResult> submit() async {
    final studentId = _studentId;
    if (studentId == null || studentId.isEmpty) {
      return const OpResult.fail('未登录，无法记录训练');
    }
    final drill = today.value;
    if (drill == null) return const OpResult.fail('训练还没有加载');
    if (submitted.value) return const OpResult.fail('本组题已经提交过了');

    final unanswered = drill.questions
        .where((q) => !chosen.containsKey(q.id))
        .toList();
    if (unanswered.isNotEmpty) {
      return OpResult.fail('还有 ${unanswered.length} 题没答，先做完再提交');
    }

    final now = _now();
    final records = <DrillAnswer>[];
    for (final q in drill.questions) {
      final picked = chosen[q.id]!;
      records.add(
        DrillAnswer(
          id: 'drill_${q.id}_${drill.date}_$studentId',
          studentId: studentId,
          questionId: q.id,
          pattern: q.pattern,
          knowledge: q.knowledge,
          tier: q.tier,
          chosenIndex: picked,
          correct: picked == q.answerIndex,
          date: drill.date,
          createdAt: now,
        ),
      );
    }

    try {
      await _repository.insertDrillAnswers(records);
      results.assignAll(records);
      submitted.value = true;
      _refreshStreak([...records], drill.date);
      return OpResult.success('答对 $correctCount/${records.length}');
    } catch (e) {
      return OpResult.fail('记录失败：$e');
    }
  }

  /// 重新加载（下拉刷新 / 失败重试）。
  Future<void> retry() => loadToday();

  void _refreshStreak(List<DrillAnswer> history, String dateKey) {
    final dates = history.map((a) => a.date).toSet();
    if (!dates.contains(dateKey)) {
      streak.value = 0;
      return;
    }
    var count = 0;
    var cursor = DateTime.tryParse(dateKey) ?? _now();
    while (true) {
      final key = _dateKey(cursor);
      if (!dates.contains(key)) break;
      count++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    streak.value = count;
  }

  static String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  /// 默认的错题权重来源：错题本按知识点聚合的**数学**错题数。
  ///
  /// 走 `DatabaseService`（本机模式下是本地库、本机版/云版是服务端）——
  /// 和复习页同一份错题池，不存在「两份错题库」对不上的问题。
  /// 只聚合数学：英语的知识点对「文字→数学表达式」训练没有意义，
  /// 但会稀释加权（每个词都乘一遍系数，数学弱项的权重就被摊薄了）。
  static Future<Map<String, int>> _loadMistakeWeightsFromDatabase() async {
    final mistakes = await DatabaseService.instance.queryReviewMistakes();
    final weights = <String, int>{};
    for (final m in mistakes) {
      if (m.subject != '数学') continue;
      // 折成规范词：错题本是模型自由文本，同一概念多写法（如解方程三词同义），
      // 不归一会让「按弱项加权」加到一个永远为 0 的数上，静默失效。
      final point = normalizeKnowledgePoint(m.knowledgePoint);
      if (point.isEmpty) continue;
      weights[point] = (weights[point] ?? 0) + 1;
    }
    return weights;
  }
}
