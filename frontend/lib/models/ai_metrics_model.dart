/// 云端用量与成本的口径。
///
/// ## 为什么整个文件都在强调「不知道就说不知道」
///
/// 成本看板最容易犯的错不是算错，而是**在缺单价、缺 usage 的情况下
/// 报出一个看起来很精确的数字**，然后被拿去当经营依据。
/// 所以这里刻意做了三处区分，而不是把字段都塞成 int：
///
/// 1. [cost] 是 `double?` —— 没配单价就是 `null`，**不是 0**。
///    0 会被读成「不花钱」，null 才会被读成「不知道」。
/// 2. [AiMetrics.costIsLowerBound] 单独给一个布尔量。
///    只把「这是下限」写进文案的话，界面很容易把这个数字当成准确值。
/// 3. [AiMetrics.scope] / [AiMetrics.scopeNote] 原样带出来。
///    网关报的是**单实例**口径，多实例部署下它不是全局数字 ——
///    这句话必须跟着数据走，让人在界面上就能看到。
class AiMetrics {
  const AiMetrics({
    required this.scope,
    required this.scopeNote,
    required this.since,
    required this.totals,
    required this.byCapability,
    required this.byCode,
    required this.latency,
    required this.pricing,
    required this.costIsLowerBound,
    required this.costNote,
  });

  /// 口径范围。当前恒为 `instance`（网关单个实例自启动以来）。
  final String scope;

  /// 口径说明（中文，给界面直接展示）。
  final String scopeNote;

  final DateTime? since;

  final AiMetricsTotals totals;
  final List<AiCapabilityUsage> byCapability;

  /// 错误码 → 次数。看板上「哪类失败最多」靠它。
  final Map<String, int> byCode;

  final AiLatency latency;
  final AiPricingState pricing;

  /// 成本是否为**下限**（有模型调用没返回 usage）。
  final bool costIsLowerBound;

  /// 成本口径的一句话说明。没有需要说明的时候是 null。
  final String? costNote;

  /// 是否拿到了完整的成本数字。
  bool get hasCost => totals.cost != null;

  /// 单实例口径的提示语要不要显示 —— 永远是「要」。
  /// 留这个 getter 是为了让界面那边别写 `if (scope == 'instance')`：
  /// 以后真出现全局口径，判断只需要改这一处。
  bool get isInstanceScoped => scope == 'instance';

  factory AiMetrics.fromJson(Map<String, dynamic> json) {
    final totals = json['totals'];
    return AiMetrics(
      scope: (json['scope'] as String?) ?? 'instance',
      scopeNote: (json['scopeNote'] as String?) ?? '',
      since: DateTime.tryParse((json['since'] as String?) ?? ''),
      totals: AiMetricsTotals.fromJson(
        totals is Map ? totals.cast<String, dynamic>() : const {},
      ),
      byCapability: (json['byCapability'] is List)
          ? (json['byCapability'] as List)
                .whereType<Map>()
                .map((item) => AiCapabilityUsage.fromJson(item.cast<String, dynamic>()))
                .toList()
          : const [],
      byCode: (json['byCode'] is Map)
          ? (json['byCode'] as Map).map(
              (key, value) => MapEntry(
                key.toString(),
                value is num ? value.toInt() : 0,
              ),
            )
          : const {},
      latency: AiLatency.fromJson(
        json['latencyMs'] is Map
            ? (json['latencyMs'] as Map).cast<String, dynamic>()
            : const {},
      ),
      pricing: AiPricingState.fromJson(
        json['pricing'] is Map
            ? (json['pricing'] as Map).cast<String, dynamic>()
            : const {},
      ),
      costIsLowerBound: json['costIsLowerBound'] == true,
      costNote: json['costNote'] as String?,
    );
  }
}

/// 网关自启动以来的总量。
class AiMetricsTotals {
  const AiMetricsTotals({
    required this.calls,
    required this.modelCalls,
    required this.cached,
    required this.ruleCalls,
    required this.failed,
    required this.units,
    required this.tokensIn,
    required this.tokensOut,
    required this.usageMissing,
    required this.images,
    required this.cost,
  });

  final int calls;

  /// 真正调了模型的次数（不含缓存命中与规则短路）。
  final int modelCalls;

  final int cached;

  /// 规则直接给出结论、没调模型的次数。
  final int ruleCalls;

  final int failed;

  /// 实际扣掉的配额单位。
  final int units;

  final int tokensIn;
  final int tokensOut;

  /// 调了模型但响应里没有 usage 的次数。> 0 时成本是下限。
  final int usageMissing;

  final int images;

  /// 成本。**未配置单价时是 null，不是 0。**
  final double? cost;

  /// 缓存 + 规则这个「没花钱但也是业务量」的合计。
  /// 「省了多少」由它回答，所以它必须是一个能单独显示的数。
  int get freeCalls => cached + ruleCalls;

  factory AiMetricsTotals.fromJson(Map<String, dynamic> json) {
    return AiMetricsTotals(
      calls: _int(json['calls']),
      modelCalls: _int(json['modelCalls']),
      cached: _int(json['cached']),
      ruleCalls: _int(json['ruleCalls']),
      failed: _int(json['failed']),
      units: _int(json['units']),
      tokensIn: _int(json['tokensIn']),
      tokensOut: _int(json['tokensOut']),
      usageMissing: _int(json['usageMissing']),
      images: _int(json['images']),
      // 这里**不做 `?? 0`**：把「没配单价」压成 0 正是本文件要防的事。
      cost: _double(json['cost']),
    );
  }
}

/// 一级能力的用量。
class AiCapabilityUsage {
  const AiCapabilityUsage({
    required this.capability,
    required this.calls,
    required this.modelCalls,
    required this.tokensIn,
    required this.tokensOut,
    required this.cost,
  });

  /// `vision` / `reasoning` / `light`。
  final String capability;

  final int calls;
  final int modelCalls;
  final int tokensIn;
  final int tokensOut;
  final double? cost;

  /// 给界面看的中文名。三级对应完全不同的单价，混着看数字没有意义。
  String get label => switch (capability) {
    'vision' => '拍照批改（视觉）',
    'reasoning' => '判定与讲解（强推理）',
    'light' => '文本解析（轻量）',
    _ => capability,
  };

  factory AiCapabilityUsage.fromJson(Map<String, dynamic> json) {
    return AiCapabilityUsage(
      capability: (json['capability'] as String?) ?? '',
      calls: _int(json['calls']),
      modelCalls: _int(json['modelCalls']),
      tokensIn: _int(json['tokensIn']),
      tokensOut: _int(json['tokensOut']),
      cost: _double(json['cost']),
    );
  }
}

/// 延迟分位。样本为空时三个分位都是 null —— 「没有样本」和「延迟为 0」不同。
class AiLatency {
  const AiLatency({
    required this.samples,
    required this.p50,
    required this.p95,
    required this.max,
  });

  final int samples;
  final int? p50;
  final int? p95;
  final int? max;

  bool get isEmpty => samples == 0;

  factory AiLatency.fromJson(Map<String, dynamic> json) {
    return AiLatency(
      samples: _int(json['samples']),
      p50: _intOrNull(json['p50']),
      p95: _intOrNull(json['p95']),
      max: _intOrNull(json['max']),
    );
  }
}

/// 单价配置状态。
///
/// [state] 三态的意义：`none` 时**故意不给成本数字**，因为价格随官方调价
/// 与模型换代变化，写死一份估算值报出来就会被当成账。
class AiPricingState {
  const AiPricingState({
    required this.state,
    required this.currency,
    required this.configuredCapabilities,
  });

  /// `none` / `partial` / `full`。partial 时网关把总额置空（报一个
  /// 「少了一部分」的总额比报空更危险，它看起来是完整的）。
  final String state;
  final String currency;

  /// 已经配了单价的能力档位。让「为什么没有成本数字」可以自查。
  final List<String> configuredCapabilities;

  bool get isNone => state == 'none';
  bool get isPartial => state == 'partial';
  bool get isFull => state == 'full';

  factory AiPricingState.fromJson(Map<String, dynamic> json) {
    final input = json['inputPerKToken'];
    final output = json['outputPerKToken'];
    final names = <String>{};
    if (input is Map) names.addAll(input.keys.map((k) => k.toString()));
    if (output is Map) names.addAll(output.keys.map((k) => k.toString()));
    return AiPricingState(
      state: (json['state'] as String?) ?? 'none',
      currency: (json['currency'] as String?) ?? 'CNY',
      configuredCapabilities: names.toList()..sort(),
    );
  }
}

int _int(Object? raw) => raw is num ? raw.toInt() : 0;

int? _intOrNull(Object? raw) => raw is num ? raw.toInt() : null;

double? _double(Object? raw) => raw is num ? raw.toDouble() : null;
