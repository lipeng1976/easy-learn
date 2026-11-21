import '../models/review_model.dart';
import 'ai_data_source.dart';
import 'simulated_ai_data_source.dart';

/// 判定两侧的比对结论。
enum JudgementAgreement {
  /// 两侧都给了明确结论，且一致。
  agree,

  /// 两侧都给了明确结论，但不一致。**这才是「模型在赚钱」的证据**。
  disagree,

  /// 至少一侧弃权（[AnswerVerdict.inconclusive]），这次没有可比性。
  abstained,
}

/// 一次「模型判定」与「规则判定」的比对结果。
///
/// ## 为什么不直接算一个布尔量
///
/// 三条口径必须分开数，混在一起会得出完全相反的结论：
/// - 两侧都定了且相同 → 说明这次判定**本可以零成本完成**；
/// - 两侧都定了但不同 → 这才是模型体现出价值的地方；
/// - 规则弃权 → 规则说「我判不了」，是它**诚实**，不是它判错。
///
/// 把弃权并进「不一致」里，会得到一个「规则很差劲」的假象，
/// 进而把一批本来能零成本判定的题继续推给模型 —— 那是花冤枉钱。
class JudgementAB {
  const JudgementAB({required this.modelVerdict, required this.ruleVerdict});

  /// 模型给的结论。
  final AnswerVerdict modelVerdict;

  /// 本地规则在同一份输入上给的结论。
  final AnswerVerdict ruleVerdict;

  /// 两侧是否**都**有明确结论（即这次比对算不算数）。
  bool get comparable =>
      modelVerdict != AnswerVerdict.inconclusive &&
      ruleVerdict != AnswerVerdict.inconclusive;

  JudgementAgreement get agreement {
    if (!comparable) return JudgementAgreement.abstained;
    return ruleVerdict == modelVerdict
        ? JudgementAgreement.agree
        : JudgementAgreement.disagree;
  }
}

/// 影子比对器：跑一侧的规则判定，**只为观察，不参与判定**。
///
/// ## 它回答的问题
///
/// 模型每判一次要花钱、要等一次往返。这个比对回答的是：
/// **同一道题，本地规则会怎么判？** 一致率高说明大量判定本可以走零成本的规则；
/// 不一致的那些，正是模型值这份钱的地方。这个问题在设计文档里被写成
/// 「判定规则与模型的 A/B 对比」。
///
/// ## 为什么只有单向
///
/// 影子**只在模型判定之后**跑规则侧。反方向（规则判完再送模型复核）没有实现，
/// 因为它在代码里根本走不通 —— 规则判定只发生在两种场景：
/// **离线**（压根没有云端可调）与**云端刚降级**（刚失败的东西再调一次）。
/// 加一个开关只会让人以为「打开就有数据」，实际打开后什么也不会发生。
/// 真要看规则侧的样本，应该去看 [JudgementABSummary.abstained] 之外的口径，
/// 而不是花钱去问一个刚刚答不上来的模型。
///
/// ## 它不改变任何判定结果
///
/// 比对结论只落库。用户看到的永远是模型给的那份结论 ——
/// 观测手段一旦能反向改写业务，它出 bug 的代价就从「统计不准」变成
/// 「学生被判错」，而后者是这套系统里最贵的一种错误。
class JudgementShadow {
  const JudgementShadow({this.rule = const SimulatedAiDataSource()});

  /// 规则侧实现。默认就是本地确定性实现 —— 它才是「零成本的那条路」。
  ///
  /// 用接口而不是直接 `SimulatedAiDataSource`，是为了让「哪一侧是规则」
  /// 这件事可替换：将来若上线一条更聪明的规则，或者要在测试里注入一个
  /// 故意唱反调的假规则，都不必改这个类。
  final AiDataSource rule;

  /// 跑一次比对。
  ///
  /// 返回 `null` 表示**这次不该记录**：判定结论不是模型给的（离线运行，
  /// 或云端失败后回落到了本地）。那种情况下比出来的是「规则 vs 规则」，
  /// 一致率会恒等于 100% —— 一个看起来完美、实际毫无信息量的数字。
  Future<JudgementAB?> compare({
    required AnswerJudgement judgement,
    required String studentAnswer,
    required String referenceAnswer,
    String subject = '',
    String knowledgePoint = '',
    String questionContent = '',
  }) async {
    if (!judgement.source.isCloud) return null;

    final ruleResult = await rule.judgeAnswer(
      studentAnswer: studentAnswer,
      referenceAnswer: referenceAnswer,
      subject: subject,
      knowledgePoint: knowledgePoint,
      questionContent: questionContent,
    );

    return JudgementAB(
      modelVerdict: judgement.verdict,
      ruleVerdict: ruleResult.verdict,
    );
  }
}

/// 一条落库的比对记录。
///
/// ## 只存两侧的**原始结论**，不存派生的一致性
///
/// 「什么算一致」是个会变的判断 —— 例如弃权该不该算不一致，就改过一次。
/// 把结论算好了存进去，等于把今天的定义焊死在今天写下的每一行上，
/// 明天想出更好的口径时，昨天的数据就再也解释不了了。
/// 存两侧原始结论，任何口径都能事后重算。
///
/// ## 刻意不存学生答案与参考答案
///
/// 和审计日志同一条理由：这两样是教育数据里最敏感的一类，
/// 而比对只需要两侧的结论。多存一份既不解决任何问题，又多出一份
/// 需要看护的数据 —— 真正要查「学生是不是写错了」时，去 `review_attempt`
/// 看那条有完整上下文的记录，而不是在这里放半份。
class JudgementABRecord {
  const JudgementABRecord({
    required this.id,
    required this.studentId,
    required this.mistakeId,
    required this.channel,
    required this.subject,
    required this.knowledgePoint,
    required this.modelVerdict,
    required this.ruleVerdict,
    required this.createdAt,
  });

  final String id;
  final String studentId;
  final String mistakeId;

  /// 哪条路产生的这次判定（纸质卷 / 举一反三）。
  final AttemptChannel channel;

  final String subject;
  final String knowledgePoint;
  final AnswerVerdict modelVerdict;
  final AnswerVerdict ruleVerdict;
  final DateTime createdAt;

  JudgementAB get comparison =>
      JudgementAB(modelVerdict: modelVerdict, ruleVerdict: ruleVerdict);

  JudgementAgreement get agreement => comparison.agreement;

  Map<String, dynamic> toMap() => {
    'id': id,
    'studentId': studentId,
    'mistakeId': mistakeId,
    'channel': channel.name,
    'subject': subject,
    'knowledgePoint': knowledgePoint,
    'modelVerdict': modelVerdict.name,
    'ruleVerdict': ruleVerdict.name,
    'createdAt': createdAt.toIso8601String(),
  };

  /// 从一行还原。**读不懂的行返回 null，由调用方丢弃。**
  ///
  /// 不做「猜一个默认值」：把读不懂的结论默认成 `inconclusive` 会让它
  /// 悄悄混进「弃权」那一档，把一个数据损坏问题伪装成一条统计口径 ——
  /// 而统计口径是一致率的**分母**，脏在这里就再也查不出来了。
  static JudgementABRecord? fromMap(Map<String, dynamic> row) {
    final modelVerdict = parseVerdict(row['modelVerdict']);
    final ruleVerdict = parseVerdict(row['ruleVerdict']);
    if (modelVerdict == null || ruleVerdict == null) return null;

    return JudgementABRecord(
      id: (row['id'] as String?) ?? '',
      studentId: (row['studentId'] as String?) ?? '',
      mistakeId: (row['mistakeId'] as String?) ?? '',
      channel: AttemptChannel.values.firstWhere(
        (e) => e.name == row['channel'],
        orElse: () => AttemptChannel.paper,
      ),
      subject: (row['subject'] as String?) ?? '',
      knowledgePoint: (row['knowledgePoint'] as String?) ?? '',
      modelVerdict: modelVerdict,
      ruleVerdict: ruleVerdict,
      createdAt: DateTime.tryParse((row['createdAt'] as String?) ?? '') ??
          DateTime.now(),
    );
  }

  /// 解析结论名。未知取值返回 null（见 [fromMap] 的说明）。
  static AnswerVerdict? parseVerdict(Object? raw) {
    return switch (raw) {
      'correct' => AnswerVerdict.correct,
      'wrong' => AnswerVerdict.wrong,
      'inconclusive' => AnswerVerdict.inconclusive,
      _ => null,
    };
  }
}

/// 一批比对记录的汇总口径。
class JudgementABSummary {
  const JudgementABSummary({
    required this.total,
    required this.agree,
    required this.disagree,
    required this.ruleAbstained,
    required this.modelAbstained,
  });

  /// 参与比对的判定次数。
  final int total;

  final int agree;
  final int disagree;

  /// 规则侧弃权的次数。
  final int ruleAbstained;

  /// 模型侧弃权的次数。
  ///
  /// 与 [ruleAbstained] **可能重叠**（同一道题两侧都说判不了），
  /// 所以两者相加不等于 [total] - [compared]。要断言总账请用 [abstained]。
  final int modelAbstained;

  static const JudgementABSummary empty = JudgementABSummary(
    total: 0,
    agree: 0,
    disagree: 0,
    ruleAbstained: 0,
    modelAbstained: 0,
  );

  static JudgementABSummary of(Iterable<JudgementABRecord> records) {
    var total = 0;
    var agree = 0;
    var disagree = 0;
    var ruleAbstained = 0;
    var modelAbstained = 0;

    for (final record in records) {
      total++;
      switch (record.agreement) {
        case JudgementAgreement.agree:
          agree++;
        case JudgementAgreement.disagree:
          disagree++;
        case JudgementAgreement.abstained:
          // 弃权不计入 agree / disagree，但要单独数出来 ——
          // 否则「规则经常弃权」这件事会完全隐形。
          if (record.ruleVerdict == AnswerVerdict.inconclusive) ruleAbstained++;
          if (record.modelVerdict == AnswerVerdict.inconclusive) {
            modelAbstained++;
          }
      }
    }

    return JudgementABSummary(
      total: total,
      agree: agree,
      disagree: disagree,
      ruleAbstained: ruleAbstained,
      modelAbstained: modelAbstained,
    );
  }

  /// 有可比性的样本数（两侧都给了明确结论）。
  int get compared => agree + disagree;

  /// 至少一侧弃权的次数。与 [compared] 相加恒等于 [total]。
  int get abstained => total - compared;

  /// 一致率。**分母是 [compared] 而不是 [total]。**
  ///
  /// 用 [total] 作分母会把「规则诚实地说判不了」算成不一致，
  /// 规则越谨慎、数字越难看 —— 那是在惩罚正确行为。
  ///
  /// 返回 `null` 表示**没有可比样本**，而不是 0，也不是 1。
  /// 没有样本时说「一致率 100%」和说「一致率 0%」一样是编的：
  /// 前者会让人以为规则已经可以替代模型，后者会让人以为模型全错。
  double? get consistencyRate => compared == 0 ? null : agree / compared;

  /// 规则弃权率。分母用 [total]：要回答的是「模型判定的这些题里，
  /// 有多大比例本地规则其实插不上手」。
  double? get ruleAbstainRate => total == 0 ? null : ruleAbstained / total;

  bool get isEmpty => total == 0;
}
