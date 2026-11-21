/// 与后端 backend/shared/errors.js 的错误码对齐。
/// retryable 决定客户端是否重试：配额失败与网络抖动必须分开。
class ApiException implements Exception {
  const ApiException({
    required this.status,
    required this.code,
    required this.message,
    required this.retryable,
  });

  final int status;
  final String code;
  final String message;
  final bool retryable;

  bool get isNetwork => code == 'network_error';
  bool get isQuota => code == 'quota_exceeded';
  bool get isAuth => status == 401 || status == 403;

  /// 只允许网络/超时类重试。写成 `if (retryable)` 而不是「失败就重试」，
  /// 否则配额失败会被无限重试到封禁。
  bool get shouldRetry => isNetwork && retryable;

  @override
  String toString() => 'ApiException($status, $code, $message)';
}
