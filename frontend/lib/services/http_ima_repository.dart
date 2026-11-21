import '../repositories/ima_repository.dart';
import 'data_api_client.dart';

/// ima 仓库的 HTTP 实现：把三个端点翻译成 [DataApiClient] 的读 / 写。
///
/// 信封拆封、token 携带、写后缓存作废全在 [DataApiClient] 里统一处理，
/// 这里只负责「拼路径 + 收字段」。写路径（connect / disconnect）走 [DataApiClient.postJson]，
/// 会自动作废读缓存，符合「写成功即整体作废」的全局约定。
class HttpImaRepository implements ImaRepository {
  const HttpImaRepository(this._api);

  final DataApiClient _api;

  /// `studentId` 只在非空时带上：空串与「没传」在服务端是两种语义
  /// （前者会被 `requireVisibleStudent` 判成缺参，后者走旧客户端兼容）。
  Map<String, Object?> _scope(String? studentId) =>
      (studentId == null || studentId.isEmpty)
          ? const <String, Object?>{}
          : <String, Object?>{'studentId': studentId};

  @override
  Future<ImaStatus> getStatus({String? studentId}) async {
    final scope = _scope(studentId);
    // 读缓存的 key 已包含 query（见 DataApiClient._cacheKey），
    // 所以切孩子不会命中上一个孩子的状态。
    final data = await _api.getJson(
      '/data/ima/status',
      query: scope.isEmpty ? null : scope,
    );
    return ImaStatus.fromJson(data);
  }

  @override
  Future<ImaStatus> connect({
    required String clientId,
    required String apiKey,
    String? studentId,
  }) async {
    // ⚠️ 键名必须与服务端一致：routes/ima.js 读的是 `clientid` / `apikey`
    // （全小写），不是 Dart 风格的 `clientId` / `apiKey`。
    final data = await _api.postJson(
      '/data/ima/connect',
      body: <String, Object?>{
        'clientid': clientId,
        'apikey': apiKey,
        ..._scope(studentId),
      },
    );
    return ImaStatus.fromJson(data);
  }

  @override
  Future<void> disconnect({String? studentId}) async {
    await _api.postJson('/data/ima/disconnect', body: _scope(studentId));
  }
}

/// 纯本地（无云端）模式下 ima 同步不可用：
/// 状态恒为未连接，连接会给出明确的本地模式提示，而不是静默失败。
class UnconfiguredImaRepository implements ImaRepository {
  const UnconfiguredImaRepository();

  @override
  Future<ImaStatus> getStatus({String? studentId}) async =>
      const ImaStatus(status: 'unconnected', available: false);

  @override
  Future<ImaStatus> connect({
    required String clientId,
    required String apiKey,
    String? studentId,
  }) async {
    throw DataApiException(
      code: 'unavailable',
      message: '当前为本地模式，无法连接 ima 知识库；请使用联网版本。',
    );
  }

  @override
  Future<void> disconnect({String? studentId}) async {}
}
