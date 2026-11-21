import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/chat_controller.dart';
import 'package:easy_learn_app/models/chat_message_model.dart';
import 'package:easy_learn_app/models/relationship_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/pages/shared/chat_page.dart';
import 'package:easy_learn_app/utils/day_label.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 真机反馈：「结伴消息里看不出时间，应该和微信类似，不同日期明显能看出来」。
///
/// ── 改之前的状态 ────────────────────────────────────────────────────────
///
/// `ChatPage` 的气泡里**只有正文**：没有日期分隔，也没有时刻。
/// 两条相隔三天的消息在界面上长得一模一样，用户分不清哪句是昨天说的。
///
/// ## 为什么时间格式化要抽成纯函数
///
/// 「今天 / 昨天 / 星期三 / 10月12日」的边界比看上去多：跨年、跨月、
/// 一周内、设备时钟比服务器快几秒（消息时间落在"未来"）。
/// 写在 widget 里这些边界只能靠截图看，而截图看不出「12月31日的昨天是1月1日」。
/// 抽出来之后 `now` 可以注入，每条边界都能单独钉住。
///
/// ## 一个容易写错的地方：`inDays` 不是"日历天"
///
/// 23:59 和次日 00:01 的 `difference().inDays` 是 **0**（不满 24 小时），
/// 但它们跨天了。所以判断"同一天"必须比年月日，判断"隔几天"必须先把
/// 时刻归零再相减 —— 下面两条判据就是在钉这个。
void main() {
  group('日期文案（纯函数）', () {
    final now = DateTime(2026, 10, 20, 15, 30); // 星期二

    test('当天 → 今天', () {
      expect(formatDayLabel(DateTime(2026, 10, 20, 0, 5), now: now), '今天');
      expect(formatDayLabel(DateTime(2026, 10, 20, 23, 59), now: now), '今天');
    });

    test('隔一天 → 昨天（按日历天，不是满 24 小时）', () {
      expect(
        formatDayLabel(DateTime(2026, 10, 19, 23, 59), now: now),
        '昨天',
        reason: '23:59 到次日 00:01 只隔两分钟，但它就是昨天',
      );
    });

    test('一周内 → 星期几', () {
      expect(formatDayLabel(DateTime(2026, 10, 18), now: now), '星期日');
      expect(formatDayLabel(DateTime(2026, 10, 14), now: now), '星期三');
    });

    test('超过一周、同年 → 月日', () {
      expect(formatDayLabel(DateTime(2026, 10, 13), now: now), '10月13日');
      expect(formatDayLabel(DateTime(2026, 3, 2), now: now), '3月2日');
    });

    test('跨年 → 带年份', () {
      expect(
        formatDayLabel(DateTime(2025, 12, 31), now: now),
        '2025年12月31日',
      );
    });

    test('跨年的「昨天」仍然说昨天', () {
      final newYear = DateTime(2026, 1, 1, 9);
      expect(formatDayLabel(DateTime(2025, 12, 31, 22), now: newYear), '昨天');
    });

    test('时间落在未来（设备时钟偏快）→ 今天，不显示负数或日期', () {
      expect(
        formatDayLabel(DateTime(2026, 10, 20, 23, 59), now: now),
        '今天',
      );
    });

    test('同一天判断：只比年月日', () {
      expect(
        isSameCalendarDay(
          DateTime(2026, 10, 20, 0, 1),
          DateTime(2026, 10, 20, 23, 59),
        ),
        isTrue,
        reason: 'inDays 会说这两条差 0 天，但必须靠年月日判断才不受时刻影响',
      );
      expect(
        isSameCalendarDay(DateTime(2026, 10, 19, 23, 59), DateTime(2026, 10, 20, 0, 1)),
        isFalse,
      );
    });

    test('时刻补零', () {
      expect(formatClock(DateTime(2026, 10, 20, 9, 5)), '09:05');
      expect(formatClock(DateTime(2026, 10, 20, 14, 30)), '14:30');
      expect(formatClock(DateTime(2026, 10, 20, 0, 0)), '00:00');
    });
  });

  group('聊天界面（分隔条真的画出来了）', () {
    setUp(() {
      Get.put(AuthController());
      Get.find<AuthController>().currentUser.value = UserModel(
        id: 'stu-1',
        name: '林小宇',
        phone: '13800000001',
        role: 'student',
        avatar: 'student',
      );
    });

    tearDown(Get.reset);

    Future<void> pumpWith(WidgetTester tester, List<ChatMessageModel> seed) async {
      Get.put<ChatController>(_SeedChatController(seed: seed));
      await tester.pumpWidget(const GetMaterialApp(home: ChatPage()));
      await tester.pump();
    }

    ChatMessageModel msg(String id, DateTime at, {bool mine = false}) =>
        ChatMessageModel(
          id: id,
          relationshipId: 'rel-1',
          senderId: mine ? 'stu-1' : 'par-1',
          receiverId: mine ? 'par-1' : 'stu-1',
          content: '内容 $id',
          createdAt: at,
          isRead: true,
        );

    testWidgets('跨天的消息之间出现日期分隔条', (tester) async {
      final today = DateTime.now();
      final yesterday = today.subtract(const Duration(days: 1));
      await pumpWith(tester, [
        msg('a', DateTime(yesterday.year, yesterday.month, yesterday.day, 21)),
        msg('b', DateTime(today.year, today.month, today.day, 9), mine: true),
      ]);

      expect(find.text('昨天'), findsOneWidget);
      expect(find.text('今天'), findsOneWidget);
    });

    testWidgets('同一天的多条消息只出现一次分隔条', (tester) async {
      final today = DateTime.now();
      await pumpWith(tester, [
        msg('a', DateTime(today.year, today.month, today.day, 8)),
        msg('b', DateTime(today.year, today.month, today.day, 12), mine: true),
        msg('c', DateTime(today.year, today.month, today.day, 20)),
      ]);

      expect(
        find.text('今天'),
        findsOneWidget,
        reason: '每条都插一次日期会把聊天记录变成一张表',
      );
    });

    testWidgets('每条消息都带时刻', (tester) async {
      final today = DateTime.now();
      await pumpWith(tester, [
        msg('a', DateTime(today.year, today.month, today.day, 8, 5)),
        msg('b', DateTime(today.year, today.month, today.day, 14, 30), mine: true),
      ]);

      expect(find.text('08:05'), findsOneWidget);
      expect(find.text('14:30'), findsOneWidget);
    });
  });
}

/// 直接把预置消息塞进控制器，绕开仓储 —— 这一组测的是**渲染**，
/// 读消息本身已经有 `chat_send_visibility_test.dart` 在盯。
class _SeedChatController extends ChatController {
  _SeedChatController({required this.seed});

  final List<ChatMessageModel> seed;

  @override
  Future<void> load(String userId) async {
    relationships.assignAll([
      RelationshipModel(
        id: 'rel-1',
        studentId: 'stu-1',
        parentId: 'par-1',
        senderId: 'par-1',
        studentName: '林小宇',
        parentName: '王老师',
        status: RelationshipStatus.active,
      ),
    ]);
    selectedRelationshipId.value = 'rel-1';
    messages.value = List<ChatMessageModel>.of(seed);
  }
}
