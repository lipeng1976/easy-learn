import 'package:get/get.dart';

import '../models/point_model.dart';
import '../repositories/point_repository.dart';
import '../services/database_service.dart';

/// 一次发分的结果。
///
/// 用枚举而不是 `bool`，是因为「没发分」有好几种完全不同的原因：
/// 重复（同一件事报了两遍，正常且无需处理）、家长关了这项、分值为 0。
/// 混成一个 false，日志里就再也分不清「防重生效」和「配置写错了」。
enum PointGrantOutcome {
  granted,

  /// 同一个防重键已经发过了。**这不是错误**，是防重在干活。
  duplicated,

  /// 家长把这项分值关掉了。
  disabled,

  /// 算下来是 0 分。记一条 0 分流水只会把账本弄脏。
  zeroPoints,

  /// 没有学生身份，发不了。
  noStudent,
}

extension PointGrantOutcomeX on PointGrantOutcome {
  bool get isGranted => this == PointGrantOutcome.granted;

  /// 给日志/调试用的说明。
  String get note {
    switch (this) {
      case PointGrantOutcome.granted:
        return '已记分';
      case PointGrantOutcome.duplicated:
        return '重复触发，未重复记分';
      case PointGrantOutcome.disabled:
        return '家长已关闭该项目的积分';
      case PointGrantOutcome.zeroPoints:
        return '分值为 0，未记分';
      case PointGrantOutcome.noStudent:
        return '没有学生身份';
    }
  }
}

/// 积分账本的唯一入口。
///
/// 两条规矩，别的地方都不要绕过：
/// 1. **余额永远由流水求和得来**，没有任何一处缓存一个 `balance` 字段。
/// 2. **每个动作都要带防重键**，同一个键只会有一笔「还活着」的记录。
///    撤销走冲正（标掉原记录 + 补一笔相反数），不删记录。
class PointController extends GetxController {
  /// 数据源。默认走本地库 —— **将来换云端实现时只改这一处的默认值**，
  /// 控制器里的业务规则一行不动。
  PointController({PointRepository? repository})
    : _repository = repository ?? DatabaseService.instance;

  final PointRepository _repository;

  static PointController get to =>
      Get.isRegistered<PointController>()
          ? Get.find<PointController>()
          : Get.put(PointController(), permanent: true);

  /// 当前账本属于哪个孩子。
  final RxString studentId = ''.obs;

  /// 全部流水，最新在前。
  final RxList<PointLedgerEntry> ledger = <PointLedgerEntry>[].obs;

  /// 家长配过的分值。**没配过的动作在这份列表里没有行**，回退默认值。
  ///
  /// 这份列表是给界面看的，永远对应 [studentId] 那个孩子。
  /// 发分判据走 [_ruleCache]，两者分开：家长给 A 设了「运动 8 分」，
  /// 但如果他此刻在看 B 的账本、又给 B 发了笔奖励，用这份列表去判就会
  /// 按 A 的配置算 —— 那种错误只会表现为「分不对」，查起来极难。
  final RxList<PointRule> rules = <PointRule>[].obs;

  /// 按孩子缓存的规则，发分时用。
  final Map<String, List<PointRule>> _ruleCache = {};

  /// 余额与累计，随时可以从 [ledger] 重算。
  final Rx<PointAccount> account = PointAccount.empty.obs;

  final RxBool isLoading = false.obs;

  /// 注入时钟：测试要断言「撤销发生在哪一天」，不能靠真实时间。
  DateTime Function() clock = DateTime.now;

  /// 拉某个孩子的账本。切换孩子时直接再调一次即可。
  Future<void> loadFor(String studentId, {bool force = false}) async {
    if (studentId.isEmpty) return;
    if (!force && this.studentId.value == studentId && ledger.isNotEmpty) {
      return;
    }
    this.studentId.value = studentId;
    isLoading.value = true;
    try {
      final entries = await _repository.queryPointLedger(
        studentId,
      );
      final configured = await _repository.queryPointRules(
        studentId,
      );
      ledger.assignAll(entries);
      rules.assignAll(configured);
      _ruleCache[studentId] = configured;
      account.value = PointAccount.fromLedger(entries);
    } finally {
      isLoading.value = false;
    }
  }

  /// 换账号时清空持有的一切。
  ///
  /// ## 为什么是「清内容」而不是「`Get.delete` 掉这个控制器」
  ///
  /// 它是 `permanent: true` 的，而且**页面里有 `Obx` 直接读
  /// `PointController.to`**（个人信息页那张积分卡）。删掉之后，只要那个页面
  /// 还在树上 —— 退出登录的过场动画期间它确实还在 —— 下一次 rebuild 就会
  /// 把它**重新建出来**：于是「删过了」这件事看起来发生了、实际没有，
  /// 下一个登录者照样看到上一个人的余额。
  ///
  /// 这条是实测出来的：删完立刻 `isRegistered` 仍是 true。
  /// 清内容不依赖任何生命周期时序，比毁对象可靠。
  void resetForAccountSwitch() {
    studentId.value = '';
    ledger.clear();
    rules.clear();
    _ruleCache.clear();
    account.value = PointAccount.empty;
    isLoading.value = false;
  }

  /// 某个孩子生效的规则。**每次发分都以此为准**，不吃界面那份缓存。
  Future<List<PointRule>> _rulesFor(String studentId) async {
    final cached = _ruleCache[studentId];
    if (cached != null) return cached;
    final configured = await _repository.queryPointRules(
      studentId,
    );
    _ruleCache[studentId] = configured;
    return configured;
  }

  static PointRule? _pick(List<PointRule> rules, PointAction action) {
    for (final rule in rules) {
      if (rule.action == action) return rule;
    }
    return null;
  }

  /// 某个孩子当前的余额。
  ///
  /// **直接查库**，不吃界面那份缓存：家长给 A 兑现心愿时，界面很可能
  /// 正开着 B 的账本，用缓存的余额去判「够不够」会判错人。
  Future<int> balanceOf(String studentId) async {
    if (studentId.isEmpty) return 0;
    final entries = await _repository.queryPointLedger(studentId);
    return PointAccount.fromLedger(entries).balance;
  }

  /// 某个动作当前生效的分值（含默认值回退）。读的是界面这份。
  int pointsFor(PointAction action) {
    for (final rule in rules) {
      if (rule.action == action) return rule.points;
    }
    return action.defaultPoints;
  }

  /// 某个动作是否开着。读的是界面这份。
  bool isEnabled(PointAction action) {
    for (final rule in rules) {
      if (rule.action == action) return rule.enabled;
    }
    return true;
  }

  /// 家长改分值 / 开关。
  Future<void> setRule({
    required String studentId,
    required PointAction action,
    int? points,
    bool? enabled,
  }) async {
    final current = _pick(await _rulesFor(studentId), action);
    final next = PointRule(
      studentId: studentId,
      action: action,
      points: points ?? current?.points ?? action.defaultPoints,
      enabled: enabled ?? current?.enabled ?? true,
      updatedAt: clock(),
    );
    await _repository.upsertPointRule(next);

    // 两份缓存一起更新：漏了 `_ruleCache` 的话，刚改完的分值要等重启才生效，
    // 家长会以为设置没保存。
    final cached = _ruleCache[studentId] ?? <PointRule>[];
    final index = cached.indexWhere((rule) => rule.action == action);
    if (index >= 0) {
      cached[index] = next;
    } else {
      cached.add(next);
    }
    _ruleCache[studentId] = cached;

    if (studentId == this.studentId.value) {
      rules.assignAll(cached);
    }
  }

  /// 记一笔分。
  ///
  /// [idempotencyKey] 是必填的：想不出一个稳定的键，往往说明这个动作
  /// 还没有一个明确的「一次」的定义 —— 那就先别急着发分。
  Future<PointGrantOutcome> award({
    required PointAction action,
    required String studentId,
    required String reason,
    required String idempotencyKey,
    String refType = '',
    String refId = '',
    String createdBy = '',
    int? pointsOverride,
  }) async {
    if (studentId.isEmpty) return PointGrantOutcome.noStudent;

    // 判据来自**这个孩子**的配置，不是界面上正在看的那份。
    final rule = _pick(await _rulesFor(studentId), action);
    if (rule != null && !rule.enabled) return PointGrantOutcome.disabled;

    final points = pointsOverride ?? rule?.points ?? action.defaultPoints;
    if (points <= 0) return PointGrantOutcome.zeroPoints;

    return _write(
      PointLedgerEntry(
        id: _newId(),
        studentId: studentId,
        action: action.code,
        points: points,
        reason: reason,
        idempotencyKey: idempotencyKey,
        refType: refType,
        refId: refId,
        createdAt: clock(),
        createdBy: createdBy.isEmpty ? studentId : createdBy,
      ),
    );
  }

  /// 扣分（愿望兑换）。
  ///
  /// 刻意和 [award] 分开：扣分**不看分值表**，它由家长在那一次兑现里定价，
  /// 走同一张表只会让「家长改了复习的分值，孩子的心愿定价也跟着变」。
  Future<PointGrantOutcome> spend({
    required PointAction action,
    required String studentId,
    required int points,
    required String reason,
    required String idempotencyKey,
    String refType = '',
    String refId = '',
    String createdBy = '',
  }) async {
    if (studentId.isEmpty) return PointGrantOutcome.noStudent;
    if (points <= 0) return PointGrantOutcome.zeroPoints;
    return _write(
      PointLedgerEntry(
        id: _newId(),
        studentId: studentId,
        action: action.code,
        points: -points,
        reason: reason,
        idempotencyKey: idempotencyKey,
        refType: refType,
        refId: refId,
        createdAt: clock(),
        createdBy: createdBy.isEmpty ? studentId : createdBy,
      ),
    );
  }

  /// 家长手动奖励。没有防重键 —— 家长点两次「奖励 5 分」就该有 10 分，
  /// 那是他的本意，不像打卡那样有「同一件事」的概念。
  Future<PointGrantOutcome> grantReward({
    required String studentId,
    required int points,
    required String reason,
    required String createdBy,
    String refType = 'manual',
    String refId = '',
  }) async {
    if (studentId.isEmpty) return PointGrantOutcome.noStudent;
    if (points <= 0) return PointGrantOutcome.zeroPoints;
    return _write(
      PointLedgerEntry(
        id: _newId(),
        studentId: studentId,
        action: PointAction.parentReward.code,
        points: points,
        reason: reason,
        // 唯一次数越多越好：每笔都是独立的一次奖励，谁都不该被防重掉。
        idempotencyKey: 'reward:${_newId()}',
        refType: refType,
        refId: refId,
        createdAt: clock(),
        createdBy: createdBy,
      ),
    );
  }

  /// 撤销某个动作的得分。
  ///
  /// 找不到还活着的记录时返回 false —— 那说明本来就没发过分
  /// （例如家长事后才把这项的分值关掉），撤销是空操作，不该凭空补一笔。
  Future<bool> revoke({
    required String studentId,
    required String idempotencyKey,
    String reason = '',
    String createdBy = '',
  }) async {
    if (studentId.isEmpty || idempotencyKey.isEmpty) return false;
    final existing = await _repository.findActivePointEntry(
      studentId: studentId,
      idempotencyKey: idempotencyKey,
    );
    if (existing == null) return false;

    final now = clock();
    await _repository.markPointEntryReversed(existing.id, now);
    await _repository.insertPointLedger(
      PointLedgerEntry(
        id: _newId(),
        studentId: studentId,
        action: existing.action,
        points: -existing.points,
        reason: reason.isEmpty ? '撤销：${existing.reason}' : reason,
        // 冲正记录不带防重键：带上就会和原记录抢同一个唯一索引，
        // 反倒把撤销这一步弄失败。它的身份由 reversalOf 说明。
        reversalOf: existing.id,
        refType: existing.refType,
        refId: existing.refId,
        createdAt: now,
        createdBy: createdBy.isEmpty ? studentId : createdBy,
      ),
    );

    await _reloadIfCurrent(studentId);
    return true;
  }

  /// 扣分之后可能不够了，或撤销之后又够了 —— 这些判断都由 UI 从
  /// [account] 现算，所以这里只要保证数据对。

  Future<PointGrantOutcome> _write(PointLedgerEntry entry) async {
    // 先查一遍是为了给出「重复」这个明确结论；真正的保证是数据库那道
    // 部分唯一索引，下面的 insert 返回值才是最终裁决 ——
    // 查与插之间永远有缝，连点两次就会从缝里钻过去。
    final existing = await _repository.findActivePointEntry(
      studentId: entry.studentId,
      idempotencyKey: entry.idempotencyKey,
    );
    if (existing != null) return PointGrantOutcome.duplicated;

    final inserted = await _repository.insertPointLedger(entry);
    if (!inserted) return PointGrantOutcome.duplicated;

    await _reloadIfCurrent(entry.studentId);
    return PointGrantOutcome.granted;
  }

  Future<void> _reloadIfCurrent(String studentId) async {
    if (this.studentId.value != studentId) return;
    final entries = await _repository.queryPointLedger(studentId);
    ledger.assignAll(entries);
    account.value = PointAccount.fromLedger(entries);
  }

  String _newId() => 'pl_${clock().microsecondsSinceEpoch}_${_seq++}';
  static int _seq = 0;

  /// 换了个孩子看账本（家长端切换孩子）。
  Future<void> switchTo(String studentId) => loadFor(studentId, force: true);

  /// 构造防重键的唯一入口。
  ///
  /// 集中在这里是为了让「键长什么样」可被一眼扫完 —— 定错了键（比如掉了
  /// 日期那一段）会安静地把第二天的分吞掉，而不是报错。
  static String homeworkKey(String homeworkId, String batchId) =>
      'homework:$homeworkId:$batchId';

  /// 全对分单独一个前缀。
  ///
  /// 和 [homeworkKey] 共用前缀会撞上「同一个 key 只能有一条活记录」的唯一索引 ——
  /// 提交分和全对分是**两件都要给分的事**，键必须能区分到动作这一层。
  static String homeworkCorrectKey(String homeworkId, String batchId) =>
      'homework_all_correct:$homeworkId:$batchId';

  static String workoutKey(String planOrProject, String dateKey) =>
      'workout:$planOrProject:$dateKey';

  static String planKey(String planId, String dateKey) =>
      'plan:$planId:$dateKey';

  /// 每日练习完成的那一笔。
  ///
  /// 键用 **quizId**，不用日期：每次出题都是新的 `ck_<uuid>`，同一份卷
  /// 反复「重试存档」也只会记一次分；按日期做键会把家长同一天出的第二组
  /// 题吞掉（那组也是孩子真做了的）。
  static String checkinKey(String quizId) => 'checkin:$quizId';

  /// 同一组题的全对奖励。前缀必须能和 [checkinKey] 区分 ——
  /// 同一个前缀会撞上部分唯一索引，症状是「完成有分、全对没分」且不报错。
  static String checkinCorrectKey(String quizId) => 'checkin_all_correct:$quizId';

  static String reviewPaperKey(String paperId) => 'review_paper:$paperId';

  static String mistakeKey(String mistakeId) => 'mistake:$mistakeId';

  static String wishRedeemKey(String wishId) => 'wish_redeem:$wishId';
}
