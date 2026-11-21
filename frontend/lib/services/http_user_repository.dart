import '../models/user_profile_model.dart';
import '../repositories/user_repository.dart';
import 'data_api_client.dart';
import 'data_row_values.dart';

/// 用户与档案的**服务端实现**。
///
/// 本地那份读的是一张单独的表（`user_profile`），而服务端把这几列放在
/// `app_user` 上（`gender / grade / hobbies / bio` 本来就在那张表的 DDL 里）。
/// 这对调用方不可见 —— 它只看 [UserProfileModel]。
///
/// ## 「读不到」与「字段为空」是两件事，这里必须保持这个区分
///
/// 契约写明 [queryUserProfile] 返回可空：用户不存在是 `null`，
/// 用户存在但档案字段为空是**一个字段为空的模型**。
/// 服务端返回的是 `{items: [...]}`，所以：
/// - `items` 为空 → `null`（真的读不到：id 不存在，或被 RLS 挡在外面）；
/// - `items` 有行但 `name`/`grade` 是空串 → 仍然返回模型。
/// 把后一种也做成 `null`，症状是「刚注册的用户点开资料页显示『用户不存在』」。
class HttpUserRepository implements UserRepository {
  HttpUserRepository(this._api);

  final DataApiClient _api;

  @override
  Future<UserProfileModel?> queryUserProfile(String userId) async {
    final items = await _api.getItems('/data/users', query: {'userId': userId});
    if (items.isEmpty) return null;
    return _profileOf(items.first);
  }

  /// 改档案。**只改传进来的字段**（服务端是掩码语义，见 `routes/user.js`）。
  ///
  /// `userId` 一起发上去是为了让服务端能明确「要改谁」。它**不是**权限声明：
  /// `app_user` 的 `user_write_self` policy 只允许改自己那一行，
  /// 传别人的 id 会得到 403 而不是改成功。
  @override
  Future<void> updateUserProfile(UserProfileModel profile) async {
    await _api.postJson('/data/users/profile', body: {
      'userId': profile.userId,
      ...profile.toMap(),
    });
  }

  /// 按 id 批量取用户行。
  ///
  /// 返回的是**原始行**（契约如此）：调用方只用 `name` / `avatar` 这类展示字段。
  /// 看不见的 id 会**直接不出现**，不报错 —— 家长端在一个已解绑的孩子身上
  /// 应当少一行，而不是整页失败。
  @override
  Future<List<Map<String, dynamic>>> queryUsersByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final data = await _api.getJson('/data/users', query: {'ids': ids.join(',')});
    return mapList(data['items']);
  }

  /// 服务端的行 → [UserProfileModel]。
  ///
  /// `hobbies` 在两边都是**逗号串**（`UserProfileModel.toMap()` 用
  /// `hobbies.join(',')`），这里拆回去。空串拆出来是 `[]` 而不是 `['']` ——
  /// 后者会让资料页上显示出一个空标签。
  UserProfileModel _profileOf(Map<String, dynamic> row) {
    final hobbies = textOf(row['hobbies'])
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return UserProfileModel(
      userId: textOf(row['id']),
      name: textOf(row['name']),
      gender: textOf(row['gender']),
      grade: textOf(row['grade']),
      term: textOf(row['term']),
      hobbies: hobbies,
      bio: textOf(row['bio']),
    );
  }
}
