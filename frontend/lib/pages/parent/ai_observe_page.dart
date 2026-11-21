import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/ai_observe_controller.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/parent_controller.dart';
import '../../models/ai_metrics_model.dart';
import '../../services/ai_config.dart';
import '../../services/database_service.dart';
import 'widgets/child_selector.dart';

/// 运行观察：**这个系统在真实运行里是什么样子**。
///
/// ## 三块刻意不合并
///
/// 用量成本（网关单实例）、判定一致率（本机）、降级记录（本机本次启动）——
/// 三个口径完全不同。合成一个「运行健康度」分数是这类页面最容易犯的错：
/// 它看起来客观，实际把三个量纲不同的东西压成了一个既不是成本、
/// 也不是一致率的数，而且没人能说清它变了意味着什么。
///
/// 所以这里每一块都单独成卡，并且**每块都带自己的边界说明**。
class AiObservePage extends StatefulWidget {
  const AiObservePage({super.key, this.controller});

  /// 测试注入用。为 null 时按当前登录身份自建。
  final AiObserveController? controller;

  @override
  State<AiObservePage> createState() => _AiObservePageState();
}

class _AiObservePageState extends State<AiObservePage> {
  late final AiObserveController controller;

  /// 家长控制器。**允许缺席**：这个页面在测试里会被单独构建，
  /// 那时没有家长会话。用 `Get.find` 硬取会把「测试环境」伪装成崩溃，
  /// 而它实际只是「没有孩子可切换」。
  ParentController? parent;

  @override
  void initState() {
    super.initState();
    final injected = widget.controller;
    if (injected != null) {
      // 注入进来的那个由**调用方**（测试）自己 load：它已经 load 过了。
      controller = injected;
    } else {
      // `Get.put` 会走 `onInit`，而 `onInit` 里已经 `load()` 了 ——
      // 所以这里**不再**补一次。补了的后果是每次都读两遍：
      // 走查的诊断里那条 `/data/review/judgement-ab` 一直是 `2x`，
      // 就是这个重复（两次并发的读，日志里看起来像「请求发了两次」）。
      controller = Get.put(
        AiObserveController(
          // 观察页也要带会话 token：它读的是网关的用量与审计，
          // 而 `AI_REQUIRE_AUTH` 打开后那几条端点同样只认 token。
          // 不带的话这一页会显示「拿不到数据」，看起来像网关没在跑。
          identity: AiIdentity.resolve(
            session: DatabaseService.cloud?.api.session,
            localUserId: Get.find<AuthController>().currentUser.value?.id,
          ),
        ),
      );
    }
    parent = Get.isRegistered<ParentController>()
        ? Get.find<ParentController>()
        : null;
    // 默认观察第一个孩子；多孩子时可在顶部切换。
    //
    // 只**重算本机那块**（一致率按孩子分桶），不重问网关：云端看板是
    // 实例口径、与哪个孩子无关，为一个孩子的切换多打一次网关没有意义。
    final bound = parent?.boundStudents ?? const [];
    if (bound.isNotEmpty) {
      // 不 await：initState 是同步的，而它内部已经把异常与超时都兜住了。
      controller.selectStudent(bound.first.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('运行观察'),
        actions: [
          IconButton(
            onPressed: controller.load,
            icon: const Icon(Icons.refresh),
            tooltip: '重新载入',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if ((parent?.boundStudents.length ?? 0) > 1) ...[
            _studentPicker(),
            const SizedBox(height: 12),
          ],
          _cloudCard(),
          const SizedBox(height: 12),
          _consistencyCard(),
          const SizedBox(height: 12),
          _degradationCard(),
        ],
      ),
    );
  }

  Widget _studentPicker() => Obx(
    () => ChildSelectorDropdown(
      students: parent!.boundStudents.toList(),
      selectedId: controller.studentId.value,
      onSelect: controller.selectStudent,
    ),
  );

  // ===== 一、云端用量与成本 =====

  Widget _cloudCard() => Obx(() {
    final state = controller.cloudState.value;
    return _Card(
      title: '云端用量与成本',
      subtitle: '口径：网关单个实例自启动以来',
      child: switch (state) {
        CloudUsageState.offline => const _Note(
          icon: Icons.cloud_off_outlined,
          text: '本机没有云端用量。\n'
              '当前是纯本地运行（未配置 AI_BASE_URL），所有批改与讲解'
              '都由本机确定性实现产出，不产生任何费用。',
        ),
        CloudUsageState.loading => const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Center(child: CircularProgressIndicator()),
        ),
        CloudUsageState.failed => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Note(
              icon: Icons.error_outline,
              color: AppColors.danger,
              text: controller.cloudError.value,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: controller.refreshCloud,
                child: const Text('重试'),
              ),
            ),
          ],
        ),
        CloudUsageState.ready => _cloudBody(controller.cloudMetrics.value!),
      },
    );
  });

  Widget _cloudBody(AiMetrics metrics) {
    final totals = metrics.totals;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 20,
          runSpacing: 12,
          children: [
            _metric('总调用', '${totals.calls}'),
            _metric('模型调用', '${totals.modelCalls}'),
            // 缓存 + 规则 = 「没花模型钱但也是业务量」的部分。
            // 它和模型调用必须分开显示，否则「省了多少」无从回答。
            _metric('缓存命中', '${totals.cached}'),
            _metric('规则直接判定', '${totals.ruleCalls}'),
            _metric('失败', '${totals.failed}'),
            _metric('Token 入/出', '${totals.tokensIn} / ${totals.tokensOut}'),
            _metric(
              'p95 延迟',
              metrics.latency.p95 == null ? '—' : '${metrics.latency.p95} ms',
            ),
          ],
        ),
        const SizedBox(height: 14),
        _costRow(metrics),
        if (totals.failed > 0 && metrics.byCode.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),
          const Text(
            '失败分类',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 6),
          ...metrics.byCode.entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '${_codeLabel(entry.key)}　${entry.value} 次',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          metrics.scopeNote,
          style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
        ),
      ],
    );
  }

  Widget _costRow(AiMetrics metrics) {
    final totals = metrics.totals;
    if (!metrics.hasCost) {
      // 没配单价时**不报数字**。这里刻意不显示 0 ——
      // 「成本 0」和「成本未知」在经营上是两件事。
      return _Note(
        icon: Icons.help_outline,
        text: metrics.costNote ??
            '未配置模型单价，因此只提供用量、不估算成本。',
      );
    }
    // 「≥」号：有模型调用没返回 usage 时，这个数字只是下限。
    // 单独一个符号而不是只写进说明里 —— 说明可能被跳过，符号不会。
    final prefix = metrics.costIsLowerBound ? '≥ ' : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            const Text(
              '成本',
              style: TextStyle(fontSize: 13, color: AppColors.textMuted),
            ),
            const SizedBox(width: 8),
            Text(
              '$prefix${totals.cost!.toStringAsFixed(4)} '
              '${metrics.pricing.currency}',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
              ),
            ),
          ],
        ),
        if (metrics.byCapability.isNotEmpty) ...[
          const SizedBox(height: 8),
          // 分档列出：三级单价差一个量级，只看总额看不出钱花在哪。
          ...metrics.byCapability.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '${item.label}：${item.modelCalls} 次　'
                '${item.cost == null ? '未配单价' : '${item.cost!.toStringAsFixed(4)} ${metrics.pricing.currency}'}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ),
          ),
        ],
        if (metrics.costNote != null) ...[
          const SizedBox(height: 8),
          Text(
            metrics.costNote!,
            style: const TextStyle(fontSize: 11, color: AppColors.warning),
          ),
        ],
      ],
    );
  }

  // ===== 二、判定一致率 =====

  Widget _consistencyCard() => Obx(() {
    final summary = controller.consistency.value;
    return _Card(
      title: '判定一致率（规则 vs 模型）',
      subtitle: '口径：本机记录到的模型判定次数',
      child: controller.localError.value.isNotEmpty
          // 读失败要**说出来**：它和「本来就没有记录」在界面上长得一样（都是空的），
          // 而前者是故障、后者是正常状态。不说出来，用户会以为一致率真的没样本。
          ? _Note(
              icon: Icons.error_outline,
              color: AppColors.danger,
              text: controller.localError.value,
            )
          : summary.isEmpty
          ? const _Note(
              icon: Icons.science_outlined,
              text: '暂无样本。\n'
                  '一致率靠「模型真的判过一次」留下记录，'
                  '纯本地运行时两侧是同一个实现，比出来的 100% 没有信息量，'
                  '所以刻意不记。',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      summary.consistencyRate == null
                          ? '无'
                          : '${(summary.consistencyRate! * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      summary.consistencyRate == null
                          ? '暂无可比样本'
                          : '${summary.agree} / ${summary.compared} 次可比判定一致',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 20,
                  runSpacing: 12,
                  children: [
                    _metric('记录总数', '${summary.total}'),
                    _metric('一致', '${summary.agree}'),
                    _metric('分歧', '${summary.disagree}'),
                    _metric('规则弃权', '${summary.ruleAbstained}'),
                    _metric('模型弃权', '${summary.modelAbstained}'),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  '分母是「两侧都给了明确结论」的次数，弃权不计入 —— '
                  '规则说「判不了」是它诚实，把它算成分歧会得出'
                  '「规则很差劲」的假象，进而把本来能零成本判定的题继续推给模型。\n'
                  '分歧的那部分才是模型值这份钱的地方。',
                  style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                ),
              ],
            ),
    );
  });

  // ===== 三、降级记录 =====

  Widget _degradationCard() => Obx(() {
    final events = controller.degradations;
    return _Card(
      title: '降级记录',
      subtitle: '口径：本机、本次启动以来',
      trailing: events.isEmpty
          ? null
          : TextButton(
              onPressed: controller.clearDegradations,
              child: const Text('清空本机记录'),
            ),
      child: events.isEmpty
          ? const _Note(
              icon: Icons.check_circle_outline,
              color: AppColors.success,
              text: '本次启动以来没有降级。\n'
                  '降级指「本该走云端、结果回落到了本机模板」—— '
                  '那种结果看起来煞有介事，所以必须能被看见。',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final event in events)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              event.operation,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.text,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.warning.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                event.code.isEmpty ? '未分类' : event.code,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: AppColors.warning,
                                ),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              _time(event.at),
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          event.reason,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  });

  Widget _metric(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        style: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: AppColors.text,
        ),
      ),
      Text(
        label,
        style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
      ),
    ],
  );
}

/// 错误码的中文说法。看板上给运维看，代码本身也要留着 ——
/// 只给中文就没法和网关日志、协议文档对上了。
String _codeLabel(String code) => switch (code) {
  'quota_exhausted' => '每日额度用尽（$code）',
  'rate_limited' => '短时频率限制（$code）',
  'model_not_enabled' => '模型未开通（$code）',
  'schema_violation' => '输出不符合契约（$code）',
  'timeout' => '超时（$code）',
  'payload_too_large' => '请求体过大（$code）',
  'quota_degraded' => '配额降级到单实例（$code）',
  _ => code,
};

String _time(DateTime at) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
}

class _Card extends StatelessWidget {
  const _Card({
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                      ),
                    ),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle!,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({
    required this.icon,
    required this.text,
    this.color = AppColors.textMuted,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, height: 1.5, color: color),
          ),
        ),
      ],
    );
  }
}
