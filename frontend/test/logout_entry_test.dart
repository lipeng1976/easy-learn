import 'dart:io';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/notification_controller.dart';
import 'package:easy_learn_app/controllers/point_controller.dart';
import 'package:easy_learn_app/controllers/profile_controller.dart';
import 'package:easy_learn_app/models/chat_message_model.dart';
import 'package:easy_learn_app/models/point_model.dart';
import 'package:easy_learn_app/models/relationship_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/models/user_profile_model.dart';
import 'package:easy_learn_app/pages/shared/profile_page.dart';
import 'package:easy_learn_app/repositories/point_repository.dart';
import 'package:easy_learn_app/repositories/relationship_repository.dart';
import 'package:easy_learn_app/repositories/user_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';

/// 「退出登录」。
///
/// 在它之前，整套登出机制（`AuthController` / `AuthService` / `HttpAuthApi`）
/// 都是齐的，**只是没有任何界面调它** —— 全仓 `logout()` 的调用点只有一处，
/// 在 `test/cloud_live_test.dart` 里。所以这个功能缺失的形态是
/// 「用户找不到地方退出」，不是「点了没反应」。
///
/// 分两组测：
///
/// - **清理行为**用纯 `test()` 直接调控制器，跑在真时钟上。
/// - **界面**用 `testWidgets`：入口在不在、有没有确认、确认后去哪儿。
///   界面这组**把数据源换成假仓储**，理由见 [_StubUserRepo] 上面那段。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  Directory? tempDir;

  setUp(() async {
    tempDir = await setUpTestDatabase();
  });

  tearDown(() async {
    Get.reset();
    final dir = tempDir;
    if (dir != null) await tearDownTestDatabase(dir);
  });

  UserModel student() => UserModel(
    id: 'stu_001',
    name: '林小宇',
    phone: '13800000001',
    role: 'student',
    avatar: '👦',
  );

  group('退出登录要清的东西', () {
    test('身份清空、账号级缓存清空', () async {
      final auth = Get.put(AuthController());
      auth.currentUser.value = student();

      // 造出「有内容」的前置状态。这两处都不随路由回收：
      // `PointController` 是 `permanent: true`，`NotificationController`
      // 注册在 `app.dart`（那一刻还没有任何路由）。
      final points = PointController.to;
      await points.loadFor('stu_001');
      expect(points.studentId.value, 'stu_001', reason: '前置：缓存里确实有东西');

      final notifications = Get.put(NotificationController());
      expect(notifications.notifications, isNotEmpty, reason: '前置：演示通知是广播，对谁都可见');

      await auth.logout();

      expect(auth.currentUser.value, isNull);
      expect(
        points.studentId.value,
        isEmpty,
        reason: '不清的话，换账号后积分余额还是上一个人的 —— 界面正常，数字是别人的',
      );
      expect(points.ledger, isEmpty);
      expect(
        notifications.notifications,
        isEmpty,
        reason: '同上：不清的话，下一个登录者在自己的通知拉回来之前看到的是上一个人的列表',
      );
    });
  });

  group('个人信息页上的入口', () {
    /// 装载个人信息页，并把两个控制器换成假仓储。
    ///
    /// ## 为什么这一组不连真库
    ///
    /// 页面 `initState` 会发起一串**串行**查询：积分流水 → 积分规则 →
    /// 档案 → 结伴，四段排在同一条 sqflite 锁上。在 `testWidgets` 的假时钟里，
    /// 每一段都要「一段真实时间窗 + 一次 `pump`」才能走完 —— 而 `pump` 之间
    /// 并不会自动给真实时间，于是**永远差最后一段**：测试跑完时
    /// `queryRelationships` 还挂在锁超时定时器（10 秒）上。
    ///
    /// 失败形态很难认：断言全过，只有框架补一句
    /// 「A Timer is still pending even after the widget tree was disposed」，
    /// 以及一条「数据库已关闭」的迟到异常。看起来像测试写得不对，
    /// 其实是**被测页面之外的东西**在报错。
    ///
    /// 这一组考的是「退出登录的入口」，读不读库与它无关。换成即时返回的假仓储，
    /// 这条依赖就整条消失了。
    ///
    /// ⚠️ 依赖 GetX `_insert` 的一条语义：键已存在且未 dirty 时**不覆盖**
    /// （`get_instance.dart` 的 `_insert`）。页面里的 `Get.put(ProfileController())`
    /// 与 `PointController.to` 都会命中我们先注册的那一份。这条不能靠记忆 ——
    /// 所以下面用 `identical` 断言把它钉住：真要哪天换成覆盖注册，
    /// 失败的会是这句「页面必须用注入进来的那一份」，而不是某条看不出因果的超时。
    Future<AuthController> openProfile(WidgetTester tester) async {
      final auth = Get.put(AuthController());
      auth.currentUser.value = student();

      final points = Get.put(
        PointController(repository: _StubPointRepo()),
        permanent: true,
      );
      final profile = Get.put(
        ProfileController(
          users: _StubUserRepo(),
          relationships: _StubRelationshipRepo(),
        ),
      );

      // 用 `home:` 而不是 `initialRoute:` + `getPages:` 装入首屏。
      // 实测后者在这个环境下**什么都不渲染**（树里连 AppBar 都没有），
      // 而失败形态很不明显：只有 `find` 找不到东西。
      // `getPages` 仍然要给：退出登录最后一步是 `Get.offAllNamed('/login')`，
      // 它要能在路由表里找到这一条。
      await tester.pumpWidget(
        GetMaterialApp(
          home: const ProfilePage(),
          getPages: [
            GetPage(
              name: '/login',
              page: () => const Scaffold(
                body: Center(child: Text('登录页')),
              ),
            ),
          ],
        ),
      );

      expect(
        identical(Get.find<ProfileController>(), profile),
        isTrue,
        reason: '页面必须用注入进来的那一份，否则它又去查库了',
      );
      expect(
        identical(PointController.to, points),
        isTrue,
        reason: '同上：页面里那张积分卡走的是 PointController.to',
      );

      // 假仓储是即时返回的，两帧足够让 `initState` 的两笔 `load` 走完并回填。
      await tester.pump();
      await tester.pump();

      // 「退出登录」在页面最下方，而这个页面的 body 是 `ListView` ——
      // **懒加载**，视口外的子项根本不会被 build，`find` 自然找不到它。
      // 默认测试视口只有 800×600，上面还有积分卡、名称、性别、年级、兴趣、
      // 简介一大串。这不是「入口不在」，是「没滚到那儿」。
      await tester.scrollUntilVisible(
        find.text('退出当前账号'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      return auth;
    }

    Finder entry() => find.widgetWithText(OutlinedButton, '退出登录');
    Finder confirm() => find.widgetWithText(TextButton, '退出登录');

    testWidgets('入口在，并且写明了要退出哪个账号', (tester) async {
      await openProfile(tester);

      expect(find.text('退出当前账号'), findsOneWidget);
      expect(entry(), findsOneWidget);
      // 只写「退出登录」是不够的：同一台设备上家长和学生轮流登录是常态，
      // 用户需要能确认自己要走的不是孩子那个号。手机号打码，不印 PII。
      expect(find.text('当前登录：林小宇 · 学生（138****0001）'), findsOneWidget);
    });

    testWidgets('退出前必须确认一次；取消则什么都不发生', (tester) async {
      final auth = await openProfile(tester);

      await tester.tap(entry());
      await tester.pumpAndSettle();
      expect(find.text('退出登录？'), findsOneWidget);
      // 对话框里也写清退出的是谁 —— 这是用户唯一一次「确认」的机会。
      // 用带前缀的整句而不是只搜身份串：卡片上也有一模一样的身份串。
      expect(
        find.textContaining('将退出当前账号：林小宇 · 学生（138****0001）'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      // 「什么都不发生」= 还停在这一页、还带着身份。
      // （不断言 `Get.currentRoute`：首屏是用 `home:` 装的，那个值是 '/'。）
      expect(find.text('退出当前账号'), findsOneWidget);
      expect(auth.currentUser.value, isNotNull, reason: '取消不该把人退出去');
    });

    testWidgets('确认后回到登录页', (tester) async {
      final auth = await openProfile(tester);

      await tester.tap(entry());
      await tester.pumpAndSettle();
      await tester.tap(confirm());
      await tester.pumpAndSettle();

      expect(find.text('登录页'), findsOneWidget);
      expect(auth.currentUser.value, isNull);
    });
  });
}

/// ## 这一组用例的假仓储
///
/// 只实现被测路径真正会调到的那几个方法，其余**显式抛 `UnimplementedError`**
/// 而不是返回空值：返回空值的话，「页面开始调别的方法了」会安静地变成一个
/// 空列表，测试照样绿；抛错则当场指出是哪一条漏了。
///
/// `PointController` / `ProfileController` 都把数据源做成构造参数
/// （见各自的 `repository` / `users` + `relationships`），正是为了这种用法。
class _StubPointRepo implements PointRepository {
  @override
  Future<List<PointLedgerEntry>> queryPointLedger(String studentId) async => [];

  @override
  Future<List<PointRule>> queryPointRules(String studentId) async => [];

  @override
  Future<PointLedgerEntry?> findActivePointEntry({
    required String studentId,
    required String idempotencyKey,
  }) async => null;

  @override
  Future<bool> insertPointLedger(PointLedgerEntry entry) async => true;

  @override
  Future<void> markPointEntryReversed(String id, DateTime reversedAt) async {}

  @override
  Future<void> upsertPointRule(PointRule rule) async {}
}

class _StubUserRepo implements UserRepository {
  @override
  Future<UserProfileModel?> queryUserProfile(String userId) async =>
      UserProfileModel(
        userId: userId,
        name: '林小宇',
        gender: '男',
        grade: '五年级',
        hobbies: const ['阅读'],
        bio: '喜欢数学',
      );

  @override
  Future<List<Map<String, dynamic>>> queryUsersByIds(List<String> ids) async =>
      const [];

  @override
  Future<void> updateUserProfile(UserProfileModel profile) async {}
}

class _StubRelationshipRepo implements RelationshipRepository {
  @override
  Future<List<RelationshipModel>> queryRelationships(String userId) async =>
      const [];

  @override
  Future<RelationshipModel> createRelationshipInvitation({
    required String senderId,
    required String targetPhone,
  }) => throw UnimplementedError('这一组用例不涉及发邀请');

  @override
  Future<void> updateRelationshipStatus({
    required String id,
    required RelationshipStatus status,
  }) => throw UnimplementedError('这一组用例不涉及改关系状态');

  @override
  Future<void> revokeRelationship({required String id}) =>
      throw UnimplementedError('这一组用例不涉及解除结伴');

  @override
  Future<List<ChatMessageModel>> queryChatMessages({
    required String relationshipId,
    required String requesterId,
  }) => throw UnimplementedError('这一组用例不涉及聊天');

  @override
  Future<ChatMessageModel> sendChatMessage({
    required String relationshipId,
    required String senderId,
    required String content,
  }) => throw UnimplementedError('这一组用例不涉及聊天');
}
