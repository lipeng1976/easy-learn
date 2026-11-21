import '../models/subject_scope.dart';
import 'data_api_client.dart';

/// 学科范围的云端仓库：**配置只有一份真相，在服务端**。
///
/// 家长与孩子是两个账号、两台设备，父母还可能各用一台 —— 配置存本地
/// 必然出现「爸爸配好了、妈妈那边还是未配置」。所以：
///   · 读：没配置返回 `configured:false`（不是 null、不抛错）；
///   · 写：失败要响亮（家长正等着保存结果）。
///
/// 纯本地模式（`DatabaseService.isCloud == false`）下界面整块不渲染，
/// 因此这里的不可用实现**写也抛错**，不假装保存成功。
abstract class SubjectScopeRepository {
  Future<List<SubjectScope>> listScopes(String studentId);

  Future<SubjectScope> getScope({
    required String studentId,
    required String subject,
  });

  /// 配置页的候选：错题本里**这一科**出现过的知识点/事件名。
  ///
  /// 单独一条端点而不是复用 `/data/checkin/seeds`：那条是「全科候选」，
  /// 语文配置页列出「整式化简」会让家长以为孩子语文错过它。
  Future<List<String>> loadSeeds({
    required String studentId,
    required String subject,
  });

  Future<SubjectScope> putScope(SubjectScope scope);
}

class HttpSubjectScopeRepository implements SubjectScopeRepository {
  const HttpSubjectScopeRepository(this._api);

  final DataApiClient _api;

  @override
  Future<List<SubjectScope>> listScopes(String studentId) async {
    final data = await _api.getJson(
      '/data/subject/scopes',
      query: <String, Object?>{'studentId': studentId},
    );
    final raw = data['scopes'];
    if (raw is! List) return const <SubjectScope>[];
    return raw
        .whereType<Map>()
        .map((one) => SubjectScope.fromJson(
              Map<String, dynamic>.from(one),
              studentId: studentId,
            ))
        .toList();
  }

  @override
  Future<SubjectScope> getScope({
    required String studentId,
    required String subject,
  }) async {
    final data = await _api.getJson(
      '/data/subject/scope',
      query: <String, Object?>{'studentId': studentId, 'subject': subject},
    );
    final scope = data['scope'];
    return SubjectScope.fromJson(
      scope is Map ? Map<String, dynamic>.from(scope) : const <String, dynamic>{},
      studentId: studentId,
      subject: subject,
    );
  }

  @override
  Future<List<String>> loadSeeds({
    required String studentId,
    required String subject,
  }) async {
    final data = await _api.getJson(
      '/data/subject/seeds',
      query: <String, Object?>{'studentId': studentId, 'subject': subject},
    );
    final raw = data['seeds'];
    if (raw is! List) return const <String>[];
    return raw
        .whereType<Map>()
        .map((one) => (one['knowledge'] ?? '').toString().trim())
        .where((one) => one.isNotEmpty)
        .toList();
  }

  @override
  Future<SubjectScope> putScope(SubjectScope scope) async {
    final data = await _api.putJson(
      '/data/subject/scope',
      body: scope.toWriteJson(),
    );
    final saved = data['scope'];
    return SubjectScope.fromJson(
      saved is Map ? Map<String, dynamic>.from(saved) : const <String, dynamic>{},
      studentId: scope.studentId,
      subject: scope.subject,
    );
  }
}

/// 没连云端：读回「未配置」，写直接失败。
///
/// 写为什么不静默成功：这个类**只在装配失败/本机模式**出现，而此时界面
/// 已被 `SubjectBoard` 整块隐藏；真有人调到这里，说明装配出了别的问题，
/// 假装保存会让家长以为配好了、孩子却永远看不到范围。
class UnavailableSubjectScopeRepository implements SubjectScopeRepository {
  const UnavailableSubjectScopeRepository();

  @override
  Future<List<SubjectScope>> listScopes(String studentId) async =>
      const <SubjectScope>[];

  @override
  Future<SubjectScope> getScope({
    required String studentId,
    required String subject,
  }) async =>
      SubjectScope(studentId: studentId, subject: subject);

  @override
  Future<List<String>> loadSeeds({
    required String studentId,
    required String subject,
  }) async =>
      const <String>[];

  @override
  Future<SubjectScope> putScope(SubjectScope scope) async {
    throw StateError('没有连接数据服务，学科范围保存不了');
  }
}
