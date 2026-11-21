import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/shared/help_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

void main() {
  Future<void> pumpHelp(WidgetTester tester) async {
    // 帮助页会根据当前角色选默认视角，所以要先注册一个 AuthController。
    Get.put(
      AuthController(
        initialUser: UserModel(
          id: 'u1',
          name: '小明',
          phone: '13800000000',
          role: 'student',
          avatar: '',
        ),
      ),
    );
    await tester.pumpWidget(const GetMaterialApp(home: HelpPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// 帮助页是 ListView（懒构建），视口外的条目根本没 build。
  /// 「内容存在」的判据必须边滚边找。
  Future<bool> scrollUntilFound(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 20; i++) {
      if (finder.evaluate().isNotEmpty) return true;
      await tester.drag(find.byType(ListView).first, const Offset(0, -320));
      await tester.pump(const Duration(milliseconds: 120));
    }
    return finder.evaluate().isNotEmpty;
  }

  testWidgets('学生手册讲全了结伴→作业→计时→计划→复习→心愿', (tester) async {
    await pumpHelp(tester);

    // 结伴与日常流程的章节标题都在（首屏就能看到的几个）。
    expect(find.text('第一步：和家长结伴'), findsOneWidget);

    final checks = <String, bool>{};
    for (final title in [
      '哪些作业要 AI 批改，哪些只记完成',
      '写作业时：开专注计时',
      '计划和锻炼：家长布置，你来打卡',
      '复习：错题本的完整闭环',
      '心愿与积分',
    ]) {
      checks[title] = await scrollUntilFound(tester, find.text(title));
    }
    for (final entry in checks.entries) {
      expect(entry.value, isTrue, reason: '缺章节：${entry.key}');
    }

    // 四个状态 + 毕业规则（滚到复习章附近）。
    final statesFound = await scrollUntilFound(tester, find.text('已掌握'));
    expect(statesFound, isTrue, reason: '错题状态流转图缺「已掌握」');
    final streakFound =
        await scrollUntilFound(tester, find.textContaining('连续两轮'));
    expect(streakFound, isTrue, reason: '毕业规则「连续两轮」没找到');
  });

  testWidgets('顶部可切到家长视角', (tester) async {
    await pumpHelp(tester);

    expect(find.text('家长视角'), findsOneWidget);
    await tester.tap(find.text('家长视角'));
    await tester.pump(const Duration(milliseconds: 100));

    // 家长版的章节标题。
    expect(find.text('和孩子结伴'), findsOneWidget);
    final found = await scrollUntilFound(
      tester,
      find.text('看懂错题本：孩子的复习闭环'),
    );
    expect(found, isTrue, reason: '家长视角缺错题本章节');
  });

  testWidgets('FAQ 默认收起，点开后能看到答案', (tester) async {
    await pumpHelp(tester);

    // 切到家长视角（FAQ 在家长版）。
    await tester.tap(find.text('家长视角'));
    await tester.pump(const Duration(milliseconds: 100));

    const q = '孩子导出卷子后，「待复习」里的题怎么不见了？';
    final foundQ = await scrollUntilFound(tester, find.text(q));
    expect(foundQ, isTrue, reason: 'FAQ 问题没找到');
    expect(find.textContaining('它们进了「复习中」'), findsNothing);

    // 确保问题文本完整落在视口内再点（否则 tap 点不到、只打警告）。
    await tester.ensureVisible(find.text(q));
    await tester.pumpAndSettle();
    await tester.tap(find.text(q));
    await tester.pumpAndSettle();

    expect(find.textContaining('它们进了「复习中」'), findsOneWidget);
  });
}
