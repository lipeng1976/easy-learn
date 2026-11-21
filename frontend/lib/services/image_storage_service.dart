import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../constants/attachment_limits.dart';
import '../models/homework_image_model.dart';
import 'database_service.dart';
import 'image_file_writer_stub.dart'
    if (dart.library.io) 'image_file_writer_io.dart';
import 'remote_image_storage.dart';
import 'web_storage.dart';

/// 按**当前运行形态**造一个照片存储。
///
/// ## 为什么要有这个函数，而不是在各处 `LocalImageStorageService()`
///
/// 代码里原先有六处直接 `new LocalImageStorageService()`。上云之后，
/// 那些位置里的每一处都会**默默地把照片继续写在本机** —— 而它的症状
/// 与「照片本来就没上传」一模一样：家长端看不到、不报任何错。
///
/// 一个「记得改」的约定挡不住第六处，所以把选择收成这一个函数：
/// 调用方只说「我要一个存照片的地方」，存哪由这里决定。
///
/// ## 云端模式下为什么不顺手也写一份本地副本
///
/// 本地那份在这条路上**没有任何读取方**（读走服务端），留着只会占满
/// Web 端那 5MB 的浏览器配额 —— 而配额满了的表现是
/// 「照片这次能看、刷新后就没了」，比直接失败更难查。
ImageStorageService createImageStorage() {
  final cloud = DatabaseService.cloud;
  if (cloud == null) return LocalImageStorageService();
  return RemoteImageStorageService(cloud.api);
}

/// 附件的落盘接口。
///
/// 名字里的 "Image" 是**历史欠债**：它从只有照片的时候就有，现在承载
/// 照片 / 音频 / 视频三种 —— 库里本来就只有一张 `homework_image` 表，
/// 服务端按 `mime_type` 归类（见 `routes/homework.js` 的 `assertAttachmentCounts`）。
/// 改名要动全仓调用点与测试，收益只是好看，所以不做；但**语义已经变了**：
/// 判定类别的唯一依据是 [mimeType]。
abstract class ImageStorageService {
  /// 存一个附件，返回**待落库的那一行**。
  ///
  /// [mimeType] 为空表示「调用方不知道它是什么」—— 那时按照片处理
  /// （相机与相册出来的本来就是 JPEG）。**非空却归不了类**时实现必须
  /// **抛错**，不许当照片存下去：那会让一段音频以图片身份流进批改，
  /// 被视觉模型静默丢弃（`doc/open-items.md` B29 那个形状）。
  Future<HomeworkImageModel> saveHomeworkImage({
    required String studentId,
    required String fileName,
    required Uint8List bytes,
    String? homeworkId,
    String? mimeType,
    String ocrStatus = 'pending',
    String ocrText = '',
    String batchId = '',
    int sortOrder = 0,
  });

  Uint8List? readImage(String storageKey);

  void deleteImage(String storageKey);
}

class LocalImageStorageService implements ImageStorageService {
  LocalImageStorageService({bool? useMemory})
    : _useMemory = useMemory ?? kIsWeb;

  final bool _useMemory;
  static final Map<String, Uint8List> _webMemoryStore = {};
  static const String _webImagePrefix = 'easy_learn_web_img_';

  /// 单张图片在 Web 端的落盘上限。浏览器 localStorage 通常只有 5MB，
  /// 超出后写入会静默失败（表现为家长端「图片不可用」）。
  /// 这里直接拒绝超大图并给出可执行的提示，而不是假装存成功。
  static const int maxWebImageBytes = 900 * 1024;

  static bool _lastWebPersistFailed = false;

  /// 最近一次 Web 端图片写入是否失败。页面据此提示用户
  /// 「照片本次可看，刷新后会丢失」，而不是让用户事后发现图片不见了。
  static bool get lastWebPersistFailed => _lastWebPersistFailed;

  static void resetWebPersistFlag() => _lastWebPersistFailed = false;

  @override
  Future<HomeworkImageModel> saveHomeworkImage({
    required String studentId,
    required String fileName,
    required Uint8List bytes,
    String? homeworkId,
    String? mimeType,
    String ocrStatus = 'pending',
    String ocrText = '',
    String batchId = '',
    int sortOrder = 0,
  }) async {
    final now = DateTime.now();
    // 同一毫秒内连拍多张会撞 ID，追加序号保证唯一。
    final id = 'img_${now.microsecondsSinceEpoch}_$sortOrder';

    // 类型以**调用方给的 MIME** 为准，文件名只当退路。
    //
    // 为什么不能只推文件名：录音的文件名常常没有后缀（`file_picker` 在部分
    // 平台给的就是个名字），只按 `fileName` 推会退化成 `.jpg` —— 于是
    // 一段音频被存成 `.jpg`、记成 `image/jpeg`，此后谁也判不出它是什么。
    final resolvedMime =
        mimeType ?? AttachmentLimits.imageMimeFallback(fileName);
    if (AttachmentKind.ofMime(resolvedMime) == null) {
      throw UnsupportedAttachmentException(resolvedMime);
    }

    final extension = path.extension(fileName).isEmpty
        ? (AttachmentLimits.mimeExt[resolvedMime] ?? '.jpg')
        : path.extension(fileName);
    final safeName = '$id$extension';

    late final String storageKey;
    if (_useMemory) {
      storageKey = 'memory://students/$studentId/homework/$safeName';
      _webMemoryStore[storageKey] = bytes;
      _persistWebImage(storageKey, bytes);
    } else {
      storageKey = await writeImageFile(studentId, safeName, bytes);
    }

    return HomeworkImageModel(
      id: id,
      studentId: studentId,
      homeworkId: homeworkId,
      storageKey: storageKey,
      fileName: fileName,
      fileSize: bytes.length,
      // ⚠️ 用上面那份 [resolvedMime]，**不再从落盘文件名反推**。
      //
      // 本文件曾经有一份只看 `.png`/`.webp` 的 `_mimeType`，它认不出
      // `.heic` —— 同一张 HEIC 走本地记 `image/jpeg`、走服务端记
      // `image/heic`，两边都不报错。现在只认 `AttachmentLimits` 那一处。
      //
      // 也不能再拿 `imageMimeFallback` 兜底：那是**图片专用**的兜底
      // （相机出来的就是 JPEG），对一段 `.m4a` 会编出一个 `image/jpeg`，
      // 而那正是 B29 里「附件以图片身份进批改、被静默丢弃」的起点。
      mimeType: resolvedMime,
      ocrStatus: ocrStatus,
      ocrText: ocrText,
      createdAt: now,
      batchId: batchId,
      sortOrder: sortOrder,
    );
  }

  @override
  Uint8List? readImage(String storageKey) {
    if (_useMemory) {
      final cached = _webMemoryStore[storageKey];
      if (cached != null) return cached;
      return _loadWebImage(storageKey);
    }
    return readImageFile(storageKey);
  }

  @override
  void deleteImage(String storageKey) {
    if (_useMemory) {
      _webMemoryStore.remove(storageKey);
      try {
        webStorage.remove(_webImagePrefix + storageKey);
      } catch (_) {}
      return;
    }
    deleteImageFile(storageKey);
  }

  void _persistWebImage(String storageKey, Uint8List bytes) {
    if (bytes.length > maxWebImageBytes) {
      _lastWebPersistFailed = true;
      debugPrint(
        '[ImageStorage] 图片 ${bytes.length} 字节超过 Web 端上限 $maxWebImageBytes，'
        '刷新后会丢失。请降低拍照分辨率或改用桌面端。',
      );
      return;
    }
    try {
      final ok = webStorage.write(
        _webImagePrefix + storageKey,
        base64Encode(bytes),
      );
      _lastWebPersistFailed = !ok;
      if (!ok) {
        debugPrint('[ImageStorage] Web 存储写入失败（可能超出浏览器配额）');
      }
    } catch (e) {
      _lastWebPersistFailed = true;
      debugPrint('[ImageStorage] Web 存储写入异常：$e');
    }
  }

  Uint8List? _loadWebImage(String storageKey) {
    try {
      final raw = webStorage.read(_webImagePrefix + storageKey);
      if (raw == null || raw.isEmpty) return null;
      final bytes = base64Decode(raw);
      _webMemoryStore[storageKey] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }
}
