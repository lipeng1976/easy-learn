import 'dart:typed_data';

import '../constants/attachment_limits.dart';
import '../models/homework_image_model.dart';
import 'data_api_client.dart';
import 'image_storage_service.dart';

/// 服务端的照片存储：字节传到数据服务，`storageKey` 用服务端给的**相对键**。
///
/// ## 它替掉的是什么
///
/// 本地实现把字节写进**这台设备**（Web 端是浏览器存储，原生端是文件系统），
/// 于是 `storageKey` 必然是一个「设备本地标识」。那个标识在别的设备上
/// **必然读不到**，而读取失败是静默返回 null 的 —— 家长看到的就是
/// 照片位置一片空白、没有任何报错。
///
/// 换成服务端存储之后，键的语义变成「相对服务端存储根目录的路径」，
/// 任何设备都能用 `/data/homework/images/file?id=` 把字节取回来。
///
/// ## 上传与写行是**两步**，这是刻意的
///
/// 拍完照的那一刻，学生往往还在录入作业 —— `homeworkId` 都还没有。
/// 所以上传只管字节（本文件），行的写入仍由「提交作业」那一步
/// 通过 `POST /data/homework/images` 完成。改动面因此只有一个方法。
class RemoteImageStorageService implements ImageStorageService {
  RemoteImageStorageService(this._api);

  final DataApiClient _api;

  /// 服务端附件端点。路径写在这里而不是散在调用点上 —— 它只有一处。
  ///
  /// 两条路各一个端点：`upload` 让字节穿过函数请求体（照片走这条），
  /// `sign-upload` 只签名、由客户端直接 PUT 到对象存储（音视频走这条）。
  /// 见 [_uploadThroughFunction] 与 [_uploadLarge]。
  static const String uploadPath = '/data/homework/images/upload';

  /// 直传签发端点。**只有对象存储后端**回得出内容 —— `IMAGE_DRIVER=fs`
  /// 的部署会如实回 503 `upload_not_configured`，而不是给一个假地址。
  static const String signUploadPath = '/data/homework/images/sign-upload';

  /// 函数请求体的实际上限。
  ///
  /// 本地 `dev-server` 是 `DATA_MAX_BODY_BYTES = 12MB`；平台侧另有上限，
  /// 且会把二进制标成 base64 再膨胀一遍。这里只拿它做**一件事**：判断
  /// 「回退到函数那条路」还成不成立 —— 超了就如实说这条路走不了，
  /// 而不是把请求发出去撞一个与真实原因无关的错误。
  static const int _functionBodyLimitBytes = 12 * 1024 * 1024;

  /// 刚上传的字节在内存里留一份（按 storageKey）。
  ///
  /// ## 为什么需要它
  ///
  /// [readImage] 是**同步**的（接口如此），而服务端的图只能异步取。
  /// 不留这一份的话，「拍完照立刻批改」那条路上的 AI 内联上传会同步读不到
  /// 字节 —— 表现为「批改不看图」，而它看起来与「照片根本没传上去」一模一样。
  ///
  /// ## 为什么是静态的，且刻意很小
  ///
  /// 同一个学生可能在几个页面里各建一个实例（工厂函数每次调用都会 new），
  /// 实例级缓存会让「A 页面上传的图，B 页面读不到」—— 又一个设备本地标识式的
  /// 问题，只是把范围缩小到了进程内。容量只取 [maxCachedImages] 张：
  /// 它的职责仅仅是覆盖「刚拍完、马上要批改」这一小段窗口，
  /// 而不是当图片缓存用（长期缓存是服务端的事）。
  static final Map<String, Uint8List> _recentUploads = <String, Uint8List>{};

  /// 内存里最多留几张。超过就丢最早的那张（Map 的迭代顺序即插入顺序）。
  static const int maxCachedImages = 6;

  /// 多大的附件才值得留在内存里。
  ///
  /// ⚠️ 这个上限是**必须**的：[maxCachedImages] 会留 6 份，若不限大小，
  /// 一个 100MB 视频加几张图就是数百 MB 常驻内存 —— 在手机上等于等着被
  /// 系统杀掉。而它存在的理由只有一个（覆盖「刚传完、马上要批改」那一段
  /// 窗口），批改只吃图片，所以音视频本来就不需要留。
  static const int _recentCacheMaxBytes = 2 * 1024 * 1024;

  /// 本次会话里刚上传的字节；没有则 null。
  ///
  /// **null 不是错误** —— 它可能是别的设备传的、也可能是上一次会话传的。
  /// 那种情况该走 `HomeworkImageReader.load`（异步、会打网络）。
  static Uint8List? recentUpload(String storageKey) =>
      _recentUploads[storageKey];

  static void _rememberRecent(String storageKey, Uint8List bytes) {
    // 大附件**不进**这个缓存，见 [_recentCacheMaxBytes]。
    if (bytes.length > _recentCacheMaxBytes) return;
    while (_recentUploads.length >= maxCachedImages) {
      _recentUploads.remove(_recentUploads.keys.first);
    }
    _recentUploads[storageKey] = bytes;
  }

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
    // 调用方没给 MIME = 老的照片调用点（相机与相册出来的就是 JPEG），
    // 按图片处理是**成立**的兜底。给了 MIME 却归不了类 = 一个我们不知道
    // 往哪归的文件 —— **不能猜**：猜成图片会让它进视觉模型，然后被静默
    // 丢弃（`doc/open-items.md` B29），表现为「批改结果里这个附件凭空消失」。
    final kind = mimeType == null
        ? AttachmentKind.image
        : AttachmentKind.ofMime(mimeType);
    if (kind == null) throw UnsupportedAttachmentException(mimeType);

    final resolvedMime = mimeType ?? mimeTypeOfFileName(fileName);
    final now = DateTime.now();

    // 通道只看**类别**，不看大小。
    //
    // 图片永远走函数（它 ≤8MB，而那条路已经跑了很久、有完整的配额与错误
    // 语义）；音视频走预签名直传。刻意**不**按字节大小分流 —— 那会让
    // 同一个文件在不同尺寸下走不同代码路径，而出问题时会表现成
    // 「有时好有时坏」，那是这类系统里最难查的一种症状。
    final uploaded = kind == AttachmentKind.image
        ? await _uploadThroughFunction(
            studentId: studentId,
            fileName: fileName,
            bytes: bytes,
            mimeType: resolvedMime,
          )
        : await _uploadLarge(
            studentId: studentId,
            fileName: fileName,
            bytes: bytes,
            kind: kind,
            mimeType: resolvedMime,
          );

    final storageKey = (uploaded['storageKey'] as String?) ?? '';
    if (storageKey.isEmpty) {
      // 上传回了 200 却没有键 —— 那就是**没法读回来的字节**。
      // 静默放过去的结果是「附件传上去了，但谁也看不到它」，
      // 而那时已经查不出是哪一步丢的。所以在这里就断掉。
      throw const DataApiException(
        code: 'bad_response',
        message: '附件上传成功，但服务端没有返回存储键（这个附件之后读不回来）',
      );
    }

    // 留一份在内存里：本进程内紧接着的「提交 → 批改」要同步读它。
    _rememberRecent(storageKey, bytes);

    return HomeworkImageModel(
      // ⚠️ 这个 id **只是本地占位**。服务端「写行」时由它自己生成 id
      // （R2：id 由服务端定，请求里带的一律忽略）。所以它与提交后
      // 列表里读回来的 id 不同 —— 这是既有行为，不是这里引入的。
      // 真正要拿去读图的 id 来自 `queryHomeworkImages`。
      id: 'img_${now.microsecondsSinceEpoch}_$sortOrder',
      studentId: studentId,
      homeworkId: homeworkId,
      // 键是**相对的**：不带任何协议头，也不绑定这台设备。
      storageKey: storageKey,
      fileName: fileName,
      fileSize: (uploaded['byteSize'] as num?)?.toInt() ?? bytes.length,
      mimeType: (uploaded['mimeType'] as String?) ?? resolvedMime,
      ocrStatus: ocrStatus,
      ocrText: ocrText,
      createdAt: now,
      batchId: batchId,
      sortOrder: sortOrder,
    );
  }

  /// 小附件（照片）：字节**穿过函数请求体**。
  ///
  /// 服务端同时做配额预检与落盘校验，回包里有真实的 `byteSize` 与
  /// `mimeType` —— 所以调用处用回包的值，不用本地的估算。
  Future<Map<String, dynamic>> _uploadThroughFunction({
    required String studentId,
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) {
    return _api.uploadBytes(
      uploadPath,
      bytes: bytes,
      contentType: mimeType,
      query: {
        'studentId': studentId,
        'fileName': fileName,
        'mimeType': mimeType,
      },
    );
  }

  /// 大附件（音频 / 视频）：**服务端只签名，客户端直接 PUT 到对象存储**。
  ///
  /// ## 为什么不能走函数
  ///
  /// 视频上限 100MB，而函数请求体有上限（本地 `dev-server` 实测 12MB，
  /// 平台侧还会把二进制按 base64 再膨胀一遍）。字节走函数是**结构上**
  /// 过不去的，不是调大某个参数就能解决。
  ///
  /// ## 返回形状与 [_uploadThroughFunction] 对齐
  ///
  /// 调用处不该知道走了哪条路 —— 知道就意味着会有人在那儿写 `if`，
  /// 然后其中一条分支漏掉某个字段。
  ///
  /// ## 只有「服务端说没配直传」才回退
  ///
  /// `IMAGE_DRIVER=fs` 的部署没有可直传的 HTTP 端点，服务端如实回
  /// `upload_not_configured`（503）。那时小文件仍可走函数那条路验通全链路
  /// —— 这是**有意的降级**，服务端注释里也是这么写的。
  /// 其余失败（网络、配额、未登录）一律原样抛：回退会让一个 100MB 的
  /// 文件去撞函数请求体上限，拿回的错误与真实原因毫无关系。
  Future<Map<String, dynamic>> _uploadLarge({
    required String studentId,
    required String fileName,
    required Uint8List bytes,
    required AttachmentKind kind,
    required String mimeType,
  }) async {
    final Map<String, dynamic> signed;
    try {
      signed = await _api.postJson(
        signUploadPath,
        body: {
          'studentId': studentId,
          'mimeType': mimeType,
          'maxBytes': AttachmentLimits.maxBytesOf(kind),
        },
      );
    } on DataApiException catch (e) {
      if (e.code != 'upload_not_configured') rethrow;
      if (bytes.length > _functionBodyLimitBytes) {
        throw DataApiException(
          code: 'upload_not_configured',
          status: e.status,
          message:
              '当前服务端的存储后端不支持大文件直传，'
              '${AttachmentLimits.humanSize(bytes.length)} 的${kind.label}传不上去'
              '（这条路的上限是 '
              '${AttachmentLimits.humanSize(_functionBodyLimitBytes)}）。'
              '请在服务端把 IMAGE_DRIVER 配成对象存储（oss）。',
          details: e.details,
        );
      }
      return _uploadThroughFunction(
        studentId: studentId,
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
      );
    }

    final uploadUrl = (signed['uploadUrl'] as String?) ?? '';
    final storageKey = (signed['storageKey'] as String?) ?? '';
    if (uploadUrl.isEmpty || storageKey.isEmpty) {
      throw const DataApiException(
        code: 'bad_response',
        message: '服务端没有返回完整的直传凭证（缺少上传地址或存储键）',
      );
    }

    await _api.putToAbsoluteUrl(
      uploadUrl,
      bytes: bytes,
      headers: _signedHeaders(signed['headers'], kind),
      timeout: _directUploadTimeout(kind),
    );

    // 直传只解决「字节怎么过去」。**行还是要客户端回来写**
    // （`POST /data/homework/images`）—— 与「先传字节、提交时写行」
    // 的既有结构一致，变的只是第一步。
    return {
      'storageKey': storageKey,
      'byteSize': bytes.length,
      'mimeType': mimeType,
    };
  }

  /// 把服务端回的签名头整份转成可发送的 map。
  ///
  /// **一个都不挑**：OSS V4 把 `content-type` / `host` / `x-oss-*` 全纳入
  /// 签名计算，漏发或改写任何一个，回的都是 `SignatureDoesNotMatch` ——
  /// 而那个错误看起来像「密钥配错了」，与「少发了一个头」毫无关联。
  /// 服务端也是按这条原则整份回传的（见 `ossimagestore.js` 的注释）。
  static Map<String, String> _signedHeaders(
    Object? raw,
    AttachmentKind kind,
  ) {
    if (raw is! Map || raw.isEmpty) {
      throw DataApiException(
        code: 'bad_response',
        message: '服务端没有返回${kind.label}直传所需的签名头',
      );
    }
    final out = <String, String>{};
    raw.forEach((key, value) {
      if (value == null) return;
      out['$key'] = '$value';
    });
    if (out.isEmpty) {
      throw DataApiException(
        code: 'bad_response',
        message: '服务端返回的${kind.label}签名头是空的',
      );
    }
    return out;
  }

  /// 直传的超时。
  ///
  /// ⚠️ **不能复用 `config.imageTimeout`**：那个值是给函数往返定的
  /// （秒级），而 100MB 视频在家用上行带宽上要几分钟。用错那个值的症状是
  /// 「大视频每次都超时、小音频都成功」，看起来像「视频格式不支持」。
  ///
  /// 视频取 12 分钟（2026-10-06 由 5 分钟提高）：上限放宽到 100MB 后，
  /// 5 分钟要求有效上行 ≥340KB/s —— 2026-10-05 晚的「提交视频失败」
  /// 就是这个形状（字节没落库、提示是连接失败）。12 分钟要求 ≥143KB/s，
  /// 且仍在 OSS 签名窗口（15 分钟，`OSS_V4_CLOCK_WINDOW_SECONDS`）内
  /// —— 窗口是服务端行为，**超了无法重试补救**，所以不能往上贴近 15。
  /// 超时的报错文案在 [_uploadLarge] 调用方那里做了针对性翻译，
  /// 不让大文件超时和普通断网说同一句话。
  static Duration _directUploadTimeout(AttachmentKind kind) =>
      kind == AttachmentKind.video
      ? const Duration(minutes: 12)
      : const Duration(minutes: 4);

  /// 同步读**只能命中本进程刚上传的那几张**（见 [_recentUploads]）。
  ///
  /// ⚠️ 其余情况一律 null —— 这是本接口的**同步**签名决定的，不是缺陷：
  /// 服务端的图只能异步取。返回 null 而不是抛异常，是因为接口是同步的、
  /// 而所有调用方都有「读不到就少一张」的兜底分支；抛异常会把
  /// 「照片读不到」从一次可降级的空白变成一次崩溃。
  ///
  /// **要读服务端照片请用 `HomeworkImageReader.load(image)`** —— 它是异步的，
  /// 认得这个键该走网络还是该回退本地，并且会告诉调用方为什么没读到。
  @override
  Uint8List? readImage(String storageKey) => recentUpload(storageKey);

  /// 服务端照片的删除**不在这里**。
  ///
  /// 删行由 `POST /data/homework/images/delete`（按作业清场）负责；
  /// 盘上的文件刻意不跟着删 —— 那是一次文件系统 IO，而删行跑在 PG 事务里，
  /// 回滚时文件已经没了。孤儿的文件不占任何用户可见状态，
  /// 清理属于运维（按归档日期目录删）。见服务端 `routes/homework.js` 的说明。
  @override
  void deleteImage(String storageKey) {}
}

/// 由文件名推 MIME。
///
/// ⚠️ 它**不再是独立规则** —— 只是 [AttachmentLimits.imageMimeFallback] 的
/// 一个别名，保留是因为「照片上传」这条链路的调用点读起来更顺。
///
/// 原先这里有**第三份**实现（`.png` / `.webp` / `.heic`，其余 `image/jpeg`），
/// 而本地那份 `LocalImageStorageService._mimeType` 认不出 `.heic` —— 同一张
/// HEIC 照片，走服务端存储记成 `image/heic`、走本地存储记成 `image/jpeg`。
/// 两份互不知情、都不报错，只在服务端白名单收紧那天炸。
///
/// 兜底成 `image/jpeg` 仍然成立，而且**只对图片成立**：相机出来的就是 JPEG，
/// 送一个服务端白名单外的类型会换来一次 400，把「上传失败」的原因从
/// 「网络」挪到「文件类型」，对用户没有任何帮助。
String mimeTypeOfFileName(String fileName) =>
    AttachmentLimits.imageMimeFallback(fileName);
