import 'dart:io';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/student/tabs/plan_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';

/// 「日常打卡」与「错题复习」必须分家（2026-11-12 虫子要求）。
///
/// 原话：「把这类概念打卡的部分，在学生端，全部做到计划里吧，放在复习里
/// 容易搞混。计划里都是日常的打卡，复习时针对做错题目的复习，两个不要
/// 混在一起了。」
///
/// ## 为什么既要静态判据又要页面判据
///
/// 静态那条盯的是**归属**：这三张卡（概念打卡 / 概念训练 / 单词打卡）不能再
/// 出现在复习页的源码里。页面那条盯的是**真的渲染出来了** —— 只把代码删掉
/// 而不往计划页加，静态断言照样绿，孩子却再也找不到入口。
///
/// 两条都不能省：一条防「搬回去」，一条防「搬丢了」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Directory? tempDir;

  setUpAll(() async {
    tempDir = await setUpTestDatabase();
  });

  tearDownAll(() async {
    final dir = tempDir;
    if (dir != null) await tearDownTestDatabase(dir);
  });

  setUp(() async {
    Get.testMode = true;
    Get.put(AuthController()).currentUser.value = UserModel(
      id: 'stu_001',
      name: '林小宇',
      phone: '13800000001',
      role: 'student',
      avatar: '',
    );
    await Get.put(StudentController(aiCheckDelay: Duration.zero)).loadData();
  });

  tearDown(Get.reset);

  testWidgets('计划页有「今日打卡」一区，概念训练与单词打卡都在里面', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PlanTab())));
    await tester.pump();
    // 这几张卡各自会读本机状态（今日概念训练进度 / 单词打卡 / 阅读任务），
    // 而 `StudentController` 自己也在拉数据。sqflite 在 fakeAsync 下不推进
    // 事务，会把事务锁的 10 秒 Timer 留着，测试以「A Timer is still pending」
    // 收场 —— 让真实 I/O 多跑几轮再断言。
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pump();
    }

    expect(find.text('今日打卡'), findsOneWidget, reason: '分区标题是这一区的入口语义');
    expect(
      // 卡上文案随状态变（「今日概念训练」/「今日概念训练 · 6 题」/「正在做…」），
      // 所以按前缀断 —— 断死一句话会在换状态时变成假红。
      find.textContaining('今日概念训练'),
      findsOneWidget,
      reason: '搬丢了的话孩子就找不到每天那 6 道题',
    );
    // 词表没配时单词卡显示引导文案；配了会变成「英语单词 · 今日 N 题」。
    // 两种都算「卡在」，所以断的是它的两种文案之一。
    expect(
      find.textContaining('英语单词'),
      findsOneWidget,
      reason: '单词打卡入口必须也在计划页',
    );
    expect(find.text('学习计划'), findsOneWidget, reason: '长期计划还是自己一区');
  });

  test('复习页源码里不再出现日常打卡入口（防止哪天又被搬回去）', () {
    final source = _codeOf('lib/pages/student/tabs/review_tab.dart');
    for (final name in [
      'CheckinEntryCard',
      'DrillEntryCard',
      'WordDrillEntryCard',
      'DailyPracticeBlock',
    ]) {
      expect(
        source.contains(name),
        isFalse,
        reason: '复习页只回答「做错的题怎么复习」；日常打卡归计划页（$name）',
      );
    }
    // 反向：复习页仍在（别把整个文件删了让上面几条空转通过）。
    expect(source.contains('class ReviewTab'), isTrue);
  });

  test('计划页画出「今日打卡」大方块，三件小练在方块里（搬运的另一半）', () {
    // 2026-11-12 晚：三张并列卡合成**一个大方块**（虫子：「可以放在一起，
    // 例如一个大方块，里面列出这些训练项」）。所以判据分两层：
    // 计划页必须构造方块，方块必须构造那三行。
    final plan = _codeOf('lib/pages/student/tabs/plan_tab.dart');
    // 断**构造**而不是「文件里出现过这个名字」：后者在只留一行 import、
    // 或者卡片被注释掉时照样绿（这条判据第一版就这么骗过我一次）。
    for (final name in ['DailyPracticeBlock', 'ReadingTaskCard']) {
      expect(
        plan.contains('const $name('),
        isTrue,
        reason: '计划页应当真的把 $name 画出来',
      );
    }

    final block = _codeOf('lib/widgets/daily_practice_block.dart');
    for (final marker in [
      'Icons.fact_check_outlined', // 每日概念打卡
      'Icons.translate', // 今日概念训练
      'Icons.abc', // 英语单词打卡
    ]) {
      expect(
        block.contains(marker),
        isTrue,
        reason: '大方块里少了 $marker 那一行，孩子就找不到其中一件小练',
      );
    }
  });
}

/// 去掉注释行后的源码。
///
/// 注释里提到卡片名是很正常的事（「这里曾经放着 `DrillEntryCard`」），
/// 但按「源码里有没有这个名字」判断归属时，注释会让判据两头都骗人：
/// 既能把搬走的卡判成还在，也能把搬回来的卡判成没搬。
String _codeOf(String path) {
  final kept = <String>[];
  for (final line in File(path).readAsLinesSync()) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('//')) continue;
    kept.add(line);
  }
  return kept.join('\n');
}
