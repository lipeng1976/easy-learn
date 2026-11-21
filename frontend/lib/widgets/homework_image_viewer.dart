import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../constants/app_colors.dart';
import '../constants/attachment_limits.dart';
import '../models/homework_image_model.dart';
import '../services/data_api_client.dart';
import '../services/database_service.dart';
import '../services/image_key.dart';
import '../services/image_storage_service.dart';
import '../services/remote_image_storage.dart';
import '../utils/pop_route.dart';
import 'attachment_player.dart';

/// 打开全屏作业照片查看器：多图左右滑动、双指缩放。
///
/// 学生端与家长端共用同一个查看器，保证「家长看到的图和老师看到的一样」。
void openHomeworkImages({
  required List<HomeworkImageModel> images,
  int initialIndex = 0,
}) {
  if (images.isEmpty) return;
  Get.dialog(
    _HomeworkImageViewer(images: images, initialIndex: initialIndex),
    barrierColor: Colors.black87,
  );
}

class _HomeworkImageViewer extends StatefulWidget {
  const _HomeworkImageViewer({
    required this.images,
    required this.initialIndex,
  });

  final List<HomeworkImageModel> images;
  final int initialIndex;

  @override
  State<_HomeworkImageViewer> createState() => _HomeworkImageViewerState();
}

class _HomeworkImageViewerState extends State<_HomeworkImageViewer> {
  late final PageController _pageController = PageController(
    initialPage: widget.initialIndex,
  );
  late int _current = widget.initialIndex;

  /// 用户手动点「重试」后，为某一页单独覆盖一个 Future。
  /// 不进静态缓存，避免污染别的页面；离开再回来仍是首次加载结果。
  final Map<int, Future<Uint8List?>> _retries = <int, Future<Uint8List?>>{};

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.images[_current];
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(14),
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => popRoute(context),
                  icon: const Icon(Icons.close, color: Colors.white),
                  tooltip: '关闭',
                ),
                Expanded(
                  child: Text(
                    image.fileName,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.images.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      '${_current + 1} / ${widget.images.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
              ],
            ),
          ),
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxHeight: 560),
              decoration: const BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(14),
                ),
              ),
              child: PageView.builder(
                controller: _pageController,
                itemCount: widget.images.length,
                onPageChanged: (index) => setState(() => _current = index),
                itemBuilder: (context, index) => FutureBuilder<Uint8List?>(
                  future: _retries[index] ??
                      HomeworkImageReader.load(
                        widget.images[index],
                        width: HomeworkImageReader.fullScreenWidth,
                      ),
                  builder: (context, snapshot) {
                    final bytes = snapshot.data;
                    // 「还没回来」与「拿不到」必须分开：把加载中画成
                    // 「这张照片已不可用」，用户会以为照片坏了 ——
                    // 而它其实只是还在路上。
                    if (bytes == null) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(
                          child: SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white54),
                            ),
                          ),
                        );
                      }
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.broken_image_outlined,
                                color: Colors.white54,
                                size: 42,
                              ),
                              const SizedBox(height: 10),
                              const Text(
                                '这张照片暂时打不开',
                                style: TextStyle(color: Colors.white70),
                              ),
                              const SizedBox(height: 14),
                              ElevatedButton.icon(
                                onPressed: () => setState(
                                  () => _retries[index] =
                                      HomeworkImageReader.retry(
                                        image,
                                        width: HomeworkImageReader.fullScreenWidth,
                                      ),
                                ),
                                icon: const Icon(Icons.refresh, size: 18),
                                label: const Text('重试'),
                                style: ElevatedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  backgroundColor: Colors.white24,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    return InteractiveViewer(
                      minScale: 1,
                      maxScale: 4,
                      child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一个**直接从对象存储取字节**的位置（大附件：视频）。
///
/// ## 为什么不让它退化成「先下载成 bytes」
///
/// 两条独立的理由，任一条都足够：
/// ① **取不回来**：函数计算的响应体上限是 32 MiB，而视频上限 100 MB ——
///    走 `GET /data/homework/images/file` 的话，超过 32 MiB 的附件传得上去、
///    取不回来（`doc/open-items.md` B32）；
/// ② **放不下**：100 MB 整段进内存在低端机上就是等着被系统杀掉，
///    而播放器本来就能一边下一边播。
///
/// [headers] 是服务端签好的 `x-oss-date` / `x-oss-content-sha256` /
/// `authorization`。**一个都不能挑、不能改** —— 与上传侧同一条规矩
/// （见 `RemoteImageStorageService._signedHeaders`）。
class AttachmentDirectRead {
  const AttachmentDirectRead({required this.url, required this.headers});

  final String url;
  final Map<String, String> headers;
}

/// 作业照片读取入口。**全应用只有这一个**。
///
/// ## 两条路，按 `storageKey` 的形态分流
///
/// | 键的形态 | 读法 |
/// |---|---|
/// | 服务端相对键（`20260920/…`） | `GET /data/homework/images/file?id=` —— 任何设备都能读 |
/// | 设备本地标识（`memory://…`、绝对路径） | 本地存储 —— **只在当初那台设备上成立** |
///
/// 之所以必须在这里分流：两种键的字节根本不在同一个地方，而且
/// **判错的症状完全相同**（照片位置一片空白、无报错）。
///
/// ## 为什么同步的 [read] 还留着
///
/// 旧数据（改动之前写进库的那些）的字节只存在于当初那台设备上，
/// 服务端没有 —— 它们只能本地读，而本地读是同步的。
/// [read] 保留的意义就是**让那些照片在原来的设备上还能看**，
/// 而不是跟着新方案一起报废。
abstract final class HomeworkImageReader {
  /// 本地读的兜底（旧数据）。新数据不经手它。
  static final ImageStorageService _local = LocalImageStorageService();

  /// 已经取回来的字节，按 `storageKey` 存。
  ///
  /// 没有它的话，一张缩略图会在**每次 build** 时重新发一次请求 ——
  /// 列表滚动、家长来回切孩子，都会把同几张照片反复拉一遍。
  static final Map<String, Uint8List> _cache = <String, Uint8List>{};

  /// 正在路上的请求。
  ///
  /// `FutureBuilder` 会在父组件每次重建时重新调用 [load]，
  /// 于是同一张图会同时在飞好几个请求。去重之后，
  /// 重复的调用直接拿到**同一个** Future —— 这不是省流量，
  /// 是让「加载中」这件事只有一个来源。
  ///
  /// ⛔ 从这张表里取出来的 Future **只能原样交出去，不能再包一层**。
  /// 曾经这里写着 `base.whenComplete(() => _inflight.remove(key))`，
  /// 见 [load] 里的说明：那个写法会 await 到它自己，**永不完成**。
  static final Map<String, Future<Uint8List?>> _inflight = <String, Future<Uint8List?>>{};

  /// 已经结束的请求。**同一个 key 永远给出同一个 Future 实例。**
  ///
  /// ## 为什么「已经完成」也必须固定下来
  ///
  /// 这一条不是省内存（值是同一份 bytes），而是 [FutureBuilder] 的硬规则：
  /// 它在 `didUpdateWidget` 里比较 `oldWidget.future != widget.future`，
  /// **不相等就把快照重置回 waiting**。而 `Future.value(bytes)` 每次调用
  /// 都是**新实例**。
  ///
  /// 于是「每次 build 现造一个已经完成的 Future」= 「界面在打转」。
  /// 这条与 [load] 里那个自等待死锁**是两回事，症状却一模一样**，
  /// 所以两条都得钉住 —— 只修死锁的话，详情页那层 `Obx` 一开始重建，
  /// 缩略图就会重新转圈（实测：网络面板 12ms / 58ms 就 200 了，界面照转不误）。
  static final Map<String, _Settled> _settled = <String, _Settled>{};

  /// 空键 / 无需网络的那一类，共用一个已完成 Future（理由同 [_settled]）。
  static final Future<Uint8List?> _empty = Future<Uint8List?>.value();

  /// 拿不到字节之后，隔多久允许再试一次。
  ///
  /// 失败**也**要固定住：不固定的话，每次重建都会重新发一次请求，
  /// 而重建可能很频繁 —— 一张读不到的图会变成一串打不完的请求。
  /// 但固定成永久，一次网络抖动就会让这张图在本次运行里永远「不可用」
  /// （本类是静态的，跨页面存活，重进页面也不会重试）。
  /// 30 秒是这个权衡的位置：够短到用户重试时已自愈，够长到不会打请求。
  static const Duration retryAfterFailure = Duration(seconds: 30);

  /// 内存里最多留几张。照片是几兆一张，无上限地攒会真的把内存吃掉。
  static const int maxCachedImages = 12;

  static DateTime Function() _now = DateTime.now;

  /// 清干净两份缓存，并把「现在」换掉。
  ///
  /// 测试必须能重置静态状态：否则一个用例留下的「失败已固定」会
  /// 让下一个用例在 30 秒内看不到任何重试 —— 而它看起来像功能坏了。
  @visibleForTesting
  static void resetForTest({DateTime Function()? now}) {
    _cache.clear();
    _inflight.clear();
    _settled.clear();
    _now = now ?? DateTime.now;
  }

  /// 同步读 —— **只对本地存储的键有效**。
  ///
  /// 服务端键在这里恒为 null（[readImage] 读不了网络）。要读服务端照片
  /// 用 [load]。
  static Uint8List? read(String storageKey) {
    if (storageKey.isEmpty) return null;
    final cached = _cache[storageKey];
    if (cached != null) return cached;
    return _local.readImage(storageKey);
  }

  /// 异步读一张照片的字节。**新数据（服务端键）走这条。**
  ///
  /// 返回 null 表示「这次拿不到」，调用方应显示不可用占位。
  /// 拿不到的原因有三类，**处置各不相同**，所以不能把它们压成一个 null：
  ///
  /// 1. 键是设备本地标识 → 回退本地读（在当初那台设备上它本来就能看）；
  /// 2. 服务端回 `details.reason == 'not_on_server'` → 同上，这是**旧数据**；
  /// 3. 其余（网络、权限、文件真没了）→ 如实不可用。
  ///
  /// ⚠️ 两条硬约束，**都是为了让「加载中」这件事只有一个来源**：
  ///
  /// ① 同一个 `storageKey` 返回的**必须是同一个 Future 实例** —— 见 [_settled]；
  /// ② 交出去的那个 Future **绝不能在内部等它自己** —— 见下方 ⛔。
  ///
  /// ⛔ **不要用 `future.whenComplete(() => _inflight.remove(key))` 这种写法。**
  ///
  /// 这行看着天经地义，实际是个**自等待死锁**：`whenComplete` 会 await
  /// 回调返回的 Future，而 `_inflight.remove(key)` 取出来的正是**它自己**
  /// （上一行刚存进去的）。于是这个 Future 一直等自己完成，**永不完成**。
  ///
  /// 症状正是「家长端缩略图一直转圈」：字节其实 12ms 就回来了（网络面板 200），
  /// `_remember` 也已把字节写进 [_cache]，**只有那个 Future 卡着**，
  /// 于是 `FutureBuilder` 永远停在 `waiting`。
  ///
  /// 为什么点开全屏却能看到原图：`_remember` 在死锁**之前**就执行过了，
  /// 全屏那次 [load] 命中的是缓存分支，拿到的是 `Future.value(bytes)`，
  /// 跟死掉的那个实例没关系。**同一个方法，差别只在「缓存有没有先被填上」。**
  static const String defaultEndpoint = '/data/homework/images/file';

  /// 缩略图网格的请求宽度。
  ///
  /// 缩略图方格只有 78–110px，800 宽画满一屏绰绰有余，字节只有原图的一成多。
  static const int thumbnailWidth = 800;

  /// 全屏查看的请求宽度。
  ///
  /// 1600 是**刻意留余量**的一档：手机屏宽 1080–1440 物理像素，1600 已超过
  /// 屏幕本身，双指放大 2 倍内仍然清晰；体积约为原图的四成，VPN
  /// （Tailscale 这类虚拟网卡 MTU 只有 1280）下也更容易稳定穿过。
  /// 再往上加对肉眼几乎无收益，却会把大响应重新推回 MTU 黑洞的射程。
  static const int fullScreenWidth = 1600;

  static Future<Uint8List?> load(
    HomeworkImageModel image, {
    String endpoint = defaultEndpoint,
    int? width,
  }) {
    final key = image.storageKey;
    if (key.isEmpty) return _empty;
    // 同一个 storageKey 在不同端点下字节相同，但 id 空间不同（作业图片与
    // 错题图片是两张表）。默认端点保持旧键，避免影响既有缓存/测试。
    // 缩略图请求的 `width` 不同 → 缓存也要分开（同一张图不同尺寸是不同字节）。
    final widthTag = width == null ? '' : '@$width';
    final cacheKey = endpoint == defaultEndpoint ? '$key$widthTag' : '$endpoint|$key$widthTag';

    final settled = _settled[cacheKey];
    if (settled != null) {
      // 成功的固定住；失败的有自愈窗口。
      if (settled.ok || _now().difference(settled.at) < retryAfterFailure) {
        return settled.future;
      }
      _settled.remove(cacheKey);
    }

    // 在飞的就复用它，别再发一次。
    final pending = _inflight[cacheKey];
    if (pending != null) return pending;

    final future = _fetch(image, endpoint: endpoint, width: width);
    _inflight[cacheKey] = future;
    unawaited(future.then(
      (bytes) {
        _inflight.remove(cacheKey);
        _settle(cacheKey, _Settled(future, ok: bytes != null, at: _now()));
      },
      onError: (Object _) {
        // `_fetch` 自己已经把异常收成 null 了，这一支是保险：
        // 万一将来它漏出一种异常，也别让这个 key 永远卡在「在飞」。
        _inflight.remove(cacheKey);
        _settle(cacheKey, _Settled(future, ok: false, at: _now()));
      },
    ));
    return future;
  }

  /// 强制重新拉一次字节。
  ///
  /// 失败默认被缓存 30 秒（`retryAfterFailure`）—— 那是防「每次重建都重发」
  /// 的代价。但 VPN / 弱网下那次失败往往是**瞬时的**（大响应在隧道里抖一下），
  /// 用户点一下就该立刻再试，而不是干等半分钟。
  /// 清空这个 key 的三处状态后再 [load]，必发一次新请求。
  static Future<Uint8List?> retry(
    HomeworkImageModel image, {
    String endpoint = defaultEndpoint,
    int? width,
  }) {
    final key = image.storageKey;
    final widthTag = width == null ? '' : '@$width';
    final cacheKey = endpoint == defaultEndpoint ? '$key$widthTag' : '$endpoint|$key$widthTag';
    _cache.remove(cacheKey);
    _inflight.remove(cacheKey);
    _settled.remove(cacheKey);
    return load(image, endpoint: endpoint, width: width);
  }

  /// 试签一个**直读**位置。返回 null = 这条路现在不可用，调用方走字节那条路。
  ///
  /// ## 为什么所有失败都收成 null，而不是抛出去
  ///
  /// 因为字节那条路是**功能上的正路**，不是「备选优化」：小附件本来就走得通，
  /// 而真出问题（网络、未登录）时那条路会把真实原因照样报出来。
  /// 把签发失败直接抛给用户，等于让一个**纯优化**的失败挡住正路。
  ///
  /// 三种 null 各自对应一条已知的路，不是「随便吞掉」：
  /// ① `upload_not_configured` → `IMAGE_DRIVER=fs`，这条路在本部署上不存在；
  /// ② 404 `not_on_server` → 旧数据，字节只在当初那台设备上，[load] 会回退本地读；
  /// ③ 网络 / 超时 → 兜底那条路会再试一次，失败信息以它为准。
  /// 每一种都打一行 [debugPrint]，所以「为什么走了慢路」在日志里看得见 ——
  /// 不打的话，「直读没生效」与「本来就没走直读」完全一样。
  ///
  /// ## 刻意**不缓存**签发结果
  ///
  /// 凭证 15 分钟过期，缓存它就得再管一个「什么时候算过期」的时钟，
  /// 而过期的表现是「播放到一半 403」—— 很难从症状反推到那个时钟。
  /// 每次打开花一次往返（几百毫秒）换掉这一整类问题，值。
  static Future<AttachmentDirectRead?> directRead(HomeworkImageModel image) async {
    if (image.id.isEmpty) return null;
    // 旧标识（设备本地路径）在对象存储里没有对象，签出来必然 404。
    if (!isServerImageKey(image.storageKey)) return null;
    // Web 端**用不了**这条路：签名放在请求头里（桶是私有的），而浏览器的
    // `<video>` 元素加不上自定义头 —— 拿到的地址会 403。
    // 如实回 null，让调用方走原来的路：网页版本来就播不了内联视频
    // （见 `video_source_stub.dart`），那句「请在手机 App 里打开」得留着。
    if (kIsWeb) return null;
    final api = _api;
    if (api == null) return null;
    try {
      final data = await api.signAttachmentRead(image.id);
      final url = (data['readUrl'] as String?) ?? '';
      final raw = data['headers'];
      if (url.isEmpty || raw is! Map) return null;
      final headers = <String, String>{
        for (final e in raw.entries)
          if (e.value != null) '${e.key}': '${e.value}',
      };
      if (headers.isEmpty) return null;
      return AttachmentDirectRead(url: url, headers: headers);
    } on DataApiException catch (e) {
      debugPrint('附件直读签发不可用（${e.code}），改走字节路径：${e.message}');
      return null;
    } catch (e) {
      debugPrint('附件直读签发失败，改走字节路径：$e');
      return null;
    }
  }

  /// 往 [_settled] 里放一条，顺手挡住它自己的无界增长。
  ///
  /// 成功项与 `_cache` 同寿（[_remember] 淘汰时会一起清），
  /// 所以这里只需要处理「全是失败项」那种堆积：先丢失败的，
  /// 它们本来就有自愈窗口，丢了代价最小。
  static void _settle(String key, _Settled entry) {
    if (_settled.length >= maxCachedImages * 2) {
      _settled.removeWhere((_, v) => !v.ok);
    }
    _settled[key] = entry;
  }

  /// 读取失败时的自动重试次数。
  ///
  /// 走服务端键的图片（作业照片）在 VPN / 弱网下偶发「请求发了、但隧道里丢了」——
  /// 服务端根本没收到，客户端只看到「拿不到字节」。这种失败是**瞬时**的，
  /// 重发一次往往就好，不该让用户每次都手动点「重试」。
  /// 只重试「网络 / 超时」这一类；`not_on_server`（旧数据，字节只在当初那台设备）
  /// 是永久结论，不重试。
  static const int _imageMaxRetries = 2;
  static const Duration _imageRetryBase = Duration(milliseconds: 700);

  static Future<Uint8List?> _fetch(
    HomeworkImageModel image, {
    String endpoint = defaultEndpoint,
    int? width,
  }) async {
    // 旧标识：本地读。注意这里**不是**「失败兜底」，而是这条路本就该这么走。
    if (!isServerImageKey(image.storageKey)) {
      return read(image.storageKey);
    }

    // 本进程刚上传的字节：`RemoteImageStorageService` 按 `storageKey` 留了一份。
    //
    // 命中它有两个意义，第二个才是关键：
    // ① 省一次往返 —— 字节就在手上，没必要再下载一遍；
    // ② 这条路**不依赖行 id**。而下载那条是按 `id` 查的，服务端的 id 由它
    //    自己生成（`imageRow()` 的 `newId()`），刚提交那一刻客户端手里可能
    //    还是本地占位 id（`img_…`）—— 那种情况下按 id 查必然查不到，
    //    照片位置就是一片空白，且不报任何错。
    //    这里先看一眼内存，等于给「id 还没采纳回来」留了一条能看见的退路。
    final recent = RemoteImageStorageService.recentUpload(image.storageKey);
    if (recent != null) {
      _remember(image.storageKey, recent);
      return recent;
    }

    final api = _api;
    if (api == null) return null;

    /// 每次重试把目标宽度调小一档：1600 过大就试 960、再试 640（按 0.6 / 0.4 递减）。
    ///
    /// VPN / 弱网下「原尺寸那档过不去」是常态 —— 同样一张图，字节少一半
    /// 往往就能穿过 MTU 黑洞。逐级下调比「原样重发」显著更容易拿到图，
    /// 代价只是这一屏分辨率略低（`Image.memory` 照常缩放显示）。
    final attemptWidths = <int?>[
      if (width == null)
        null
      else ...[
        width,
        (width * 0.6).round(),
        (width * 0.4).round(),
      ],
    ];

    for (var attempt = 0; attempt <= _imageMaxRetries; attempt++) {
      try {
        final query = <String, Object?>{'id': image.id};
        // 传了宽度就让服务端现场缩图（VPN / 弱网下大原图最易被 MTU 黑洞卡住）。
        final w = attemptWidths[attempt < attemptWidths.length
            ? attempt
            : attemptWidths.length - 1];
        if (w != null) query['w'] = w;
        final bytes = await api.downloadBytes(
          endpoint,
          query: query,
        );
        _remember(image.storageKey, bytes);
        return bytes;
      }       on DataApiException catch (e) {
        // 「字节不在服务端」= 这一行是改动之前写的，字节只在当初那台设备上。
        // 直接报不可用会把**原本还能看**的照片一起丢掉。这是永久结论，不重试。
        if (e.details?['reason'] == 'not_on_server') {
          return read(image.storageKey);
        }
        // 只有「网络 / 超时」这一类是瞬时的（VPN / 弱网偶发丢包），
        // 退避后重发往往就好。其余（`not_found` / `bad_response` 等）是
        // 永久结论，重发也没用，直接如实不可用，避免无意义地轰炸服务端。
        final retryable = e.code == 'network' || e.code == 'timeout';
        if (retryable && attempt < _imageMaxRetries) {
          await Future.delayed(_imageRetryBase * (attempt + 1));
          continue;
        }
        debugPrint(
          '作业图片读取失败（${retryable ? '已重试 $_imageMaxRetries 次' : '不可重试'}，'
          'id=${image.id}）：${e.code} ${e.message}',
        );
        return null;
      } catch (_) {
        // 兜底的一类（非 DataApiException）也按瞬时失败重试；最后一次才如实不可用。
        // 一张照片读不到不该炸掉整个查看器（同一屏里还有别的照片）。
        if (attempt < _imageMaxRetries) {
          await Future.delayed(_imageRetryBase * (attempt + 1));
          continue;
        }
        return null;
      }
    }
    return null;
  }

  static void _remember(String storageKey, Uint8List bytes) {
    while (_cache.length >= maxCachedImages) {
      final oldest = _cache.keys.first;
      _cache.remove(oldest);
      // 字节没了，那个「已完成」的 Future 也留不住它 —— 一起清，
      // 否则下次 load 会返回一个指向**已被淘汰的图**的 Future 实例。
      _settled.remove(oldest);
    }
    _cache[storageKey] = bytes;
  }

  /// 当前的数据服务客户端。**刻意不设「装配入口」**。
  ///
  /// 一个 `useRemote(api)` 之类的接线函数意味着「启动时记得调它」，
  /// 而忘记调的表现是「照片全都不见了」—— 又是一次静默失败。
  /// 直接从运行形态里取，就没有这道可漏的工序。
  static DataApiClient? get _api => DatabaseService.cloud?.api;
}

/// 一次已经结束的读取 —— 连同「它成不成功」和「什么时候结束的」一起记住。
///
/// 只记 Future 是不够的：失败的那一类需要在 [HomeworkImageReader.retryAfterFailure]
/// 之后放行重试，而「什么时候结束的」只能额外存。
class _Settled {
  const _Settled(this.future, {required this.ok, required this.at});

  final Future<Uint8List?> future;

  /// 拿到了字节没有。false 的那一类有自愈窗口。
  final bool ok;

  final DateTime at;
}

/// 作业照片缩略图网格。点击任意一张进入全屏查看。
class HomeworkImageGrid extends StatelessWidget {
  const HomeworkImageGrid({
    super.key,
    required this.images,
    this.thumbnailSize = 92,
    this.emptyHint = '本次提交没有上传附件',
  });

  final List<HomeworkImageModel> images;
  final double thumbnailSize;
  final String emptyHint;

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            const Icon(
              Icons.image_not_supported_outlined,
              size: 26,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: 6),
            Text(
              emptyHint,
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ],
        ),
      );
    }

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (var i = 0; i < images.length; i++)
          _Thumbnail(
            image: images[i],
            size: thumbnailSize,
            onTap: () => _openAt(context, i),
          ),
      ],
    );
  }

  /// 点开第 [index] 个附件。
  ///
  /// 图片走左右滑动的查看器，音视频走播放器 —— 两条路必须分开：
  /// 「滑动看下一张」对一段视频没有意义，而把音视频塞进图片查看器
  /// 会在滑到它时出现一个**点不动的空页**。
  void _openAt(BuildContext context, int index) {
    final image = images[index];
    final kind = AttachmentKind.ofMime(image.mimeType);
    if (kind == AttachmentKind.image) {
      // ⚠️ 只把**图片**传给查看器。整份列表传进去的话，翻页索引与页数
      //    都对不上（音视频占了位子却没有画面）。
      final photoIndexes = <int>[
        for (var i = 0; i < images.length; i++)
          if (AttachmentKind.ofMime(images[i].mimeType) ==
              AttachmentKind.image)
            i,
      ];
      if (photoIndexes.isEmpty) return;
      openHomeworkImages(
        images: [for (final i in photoIndexes) images[i]],
        initialIndex: photoIndexes
            .indexOf(index)
            .clamp(0, photoIndexes.length - 1),
      );
      return;
    }
    unawaited(_openAttachment(context, image, kind));
  }

  /// 音视频：**先试直读**，拿不到才把字节取回来交给播放器。
  ///
  /// 取不回来就**明说**。「点了没反应」与「加载失败」在用户眼里是同一件事，
  /// 而后者至少能让他知道该重试而不是反复点。
  ///
  /// ## 为什么音频也走直读（它 ≤20 MB，明明过得去函数）
  ///
  /// 因为直读是音频**唯一不经本地明文代理**的路：`just_audio` 吃内存字节时
  /// 会经它自己的 `http://127.0.0.1` 代理转发给 ExoPlayer，而回环明文在
  /// `targetSdk >= 28` 上被禁 —— 症状正是「照片、视频都好好的，**所有音频**
  /// 都报 `(0)source error`」。完整机制见 `attachment_player.dart` 的
  /// `_AudioBodyState.initState`。
  ///
  /// 视频另有一个理由：100 MB 既过不去函数 32 MiB 的响应体上限
  /// （`doc/open-items.md` B32），也不该整段读进内存。
  ///
  /// 两条都保留退路：直读拿不到时（`IMAGE_DRIVER=fs` 的部署、旧数据、
  /// 网页版）仍走字节那条 —— 播放器收到字节后落盘成 `file:`，同样不过代理。
  ///
  /// ⚠️ **直读签得到、但播放器打不开**是另一回事（2026-10-03 真机上出过）：
  /// 这里看不出来，因为异常发生在播放器内部。所以下面多传了一个 `loadBytes`
  /// —— 播放器自己在失败时退回落盘那条，不用回到这里重来。见 B34。
  Future<void> _openAttachment(
    BuildContext context,
    HomeworkImageModel image,
    AttachmentKind? kind,
  ) async {
    if (kind == null) {
      Get.snackbar('打不开', '这个附件的类型无法识别。');
      return;
    }
    final title = image.fileName.isEmpty ? '${kind.label}附件' : image.fileName;

    if (kind == AttachmentKind.video || kind == AttachmentKind.audio) {
      final target = await HomeworkImageReader.directRead(image);
      if (target != null) {
        if (!context.mounted) return;
        // URL 直接交给播放器：它边下边播，函数与内存都不经手这一段字节。
        // `loadBytes` 是**退路**：直读打不开时播放器会自己去取字节落盘再播，
        // 不用退回这里重来（真机上直读曾经打不开 —— 见 B34）。
        await openAttachmentPlayer(
          context: context,
          title: title,
          kind: kind,
          directUrl: target.url,
          headers: target.headers,
          loadBytes: () => HomeworkImageReader.load(image),
          mimeType: image.mimeType,
        );
        return;
      }
    }

    final bytes = await HomeworkImageReader.load(image);
    if (bytes == null || bytes.isEmpty) {
      Get.snackbar('打不开', '这个附件的字节暂时取不回来，请稍后再试。');
      return;
    }
    if (!context.mounted) return;
    await openAttachmentPlayer(
      context: context,
      title: title,
      kind: kind,
      bytes: bytes,
      mimeType: image.mimeType,
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    required this.image,
    required this.size,
    required this.onTap,
  });

  final HomeworkImageModel image;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: _buildContent(),
      ),
    );
  }

  /// 缩略图内容：图片画字节，音视频画一个类型图标。
  ///
  /// ⚠️ 音视频**刻意不加载字节** —— 一个 100MB 的视频被读进内存只为画一个
  /// 78px 的方格，在手机上等于自己制造一次 OOM。它们只需要类型图标与体积，
  /// 字节留到点开播放那一刻再取（见 `_openAttachment`）。
  Widget _buildContent() {
    final kind = AttachmentKind.ofMime(image.mimeType);
    if (kind != AttachmentKind.image) {
      return _MediaThumb(kind: kind, byteSize: image.fileSize);
    }
    return FutureBuilder<Uint8List?>(
      future: HomeworkImageReader.load(
        image,
        width: HomeworkImageReader.thumbnailWidth,
      ),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null) return Image.memory(bytes, fit: BoxFit.cover);
        // 「加载中」与「拿不到」要分开画：把前者画成「不可用」，
        // 一屏缩略图会在网络回来的那一刻**整片闪一次**「照片坏了」。
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.textMuted),
              ),
            ),
          );
        }
        return const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.broken_image_outlined,
              size: 26,
              color: AppColors.textMuted,
            ),
            SizedBox(height: 4),
            Text(
              '不可用',
              style: TextStyle(fontSize: 10, color: AppColors.textMuted),
            ),
          ],
        );
      },
    );
  }
}

/// 音视频附件的缩略图：类型图标 + 体积。
///
/// 没有预览帧是**刻意的**：抽一帧要先把整个文件下载并解码，而缩略图网格
/// 里可能有六个附件 —— 那会让打开一次作业顺带下载上百 MB。类型图标能让
/// 学生认出「这是我录的那段」就够了，真要确认内容他会点开播放。
class _MediaThumb extends StatelessWidget {
  const _MediaThumb({required this.kind, required this.byteSize});

  final AttachmentKind? kind;
  final int byteSize;

  @override
  Widget build(BuildContext context) {
    final icon = switch (kind) {
      AttachmentKind.video => Icons.videocam,
      AttachmentKind.audio => Icons.audiotrack,
      _ => Icons.help_outline,
    };
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          icon,
          size: 26,
          color: kind == null ? AppColors.textMuted : AppColors.primary,
        ),
        const SizedBox(height: 4),
        Text(
          kind == null ? '未知附件' : AttachmentLimits.humanSize(byteSize),
          style: const TextStyle(fontSize: 10, color: AppColors.textMuted),
        ),
      ],
    );
  }
}
