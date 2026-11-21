import 'dart:typed_data';

import '../constants/attachment_limits.dart';

/// 学生选好但尚未入库的**一个附件**（照片 / 音频 / 视频）。
///
/// 刻意不直接传 `image_picker` 的 `XFile`：
/// - `XFile` 依赖平台通道，无法在纯 Dart 单元测试里构造；
/// - 控制器只关心「文件名 + 字节」，不该知道附件是从相机还是相册来的。
///
/// ## 类型从哪来
///
/// [kind] 与 [mimeType] 默认**由文件名推出来**（[AttachmentLimits] 是唯一
/// 定义处）。这是调用方本来就有的信息，不需要再造一个字段跟着字节一起传。
/// 选择器若已经知道确切 MIME（`file_picker` 会给），用 [mimeTypeOverride]
/// 显式传进来 —— 文件名推不出来的情况（没有后缀的录音）就靠它兜。
///
/// ⚠️ 推不出来时两者都是 **null**，**不兜底成图片**：兜底会把一段音频按
/// 图片送进视觉模型，而模型对不认识的输入是**静默丢弃**的
/// （见 `doc/open-items.md` B29），表现为「批改结果里这个附件凭空消失」。
///
/// 命名欠债：[HomeworkPhotoDraft] 这个名字来自只有照片的时候，现在它承载
/// 三种类型。改名要动 4 个 `lib/` 文件与 5 个测试，留到能跑
/// `flutter analyze` 时一起做（2026-10-03 记，那时这台机器的 dart 无法
/// spawn 子进程 —— 见 `doc/open-items.md` 的 231 条目）。
class HomeworkPhotoDraft {
  const HomeworkPhotoDraft({
    required this.fileName,
    required this.bytes,
    this.mimeTypeOverride,
  });

  final String fileName;
  final Uint8List bytes;

  /// 一张**确定是图片**的草稿。
  ///
  /// 相机与相册出来的就是 JPEG；而 Web 上 `image_picker` 给的文件名是
  /// blob 名（没有后缀），按文件名推 MIME 会得到 null —— 而 null 会被
  /// 提交链路当成「认不出的文件」挡掉，症状是「明明选了照片，却说认不出」。
  /// 所以图片这条路**在构造时就把 MIME 定下来**，不留给下游猜。
  factory HomeworkPhotoDraft.photo({
    required String fileName,
    required Uint8List bytes,
  }) => HomeworkPhotoDraft(
    fileName: fileName,
    bytes: bytes,
    mimeTypeOverride: AttachmentLimits.imageMimeFallback(fileName),
  );

  /// 选择器已经知道的确切 MIME。为空时由 [fileName] 推断。
  final String? mimeTypeOverride;

  bool get isEmpty => bytes.isEmpty;

  /// 这个附件的 MIME。推不出来就是 **null**，不是一个猜出来的值。
  String? get mimeType =>
      mimeTypeOverride ?? AttachmentLimits.mimeOfFileName(fileName);

  /// 这个附件属于哪一类（决定它算进哪个配额、会不会进批改）。
  /// 推不出来就是 null。
  AttachmentKind? get kind {
    final mime = mimeType;
    return mime == null ? null : AttachmentKind.ofMime(mime);
  }
}
