/// 作业附件的**类型、数量与大小上限的唯一定义处**。
///
/// ## 为什么单独一个文件
///
/// 这组数字（图片 9 / 音频 3 / 视频 1，8MB / 20MB / 100MB）同时活在四处：
/// 提交面板的计数与提示、存储层的 MIME 与大小校验、服务端的落盘校验、
/// 以及文档。散着写就一定会漂，而漂的那天**不报错** —— 只表现为
/// 「界面上能选 9 张，存第 7 张开始失败」。
///
/// ⚠️ 服务端有一份**同口径**的定义（`serverless/data-service/src/attachments.js`）。
/// Dart 与 JS 没法共享常量，所以两份必须逐字对齐 —— 这是本项目
/// `src/vocab.js` ↔ Dart 枚举那条规则（「一个语义只许一个词」）的又一次应用。
/// **改一份就要改另一份。**
///
/// ## 它顺手修掉了什么
///
/// 「文件名 → MIME」这条规则原来有**三份**：`remote_image_storage.dart` 的
/// `mimeTypeOfFileName`、`image_storage_service.dart` 的 `_mimeType`，
/// 以及这里的表。三份还不一样 —— `image_storage_service` 那份**认不出
/// `.heic`**：同一张 HEIC 照片，走服务端存储记成 `image/heic`、走本地存储
/// 记成 `image/jpeg`，两边都不报错。现在那两个函数都只是
/// [AttachmentLimits.imageMimeFallback] 的别名，规则只剩这一份。
library;

/// 附件类型。`wire` 是**落库与跨端传的值**，必须与服务端逐字相同。
enum AttachmentKind {
  image('image', '照片', '张'),
  audio('audio', '音频', '个'),
  video('video', '视频', '个');

  const AttachmentKind(this.wire, this.label, this.unit);

  /// 落库值。改它等于改协议 —— 服务端 `attachments.js` 的 `WIRE` 要同步。
  final String wire;

  /// 界面上给用户看的名字。
  final String label;

  /// 计数单位（「9 张」「1 个」）。
  final String unit;

  /// 从落库值还原。**不认识就返回 null**，不猜一个默认值 ——
  /// 猜错的表现是「一段音频被当成图片」，而它不会报错。
  static AttachmentKind? fromWire(Object? value) {
    final text = value?.toString() ?? '';
    for (final kind in values) {
      if (kind.wire == text) return kind;
    }
    return null;
  }

  /// 从 MIME 归类。不认识返回 null。
  ///
  /// ⚠️ **刻意不兜底成图片**：兜底会把一段音频按图片送进视觉模型，
  /// 而模型对不认识的内容是静默丢弃的（见 `doc/open-items.md` B29），
  /// 表现为「批改结果里这个附件凭空消失」。
  static AttachmentKind? ofMime(String mimeType) {
    final mime = mimeType.toLowerCase().trim();
    if (mime.isEmpty) return null;
    for (final kind in values) {
      if (mime.startsWith('${kind.wire}/')) return kind;
    }
    return null;
  }

  /// 从文件名后缀归类。不认识返回 null。
  static AttachmentKind? ofFileName(String fileName) {
    final mime = AttachmentLimits.mimeOfFileName(fileName);
    return mime == null ? null : ofMime(mime);
  }
}

/// 「用户选了一个我们不认识的文件」。
///
/// 刻意**不是** `ArgumentError` / `StateError`：那两个的语义是「程序写错了」，
/// 而这里错的是输入 —— 它必须一路带到界面上，用中文告诉学生换个文件。
/// 存储层与控制器共用这一个类型，就不会出现「同一件事两处各抛各的」。
///
/// 触发它的是：文件的 MIME 归不进 [AttachmentKind]（不是 image/audio/video）。
/// ⚠️ **绝不能改成兜底成图片** —— 兜底的表现是「批改结果里这个附件凭空消失」
/// （见 `doc/open-items.md` B29：模型对不认识的内容静默丢弃）。
class UnsupportedAttachmentException implements Exception {
  const UnsupportedAttachmentException(this.mimeType);

  /// 归不了类的那个 MIME。为空表示连 MIME 都没推出来。
  final String? mimeType;

  @override
  String toString() =>
      '不支持的附件类型：${mimeType ?? '（认不出这是什么文件）'}'
      '（只认图片、音频、视频）';
}

/// 数量与字节上限。**这些数字只在这里定义一次。**
abstract final class AttachmentLimits {
  /// 每个类型**一次提交**最多几个附件。
  ///
  /// 三类**各自独立计数**，不共享名额 —— 一个朗读录音不该挤掉一张作业照片。
  static const Map<AttachmentKind, int> maxCount = {
    AttachmentKind.image: 9,
    AttachmentKind.audio: 3,
    AttachmentKind.video: 1,
  };

  /// 每个类型的**单文件**字节上限。
  ///
  /// 视频给到 100MB（2026-10-06 由 50MB 放宽）是因为它有**另一条上传通道**：
  /// 超过函数请求体上限的文件
  /// 走对象存储预签名直传（见 `remote_image_storage.dart` 的 `_uploadLarge`）。
  /// 50MB 那版在 5 分钟直传超时下要求有效上行 ≥170KB/s，家用 Wi-Fi 晚间
  /// 拥挤时经常达不到 —— 实测（2026-10-05 晚）表现为「提交视频失败」，
  /// 字节根本没落库。放宽后必须**同轮**把直传超时提到 12 分钟，
  /// 否则 100MB 反而更容易超时（OSS 签名窗口 15 分钟，见
  /// `ossimagestore.js` 的 `OSS_V4_CLOCK_WINDOW_SECONDS`）。
  /// 用本地存储（Web 浏览器配额 / 未上云）时这个值达不到，那里会**如实失败**。
  static const Map<AttachmentKind, int> maxBytes = {
    AttachmentKind.image: 8 * 1024 * 1024,
    AttachmentKind.audio: 20 * 1024 * 1024,
    AttachmentKind.video: 100 * 1024 * 1024,
  };

  /// MIME → 落盘扩展名。
  ///
  /// ⚠️ 服务端 `attachments.js` 的 `MIME_EXT` 必须与这份**逐字相同**：
  /// 客户端按 MIME 上传、服务端按 MIME 查扩展名，两边白名单不一致时，
  /// 表现是「选得中、传得上去、存不下来」。
  static const Map<String, String> mimeExt = {
    // —— 图片 ——
    'image/jpeg': '.jpg',
    'image/jpg': '.jpg',
    'image/png': '.png',
    'image/webp': '.webp',
    'image/heic': '.heic',
    'image/heif': '.heic',
    // —— 音频 ——
    'audio/mpeg': '.mp3',
    'audio/mp4': '.m4a',
    'audio/aac': '.aac',
    'audio/wav': '.wav',
    'audio/x-wav': '.wav',
    'audio/ogg': '.ogg',
    'audio/webm': '.weba',
    'audio/amr': '.amr',
    // —— 视频 ——
    'video/mp4': '.mp4',
    'video/quicktime': '.mov',
    'video/webm': '.webm',
    'video/3gpp': '.3gp',
  };

  /// 只认图片的那份 —— 批改链路要用它把附件**过滤到图片**。
  ///
  /// 这个列表存在的理由：视觉模型只吃图片，而一段视频以「图片」的身份
  /// 送进去不会报错，只会被丢掉。过滤必须发生在**收集**这一步。
  static final List<String> imageMimeTypes = mimeExt.keys
      .where((m) => m.startsWith('image/'))
      .toList(growable: false);

  /// 扩展名 → MIME。从 [mimeExt] **反向推导**，不另维护一张表 ——
  /// 两张表一定会漂，而漂的表现是「选的时候认得出、存的时候不认」。
  ///
  /// 一对多（`image/jpeg` 与 `image/jpg` 都指向 `.jpg`）时取**先声明的那个**，
  /// 所以 `.jpg` 稳定映射到 `image/jpeg`，`.heic` 映射到 `image/heic`。
  static final Map<String, String> _extMime = () {
    final out = <String, String>{};
    mimeExt.forEach((mime, ext) => out.putIfAbsent(ext, () => mime));
    return out;
  }();

  static int maxCountOf(AttachmentKind kind) => maxCount[kind]!;

  static int maxBytesOf(AttachmentKind kind) => maxBytes[kind]!;

  /// 某一类附件允许的后缀（**不带点**），给系统文件选择器用。
  ///
  /// 从 [mimeExt] **反向推**，不另维护一张列表：两张表一定会漂，
  /// 而漂的表现是「选择器里选得中、传上去被服务端拒」—— 因为服务端的
  /// 白名单是另一份。这里少写一个后缀的后果只是「选不中」，比那温和，
  /// 但仍然不该让它有机会发生。
  static List<String> extensionsOf(AttachmentKind kind) {
    final prefix = '${kind.wire}/';
    final out = <String>{};
    mimeExt.forEach((mime, ext) {
      if (mime.startsWith(prefix)) out.add(ext.substring(1));
    });
    return out.toList(growable: false);
  }

  /// 由文件名推 MIME。认不出返回 **null**。
  ///
  /// ⚠️ 返回 null 而不是兜底成 `image/jpeg`：调用方要么知道自己拿的是图片
  /// （相机/相册选出来的，那时用 [imageMimeFallback] 显式兜底），
  /// 要么不知道 —— 不知道就不该编一个类型出来。
  static String? mimeOfFileName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return null;
    return _extMime[fileName.substring(dot).toLowerCase()];
  }

  /// 图片的兜底 MIME。相机与相册出来的绝大多数就是 JPEG，
  /// 而个别平台给的文件名不带后缀（`image_picker` 在 Web 上会给 blob 名）。
  /// 这个兜底**只对图片成立**，不要拿它给音视频兜底。
  static String imageMimeFallback(String fileName) =>
      mimeOfFileName(fileName) ?? 'image/jpeg';

  /// 把字节数说成人话，用于错误提示（`100MB`、`820KB`）。
  static String humanSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      final mb = bytes / (1024 * 1024);
      return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)}MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).round()}KB';
    return '${bytes}B';
  }
}
