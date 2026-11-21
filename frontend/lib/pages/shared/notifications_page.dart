import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/notification_controller.dart';
import '../../controllers/parent_controller.dart';
import '../../controllers/student_controller.dart';
import '../../models/notification_model.dart';
import '../../utils/pop_route.dart';

class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  /// 点击一条通知：先标已读，再**跳到能处理它的那一屏**。
  ///
  /// `AppNotificationModel.relatedBizId` 的注释写着「点击通知可直达详情」,
  /// 而这里原来只做「标为已读」—— 于是家长收到「孩子想兑换心愿」之后
  /// **被告知了、却无处可去**：点进去只是列表上多一个灰点，心愿页那份
  /// 登录时取到的旧快照里，同意/拒绝两个按钮根本不存在。
  ///
  /// ## 第二轮（2026-09-25）：从「只接口愿」扩到两端主要类型
  ///
  /// 落点只用**已存在的页签**（底部导航的对应 tab），不新建页面：
  /// - 学生端：作业 / 运动 / 复习 / 计划 / 心愿五个类型各有对应 tab；
  /// - 家长端：心愿之外，作业 → 总览、计划 → 计划、复习 → 复习。
  ///
  /// `dailyComment` 两端都**故意不接**：它该落在哪一屏还没定口径
  /// （学生端展示位置分散，接错了比不接更糟）—— 点了仍只标已读。
  /// `system` 同理。
  ///
  /// ## 为什么落地后必须重拉
  ///
  /// 通知说的就是「刚刚发生的事」，而两端手里的都是**登录那一刻的快照** ——
  /// 不重拉的话，跳过去看到的还是旧数据，等于白跳（B7 的核心教训）。
  void _openRelated(BuildContext context, AppNotificationModel item) {
    final role = Get.isRegistered<AuthController>()
        ? Get.find<AuthController>().currentUser.value?.role
        : null;

    if (role == 'student' && Get.isRegistered<StudentController>()) {
      final tab = _studentTabIndexFor(item.type);
      if (tab == null) return;
      final student = Get.find<StudentController>();
      student.currentTabIndex.value = tab;
      student.loadData();
      if (Navigator.of(context).canPop()) popRoute(context);
      return;
    }

    if (role != 'parent' || !Get.isRegistered<ParentController>()) return;

    final parent = Get.find<ParentController>();
    if (item.type == NotificationType.wish) {
      // 心愿是家长端唯一一处**要当场做决定**的通知
      // （同意/拒绝会动积分，孩子那边在等），用窄口径的 refreshWishes
      // 而不是全量 loadData —— 后者是一串串行查询，点按会有迟滞。
      parent.currentTab.value = ParentTab.wishes;
      parent.refreshWishes();
      if (Navigator.of(context).canPop()) popRoute(context);
      return;
    }
    final parentTab = _parentTabFor(item.type);
    if (parentTab == null) return;
    parent.currentTab.value = parentTab;
    parent.loadData();
    if (Navigator.of(context).canPop()) popRoute(context);
  }

  /// 学生端通知类型 → 首页 tab 下标（Homework/Workout/Review/Plan/Wish）。
  /// 返回 null 表示「暂无落点」，只标已读。
  int? _studentTabIndexFor(NotificationType type) => switch (type) {
    NotificationType.homework => 0,
    NotificationType.workout => 1,
    NotificationType.review => 2,
    NotificationType.studyPlan => 3,
    NotificationType.wish => 4,
    _ => null,
  };

  /// 家长端通知类型 → 页签。心愿单独走（要当场决策 + 窄口径重拉）。
  ParentTab? _parentTabFor(NotificationType type) => switch (type) {
    NotificationType.homework => ParentTab.overview,
    NotificationType.studyPlan => ParentTab.plans,
    NotificationType.review => ParentTab.review,
    _ => null,
  };

  /// 一键全部标已读。
  ///
  /// 只改已读状态、不删不跳，所以**不做二次确认** —— 给一个「确认」弹窗
  /// 反而会让人以为这是不可逆操作。
  ///
  /// 失败必须说出来：控制器会把乐观改过的内存整体回滚，但如果界面一声不响，
  /// 家长只会看到红点「点了没消失」，然后反复点。这正是本项目最忌讳的
  /// 那种静默失败 —— 所以成功、失败都给一句 SnackBar。
  Future<void> _markAllRead(
    BuildContext context,
    NotificationController controller,
  ) async {
    final ok = await controller.markAllAsRead();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已全部标为已读' : '标记失败，请稍后重试'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<NotificationController>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('消息通知'),
        actions: [
          // 未读清零时按钮消失：留着它只会让人点一下、然后什么都没有发生。
          Obx(() {
            if (controller.unreadCount == 0) return const SizedBox.shrink();
            return TextButton(
              onPressed: () => _markAllRead(context, controller),
              child: const Text('全部已读'),
            );
          }),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Obx(() => Text('${controller.unreadCount} 未读')),
              ),
            ),
          ),
        ],
      ),
      body: Obx(() {
        final notifications = controller.notifications;
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: notifications.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final item = notifications[index];
            return GestureDetector(
              onTap: () {
                controller.markAsRead(item.id);
                _openRelated(context, item);
              },
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: item.isRead
                      ? Colors.white
                      : AppColors.primary.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      margin: const EdgeInsets.only(top: 6),
                      decoration: BoxDecoration(
                        color: item.isRead ? Colors.grey : AppColors.warning,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            item.body,
                            style: const TextStyle(color: AppColors.textMuted),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            item.createdAt.toLocal().toString().substring(
                              0,
                              16,
                            ),
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      }),
    );
  }
}
