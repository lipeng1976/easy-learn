import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../models/ai_metrics_model.dart';
import '../services/ai_api_client.dart';
import '../services/ai_config.dart';
import '../services/ai_data_source.dart';
import '../services/ai_degradation_log.dart';
import '../repositories/review_repository.dart';
import '../services/database_service.dart';
import '../services/judgement_ab.dart';

/// 云端看板的三种状态。
enum CloudUsageState {
  /// 没配网关（`AI_BASE_URL` 为空）—— **纯本地运行，本来就没有云端用量**。
  /// 和「取不到」是两件事，界面文案也完全不同。
  offline,

  /// 正在取。
  loading,

  /// 取到了。
  ready,

  /// 配了网关但取不到（网络、超时、口令不对…）。
  failed,
}

/// 「运行观察」页的控制器。
///
/// ## 三块数据，三个完全不同的来源与诚实边界
///
/// | 板块 | 来源 | 它能回答什么 | 它**不能**回答什么 |
/// |---|---|---|---|
/// | 云端用量与成本 | 网关 `/ai/metrics` | 这个实例这段时间花了多少 | 全局花了多少（单实例口径） |
/// | 判定一致率 | 本机 `judgement_ab` | 本机跑过的判定里规则与模型差多少 | 全平台的一致率 |
/// | 降级记录 | 进程内存 | 这次启动以来降级了几次 | 历史上降级过几次 |
///
/// 三块都**必须**在界面上带着自己的边界展示。凑成一个「运行健康度」的
/// 综合数字是这类页面最诱人的错误 —— 它看起来客观，实际把三个不同口径
/// 混成了一个既不是成本、也不是一致率的数。
class AiObserveController extends GetxController {
  AiObserveController({
    AiConfig? config,
    this.httpClient,
    required this.identity,
    ReviewRepository? review,
    this.localReadTimeout = const Duration(seconds: 8),
  }) : config = AiConfig.resolve(config),
       _review = review ?? DatabaseService.instance;

  final AiConfig config;
  final AiIdentity identity;

  /// 本机那块读多久算「读不到」。见 [_loadLocalGuarded]。
  /// 可注入是为了能在测试里把「悬住」这件事压缩到毫秒级。
  final Duration localReadTimeout;

  /// 测试注入用的传输层；生产为 null，由 [AiApiClient] 自建连接池。
  final http.Client? httpClient;

  /// 判定影子比对记录的来源（一致率的分母）。
  final ReviewRepository _review;

  final Rx<CloudUsageState> cloudState = CloudUsageState.loading.obs;
  final Rxn<AiMetrics> cloudMetrics = Rxn<AiMetrics>();

  /// 云端取不到时的原因（给用户看的）。
  final RxString cloudError = ''.obs;

  /// 本机那块读失败时的原因。
  ///
  /// 单独一个字段而不是塞进 [cloudError]：两者的**处置完全不同** ——
  /// 云端那块是网络与鉴权，本机这块是本地记录（数据库、存储）。
  /// 混成一个字段，用户会拿着一条本机错误去查网络。
  ///
  /// 它必须能显示出来：读失败与「本来就没有记录」在界面上长得一样
  /// （都是空的），而前者是故障、后者是正常状态。
  final RxString localError = ''.obs;

  /// 判定一致率（只统计当前孩子的数据）。
  ///
  /// 用 [JudgementABSummary.empty] 而不是 `null` 作为初值：空汇总本身
  /// 就诚实表达了「暂无样本」（一致率是 null、计数是 0），
  /// 再多一层 null 只会让界面到处写 `?.`，还容易某处漏写成 0。
  final Rx<JudgementABSummary> consistency = Rx<JudgementABSummary>(
    JudgementABSummary.empty,
  );

  /// 降级记录（本机、本次启动以来）。
  final RxList<AiDegradation> degradations = <AiDegradation>[].obs;

  /// 当前观察的孩子。
  final RxString studentId = ''.obs;

  AiApiClient? _client;

  /// 是否配了云端网关。没配时整个云端板块显示「本机没有云端用量」，
  /// 而不是一个红色的错误 —— 纯本地运行是**正常状态**，不是故障。
  bool get hasBackend => config.hasBackend;

  @override
  void onInit() {
    super.onInit();
    load();
  }

  @override
  void onClose() {
    _client?.close();
    super.onClose();
  }

  Future<void> load() async {
    // 两块**并行**，不是串成一条 await 链。
    //
    // 这里踩过一次，代价是好几轮排查：串成 `await _loadLocal(); await _loadCloud();`
    // 时，本机那块**挂住**（不是抛错 —— 抛错还有 catch 兜）就意味着云端那块
    // 永远不会开始，而它的界面停在**初值** `CloudUsageState.loading` 上。
    // 现场长这样：一张转圈的卡片 + 网关 0 请求 + 浏览器层面 0 失败 ——
    // 每一条证据都指向「网关没通 / 鉴权没过」，而真正卡住的是本机那次读。
    // 更坏的是本机那两块显示的「暂无样本 / 本次启动以来没有降级」**恰好等于
    // 它们的初值**，于是「跑完了」和「压根没跑」在界面上长得一模一样。
    //
    // 两块的数据源不同（本机库 vs 网关）、界面状态各自独立，
    // 没有任何理由让一块等另一块。并行之后，任何一块坏掉都只影响自己那块。
    await Future.wait([_loadLocalGuarded(), _loadCloud()]);
  }

  /// 本机那两块：**各自兜住自己的异常，而且兜住「不返回」**。
  ///
  /// 超时这一条不是防御性编程：本机读是本页最底层的依赖，它一旦悬住，
  /// 「不返回」与「没有记录」在界面上完全同形，而两者的处置相反 ——
  /// 前者要去修本机库/存储，后者什么都不用做。宁可说「超时」，
  /// 也不要让人以为这个孩子真的没练过。
  ///
  /// 成功时把 [localError] 抹掉：它描述的是**这一次**读，不是这个页面的属性。
  /// 留着上一次的失败会让「重试成功了」看起来像还坏着。
  Future<void> _loadLocalGuarded() async {
    try {
      await _loadLocal().timeout(localReadTimeout);
      localError.value = '';
    } on TimeoutException {
      localError.value = '本机记录读取超时（${localReadTimeout.inSeconds} 秒）。'
          '这块显示的不是「没有记录」，而是「没读到」。';
    } catch (e) {
      // 读不到本机记录只是少一个数字，不该让整页瘫掉；
      // 但也不能装作没发生 —— 卡片上要写出来（见 [localError]）。
      localError.value = '本机记录读取失败：$e';
    }
  }

  /// 切换观察的孩子并重算一致率。
  ///
  /// 为什么要切换：一个家长可能结伴了多个孩子，而一致率是**按孩子**分桶的。
  /// 把孩子混在一起算，会得到一个「谁也不是」的数字；
  /// 而判定能力的问题往往就出在某一个孩子常做的那类题上。
  ///
  /// 必须走 [_loadLocalGuarded] 而不是直接读：这条路径原来是裸的
  /// `await _loadConsistency()`，本机读一失败就**抛进虚空** ——
  /// 界面上没有提示（卡片留着上一个孩子的数字），控制台里是一个
  /// 没人认领的异常。切孩子恰恰是最容易撞上本机读失败的时刻。
  Future<void> selectStudent(String id) async {
    if (studentId.value == id) return;
    studentId.value = id;
    await _loadLocalGuarded();
  }

  Future<void> _loadLocal() async {
    degradations.value = AiDegradationLog.events;
    await _loadConsistency();
  }

  Future<void> _loadConsistency() async {
    final target = studentId.value;
    final records = await _review.queryJudgementAB(
      studentId: target.isEmpty ? null : target,
    );
    consistency.value = JudgementABSummary.of(records);
  }

  Future<void> _loadCloud() async {
    if (!hasBackend) {
      cloudState.value = CloudUsageState.offline;
      cloudMetrics.value = null;
      cloudError.value = '';
      return;
    }

    cloudState.value = CloudUsageState.loading;
    cloudError.value = '';
    try {
      _client ??= AiApiClient(
        config: config,
        identity: identity,
        client: httpClient,
      );
      cloudMetrics.value = await _client!.metrics();
      cloudState.value = CloudUsageState.ready;
    } on AiRequestException catch (e) {
      // 401 单独说清楚：它多半是运维开了 `AI_METRICS_TOKEN`。
      // 那个口令是**刻意不进客户端产物**的（Web 端编译进 JS 就能被抄走），
      // 所以正确的话术是「去看网关的日志/运维侧」，而不是让 App 去塞一个密钥。
      cloudError.value = e.statusCode == 401
          ? '云端看板需要运维口令（AI_METRICS_TOKEN）。'
                '该口令刻意不放进客户端，请从运维侧查看。'
          : '取不到云端用量：${e.userMessage}';
      cloudMetrics.value = null;
      cloudState.value = CloudUsageState.failed;
    } catch (e) {
      // ⚠️ 不拼 `$e`：那会带上类名与内部 code（见 `toString()`），
      // 对看这个页面的人没有意义。原文留在日志里。
      debugPrint('取云端用量失败（非 AiRequestException）：$e');
      cloudError.value = '取不到云端用量，请稍后重试';
      cloudMetrics.value = null;
      cloudState.value = CloudUsageState.failed;
    }
  }

  /// 手动重试云端那一块。只有它需要网络。
  Future<void> refreshCloud() => _loadCloud();

  /// 清掉本机的降级记录（进程内）。
  ///
  /// 只清日志，**不动云端任何数据**：这个按钮是「我知道了，别再显示了」，
  /// 不是「这件事没发生过」。所以它清的是本机视图，不是审计。
  void clearDegradations() {
    AiDegradationLog.clear();
    degradations.value = <AiDegradation>[];
  }
}
