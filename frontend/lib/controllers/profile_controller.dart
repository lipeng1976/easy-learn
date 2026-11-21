import 'package:get/get.dart';

import '../models/relationship_model.dart';
import '../models/user_profile_model.dart';
import '../repositories/relationship_repository.dart';
import '../repositories/user_repository.dart';
import '../services/database_service.dart';
import 'notification_controller.dart';

/// 个人信息与结伴。
///
/// 依赖**两个**数据契约：档案（[UserRepository]）与关系（[RelationshipRepository]）。
/// 拆开是因为它们将来上云的时间点不同 —— 关系要跟着「服务端登录」一起上
/// （邀请必须查得到对方账号），而档案可以更晚。
class ProfileController extends GetxController {
  ProfileController({
    RelationshipRepository? relationships,
    UserRepository? users,
  }) : _relationships = relationships ?? DatabaseService.instance,
       _users = users ?? DatabaseService.instance;

  final RelationshipRepository _relationships;
  final UserRepository _users;

  final Rx<UserProfileModel?> profile = Rx<UserProfileModel?>(null);
  final RxList<RelationshipModel> relationships = <RelationshipModel>[].obs;
  final RxBool isLoading = false.obs;

  Future<void> load(String userId) async {
    isLoading.value = true;
    try {
      profile.value = await _users.queryUserProfile(userId);
      relationships.value = await _relationships.queryRelationships(userId);
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> saveProfile(UserProfileModel value) async {
    await _users.updateUserProfile(value);
    profile.value = value;
  }

  Future<void> inviteByPhone({
    required String senderId,
    required String phone,
  }) async {
    final relationship = await _relationships.createRelationshipInvitation(
      senderId: senderId,
      targetPhone: phone,
    );
    relationships.insert(0, relationship);

    if (Get.isRegistered<NotificationController>()) {
      Get.find<NotificationController>().addNotification(
        title: '结伴邀请',
        body: '已向手机号 $phone 发出结伴邀请，等待对方确认',
      );
    }
  }

  Future<void> updateRelationship(String id, RelationshipStatus status) async {
    await _relationships.updateRelationshipStatus(id: id, status: status);
    final index = relationships.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final current = relationships[index];
    relationships[index] = RelationshipModel(
      id: current.id,
      studentId: current.studentId,
      parentId: current.parentId,
      senderId: current.senderId,
      studentName: current.studentName,
      parentName: current.parentName,
      status: status,
    );
  }

  /// 解除结伴（**家长单方，立即生效**）。
  ///
  /// 与 [updateRelationship] 一样把服务端的错误原样抛给调用方（不吞）：
  /// 非家长是 403、关系不是 active 也是 403 —— 两种情况都该让用户看到，
  /// 而不是静默地「什么都没发生」。
  ///
  /// ⚠️ 成功后**重拉整页**（而不是像 [updateRelationship] 那样就地改那一行）。
  /// 为什么必须重拉：解除改变的是**服务端算出来的可见集合**（家长从此看不到
  /// 这个孩子），而 `relationships` 只是本地镜像。只改这一行的话，
  /// 列表上那条确实是 `已解除` 了，但**孩子的数据仍在别处的内存里**
  /// （家长端首页 / 积分 / 复习都是各自加载的），要等下次重启才消失 ——
  /// 那正是「解除之后还能看到」的假象。
  ///
  /// ⚠️ 但**这一层拉不干净 `ParentController` 的数据**（它有自己的 children
  /// 与账本），所以调用方还必须同时刷它 —— 见 `binding_page.dart: _revoke`
  /// 的说明。两处都要做，缺一个就会出现「结伴列表已经解除、首页还看得到孩子」。
  Future<void> revokeRelationship({
    required String id,
    required String requesterId,
  }) async {
    await _relationships.revokeRelationship(id: id);
    await load(requesterId);
  }
}
