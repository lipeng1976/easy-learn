import 'package:get/get.dart';

import '../models/checkin_models.dart';
import '../models/subject_scope.dart';
import '../repositories/checkin_repository.dart';
import '../services/data_api_client.dart';
import '../services/database_service.dart';
import '../services/subject_api.dart';
import '../services/word_api.dart';
import 'parent_controller.dart';

/// 「今天练什么」看板：**上半负责配置，下半负责出题**。
///
/// ## 为什么要一个 controller，而不是让两张卡各自读
///
/// 配置区改了范围、出题区立刻要用新范围出题；出题后「待完成」也要马上变。
/// 两块各读各的必然出现「配好了但出题还用旧值」—— 那不是缓存问题，是
/// 两个真相。这里只有一份 [`scopes`]，两块都读它。
///
/// ## 十科都能出题，题型只有两种
///
/// 早先只有数学接了出题，其余科目色块显示「出题待开放」。11-12 定了口径：
/// 语文/历史/物理这些**只出选择题和判断题**，于是十科一起开 —— 出题模板
/// 本来就没有科目分支，卡住的只是「题型要定下来」这件事。
///
/// 判分仍然在客户端本地做（`CheckinSubmitResult.judge`），所以填空、解答
/// 不能放进来：写法上的等价形式（`0.5` / `1/2`）会被判错。要开那两类，
/// 先把归一化判分做出来，只改色块可点性是不够的。
///
/// ## 出题失败要说人话
///
/// 服务端把三种失败分开了（`no_seed` / `model_unavailable` / `model_timeout`），
/// 这里照原样透出 `userMessage`，不统一成「出题失败」—— 家长能据此决定
/// 「先去录错题」还是「过会儿再试」。
class SubjectBoardController extends GetxController {
  SubjectBoardController({
    SubjectScopeRepository? subjectRepo,
    CheckinRepository? checkinRepo,
    WordRepository? wordRepo,
    String? studentId,
    DateTime Function()? now,
  })  : _subjectRepo = subjectRepo ?? DatabaseService.subject,
        _checkinRepo = checkinRepo ?? DatabaseService.checkin,
        _word = wordRepo ?? DatabaseService.word,
        _injectedStudentId = studentId,
        _now = now ?? DateTime.now;

  final SubjectScopeRepository _subjectRepo;
  final CheckinRepository _checkinRepo;
  final WordRepository _word;
  final String? _injectedStudentId;
  final DateTime Function() _now;

  /// 服务端已配好的科目（没配的科目不在这里，读的时候用 [scopeOf] 兜默认值）。
  final RxMap<String, SubjectScope> scopes = <String, SubjectScope>{}.obs;

  /// 各科「还没交」的份数（跨天累计，口径同 `CheckinEntryState`）。
  final RxMap<String, int> pendingBySubject = <String, int>{}.obs;

  /// 英语那一行的摘要来自**词表配置**（`word_scope`），不是 `subject_scope`。
  /// 两套真值各管各的：单词打卡的词表/单元/题量在 `/word-scope` 配。
  final RxString wordSummary = ''.obs;

  /// 英语色块上的「今天做了多少」。空串 = 今天还没做 / 读不到。
  ///
  /// 它替代了被合并掉的 `WordDailyCard` 的一项信息：家长每天最想看的
  /// 就是「今天做了几题、对了几个」，不能因为重排版面就把它弄丢。
  final RxString wordToday = ''.obs;

  final RxBool loading = false.obs;

  /// 正在出题的科目（色块显示「出题中…」并禁用点击）。
  final RxSet<String> generating = <String>{}.obs;

  /// 一条灰字提示（成功「出了一组 5 题」/ 失败原因）。页面级红条不用。
  final RxnString hint = RxnString();

  int _generation = 0;

  String get _studentId =>
      _injectedStudentId ??
      (Get.isRegistered<ParentController>()
          ? Get.find<ParentController>().selectedStudentId.value
          : '');

  /// 某科的范围；没配过时返回带默认值的「未配置」对象，调用方不必判空。
  ///
  /// ⚠️ 英语有**两套真值**：`subject_scope` 里可能没有英语这一行（它的范围
  /// 存在 `word_scope`）。只看 `scopes` 会让「学科范围」卡片里永远没有英语，
  /// 而英语色块在配好词表后点击又只会进「看记录」-> 家长的配置入口整个消失。
  /// 11-12 的实例：虫子问「英语的词典配置去哪了」，就是这么丢的。
  /// 所以词表一有书，就合成一行「已配置」，让配置区有落点。
  SubjectScope scopeOf(String subject) {
    final hit = scopes[subject];
    if (hit != null) return hit;
    if (subject == '英语' && wordSummary.value.isNotEmpty) {
      // 具体摘要由页面用 `wordSummary` 覆盖（那是词表页的话术，不是
      // 「每天 5 题 · 基础 · 0 个知识点」这套默认值）。
      return SubjectScope(
        studentId: _studentId,
        subject: subject,
        configured: true,
      );
    }
    return SubjectScope(studentId: _studentId, subject: subject);
  }

  /// 这科能不能在这块看板上**调 AI 出教材题**（十科全开）。
  ///
  /// 11-13 前英语返回 `false`：那时英语只有词表，题由学生端本地生成。
  /// 现在英语是**两本资料**：词表题仍本地自动出（色块「看记录」），
  /// 教材题（语法 / 时态 / 句型）由家长点「出一组教材题」调服务端出。
  /// 两套题的卷子都记在 `checkin_quiz`，互不覆盖，也不是两份真值 ——
  /// 它们本来就是两种练习。
  bool canGenerate(String subject) => subject.isNotEmpty;

  bool isGenerating(String subject) => generating.contains(subject);

  Future<void> load() async {
    final generation = ++_generation;
    final studentId = _studentId;
    if (studentId.isEmpty) return; // 切孩子晚到：页面靠 ever 再拉一次
    loading.value = true;
    hint.value = null;
    try {
      List<SubjectScope> list = const <SubjectScope>[];
      try {
        list = await _subjectRepo.listScopes(studentId);
      } catch (_) {
        // 026 未迁移 / 断网：按「每科未配置」渲染，不弹红条。
      }
      if (generation != _generation) return;
      scopes
        ..clear()
        ..addEntries(list.map((one) => MapEntry(one.subject, one)));

      await _loadPending(studentId, generation);
      await _loadWordSummary(studentId, generation);
    } finally {
      if (generation == _generation) loading.value = false;
    }
  }

  Future<void> _loadPending(String studentId, int generation) async {
    try {
      final page = await _checkinRepo.getQuizzes(
        studentId: studentId,
        status: CheckinQuizStatus.pending,
        limit: 0,
      );
      if (generation != _generation) return;
      final counts = <String, int>{};
      for (final quiz in page.items) {
        final subject = quiz.subject.isEmpty ? '其他' : quiz.subject;
        counts[subject] = (counts[subject] ?? 0) + 1;
      }
      pendingBySubject
        ..clear()
        ..addAll(counts);
    } catch (_) {
      // 读不到就当作「没有待完成」—— 不因为一个数字把整块变红。
      if (generation == _generation) pendingBySubject.clear();
    }
  }

  Future<void> _loadWordSummary(String studentId, int generation) async {
    try {
      final scope = await _word.getScope(studentId);
      if (generation != _generation) return;
      const modeNames = <String, String>{
        'current': '仅当前单元',
        'learned': '已学区间',
        'selected': '指定单元',
        'all': '整本',
      };
      wordSummary.value = scope.hasBook
          ? '${scope.bookTitle} · ${modeNames[scope.unitMode] ?? scope.unitMode} · '
              '每天 ${scope.dailyCount} 题'
          : '';
    } catch (_) {
      if (generation == _generation) wordSummary.value = '';
    }

    // 今天做了没有：与 `WordDailyCard` 同一个数据源（摘要表按天一行）。
    // 读不到就留空 —— 灰字少一行，比整块变红好。
    try {
      final rows = await _word.listDaily(studentId: studentId, limit: 1);
      if (generation != _generation) return;
      final today = dateKeyOf(_now());
      final hit = rows.where((one) => one.day == today).toList();
      if (hit.isEmpty) {
        wordToday.value = '';
        return;
      }
      final one = hit.first;
      wordToday.value = '今天 ${one.total} 题 · 正确率 ${(one.accuracy * 100).round()}%';
    } catch (_) {
      if (generation == _generation) wordToday.value = '';
    }
  }

  /// 按**已配好的范围**出一组题。返回是否成功（页面据此决定要不要跳转）。
  ///
  /// 范围为空也允许出：服务端会回落到「按错题本同科知识点自动聚合」
  /// （`resolveCheckinSeeds`），这比逼家长先填 6 条更顺手。
  Future<bool> generate(String subject) async {
    final studentId = _studentId;
    if (studentId.isEmpty) {
      hint.value = '还没选孩子，先在上方切换学生';
      return false;
    }
    if (generating.contains(subject)) return false;
    final scope = scopeOf(subject);
    generating.add(subject);
    hint.value = null;
    try {
      final quiz = await _checkinRepo.generate(
        studentId: studentId,
        quizDate: dateKeyOf(_now()),
        subject: subject,
        count: scope.dailyCount,
        knowledgePoints: scope.points,
        difficulty: scope.configured ? scope.difficulty : '',
      );
      hint.value = '已出 ${quiz.questions.length} 道$subject题，孩子打开就能做。';
      await _loadPending(studentId, _generation);
      return true;
    } catch (e) {
      hint.value = _describe(e, subject);
      return false;
    } finally {
      generating.remove(subject);
    }
  }

  /// `yyyy-MM-dd`（本地日）。**不能用 UTC**：晚上 8 点后出的题会记到明天，
  /// 家长第二天看到「昨天没出题」。
  static String dateKeyOf(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)}';
  }

  /// 失败要说人话，而且**按科目说**。
  ///
  /// `no_seed` 的老文案是「这科还没有错题记录」—— 对历史、政治这类
  /// **还没学过所以不可能有错题**的科目，这句话把家长引向一条不存在的路：
  /// 他照着去录错题也录不出来，功能就一直卡着。真正能做的是配教材章节
  /// （`subject_book`，按课推进）或者填两个知识点。
  static String _describe(Object e, String subject) {
    final text = e.toString();
    if (text.contains('no_seed')) {
      // 新服务端的文案已经带了科目和下一步，原样用；老服务端没有，本地补一条同义的。
      if (e is DataApiException && e.message.contains('出题范围')) return e.message;
      return '$subject还没有出题范围：先给这一科选教材（按章节出），或者填两个知识点。';
    }
    if (text.contains('schema_violation')) return '模型这次没给出合格题目，点一下重试。';
    if (text.contains('model_timeout') || text.contains('timeout')) {
      return '模型这次太慢了，过一会儿再试。';
    }
    if (e is DataApiException && e.message.trim().isNotEmpty) return e.message;
    return text.length > 80 ? '${text.substring(0, 80)}…' : text;
  }
}
