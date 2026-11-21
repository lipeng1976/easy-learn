import 'dart:async';

import 'package:http/http.dart' as http;

import 'ai_api_client.dart';
import 'ai_config.dart';
import 'ai_data_source.dart';
import 'ai_image_transport.dart';
import 'endpoint_resolver.dart';
import 'http_ocr_data_source.dart';
import 'image_storage_service.dart';
import 'ocr_data_source.dart';
import 'remote_ai_data_source.dart';
import 'simulated_ai_data_source.dart';

/// 一次装配好的 AI 运行环境。
///
/// 存在的理由是「装配」本身有三件事要做，且顺序不能乱：
/// 先建传输层 → 再用它探测能力 → 探测结果反过来决定哪些调用可以直接短路。
/// 把这些散在调用方（`StudentHomePage` / `ReviewController` / `OcrService`）里，
/// 就会出现三处各自 new 一个 client、各自一个连接池的局面。
class AiRuntime {
  AiRuntime({
    required this.dataSource,
    required this.ocrDataSource,
    this.remote,
    this.client,
  });

  /// 学生端 / 复习端统一使用的 AI 数据源。
  final AiDataSource dataSource;

  /// OCR 数据源。
  final OcrDataSource ocrDataSource;

  /// 云端实现。为 null 表示当前是纯本地运行。
  final RemoteAiDataSource? remote;

  /// HTTP 传输层。为 null 表示当前是纯本地运行。
  final AiApiClient? client;

  bool get isRemote => remote != null;

  /// 问一次网关哪些能力开着，并据此修正短路开关。
  ///
  /// 失败静默：探测不到不代表不能用，只代表「维持默认假设」。
  /// 把探测失败做成错误只会在弱网环境里刷出一堆无意义的提示。
  Future<AiCapabilities?> refreshCapabilities() async {
    return remote?.refreshCapabilities();
  }

  /// 释放连接池。纯本地运行时不持有任何资源，调用是安全的空操作。
  void dispose() => client?.close();
}

/// 装配 AI 运行环境。
///
/// 默认（不传 [config]、也没有 `--dart-define=AI_BASE_URL`）会返回**纯本地**实现，
/// 与接入云端之前的行为完全一致。这一点是刻意的：
/// 环境变量漏配时应当退化成「本地可用」，而不是「启动即报错」或「默默开始计费」。
///
/// [identityOf] 是**按请求解析身份**的口子。传了它，登录/退出/切换孩子之后
/// 身份立即跟着变；不传就沿用 [identity] 这一份快照。
/// 现行装配一律传它：身份在运行期内会变，快照迟早会与事实不符。
AiRuntime createAiRuntime({
  AiConfig? config,
  required AiIdentity identity,
  AiIdentity Function()? identityOf,
  ImageStorageService? imageStorage,
  http.Client? httpClient,
  AiDegradationListener? onDegraded,
}) {
  final resolved = AiConfig.resolve(config);

  if (!resolved.hasBackend) {
    return AiRuntime(
      dataSource: const SimulatedAiDataSource(),
      ocrDataSource: const SimulatedOcrDataSource(),
    );
  }

  // 多地址择优（家里局域网 / Tailscale）。只有一个候选时不建 —— 没什么可选的。
  final endpoint = _buildAiEndpoint(resolved);

  // 装配是同步的，但探测是异步的 —— 这里**不阻塞**装配，先把探测放出去。
  //
  // 从装配到用户第一次点「批改 / 讲题」通常隔着好几秒，探测早回来了。
  // 万一没回来（或回来之前就点了），那一次请求会走首选地址失败一次，
  // 而失败处理里会重新探测并把地址换掉 —— 下一次就对了。
  //
  // ⚠️ 不能改成 `await`：这个函数在没有 `await` 上下文的地方被调用，
  // 改成 Future 会波及首页的装配顺序。
  if (endpoint != null) {
    unawaited(endpoint.resolve());
  }

  final client = AiApiClient(
    config: resolved,
    identity: identity,
    identityOf: identityOf,
    endpoint: endpoint,
    client: httpClient,
  );

  final remote = RemoteAiDataSource(
    client: client,
    config: resolved,
    imageUploader: _createImageUploader(
      config: resolved,
      client: client,
      imageStorage: imageStorage,
    ),
    onDegraded: onDegraded,
  );

  return AiRuntime(
    dataSource: remote,
    ocrDataSource: HttpOcrDataSource(client: client, onDegraded: onDegraded),
    remote: remote,
    client: client,
  );
}

HomeworkImageUploader _createImageUploader({
  required AiConfig config,
  required AiApiClient client,
  required ImageStorageService? imageStorage,
}) {
  if (imageStorage == null) {
    // 没有图片存取服务就送不出照片。返回占位实现而不是抛异常，
    // 让调用方按「本次没有图可用」正常降级 —— 图片服务缺失不该炸掉交作业。
    return const UnavailableHomeworkImageUploader();
  }
  return switch (config.imageTransport) {
    AiImageTransport.inline => InlineHomeworkImageUploader(
      storage: imageStorage,
      config: config,
    ),
    AiImageTransport.objectStorage => ObjectStorageHomeworkImageUploader(
      storage: imageStorage,
      client: client,
      config: config,
    ),
  };
}

/// AI 网关的地址选择器。候选少于两个时返回 `null`（没什么可选的）。
///
/// 探测路径用 `/ai/health`：那条端点在网关里 `auth: false`、不调模型，
/// 是最轻的「你在不在」信号。用业务端点探测会把单价算到你头上。
EndpointResolver? _buildAiEndpoint(AiConfig config) {
  final candidates = config.candidateBaseUrls;
  if (candidates.length < 2) return null;
  return EndpointResolver(
    candidates: candidates,
    healthPath: '/ai/health',
    expectedInstance: kServerInstanceId,
  );
}
