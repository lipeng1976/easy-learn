import 'package:easy_learn_app/constants/app_colors.dart';
import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/reading_controller.dart';
import 'package:easy_learn_app/models/reading_models.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/student/reading_page.dart';
import 'package:easy_learn_app/repositories/reading_repository.dart';
import 'package:easy_learn_app/services/cloud_runtime.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/services/server_tts.dart';
import 'package:easy_learn_app/services/speech_rate.dart';
import 'package:easy_learn_app/services/tts_voice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 阅读页「伴读」按钮的判据。
///
/// 这里要盯住的全是**静默失败**：
///  · 按钮不在，或者被打卡按钮挤掉（孩子根本发现不了有朗读）；
///  · 点下去送的是中文 —— 声音出来了，只是用中文腔念英文；
///  · 念到一半按钮还写着「伴读」—— 学生想停却找不到开关。
/// 三种情况都不会报错，只能靠断言。
///
/// ⚠️ 2026-11-07 起伴读**不走系统 TTS**：学生那台鸿蒙手机通过卓易通跑安卓应用，
/// 容器里没有安卓的语音合成服务（真机实测卡十几秒后超时）。所以判据从
/// 「MethodChannel 收到了什么」改成「`ServerTts` 收到了什么」。
class _FakeReadingRepository implements ReadingRepository {
  _FakeReadingRepository({required this.task, required this.lesson});

  final ReadingTask task;
  final ReadingLesson lesson;

  /// 每次取课文就 +1。用来证明点「读下一篇」真的换了内容。
  int lessonCalls = 0;

  @override
  Future<List<ReadingTask>> listTasks({String? studentId}) async => [task];

  @override
  Future<ReadingLesson> getLesson({
    required String bookId,
    required int lessonNo,
    String? studentId,
  }) async {
    lessonCalls += 1;
    return lesson;
  }

  @override
  Future<List<ReadingAvailableBook>> listAvailableBooks({String? studentId}) async => const [];

  @override
  Future<ReadingImportResult> importBook({
    required String mediaId,
    String? studentId,
    String fileName = '',
    String title = '',
  }) async =>
      throw UnimplementedError();

  @override
  Future<List<ReadingBook>> listBooks({String? studentId}) async => const [];

  @override
  Future<List<ReadingLessonSummary>> listLessons({
    required String bookId,
    String? studentId,
  }) async =>
      const [];

  @override
  Future<({ReadingTask task, bool created})> createTask({
    required String bookId,
    String? studentId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<ReadingReadResult> readLesson({
    required String taskId,
    required int lessonNo,
    required String day,
    String? studentId,
  }) async =>
      ReadingReadResult(
        task: ReadingTask(
          id: taskId,
          bookId: 'book_1',
          bookTitle: '感动世界的文字',
          doneLessons: lessonNo,
          totalLessons: 96,
          nextLessonNo: lessonNo + 1,
          readLessonNos: [for (var i = 1; i <= lessonNo; i++) i],
        ),
      );

  @override
  Future<ReadingTask> cancelTask({
    required String taskId,
    String? studentId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<ReadingLogPage> listLogs({
    String? studentId,
    String? from,
    String? to,
    int limit = 50,
    int offset = 0,
  }) async =>
      const ReadingLogPage();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<({String text, String language})> serverCalls;
  late List<double> appliedSpeeds;
  String? storedRate;
  TtsAudioSource? fakeSource;

  /// 两个语速胶囊的选中态靠文字颜色看，不靠文案（文案会改，颜色是行为）。
  Color? chipColor(WidgetTester tester, String key, String label) => tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.text(label),
        ),
      )
      .style
      ?.color;

  setUp(() {
    Get.reset();
    serverCalls = <({String text, String language})>[];
    appliedSpeeds = <double>[];
    storedRate = null;
    fakeSource = null;
    speechSource.value = null;
    // 先清状态再装钩子：清状态会通知一次监听，早装会多记一条倍率。
    SpeechRateSettings.resetForTest();
    SpeechRateSettings.readForTest = (key) async => storedRate;
    SpeechRateSettings.writeForTest = (key, value) async => storedRate = value;
    ServerTts.setSpeedForTest = (speed) async => appliedSpeeds.add(speed);
    ServerTts.state.value = ServerSpeechState.idle;
    ServerTts.error.value = null;
    // 假实现自己把状态推到「播放中」—— 真实那条路要建 http、下文件、起播放器。
    ServerTts.speakForTest = (text, language) async {
      serverCalls.add((text: text, language: language));
      ServerTts.state.value = ServerSpeechState.playing;
      // 真链路在 `_play` 里置来源；测试分支由用例指定要模拟哪一条。
      speechSource.value = fakeSource;
    };
    DatabaseService.useCloudRuntime(
      CloudRuntime(config: const DataConfig(baseUrl: 'http://127.0.0.1:8788')),
    );
    Get.put(AuthController()).currentUser.value = UserModel(
      id: 'stu_001',
      name: '林小宇',
      phone: '13800000002',
      role: 'student',
      avatar: '🧒',
    );
  });

  tearDown(() {
    ServerTts.setSpeedForTest = null;
    ServerTts.speakForTest = null;
    speechSource.value = null;
    SpeechRateSettings.resetForTest();
    SpeechRateSettings.readForTest = null;
    SpeechRateSettings.writeForTest = null;
    ServerTts.state.value = ServerSpeechState.idle;
    ServerTts.error.value = null;
    DatabaseService.useCloudRuntime(null);
    Get.reset();
  });

  ReadingTask activeTask({int nextLessonNo = 4, int done = 3}) => ReadingTask(
        id: 'task_1',
        bookId: 'book_1',
        bookTitle: '感动世界的文字',
        doneLessons: done,
        totalLessons: 96,
        nextLessonNo: nextLessonNo,
        readLessonNos: [for (var i = 1; i <= done; i++) i],
      );

  const lesson = ReadingLesson(
    lessonNo: 4,
    title: 'The Little Hero',
    titleZh: '小英雄',
    body: 'Tom is a little boy. He likes swimming very much! Do you know why?',
    translation: '汤姆是个小男孩。',
    charCount: 66,
  );

  Future<_FakeReadingRepository> pumpReading(
    WidgetTester tester, {
    ReadingTask? task,
    ReadingLesson? content,
  }) async {
    final repo = _FakeReadingRepository(
      task: task ?? activeTask(),
      lesson: content ?? lesson,
    );
    Get.put(ReadingController(repository: repo));
    await tester.pumpWidget(const GetMaterialApp(home: ReadingPage()));
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets('伴读按钮在打卡按钮左侧，两个都在', (tester) async {
    await pumpReading(tester);

    final listen = find.text('伴读');
    final mark = find.text('我读完了，打卡');
    expect(listen, findsOneWidget, reason: '没有伴读按钮，孩子根本发现不了可以听');
    expect(mark, findsOneWidget);

    // 位置不是随便放的：伴读是主流程里的辅助动作，放在打卡右边会被
    // 当成「读完之后的下一步」，读者会先打卡再想听。
    expect(
      tester.getTopLeft(listen).dx < tester.getTopLeft(mark).dx,
      isTrue,
      reason: '伴读应该在「我读完了，打卡」的左侧',
    );
  });

  testWidgets('点伴读：把英文正文送去服务端合成，language=en', (tester) async {
    await pumpReading(tester);

    await tester.tap(find.text('伴读'));
    await tester.pumpAndSettle();

    expect(serverCalls, hasLength(1), reason: '点了伴读却没送朗读请求');
    expect(
      serverCalls.single.language,
      'en',
      reason: '不带 en 的话，英文会被按中文念出来 —— 有声音但一句听不懂',
    );
    expect(serverCalls.single.text.contains('Tom is a little boy.'), isTrue);
  });

  testWidgets('只念英文正文，不念默认收起的中文译文', (tester) async {
    await pumpReading(tester);

    await tester.tap(find.text('伴读'));
    await tester.pumpAndSettle();

    final spoken = serverCalls.single.text;
    expect(spoken.contains('Tom'), isTrue);
    expect(spoken.contains('汤姆'), isFalse, reason: '译文是收起的，念出来孩子会莫名其妙');
  });

  testWidgets('播放中按钮变「停止」，点一下回到「伴读」', (tester) async {
    await pumpReading(tester);

    await tester.tap(find.text('伴读'));
    await tester.pumpAndSettle();
    expect(find.text('停止'), findsOneWidget, reason: '在念的时候必须能停下来');
    expect(find.text('伴读'), findsNothing);

    await tester.tap(find.text('停止'));
    await tester.pumpAndSettle();
    expect(ServerTts.state.value, ServerSpeechState.idle);
    expect(find.text('伴读'), findsOneWidget);
    expect(find.text('停止'), findsNothing);
  });

  testWidgets('准备音频期间显示「准备中…」，不装作没点上', (tester) async {
    await pumpReading(tester);

    // 把「合成」挂住，模拟真实网络那几秒。
    ServerTts.speakForTest = (text, language) async {
      serverCalls.add((text: text, language: language));
      ServerTts.state.value = ServerSpeechState.preparing;
    };
    await tester.tap(find.text('伴读'));
    // ⚠️ 不能用 `pumpAndSettle`：这个态里有一个无限循环的
    // `CircularProgressIndicator`，settle 永远等不到静止，测试会超时。
    await tester.pump();
    await tester.pump();
    expect(find.text('准备中…'), findsOneWidget);
    expect(
      find.text('伴读'),
      findsNothing,
      reason: '准备时不改文案，孩子会以为没点上，连着点好几次',
    );
  });

  testWidgets('点「读下一篇」把朗读停掉，别让上一篇的声音跟到新课文', (tester) async {
    // 这一条对应的是一个很具体的现场：孩子一边听一边翻页，新文章显示出来，
    // 耳朵里还是上一篇 —— 会以为自己串页了。
    await pumpReading(tester, task: activeTask(nextLessonNo: 4, done: 3));
    await tester.tap(find.text('伴读'));
    await tester.pumpAndSettle();
    expect(ServerTts.state.value, ServerSpeechState.playing);

    // 先打卡把按钮变成「读下一篇」。
    await tester.tap(find.text('我读完了，打卡'));
    await tester.pumpAndSettle();
    expect(find.text('读下一篇'), findsOneWidget);

    await tester.tap(find.text('读下一篇'));
    await tester.pumpAndSettle();
    expect(
      ServerTts.state.value,
      ServerSpeechState.idle,
      reason: '翻页了声音还在，学生会以为串页',
    );
  });

  testWidgets('阅读页有「正常 / 慢速」，默认正常且选中态看得见', (tester) async {
    await pumpReading(tester);

    expect(find.byKey(const Key('speech_rate_normal')), findsOneWidget);
    expect(find.byKey(const Key('speech_rate_slow')), findsOneWidget);
    expect(SpeechRateSettings.current.value, SpeechRate.normal);
    expect(chipColor(tester, 'speech_rate_normal', '正常'), AppColors.primary);
    expect(chipColor(tester, 'speech_rate_slow', '慢速'), AppColors.textMuted);
  });

  testWidgets('点慢速 → 选中态变、偏好写盘、朗读按 0.8 倍走', (tester) async {
    await pumpReading(tester);

    await tester.tap(find.byKey(const Key('speech_rate_slow')));
    await tester.pumpAndSettle();

    expect(SpeechRateSettings.current.value, SpeechRate.slow);
    expect(chipColor(tester, 'speech_rate_slow', '慢速'), AppColors.primary);
    expect(storedRate, 'slow', reason: '设一次就要记住，下回进来不用再点');

    // 清掉切档监听刚记的那一次：这里要盯的是**点伴读时**自己设的倍率。
    appliedSpeeds.clear();
    await tester.tap(find.text('伴读'));
    await tester.pumpAndSettle();
    expect(appliedSpeeds, [0.8], reason: '选了慢速却没把 0.8 传给播放器');
    expect(serverCalls, hasLength(1), reason: '切档不该触发一次新的合成');
  });

  testWidgets('上次存的慢速，重进阅读页还是慢速', (tester) async {
    storedRate = 'slow';
    await pumpReading(tester);

    expect(SpeechRateSettings.current.value, SpeechRate.slow);
    expect(chipColor(tester, 'speech_rate_slow', '慢速'), AppColors.primary);
    expect(chipColor(tester, 'speech_rate_normal', '正常'), AppColors.textMuted);
  });

  testWidgets('没在念时不显示来源标签，不占底栏空间', (tester) async {
    await pumpReading(tester);
    expect(find.byKey(const Key('speech_source_badge')), findsNothing);
  });

  testWidgets('走云端 Qwen：底栏明说是女声兜底', (tester) async {
    fakeSource = TtsAudioSource.cloud;
    await pumpReading(tester);

    await tester.tap(find.text('伴读'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('speech_source_badge')), findsOneWidget);
    expect(find.textContaining('女声'), findsOneWidget);
    expect(find.textContaining('云端'), findsOneWidget);
  });

  testWidgets('命中本机缓存：底栏明说是男声、不联网', (tester) async {
    fakeSource = TtsAudioSource.local;
    await pumpReading(tester);

    await tester.tap(find.text('伴读'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('speech_source_badge')), findsOneWidget);
    expect(find.textContaining('男声'), findsOneWidget);
    expect(find.textContaining('本机缓存'), findsOneWidget);
  });

  /// 正文段落里所有 span 的 (文字, 样式)。
  List<(String, TextStyle?)> bodySpans(WidgetTester tester) {
    final out = <(String, TextStyle?)>[];
    for (final widget in tester.widgetList<SelectableText>(
      find.byType(SelectableText),
    )) {
      final span = widget.textSpan;
      if (span == null) continue;
      void walk(TextSpan node) {
        if (node.text != null && node.text!.isNotEmpty) {
          out.add((node.text!, node.style));
        }
        for (final child in node.children ?? const <InlineSpan>[]) {
          if (child is TextSpan) walk(child);
        }
      }

      walk(span);
    }
    return out;
  }

  testWidgets('正文里的生词标成粗体蓝色，普通词不动', (tester) async {
    // 「函数写好了但页面没用上」是这个项目反复出现过的一类静默失败：
    // 单测全绿、学生看到的还是黑字。所以这条断言直接读渲染出来的 span。
    const content = ReadingLesson(
      lessonNo: 4,
      title: 'The Little Hero',
      body: 'Tom is a little boy. He likes swimming very much!',
      vocabulary: [
        ReadingVocabulary(no: 1, word: 'swim', meaning: '游泳'),
        ReadingVocabulary(no: 2, word: 'boy', meaning: '男孩'),
      ],
      charCount: 55,
    );
    await pumpReading(tester, content: content);

    final spans = bodySpans(tester);
    TextStyle? styleOf(String text) {
      for (final (value, style) in spans) {
        if (value.trim() == text) return style;
      }
      return null;
    }

    final swimming = styleOf('swimming');
    expect(swimming?.fontWeight, FontWeight.w700, reason: 'swimming 是 swim 的变形，应该标');
    expect(swimming?.color, AppColors.primary, reason: '生词要蓝色');

    final boy = styleOf('boy');
    expect(boy?.fontWeight, FontWeight.w700);

    final tom = styleOf('Tom');
    expect(tom?.fontWeight, isNot(FontWeight.w700), reason: '不是生词的词不该变粗');
    expect(tom?.color, isNot(AppColors.primary));
  });
}
