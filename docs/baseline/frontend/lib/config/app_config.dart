/// 构建期配置：全部来自 `--dart-define`，不读 `.env`、不含任何密钥。
///
/// 客户端连哪份库是**构建期**决定的。换后端地址必须重新出包 ——
/// 改服务器上的 .env 不会影响已安装的 APP，这是最常见的一类「配置改了没生效」误判。
///
/// 构造命令见 README「本地启动」。
class AppConfig {
  const AppConfig._();

  static const String dataApiBaseUrl =
      String.fromEnvironment('DATA_API_BASE_URL');
  static const String aiBaseUrl = String.fromEnvironment('AI_BASE_URL');

  static const int dataTimeoutMs =
      int.fromEnvironment('DATA_TIMEOUT_MS', defaultValue: 12000);
  static const int aiTimeoutMs =
      int.fromEnvironment('AI_TIMEOUT_MS', defaultValue: 90000);
  static const int aiUploadTimeoutMs =
      int.fromEnvironment('AI_UPLOAD_TIMEOUT_MS', defaultValue: 120000);
  static const int aiJudgeTimeoutMs =
      int.fromEnvironment('AI_JUDGE_TIMEOUT_MS', defaultValue: 45000);

  static bool get hasCloudBackend => dataApiBaseUrl.isNotEmpty;
  static bool get hasAiGateway => aiBaseUrl.isNotEmpty;

  static Uri dataUri(String path, [Map<String, String>? query]) =>
      _uri(dataApiBaseUrl, path, 'DATA_API_BASE_URL', query);

  static Uri aiUri(String path, [Map<String, String>? query]) =>
      _uri(aiBaseUrl, path, 'AI_BASE_URL', query);

  static Uri _uri(
    String base,
    String path,
    String defineName,
    Map<String, String>? query,
  ) {
    if (base.isEmpty) {
      throw AppConfigException(
        '未配置 $defineName，请用 --dart-define=$defineName=... 重新构建',
      );
    }
    final normalized = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final uri = Uri.parse('$normalized$path');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: {...uri.queryParameters, ...query});
  }
}

class AppConfigException implements Exception {
  const AppConfigException(this.message);
  final String message;

  @override
  String toString() => 'AppConfigException: $message';
}
