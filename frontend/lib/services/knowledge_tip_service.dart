import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/knowledge_tip.dart';
import '../models/review_model.dart';
import 'ai_data_source.dart';
import 'database_service.dart';
import 'knowledge_tip_store.dart';
import 'simulated_ai_data_source.dart';

/// 把「错题库」变成计时页下方的一句知识点提示。
///
/// ## 为什么要缓存，而不是每次进计时页都问模型
///
/// 计时页是学生**正在做题**的那一屏。让它在打开时等一次模型（真机上
/// 30 秒窗口），学生看到的会是一张空白卡片，而空白会被理解成「没这功能」。
/// 所以路径固定为：**先给能立刻显示的东西，再在后台换成更好的**。
///
/// ## 三条优先级
///
/// 1. 有同一份错题池生成的模型提示（且没过期）→ 直接用，不发请求；
/// 2. 有旧提示但错题池变了 → 先显示**本地规则**提示（它一定对应当前错题），
///    同时在后台重新生成；
/// 3. 什么都没有 → 先显示本地规则提示，后台请求模型。
///
/// 规则提示长这样：「「一元二次方程」你已经错了 3 次：先用一句话说出它的
/// 定义，说不出来就先翻书。」——它**没有**编造知识内容，只是把错题次数
/// 和一个自检动作说出来。模型提示才是「这个知识点本身的关键」。
/// 两者的出处记在 [KnowledgeTip.source] 里，不会被混成一种东西。
class KnowledgeTipService {
  KnowledgeTipService({
    AiDataSource? ai,
    KnowledgeTipStore? store,
    DateTime Function()? clock,
    this.ttl = const Duration(hours: 72),
    this.failureCooldown = const Duration(minutes: 5),
  }) : _ai = ai ?? const SimulatedAiDataSource(),
       _store = store ?? DatabaseService.instance,
       _clock = clock ?? DateTime.now;

  /// 全应用共用一份：计时页可能在一次会话里被开关多次，
  /// 每次重建一个实例等于每次重新问模型。
  static final KnowledgeTipService instance = KnowledgeTipService();

  final AiDataSource _ai;
  final KnowledgeTipStore _store;
  final DateTime Function() _clock;

  /// 提示的保鲜期。错题池没变时，三天内不再问模型。
  final Duration ttl;

  /// 一次失败之后，这段时间内不再尝试（避免离线时每开一次计时页等 30 秒）。
  final Duration failureCooldown;

  /// 当前科目的提示，按 [KnowledgeTip.sortOrder] 排好。
  final ValueNotifier<List<KnowledgeTip>> tips =
      ValueNotifier<List<KnowledgeTip>>(const []);

  /// 正在后台向模型要新提示。
  final ValueNotifier<bool> refreshing = ValueNotifier<bool>(false);

  /// 本次参与归纳的知识点数。0 表示这个科目还没有错题。
  final ValueNotifier<int> seedCount = ValueNotifier<int>(0);

  int _token = 0;
  DateTime? _lastFailureAt;

  /// 载入某个科目的提示。重复调用（例如返回再进来）是安全的：
  /// 旧请求的返回会被 token 作废，不会把 A 科目的提示写进 B 科目。
  Future<void> load({
    required String studentId,
    required String subject,
    required List<ReviewMistake> pool,
  }) async {
    final token = ++_token;
    final seeds = seedsFrom(pool, subject);
    seedCount.value = seeds.length;
    if (seeds.isEmpty) {
      tips.value = const <KnowledgeTip>[];
      refreshing.value = false;
      return;
    }

    final signature = signatureFor(subject, seeds);
    // 读缓存失败（老库缺表、磁盘只读…）不该让提示区空着：
    // 规则提示完全不依赖存储，照样能显示。
    List<KnowledgeTip> cached;
    try {
      cached = await _store.queryKnowledgeTips(
        studentId: studentId,
        subject: subject,
      );
    } catch (_) {
      cached = const <KnowledgeTip>[];
    }
    if (token != _token) return;

    final cachedMatches =
        cached.isNotEmpty && cached.first.signature == signature;
    final cacheFresh =
        cachedMatches &&
        cached.first.source == KnowledgeTipSource.model &&
        _clock().difference(cached.first.generatedAt) < ttl;
    if (cacheFresh) {
      tips.value = cached;
      return;
    }

    // 立刻能显示的东西：错题池没变就用旧提示（它至少是模型写的），
    // 变了就用规则提示（它对应现在的错题，不会指向已毕业的知识点）。
    tips.value = cachedMatches
        ? cached
        : _materialize(
            SimulatedAiDataSource.buildRuleTips(seeds),
            signature,
            studentId: studentId,
            subject: subject,
          );

    final lastFailure = _lastFailureAt;
    if (lastFailure != null && _clock().difference(lastFailure) < failureCooldown) {
      return;
    }

    refreshing.value = true;
    try {
      final drafts = await _ai.summarizeMistakeTips(
        subject: subject,
        items: seeds,
      );
      if (token != _token) return;
      if (drafts.isEmpty) return;

      final models = _materialize(
        drafts,
        signature,
        studentId: studentId,
        subject: subject,
      );
      tips.value = models;
      // 只有**至少一条来自模型**才写缓存。
      // 把降级产物（规则提示）也按「当前签名」写进去，会让一次短暂断网
      // 变成三天内都不再重试 —— 界面看起来正常，只是永远只有自检问句。
      if (drafts.any((draft) => draft.source == KnowledgeTipSource.model)) {
        await _store.replaceKnowledgeTips(
          studentId: studentId,
          subject: subject,
          tips: models,
        );
      } else {
        _lastFailureAt = _clock();
      }
    } catch (_) {
      // 保留已经显示的提示。计时页不该因为「提示没生成出来」而空一块，
      // 更不该弹错误 —— 那件事和正在做的作业无关。
      _lastFailureAt = _clock();
    } finally {
      if (token == _token) refreshing.value = false;
    }
  }

  /// 按知识点聚合当前科目下的错题。
  ///
  /// 三条规则：
  /// · **只算没毕业的**：已经掌握的题再提示「你总在这里错」，学生会以为系统没记住；
  /// · **错题次数累加**：同一知识点的两道题各错一次，就是错两次；
  /// · **最近一次错因取最新的那条**：给模型当佐料，不是主体。
  @visibleForTesting
  static List<MistakeTipSeed> seedsFrom(
    List<ReviewMistake> pool,
    String subject,
  ) {
    final key = subject.trim();
    if (key.isEmpty) return const <MistakeTipSeed>[];

    final counts = <String, int>{};
    final reasons = <String, String>{};
    final latest = <String, DateTime>{};

    for (final mistake in pool) {
      if (mistake.subject.trim() != key) continue;
      if (mistake.masteredAt != null) continue;
      final point = mistake.knowledgePoint.trim();
      if (point.isEmpty) continue;

      counts[point] = (counts[point] ?? 0) + (mistake.wrongCount < 1 ? 1 : mistake.wrongCount);

      final at = mistake.lastWrongAt ?? mistake.createdAt;
      final seen = latest[point];
      if (seen == null || at.isAfter(seen)) {
        latest[point] = at;
        final reason = mistake.wrongReason.trim();
        if (reason.isNotEmpty) reasons[point] = reason;
      }
    }

    final seeds = [
      for (final entry in counts.entries)
        MistakeTipSeed(
          knowledgePoint: entry.key,
          wrongCount: entry.value,
          wrongReason: reasons[entry.key] ?? '',
        ),
    ]..sort((a, b) {
      final byCount = b.wrongCount.compareTo(a.wrongCount);
      return byCount != 0 ? byCount : a.knowledgePoint.compareTo(b.knowledgePoint);
    });

    return seeds.length > 12 ? seeds.sublist(0, 12) : seeds;
  }

  /// 一次生成对应的输入指纹。错题池一变，缓存就作废。
  @visibleForTesting
  static String signatureFor(String subject, List<MistakeTipSeed> seeds) {
    final parts = [...seeds]
      ..sort((a, b) => a.knowledgePoint.compareTo(b.knowledgePoint));
    return '$subject|${parts.map((s) => '${s.knowledgePoint}:${s.wrongCount}').join(';')}';
  }

  List<KnowledgeTip> _materialize(
    List<MistakeTipDraft> drafts,
    String signature, {
    required String studentId,
    required String subject,
  }) {
    final now = _clock();
    final result = <KnowledgeTip>[];
    for (var index = 0; index < drafts.length; index++) {
      final draft = drafts[index];
      final text = draft.text.trim();
      final point = draft.knowledgePoint.trim();
      if (text.isEmpty || point.isEmpty) continue;
      result.add(
        KnowledgeTip(
          id: 'tip_${now.microsecondsSinceEpoch}_$index',
          studentId: studentId,
          subject: subject,
          knowledgePoint: point,
          text: text,
          source: draft.source,
          sortOrder: index,
          generatedAt: now,
          signature: signature,
        ),
      );
    }
    return result;
  }

  /// 测试用：把状态清回初始值。
  @visibleForTesting
  void reset() {
    _token++;
    _lastFailureAt = null;
    tips.value = const <KnowledgeTip>[];
    refreshing.value = false;
    seedCount.value = 0;
  }

  @visibleForTesting
  void dispose() {
    tips.dispose();
    refreshing.dispose();
    seedCount.dispose();
  }
}
