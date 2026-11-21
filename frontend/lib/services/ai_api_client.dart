import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../models/ai_metrics_model.dart';
import 'ai_config.dart';
import 'endpoint_resolver.dart';

/// AI 网关的 HTTP 传输层。
///
/// **刻意不做重试**：重试策略需要「这次为什么失败」的信息才能决定要不要重试，
/// 而校验失败的详情只有上层（[RemoteAiDataSource]）才有 —— 例如模型返回的
/// JSON 少了一个必需字段，重试时应当把这条信息带回去纠正模型。
/// 把重试放在传输层，上层就只能盲重试，白白多花一次 token。
///
/// 这里只负责把一次请求做对：鉴权头、UTF-8、超时、错误归一。
class AiApiClient {
  AiApiClient({
    required this.config,
    required AiIdentity identity,
    this.identityOf,
    this.endpoint,
    http.Client? client,
  }) : _frozenIdentity = identity,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final AiConfig config;

  /// 多地址择优（家里局域网 / Tailscale）。null = 只用 [AiConfig.baseUrl]，
  /// 与接入这个能力之前**逐字相同**。
  final EndpointResolver? endpoint;

  /// 当前实际发往的网关地址：探测选中的那个，没选出来就用首选。
  String get activeBaseUrl => endpoint?.active ?? config.baseUrl;

  /// 装配时定下的身份。没有 [identityOf] 时用它。
  final AiIdentity _frozenIdentity;

  /// 按请求解析身份。
  ///
  /// 为什么不是构造时定死：身份**在运行期内会变** —— 登录、退出、
  /// 家长切换孩子，都会让它变。定死之后，最坏的情况不是「用了旧学号」，
  /// 而是「装配时还没登录，于是一整个会话都在用占位符学号」：
  /// 网关按无身份拒收，客户端再降级成本地模拟，
  /// 用户看到的是「照片认不出内容」，而模型一次都没被调用
  /// （2026-09-15 那次排查就是这个形状）。
  ///
  /// 惰性解析把这类 bug 从「时序问题」降级成「不会发生」：
  /// 请求发出的那一刻身份是什么，就用什么。
  final AiIdentity Function()? identityOf;

  /// 当前身份。每次访问都重新解析。
  AiIdentity get identity => identityOf?.call() ?? _frozenIdentity;

  final http.Client _client;
  final bool _ownsClient;

  static final Random _random = Random();
  static int _sequence = 0;

  /// 发一次 POST，返回响应信封里的 `data`。
  ///
  /// 抛出的异常一律是 [AiRequestException]，调用方据此判断是否值得重试。
  ///
  /// [requireIdentity] 默认开。关掉只有一种情形：探活 ——
  /// 网关的 `/ai/health` 刻意不鉴权（监控系统不该为了取一个状态码而持有学生身份），
  /// 而「启动时先问一句后端在不在」恰恰发生在登录之前。
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body, {
    Duration? timeout,
    bool requireIdentity = true,
  }) async {
    final uri = _resolve(path);
    final requestId = _nextRequestId();
    final current = identity;

    // 没有可用身份就**不发**。
    //
    // 这一条是本地判断，不是省一次往返那么简单：拿占位符去问，
    // 网关只能回一个「缺少 X-Student-Id」的 bad_request，
    // 而那个错误字符串对排查毫无帮助（请求头明明在，只是值没意义）。
    // 在源头挡住，调用方拿到的是一句能读懂的 'no_identity'。
    if (requireIdentity && !current.usable) {
      throw const AiRequestException(
        code: 'no_identity',
        message: '尚未登录，本次没有向网关发送请求',
        retryable: false,
      );
    }

    late final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: _headers(requestId, current),
            // 传字节而不是字符串：字符串会被 http 包按自己的规则编码，
            // 中文与 emoji 一旦落进 latin1 就成了问号，而错题本里全是中文。
            body: utf8.encode(jsonEncode(body)),
          )
          .timeout(timeout ?? config.requestTimeout);
    } on TimeoutException {
      throw AiRequestException(
        code: 'timeout',
        message: '请求超时（${(timeout ?? config.requestTimeout).inSeconds}s）',
        retryable: true,
      );
    } on http.ClientException catch (e) {
      // 连不上 ⇒ 可能只是换了网络（出门 / 回家）。把当前地址作废，
      // **这一次仍然失败**，但下一次会用重新探测出来的地址。
      //
      // 刻意不在这里重试：本类不做重试（见类注释），重试策略在上层，
      // 而「多花一次 token」比「少一次往返」贵得多。
      await endpoint?.onNetworkFailure();
      // 断网、DNS 失败、连接被重置都归一到这里。可重试 ——
      // 移动网络的抖动是常态，一次重试能救回相当一部分请求。
      throw AiRequestException(
        code: 'transport_error',
        message: '网络异常：${e.message}',
        retryable: true,
      );
    }

    return _decode(response, requestId);
  }

  /// 健康检查。故意走同一套错误处理 ——
  /// 探测接口本身如果静默失败，「能力开关」就会永远停在默认值上。
  ///
  /// `requireIdentity: false`：这条端点在网关上就是不鉴权的，
  /// 而调用它最常见的位置是「进首页时问一句后端在不在」——
  /// 若也要身份，未登录状态下连能力位都探不到。
  Future<Map<String, dynamic>> health() => postJson(
    AiEndpoints.health,
    const {'probe': true},
    timeout: const Duration(seconds: 5),
    requireIdentity: false,
  );

  /// 用量与成本看板。
  ///
  /// 走 POST 而不是 GET：网关为两种方法都开了路由，而本类只实现 POST ——
  /// 为看板单独加一条 GET 通道，等于让鉴权头、错误归一、UTF-8 解码
  /// 各多一份实现，而它们正是最容易出「只在某一条路径上」的 bug 的地方。
  ///
  /// **不会降级、不会重试**：看板是一个只读的观察面，
  /// 取不到就如实报错让界面说「取不到」，比回落成一份本地缓存更诚实 ——
  /// 缓存里的成本数字看起来一样精确，但它已经不是当下的账了。
  Future<AiMetrics> metrics() async {
    final data = await postJson(
      AiEndpoints.metrics,
      const <String, dynamic>{},
      timeout: const Duration(seconds: 8),
    );
    return AiMetrics.fromJson(data);
  }

  /// 把字节直传到对象存储的预签名地址。
  ///
  /// 这个方法刻意**不带任何自定义鉴权头**：预签名 URL 本身已经含有授权信息，
  /// 再叠一个 `Authorization: Bearer` 反而会被对象存储判为签名冲突而拒绝。
  /// 只有网关回传的 [extraHeaders] 才允许附加（对象存储要求的 x-tos-* 之类）。
  Future<void> putBytes(
    String absoluteUrl,
    List<int> bytes, {
    String contentType = 'application/octet-stream',
    Map<String, String> extraHeaders = const {},
  }) async {
    final headers = <String, String>{
      'Content-Type': contentType,
      ...extraHeaders,
    };

    late final http.Response response;
    try {
      response = await _client
          .put(Uri.parse(absoluteUrl), headers: headers, body: bytes)
          .timeout(config.uploadTimeout);
    } on TimeoutException {
      throw AiRequestException(
        code: 'upload_timeout',
        message: '照片上传超时（${config.uploadTimeout.inSeconds}s）',
        retryable: true,
      );
    } on http.ClientException catch (e) {
      throw AiRequestException(
        code: 'upload_transport_error',
        message: '照片上传失败：${e.message}',
        retryable: true,
      );
    }

    if (response.statusCode >= 400) {
      throw AiRequestException(
        code: 'upload_http_${response.statusCode}',
        message: '照片上传被拒绝（${response.statusCode}）',
        statusCode: response.statusCode,
        // 403 说明签名过期或不对，重试同一个 URL 不会变好，只会更慢。
        retryable: response.statusCode >= 500,
      );
    }
  }

  Map<String, dynamic> _decode(http.Response response, String requestId) {
    // 必须用 bodyBytes 自行解码。http 包在响应头没带 charset 时按 latin1 解，
    // 于是所有中文变成乱码 —— 而这类问题在英文环境测不出来，上线才发现。
    final raw = utf8.decode(response.bodyBytes, allowMalformed: true);

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      decoded = null;
    }

    if (response.statusCode >= 400) {
      // **先看信封再看状态码。**
      // 网关会在 error 里给出 retryable，而这个判断服务端比客户端准：
      // 它知道这次失败是「模型临时抽风」（可重试）还是「这个模型没开通」
      // （重试一百次也没用，只会烧钱）。先按状态码猜，就会把 503 一律当成
      // 可重试，`model_not_enabled` 这类不可重试的错误会被白重试一遍。
      if (decoded is Map<String, dynamic> && decoded['error'] is Map) {
        throw _errorFromBody(decoded, response.statusCode, requestId);
      }
      throw _errorFromStatus(response.statusCode, raw, requestId);
    }

    if (decoded == null) {
      throw AiRequestException(
        code: 'invalid_json',
        message: '网关返回的不是合法 JSON（requestId: $requestId）',
        statusCode: response.statusCode,
        retryable: false,
        requestId: requestId,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw AiRequestException(
        code: 'invalid_envelope',
        message: '网关返回的信封不是对象（requestId: $requestId）',
        statusCode: response.statusCode,
        retryable: false,
        requestId: requestId,
      );
    }

    if (decoded['ok'] == false) {
      throw _errorFromBody(decoded, response.statusCode, requestId);
    }

    final data = decoded['data'];
    if (data is! Map<String, dynamic>) {
      throw AiRequestException(
        code: 'invalid_envelope',
        message: '网关信封缺少 data 对象（requestId: $requestId）',
        statusCode: response.statusCode,
        retryable: false,
        requestId: requestId,
      );
    }
    return data;
  }

  /// 网关按约定在错误体里给出 `error.code` / `error.retryable`。
  /// 有了它，客户端不必靠 HTTP 状态码猜语义 —— 这是把重试判断交给服务端的好处。
  AiRequestException _errorFromBody(
    Map<String, dynamic> body,
    int statusCode,
    String requestId,
  ) {
    final error = body['error'];
    if (error is! Map) {
      return AiRequestException(
        code: 'gateway_error',
        message: '网关返回错误但未给出 error 对象（requestId: $requestId）',
        statusCode: statusCode,
        retryable: statusCode >= 500,
      );
    }
    final retryable = error['retryable'];
    return AiRequestException(
      code: (error['code'] as String?) ?? 'gateway_error',
      message: (error['message'] as String?) ?? '网关返回未知错误',
      statusCode: statusCode,
      retryable: retryable is bool ? retryable : statusCode >= 500,
      requestId: requestId,
    );
  }

  /// 网关没按约定返回错误体时的兜底：状态码自带的信息已经够用。
  AiRequestException _errorFromStatus(
    int statusCode,
    String raw,
    String requestId,
  ) {
    if (statusCode == 401 || statusCode == 403) {
      return AiRequestException(
        code: 'unauthorized',
        message: '网关拒绝了本次调用（$statusCode），请检查会话是否有效',
        statusCode: statusCode,
        retryable: false,
        requestId: requestId,
      );
    }
    if (statusCode == 429) {
      return AiRequestException(
        code: 'rate_limited',
        message: '调用过于频繁，已触发限流',
        statusCode: statusCode,
        retryable: true,
        requestId: requestId,
      );
    }
    if (statusCode == 413) {
      // 单独拎出来：照片太大是客户端能自己修的问题，
      // 而且必须有明确的错误码，否则会被当成「模型故障」降级，
      // 表现为「批改结果总是离线版」，根因却被埋掉。
      return AiRequestException(
        code: 'payload_too_large',
        message: '本次请求内容过大，请减少照片数量或降低分辨率',
        statusCode: statusCode,
        retryable: false,
        requestId: requestId,
      );
    }
    return AiRequestException(
      code: 'http_$statusCode',
      message: '网关返回 $statusCode：${_truncate(raw)}',
      statusCode: statusCode,
      retryable: statusCode >= 500 || statusCode == 408,
      requestId: requestId,
    );
  }

  Map<String, String> _headers(String requestId, AiIdentity current) {
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      'Accept': 'application/json',
      // 排障靠它：网关会把 requestId 打进审计日志，
      // 用户报障时能凭这一个字符串捞出完整的调用链。
      'X-Request-Id': requestId,
      'X-Student-Id': current.studentId,
    };
    if (current.deviceId.isNotEmpty) {
      headers['X-Device-Id'] = current.deviceId;
    }
    if (current.appVersion.isNotEmpty) {
      headers['X-App-Version'] = current.appVersion;
    }
    if (current.sessionToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${current.sessionToken}';
    }
    return headers;
  }

  Uri _resolve(String path) {
    final active = activeBaseUrl;
    final base = active.endsWith('/')
        ? active.substring(0, active.length - 1)
        : active;
    final suffix = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$suffix');
  }

  String _nextRequestId() {
    // 不引 uuid 依赖：requestId 只用于日志串联，不需要全局唯一性保证。
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'r$stamp${(_sequence++ % 1000).toRadixString(36)}'
        '${_random.nextInt(1 << 20).toRadixString(36)}';
  }

  static String _truncate(String value, [int max = 200]) =>
      value.length <= max ? value : '${value.substring(0, max)}…';

  /// 只关闭自己创建的连接池。外部注入的由外部负责 ——
  /// 否则测试里复用同一个 MockClient 时会莫名报「Client is already closed」。
  void close() {
    if (_ownsClient) _client.close();
  }
}

/// 一次 AI 调用失败的原因。
///
/// [retryable] 的判定权在网关：只有服务端知道这次失败是「模型临时抽风」
/// 还是「这个模型压根没开通」—— 后者重试一百次也没用，只会把账单烧掉。
class AiRequestException implements Exception {
  const AiRequestException({
    required this.code,
    required this.message,
    this.statusCode,
    this.retryable = false,
    this.requestId = '',
  });

  final String code;
  final String message;
  final int? statusCode;
  final bool retryable;
  final String requestId;

  /// 可以**直接摆给用户看**的一句话。与 [message] 分开是有意的 ——
  /// 与 `DataApiException.userMessage` 同一条理由（那边的长注释写了成因）。
  ///
  /// [message] 里装的是**排查用的东西**：底层英文异常
  /// （`ClientException: Software caused connection abort`）、`requestId`、
  /// 网关响应体原文。而它会被 `AiDegradation.reason` 带进两个**界面**
  /// （`ai_degraded_banner.dart` / `ai_observe_page.dart`）——
  /// 2026-10-06 之前那里直接显示 `message`，家长端会看到一屏英文。
  ///
  /// 服务端回来的业务文案（`error.message` 透传的那类）本来就该原样给用户，
  /// 所以这里只换**客户端本地生成**的那几个 code。
  String get userMessage {
    // `http_4xx/5xx` 的 message 里塞着响应体原文（可能是 HTML），一律不进界面。
    if (code.startsWith('http_')) return 'AI 服务暂时不可用，请稍后重试';
    return switch (code) {
      'timeout' || 'upload_timeout' => '网络较慢或服务繁忙，请稍后重试',
      'transport_error' || 'upload_transport_error' => '网络不可用，请检查网络后重试',
      'invalid_json' || 'invalid_envelope' || 'gateway_error' =>
        'AI 服务返回了无法识别的内容，请稍后重试',
      _ => message,
    };
  }

  @override
  String toString() =>
      'AiRequestException($code${statusCode == null ? '' : '/$statusCode'}): '
      '$message${requestId.isEmpty ? '' : ' [$requestId]'}';
}
