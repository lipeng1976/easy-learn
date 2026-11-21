import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

import '../constants/attachment_limits.dart';
import '../utils/pop_route.dart';
import 'video_source_stub.dart' if (dart.library.io) 'video_source_io.dart';

// `just_audio` 的 `StreamAudioSource` / `StreamAudioResponse` 标着 @experimental
// （「可能随时改动」）。我们**有意**承担这个风险 —— 但只在一个地方用它：
// **网页版**的音频。原生平台上音频走 `setUrl` / `setFilePath`（见 `_AudioBody`），
// 不用它。理由写在 `_AudioBodyState.initState` 那段。
//
// ignore_for_file: experimental_member_use

/// 播放器构建标记 —— 只出现在**失败信息**里。
///
/// 真机上没有日志可看，而「我装的是不是新包」**无法从症状判断**：修复前后
/// 的报错可能一字不差（这一轮就撞上了）。把它印在失败信息里，一张截图就能
/// 回答「他手上到底是哪一版」。验证通过后可以删（下面两处引用一起删）。
const kAttachmentPlayerBuild = 'b5';

/// 打开附件的播放 / 预览界面。
///
/// 三种类型的呈现完全不同（图片放大、音频放声音、视频放画面），但它们
/// 共用**一个入口** —— 调用方只描述「这是什么」，不必自己分支。分成三个
/// 入口的话，调用点迟早会漏掉一支，而漏掉的表现是「点了没反应」。
///
/// ## 三个来源参数：直读优先，字节是**退路**（不是二选一）
///
/// | 参数 | 是什么 | 谁会填 |
/// |---|---|---|
/// | [bytes] | 已经拿在手上的字节 | 图片（≤8 MB，查看器那层缓存了）、草稿的预览 |
/// | [directUrl] + [headers] | 服务端签好的**对象存储位置** | 已入库的音视频 |
/// | [loadBytes] | **懒加载**字节的回调，直读打不开时才调 | 已入库的音视频（`HomeworkImageReader.load`） |
///
/// [directUrl] 优先是有理由的：不受函数 32 MiB 响应体上限约束（视频 100 MB
/// 过不去，见 `doc/open-items.md` B32），且是流式播放、不把整段读进内存。
/// ⚠️ [headers] 是签名的一部分，**一个都不能改**（服务端 `signDirectGet`
/// 的注释里写了为什么把整份头原样回传）。
///
/// ## ⚠️ 直读失败**必须能退**（2026-10-03 真机教训）
///
/// 之前这里是「二选一」：调用方拿到 [directUrl] 就只传它，于是**直读一旦
/// 打不开，这条路就到此为止** —— 而 `video_player` / `just_audio` 报出来的
/// 只有 `(0) source error` 一句（`code 0` = ExoPlayer 的 `TYPE_SOURCE`），
/// 看不出是地址、签名、还是播放器的问题。
/// 「传得上去、播不出来、还不说为什么」正是这一族缺陷的招牌。
/// 现在两样都给：直读打不开就退回「字节 → 落盘 → `file:`」，那条路只依赖
/// 我们已经跑通的 `GET images/file`（照片一直在用）。
///
/// ## 界面上会留一行「来源」
///
/// 播放器下面那行 10px 灰字（`直读` / `本地文件` + 失败过的那几条）**不要删**：
/// 这条链上有三四种失败长得一模一样，唯一的区分办法就是把它显示出来。
/// 真机排障全靠它 —— 见 `doc/open-items.md` B34。
Future<void> openAttachmentPlayer({
  required BuildContext context,
  required String title,
  required AttachmentKind kind,
  Uint8List? bytes,
  String? directUrl,
  Map<String, String> headers = const <String, String>{},
  Future<Uint8List?> Function()? loadBytes,
  String? mimeType,
}) {
  assert(
    bytes != null || directUrl != null,
    'openAttachmentPlayer 至少要给一种来源：字节，或直读地址',
  );
  return Get.dialog<void>(
    _AttachmentPlayerDialog(
      title: title,
      kind: kind,
      bytes: bytes,
      directUrl: directUrl,
      headers: headers,
      loadBytes: loadBytes,
      mimeType: mimeType,
    ),
    barrierColor: Colors.black87,
  );
}

class _AttachmentPlayerDialog extends StatelessWidget {
  const _AttachmentPlayerDialog({
    required this.title,
    required this.kind,
    required this.bytes,
    required this.directUrl,
    required this.headers,
    required this.loadBytes,
    required this.mimeType,
  });

  final String title;
  final AttachmentKind kind;
  final Uint8List? bytes;
  final String? directUrl;
  final Map<String, String> headers;
  final Future<Uint8List?> Function()? loadBytes;
  final String? mimeType;

  @override
  Widget build(BuildContext context) {
    final bytes = this.bytes;
    return Dialog(
      backgroundColor: Colors.black87,
      insetPadding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppBar(
            backgroundColor: Colors.transparent,
            automaticallyImplyLeading: false,
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, color: Colors.white),
            ),
            leading: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => popRoute(context),
            ),
          ),
          Flexible(
            child: switch (kind) {
              // 图片只有字节这一种来源（它 ≤8MB，且查看器那层已经缓存了字节）。
              AttachmentKind.image => InteractiveViewer(
                child: Image.memory(bytes!, fit: BoxFit.contain),
              ),
              AttachmentKind.audio => _AudioBody(
                bytes: bytes,
                directUrl: directUrl,
                headers: headers,
                loadBytes: loadBytes,
                fileName: title,
                mimeType: mimeType,
              ),
              AttachmentKind.video => _VideoBody(
                bytes: bytes,
                directUrl: directUrl,
                headers: headers,
                loadBytes: loadBytes,
                fileName: title,
              ),
            },
          ),
        ],
      ),
    );
  }
}

/// 音频：三种来源，**优先那两条不经本地代理的**。
///
/// | 给了什么 | 怎么播 | 什么时候会走到 |
/// |---|---|---|
/// | [directUrl] + [headers] | `setUrl` —— 请求头由 ExoPlayer 直接发 | 对象存储部署（生产） |
/// | [bytes] / [loadBytes]（原生） | 先落盘再 `setFilePath` —— `file:` 不经代理 | 直读打不开时的**退路** |
/// | [bytes]（Web） | `StreamAudioSource` —— just_audio 自己编成 data URL | 网页版 |
///
/// ⚠️ 三条路**都不经 just_audio 的本地明文代理**（Web 那条在 `_onLoad` 里
/// 由 `kIsWeb` 分支直接编 data URL）。这不是优化，是唯一能让音频在
/// `targetSdk >= 28` 的真机上播出来的前提 —— 展开见 `initState`。
///
/// ## 三条是**依次尝试**，不是「二选一」
///
/// 真机上直读那条曾经打不开（2026-10-03：「传上去了、就是播不出」），
/// 而当时 [directUrl] 一给，字节那条就再也没有机会 —— 整条链死在那里。
/// 现在：直读失败 → 退回落盘 → 再失败 → 退内存（只有 Web 会走到）。
///
/// 每一条的失败原因都记进 `_source` 并**显示在播放器下面**：这条链上
/// 「地址不对」「签名不对」「字节取不回」「就是解不了」在播放器里说的是
/// 同一句 `(0) source error`（`code 0` = ExoPlaybackException 的 TYPE_SOURCE），
/// 只有那一行分得开它们。
class _AudioBody extends StatefulWidget {
  const _AudioBody({
    required this.bytes,
    required this.directUrl,
    required this.headers,
    required this.loadBytes,
    required this.fileName,
    required this.mimeType,
  });

  final Uint8List? bytes;
  final String? directUrl;
  final Map<String, String> headers;
  final Future<Uint8List?> Function()? loadBytes;
  final String fileName;
  final String? mimeType;

  @override
  State<_AudioBody> createState() => _AudioBodyState();
}

class _AudioBodyState extends State<_AudioBody> {
  /// ⚠️ 不是 `final`：直读失败之后要**换一个干净的播放器**再退回落盘那条 ——
  ///    出错后的实例状态（平台侧已释放的解码器）不该带进下一次尝试。
  AudioPlayer _player = _newPlayer();

  String? _error;
  bool _ready = false;

  /// 面板已经关掉了。用来挡住「关掉之后又造了一个没人销毁的播放器」。
  bool _closed = false;

  /// 最终用的那条路 —— 连同**失败过的那几条**，显示在播放器下面。
  ///
  /// 为什么值得占一行界面：这条链上四种失败的文案完全相同，只有这里能分开。
  /// 真机排障全靠它，**不要删**。
  String? _source;

  /// 唯一的播放器构造点。⚠️ `useProxyForRequestHeaders: false` **不准删**。
  ///
  /// just_audio 默认（`true`）会把**带请求头**的播放交给它自己的本地 HTTP
  /// 代理：`just_audio.dart:2748-2753` 起一个 `http://127.0.0.1:<port>` 的服务，
  /// 再让 ExoPlayer 去请求它。而回环明文在 `targetSdk >= 28` 上被默认禁止，
  /// ExoPlayer 于是只报一句笼统的 `(0) source error` —— 真正的
  /// `CLEARTEXT communication to 127.0.0.1 not permitted` 被吞在 cause 里，
  /// 界面上看不见，所以它看起来像「音频文件坏了」或「解码不了」。
  ///
  /// 关掉之后请求头改由 ExoPlayer 自己发（`setDefaultRequestProperties`），
  /// **完全不经过本地代理** —— 与视频那条的 `networkUrl(httpHeaders:)` 同机制。
  ///
  /// ⚠️ `StreamAudioSource`（内存字节）**不受这个开关影响**：
  /// `just_audio.dart:3314` 里它是无条件走代理的。所以原生平台上「字节」那条
  /// 必须落盘成 `file:`（见 [_load]），不能指望这个开关救它。
  static AudioPlayer _newPlayer() =>
      AudioPlayer(useProxyForRequestHeaders: false);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// 依次尝试三条来源，**每一条失败都不放弃**。
  Future<void> _load() async {
    final failures = <String>[];
    String? used;

    // ① 直读：流式、不经函数、也不经本地代理。首选。
    final url = widget.directUrl;
    if (url != null) {
      try {
        await _player.setUrl(url, headers: widget.headers);
        used = '直读';
      } catch (error) {
        failures.add('直读 ${_shortError(error)}${await _probeDirectUrl(url)}');
        // 出错后的实例状态不带进下一次尝试。
        _discardPlayer();
      }
    }

    // ② 字节 → 临时文件（`file:`，同样不经代理）。
    // ③ 内存（只有 Web 会走到：那边没有文件系统，just_audio 自己编 data URL）。
    if (used == null) {
      final bytes = await _resolveBytes(widget.bytes, widget.loadBytes);
      if (bytes == null || bytes.isEmpty) {
        failures.add('字节取不回来');
      } else {
        try {
          final target = await writeTempAttachment(bytes, widget.fileName);
          if (target == null) {
            await _player.setAudioSource(
              _BytesAudioSource(bytes, widget.mimeType ?? 'audio/mpeg'),
            );
            used = '内存（网页版）';
          } else {
            await _player.setFilePath(target);
            used = '本地文件';
          }
        } catch (error) {
          failures.add('本地文件 ${_shortError(error)}');
        }
      }
    }

    if (!mounted) return;
    final picked = used;
    if (picked == null) {
      setState(() => _error = failures.isEmpty ? '没有可用的来源' : failures.join('；'));
      return;
    }
    setState(() {
      _ready = true;
      // 一路顺畅时只显示「直读」；失败过才把那几条挂上去。
      _source = failures.isEmpty ? picked : '$picked（${failures.join('；')}）';
    });
    // 打开就播：学生点开一个录音，想看的就是「它是不是我录的那段」。
    // 还要再点一次播放键属于多余的一步。
    unawaited(_player.play());
  }

  /// 播放器打不开直读地址时，用**我们自己的** HTTP 栈再问一次对象存储。
  ///
  /// 它把「地址 / 签名不对」与「播放器不对」分成两类 —— 而这两类在界面上
  /// 是同一句话。只取 2 个字节，且只在失败之后跑，正常播放不受影响。
  Future<String> _probeDirectUrl(String url) async {
    if (kIsWeb) return '';
    try {
      final res = await http
          .get(Uri.parse(url), headers: {...widget.headers, 'range': 'bytes=0-1'})
          .timeout(const Duration(seconds: 8));
      return '（自测 HTTP ${res.statusCode}）';
    } catch (error) {
      return '（自测 ${_shortError(error)}）';
    }
  }

  /// 换一个干净的播放器：出错后的实例状态（平台侧可能已经释放了解码器）
  /// 不该带进下一次尝试。
  ///
  /// **先换引用、再销毁旧的** —— 这样 [dispose] 无论何时跑，销毁的都是
  /// 「当时那个」，既不会漏销毁、也不会销毁两次。（`dispose` 与这里都是
  /// 同步跑完的，Dart 单线程 ⇒ 不存在交错。）
  void _discardPlayer() {
    final old = _player;
    _player = _newPlayer();
    if (_closed) {
      // 面板已经关了：刚造的这个没人会用，就地销毁；旧的由 `dispose` 负责。
      unawaited(_player.dispose());
      return;
    }
    unawaited(old.dispose());
  }

  @override
  void dispose() {
    // ⚠️ 顺序不能反：先置 `_closed` 再销毁 `_player` —— [_discardPlayer] 靠
    //    这个标志判断「刚造的那个播放器没人用」。
    _closed = true;
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _PlaybackMessage(
        text: '这段音频播放不了（播放器 $kAttachmentPlayerBuild）：$_error',
      );
    }
    final bytes = widget.bytes;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.audiotrack, size: 56, color: Colors.white70),
          const SizedBox(height: 12),
          Text(
            // 直读那条路的字节不经我们的手，拿不到文件大小 —— 用时长代替。
            bytes != null
                ? AttachmentLimits.humanSize(bytes.length)
                : _friendlyDuration(_player.duration),
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          const SizedBox(height: 12),
          if (!_ready)
            const CircularProgressIndicator()
          else
            StreamBuilder<Duration>(
              stream: _player.positionStream,
              builder: (context, snapshot) {
                final position = snapshot.data ?? Duration.zero;
                final total = _player.duration ?? Duration.zero;
                return Column(
                  children: [
                    // ⚠️ 用**总量**做分母前先确认它不是 0：不定长音频（部分
                    //    容器头里没写时长）会让 `position / total` 得到 NaN，
                    //    而 NaN 喂给 `value:` 会让进度条**整个不显示**。
                    Slider(
                      value: total.inMilliseconds == 0
                          ? 0
                          : (position.inMilliseconds / total.inMilliseconds)
                                .clamp(0.0, 1.0),
                      onChanged: total.inMilliseconds == 0
                          ? null
                          : (v) => _player.seek(
                              Duration(
                                milliseconds:
                                    (v * total.inMilliseconds).round(),
                              ),
                            ),
                    ),
                    StreamBuilder<PlayerState>(
                      stream: _player.playerStateStream,
                      builder: (context, snapshot) {
                        final playing =
                            snapshot.data?.playing ?? _player.playing;
                        return IconButton(
                          iconSize: 40,
                          color: Colors.white,
                          icon: Icon(
                            playing ? Icons.pause_circle : Icons.play_circle,
                          ),
                          onPressed: () =>
                              playing ? _player.pause() : _player.play(),
                        );
                      },
                    ),
                    const SizedBox(height: 4),
                    if (_source != null)
                      Text(
                        // ⚠️ 这一行不要删。直读 / 本地文件 / 内存三条路失败时
                        //    播放器报的是同一句话，只有这里分得开是哪一条、
                        //    以及之前失败过什么（见 B34）。
                        _source!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white38,
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

/// 把内存里的一段音频交给 `just_audio`。
///
/// ⚠️ 它只服务**网页版**。原生平台上这个源**必然经过 just_audio 的本地明文
/// 代理**（`just_audio.dart:3314` 是无条件走代理的，`useProxyForRequestHeaders`
/// 那个开关管不到它），而回环明文在 `targetSdk >= 28` 上打不开 ⇒ 症状是
/// 所有音频都报 `(0)source error`。原生平台的字节必须先落盘成 `file:`，
/// 见 `_AudioBodyState._load`。
class _BytesAudioSource extends StreamAudioSource {
  _BytesAudioSource(this._bytes, this._contentType);

  final Uint8List _bytes;
  final String _contentType;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    // 越界的 start/end 必须夹回来：播放器在结尾附近会请求一个刚好超出
    // 长度的区间，直接 sublist 会抛 `RangeError` —— 症状是「快播完时崩」。
    final from = (start ?? 0).clamp(0, _bytes.length);
    final to = (end ?? _bytes.length).clamp(from, _bytes.length);
    return StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: to - from,
      offset: from,
      stream: Stream<List<int>>.value(_bytes.sublist(from, to)),
      contentType: _contentType,
    );
  }
}

/// 视频：两种来源，优先**流式直读**，退路是「字节先落盘」。
///
/// | 给了什么 | 怎么播 | 什么时候会走到 |
/// |---|---|---|
/// | [directUrl] + [headers] | `VideoPlayerController.networkUrl` —— 边下边播 | 对象存储部署（生产） |
/// | [bytes] / [loadBytes] | 先落盘再 `file:`（见 `video_source_io.dart`） | 直读打不开时的退路、`IMAGE_DRIVER=fs`、Web 端 |
///
/// 直读那条不只是「更快」：函数计算的响应体上限是 32 MiB，而视频上限
/// 100 MB —— 走字节那条路时，超过 32 MiB 的视频**取不回来**
/// （`doc/open-items.md` B32）。所以这里不是「优化」，是那条尺寸下唯一的活路。
///
/// ⚠️ 但**先直读不等于只有直读**：直读打不开时必须退回落盘那条，否则
/// 一个签错/过期的地址就能让整段视频「点了没反应」。真机上出过这个形态
/// （2026-10-03），两条都留着。
class _VideoBody extends StatefulWidget {
  const _VideoBody({
    required this.bytes,
    required this.directUrl,
    required this.headers,
    required this.loadBytes,
    required this.fileName,
  });

  final Uint8List? bytes;
  final String? directUrl;
  final Map<String, String> headers;
  final Future<Uint8List?> Function()? loadBytes;
  final String fileName;

  @override
  State<_VideoBody> createState() => _VideoBodyState();
}

class _VideoBodyState extends State<_VideoBody> {
  VideoPlayerController? _controller;
  String? _error;

  /// 最终用的那条路 + 之前失败过的那几条，显示在画面下面。见 B34。
  String? _source;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// 先试直读，失败退回落盘 —— **不放弃**。
  Future<void> _load() async {
    final failures = <String>[];
    VideoPlayerController? controller;
    String? used;

    final url = widget.directUrl;
    if (url != null) {
      try {
        controller = await _controllerFromUrl(url, widget.headers);
        used = '直读';
      } catch (error) {
        failures.add('直读 ${_shortError(error)}${await _probeDirectUrl(url)}');
      }
    }

    if (controller == null) {
      final bytes = await _resolveBytes(widget.bytes, widget.loadBytes);
      if (bytes == null || bytes.isEmpty) {
        failures.add('字节取不回来');
      } else {
        try {
          controller = await videoControllerFromBytes(bytes, widget.fileName);
          used = '本地文件';
        } catch (error) {
          failures.add('本地文件 ${_shortError(error)}');
        }
      }
    }

    if (!mounted) {
      // 面板已经被关掉了：这个控制器必须在这里销毁 —— 它持有一个
      // 平台侧的解码器，漏掉就是一份**继续解码的**资源。
      final opened = controller;
      if (opened != null) unawaited(opened.dispose());
      return;
    }

    final opened = controller;
    if (opened == null) {
      setState(() => _error = failures.isEmpty ? '没有可用的来源' : failures.join('；'));
      return;
    }
    setState(() {
      _controller = opened;
      _source = failures.isEmpty ? used : '$used（${failures.join('；')}）';
    });
    unawaited(opened.play());
  }

  /// 见 `_AudioBodyState._probeDirectUrl` —— 把「地址不对」与「播放器不对」
  /// 分开。视频这条更容易撞上：**凭证 15 分钟就过期**。
  Future<String> _probeDirectUrl(String url) async {
    if (kIsWeb) return '';
    try {
      final res = await http
          .get(Uri.parse(url), headers: {...widget.headers, 'range': 'bytes=0-1'})
          .timeout(const Duration(seconds: 8));
      return '（自测 HTTP ${res.statusCode}）';
    } catch (error) {
      return '（自测 ${_shortError(error)}）';
    }
  }

  /// 直接从对象存储播：**流式**，不把整段字节读进内存。
  ///
  /// ⚠️ [headers] 是签名的一部分（桶是私有的），**一个都不能挑、不能改** ——
  /// 少一个就是 403，而那个错误看起来像密钥配错了。
  ///
  /// ⚠️ 播放器会自己发 `Range` 请求（拖动进度、以及边下边播的分段都是它）。
  /// `Range` **不在签名头里**（见服务端 `isSignedHeader`），所以同一份
  /// `authorization` 对每一个分段请求都有效 —— 这正是复用头部签名而不是
  /// 查询串签名的额外好处。
  ///
  /// ⚠️ 凭证 15 分钟过期（`expiresIn`）：慢到超过它的播放会中途 403，
  /// 那种失败只能重新签一次，不能原地重试。见服务端 `signDirectGet`。
  static Future<VideoPlayerController> _controllerFromUrl(
    String url,
    Map<String, String> headers,
  ) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      throw ArgumentError('直读地址不是合法 URL：$url');
    }
    final controller = VideoPlayerController.networkUrl(
      uri,
      httpHeaders: headers,
    );
    await controller.initialize();
    return controller;
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return _PlaybackMessage(
        text: error.contains('web_has_no_local_file')
            ? '网页版暂不支持内联播放视频，请在手机 App 里打开这条作业。'
            : '这段视频播放不了（播放器 $kAttachmentPlayerBuild）：$error',
      );
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Padding(
        padding: EdgeInsets.all(40),
        child: CircularProgressIndicator(),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: controller.value.aspectRatio,
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              VideoPlayer(controller),
              // ⚠️ `VideoPlayerController` 是 `ValueNotifier<VideoPlayerValue>`，
              //    **不是** Stream —— 写成 `StreamBuilder(stream: controller)`
              //    编不过。这个区别在 `video_player` 的文档里不显眼，
              //    但错法只有一种，编译器会直接拦下。
              ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: controller,
                builder: (context, value, _) {
                  final playing = value.isPlaying;
                  return IconButton(
                    iconSize: 44,
                    color: Colors.white,
                    icon: Icon(
                      playing ? Icons.pause_circle : Icons.play_circle,
                    ),
                    onPressed: () =>
                        playing ? controller.pause() : controller.play(),
                  );
                },
              ),
            ],
          ),
        ),
        if (_source != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 8, right: 8),
            child: Text(
              // ⚠️ 这一行不要删。直读 / 本地文件两条路失败时播放器报的是
              //    同一句话，只有这里分得开是哪一条、以及之前失败过什么。
              _source!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10, color: Colors.white38),
            ),
          ),
      ],
    );
  }
}

class _PlaybackMessage extends StatelessWidget {
  const _PlaybackMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.info_outline, size: 32, color: Colors.white70),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Colors.white),
          ),
          const SizedBox(height: 6),
          const Text(
            // 附件的字节已经存下来了 —— 这一句是给「换个地方再看」用的。
            '附件本身已经保存，换个设备也能查看。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

/// `m:ss`。时长还没解析出来（网络源刚打开那一下）时回空串，
/// 界面宁可显示一行空白，也不要闪一个 `0:00` —— 那看着像音频是空的。
String _friendlyDuration(Duration? duration) {
  if (duration == null) return '';
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds.remainder(60);
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// 取字节：手上有就直接用，没有才去调那个**懒加载**回调。
///
/// 为什么要有这个回调：直读优先时调用方手里并没有字节，而「字节 → 落盘」
/// 是**退路** —— 让它先跑就等于每次都要先把整段下下来（视频 100 MB），
/// 只有真走到那一步时才值得付这个代价。
Future<Uint8List?> _resolveBytes(
  Uint8List? inline,
  Future<Uint8List?> Function()? loader,
) async {
  if (inline != null) return inline;
  return loader?.call();
}

/// 把异常压成一行 —— 界面上那行只有几个字的位置，全文属于日志。
String _shortError(Object error) {
  final text = '$error'.replaceAll('\n', ' ').trim();
  return text.length <= 90 ? text : '${text.substring(0, 87)}…';
}
