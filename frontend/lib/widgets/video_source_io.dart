import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

/// 把内存里的附件字节写成一份**临时副本**，返回它的绝对路径。
///
/// Web 上没有本地文件系统 ⇒ `video_source_stub.dart` 里返回 `null`
/// （调用方据此走另一条路，不是「失败」）。
///
/// 音频与视频共用它：两者的播放器都没有内存源，也都不该经
/// `just_audio` 的本地明文代理（见 `attachment_player.dart` 里
/// `useProxyForRequestHeaders` 那段说明）。
///
/// ## 为什么落在**临时**目录
///
/// 它只是给播放器读的副本，用完就该消失。落到文稿目录会让作业目录里
/// 堆起一份既不是学生提交的内容、也不会被任何清理逻辑回收的
/// 「播放缓存」—— 那类文件只会以「手机空间莫名少了」的形式被人发现。
///
/// ## 文件名带时间戳
///
/// 同一个附件会被反复播放，而每次播放都会写一个文件。名字里不带戳的话，
/// 第二次写入会撞上正在被播放器读的那个文件 —— 在 Windows 上那是
/// 一次「拒绝访问」，表现为「第一次能播，第二次打不开」。
Future<String?> writeTempAttachment(Uint8List bytes, String fileName) async {
  final directory = await getTemporaryDirectory();
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final file = File(
    path.join(directory.path, 'easy_learn_media', '${stamp}_$fileName'),
  );
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

/// 用内存里的视频字节造一个**已初始化**的播放控制器。
///
/// ⚠️ 这是**退路**，不是主路。主路是直读：服务端签一个对象存储的位置，
/// URL 直接交给 `VideoPlayerController.networkUrl`（见 `attachment_player.dart`
/// 的 `_VideoBody`）。走这条路只在两种情况：`IMAGE_DRIVER=fs` 的部署
/// （没有可直读的 HTTP 端点），或者客户端没签下来。
///
/// ## 为什么非得落一次盘
///
/// `video_player` 没有内存源：构造只有 `.file` / `.networkUrl` / `.asset`
/// 三条，没有一条吃 `Uint8List`。而作业附件先从服务端取回来就是字节
/// （`HomeworkImageReader.load`），所以中间必须有一次落盘。
Future<VideoPlayerController> videoControllerFromBytes(
  Uint8List bytes,
  String fileName,
) async {
  final target = await writeTempAttachment(bytes, fileName);
  // 这条路只能在非 Web 平台被调用（Web 是 `video_source_stub.dart`），
  // 所以上面那个 `null` 分支在这里不可达。
  final controller = VideoPlayerController.file(File(target!));
  await controller.initialize();
  return controller;
}
