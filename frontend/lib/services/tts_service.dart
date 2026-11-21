import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/speech_text.dart';

/// 朗读失败。这是**要显示给学生看**的原因，不是日志。
class TtsException implements Exception {
  const TtsException(this.message, {this.code = '', this.details = const {}});

  final String message;

  /// 原生给的失败类别（`engine_init_failed` / `language_not_supported` /
  /// `no_chinese_voice` …）。**别拿 message 做判断** —— 文案会改，码不会。
  final String code;

  /// 失败时的原始事实（厂商、引擎数、初始化返回码）。给「诊断」那一行用。
  final Map<String, Object?> details;

  @override
  String toString() => message;
}

/// 系统离线朗读（Android TextToSpeech）。
///
/// 为什么不用第三方 TTS 插件：讲解朗读只需要「把一段中文念出来」，
/// 系统引擎已经装了、能离线、还跟着系统语言包走。多引一个插件等于
/// 多一份原生依赖和一次打包风险，换不到任何能力。
///
/// 两个必须显式处理的失败：
/// 1. 设备没有引擎 / 没装中文语音包 —— 要明确告诉用户，不能「点了没反应」；
/// 2. 长文本超过引擎上限 —— 自动切段顺序播，不是截断。
class TtsService {
  TtsService._();

  static const MethodChannel _channel = MethodChannel('cn.easylearn.app/tts');

  /// 朗读设置的查询与写入（引擎列表 / 音色列表 / 当前状态 / 应用）。
  ///
  /// 单独的通道：原生那边这些操作跑在**后台 task queue** 上（枚举音色要给那个引擎
  /// 临时建实例，可能要等几秒），不能和 speak/stop 抢主线程那条。
  static const MethodChannel _catalog = MethodChannel(
    'cn.easylearn.app/tts-catalog',
  );

  /// 本机装的一个朗读引擎。
  static Future<List<({String name, String label, bool isDefault})>>
  listEngines() async {
    final rows = await _catalogCall<List<Object?>>('engines');
    return rows
        .whereType<Map<Object?, Object?>>()
        .map(
          (row) => (
            name: row['name'] as String? ?? '',
            label: row['label'] as String? ?? '',
            isDefault: row['isDefault'] as bool? ?? false,
          ),
        )
        .where((e) => e.name.isNotEmpty)
        .toList();
  }

  /// 某个引擎里的中文音色（按质量降序）。[engine] 为空表示系统默认引擎。
  static Future<List<({String name, String locale, int quality, bool network})>>
  listVoices(String? engine) async {
    final rows = await _catalogCall<List<Object?>>('voices', <String, Object?>{
      'engine': engine,
    });
    return rows
        .whereType<Map<Object?, Object?>>()
        .map(
          (row) => (
            name: row['name'] as String? ?? '',
            locale: row['locale'] as String? ?? '',
            quality: row['quality'] as int? ?? -1,
            network: row['network'] as bool? ?? false,
          ),
        )
        .where((v) => v.name.isNotEmpty)
        .toList();
  }

  /// 当前真正在用的东西。注意 [voice] 是**实际生效**的音色名，
  /// 不是「用户选了还没生效」的那个 —— 原生侧只在 setVoice 成功后才记。
  ///
  /// [ready] 与 [degraded] 要一起看：
  /// `ready && !degraded` = 中文数据、音色都按设置配上了；
  /// `ready && degraded` = **能念**，只是用系统默认的那个声音（中文数据或
  /// 音色没配上）。后者不该被当成故障 —— 它仍然把题念出来了。
  static Future<
    ({bool ready, bool degraded, String engine, String voice, double rate})
  >
  status() async {
    final row = await _catalogCall<Map<Object?, Object?>>('status');
    return (
      ready: row['ready'] as bool? ?? false,
      degraded: row['degraded'] as bool? ?? false,
      engine: row['engine'] as String? ?? '',
      voice: row['voice'] as String? ?? '',
      rate: (row['rate'] as num?)?.toDouble() ?? 0.95,
    );
  }

  /// 这台机器的朗读环境事实（厂商、引擎数、初始化返回码、语言是否可用）。
  ///
  /// **只用于解释失败**，不参与任何功能判断。它的存在是因为
  /// 「引擎根本起不来」和「引擎没有中文」在界面上曾共用一句文案，
  /// 而这两种情况给人的下一步完全不同。
  static Future<
    ({
      String manufacturer,
      String model,
      int sdk,
      int engineCount,
      int state,
      int initStatus,
      bool languageReady,
    })
  >
  diagnose() async {
    final row = await _catalogCall<Map<Object?, Object?>>('diagnose');
    return (
      manufacturer: row['manufacturer'] as String? ?? '',
      model: row['model'] as String? ?? '',
      sdk: row['sdk'] as int? ?? 0,
      engineCount: row['engineCount'] as int? ?? 0,
      state: row['state'] as int? ?? 0,
      initStatus: row['initStatus'] as int? ?? -1,
      languageReady: row['languageReady'] as bool? ?? false,
    );
  }

  /// 写回设置并**立刻重建引擎**生效。
  ///
  /// 三个参数都有三种状态，含义必须一致：
  /// `null` = 这一项不动；`''` = 恢复系统默认；有值 = 就用它。
  /// 若语义在每个调用点各写一遍，早晚有一个点写错（比如「换引擎」忘记清音色）。
  static Future<
    ({bool ready, bool degraded, String engine, String voice, double rate})
  >
  apply({String? engine, String? voice, double? rate}) async {
    final row = await _catalogCall<Map<Object?, Object?>>(
      'apply',
      <String, Object?>{
        // 值为 null 的键整个不出现 = 原生侧「这一项不动」。
        'engine': ?engine,
        'voice': ?voice,
        'rate': ?rate,
      },
    );
    return (
      ready: row['ready'] as bool? ?? false,
      degraded: row['degraded'] as bool? ?? false,
      engine: row['engine'] as String? ?? '',
      voice: row['voice'] as String? ?? '',
      rate: (row['rate'] as num?)?.toDouble() ?? 0.95,
    );
  }

  /// 天然会被原生的失败当成 TtsException 抛出的万用表：空列表要让人知道为什么。
  static Future<T> _catalogCall<T>(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    try {
      final result = await _catalog.invokeMethod<T>(method, args);
      if (result == null) {
        throw TtsException(_catalogFailure(method));
      }
      return result;
    } on PlatformException catch (e) {
      // 原生给的话已经是给人看的一句；绝不留默认的 "error/channel-error"。
      // `details` 里是原始事实，面板的「诊断」行要用。
      final raw = e.details;
      throw TtsException(
        e.message ?? _catalogFailure(method),
        code: e.code,
        details: raw is Map
            ? raw.map((key, value) => MapEntry(key.toString(), value))
            : const <String, Object?>{},
      );
    } on MissingPluginException {
      throw const TtsException('当前平台读不到朗读引擎信息，请在手机上使用');
    }
  }

  static String _catalogFailure(String method) => switch (method) {
    'engines' => '没读到本机装了哪些朗读引擎',
    'voices' => '这个引擎的音色列表取不到',
    'status' => '读不到当前的朗读设置',
    _ => '朗读设置没能生效',
  };

  /// 是否正在朗读。UI 靠它切换「朗读 / 停止」。
  static final ValueNotifier<bool> speaking = ValueNotifier<bool>(false);

  /// 最近一次失败原因；UI 读完置空。
  static final ValueNotifier<String?> error = ValueNotifier<String?>(null);

  static final List<({String text, bool english})> _queue =
      <({String text, bool english})>[];

  /// 每次「开始朗读」或「停止」都 +1，用来让迟到的原生回调失效。
  static int _generation = 0;

  static String? _currentUtterance;
  static int _utteranceSeq = 0;
  static bool _handlerInstalled = false;

  /// 句与句之间的静默（毫秒）。
  ///
  /// 引擎拿到一大段文字会从头一路念到尾、句号后面不换气 —— 那是「念稿」的听感。
  /// 一句一次 `speak`、中间用 `playSilentUtterance` 补这段空白才有停顿。
  /// 300ms 接近真人说话句间的呼吸；再长就变成结巴了。
  static const int sentencePauseMs = 300;

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 朗读一段文字。返回时表示**引擎已经受理**（不是「已经出声」）。
  ///
  /// 「有没有真的出声」走 [error]：原生侧受理后 8 秒内没有任何进度回调，
  /// 会推一条明确的失败原因上来（鸿蒙/卓易通那类没有安卓语音合成服务的设备
  /// 正是这个表现 —— `speak()` 返回成功，但一声不吭）。
  /// 受理即返回是必须的：一整篇英文课文几十句，等它念到最后一句再回，
  /// 这里 10 秒的超时早就炸了，用户看到的是「没有响应」，可声音明明在放。
  ///
  /// [english] = true 时：按英文标点断句，并让原生切到英文语音数据。
  /// 这个开关不能用「文本里有没有中文」自动猜 —— 一篇英文课文里夹着中文
  /// 译文或人名是常态，猜错的后果是整篇用中文音色念英文，听感当场崩掉。
  ///
  /// 失败一律抛 [TtsException]，由调用方展示 —— 静默失败在这里是最坏的结果：
  /// 学生以为在播放，等半天没声音。
  static Future<void> speak(String text, {bool english = false}) async {
    if (!isSupported) {
      throw const TtsException('网页版和电脑版暂不支持朗读，请在手机上使用');
    }
    final chunks = splitForSpeech(text, english: english);
    if (chunks.isEmpty) {
      throw const TtsException('还没有可朗读的内容');
    }

    _installHandler();
    await stop();

    final session = _generation;
    _queue.addAll(
      chunks.map((chunk) => (text: chunk, english: english)),
    );
    error.value = null;
    speaking.value = true;
    // 首段失败直接把原因交给调用方（弹一次）；中途失败走 [error] 通知。
    // 两条路只能各自弹一次，否则学生会看到两条一模一样的提示。
    final failure = await _playNext(session, surfaceError: false);
    if (failure != null) throw TtsException(failure);
  }

  static Future<void> stop() async {
    _generation++;
    _queue.clear();
    _currentUtterance = null;
    speaking.value = false;
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // 没有原生实现时 stop 无事可做，也不需要打扰用户。
    } on PlatformException {
      // 同上：停不下来时上层已经不会再收到进度回调。
    }
  }

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onDone':
          final id = call.arguments is String ? call.arguments as String : '';
          unawaited(_playNext(_generation, completed: id).then<void>((_) {}));
        case 'onError':
          final reason =
              call.arguments is String && (call.arguments as String).isNotEmpty
              ? call.arguments as String
              : '朗读中断了，可能是系统语音包不完整';
          _fail(reason);
      }
      return null;
    });
  }

  static Future<String?> _playNext(
    int session, {
    String? completed,
    bool surfaceError = true,
  }) async {
    if (session != _generation) return null;
    if (completed != null && completed != _currentUtterance) return null;

    if (_queue.isEmpty) {
      _currentUtterance = null;
      speaking.value = false;
      return null;
    }

    final item = _queue.removeAt(0);
    final utteranceId = '$session-${_utteranceSeq++}';
    _currentUtterance = utteranceId;

    try {
      await _channel
          .invokeMethod<void>('speak', <String, Object?>{
            // 按句传：**几句话之间要不要喘气，是这儿说了算的**。
            // 传整段的话原生侧再怎么排队也没有句子边界。
            'sentences': splitIntoSentences(item.text, english: item.english),
            'utteranceId': utteranceId,
            'pauseMs': sentencePauseMs,
            // 原生据此切到对应的语音数据。不带时按中文处理，
            // 所以讲解朗读那条老路一个字节都没变。
            'language': item.english ? 'en' : 'zh',
          })
          .timeout(const Duration(seconds: 10));
      return null;
    } on TimeoutException {
      return _fail(
        '系统语音服务 10 秒没有回应，请退出这一页再试一次',
        surfaceError: surfaceError,
      );
    } on PlatformException catch (e) {
      return _fail(e.message ?? '朗读失败，请检查系统的语音引擎', surfaceError: surfaceError);
    } on MissingPluginException {
      return _fail('这台设备不支持朗读', surfaceError: surfaceError);
    }
  }

  static String _fail(String message, {bool surfaceError = true}) {
    _generation++;
    _queue.clear();
    _currentUtterance = null;
    speaking.value = false;
    if (surfaceError) error.value = message;
    return message;
  }
}
