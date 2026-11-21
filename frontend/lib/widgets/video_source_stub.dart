import 'dart:typed_data';

import 'package:video_player/video_player.dart';

/// Web 上没有本地文件系统。
///
/// 视频那条路**只能**落盘（`video_player` 没有内存源），所以网页版
/// **播不了内联视频**；音频那条路还有 `StreamAudioSource` 兜底
/// （`just_audio` 会自己把内容编成 data URL），所以网页版音频照常能播。
/// 两者对「没有文件系统」的处置不同，但都从这一个函数开始分流。
Future<String?> writeTempAttachment(Uint8List bytes, String fileName) async =>
    null;

/// ## 为什么是抛错，而不是回一个假 URI
///
/// 假 URI 会让播放器转一会儿圈然后什么都不显示。那个现象与「文件坏了」
/// 「网络断了」逐字一样，谁也查不出真因 —— 而它其实是一句确定的
/// 「这个平台做不到」。抛出去，界面才能如实说「请在手机 App 里打开」。
///
/// ## 这是产品限制，不是缺陷
///
/// 浏览器的 Blob URL 与 `video_player` 的 Web 实现之间没有可靠的桥 ——
/// 那件事该由一个专门的、能被真机验证的改动来做，而不是在这里猜一个
/// 能编过的写法。
Future<VideoPlayerController> videoControllerFromBytes(
  Uint8List bytes,
  String fileName,
) async {
  throw UnsupportedError('web_has_no_local_file');
}
