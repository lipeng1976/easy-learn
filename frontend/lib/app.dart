import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'controllers/auth_controller.dart';
import 'controllers/notification_controller.dart';
import 'models/user_model.dart';
import 'pages/auth/login_page.dart';
import 'pages/auth/register_page.dart';
import 'pages/auth/sms_code_page.dart';
import 'pages/parent/ai_observe_page.dart';
import 'pages/parent/checkin_setup_page.dart';
import 'pages/parent/reading_setup_page.dart';
import 'pages/parent/subject_scope_page.dart';
import 'pages/parent/word_scope_page.dart';
import 'pages/parent/parent_home_page.dart';
import 'pages/shared/binding_page.dart';
import 'pages/shared/chat_page.dart';
import 'pages/shared/notifications_page.dart';
import 'pages/shared/profile_page.dart';
import 'pages/shared/help_page.dart';
import 'pages/shared/ima_settings_page.dart';
import 'pages/shared/reading_logs_page.dart';
import 'pages/shared/word_daily_logs_page.dart';
import 'pages/student/checkin_page.dart';
import 'pages/student/checkin_subject_page.dart';
import 'pages/student/reading_page.dart';
import 'pages/student/daily_drill_page.dart';
import 'pages/student/word_drill_page.dart';
import 'pages/student/student_home_page.dart';
import 'services/database_service.dart';
import 'services/sms_gateway.dart';
import 'utils/auth_guard.dart';

class EasyLearnApp extends StatelessWidget {
  const EasyLearnApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 只注册一次。
    //
    // `Get.put` 会**替换**已存在的实例，而这里是 `build()`：一旦本组件重建，
    // 换上的新 AuthController 就是一份 `currentUser == null` 的空实例 ——
    // 用户还停在首页，登录态却没了。以前只是「有些地方读到空用户」，
    // 现在 [AuthGuard] 也依赖它，那会直接把已登录的人弹回登录页。
    //
    // ⚠️ 2026-10-06（B37）：`AuthController` 现在**由 `main.dart` 建**
    //    —— 它要在 `runApp` 之前 await `hydrate()` 把「记住的密码」读出来，
    //    而这里是同步的 `build()`，没有 await 的位置。下面的分支因此
    //    **正常情况下不会执行**，保留它是为了兜住「有人绕过 main 直接
    //    runApp（测试、未来的新入口）」这种情况：至少不会崩。
    final restored = _restoredUser();
    if (!Get.isRegistered<AuthController>()) {
      Get.put(AuthController(initialUser: restored));
    }
    if (!Get.isRegistered<NotificationController>()) {
      Get.put(NotificationController());
    }

    return GetMaterialApp(
      title: '伴学APP',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F7FF),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4D7CFE),
          brightness: Brightness.light,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black87,
          elevation: 0,
        ),
      ),
      home: _firstScreen(restored),
      // 受保护页面统一挂 [AuthGuard]。
      //
      // 别的做法是在每个页面内部自查登录态，但那只能拦住「界面」，
      // 拦不住职责：页面已经在构建了，AI 运行时已经带着空身份装出来了。
      // 守卫在**路由层**拦，页面根本不会被创建。
      //
      // `/login` 与 `/register` 当然不挂 —— 它们正是没登录时要能进的地方。
      getPages: [
        GetPage(name: '/login', page: () => const LoginPage()),
        GetPage(name: '/register', page: () => const RegisterPage()),
        // 短信验证码的两条路径：登录 与 找回密码。
        //
        // **不挂 AuthGuard**（和 /login、/register 同级），有两个原因：
        // 1. 它们本来就是「进不去的时候要去的地方」，挂上守卫会变成
        //    没登录 → 跳登录页 → 点忘记密码 → 被弹回登录页 的死循环；
        // 2. 个人信息页里「修改密码」也要能进到同一个页面 ——
        //    那是已登录状态，两条路必须都能走。
        //
        // 页面本身不校验身份：它只负责拿验证码，凭证由服务端签发。
        GetPage(
          name: '/sms-login',
          page: () => const SmsCodePage(purpose: SmsPurpose.login),
        ),
        GetPage(
          name: '/forgot-password',
          page: () => const SmsCodePage(purpose: SmsPurpose.resetPassword),
        ),
        GetPage(
          name: '/student-home',
          page: () => const StudentHomePage(),
          middlewares: [AuthGuard()],
        ),
        GetPage(
          name: '/parent-home',
          page: () => const ParentHomePage(),
          middlewares: [AuthGuard()],
        ),
        GetPage(
          name: '/notifications',
          page: () => const NotificationsPage(),
          middlewares: [AuthGuard()],
        ),
        // 每日概念训练（学生端）。数据只在本机（drill_answer 表），
        // 但页面仍走 AuthGuard：未登录时没有 studentId，选题与记录都无处落。
        GetPage(
          name: '/daily-drill',
          page: () => const DailyDrillPage(),
          middlewares: [AuthGuard()],
        ),
        GetPage(
          name: '/binding',
          page: () => const BindingPage(),
          middlewares: [AuthGuard()],
        ),
        GetPage(
          name: '/chat',
          page: () => const ChatPage(),
          middlewares: [AuthGuard()],
        ),
        GetPage(
          name: '/profile',
          page: () => const ProfilePage(),
          middlewares: [AuthGuard()],
        ),
        GetPage(
          name: '/ima-settings',
          page: () => const ImaSettingsPage(),
          middlewares: [AuthGuard()],
        ),
        // 每日概念打卡：家长发起 / 学生作答同页（三种状态在屏内切换）。
        GetPage(
          name: '/checkin',
          page: () => const CheckinPage(),
          middlewares: [AuthGuard()],
        ),
        // 某一科的已完成打卡记录（学生端「已完成」色块点进来）。
        // `arguments` 是科目名 —— 页面自己不猜「这一科是谁的」。
        GetPage(
          name: '/checkin-subject',
          page: () => CheckinSubjectPage(subject: Get.arguments as String? ?? '其他'),
          middlewares: [AuthGuard()],
        ),
        // 家长发起前选范围（学科 / 知识点 / 题量 / 难度）。
        // `arguments` 是这份打卡挂在谁名下（孩子 id）—— 配置页自己不查，
        // 同一个值只有调用方知道。
        GetPage(
          name: '/checkin-setup',
          page: () => CheckinSetupPage(studentId: Get.arguments as String?),
          middlewares: [AuthGuard()],
        ),
        // 英文阅读：学生读一篇 + 打卡。`arguments` 是任务 id（可空 ——
        // 空时页面自己取第一份进行中的任务，从通知点进来的场景）。
        GetPage(
          name: '/reading',
          page: () => const ReadingPage(),
          middlewares: [AuthGuard()],
        ),
        // 家长的导入 / 布置页。只有家长会走到这里，学生端点不到
        // （入口卡在学生端不渲染这个按钮）。
        GetPage(
          name: '/reading-setup',
          page: () => const ReadingSetupPage(),
          middlewares: [AuthGuard()],
        ),
        // 阅读打卡记录。两端共用：学生看自己，家长看孩子 ——
        // 「挂在谁名下」由 `ReadingController.targetStudentId()` 决定，
        // 页面不自己传 id。
        GetPage(
          name: '/reading-logs',
          page: () => const ReadingLogsPage(),
          middlewares: [AuthGuard()],
        ),
        // 英语单词打卡：学生答题 / 家长配范围与看记录。题目在客户端本地生成，
        // 服务端只有词表、范围与成绩摘要，所以断网也能进答题页。
        GetPage(
          name: '/word-drill',
          page: () => const WordDrillPage(),
          middlewares: [AuthGuard()],
        ),
        GetPage(
          name: '/word-scope',
          page: () => const WordScopePage(),
          middlewares: [AuthGuard()],
        ),
        // 学科范围（十科都能进）。参数是科目名。英语有两本资料：
        // 词表在 `/word-scope`，教材 / 语法范围在这页。`subject_scope` 按科一行，
        // 英语那行就是教材题的范围，与词表互不覆盖。
        GetPage(
          name: '/subject-scope',
          page: () => SubjectScopePage(subject: Get.arguments as String?),
          middlewares: [AuthGuard()],
        ),
        GetPage(
          name: '/word-daily-logs',
          page: () => const WordDailyLogsPage(),
          middlewares: [AuthGuard()],
        ),
        GetPage(
          name: '/help',
          page: () => const HelpPage(),
          middlewares: [AuthGuard()],
        ),
        // 运行观察：用量成本 / 判定一致率 / 降级记录。家长端的运维视角。
        GetPage(
          name: '/ai-observe',
          page: () => const AiObservePage(),
          middlewares: [AuthGuard()],
        ),
      ],
    );
  }

  /// **首屏**：有恢复回来的会话就直接进首页，否则登录页。
  ///
  /// ## 为什么必须在这里定，而不是进登录页之后再跳
  ///
  /// `home:` 是**首帧**就渲染出来的东西。把这件事交给登录页的 `initState`
  /// 去做（「发现已登录就 `offAllNamed` 走人」），用户会先看到登录页闪一下 ——
  /// 而 `main.dart` 特意把读会话放在 `runApp` **之前**，就是为了避免这一下。
  /// 更糟的是它给了登录页一个它不该有的职责：登录页负责「让你登进来」，
  /// 不负责「你其实已经在里面了」。
  ///
  /// 缺了这一句的症状是**静默的**：会话恢复得好好的（token 都在），
  /// 端口也对，就是每次冷启动都停在登录页 —— 用户以为「又要重新登」，
  /// 而实际上他要做的是再点一次登录（于是又多了一个会话）。
  ///
  /// 角色到首页的对应关系不在这里另写一遍，读 [AuthController.homeRouteFor]：
  /// 它和登录成功之后那一次跳转必须是同一个答案。
  static Widget _firstScreen(UserModel? restored) {
    if (restored == null) return const LoginPage();
    return AuthController.homeRouteFor(restored.role) == '/student-home'
        ? const StudentHomePage()
        : const ParentHomePage();
  }

  /// 冷启动时从落盘的会话里取回当前用户。纯本地模式下永远是 null。
  ///
  /// 放在这里而不是 `main()` 里读：`main()` 读到的只是一份数据，
  /// 而「用它决定首页是哪个」是**渲染**这一步的事。分开的话，
  /// 「谁负责初始路由」会有两个答案。
  ///
  /// 读 `DatabaseService.cloud` 而不是另存一份全局：数据走哪条路与登录
  /// 走哪条路必须由同一个事实决定 —— 见 `DatabaseService.cloud`。
  static UserModel? _restoredUser() {
    final session = DatabaseService.cloud?.api.session;
    final user = session?.user;
    if (session == null || user == null || !session.isAuthenticated) return null;
    return UserModel.fromJson(user);
  }
}
