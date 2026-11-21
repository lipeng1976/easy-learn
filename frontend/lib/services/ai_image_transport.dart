import 'dart:convert';
import 'dart:typed_data';

import '../constants/attachment_limits.dart';
import 'ai_api_client.dart';
import 'ai_config.dart';
import 'image_storage_service.dart';

/// 一张已经能被子端取到的作业照片。
///
/// 两种模式共用这一个形状，好让上层不必区分：
/// - 内联模式填 [base64]
/// - 对象存储模式填 [url]
class CloudHomeworkImage {
  const CloudHomeworkImage({
    required this.storageKey,
    required this.mimeType,
    required this.byteSize,
    this.base64 = '',
    this.url = '',
  });

  /// 客户端本地的存储键（[ImageStorageService] 的 storageKey）。
  /// 保留它只是为了排查问题时能把云端的图和本地的图对上。
  final String storageKey;

  final String mimeType;
  final int byteSize;

  /// 内联模式：图片字节的 base64（不含 data URI 前缀）。
  final String base64;

  /// 对象存储模式：对象存储上可访问的 URL。
  final String url;

  bool get isInline => base64.isNotEmpty;
  bool get isUrl => url.isNotEmpty;
  bool get isEmpty => base64.isEmpty && url.isEmpty;

  /// 网关契约里的图片载荷。
  ///
  /// 不组装 `data:` 前缀 —— 那是「转成方舟的多模态输入」这一步的细节，
  /// 属于服务端职责。客户端只交事实（什么格式、字节是什么），
  /// 以后要换成 `file_id` 或别的形态，服务端改一处即可。
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'storageKey': storageKey,
      'mimeType': mimeType,
      'byteSize': byteSize,
    };
    if (isInline) json['base64'] = base64;
    if (isUrl) json['url'] = url;
    return json;
  }
}

/// 一批照片的准备结果。
///
/// 之所以要 [skipped] 而不是只返回成功的列表：**丢图必须能被说出来**。
/// 一次批改少看了一张照片，结论就是错的，而「少了一张」这件事
/// 如果只体现在列表长度上，界面上永远看不出来。
class PreparedHomeworkImages {
  const PreparedHomeworkImages({
    this.images = const [],
    this.skipped = 0,
    this.note = '',
  });

  final List<CloudHomeworkImage> images;

  /// 因读取失败或超出体积/张数预算而被丢弃的张数。
  final int skipped;

  /// 丢弃原因，给日志与降级说明用。
  final String note;

  bool get isEmpty => images.isEmpty;

  int get totalBytes => images.fold(0, (sum, image) => sum + image.byteSize);

  @override
  String toString() =>
      'PreparedImages(${images.length} 张${skipped == 0 ? '' : ', 丢弃 $skipped 张'})'
      '${note.isEmpty ? '' : ' · $note'}';
}

/// 把作业照片搬到「云端函数取得到」的地方。
///
/// **这个端口的存在本身就是那个卡点的答案。**
/// 在此之前 `AiDataSource.checkHomework` 收到的是本地 storageKey：
/// 桌面/移动端是文件路径，Web 端是 `memory://...`。这些值进了 Serverless
/// 函数一律读不到 —— 而且本地实现完全忽略图片，所以从测试到运行都不会报错，
/// 只会在接入云端的那一天表现为「批改结果永远不看图」。
///
/// 因此把「读字节」这件事收到客户端来做：只有客户端手里有
/// [ImageStorageService]，能同时覆盖文件系统与浏览器 localStorage 两种存储。
abstract class HomeworkImageUploader {
  /// 单次最多送几张。
  int get maxImages;

  /// 单次照片总体积上限（base64 之前的原始字节）。
  int get maxTotalBytes;

  /// 是否需要在发送批改请求之前先做一次额外的网络往返。
  bool get requiresUpload;

  /// 从不抛异常：单张失败只计入 [PreparedHomeworkImages.skipped]。
  ///
  /// 理由是一次批改不该被一张读不出来的照片整个毁掉 ——
  /// 上下文里少一张图，模型还能给出部分结论；整条请求失败，就只剩降级了。
  Future<PreparedHomeworkImages> prepare(List<String> storageKeys);
}

/// 内联模式：读字节 → base64 → 塞进请求体。
///
/// 默认实现。不需要对象存储、不需要签名、照片不产生公网 URL。
class InlineHomeworkImageUploader implements HomeworkImageUploader {
  const InlineHomeworkImageUploader({
    required this.storage,
    this.config = const AiConfig(),
  });

  final ImageStorageService storage;
  final AiConfig config;

  @override
  int get maxImages => config.inlineImageMaxCount;

  @override
  int get maxTotalBytes => config.inlineImageMaxBytes;

  @override
  bool get requiresUpload => false;

  @override
  Future<PreparedHomeworkImages> prepare(List<String> storageKeys) async {
    final images = <CloudHomeworkImage>[];
    var skipped = 0;
    var totalBytes = 0;
    var budgetExhausted = false;
    var unreadable = 0;

    for (final key in storageKeys) {
      if (images.length >= maxImages) {
        skipped++;
        budgetExhausted = true;
        continue;
      }

      final bytes = storage.readImage(key);
      if (bytes == null || bytes.isEmpty) {
        skipped++;
        unreadable++;
        continue;
      }

      if (totalBytes + bytes.length > maxTotalBytes) {
        skipped++;
        budgetExhausted = true;
        continue;
      }

      totalBytes += bytes.length;
      images.add(
        CloudHomeworkImage(
          storageKey: key,
          mimeType: mimeTypeOf(key),
          byteSize: bytes.length,
          base64: base64Encode(bytes),
        ),
      );
    }

    final reasons = <String>[];
    if (unreadable > 0) reasons.add('$unreadable 张读取失败');
    if (budgetExhausted) {
      reasons.add(
        '超出内联预算（≤ $maxImages 张、≤ ${_mb(maxTotalBytes)}MB），'
        '超出的已丢弃',
      );
    }

    return PreparedHomeworkImages(
      images: images,
      skipped: skipped,
      note: reasons.join('；'),
    );
  }
}

/// 对象存储模式：取预签名 URL → 客户端直传 → 回填 URL。
///
/// 直传而不是经网关中转，是因为 Serverless 函数转发大文件既慢又贵，
/// 而且会先撞上请求体上限。网关只负责**签名**这一件小事。
class ObjectStorageHomeworkImageUploader implements HomeworkImageUploader {
  // 不是 const：默认值要从注入的 client 上取（client.config），这不是常量表达式。
  ObjectStorageHomeworkImageUploader({
    required this.storage,
    required this.client,
    AiConfig? config,
  }) : _config = config ?? client.config;

  final ImageStorageService storage;
  final AiApiClient client;
  final AiConfig _config;

  AiConfig get config => _config;

  @override
  int get maxImages => config.inlineImageMaxCount;

  @override
  int get maxTotalBytes => config.inlineImageMaxBytes;

  @override
  bool get requiresUpload => true;

  @override
  Future<PreparedHomeworkImages> prepare(List<String> storageKeys) async {
    if (storageKeys.isEmpty) return const PreparedHomeworkImages();

    // 先读字节：读不出来的照片不必浪费一次签名。
    final readable = <String, Uint8List>{};
    var unreadable = 0;
    for (final key in storageKeys.take(maxImages)) {
      final bytes = storage.readImage(key);
      if (bytes == null || bytes.isEmpty) {
        unreadable++;
        continue;
      }
      readable[key] = bytes;
    }
    if (readable.isEmpty) {
      return PreparedHomeworkImages(
        skipped: storageKeys.length,
        note: unreadable > 0 ? '$unreadable 张读取失败' : '',
      );
    }

    // 一次签名批量取好：逐张签名会让「交作业」这一步多出 N 次往返。
    final Map<String, dynamic> signed;
    try {
      signed = await client.postJson(AiEndpoints.uploadsSign, {
        'files': readable.entries
            .map(
              (entry) => {
                'storageKey': entry.key,
                'contentType': mimeTypeOf(entry.key),
                'byteSize': entry.value.length,
              },
            )
            .toList(),
      });
    } on AiRequestException catch (e) {
      return PreparedHomeworkImages(
        skipped: storageKeys.length,
        // ⚠️ `userMessage` 而不是 `message`（2026-10-06）：`note` 会被展示，
        // 而 `message` 里可能带着底层英文异常。
        note: '取上传凭证失败：${e.userMessage}',
      );
    }

    final rawUploads = signed['uploads'];
    if (rawUploads is! List) {
      return PreparedHomeworkImages(
        skipped: storageKeys.length,
        note: '上传凭证格式异常',
      );
    }

    final images = <CloudHomeworkImage>[];
    var skipped = unreadable;
    for (final raw in rawUploads) {
      if (raw is! Map) {
        skipped++;
        continue;
      }
      final storageKey = raw['storageKey'] as String? ?? '';
      final uploadUrl = raw['uploadUrl'] as String? ?? '';
      final objectUrl = raw['objectUrl'] as String? ?? '';
      final bytes = readable[storageKey];
      if (bytes == null || uploadUrl.isEmpty || objectUrl.isEmpty) {
        skipped++;
        continue;
      }
      try {
        await client.putBytes(
          uploadUrl,
          bytes,
          contentType:
              (raw['contentType'] as String?) ?? mimeTypeOf(storageKey),
          extraHeaders: _stringMap(raw['headers']),
        );
      } on AiRequestException {
        skipped++;
        continue;
      }
      images.add(
        CloudHomeworkImage(
          storageKey: storageKey,
          mimeType: mimeTypeOf(storageKey),
          byteSize: bytes.length,
          url: objectUrl,
        ),
      );
    }

    final extra = storageKeys.length - readable.length - unreadable;
    return PreparedHomeworkImages(
      images: images,
      skipped: skipped + (extra > 0 ? extra : 0),
      note: skipped > 0 ? '$skipped 张未能送达对象存储' : '',
    );
  }

  Map<String, String> _stringMap(Object? value) {
    if (value is! Map) return const {};
    return value.map((key, item) => MapEntry('$key', '$item'));
  }
}

/// 未配置图片通道时的占位实现。
///
/// 返回空而不是抛异常：调用方据此判断「这次批改没有图可用」，
/// 该降级就降级，该提示就提示，而不是让整个提交动作炸掉。
class UnavailableHomeworkImageUploader implements HomeworkImageUploader {
  const UnavailableHomeworkImageUploader();

  @override
  int get maxImages => 0;

  @override
  int get maxTotalBytes => 0;

  @override
  bool get requiresUpload => false;

  @override
  Future<PreparedHomeworkImages> prepare(List<String> storageKeys) async {
    return PreparedHomeworkImages(
      skipped: storageKeys.length,
      note: '未配置图片上传通道',
    );
  }
}

/// 按 storageKey 推 MIME 类型。
///
/// ⚠️ **不再是独立规则** —— 委托给 [AttachmentLimits.imageMimeFallback]，
/// 那是全仓唯一的「文件名/键 → MIME」定义处。原先这里有**第四份**副本
/// （`.png` / `.webp` / `.heic`，其余 `image/jpeg`），与另外三份各写各的。
///
/// Web 端拍下来的图不带扩展名（`memory://...` 那种伪造键也未必带），
/// 认不出的后缀一律回落到 jpeg —— 相机与 [ImagePicker] 的默认输出就是 jpeg。
/// 这个兜底**只对图片成立**，因为这条链路只传图片。
String mimeTypeOf(String storageKey) =>
    AttachmentLimits.imageMimeFallback(storageKey);

/// 按**真实字节**判断图片类型，扩展名只作兜底。
///
/// 为什么不能只信扩展名（[mimeTypeOf]）：文件名是**用户侧的东西**，并不可靠 ——
/// 把 `作业.png` 改名成 `.jpg`、截图工具输出无扩展名文件、聊天软件导出成随机名，
/// 都会让「声明 jpeg、实为 png」的请求发出去。
/// 网关目前按声明值过白名单（不嗅探字节），所以这种错配侥幸能过；
/// 接方舟之后，`data:image/jpeg;base64,<PNG 字节>` 会被厂商侧按格式不符拒绝，
/// 而那时报出来的错与「照片拍糊了」长得一样 —— 又是一场很难查的排查。
///
/// 顺序刻意是「先字节、后扩展名」：字节是事实，扩展名是猜测。
String imageMimeTypeOf(Uint8List bytes, {String fileName = ''}) {
  return _sniffMime(bytes) ?? mimeTypeOf(fileName);
}

/// 魔数嗅探。只认白名单里的那几种（见网关 `media.js`），其余返回 null 交给扩展名。
String? _sniffMime(Uint8List bytes) {
  bool startsWith(List<int> magic, [int offset = 0]) {
    if (bytes.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (startsWith([0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  // WebP：`RIFF....WEBP`，中间 4 字节是文件长度。
  if (startsWith([0x52, 0x49, 0x46, 0x46]) &&
      startsWith([0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  // HEIF 家族：`....ftyp` 后跟品牌（heic / heix / mif1…）。
  // iPhone 默认就这么拍，落到这里能少一次「怎么又认不出」。
  if (startsWith([0x66, 0x74, 0x79, 0x70], 4) &&
      (startsWith([0x68, 0x65, 0x69], 8) ||
          startsWith([0x6D, 0x69, 0x66], 8))) {
    return 'image/heic';
  }
  return null;
}

String _mb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);
