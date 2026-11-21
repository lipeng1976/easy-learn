import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/data_status_controller.dart';
import '../../controllers/notification_controller.dart';
import '../../controllers/parent_controller.dart';
import '../../controllers/reading_controller.dart';
import '../../widgets/offline_data_banner.dart';
import 'widgets/parent_app_bar.dart';
import 'tabs/overview_tab.dart';
import 'tabs/plans_tab.dart';
import 'tabs/points_tab.dart';
import 'tabs/review_parent_tab.dart';
import 'tabs/wishes_parent_tab.dart';

class ParentHomePage extends StatefulWidget {
  const ParentHomePage({super.key});

  @override
  State<ParentHomePage> createState() => _ParentHomePageState();
}

class _ParentHomePageState extends State<ParentHomePage>
    with WidgetsBindingObserver {
  final ParentController controller = Get.put(ParentController());
  final NotificationController notificationController = Get.put(
    NotificationController(),
  );

  /// 数据层提示位（方案 B）。家长端比学生端**更需要**它：
  /// 家长看到的是一份「孩子的」数据，而那份数据随时可能被孩子那一端改掉 ——
  /// 一个陈旧的「已完成」会让家长做出错误判断，且他不会再回来核对。
  final DataStatusController dataStatus = Get.put(DataStatusController());

  final List<Widget> pages = const [
    OverviewTab(),
    PlansTab(),
    ReviewParentTab(),
    WishesParentTab(),
    PointsTab(),
  ];

  @override
  void initState() {
    super.initState();
    // 同学生端：NotificationController 早于登录创建，进入首页后要按
    // 当前家长账号重新拉取，否则收不到「孩子提交作业」这类定向通知。
    notificationController.loadNotifications();

    // 回前台重拉：家长端比学生端更需要 —— 孩子在另一台设备上做的事
    // （提交作业、申请兑换）都发生在后台期间，不重拉就永远是旧快照（B7）。
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    controller.loadData();
    // 积分页的数据来自另一个按需拉的入口（loadPointsForSelected），
    // loadData 不覆盖它；当前正停在积分页时单独补一次。
    if (controller.currentTab.value == ParentTab.points) {
      controller.loadPointsForSelected();
    }
    notificationController.loadNotifications();
  }

  /// 切换底部页签。
  ///
  /// 进「心愿」页时顺带重拉一次心愿与余额：心愿是家长端唯一一处
  /// **孩子在另一台设备上先动手、家长在这里等确认**的地方，
  /// 而家长端的数据是登录那一刻取的一份快照（见 `refreshWishes` 的说明）。
  /// 其余四个页签是「查看」，交给下拉刷新，不在这里每次都拉一遍 ——
  /// `loadData()` 是一串串行查询，挂在每次切页上会让点按有明显的迟滞。
  void _onTabSelected(int index) {
    final next = ParentTab.values[index];
    final changed = controller.currentTab.value != next;
    controller.currentTab.value = next;
    if (changed && next == ParentTab.wishes) {
      controller.refreshWishes();
    }
    // 进「计划」页时重拉阅读任务与今天的打卡。
    //
    // 阅读是**孩子在另一台设备上产生的数据**：家长开着 App 的时候孩子
    // 刚读完一篇，切回计划页看到的还是旧数字和「今天还没打卡」——
    // 而它不会报错，家长只会以为孩子没读。两个请求都很小，不整包
    // `loadData()`（那是串行的一长串）。
    if (changed && next == ParentTab.plans && Get.isRegistered<ReadingController>()) {
      final reading = Get.find<ReadingController>();
      reading.load();
      reading.loadTodayLogs();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 连订阅一起收掉。留着它的话，一个已经销毁的页面会继续订阅数据层事件 ——
    // 而事件在切换角色之后仍然会来，于是它每次都在往一个死掉的 Rx 上写。
    if (Get.isRegistered<DataStatusController>()) {
      Get.delete<DataStatusController>(force: true);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 整页包一层 `Obx`：顶栏与底部导航都要跟着控制器上的值走
    // （孩子列表、当前选中的孩子、未读数、当前页签）。同学生端首页的写法。
    return Obx(() {
      final selectedIndex = controller.currentTab.value.index;
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: ParentAppBar(
          students: controller.boundStudents.toList(),
          selectedId: controller.selectedStudentId.value,
          onSelect: (id) => controller.selectedStudentId.value = id,
          unreadCount: notificationController.unreadCount,
        ),
        body: Column(
          children: [
            // 横幅在 tab 之外，与「选择孩子」的下拉框一样属于整页的上下文：
            // 「这份数据可能不是此刻的」这句话对哪个 tab 都成立。
            OfflineDataBanner(status: dataStatus),
            Expanded(
              // 家长看到的是**孩子的**数据，而那份数据随时可能被孩子那一端
              // 改掉；此前整页没有任何重拉入口，家长只能杀掉应用重进。
              //
              // 五个 tab 的根都是 `ListView`，挂在外面的 `RefreshIndicator`
              // 一次就能管住全部，不必逐个 tab 去包。
              //
              // 不需要给各 tab 的 ListView 加 `AlwaysScrollableScrollPhysics` ——
              // 实测（见 `test/parent_wish_redeem_flow_test.dart` 里的下拉用例）
              // Flutter 对**无 controller、未设 primary** 的纵向 `ListView`
              // 会自动套上该物理（`scroll_view.dart`），短列表同样能下拉；
              // 之前那版注释宣称「不加就拉不动」，是没验过的民间说法。
              child: RefreshIndicator(
                onRefresh: controller.loadData,
                child: pages[selectedIndex],
              ),
            ),
          ],
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: selectedIndex,
          onTap: _onTabSelected,
          type: BottomNavigationBarType.fixed,
          selectedItemColor: AppColors.primary,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.dashboard), label: '首页'),
            BottomNavigationBarItem(icon: Icon(Icons.fact_check), label: '计划'),
            BottomNavigationBarItem(
              icon: Icon(Icons.library_books),
              label: '复习',
            ),
            BottomNavigationBarItem(icon: Icon(Icons.favorite), label: '心愿'),
            BottomNavigationBarItem(icon: Icon(Icons.stars), label: '积分'),
          ],
        ),
      );
    });
  }
}
