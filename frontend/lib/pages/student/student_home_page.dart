import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/ai_status_controller.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/data_status_controller.dart';
import '../../controllers/drill_controller.dart';
import '../../controllers/notification_controller.dart';
import '../../controllers/review_controller.dart';
import '../../controllers/student_controller.dart';
import '../../services/ai_config.dart';
import '../../services/ai_data_source.dart';
import '../../services/ai_data_source_factory.dart';
import '../../services/database_service.dart';
import '../../services/image_storage_service.dart';
import '../../widgets/ai_degraded_banner.dart';
import '../../widgets/offline_data_banner.dart';
import 'tabs/homework_tab.dart';
import 'tabs/plan_tab.dart';
import 'tabs/review_tab.dart';
import 'tabs/wish_tab.dart';
import 'tabs/workout_tab.dart';

class StudentHomePage extends StatefulWidget {
  const StudentHomePage({super.key});

  @override
  State<StudentHomePage> createState() => _StudentHomePageState();
}

class _StudentHomePageState extends State<StudentHomePage>
    with WidgetsBindingObserver {
  /// AI 运行环境：装配传输层、云端实现与本地降级。
  ///
  /// 在这里装配而不是在 `app.dart`，是因为身份要等登录之后才有值 ——
  /// 启动时装配会拿到一个空的 studentId，网关侧的配额与审计就全落在空账号上，
  /// 上线后既限额不准也追不到人。
  late final AiRuntime aiRuntime;

  late final StudentController controller;

  /// 复习闭环控制器必须在这里注册：它复用 StudentController 持有的错题池，
  /// 两者生命周期一致。若放到复习页内部再 Get.put，离开复习页会被回收，
  /// 回到页面时错题池与资料会重新拉一次，「刚批改完的结果」会有一瞬对不上。
  late final ReviewController reviewController;

  late final NotificationController notificationController;

  /// 每日概念训练控制器。注册在这里（而不是训练页内部）的理由与
  /// [reviewController] 相同：题组与已选选项要跨 tab 切换存活 ——
  /// 答到第三题切去作业 tab 再回来，不能题没变、选项没了。
  late final DrillController drillController;

  /// 降级提示位。跨页面共用一条横幅，见 [AiStatusController] 的类注释。
  late final AiStatusController aiStatus;

  /// 数据层提示位（方案 B）：断网时显示的是缓存、写没保存。
  ///
  /// 与 [aiStatus] 并列而不是合并：一个是「AI 给了离线兜底的结果」，
  /// 另一个是「你看到的数字可能不是此刻的」—— 前者说的是内容质量，
  /// 后者说的是**时间**，混成一条之后两种情况都说不清。
  late final DataStatusController dataStatus;

  final List<Widget> pages = const [
    HomeworkTab(),
    WorkoutTab(),
    ReviewTab(),
    PlanTab(),
    WishTab(),
  ];

  @override
  void initState() {
    super.initState();

    // 图片存取只建一个实例，AI 运行时与控制器共用 ——
    // Web 端它内部持有 localStorage 的写入状态（配额失败标记），
    // 两份实例会让「图片存失败」这个信号只更新在其中一份上。
    //
    // ⚠️ 用 `createImageStorage()` 而不是直接 new 本地实现：云端模式下
    // 照片必须存到服务端，否则 `storageKey` 又会是一个「设备本地标识」，
    // 家长端在别的设备上永远看不到。
    final imageStorage = createImageStorage();

    // 先建提示位：AI 运行时装配时会立刻接线 onDegraded，
    // 顺序反了就会出现「第一次降级没地方报」。
    aiStatus = Get.put(AiStatusController());

    // 数据层提示位。放在这里（而不是等某个页面按需建）的理由与 aiStatus 相同：
    // 触发它的读可能发生在任何一个 tab 的后台调用上。
    dataStatus = Get.put(DataStatusController());

    aiRuntime = Get.put(
      createAiRuntime(
        // 身份按请求解析，而不是在这里取一次快照。
        //
        // 原来的写法是 `currentUser.value?.id ?? 'anonymous'`，两个问题叠在一起：
        // ① 取了快照 —— 登录态一变，运行时就与事实不符；
        // ② 兜底值是**网关认识的占位符**，于是未登录时会把 'anonymous'
        //    当成学号发上去，网关按「无身份」拒收，客户端再降级成本地模拟。
        //    用户看到的是「照片认不出内容」，而模型一次都没被调用。
        // 现在改成：拿不到就是空身份 —— 传输层看到空身份会**不发请求**，
        // 并把原因（未登录）如实回给调用方。
        identity: _identityFromAuth(),
        identityOf: _identityFromAuth,
        imageStorage: imageStorage,
        onDegraded: _onAiDegraded,
      ),
    );

    controller = Get.put(
      StudentController(ai: aiRuntime.dataSource, imageStorage: imageStorage),
    );
    // ⚠️ 把 imageStorage 一并传进去，而不是让它自己去新建一个。
    // 两个实例会各自读一次 `DatabaseService.cloud`，在云端刚接上、
    // 或刚掉线的那个瞬间读到不同的结果 —— 于是同一张照片
    // 拍照作答这边存进了本地盘、作业那边去找远端，读回来是空的。
    //
    // 同时注册进容器：`ReviewController.imageStorage` 的兜底分支会
    // `Get.find`，而缺注册时的报错（`ImageStorageService not found`）
    // 看起来像接线漏了，真相却是「没注册」。注册在这里一处即可。
    if (!Get.isRegistered<ImageStorageService>()) {
      Get.put<ImageStorageService>(imageStorage, permanent: true);
    }
    reviewController = Get.put(
      ReviewController(ai: aiRuntime.dataSource, imageStorage: imageStorage),
    );
    notificationController = Get.put(NotificationController());
    drillController = Get.put(DrillController());

    // 进首页后问一次网关哪些能力真的开着。方舟的视觉与强推理模型通常要分别开通，
    // 部分还要单独申请；不探测的后果很具体：把 3MB 的照片发上去，
    // 等一个必然失败的响应回来，再走一遍降级 —— 用户白等十几秒。
    aiRuntime.refreshCapabilities();

    // NotificationController 在 App 启动时就创建了，那时还没有登录用户，
    // 只能拉到广播消息。进入首页后必须按当前用户重新拉取，
    // 否则上一轮会话里「老师/家长发给我的通知」在消息中心里看不到。
    notificationController.loadNotifications();

    // 回前台重拉：后台期间「另一半」（家长的点评、云端同步）发生的变化
    // 只有进对应页或下拉才看得到 —— 而人不会记得下拉（open-items B7）。
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 只接 resumed：后台↔前台的切换才是「别人可能动过数据」的信号；
    // paused 之后应用随时可能被杀，不在此处做任何写操作。
    if (state != AppLifecycleState.resumed) return;
    controller.loadData();
    notificationController.loadNotifications();
  }

  /// 从当前登录态读出请求身份。
  ///
  /// 未登录时返回**空学号**而不是占位符：网关的配额与审计要能归到某个真实学生，
  /// 占位符只会换来一个必然失败的往返。空身份由传输层识别（`AiIdentity.usable`），
  /// 直接不发请求并如实报 'no_identity'。
  ///
  /// **会话 token 也必须带上**：网关打开 `AI_REQUIRE_AUTH` 后只认它，
  /// 不带的结果是每一条 AI 调用都 401。用 [AiIdentity.resolve] 而不是自己
  /// new 一个，就是为了让 token 与学号来自同一份事实（见那个方法的说明）。
  ///
  /// 会话读的是 `DatabaseService.cloud` 上那一份 —— 与数据层、登录**共用同一个**
  /// `SessionStore`。另建一份的后果是「登录把票写进 A、AI 请求从 B 取」，
  /// 票永远取不到，而两边看起来都正常。
  ///
  /// deviceId 与 appVersion 仍留空：前者没有可靠的设备标识来源，
  /// 后者要等接入 package_info_plus。塞一个写死的版本号比不塞更糟 ——
  /// 它会让人误以为能按版本排查线上问题。
  AiIdentity _identityFromAuth() {
    final auth = Get.isRegistered<AuthController>()
        ? Get.find<AuthController>()
        : null;
    return AiIdentity.resolve(
      session: DatabaseService.cloud?.api.session,
      localUserId: auth?.currentUser.value?.id,
    );
  }

  /// 云端调用回落到本地时触发。
  ///
  /// 本地实现给出的是通用模板，看起来煞有介事 —— 所以「这次其实是离线结果」
  /// 必须是个能被读到的信号。横幅挂在首页而不是各个页面各自弹一次：
  /// 降级最容易发生在**后台自己跑起来的调用**上（进首页时的能力探测、
  /// 提交后的自动批改），那些调用不挂在任何一个页面的生命周期上。
  void _onAiDegraded(AiDegradation event) {
    debugPrint('[AI 降级] $event');
    aiStatus.report(event);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 连接池属于本页面创建的对象，页面走了就关掉。
    aiRuntime.dispose();
    if (Get.isRegistered<AiRuntime>()) Get.delete<AiRuntime>(force: true);
    // 提示位持有自动隐藏的 Timer，不随页面回收的话会留一个悬空定时器；
    // 退出登录再登录也会拿到上一轮残留的降级提示。
    if (Get.isRegistered<AiStatusController>()) {
      Get.delete<AiStatusController>(force: true);
    }
    // 同上：留着的话会跟着一个已销毁的页面继续订阅数据层事件。
    if (Get.isRegistered<DataStatusController>()) {
      Get.delete<DataStatusController>(force: true);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final selectedIndex = controller.currentTabIndex.value;
      return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('伴学学习'),
        actions: [
          Stack(
            alignment: Alignment.topRight,
            children: [
              IconButton(
                onPressed: () => Get.toNamed('/notifications'),
                icon: const Icon(Icons.notifications_none),
                tooltip: '消息通知',
              ),
              Obx(
                () => notificationController.unreadCount > 0
                    ? Positioned(
                        right: 8,
                        top: 8,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                            color: AppColors.danger,
                            shape: BoxShape.circle,
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
          IconButton(
            onPressed: () => Get.toNamed('/binding'),
            icon: const Icon(Icons.group_add_outlined),
            tooltip: '绑定管理',
          ),
          IconButton(
            onPressed: () => Get.toNamed('/profile'),
            icon: const Icon(Icons.person_outline),
            tooltip: '个人信息',
          ),
          IconButton(
            onPressed: () => Get.toNamed('/help'),
            icon: const Icon(Icons.help_outline),
            tooltip: '使用帮助',
          ),
          IconButton(
            onPressed: () => Get.toNamed('/chat'),
            icon: const Icon(Icons.chat_bubble_outline),
            tooltip: '伴学消息',
          ),
        ],
      ),
      body: Column(
        children: [
          // 横幅在 tab 之外：降级可能发生在任何一个 tab 的后台调用上，
          // 而它一旦发生，学生需要的是「换到哪个页面都能看见」。
          AiDegradedBanner(status: aiStatus),
          // 数据层那条同理，而且它比 AI 降级更该被看见 ——
          // 用户此刻的判断可能建立在一份旧数据上。
          OfflineDataBanner(status: dataStatus),
          Expanded(
            // 家长端同样有这一层（`parent_home_page.dart`）。
            //
            // 学生端此前**没有任何重拉入口**：`loadData()` 只在进首页那一刻跑一次，
            // 于是「家长已经同意兑现」这类**由另一台设备造成的变化**，
            // 学生不重启就永远看不到 —— 心愿页会一直停在「等待家长确认」。
            // 五个 tab 的根都是可滚动的 `ListView`，挂在外面一次管住全部。
            child: RefreshIndicator(
              onRefresh: controller.loadData,
              child: pages[selectedIndex],
            ),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: selectedIndex,
        onTap: (index) => controller.currentTabIndex.value = index,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: AppColors.primary,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.task_alt), label: '作业'),
          BottomNavigationBarItem(
            icon: Icon(Icons.directions_run),
            label: '运动',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.menu_book), label: '复习'),
          BottomNavigationBarItem(icon: Icon(Icons.fact_check), label: '计划'),
          BottomNavigationBarItem(
            icon: Icon(Icons.favorite_border),
            label: '心愿',
          ),
        ],
      ),
      );
    });
  }
}
