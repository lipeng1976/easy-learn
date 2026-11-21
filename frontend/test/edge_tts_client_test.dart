import 'package:easy_learn_app/services/edge_tts_client.dart';
import 'package:easy_learn_app/services/tts_voice.dart';
import 'package:flutter_test/flutter_test.dart';

/// 拼 SSML 的判据。
///
/// 这里错一个字符，表现是「接口有响应但没有音频」—— 报错完全指不出方向，
/// 所以只能靠断言把每个特殊字符钉死。
void main() {
  test('正文里的 XML 特殊字符全部转义', () {
    final ssml = EdgeTtsClient.buildSsml(
      'Tom & Jerry <said> "hi" it\'s',
      voice: TtsVoices.localMaleEn,
      language: 'en-US',
    );

    expect(ssml, contains('Tom &amp; Jerry &lt;said&gt; &quot;hi&quot; it&apos;s'));
    // 未转义的尖括号会让整段 SSML 解析失败
    expect(ssml, isNot(contains('<said>')));
  });

  test('英文课文的换行原样保留，不影响 SSML 结构', () {
    final ssml = EdgeTtsClient.buildSsml(
      'Line one.\nLine two.\n\nNew paragraph.',
      voice: TtsVoices.localMaleEn,
      language: 'en-US',
    );
    expect(ssml, contains('Line one.\nLine two.\n\nNew paragraph.'));
    expect('<speak'.allMatches(ssml), hasLength(1));
  });

  test('语言决定 xml:lang 与默认音色（本机一律男声）', () {
    expect(EdgeTtsClient.langFor('en'), 'en-US');
    expect(EdgeTtsClient.langFor('zh'), 'zh-CN');
    // 11-08 起的区分约定：男声 = 本机 / 直连，女声 = 云端 Qwen。
    // 这两个曾经是 Aria / 晓晓（都是女声），改回去会让「一听就知道
    // 走哪条路」失效，而且旧缓存里的女声音频会被误命中。
    expect(EdgeTtsClient.voiceFor('en'), TtsVoices.localMaleEn);
    expect(EdgeTtsClient.voiceFor('zh'), TtsVoices.localMaleZh);
    expect(EdgeTtsClient.voiceFor('en'), 'en-US-GuyNeural');
    expect(EdgeTtsClient.voiceFor('zh'), 'zh-CN-YunxiNeural');
  });

  test('超时随文本长度放宽', () {
    expect(
      EdgeTtsClient.timeoutFor(0).inSeconds,
      lessThan(EdgeTtsClient.timeoutFor(4822).inSeconds),
    );
    // 4822 字符实测 15.9 秒，默认上限必须显著大于它
    expect(EdgeTtsClient.timeoutFor(4822).inSeconds, greaterThan(30));
  });

  test('空文本直接抛，不发请求', () async {
    await expectLater(
      const EdgeTtsClient().synthesize(text: '   '),
      throwsA(
        isA<EdgeTtsException>().having((e) => e.code, 'code', 'empty_text'),
      ),
    );
  });
}
