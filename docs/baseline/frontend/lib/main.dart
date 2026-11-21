import 'package:flutter/material.dart';

import 'app.dart';

/// 装配必须在 runApp **之前**完成。
///
/// 原工程在这里还要：读落盘凭证、恢复云端会话、装配控制器。
/// 那些都是异步的，放到 runApp 之后会让首屏先闪一下登录页，或出现
/// 「密码框偶尔是空的」这类时好时坏的问题。业务代码迁入时保持这个顺序。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EasyLearnApp());
}
