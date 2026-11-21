import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 音频**必须**关掉 `just_audio` 的「用本地代理发请求头」开关。
///
/// ## 为什么值得写一条读源码的测试
///
/// 这条约束只在真机上有效果：`just_audio` 默认（`true`）会把带请求头的播放
/// 交给它自己的 `http://127.0.0.1:<port>` 代理，再让 ExoPlayer 去请求它；
/// 而**回环明文**在 `targetSdk >= 28` 上被系统禁止（本工程 `targetSdk = 36`）。
/// 于是 ExoPlayer 只报一句笼统的 `(0)source error` ——
/// 真正的 `CLEARTEXT communication to 127.0.0.1 not permitted` 被吞在 cause 里，
/// 界面上看不见，看起来像「音频文件坏了」或者「解码不了」。
///
/// 而把那个开关删掉（或者新写一个裸的 `AudioPlayer()`），
/// `flutter analyze` 与 `flutter test` **一个都不会红**，构建也照过 ——
/// 唯一会红的是真机上的**每一条音频**。
/// 这种「删了没人拦」的约束必须由测试盯着，否则下一次重构就漂了。
///
/// ⚠️ 断言都按**代码形态**写（不是「文件里含某个词」）：注释里也写着这些
/// 词，含词判据会变成**空转的绿**。
void main() {
  late String player;
  late String viewer;

  setUpAll(() {
    player = File('lib/widgets/attachment_player.dart').readAsStringSync();
    viewer = File('lib/widgets/homework_image_viewer.dart').readAsStringSync();
  });

  test('音频唯一的播放器构造点关掉了本地代理', () {
    expect(
      player.contains('AudioPlayer(useProxyForRequestHeaders: false)'),
      isTrue,
      reason: '`_AudioBodyState.initState` 必须这样构造播放器。'
          '默认值 true 会让 ExoPlayer 去请求 http://127.0.0.1:<port>，'
          '而那条路在 targetSdk >= 28 上被明文策略挡死 —— '
          '真机症状是「照片视频都好好的，所有音频都报 source error」。',
    );
  });

  test('没有裸的 AudioPlayer()（它会悄悄把代理打开）', () {
    expect(
      RegExp(r'AudioPlayer\(\s*\)').hasMatch(player),
      isFalse,
      reason: '裸构造 = useProxyForRequestHeaders 取默认值 true。',
    );
  });

  test('内存字节那条路不再是原生平台的主路（要有落盘那一支）', () {
    // 只断言「文件里含 writeTempAttachment」会命中注释，所以按调用形态写。
    expect(
      RegExp(r'await writeTempAttachment\(').hasMatch(player),
      isTrue,
      reason: '原生平台上字节必须先落盘成 `file:` 再播 —— '
          '`StreamAudioSource` 是无条件走代理的，开关救不了它。',
    );
    expect(
      RegExp(r'await _player\.setFilePath\(').hasMatch(player),
      isTrue,
    );
  });

  test('音频与视频一样优先走直读（那是唯一不经代理的路）', () {
    expect(
      RegExp(
        r'if \(kind == AttachmentKind\.video \|\| kind == AttachmentKind\.audio\)',
      ).hasMatch(viewer),
      isTrue,
      reason: '把 audio 从这个条件里删掉，音频就只剩「内存字节」那条路，'
          '而它在原生平台上打不开。',
    );
  });

  // ===== 下面两条盯的是**另一个**真机事故（2026-10-03 下午）=====
  //
  // 「直读签得到、播放器打不开」时，链路里原来**没有第二条路**：
  // 调用方一旦给了 directUrl，字节那条就被跳过了，于是整条链死在那里，
  // 而报错只有 `(0) source error`（ExoPlaybackException 的 code 0 =
  // TYPE_SOURCE，对四种失败说的是同一句话）。
  //
  // 这个缺口的特征是：**把退路删掉，analyze / test / 构建全都不红**，
  // 只有真机会红。所以和上面那条一样，必须有测试盯着。

  test('直读之后必须还有退路：调用方要给播放器一个「懒取字节」的回调', () {
    expect(
      RegExp(r'loadBytes: \(\) => HomeworkImageReader\.load\(image\)')
          .hasMatch(viewer),
      isTrue,
      reason: '`_openAttachment` 走直读那支时必须把 `loadBytes` 一起传下去 —— '
          '不然直读一旦打不开，这条路就到此为止。',
    );
    expect(
      RegExp(r'loadBytes: loadBytes').hasMatch(player),
      isTrue,
      reason: '`_AttachmentPlayerDialog` 要把 `loadBytes` 透给播放器。',
    );
    expect(
      RegExp(r'await _resolveBytes\(').hasMatch(player),
      isTrue,
      reason: '播放器要靠 `_resolveBytes` 去够那份懒加载的字节。',
    );
  });

  test('播放器下面那行「来源」不能被删（四种失败只有它分得开）', () {
    expect(
      RegExp(r'_source!,').hasMatch(player),
      isTrue,
      reason: '直读 / 本地文件 / 内存三条路失败时，播放器给的是同一句话；'
          '界面上那行 `_source` 是唯一能把它们分开的东西。',
    );
  });
}
