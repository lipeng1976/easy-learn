import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../controllers/auth_controller.dart';

/// 需要登录才能进的页面。
///
/// 为什么必须有这一层：`app.dart` 里原先是一排裸 `GetPage`，
/// 任何人都能直接落到 `/student-home`。这在 Flutter Web 上不是理论风险 ——
/// 浏览器地址栏里留着 `#/student-home`，一次刷新（或从收藏夹打开）
/// 就会在没有登录态的情况下把学生首页建起来。
///
/// 后果不只是「看到了不该看的界面」，而是**身份为空**：
/// 学生首页会据此装配 AI 运行时，一个空身份发出去的请求会被网关按
/// 「无身份」拒收，然后降级成本地模拟 —— 用户看到的是「照片认不出内容」，
/// 怎么重拍都没用（2026-09-15 那次线上现象）。
///
/// 所以这里的重定向同时守住了两件事：页面可见性，以及身份的有效性。
class AuthGuard extends GetMiddleware {
  AuthGuard();

  @override
  RouteSettings? redirect(String? route) {
    final auth = Get.isRegistered<AuthController>()
        ? Get.find<AuthController>()
        : null;
    if (auth?.currentUser.value == null) {
      // 回到登录页，而不是弹一句提示留在原地：
      // 留在原地的话页面已经在构建了，AI 运行时照样会带着空身份装出来。
      return const RouteSettings(name: '/login');
    }
    return null;
  }
}
