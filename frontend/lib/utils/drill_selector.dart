/// 每日概念训练的**选题规则**。
///
/// 全部是纯函数（不碰数据库、不碰网络、不碰 Flutter）——「今天练哪 6 道」
/// 由三个输入完全决定：学生、日期、她的历史。同样的输入必须给出同样的题组，
/// 否则「同一天重复打开页面题却变了」会让人以为题被偷换过。
///
/// ## 三个输入各管什么
///
///  · [mistakeWeights]（错题本）：她错得多的知识点多出题。键是错题表的
///    `knowledge_point` 原值 —— 键对不上时加权静默失效（加 0 不报错），
///    所以题库的 knowledge 取值与错题表保持同一套词。
///  · [history]（训练流水）：同一个句式（pattern）最近做错了，立刻重复出现；
///    连续做对就降权 —— 「练会了还天天练」和「总错的反而不再出现」
///    都是把训练变成形式。
///  · 日期：决定随机种子，也决定「最近 3 天出过的题降权」。
library;

import 'dart:math';

import '../data/drill_bank.dart';
import '../models/drill_question.dart';

/// 一天的题组。
class DailyDrill {
  const DailyDrill({required this.date, required this.questions});

  /// `YYYY-MM-DD`（本地时区）。
  final String date;
  final List<DrillQuestion> questions;
}

/// 分层保底配额（size=6 时）：基础 3 / 进阶 2 / 综合 1。
///
/// 概念不牢时拔高题只会打击信心 —— 她现在的状况（文字→式子翻译弱）
/// 恰恰是「基础层没打牢」的典型症状，所以基础层必须占一半。
const Map<DrillTier, int> kDrillTierQuota = <DrillTier, int>{
  DrillTier.basic: 3,
  DrillTier.advanced: 2,
  DrillTier.composite: 1,
};

/// 新鲜度窗口：这么多天内出过的题大幅降权（仍可能出现，但概率很低）。
const int kDrillFreshnessDays = 3;

/// 错题本 `knowledge_point` 是模型生成的自由文本，同一概念常有多种写法
/// （如「解一元一次方程」「方程求解」「解方程」三词同义）。选题加权是
/// **精确匹配**（`mistakeWeights[q.knowledge]`），不归一会丢一半弱项权重——
/// 加一个永远为 0 的数，不报错，只是「个性化」悄悄不存在了。
///
/// 这里在「权重来源」一侧把自由文本折成一套规范词（canonical），题库的
/// `knowledge` 也用这套词 —— 两边对得上，加权才不是空转。
/// 只合并**明显同义**的；拿不准的不合并（见 `drill_controller.dart`）。
const Map<String, String> kKnowledgeAlias = <String, String>{
  // 解方程：三种写法同一概念
  '方程求解': '解一元一次方程',
  '解方程': '解一元一次方程',
  // 列方程（含应用；和倍、相遇另有独立题型，不强合并）
  '一元一次方程应用': '列方程解应用题',
  // 有理数运算族：全部折到「有理数混合运算」
  '有理数简便运算': '有理数混合运算',
  '有理数乘除': '有理数混合运算',
  '有理数加减': '有理数混合运算',
  '有理数乘除混合运算': '有理数混合运算',
  '有理数加减混合运算': '有理数混合运算',
  '有理数乘方运算': '有理数混合运算',
  '有理数乘法': '有理数混合运算',
  '有理数除法': '有理数混合运算',
  '有理数大小比较': '有理数混合运算',
  '分数除法': '有理数混合运算',
  // 倒数并入相反数与倒数
  '倒数': '相反数与倒数',
  // 分段计费是列代数式的一种
  '列代数式（分段计费）': '列代数式',
  // 组合图形面积
  '组合图形面积计算': '代数式表示图形面积',
  // 积的乘方逆运算并入幂的运算
  '积的乘方逆运算': '幂的运算',
};

/// 把错题本的自由文本知识点折成规范词；非别名原样返回。
String normalizeKnowledgePoint(String raw) {
  final t = raw.trim();
  return kKnowledgeAlias[t] ?? t;
}

class DrillSelector {
  const DrillSelector._();

  /// 选今天的一组题。
  ///
  /// [size] 默认 6，与 [kDrillTierQuota] 之和一致。
  static DailyDrill pick({
    required String studentId,
    required DateTime date,
    List<DrillQuestion> bank = kDrillBank,
    Map<String, int> mistakeWeights = const <String, int>{},
    List<DrillAnswer> history = const <DrillAnswer>[],
    int size = 6,
  }) {
    final dateKey = _dateKey(date);
    final rng = Random(_seed(studentId, dateKey));
    final weights = <String, double>{
      for (final q in bank) q.id: _weight(
        q,
        mistakeWeights: mistakeWeights,
        history: history,
        date: date,
      ),
    };
    final picked = <DrillQuestion>[];

    // 按配额遍历：Map 字面量保序（基础 → 进阶 → 综合），
    // 展示顺序因此也是「先打基础再拔高」。
    for (final entry in kDrillTierQuota.entries) {
      final quota = _quotaFor(entry.key, size);
      if (quota <= 0) continue;
      picked.addAll(
        _sampleTier(
          bank.where((q) => q.tier == entry.key).toList(),
          quota: quota,
          rng: rng,
          weights: weights,
          exclude: picked.map((q) => q.id).toSet(),
        ),
      );
    }

    // 题库某层不够时，用剩余轮次从全库补足（保证每天都有 size 道）。
    if (picked.length < size) {
      final rest = bank
          .where((q) => !picked.any((p) => p.id == q.id))
          .toList();
      picked.addAll(
        _sampleTier(
          rest,
          quota: size - picked.length,
          rng: rng,
          weights: weights,
          exclude: picked.map((q) => q.id).toSet(),
        ),
      );
    }

    return DailyDrill(date: dateKey, questions: picked);
  }

  /// 单题权重 = 基础 1 × 错题 boost × 历史因子 × 新鲜度。
  static double _weight(
    DrillQuestion q, {
    required Map<String, int> mistakeWeights,
    required List<DrillAnswer> history,
    required DateTime date,
  }) {
    var w = 1.0;

    // 错题 boost：错得越多权重越高，封顶 6 次（防单点异常刷爆）。
    final mistakes = mistakeWeights[q.knowledge] ?? 0;
    if (mistakes > 0) {
      w *= 1 + 0.5 * min(mistakes, 6);
    }

    // 历史因子：按 pattern（句式）算 —— 孩子是在「一种翻译」上反复出错，
    // 不是在「某一道题」上出错。
    final patternHistory = history
        .where((a) => a.pattern == q.pattern)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (patternHistory.isNotEmpty) {
      if (!patternHistory.first.correct) {
        w *= 2.0; // 最近一次做错：明天立刻再现
      } else if (patternHistory.length >= 2 &&
          patternHistory[0].correct &&
          patternHistory[1].correct) {
        w *= 0.25; // 连续两次做对：这个句式降权
      }
    }

    // 新鲜度：最近 kDrillFreshnessDays 天内出过的题降权。
    final cutoff = DateTime(
      date.year,
      date.month,
      date.day,
    ).subtract(const Duration(days: kDrillFreshnessDays));
    final seen = history.any(
      (a) => a.questionId == q.id && !a.createdAt.isBefore(cutoff),
    );
    if (seen) w *= 0.2;

    return w;
  }

  /// 按配额从某一层里加权不重复抽样（Efraimidis–Spirakis：key = rng^(1/w)）。
  ///
  /// 用指数而不是「排序取前 N」：后者在权重差大时会**永远**取同一批题，
  /// 而指数法让低权重题仍留一条缝 —— 「弱项多练」不等于「其他永远不出现」。
  static List<DrillQuestion> _sampleTier(
    List<DrillQuestion> candidates, {
    required int quota,
    required Random rng,
    required Map<String, double> weights,
    required Set<String> exclude,
  }) {
    final pool = candidates.where((q) => !exclude.contains(q.id)).toList();
    if (pool.isEmpty || quota <= 0) return const [];
    final scored = <MapEntry<DrillQuestion, double>>[];
    for (final q in pool) {
      final w = weights[q.id] ?? 1.0;
      final u = rng.nextDouble();
      // w ≤ 0 理论上不会出现（所有因子都 > 0）；兜底用极小值防止除零。
      final key = pow(u, 1 / max(w, 1e-9)).toDouble();
      scored.add(MapEntry(q, key));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(quota).map((e) => e.key).toList();
  }

  /// 配额：size=6 → 基础 3 / 进阶 2 / 综合 1（[kDrillTierQuota] 的等比缩放）。
  ///
  /// 基础层至少占一半：概念翻译没打牢时，进阶层和综合层除了打击信心
  /// 没有别的作用。余量全给基础层，保证总和正好是 size。
  /// 比例只从 [kDrillTierQuota] 一处推 —— 再抄一份数字就是两份会漂的约定。
  static int _quotaFor(DrillTier tier, int size) {
    if (size <= 0) return 0;
    final total = kDrillTierQuota.values.fold(0, (a, b) => a + b);
    final scaled = (kDrillTierQuota[tier]! * size / total).floor();
    if (tier != DrillTier.basic) return scaled;
    final others = kDrillTierQuota.entries
        .where((e) => e.key != DrillTier.basic)
        .fold<int>(0, (a, e) => a + (e.value * size / total).floor());
    return size - others;
  }

  /// 同一天必须是同一组题：种子只由「学生 + 日期」决定。
  ///
  /// 用字符串哈希而不是 `date.millisecondsSinceEpoch`：后者带时分秒，
  /// 「今天」会被切成无数个不同的种子 —— 症状是每次进页面题都变，
  /// 而看起来一切正常。
  static int _seed(String studentId, String dateKey) {
    var h = 2166136261;
    for (final code in '$studentId|$dateKey'.codeUnits) {
      h ^= code;
      h = (h * 16777619) & 0x7FFFFFFF;
    }
    return h;
  }

  static String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

/// 露出给测试的种子函数（与内部实现同源，避免测试复制一份逻辑）。
int drillSeedFor(String studentId, String dateKey) =>
    DrillSelector._seed(studentId, dateKey);
