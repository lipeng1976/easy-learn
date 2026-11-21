import 'package:easy_learn_app/services/tts_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 这里用模拟的平台通道验证「状态机 + 失败路径」。
///
/// 真机能不能出声测不了（TestWidgetsFlutterBinding 没有声卡），
/// 但「点了之后按钮有没有变成正在朗读」「引擎报错有没有变成一句人话」
/// 是纯状态逻辑，必须在这里锁住 —— 这类 bug 恰恰是静音的。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'cn.easylearn.app/tts';
  const codec = StandardMethodCodec();

  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall call) onSpeak;

  setUp(() async {
    calls = <MethodCall>[];
    onSpeak = (_) async => null;
    TtsService.error.value = null;
    TtsService.speaking.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), (call) async {
          calls.add(call);
          if (call.method == 'speak') return onSpeak(call);
          return null;
        });
  });

  tearDown(() async {
    await TtsService.stop();
    TtsService.error.value = null;
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), null);
  });

  Future<void> emitFromNative(String method, Object? arguments) async {
    final data = codec.encodeMethodCall(MethodCall(method, arguments));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channelName, data, (_) {});
    await pumpEventQueue();
  }

  test('开始朗读后 speaking 为真，收到 onDone 后恢复', () async {
    await TtsService.speak('先通分，再把分子相加。');
    expect(TtsService.speaking.value, isTrue);

    final speakCall = calls.firstWhere((call) => call.method == 'speak');
    final utteranceId = (speakCall.arguments as Map)['utteranceId'] as String;
    expect(utteranceId, isNotEmpty);

    await emitFromNative('onDone', utteranceId);
    expect(TtsService.speaking.value, isFalse);
  });

  test('念英文课文时把 language=en 传给原生，并按英文标点断句', () async {
    await TtsService.speak(
      'Tom is a little boy. He likes swimming very much! Do you know why?',
      english: true,
    );

    final call = calls.firstWhere((c) => c.method == 'speak');
    final args = call.arguments as Map;
    expect(args['language'], 'en', reason: '不传 en 的话原生会用中文音色念英文');
    expect(args['sentences'], [
      'Tom is a little boy.',
      'He likes swimming very much!',
      'Do you know why?',
    ], reason: '英文句子没切开，引擎会一口气念到底');
  });

  test('不传 english 时仍然按中文送下去（讲解那条老路一个字节没变）', () async {
    await TtsService.speak('先通分，再把分子相加。');

    final args = calls.firstWhere((c) => c.method == 'speak').arguments as Map;
    expect(args['language'], 'zh');
    expect(args['sentences'], ['先通分，再把分子相加。']);
  });

  test('引擎不可用时抛出可展示的原因，且不留在「朗读中」', () async {
    onSpeak = (_) async => throw PlatformException(
      code: 'engine_unavailable',
      message: '这台设备没有可用的朗读引擎',
    );

    await expectLater(
      TtsService.speak('先通分。'),
      throwsA(
        isA<TtsException>().having(
          (e) => e.message,
          'message',
          contains('朗读引擎'),
        ),
      ),
    );
    expect(TtsService.speaking.value, isFalse);
  });

  test('长稿分多次送进引擎，上一段 onDone 之后才送下一段', () async {
    final longText = List<String>.generate(500, (i) => '这是第$i句话。').join();
    await TtsService.speak(longText);

    var speakCalls = calls.where((call) => call.method == 'speak').toList();
    expect(speakCalls.length, 1, reason: '第一段还没播完，不该把后面的都塞进去');

    final firstId = (speakCalls.first.arguments as Map)['utteranceId'] as String;
    await emitFromNative('onDone', firstId);

    speakCalls = calls.where((call) => call.method == 'speak').toList();
    expect(speakCalls.length, 2);
    expect(TtsService.speaking.value, isTrue);
  });

  test('送进通道的是「一句句」而不是整段，并带着句间静默', () async {
    // 这两件事决定了听感：一次给整段 ⇒ 引擎一口气念到底、句号后不换气；
    // 没有 pauseMs ⇒ 原生侧就算分了句也不会在句子之间留白。
    await TtsService.speak('这道题考的是通分。先找公分母，再把分子相加。最后约分。');

    final args = (calls.firstWhere((call) => call.method == 'speak').arguments
        as Map);
    expect(args.containsKey('text'), isFalse,
        reason: '不能再留整段字段：两处都能取值时，总有一天会有一边没更新');

    final sentences = (args['sentences'] as List).cast<String>();
    expect(sentences, [
      '这道题考的是通分。',
      '先找公分母，再把分子相加。',
      '最后约分。',
    ]);
    expect(sentences.every((s) => s.isNotEmpty), isTrue,
        reason: '空句子会让引擎念出一段空白，听着像卡住了');

    final pauseMs = args['pauseMs'] as int;
    expect(pauseMs, greaterThan(0),
        reason: '句间没有静默 == 一口气念完，这正是「生硬」的来源');
    expect(pauseMs, lessThan(1000), reason: '超过 1 秒就不是停顿，是结巴');
  });

  test('上一轮朗读迟到的 onDone 不会推进新一轮的队列', () async {
    final longText = List<String>.generate(500, (i) => '这是第$i句话。').join();
    await TtsService.speak(longText);
    final staleId =
        (calls.firstWhere((call) => call.method == 'speak').arguments
                as Map)['utteranceId']
            as String;

    await TtsService.stop();
    calls.clear();

    // 新一轮：队列重新填满，并且已经送出了第一段。
    await TtsService.speak(longText);
    expect(calls.where((call) => call.method == 'speak').length, 1);

    // 上一轮的 onDone 现在才到。若只按「队列非空就继续」处理，
    // 它会把这一轮直接推进到第二段 —— 学生听到的讲解会跳段。
    await emitFromNative('onDone', staleId);
    expect(
      calls.where((call) => call.method == 'speak').length,
      1,
      reason: '旧回调属于上一轮，不能推进这一轮',
    );
    expect(TtsService.speaking.value, isTrue);
  });

  test('非 Android 平台明确说不支持，而不是点了没反应', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await expectLater(
      TtsService.speak('先通分。'),
      throwsA(
        isA<TtsException>().having(
          (e) => e.message,
          'message',
          contains('不支持'),
        ),
      ),
    );
    expect(calls.where((call) => call.method == 'speak'), isEmpty);
  });

  test('空讲解直接报错，不会送一段空字符串给引擎', () async {
    await expectLater(
      TtsService.speak('   '),
      throwsA(isA<TtsException>()),
    );
    expect(calls.where((call) => call.method == 'speak'), isEmpty);
  });
}
