/// 积分体系的数据模型。
///
/// 一句话说清整套设计：**余额不单独存，它是账本流水的求和**。
///
/// `point_ledger` 是唯一真相，`point_rule` 只是「每个动作值多少分」的配置表。
/// 之所以不存一个 `balance` 字段，是因为那个字段迟早会和流水对不上 ——
/// 撤销打卡、家长改分值、愿望兑换扣分，任何一处漏改余额，孩子看到的数字
/// 就再也解释不清了。反过来，只要流水是对的，余额随时能重算出来。
library;

/// 可以赚分（或扣分）的动作。
///
/// 这些字符串会落库，**改名等于数据迁移** —— 展示文案改 [label] 就好。
enum PointAction {
  /// 提交了要批改的作业（材料已交，等结果）。
  homeworkGraded,

  /// 提交了不需要批改的作业（朗读、背诵、默写、字帖这类）。
  homeworkNoGrading,

  /// 批改结果全对 / 订正后通过。
  homeworkAllCorrect,

  /// 运动打卡。
  workoutCheckin,

  /// 学习计划执行打卡。
  planCheckin,

  /// 完成一组「每日练习 / 今天练什么」并交卷。
  ///
  /// 与 [planCheckin] 是两件事，别合并：那个是「勾掉家长排的计划」，
  /// 这个是「做完一份 AI 出的题」。孩子可能只做其中一件。
  checkinCompleted,

  /// 每日练习交卷**且全对**。与 [checkinCompleted] 是两笔，不是替代。
  ///
  /// 拆成两笔的理由与作业那边一致：全对是「完成之上的奖励」，
  /// 家长需要能分别定价（完成 5 分、全对再 +5，而不是一个笼统的 10 分）。
  checkinAllCorrect,

  /// 完成一份复习资料（一轮复习）。
  reviewRound,

  /// 一道错题毕业（移出错题库）。
  mistakeGraduated,

  /// 家长手动额外奖励。分值由家长当次填写，**不进设置表**。
  parentReward,

  /// 愿望兑换扣分。由家长定价、家长兑现时触发，**不进设置表**。
  wishRedeem,

  /// 家长手动记录的行为扣分（迟到、旷课、自定义行为）。
  ///
  /// 分值不在这里，而在 [PointBehavior] 表：每种行为各有自己的名字和分值，
  /// 塞进 point_rule 会让「行为名」无处可存，改名还得改数据。
  /// 账本里用 refId 指向具体行为，所以查记录时能按行为筛。
  behaviorDeduction,
}

extension PointActionX on PointAction {
  /// 落库用的稳定标识。
  String get code => name;

  /// 家长端设置表里的名称。
  String get label {
    switch (this) {
      case PointAction.homeworkGraded:
        return '提交作业（需批改）';
      case PointAction.homeworkNoGrading:
        return '提交作业（无需批改）';
      case PointAction.homeworkAllCorrect:
        return '作业全对 / 订正通过';
      case PointAction.workoutCheckin:
        return '运动打卡';
      case PointAction.planCheckin:
        return '学习计划打卡';
      case PointAction.checkinCompleted:
        return '每日练习完成';
      case PointAction.checkinAllCorrect:
        return '每日练习全对';
      case PointAction.reviewRound:
        return '完成一轮复习';
      case PointAction.mistakeGraduated:
        return '错题毕业';
      case PointAction.parentReward:
        return '家长奖励';
      case PointAction.wishRedeem:
        return '愿望兑换';
      case PointAction.behaviorDeduction:
        return '行为扣分';
    }
  }

  /// 给家长解释「这个动作在什么时候给分」。
  ///
  /// 这张表就是设置页的说明文案，必须写清触发时机 ——
  /// 否则家长改完分值不知道钱是怎么花出去的。
  String get hint {
    switch (this) {
      case PointAction.homeworkGraded:
        return '孩子把作业照片交上来就记分，不等批改结果。';
      case PointAction.homeworkNoGrading:
        return '默写、字帖、朗读这类交照片即完成，不判对错。';
      case PointAction.homeworkAllCorrect:
        return '批改结果全对，或订正后通过时记分。';
      case PointAction.workoutCheckin:
        return '每完成一次运动记录，同一项目每天只记一次。';
      case PointAction.planCheckin:
        return '完成学习计划的今日打卡。取消打卡会同步扣回。';
      case PointAction.checkinCompleted:
        return '完成一组每日练习并交卷就记分，不看对错。';
      case PointAction.checkinAllCorrect:
        return '同一组每日练习全对时额外记一笔；有错题不记。';
      case PointAction.reviewRound:
        return '完成一份复习资料并提交批改后记分。';
      case PointAction.mistakeGraduated:
        return '每有一道错题通过检查、移出错题库就记一次。';
      case PointAction.parentReward:
        return '家长临时给的奖励，分值每次单独填写。';
      case PointAction.wishRedeem:
        return '兑现心愿时按家长定价扣除。';
      case PointAction.behaviorDeduction:
        return '家长记录迟到、旷课等行为时扣除，分值按行为单独配置。';
    }
  }

  /// 出厂默认分值。家长没改过时用这个。
  int get defaultPoints {
    switch (this) {
      case PointAction.homeworkGraded:
        return 5;
      case PointAction.homeworkNoGrading:
        return 3;
      case PointAction.homeworkAllCorrect:
        return 5;
      case PointAction.workoutCheckin:
        return 5;
      case PointAction.planCheckin:
        return 5;
      case PointAction.checkinCompleted:
        return 5;
      case PointAction.checkinAllCorrect:
        return 5;
      case PointAction.reviewRound:
        return 10;
      case PointAction.mistakeGraduated:
        return 10;
      case PointAction.parentReward:
        return 0;
      case PointAction.wishRedeem:
        return 0;
      case PointAction.behaviorDeduction:
        return 0;
    }
  }

  /// 是否出现在家长端的分值设置表里。
  ///
  /// 奖励与兑换的分值由家长在具体那一次决定，放进固定表里只会
  /// 让人以为「改了设置就能改定价」，实际不生效 —— 那比不显示更糟。
  bool get configurable =>
      this != PointAction.parentReward &&
      this != PointAction.wishRedeem &&
      this != PointAction.behaviorDeduction;

  /// 这条动作是加分还是扣分。
  ///
  /// 注意**冲正记录不算动作**，它的正负由被冲掉的那条决定。
  bool get isDeduction =>
      this == PointAction.wishRedeem || this == PointAction.behaviorDeduction;
}

/// 家长端设置表里按顺序展示的可配置动作。
final List<PointAction> kConfigurablePointActions = PointAction.values
    .where((action) => action.configurable)
    .toList(growable: false);

/// 账本里的动作标识解析。
///
/// **认不出来的 code 不抛异常** —— 账本是历史数据，将来删掉或改名某个动作时，
/// 老记录还得能显示出来。抛异常会让整个明细页打不开，比显示一个原始
/// code 糟糕得多。
PointAction? pointActionFromCode(String code) {
  for (final action in PointAction.values) {
    if (action.code == code) return action;
  }
  return null;
}

/// 展示用名称：认识的翻译，不认识的照原样显示。
String pointActionLabel(String code) =>
    pointActionFromCode(code)?.label ?? code;

/// 一条「行为扣分」的配置。
///
/// [points] **刻意存正数**：扣分的方向由账本里那笔负数流水表达。
/// 两处各存一个符号，迟早会出现「配置 -2、流水 +2」的怪事。
class PointBehavior {
  const PointBehavior({
    required this.studentId,
    required this.id,
    required this.name,
    required this.points,
    this.enabled = true,
    this.builtin = false,
    this.updatedAt,
  });

  final String studentId;

  /// 稳定标识。内置行为用 `builtin_xxx`，自定义行为由客户端生成。
  /// 账本的 refId 存的就是它 —— 所以**行为 id 不能跟着名字改**。
  final String id;
  final String name;
  final int points;
  final bool enabled;

  /// 内置行为可以改分值、可以关掉，但不能删 —— 历史记录还要靠它显示名字。
  final bool builtin;
  final DateTime? updatedAt;

  Map<String, dynamic> toMap() => {
        'studentId': studentId,
        'id': id,
        'name': name,
        'points': points,
        // SQLite 只吃 0/1；服务端 toBool 也认 0/1，所以两边共用一份 toMap。
        'enabled': enabled ? 1 : 0,
        'builtin': builtin ? 1 : 0,
        'updatedAt': updatedAt?.toIso8601String(),
      };

  factory PointBehavior.fromMap(Map<String, dynamic> map) {
    return PointBehavior(
      studentId: (map['studentId'] ?? '') as String,
      id: (map['id'] ?? '') as String,
      name: (map['name'] ?? '') as String,
      points: (map['points'] as num?)?.toInt() ?? 0,
      // SQLite 存 0/1，服务端 API 回 true/false，两边都要认。
      enabled: (map['enabled'] is bool)
          ? map['enabled'] as bool
          : (map['enabled'] as num?)?.toInt() == 1 || map['enabled'] == null,
      builtin: (map['builtin'] is bool)
          ? map['builtin'] as bool
          : (map['builtin'] as num?)?.toInt() == 1,
      updatedAt: DateTime.tryParse((map['updatedAt'] ?? '') as String),
    );
  }
}

/// 预置行为。首次进入积分页时按稳定 id 落表，之后家长改的是表里那行。
class PointBehaviorSeed {
  const PointBehaviorSeed(this.id, this.name, this.points);

  final String id;
  final String name;
  final int points;
}

const List<PointBehaviorSeed> kBuiltinPointBehaviors = [
  PointBehaviorSeed('builtin_late', '迟到', 2),
  PointBehaviorSeed('builtin_absent', '旷课', 5),
  PointBehaviorSeed('builtin_discipline', '违纪', 3),
];

/// 一个动作在一个孩子名下的分值配置。
class PointRule {
  final String studentId;
  final PointAction action;
  final int points;
  final bool enabled;
  final DateTime updatedAt;

  const PointRule({
    required this.studentId,
    required this.action,
    required this.points,
    this.enabled = true,
    required this.updatedAt,
  });

  PointRule copyWith({int? points, bool? enabled, DateTime? updatedAt}) {
    return PointRule(
      studentId: studentId,
      action: action,
      points: points ?? this.points,
      enabled: enabled ?? this.enabled,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() => {
    'studentId': studentId,
    'action': action.code,
    'points': points,
    'enabled': enabled ? 1 : 0,
    'updatedAt': updatedAt.toIso8601String(),
  };

  static PointRule? fromMap(Map<String, dynamic> row) {
    final action = pointActionFromCode((row['action'] as String?) ?? '');
    if (action == null) return null;
    return PointRule(
      studentId: (row['studentId'] as String?) ?? '',
      action: action,
      points: (row['points'] as num?)?.toInt() ?? action.defaultPoints,
      enabled: ((row['enabled'] as num?)?.toInt() ?? 1) == 1,
      updatedAt:
          DateTime.tryParse((row['updatedAt'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// 账本里的一笔。
///
/// [points] 正数是赚、负数是扣（兑换与冲正）。
/// 撤销**不是删记录**，而是把原记录标上 [reversedAt]，再补一笔相反数的
/// 冲正记录：删掉的话，孩子会看到「我刚才明明做过」的东西凭空消失；
/// 留下两笔，账目才是自洽的，也拦得住「打卡→撤销→打卡」刷分。
class PointLedgerEntry {
  final String id;
  final String studentId;
  final String action;
  final int points;

  /// 展示文案，例如「完成数学作业A」。
  final String reason;

  /// 防重键。空字符串表示这笔不参与幂等（例如冲正记录）。
  final String idempotencyKey;

  /// 冲正记录指向被冲掉的那笔；普通记录为空。
  final String reversalOf;

  /// 业务类型：homework / plan / workout / review_paper / mistake / wish / manual。
  final String refType;
  final String refId;
  final DateTime createdAt;

  /// 操作者 userId。
  final String createdBy;

  /// 非空表示这笔已被撤销（只在原记录上标记）。
  final DateTime? reversedAt;

  const PointLedgerEntry({
    required this.id,
    required this.studentId,
    required this.action,
    required this.points,
    required this.reason,
    this.idempotencyKey = '',
    this.reversalOf = '',
    this.refType = '',
    this.refId = '',
    required this.createdAt,
    this.createdBy = '',
    this.reversedAt,
  });

  bool get isReversal => reversalOf.isNotEmpty;
  bool get isReversed => reversedAt != null;

  PointLedgerEntry copyWith({DateTime? reversedAt}) {
    return PointLedgerEntry(
      id: id,
      studentId: studentId,
      action: action,
      points: points,
      reason: reason,
      idempotencyKey: idempotencyKey,
      reversalOf: reversalOf,
      refType: refType,
      refId: refId,
      createdAt: createdAt,
      createdBy: createdBy,
      reversedAt: reversedAt ?? this.reversedAt,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'studentId': studentId,
    'action': action,
    'points': points,
    'reason': reason,
    'idempotencyKey': idempotencyKey,
    'reversalOf': reversalOf,
    'refType': refType,
    'refId': refId,
    'createdAt': createdAt.toIso8601String(),
    'createdBy': createdBy,
    'reversedAt': reversedAt?.toIso8601String(),
  };

  static PointLedgerEntry fromMap(Map<String, dynamic> row) {
    return PointLedgerEntry(
      id: (row['id'] as String?) ?? '',
      studentId: (row['studentId'] as String?) ?? '',
      action: (row['action'] as String?) ?? '',
      points: (row['points'] as num?)?.toInt() ?? 0,
      reason: (row['reason'] as String?) ?? '',
      idempotencyKey: (row['idempotencyKey'] as String?) ?? '',
      reversalOf: (row['reversalOf'] as String?) ?? '',
      refType: (row['refType'] as String?) ?? '',
      refId: (row['refId'] as String?) ?? '',
      createdAt:
          DateTime.tryParse((row['createdAt'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      createdBy: (row['createdBy'] as String?) ?? '',
      reversedAt: DateTime.tryParse((row['reversedAt'] as String?) ?? ''),
    );
  }
}

/// 余额与累计，全部由流水派生。
class PointAccount {
  final int balance;
  final int totalEarned;
  final int totalSpent;
  final int entryCount;

  const PointAccount({
    this.balance = 0,
    this.totalEarned = 0,
    this.totalSpent = 0,
    this.entryCount = 0,
  });

  static const PointAccount empty = PointAccount();

  /// 全部来自流水，因此永远不会和明细打架。
  ///
  /// 已被撤销的那笔**连同它的冲正记录一起跳过**，而不是让一正一负去抵消：
  /// 抵消虽然余额也对，但「累计获得」会凭空多出那 5 分，家长看到
  /// 「孩子撤销了打卡，累计获得却涨了」只会以为系统算错了。
  /// 跳过之后「打工-撤销-再打工」依然只算 5 分 —— 余额也正是靠这个拦住刷分。
  factory PointAccount.fromLedger(List<PointLedgerEntry> ledger) {
    var balance = 0;
    var earned = 0;
    var spent = 0;
    var count = 0;
    for (final entry in ledger) {
      if (entry.isReversed || entry.isReversal) continue;
      balance += entry.points;
      if (entry.points > 0) earned += entry.points;
      if (entry.points < 0) spent += -entry.points;
      count++;
    }
    return PointAccount(
      balance: balance,
      totalEarned: earned,
      totalSpent: spent,
      entryCount: count,
    );
  }
}
