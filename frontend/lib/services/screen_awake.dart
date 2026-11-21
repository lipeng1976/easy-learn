import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 让屏幕在计时页开着时不自动熄灭。
///
/// ## 为什么必须有它
///
/// 计时页是「把手机立在桌上，看着秒数做作业」的场景。系统默认 30 秒~1 分钟
/// 熄屏，然后锁屏 —— 而锁屏会触发「离开应用自动暂停」（见 `focus_timer_page`），
/// 学生看到的是「我什么都没干，计时自己停了」。这不是省电，是**功能坏了**。
///
/// ## 为什么不用 wakelock 插件
///
/// 需要的只是 Android 的 `FLAG_KEEP_SCREEN_ON`：一个窗口标志、零权限、
/// 页面退出就随窗口消失。引一个插件换同样的效果，等于多一份原生依赖和一次
/// 打包风险 —— 与 TTS 那边「用系统能力、不引插件」是同一条取舍。
///
/// ## 失败一律静默
///
/// 屏幕亮不亮不影响计时本身（时间照走、照存）。这里失败只意味着「会熄屏」，
/// 弹一个提示反而把学生的注意力从计时上拉走。**但也不假装成功** ——
/// 上层没办法据此做任何决策，所以这里不需要返回值。
class ScreenAwake {
  ScreenAwake._();

  static const MethodChannel _channel = MethodChannel(
    'cn.easylearn.app/screen',
  );

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> keepOn(bool on) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('setKeepScreenOn', {'on': on});
    } on MissingPluginException {
      // 老包里没有这个原生方法（热更新/旧 APK），退化为「会熄屏」。
    } on PlatformException {
      // 权限、窗口状态异常等：同上，不影响计时。
    }
  }
}
