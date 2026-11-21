import 'package:easy_learn_app/pages/student/widgets/tts_settings_sheet.dart';
import 'package:easy_learn_app/services/tts_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 朗读设置这条链路：查询 → 列表 → 写入。
///
/// 这里测不到「换个音色到底好听多少」（没有声卡，也没有 Android 运行时），
/// 但能测到三件**最容易静默出错**的事：
/// 1. 面板拿不到数据时是**说出原因**，还是变成一个空壳（空壳 = 用户以为没得选）；
/// 2. 换引擎时会不会**顺手把旧音色也写回去**（音色名跨引擎无效，写了就是错）；
/// 3. 「不改这一项」和「改回默认」是不是被当成同一件事。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const catalogName = 'cn.easylearn.app/tts-catalog';
  const speechName = 'cn.easylearn.app/tts';

  late List<MethodCall> calls;
  late Map<String, Object?>? status;
  late List<Object?> engines;
  late List<Object?> voices;
  String? voicesFailure;

  /// 诊断行返回的事实。默认那套 = **引擎根本起不来**的那台机器（鸿蒙容器）。
  /// 要它可配置，是因为「引擎起不来」和「引擎好着只是没中文数据」在界面上
  /// 是两条完全不同的结论，得能分别造出来才测得到。
  late Map<String, Object?> diagnosis;

  setUp(() {
    calls = <MethodCall>[];
    status = <String, Object?>{
      'ready': true,
      'degraded': false,
      'engine': '',
      'voice': 'zh-cn-x-ccc-local',
      'rate': 0.95,
    };
    engines = <Object?>[
      <String, Object?>{
        'name': 'com.google.android.tts',
        'label': 'Google 语音服务',
        'isDefault': true,
      },
      <String, Object?>{
        'name': 'com.iflytek.tts',
        'label': '讯飞语音',
        'isDefault': false,
      },
    ];
    voices = <Object?>[
      <String, Object?>{
        'name': 'zh-cn-x-ccc-local',
        'quality': 400,
        'network': false,
        'locale': 'zh_CN',
      },
      <String, Object?>{
        'name': 'zh-cn-x-xxx-local',
        'quality': 200,
        'network': false,
        'locale': 'zh_CN',
      },
      <String, Object?>{
        'name': 'zh-cn-x-net-online',
        'quality': 400,
        'network': true,
        'locale': 'zh_CN',
      },
    ];
    voicesFailure = null;
    diagnosis = <String, Object?>{
      'manufacturer': 'HUAWEI',
      'model': 'Mate 60',
      'sdk': 31,
      'defaultEngine': 'com.google.android.tts',
      'preferredEngine': '',
      'state': -1,
      'initStatus': -1,
      'languageReady': false,
      'activeVoice': '',
    };

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(catalogName),
      (call) async {
        calls.add(call);
        switch (call.method) {
          case 'status':
            return status;
          case 'engines':
            return engines;
          case 'voices':
            if (voicesFailure != null) {
              throw PlatformException(
                code: 'catalog_failed',
                message: voicesFailure,
              );
            }
            return voices;
          case 'apply':
            return status;
          case 'diagnose':
            // 只在出问题时才会被调用；默认这套数字对应「引擎起不来」的那台机器。
            // ⚠️ engineCount 必须在**被调用时**取：测试是在 setUp 之后才把
            //    engines 清空的，setUp 里快照会让它恒等于 2，那条「0 个引擎」
            //    的判据就成了空转的绿。
            return <String, Object?>{
              ...diagnosis,
              'engineCount': diagnosis['engineCount'] ?? engines.length,
            };
          default:
            return null;
        }
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(speechName),
      (call) async => null,
    );

    // 不用设 debugDefaultTargetPlatformOverride：flutter test 里它默认就是
    // android。设了反而要在 body 结束前还原，否则框架会报
    // 「foundation debug variable was changed by the test」。
    TtsService.error.value = null;
    TtsService.speaking.value = false;
  });

  tearDown(() async {
    await TtsService.stop();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(catalogName), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(speechName), null);
  });

  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showTtsSettingsSheet(context),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  group('服务层：通道形状', () {
    test('listEngines 过滤掉空包名', () async {
      engines = <Object?>[
        <String, Object?>{'name': '', 'label': '坏数据', 'isDefault': false},
        <String, Object?>{
          'name': 'com.google.android.tts',
          'label': 'Google 语音服务',
          'isDefault': true,
        },
      ];
      final result = await TtsService.listEngines();
      expect(result.length, 1);
      expect(result.single.label, 'Google 语音服务');
    });

    test('「这一项不动」时参数里根本不出现这个键', () async {
      // null 和 '' 是两件事：null = 不改；'' = 改回系统默认。
      // 如果都写成空字符串，「只换引擎」就会顺手把音色清空。
      await TtsService.apply(voice: 'zh-cn-x-ccc-local');
      final args = calls.firstWhere((c) => c.method == 'apply').arguments as Map;
      expect(args.containsKey('voice'), isTrue);
      expect(args['voice'], 'zh-cn-x-ccc-local');
      expect(args.containsKey('engine'), isFalse);
      expect(args.containsKey('rate'), isFalse);
    });

    test('恢复默认 = 显式传空串，而不是不传', () async {
      await TtsService.apply(engine: '');
      final args = calls.firstWhere((c) => c.method == 'apply').arguments as Map;
      expect(args.containsKey('engine'), isTrue);
      expect(args['engine'], '');
    });

    test('status 读出「降级」，老原生不给这个键时按不降级处理', () async {
      // 降级 = 能念，只是用系统默认的声音。读不出来时按「没降级」走是安全的：
      // 那只是不显示那条提示，不会把能念的机器判成念不了（反过来才危险）。
      status = <String, Object?>{
        'ready': true,
        'engine': '',
        'voice': '',
        'rate': 0.95,
      };
      expect((await TtsService.status()).degraded, isFalse);

      status = <String, Object?>{
        'ready': true,
        'degraded': true,
        'engine': '',
        'voice': '',
        'rate': 0.95,
      };
      expect((await TtsService.status()).degraded, isTrue);
    });

    test('降级时 ready 仍然为真 —— 它只是声音是默认的，不是念不了', () async {
      // 这条盯着的是「ready 的口径」。把 ready 定义成「一切都按设置配好了」，
      // 界面就会在明明出得了声的机器上显示朗读不可用。
      status = <String, Object?>{
        'ready': true,
        'degraded': true,
        'engine': '',
        'voice': '',
        'rate': 0.95,
      };
      final result = await TtsService.status();
      expect(result.ready, isTrue);
      expect(result.degraded, isTrue);
    });

    test('原生给的解释会原样变成 TtsException，而不是 "PlatformException"', () async {
      voicesFailure = '这个引擎没有中文朗读能力';
      await expectLater(
        TtsService.listVoices('com.iflytek.tts'),
        throwsA(
          isA<TtsException>().having(
            (e) => e.message,
            'message',
            contains('没有中文朗读能力'),
          ),
        ),
      );
    });
  });

  group('面板', () {
    testWidgets('列出引擎与音色，当前生效的那个带勾', (tester) async {
      await openSheet(tester);

      expect(find.text('Google 语音服务'), findsOneWidget);
      expect(find.text('讯飞语音'), findsOneWidget);
      expect(find.textContaining('ccc-local'), findsOneWidget);
      expect(find.textContaining('xxx-local'), findsOneWidget);
      // 当前生效的音色有且只有一个勾。
      expect(find.byIcon(Icons.check_circle), findsWidgets);
    });

    testWidgets('同档音色的名字必须能区分开，不能两行一模一样', (tester) async {
      await openSheet(tester);
      final labels = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((tile) => (tile.title as Text?)?.data ?? '')
          .where((text) => text.contains('高质量') || text.contains('标准'))
          .toList();
      expect(labels.length, greaterThanOrEqualTo(2));
      expect(labels.toSet().length, labels.length, reason: '出现了两行完全相同的选项：$labels');
    });

    testWidgets('需要联网的音色被标注出来', (tester) async {
      await openSheet(tester);
      expect(find.textContaining('需要联网'), findsOneWidget);
    });

    testWidgets('点音色 → 只写 voice，不碰引擎和语速', (tester) async {
      await openSheet(tester);
      await tester.tap(find.byKey(const ValueKey<String>('tts-voice-zh-cn-x-xxx-local')));
      await tester.pumpAndSettle();

      final args = calls.firstWhere((c) => c.method == 'apply').arguments as Map;
      expect(args['voice'], 'zh-cn-x-xxx-local');
      expect(args.containsKey('engine'), isFalse, reason: '只换个音色，不该重建到别的引擎去');
      expect(args.containsKey('rate'), isFalse);
    });

    testWidgets('换引擎 → 只写 engine（旧音色名跨引擎无效，绝不能一起写）', (tester) async {
      await openSheet(tester);
      await tester.tap(find.text('讯飞语音'));
      await tester.pumpAndSettle();

      final args = calls.firstWhere((c) => c.method == 'apply').arguments as Map;
      expect(args['engine'], 'com.iflytek.tts');
      expect(args.containsKey('voice'), isFalse,
          reason: '音色名只在同一个引擎里有效，换引擎时带上旧音色就是错的');
    });

    testWidgets('拿不到音色列表时说出原因，而不是给一个空面板', (tester) async {
      voicesFailure = '这个引擎没有可选的中文音色 —— 去系统设置里给它装一个中文语音包再回来';
      await openSheet(tester);

      expect(find.textContaining('没有可选的中文音色'), findsOneWidget);
      expect(find.text('重新读取'), findsOneWidget);
    });

    testWidgets('音色读不到时，引擎列表仍然可点 —— 换引擎是唯一有效的动作', (tester) async {
      // 鸿蒙 / 卓易通上默认引擎起不来，用户唯一能自救的动作就是换一个引擎。
      // 原来一个 `_error` 管全部，于是这一屏变成纯错误页，那一步点不到。
      voicesFailure = '这个引擎没有中文朗读能力';
      await openSheet(tester);

      expect(find.text('讯飞语音'), findsOneWidget, reason: '引擎列表必须还在');
      await tester.tap(find.text('讯飞语音'));
      await tester.pumpAndSettle();

      final applied = calls.firstWhere((c) => c.method == 'apply');
      expect(
        (applied.arguments as Map)['engine'],
        'com.iflytek.tts',
        reason: '点引擎必须真的把选择写下去',
      );
    });

    testWidgets('引擎一个都没有时，说明是系统层面缺服务并列出诊断事实', (tester) async {
      engines = const <Object?>[];
      voicesFailure = '引擎「系统默认引擎」没有启动起来（系统返回 -1）';
      await openSheet(tester);

      expect(find.textContaining('没有向系统注册任何朗读引擎'), findsOneWidget);
      // 诊断行：只陈述事实，让人能判断「这条路在这台机器上不存在」。
      expect(find.textContaining('HUAWEI'), findsOneWidget);
      expect(find.textContaining('引擎：0 个'), findsOneWidget);
    });

    testWidgets('降级时说「用系统默认」，并且不当成故障页', (tester) async {
      // 探测说「没有中文数据」不等于念不出来。以前这条路径会把整块面板
      // 判成不可用，于是试听也点不了 —— 而试听恰恰是判断「到底念不念得出来」
      // 的唯一办法。现在它必须还是一屏正常的设置。
      status = <String, Object?>{
        'ready': true,
        'degraded': true,
        'engine': '',
        'voice': '',
        'rate': 0.95,
      };
      await openSheet(tester);

      expect(find.textContaining('正在用系统默认的声音朗读'), findsOneWidget);
      expect(find.text('Google 语音服务'), findsOneWidget, reason: '引擎列表必须还在');
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('重试'), findsNothing, reason: '不是故障，不该给错误页');
    });

    testWidgets('降级时换引擎仍然能把选择写下去', (tester) async {
      status = <String, Object?>{
        'ready': true,
        'degraded': true,
        'engine': '',
        'voice': '',
        'rate': 0.95,
      };
      await openSheet(tester);
      await tester.tap(find.text('讯飞语音'));
      await tester.pumpAndSettle();

      expect(
        (calls.firstWhere((c) => c.method == 'apply').arguments as Map)['engine'],
        'com.iflytek.tts',
        reason: '降级只影响声音，不影响「能不能改设置」',
      );
    });

    testWidgets('诊断行分开「系统没服务」和「只是没中文数据」', (tester) async {
      // 这两条结论给人的下一步是相反的：一个说「别折腾了」，一个说「还有救」。
      // 原来共用一句「没有中文朗读能力」，把人引去装语音包 —— 在没服务的
      // 机器上那条路根本不存在。
      engines = <Object?>[
        <String, Object?>{
          'name': 'com.google.android.tts',
          'label': 'Google 语音服务',
          'isDefault': true,
        },
      ];
      voicesFailure = '这个引擎没有中文朗读能力';
      diagnosis = <String, Object?>{
        'manufacturer': 'Xiaomi',
        'model': 'M2102K1C',
        'sdk': 33,
        'engineCount': 1,
        'defaultEngine': 'com.google.android.tts',
        'preferredEngine': '',
        'state': 2,
        'initStatus': 0,
        'languageReady': false,
        'activeVoice': '',
      };
      await openSheet(tester);

      expect(
        find.textContaining('会用系统默认的声音继续朗读'),
        findsOneWidget,
        reason: '引擎起来了只是没中文数据，这是降级，不是没救',
      );
      expect(
        find.textContaining('装中文语音包也不会生效'),
        findsNothing,
        reason: '这句只该出现在「系统层面没有 TTS 服务」的机器上',
      );
      expect(find.textContaining('降级（用系统默认）'), findsOneWidget);
    });

    testWidgets('网页版明确说没有这个面板，而不是转圈到死', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await openSheet(tester);
        expect(find.textContaining('只能在手机上调整'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
