import 'dart:typed_data';

import 'package:easy_learn_app/repositories/focus_repository.dart';
import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/models/focus_session_model.dart';
import 'package:easy_learn_app/models/homework_image_model.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/models/knowledge_tip.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/pages/student/focus_timer_page.dart';
import 'package:easy_learn_app/repositories/homework_repository.dart';
import 'package:easy_learn_app/services/focus_timer_service.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/services/knowledge_tip_service.dart';
import 'package:easy_learn_app/services/knowledge_tip_store.dart';
import 'package:easy_learn_app/services/simulated_ai_data_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 全屏计时页的判据。
///
/// 这一屏的四条口径，每一条都有一种**看起来正常**的错法：
///   · 「暂停不计入」写成每秒 +1 ⇒ 暂停期间数字还在涨；
///   · 「离开应用自动暂停」漏掉 ⇒ 手机放桌上一小时被记成学习一小时；
///   · 保存失败的时把会话清掉 ⇒ 一小时白计时，而且没有任何提示；
///   · 保存成功却不清会话 ⇒ 回到卡片还显示「计时中」，永远不会结束。
///
/// 时钟是**注入的**：真实时钟下 40 分钟的作业没法测，而 `pump(Duration)`
/// 只能推进 Flutter 的假时钟，`DateTime.now()` 不受它控制。
class _Clock {
  DateTime value = DateTime(2026, 10, 19, 9, 0, 0);

  DateTime call() => value;

  void advance(int seconds) => value = value.add(Duration(seconds: seconds));
}

class _FakeHomework implements HomeworkRepository {
  final List<HomeworkPatch> patches = <HomeworkPatch>[];
  Object? error;

  @override
  Future<void> updateHomework(HomeworkPatch patch) async {
    final e = error;
    if (e != null) throw e;
    patches.add(patch);
  }

  @override
  Future<List<HomeworkItem>> queryHomework(String userRole) => _unused();

  @override
  Future<List<HomeworkItem>> queryHomeworkByStudentIds(List<String> ids) =>
      _unused();

  @override
  Future<HomeworkItem> insertHomework(HomeworkItem item, String userRole) =>
      _unused();

  @override
  Future<List<HomeworkImageModel>> saveHomeworkImage(
    HomeworkImageModel image,
  ) => _unused();

  @override
  Future<SavedHomeworkImages> saveHomeworkImages(
    List<HomeworkImageModel> images,
  ) => _unused();

  @override
  Future<List<HomeworkImageModel>> queryHomeworkImages(String studentId) =>
      _unused();

  @override
  Future<List<HomeworkImageModel>> queryHomeworkImagesByHomeworkId(
    String homeworkId,
  ) => _unused();

  @override
  Future<void> deleteHomework(String id) => _unused();

  @override
  Future<void> deleteHomeworkImagesByHomeworkId(String homeworkId) => _unused();

  @override
  Future<int> countHomeworkImages(String homeworkId) => _unused();
}

Never _unused() =>
    throw UnimplementedError('这个替身只实现 updateHomework —— 走到这里说明调用方多做了什么');

class _MemoryFocus implements FocusRepository {
  final List<FocusSession> saved = <FocusSession>[];
  Object? error;

  @override
  Future<void> saveFocusSession(FocusSession session) async {
    final e = error;
    if (e != null) throw e;
    // 按 id 覆盖，跟服务端/本地库一样是 upsert：
    // 若这里每次 add 一条，测试就测不出「检查点重复保存不会翻倍」。
    final index = saved.indexWhere((s) => s.id == session.id);
    if (index >= 0) {
      saved[index] = session;
    } else {
      saved.add(session);
    }
  }

  @override
  Future<List<FocusSession>> queryFocusSessions({
    required String studentId,
    required String from,
    required String to,
  }) async =>
      saved.where((s) => s.studentId == studentId).toList();
}

class _MemoryStorage implements ImageStorageService {
  @override
  void deleteImage(String storageKey) {}

  @override
  Uint8List? readImage(String storageKey) => null;

  @override
  Future<HomeworkImageModel> saveHomeworkImage({
    required String studentId,
    required String fileName,
    required Uint8List bytes,
    String? homeworkId,
    String? mimeType,
    String ocrStatus = 'pending',
    String ocrText = '',
    String batchId = '',
    int sortOrder = 0,
  }) => _unused();
}

const int _recordedBefore = 300; // 这份作业此前已经记了 5 分钟

/// 内存版提示存储：判据不该依赖 SQLite。
class _MemoryTipStore implements KnowledgeTipStore {
  final List<KnowledgeTip> rows = <KnowledgeTip>[];
  int writes = 0;

  @override
  Future<List<KnowledgeTip>> queryKnowledgeTips({
    required String studentId,
    required String subject,
  }) async {
    final result = rows
        .where((row) => row.studentId == studentId && row.subject == subject)
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return result;
  }

  @override
  Future<void> replaceKnowledgeTips({
    required String studentId,
    required String subject,
    required List<KnowledgeTip> tips,
  }) async {
    writes += 1;
    rows.removeWhere(
      (row) => row.studentId == studentId && row.subject == subject,
    );
    rows.addAll(tips);
  }
}

/// 只替换「归纳提示」这一件事的 AI：其余能力沿用本地实现。
class _FakeTipsAi extends SimulatedAiDataSource {
  _FakeTipsAi(this.drafts);

  final List<MistakeTipDraft> drafts;
  int calls = 0;
  Object? error;

  @override
  Future<List<MistakeTipDraft>> summarizeMistakeTips({
    required String subject,
    required List<MistakeTipSeed> items,
  }) async {
    calls += 1;
    final e = error;
    if (e != null) throw e;
    return drafts;
  }
}

ReviewMistake _mistake({
  required String id,
  required String point,
  int wrongCount = 1,
  String subject = '数学',
  DateTime? masteredAt,
}) => ReviewMistake(
  id: id,
  subject: subject,
  title: '数学作业A · $point',
  originalAnswer: '（学生的错误答案）',
  wrongReason: '这一步没有先通分',
  createdAt: DateTime(2026, 10, 10),
  state: ReviewState.pending,
  studentId: 'stu_001',
  knowledgePoint: point,
  wrongCount: wrongCount,
  lastWrongAt: DateTime(2026, 10, 15),
  masteredAt: masteredAt,
);

HomeworkItem _item() => HomeworkItem(
  id: 'hw_timer',
  title: '数学练习册 P28',
  subject: '数学',
  imageUrl: '',
  dueAt: DateTime(2026, 10, 19),
  estimatedMinutes: 30,
  actualSeconds: _recordedBefore,
  status: HomeworkStatus.pending,
  wrongCount: 0,
  aiEnabled: true,
  needsGrading: true,
  userRole: 'student',
  studentId: 'stu_001',
);

/// 带「打开」按钮的宿主页：`FocusTimerPage` 要能 pop，不能是根路由。
class _Host extends StatelessWidget {
  const _Host({
    required this.timer,
    required this.controller,
    this.tips,
    this.onRestReminder,
  });

  final FocusTimerService timer;
  final StudentController controller;
  final KnowledgeTipService? tips;
  final Future<void> Function(String message)? onRestReminder;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Builder(
        builder: (inner) => Center(
          child: TextButton(
            onPressed: () => Navigator.of(inner).push<String>(
              MaterialPageRoute(
                builder: (_) => FocusTimerPage(
                  target: FocusTarget.homework(_item()),
                  controller: controller,
                  timer: timer,
                  tips: tips,
                  onRestReminder: onRestReminder,
                ),
              ),
            ),
            child: const Text('打开计时'),
          ),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  late _Clock clock;
  late FocusTimerService timer;
  late _FakeHomework repo;
  late _MemoryFocus focusRepo;
  late StudentController controller;

  setUp(() {
    clock = _Clock();
    timer = FocusTimerService(clock: clock.call);
    repo = _FakeHomework();
    focusRepo = _MemoryFocus();
    // 写流水要知道「记在谁名下」，所以这里必须有登录态。
    Get.put(AuthController()).currentUser.value = UserModel(
      id: 'stu_001',
      name: '林小宇',
      phone: '13800000001',
      role: 'student',
      avatar: '',
    );
    controller = StudentController(
      aiCheckDelay: Duration.zero,
      homework: repo,
      focus: focusRepo,
      imageStorage: _MemoryStorage(),
      clock: clock.call,
    )..homeworkList.add(_item());
  });

  tearDown(() {
    // 用 `reset()` 而不是 `dispose()`：页面可能还挂在树上（用例中途失败时），
    // 而 `dispose()` 会把它正在读的 ValueNotifier 一起废掉 ——
    // 收尾时抛的「used after being disposed」会把真正的失败原因盖掉。
    // 每个用例都是新实例，不 dispose 不会串数据。
    timer.reset();
  });

  Future<void> open(
    WidgetTester tester, {
    KnowledgeTipService? tips,
    Future<void> Function(String message)? onRestReminder,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _Host(
          timer: timer,
          controller: controller,
          tips: tips,
          onRestReminder: onRestReminder,
        ),
      ),
    );
    await tester.tap(find.text('打开计时'));
    // 不能用 pumpAndSettle：这一屏有一个每秒触发的 ticker，
    // 它会一直安排新帧，settle 永远等不到。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('打开即开始计时，数字来自墙钟差', (tester) async {
    await open(tester);
    expect(find.byType(FocusTimerPage), findsOneWidget);
    expect(timer.status.value, FocusTimerStatus.running);
    expect(find.text('00:00:00'), findsOneWidget);

    clock.advance(5);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('00:00:05'), findsOneWidget);
  });

  testWidgets('暂停：数字冻结、立刻写一次检查点', (tester) async {
    await open(tester);
    clock.advance(5);
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.pump();
    await tester.pump();

    expect(timer.status.value, FocusTimerStatus.paused);
    expect(repo.patches, hasLength(1), reason: '暂停是个天然的检查点，要顺手存一次');
    expect(
      repo.patches.single.toMap()['actualSeconds'],
      305,
      reason: '写的是「此前 300 秒 + 本次 5 秒」的总量，不是增量 5',
    );

    // 暂停十分钟：数字不能动。
    clock.advance(600);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('00:00:05'), findsOneWidget);
    expect(timer.sessionSeconds, 5);
  });

  testWidgets('继续：接着上一次的数字走，不清零', (tester) async {
    await open(tester);
    clock.advance(5);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.pump();

    clock.advance(600);
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    clock.advance(3);
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('00:00:08'), findsOneWidget);
  });

  testWidgets('离开应用：自动暂停并保存，回来不会继续偷偷计时', (tester) async {
    // 用例中途断言失败会把 binding 留在 paused 状态，连累后面的用例
    // （paused 时 `pump` 不产生帧，pop 动画永远跑不完）。
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    await open(tester);
    clock.advance(7);
    await tester.pump(const Duration(seconds: 1));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump();

    expect(timer.status.value, FocusTimerStatus.paused);
    expect(timer.autoPaused.value, isTrue);
    expect(repo.patches.last.toMap()['actualSeconds'], 307);

    clock.advance(3600);
    await tester.pump(const Duration(seconds: 1));
    expect(
      timer.sessionSeconds,
      7,
      reason: '手机放桌上一小时，不能记成学习一小时',
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('结束并保存：写库成功才清会话并退出', (tester) async {
    await open(tester);
    clock.advance(12);
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.text('结束并保存'));
    await tester.pump();
    await tester.pump();
    // 退场动画要跑完，路由才从树上摘掉；摘掉之后还需要一帧做收尾。
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(find.byType(FocusTimerPage), findsNothing);
    expect(timer.hasSession, isFalse, reason: '不清会话，卡片会永远显示「计时中」');
    expect(repo.patches.last.toMap()['actualSeconds'], 312);
    // 内存里那份作业也要跟着变 —— 卡片读的是它。
    expect(controller.homeworkList.single.actualSeconds, 312);
  });

  testWidgets('保存失败：留住会话，把原因显示出来', (tester) async {
    await open(tester);
    clock.advance(9);
    await tester.pump(const Duration(seconds: 1));

    repo.error = Exception('网络断了');
    await tester.tap(find.text('结束并保存'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(FocusTimerPage), findsOneWidget, reason: '保存失败不能悄悄退出');
    expect(timer.hasSession, isTrue, reason: '失败时把会话清掉 = 这段计时彻底丢了');
    expect(timer.sessionSeconds, 9);
    expect(find.textContaining('稍后重试'), findsOneWidget);
  });

  // ===== 知识点提示 =====

  testWidgets('提示按当前作业科目显示；「换一条」轮换到下一条', (tester) async {
    controller.mistakes.addAll([
      _mistake(id: 'm1', point: '一元二次方程', wrongCount: 3),
      _mistake(id: 'm2', point: '分式化简'),
      // 另一个科目的错题不能出现在「数学」的提示里。
      _mistake(id: 'm3', point: '古诗默写', subject: '语文', wrongCount: 9),
    ]);

    final store = _MemoryTipStore();
    final ai = _FakeTipsAi(const [
      MistakeTipDraft(
        knowledgePoint: '一元二次方程',
        text: '求根前先算判别式，再决定用公式还是因式分解。',
      ),
      MistakeTipDraft(
        knowledgePoint: '分式化简',
        text: '分式加减先通分，分子相加减时分母保持不变。',
      ),
    ]);
    final tips = KnowledgeTipService(ai: ai, store: store, clock: clock.call);

    await open(tester, tips: tips);
    await tester.pump();

    expect(find.text('数学 · 知识点提示'), findsOneWidget);
    expect(find.text('求根前先算判别式，再决定用公式还是因式分解。'), findsOneWidget);

    await tester.tap(find.text('换一条'));
    await tester.pump();
    expect(find.text('分式加减先通分，分子相加减时分母保持不变。'), findsOneWidget);

    expect(ai.calls, 1);
    expect(store.writes, 1, reason: '模型提示要落缓存，下次进页面不必再问一遍');
    expect(
      store.rows.every((tip) => tip.subject == '数学'),
      isTrue,
      reason: '语文的错题不该被算进数学的提示',
    );
  });

  // ===== 休息提醒 =====

  testWidgets('连续 40 分钟：变暖色、出提醒卡、只念一次', (tester) async {
    final announced = <String>[];
    await open(tester, onRestReminder: (message) async => announced.add(message));

    clock.advance(40 * 60);
    await tester.pump(const Duration(seconds: 1));

    expect(timer.restDue.value, isTrue);
    expect(find.text('该让眼睛歇一会儿了'), findsOneWidget);
    expect(
      find.textContaining('已经连续专注 40 分钟'),
      findsOneWidget,
      reason: '字幕必须写清「连续多久」，否则学生不知道这条提醒是怎么来的',
    );
    expect(announced, hasLength(1));

    // 再过五分钟：提醒还在，但不能每帧都念一遍。
    clock.advance(5 * 60);
    await tester.pump(const Duration(seconds: 1));
    expect(announced, hasLength(1), reason: '提醒是一个状态，不是一次事件');
  });

  testWidgets('「再学 10 分钟」：提醒收回，10 分钟后再出现', (tester) async {
    final announced = <String>[];
    await open(tester, onRestReminder: (message) async => announced.add(message));

    clock.advance(40 * 60);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('该让眼睛歇一会儿了'), findsOneWidget);

    await tester.tap(find.text('再学 10 分钟'));
    await tester.pump();
    expect(find.text('该让眼睛歇一会儿了'), findsNothing);
    expect(timer.restDue.value, isFalse);

    clock.advance(9 * 60);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('该让眼睛歇一会儿了'), findsNothing, reason: '还没到 10 分钟');

    clock.advance(60);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('该让眼睛歇一会儿了'), findsOneWidget);
    expect(announced, hasLength(2));
  });

  testWidgets('「好，去休息」：暂停并保存，连续时长清零', (tester) async {
    await open(tester, onRestReminder: (_) async {});

    clock.advance(41 * 60);
    await tester.pump(const Duration(seconds: 1));
    expect(timer.restDue.value, isTrue);

    await tester.tap(find.text('好，去休息'));
    await tester.pump();
    await tester.pump();

    expect(timer.status.value, FocusTimerStatus.paused, reason: '起身了就该停表，不然这段休息会被记成学习');
    expect(timer.restDue.value, isFalse);
    expect(timer.continuous, 0);
    expect(
      repo.patches.last.toMap()['actualSeconds'],
      _recordedBefore + 41 * 60,
    );
  });
}
