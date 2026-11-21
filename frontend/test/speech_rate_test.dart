import 'package:easy_learn_app/services/server_tts.dart';
import 'package:easy_learn_app/services/speech_rate.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「正常 / 慢速」的判据。
///
/// 这里盯的是**最容易静默失败**的三件事：
///  · 选了慢速，倍率根本没传到播放层（按钮变了、声音一点没慢）；
///  · 念到一半切档要重合成一遍（孩子等十几秒，还把离线缓存绕过去）；
///  · 偏好读不回来 / 存不上去时把阅读页弄崩。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<double> applied;
  late List<String> written;
  String? stored;
  Object? readError;

  setUp(() {
    // 先把静态状态清干净，再装钩子：清状态本身会通知一次监听器，
    // 钩子早装就会在断言之外多记一条倍率。
    SpeechRateSettings.resetForTest();
    applied = <double>[];
    written = <String>[];
    stored = null;
    readError = null;
    SpeechRateSettings.readForTest = (key) async {
      if (readError != null) throw readError!;
      return stored;
    };
    SpeechRateSettings.writeForTest = (key, value) async {
      written.add(value);
      stored = value;
    };
    ServerTts.state.value = ServerSpeechState.idle;
    ServerTts.error.value = null;
    ServerTts.setSpeedForTest = (speed) async => applied.add(speed);
    ServerTts.speakForTest = (text, language) async {
      ServerTts.state.value = ServerSpeechState.playing;
    };
  });

  tearDown(() {
    ServerTts.setSpeedForTest = null;
    ServerTts.speakForTest = null;
    ServerTts.state.value = ServerSpeechState.idle;
    SpeechRateSettings.resetForTest();
    SpeechRateSettings.readForTest = null;
    SpeechRateSettings.writeForTest = null;
  });

  test('两档倍率与存储值：脏数据一律回落到正常速', () {
    expect(SpeechRate.normal.speed, 1.0);
    expect(SpeechRate.slow.speed, 0.8, reason: '慢速要听得出来，又不能拖成催眠曲');
    expect(SpeechRate.fromStorage('slow'), SpeechRate.slow);
    expect(SpeechRate.fromStorage('normal'), SpeechRate.normal);
    expect(SpeechRate.fromStorage('0.3'), SpeechRate.normal);
    expect(SpeechRate.fromStorage(null), SpeechRate.normal);
  });

  test('本机偏好读不到 / 读坏了都按正常速，不抛', () async {
    stored = 'slow';
    readError = StateError('db not ready');
    await expectLater(SpeechRateSettings.load(), completes);
    expect(SpeechRateSettings.current.value, SpeechRate.normal);

    readError = null;
    stored = 'garbage';
    await SpeechRateSettings.load();
    expect(SpeechRateSettings.current.value, SpeechRate.normal);
  });

  test('选慢速会写本机，下次冷启动读回来还是慢速', () async {
    await SpeechRateSettings.select(SpeechRate.slow);
    expect(written, ['slow']);
    expect(SpeechRateSettings.current.value, SpeechRate.slow);

    // 模拟重开 App：内存清空，只剩刚写下去的那一条。
    SpeechRateSettings.resetForTest();
    expect(SpeechRateSettings.current.value, SpeechRate.normal);
    await SpeechRateSettings.load();
    expect(SpeechRateSettings.current.value, SpeechRate.slow);
  });

  test('DB 读回来得比手慢时，不能覆盖孩子刚点的慢速', () async {
    // 冷启动的 load() 还没回来，孩子已经点了慢速。
    await SpeechRateSettings.select(SpeechRate.slow);
    stored = 'normal';
    await SpeechRateSettings.load();
    expect(SpeechRateSettings.current.value, SpeechRate.slow);
  });

  test('写盘失败不抛，这一次仍然生效', () async {
    SpeechRateSettings.writeForTest = (key, value) async =>
        throw StateError('disk full');
    await expectLater(
      SpeechRateSettings.select(SpeechRate.slow),
      completes,
    );
    expect(SpeechRateSettings.current.value, SpeechRate.slow);
  });

  test('正常速朗读传 1.0，慢速朗读传 0.8', () async {
    await ServerTts.speak('Tom is a little boy.', language: 'en');
    expect(applied, [1.0]);

    await ServerTts.stop();
    await SpeechRateSettings.select(SpeechRate.slow);
    await ServerTts.speak('Tom is a little boy.', language: 'en');
    expect(applied.last, 0.8);
  });

  test('每次朗读都自己重设倍率，不能只靠切档那一次通知', () async {
    // 先切档（会触发监听），清掉记录，再看 speak 自己有没有设一次。
    // 少了这一条，`speak()` 里那次变速被删掉时判据仍会绿：
    // 监听恰好补上了同一个数。11-08 证伪时踩到过。
    await SpeechRateSettings.select(SpeechRate.slow);
    applied.clear();
    await ServerTts.speak('A. B.', language: 'en');
    expect(applied, [0.8]);

    applied.clear();
    await ServerTts.speak('C. D.', language: 'en');
    expect(applied, [0.8], reason: '第二篇也要设，不能只在第一次生效');
  });

  test('念到一半切慢速：立刻变速，不重新合成', () async {
    var speaks = 0;
    ServerTts.speakForTest = (text, language) async {
      speaks += 1;
      ServerTts.state.value = ServerSpeechState.playing;
    };

    await ServerTts.speak('A. B.', language: 'en');
    expect(speaks, 1);
    final before = applied.length;

    await SpeechRateSettings.select(SpeechRate.slow);
    // 播放器的倍率被重设了一次；没有第二次 speak，也不需要再联网合成。
    expect(applied.length, before + 1);
    expect(applied.last, 0.8);
    expect(speaks, 1, reason: '切语速不该把整篇重合成一遍');
  });

  test('切回正常速也立刻生效', () async {
    await SpeechRateSettings.select(SpeechRate.slow);
    await ServerTts.speak('A. B.', language: 'en');
    await SpeechRateSettings.select(SpeechRate.normal);
    expect(applied.last, 1.0);
  });
}
