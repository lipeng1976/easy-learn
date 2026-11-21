import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// HTTP 传输层。页面 / 仓储不直接碰 http 包。
///
/// ★ 超时处理：`.timeout()` **不会关掉底层 socket**，只加它会挂到 90s。
///   这里在 onTimeout 里显式 client.close()，并把错误标成 network_error / retryable。
class ApiClient {
  ApiClient({
    required this.baseUrl,
    this.token,
    Duration? timeout,
    http.Client Function()? clientFactory,
  })  : timeout = timeout ?? const Duration(milliseconds: 12000),
        _clientFactory = clientFactory ?? (() => http.Client());

  final String baseUrl;
  final String? token;
  final Duration timeout;
  final http.Client Function() _clientFactory;

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
  }) async {
    final response = await _send('GET', path, query: query);
    return _decode(response);
  }

  Future<Map<String, dynamic>> postJson(String path, Object? body) async {
    final response = await _send('POST', path, body: body);
    return _decode(response);
  }

  /// 只返回字节，客户端不接触任何路径。
  Future<List<int>> getBytes(String path) async {
    final response = await _send('GET', path);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _throwFrom(response);
    }
    return response.bodyBytes;
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (baseUrl.isEmpty) {
      throw const ApiException(
        status: 0,
        code: 'config_missing',
        message: '未配置服务地址（构建期 --dart-define 注入）',
        retryable: false,
      );
    }

    final client = _clientFactory();
    try {
      final uri = _buildUri(path, query);
      final headers = <String, String>{'Accept': 'application/json'};
      if (token != null && token!.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }

      late final Future<http.Response> future;
      if (method == 'GET') {
        future = client.get(uri, headers: headers);
      } else {
        headers['Content-Type'] = 'application/json; charset=utf-8';
        future = client.post(
          uri,
          headers: headers,
          body: jsonEncode(body ?? <String, dynamic>{}),
        );
      }

      return await future.timeout(timeout, onTimeout: () {
        client.close();
        throw const ApiException(
          status: 0,
          code: 'network_error',
          message: '请求超时',
          retryable: true,
        );
      });
    } on ApiException {
      rethrow;
    } on http.ClientException catch (err) {
      throw ApiException(
        status: 0,
        code: 'network_error',
        message: err.message,
        retryable: true,
      );
    } finally {
      client.close();
    }
  }

  Uri _buildUri(String path, Map<String, String>? query) {
    final normalized =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final uri = Uri.parse('$normalized$path');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: {...uri.queryParameters, ...query});
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _throwFrom(response);
    }
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // 落到下面统一报错，不把解析细节漏给上层。
    }
    throw const ApiException(
      status: 0,
      code: 'internal',
      message: '服务端返回了非预期的响应体',
      retryable: false,
    );
  }

  Never _throwFrom(http.Response response) {
    var code = 'internal';
    var message = '请求失败（HTTP ${response.statusCode}）';
    var retryable = false;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final error = decoded is Map ? decoded['error'] : null;
      if (error is Map) {
        code = error['code']?.toString() ?? code;
        message = error['message']?.toString() ?? message;
        retryable = error['retryable'] == true;
      }
    } catch (_) {
      // 非 JSON 错误响应保留默认信息。
    }
    throw ApiException(
      status: response.statusCode,
      code: code,
      message: message,
      retryable: retryable,
    );
  }
}
