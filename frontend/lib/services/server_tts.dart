import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../controllers/auth_controller.dart';
import 'ai_api_client.dart';
import 'ai_config.dart';
import 'database_service.dart';
import 'edge_tts_client.dart';
import 'speech_rate.dart';
import 'tts_audio_cache.dart';
import 'tts_chunk_feed.dart';
import 'tts_chunker.dart';
import 'tts_voice.dart';

/// 伴读的三种状态。UI 靠它切换按钮文案 —— 不能只用「响没响」两态：
/// 合成一篇 2000 字的课文要几秒，那几秒里既不是「在响」也不是「没开始」。
enum ServerSpeechState { idle, preparing, playing }

/// 服务端伴读失败。**这条消息是要给学生看的**，不是日志。
class ServerTtsException implements Exception {
  const ServerTtsException(this.message, {this.code = ''});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// 「伴读」的服务端语音合成播放器。
///
/// ## 为什么不走系统 TTS
///
/// 学生那台机器是鸿蒙 NEXT + 卓易通。鸿蒙自家的朗读能力（CoreSpeechKit）只给
/// ArkTS 原生应用；卓易通那个容器**没有实现安卓的 `TextToSpeechService`**。
/// 端上 `TextToSpeech.speak()` 会把主线程卡十几秒然后超时（真机实测：
/// 先是「朗读引擎没有响应」，改成受理即返回后是「系统语音服务 10 秒没有回应」）。
/// 也就是说，这不是参数问题，是那台设备上**根本没有这条路**。
///
/// 所以伴读改成：文字发到网关 → 百炼 `qwen3-tts-flash` 合成 → 客户端只负责播放。
/// 与设备有没有 TTS 引擎完全无关，音质也比系统 TTS 好得多。
///
/// ## 为什么是流式播 URL，而不是先下载成文件
///
/// `qwen3-tts-flash` **只产出 wav**（24kHz/16bit/单声道 ≈ 48KB 每秒），
/// 传 `format: mp3` 与 `sample_rate` 都不生效（2026-11-07 实测：
/// 1224 字 → 3 段、第一段 1.65MB）。一篇课文 1~2MB。
///
/// 先下载完再播的代价是「点一下等十几秒才出声」，而且每次都占一份存储。
/// 直接 `AudioSource.uri` 边下边播，首句几乎立刻开始，存储占用为零。
/// 代价是每次播放都走一遍流量 —— 对一天听两三次的使用频率来说，
/// 这笔账比「等」划算。
///
/// 合成结果按「语言 + 全文」缓存 **12 小时**：厂商返回的地址 24 小时后失效，
/// 缓存太久会出现「昨天能听、今天点了没反应」这种没人能想到的失败。
///
/// ## 取音频的三层（2026-11-07 起）
///
/// ```
/// ① 本地文件命中   → 完全不联网（断网也能听）
/// ② 手机直连微软   → 分块合成，第一块好了就出声，其余边播边合成
/// ③ 直连失败       → 静默退回网关 /ai/tts（孩子无感）
/// ```
///
/// 第 ② 层不是锦上添花：网关那条要一次合成整篇（1376 字符 11.4 秒），
/// 而直连整篇 4822 字符才 15.9 秒、0 成本。切成块之后首声只等约 200 字符。
///
/// ## 语速（11-08）
///
/// 正常 / 慢速由 [SpeechRateSettings] 单点持有，在这里落到 `AudioPlayer.setSpeed`。
/// **不重合成、不分缓存、不惊动服务端**：音频字节跟档位无关，切档时若正在播，
/// 直接改播放器的倍率，孩子立刻听得出来；离线缓存的那篇也一样能慢。
/// 详情（为什么不走 SSML rate）写在 `speech_rate.dart` 的类注释里。
///
/// ## 音色与来源（11-08）
///
/// **男声 = 本机（缓存 / 直连微软），女声 = 云端 Qwen 兜底**，见 `tts_voice.dart`。
/// 与语速不同，音色写进了音频字节，所以 [digestOf] 必须带音色版本，
/// 且网关兜底那次不再把 wav 落进本地槽 —— 否则旧女声文件会被当成男声命中。
class ServerTts {
  ServerTts._();

  static final ValueNotifier<ServerSpeechState> state =
      ValueNotifier<ServerSpeechState>(ServerSpeechState.idle);

  /// 最近一次失败原因。UI 读完置空 —— 和 `TtsService.error` 同一个约定。
  static final ValueNotifier<String?> error = ValueNotifier<String?>(null);

  static AudioPlayer? _player;
  static StreamSubscription<PlayerState>? _stateSub;
  static int _generation = 0;

  /// 音频字节的本地副本。测试替换它就能脱离文件系统。
  @visibleForTesting
  static TtsAudioCache audioCache = TtsAudioCache();

  /// 直连微软朗读接口的客户端。测试替换它就能脱离网络。
  @visibleForTesting
  static EdgeTtsClient edgeClient = const EdgeTtsClient();

  /// 测试接缝：替换真正的 `AudioPlayer.setSpeed`。
  ///
  /// 播放器在 widget 测试里起不来（没有平台通道），但「慢速到底有没有
  /// 传到播放层」是必须盯住的判据，所以留这一个函数类型的口子。
  @visibleForTesting
  static Future<void> Function(double speed)? setSpeedForTest;

  /// 语速变化监听只挂一次（静态类没有 initState）。
  static bool _rateWired = false;

  /// 直连失败后的冷却截止时间。**一次失败就停一会儿**，别每次点「伴读」
  /// 都先等一次超时才轮到网关 —— 那会让人以为功能坏了。
  static DateTime? _directDownUntil;

  /// 后台还在补后面的块。用来分辨「这一块放完了」和「整篇读完了」：
  /// 前者的 `completed` 是合唱中间的换气，不是结束。
  static bool _feedBusy = false;

  /// 合成一篇课文的上限。网关那边同步调厂商，2000 字大约 3~6 秒；
  /// 给到 60 秒是为了扛住弱网 —— 超时就报「服务连不上」，别让学生干等。
  static const Duration _requestTimeout = Duration(seconds: 60);

  /// 音频地址的缓存时长。厂商的地址 24 小时失效，这里取一半。
  static const Duration _urlTtl = Duration(hours: 12);

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static bool get isBusy => state.value != ServerSpeechState.idle;

  /// 测试接缝：替换真正的「请求网关 + 播放」。
  ///
  /// 生产代码永远不设置它。没有它的话，阅读页的 widget 测试要连真网关、
  /// 真调 just_audio —— 两条都需要网络或设备。
  /// 测试里由假实现自己把 [state] 设成 [ServerSpeechState.playing]。
  @visibleForTesting
  static Future<void> Function(String text, String language)? speakForTest;

  /// 朗读一段文字。返回时**已经开始播放**。
  ///
  /// [language] 只认 `en` / `zh`：厂商的 `language_type` 是个闭集，
  /// 猜错的后果是英文课文被当中文、按拼音念出来 —— 有声音，但一句听不懂。
  static Future<void> speak(String text, {String language = 'en'}) async {
    if (!isSupported) {
      throw const ServerTtsException('网页版不支持伴读，请在手机上使用');
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const ServerTtsException('这一篇还没有可朗读的正文');
    }

    await stop();
    final generation = ++_generation;
    state.value = ServerSpeechState.preparing;
    error.value = null;
    _wireRate();

    // 语速**只在这里定一次**，且必须放在 `speakForTest` 分支之前：
    // 判据盯住的这一次调用，就是生产路径真正落到播放器的那一次。
    // 测试里 `speakForTest` 不为空 → 不建播放器，走 `setSpeedForTest` 接缝；
    // 生产里先把播放器建好再设倍率（just_audio 加载音源时会补设一次 speed）。
    final testSpeak = speakForTest;
    await _applySpeed(
      player: testSpeak == null ? (_player ??= AudioPlayer()) : null,
    );

    if (testSpeak != null) {
      await testSpeak(trimmed, language);
      return;
    }

    try {
      final plan = await _prepare(trimmed, language, generation);
      if (generation != _generation) return;
      await _play(plan, generation);
    } catch (cause) {
      if (generation == _generation) {
        state.value = ServerSpeechState.idle;
      }
      rethrow;
    }
  }

  /// 停止播放。**任何失败都不能阻断它** —— 停不下来比播错更糟。
  static Future<void> stop() async {
    _generation++;
    _feedBusy = false;
    state.value = ServerSpeechState.idle;
    speechSource.value = null;
    await _stateSub?.cancel();
    _stateSub = null;
    try {
      await _player?.stop();
    } catch (cause) {
      debugPrint('停止伴读失败（忽略）：$cause');
    }
  }

  /// 把当前档位落到播放器。
  ///
  /// [player] 为空表示「这次还没有播放器」：不创建、不报错，等 [_play]
  /// 建好播放器再设一次。测试里 [setSpeedForTest] 优先于真实播放器。
  ///
  /// 设不上不能静默：慢速没生效却显示「慢速」正是本项目最怕的那种
  /// 「功能安静地不对」，所以写一条 [error] 让页面提示（播放照常继续）。
  static Future<void> _applySpeed({AudioPlayer? player}) async {
    final speed = SpeechRateSettings.current.value.speed;
    final hook = setSpeedForTest;
    if (hook != null) {
      try {
        await hook(speed);
      } catch (cause) {
        debugPrint('测试接缝设置语速失败：$cause');
      }
      return;
    }

    final target = player ?? _player;
    if (target == null) return;
    try {
      await target.setSpeed(speed);
    } catch (cause) {
      debugPrint('设置伴读语速失败（按正常速度继续）：$cause');
      if (speed != 1.0) {
        error.value = '这台设备没能切成慢速，这次先按正常语速朗读';
      }
    }
  }

  /// 念到一半切档也要立刻变：监听挂在语速状态上，而不是只在 [speak] 里读一次。
  static void _wireRate() {
    if (_rateWired) return;
    _rateWired = true;
    SpeechRateSettings.current.addListener(() {
      unawaited(_applySpeed());
    });
  }

  /// 决定这一篇从哪儿出声：**本地有就完全不联网**，没有才请求网关。
  ///
  /// 「先本地后网络」和「网络失败再退回本地」不是一回事：前者断网秒开，
  /// 后者要先等一次 60 秒超时 —— 学生只会以为伴读坏了。
  static Future<_AudioPlan> _prepare(
    String text,
    String language,
    int generation,
  ) async {
    final digest = digestOf(text, language);

    final local = await audioCache.lookup(digest);
    if (local != null && local.isNotEmpty) {
      return _AudioPlan(
        digest: digest,
        files: local,
        source: TtsAudioSource.local,
      );
    }

    // 直连优先：手机自己连微软，0 成本、音色是神经网络那套，比网关那条快。
    // 失败就静默退回网关 —— 孩子不该看到「接口 403」这种东西。
    final direct = await _tryDirect(text, language, digest);
    if (direct != null) return direct;

    final List<String> urls;
    try {
      urls = await _ensureUrls(text, language, generation);
    } on ServerTtsException catch (e) {
      // 本地没有副本 + 连不上 = 这一篇从没在本机存过。
      // 说「连不上朗读服务」会让人去查网络，而真正的原因是这篇还没缓存过。
      if (e.code == 'transport_error' || e.code == 'timeout') {
        throw const ServerTtsException(
          '这一篇的语音还没存到本机，需要联网加载一次',
          code: 'not_cached_offline',
        );
      }
      rethrow;
    }
    if (urls.isEmpty) {
      throw const ServerTtsException('这一篇还没有可朗读的正文');
    }
    return _AudioPlan(
      digest: digest,
      urls: urls,
      source: TtsAudioSource.cloud,
    );
  }

  /// 直连微软朗读接口，**只等第一块合成好**就返回。
  ///
  /// 整篇一次合成要 15.9 秒（书里最长那一课 4822 字符，2026-11-07 实测），
  /// 学生点完按钮愣十几秒才出声。切成块之后首声只等第一块（约 200 字符），
  /// 后面的块边播边合成 —— 见 [TtsChunkFeed]。
  ///
  /// 任何失败都返回 null 静默降级。熔断分两档：算法/UA 被拒（403）短期
  /// 不会自己好，停 30 分钟；网络类问题可能马上恢复，停 2 分钟。
  static Future<_AudioPlan?> _tryDirect(
    String text,
    String language,
    String digest,
  ) async {
    if (language != 'en') return null;

    final downUntil = _directDownUntil;
    if (downUntil != null && DateTime.now().isBefore(downUntil)) return null;

    final chunks = splitForSpeech(text);
    if (chunks.isEmpty) return null;

    // 上次听到一半留下的块直接复用，不重合成。
    final ready = await audioCache.existingChunks(digest);
    final feed = TtsChunkFeed(
      digest: digest,
      chunks: chunks,
      language: language,
      synthesize: (body, lang) => edgeClient.synthesize(
        text: body,
        language: lang,
        // 显式给男声，别只靠 voiceFor 的默认值：这个参数是「来源约定」的
        // 一部分，写在这里才看得见它跟本地缓存用的是同一个音色。
        voice: TtsVoices.localVoiceFor(lang),
      ),
      cache: audioCache,
      ready: ready,
    );

    final first = await feed.next();
    if (first == null) {
      // 第一块就拿不到 = 这条路现在不通。把原因留给熔断逻辑，
      // 别在这里把它翻成人话 —— 上层要看的是 code。
      final cause = feed.cause;
      if (cause is EdgeTtsException) {
        _markDirectDown(cause);
      } else if (cause != null) {
        _directDownUntil = DateTime.now().add(const Duration(minutes: 2));
        debugPrint('直连朗读异常，退回网关：$cause');
      }
      return null;
    }

    return _AudioPlan(
      digest: digest,
      files: [first],
      pending: feed.finished ? null : feed,
      source: TtsAudioSource.direct,
    );
  }

  static void _markDirectDown(EdgeTtsException e) {
    final fatal = e.code == 'forbidden' || e.code == 'handshake';
    _directDownUntil = DateTime.now().add(
      fatal ? const Duration(minutes: 30) : const Duration(minutes: 2),
    );
    debugPrint('直连朗读不可用（${e.code}），退回网关：$e');
  }

  @visibleForTesting
  static void resetDirectCooldown() => _directDownUntil = null;

  /// 「语言 + **音色版本** + 全文」的 sha256。
  ///
  /// 用文本而不是 lessonId 做键，是因为重导入可能换掉同一课的内容 ——
  /// 拿旧音频去配新课文，孩子听到的是另一篇文章，而界面上没有任何异常。
  ///
  /// ⚠️ **语速刻意不进这个键**：慢速是播放层的倍率，音频字节没变。
  /// 把 rate 拼进来会变成「切一次慢速整篇重合成 + 断网时慢速没音频」，
  /// 那是把一个简单的偏好做成一次功能缺失。
  ///
  /// ⚠️ **音色必须进这个键**：它写在音频字节里。v1 是 Aria 女声，11-08
  /// 起本地改 Guy 男声；沿用旧键会让升级后第一次点「伴读」直接命中旧
  /// 女声文件，孩子（和排查问题的家长）会误判成「又走 Qwen 了」。
  /// 见 `tts_voice.dart`：换音色一定要 bump [TtsVoices.cacheSchema]。
  @visibleForTesting
  static String digestOf(String text, String language) => sha256
      .convert(utf8.encode('$language\n${TtsVoices.cacheSchema}\n$text'))
      .toString();

  /// 拿这一篇的音频地址：优先用 URL 缓存（省一次合成），过期才请求网关。
  static Future<List<String>> _ensureUrls(
    String text,
    String language,
    int generation,
  ) async {
    final file = await _cacheFile(text, language);

    final cached = await _readCache(file);
    if (cached != null) return cached;

    final urls = await _requestSegments(text, language);
    if (generation != _generation) return const <String>[];
    await _writeCache(file, language, urls);
    return urls;
  }

  static Future<File> _cacheFile(String text, String language) async {
    final root = await getTemporaryDirectory();
    return File('${root.path}/tts/${digestOf(text, language)}.json');
  }

  static Future<List<String>?> _readCache(File file) async {
    if (!await file.exists()) return null;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return null;
      final at = DateTime.tryParse('${raw['at'] ?? ''}');
      if (at == null || DateTime.now().difference(at) > _urlTtl) return null;
      final urls = (raw['urls'] as List?)?.map((e) => '$e').where((e) => e.isNotEmpty);
      if (urls == null || urls.isEmpty) return null;
      return urls.toList();
    } catch (cause) {
      // 缓存坏了不是错误，重合成一遍就是 —— 但别让坏文件继续被读到。
      debugPrint('伴读缓存读不出来，重新合成：$cause');
      return null;
    }
  }

  static Future<void> _writeCache(File file, String language, List<String> urls) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'language': language,
          'urls': urls,
          'at': DateTime.now().toIso8601String(),
        }),
        flush: true,
      );
    } catch (cause) {
      // 写不进去只意味着下次要重新合成一次，不该让这次朗读失败。
      debugPrint('伴读缓存写不进去（忽略）：$cause');
    }
  }

  /// 交给网关的请求体。
  ///
  /// 抽出来是为了让判据能盯住 `voice`：它是「女声 = 云端」这条约定的一半，
  /// 直接内联在 `_requestSegments` 里的话，删掉它不会有任何测试变红。
  @visibleForTesting
  static Map<String, dynamic> ttsBodyFor(String text, String language) => {
        'text': text,
        'language': language,
        // 显式带女声：网关的 BAILIAN_TTS_VOICE 若被覆盖成男声，
        // 「女声 = 云端」这条约定就断了。客户端单点钉住它。
        'voice': TtsVoices.cloudFemale,
      };

  /// 向网关要音频地址列表。
  static Future<List<String>> _requestSegments(String text, String language) async {
    final client = _newClient();
    late final Map<String, dynamic> data;
    try {
      data = await client.postJson(
        AiEndpoints.tts,
        ttsBodyFor(text, language),
        timeout: _requestTimeout,
      );
    } on AiRequestException catch (e) {
      throw ServerTtsException(_humanize(e), code: e.code);
    } finally {
      client.close();
    }

    final raw = data['segments'];
    if (raw is! List || raw.isEmpty) {
      // 200 但没有段落，是本项目里典型的「静默失败」形状：不报错，也没声音。
      throw const ServerTtsException('朗读服务没有返回音频，请稍后再试', code: 'no_segments');
    }
    final urls = <String>[];
    for (final item in raw) {
      final url = item is Map ? '${item['url'] ?? ''}' : '';
      if (url.isEmpty) {
        throw const ServerTtsException('朗读服务返回的音频地址不完整，请稍后再试');
      }
      urls.add(url);
    }
    return urls;
  }

  static Future<void> _play(_AudioPlan plan, int generation) async {
    final player = _player ??= AudioPlayer();
    final pending = plan.pending;

    if (pending != null) {
      // 边播边合成：先只放第一块，剩下的用 `addAudioSource` 往后接。
      await player.setAudioSource(AudioSource.file(plan.files!.first.path));
    } else {
      final sources = plan.files != null
          ? plan.files!.map((file) => AudioSource.file(file.path)).toList()
          : plan.urls!.map((url) => AudioSource.uri(Uri.parse(url))).toList();
      await player.setAudioSources(sources);
    }
    if (generation != _generation) return;

    // 再定一次倍率（幂等）：合成这几秒里孩子可能切了档，而 [speak] 里
    // 那次设的是开播前的旧值。放在 play() 之前是最没有歧义的位置。
    await _applySpeed(player: player);
    if (generation != _generation) return;

    // ⚠️ 11-08 起网关兜底**不再把 wav 落到本机**：那会让「本地缓存槽」
    // 混进女声，下次断网命中本地时听起来像走了云端。取舍见 tts_voice.dart。
    // 主路直连的块仍由 TtsChunkFeed 照常落盘，断网可听不受影响。
    state.value = ServerSpeechState.playing;
    speechSource.value = plan.source;
    await _stateSub?.cancel();
    _stateSub = player.playerStateStream.listen((event) {
      if (event.processingState != ProcessingState.completed) return;
      if (state.value != ServerSpeechState.playing) return;
      // 还有块在路上时，这一块的 `completed` 只是换气 —— 报「读完了」
      // 会让按钮提前变回「伴读」，孩子以为读漏了。
      if (_feedBusy) return;
      state.value = ServerSpeechState.idle;
    });

    // 先立旗再开播：第一块可能很短，`completed` 说不定比补块的协程先到。
    if (pending != null) _feedBusy = true;

    // 不 await：`play()` 要到整篇播完才返回，await 会把「开始播放」这件事
    // 拖成一整个 Future —— 点按钮那一刻就永远等不到返回。
    unawaited(player.play().catchError((Object cause) {
      debugPrint('伴读播放中断：$cause');
      if (state.value == ServerSpeechState.playing) {
        state.value = ServerSpeechState.idle;
        // `speak()` 早就返回了（它只保证「已经开始播」），所以这条失败
        // 没有 await 可以抛 —— 只能走 notifier 让页面弹一次。
        error.value = '伴读中断了，请再点一次';
      }
    }));

    if (pending != null) unawaited(_feed(player, pending, generation));
  }

  /// 一边播一边把后面的块接上去。
  ///
  /// 三个必须留神的地方：
  ///  · **播放可能跑在合成前面**：网络慢时第一块放完了、第二块还没好，
  ///    队列停在 `completed`，之后补上的块不会自己接着播 —— 要显式挪指针。
  ///  · **失败要停下**，不能假装还在读：孩子听到一半突然没声，比一开始
  ///    就提示「连不上」更让人困惑。
  ///  · **换课/暂停时立刻收手**：`generation` 变了就什么都不做，否则上一课
  ///    的音频会被接进新课文里。
  static Future<void> _feed(
    AudioPlayer player,
    TtsChunkFeed feed,
    int generation,
  ) async {
    try {
      while (true) {
        if (generation != _generation) return;
        final file = await feed.next();
        if (generation != _generation) return;

        if (file == null) {
          if (feed.failed) {
            final cause = feed.cause;
            if (cause is EdgeTtsException) _markDirectDown(cause);
            _interrupt('这一篇没念完，网络断了，请再点一次');
          }
          return;
        }

        final nextIndex = (player.currentIndex ?? 0) + 1;
        try {
          await player.addAudioSource(AudioSource.file(file.path));
        } catch (cause) {
          debugPrint('后续音频接不上：$cause');
          _interrupt('这一篇没念完，请再点一次');
          return;
        }

        if (player.processingState == ProcessingState.completed) {
          try {
            await player.seek(Duration.zero, index: nextIndex);
            if (!player.playing) unawaited(player.play());
          } catch (cause) {
            debugPrint('续播失败：$cause');
          }
        }
      }
    } finally {
      if (generation == _generation) _feedBusy = false;
    }
  }

  /// 读到一半停下的提示。只在**这次朗读还在进行**时才提示 ——
  /// 换课/退出时的收尾不该弹窗。
  static void _interrupt(String message) {
    if (state.value != ServerSpeechState.playing) return;
    state.value = ServerSpeechState.idle;
    error.value = message;
  }

  static AiApiClient _newClient() {
    final auth = Get.isRegistered<AuthController>()
        ? Get.find<AuthController>()
        : null;
    return AiApiClient(
      config: AiConfig.resolve(),
      // 身份必须取自**同一份会话**（见 `AiIdentity.resolve` 的注释）：
      // 另建一份的后果是登录把票写进 A、这里从 B 取，票永远取不到。
      identity: AiIdentity.resolve(
        session: DatabaseService.cloud?.api.session,
        localUserId: auth?.currentUser.value?.id,
      ),
    );
  }

  /// 把网关的错误码翻成学生能懂的一句话。
  ///
  /// 不直接铺 `e.userMessage`：网关有几条文案是写给运维的
  /// （「请检查 BAILIAN_API_KEY」），学生看了只会一头雾水。
  static String _humanize(AiRequestException e) => switch (e.code) {
    'model_not_enabled' => '服务器上还没有开通语音朗读，暂时听不了',
    'model_auth_failed' => '朗读服务的凭证失效了，需要管理员处理',
    'model_timeout' || 'timeout' => '朗读准备超时了，请检查网络后再试',
    'transport_error' => '连不上朗读服务，请检查网络',
    'quota_exhausted' => '今天的 AI 额度用完了，明天再试',
    _ => '朗读没成功：${e.userMessage}',
  };
}

/// 这一次朗读的音频来源：本地文件或远程地址，二选一。
class _AudioPlan {
  const _AudioPlan({
    required this.digest,
    required this.source,
    this.files,
    this.urls,
    this.pending,
  });

  /// 「语言 + 音色版本 + 全文」的 sha256，也是本地目录名。
  final String digest;

  /// 这次从哪儿出声。决定 UI 上那行来源小字，也决定音色是男是女。
  final TtsAudioSource source;

  /// 本地副本（按段顺序）。非空即表示**不需要联网**。
  final List<File>? files;

  /// 远程地址，仅在没有本地副本时使用。
  final List<String>? urls;

  /// 直连分块时还没合成完的后续块。非空表示 [files] 里只有第一块，
  /// 其余的要边播边取。
  final TtsChunkFeed? pending;
}
