import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/notification_controller.dart';
import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/controllers/point_controller.dart';
import 'package:easy_learn_app/models/chat_message_model.dart';
import 'package:easy_learn_app/models/daily_comment_model.dart';
import 'package:easy_learn_app/models/notification_model.dart';
import 'package:easy_learn_app/models/point_model.dart';
import 'package:easy_learn_app/models/relationship_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/models/wish_model.dart';
import 'package:easy_learn_app/pages/parent/parent_home_page.dart';
import 'package:easy_learn_app/pages/parent/tabs/wishes_parent_tab.dart';
import 'package:easy_learn_app/pages/shared/notifications_page.dart';
import 'package:easy_learn_app/repositories/notification_repository.dart';
import 'package:easy_learn_app/repositories/point_repository.dart';
import 'package:easy_learn_app/repositories/relationship_repository.dart';
import 'package:easy_learn_app/repositories/wish_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 「孩子申请兑现之后，家长端**看不到、也点不到**同意/拒绝」。
///
/// ## 真机上报的形态
///
/// > 积分兑换逻辑里，当家长设置了愿望需要的积分以后，学生端确认，点申请兑换以后，
/// > 在家长端没有确认的功能，还是停在上一次设置积分以后发给学生确认的页面。
///
/// 查库的结果是：**服务端那一行是对的** —— `redeem_requested_at` 已写入、
/// `parent_confirmed = true`、`student_confirmed = false`，
/// 家长还收到了一条「孩子想兑换心愿」。所以画面停在「等待学生确认」，
/// 只能是**客户端手里那份数据是登录那一刻的快照**。
///
/// 而家长端此前**没有任何重拉入口**：`loadData()` 只在 `onInit` 跑一次，
/// 五个 tab 一个下拉刷新都没有，通知点了也只标已读。于是「确认功能」在界面上
/// 确实不存在 —— 功能没丢，是路断了。这一组盯的就是这几条路。
const parentId = 'p_1';
const studentId = 's_1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  tearDown(() async {
    Get.closeAllSnackbars();
    Get.reset();
  });

  UserModel parent() => UserModel(
    id: parentId,
    name: '李鹏',
    phone: '18684960521',
    role: 'parent',
    avatar: '👨',
  );

  /// 孩子在**另一台设备**上刚点完「申请兑换」之后，服务端那一行长这样。
  WishModel wish({DateTime? requestedAt}) => WishModel(
    id: 'w_1',
    title: '买猫七夜周边',
    description: '攒了很久',
    isPublic: true,
    parentConfirmed: true,
    studentConfirmed: false,
    isArchived: false,
    studentId: studentId,
    pointCost: 3,
    redeemRequestedAt: requestedAt,
  );

  /// 只把 `loadData` 摘掉（它会拉一整套家长端数据、连库），
  /// `onInit` 里那条 `ever(selectedStudentId, …)` 订阅照常生效 ——
  /// 同 `wish_cost_dialog_test.dart` 的做法与理由。
  ParentController installParent({WishRepository? wishes}) {
    Get.put(PointController(repository: _StubPointRepo()), permanent: true);
    final parent = Get.put<ParentController>(
      _NoLoadParentController(
        wishes: wishes ?? _StubWishRepo(reads: []),
        relationships: _StubRelationshipRepo(),
      ),
    );
    return parent;
  }

  void installParentUser() {
    Get.put(AuthController()).currentUser.value = parent();
  }

  group('控制器：refreshWishes 真的会把服务端新写入的申请捞进来', () {
    test('申请之前是「等待学生确认」，重拉之后变成「孩子申请兑现」', () async {
      installParentUser();
      // 第一次读到的还是申请之前的样子；之后读到申请已经写入的样子 ——
      // 模拟孩子在那台手机上点了「申请兑换」。
      final repo = _StubWishRepo(
        reads: [
          wish(),
          wish(requestedAt: DateTime.now()),
        ],
      );
      final parent = installParent(wishes: repo)
        ..selectedStudentId.value = studentId;

      await parent.refreshWishes();
      expect(repo.readCount, 1, reason: '前置：重拉确实读了一次');
      expect(
        parent.wishes.single.isRedeemPending,
        isFalse,
        reason: '前置：这一份是申请之前的快照，界面上只有「设置积分」',
      );

      await parent.refreshWishes();

      expect(
        repo.readCount,
        2,
        reason: '判据打在**真的又读了一次**上：只在内存里改字段的话，别的设备做的事永远进不来',
      );
      expect(
        parent.wishes.single.isRedeemPending,
        isTrue,
        reason: '捞到申请之后，心愿页才有依据显示「同意并扣 N 分 / 拒绝」',
      );
    });
  });

  group('界面：申请进来之后，同意 / 拒绝 两个按钮要在', () {
    /// 三种状态各自渲染一次，互相做**反面**。
    Future<void> openWith(WidgetTester tester, WishModel w) async {
      installParentUser();
      final parent = installParent()..wishes.value = [w];
      // 心愿页展示的是**当前选中孩子**的心愿（`visibleWishes` 按
      // `_isSelectedChild` 过滤）。不选孩子的话这一页是空的，
      // 断言会以「找不到控件」的形式失败，看不出到底是哪一层的问题。
      parent.selectedStudentId.value = studentId;
      await tester.pumpWidget(
        GetMaterialApp(home: Scaffold(body: const WishesParentTab())),
      );
      await tester.pump();
    }

    testWidgets('待家长处理：出现「同意并扣 3 分」与「拒绝」，定价入口同时收起', (tester) async {
      await openWith(tester, wish(requestedAt: DateTime.now()));

      expect(find.text('孩子申请兑现'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, '同意并扣 3 分'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '拒绝'), findsOneWidget);
      // 孩子已经在申请了，这时候家长再改价就变成「按 3 分攒够、改成 30」。
      expect(find.widgetWithText(TextButton, '设置积分'), findsNothing);
    });

    testWidgets('反面：孩子还没申请时，不该出现「同意 / 拒绝」', (tester) async {
      await openWith(tester, wish());

      expect(find.text('等待学生确认'), findsOneWidget);
      expect(find.text('孩子申请兑现'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, '同意并扣 3 分'), findsNothing);
      expect(find.widgetWithText(TextButton, '设置积分'), findsOneWidget);
    });

    testWidgets('已兑现的心愿不再标「已逾期」', (tester) async {
      // 这是真机库里那条「下午去拼豆」的形状：到期日在过去、家长已兑现、
      // 但 `parentConfirmed` 还是 false（老数据）。修之前这里会显示
      // 「已兑现 + 已逾期 30 天」——同一张卡片自相矛盾。
      final redeemed = WishModel(
        id: 'w_done',
        title: '下午去拼豆',
        description: '攒了很久',
        isPublic: true,
        parentConfirmed: false,
        studentConfirmed: true,
        isArchived: false,
        studentId: studentId,
        pointCost: 3,
        expectedDate: DateTime.now().subtract(const Duration(days: 30)),
        redeemedAt: DateTime.now(),
      );
      await openWith(tester, redeemed);

      expect(find.text('已兑现'), findsOneWidget, reason: '前置：确实走的是已兑现分支');
      expect(
        find.textContaining('已逾期'),
        findsNothing,
        reason: '已经实现了的心愿不该再催日期',
      );
    });
  });

  group('家长端要有一个「拿到此刻数据」的入口', () {
    testWidgets('下拉刷新挂在真页面（ParentHomePage）上，而且真的会整页重拉', (tester) async {
      installParentUser();
      Get.put(PointController(repository: _StubPointRepo()), permanent: true);
      // 记下 `loadData` 被调了几次。真页面会把 `loadData` 交给
      // `RefreshIndicator.onRefresh`，所以这个计数就是「下拉有没有真的拉」。
      // 不这样测就只能自己把 `RefreshIndicator` 套在页面外面 ——
      // 那测的是测试自己搭的组合，生产接线断了它照样绿。
      final parent = _CountingParentController();
      Get.put<ParentController>(parent);

      await tester.pumpWidget(GetMaterialApp(home: const ParentHomePage()));
      await tester.pump();

      // 控制器建起来时 `onInit` 自己会拉一次，所以只能比**增量**。
      final before = parent.loadCalls;
      expect(find.byType(RefreshIndicator), findsOneWidget, reason: '前置：入口在');
      await tester.fling(
        find.byType(ListView).first,
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      expect(
        parent.loadCalls,
        before + 1,
        reason: '拉了一把却什么都没重拉 —— 家长会以为「刷过了，还是这样」',
      );
    });
  });

  group('通知点得进去', () {
    testWidgets('点「孩子想兑换心愿」，落在心愿页并且当场重拉', (tester) async {
      installParentUser();
      final repo = _StubWishRepo(reads: [wish()]);
      final parent = installParent(wishes: repo);
      final before = repo.readCount;

      final notifications = Get.put(
        NotificationController(
          database: _StubNotificationRepo(
            items: [
              AppNotificationModel(
                id: 'n_1',
                title: '孩子想兑换心愿',
                body: '《买猫七夜周边》申请兑现，需要 3 分',
                createdAt: DateTime.now(),
                isRead: false,
                targetUserId: parentId,
                type: NotificationType.wish,
                relatedBizId: 'w_1',
              ),
            ],
          ),
        ),
      );
      await notifications.loadNotifications();

      await tester.pumpWidget(GetMaterialApp(home: const NotificationsPage()));
      await tester.pump();

      await tester.tap(find.text('孩子想兑换心愿'));
      await tester.pump();

      expect(
        parent.currentTab.value,
        ParentTab.wishes,
        reason: '通知说的是心愿，落点却停在别处 —— 等于只告诉了用户，没给路',
      );
      expect(
        repo.readCount,
        greaterThan(before),
        reason: '跳过去必须重拉：否则落在那一屏看到的还是旧快照，白跳',
      );
      expect(
        notifications.notifications.first.isRead,
        isTrue,
        reason: '点过就算已读，红点该没',
      );
    });
  });
}

class _NoLoadParentController extends ParentController {
  _NoLoadParentController({super.wishes, super.relationships});

  @override
  Future<void> loadData() async {
    // 刻意不拉数据（连库）。
  }
}

/// 只数「整页重拉被叫了几次」，不真的去连库。
class _CountingParentController extends ParentController {
  int loadCalls = 0;

  @override
  Future<void> loadData() async {
    loadCalls++;
  }
}

/// 心愿仓储：按 [reads] 依次返回，读完之后一直返回最后一条。
///
/// 「服务端那一行变了」这件事只能靠**再读一次**看见 —— 所以
/// [readCount] 是这一组最要紧的观测点。
class _StubWishRepo implements WishRepository {
  _StubWishRepo({required this.reads});

  final List<WishModel> reads;
  int readCount = 0;

  WishModel get _next =>
      reads[readCount++ < reads.length ? readCount - 1 : reads.length - 1];

  @override
  Future<List<WishModel>> queryPublicWishesByStudent(String studentId) async =>
      [_next];

  @override
  Future<List<WishModel>> queryWishes(String userRole) =>
      throw UnimplementedError('这一组只看「孩子的心愿墙」');

  @override
  Future<List<WishModel>> queryPublicWishes() =>
      throw UnimplementedError('这一组只看「孩子的心愿墙」');

  @override
  Future<List<WishModel>> queryUnfulfilledWishes() =>
      throw UnimplementedError('这一组不看未闭环口径');

  @override
  Future<void> insertWish(WishModel wish, String userRole) =>
      throw UnimplementedError('这一组不建心愿');

  @override
  Future<void> updateWishConfirmation({
    required String id,
    bool? parentConfirmed,
    bool? studentConfirmed,
  }) => throw UnimplementedError('这一组不改确认状态');

  @override
  Future<void> updateWishArchived(String id, bool isArchived) =>
      throw UnimplementedError('这一组不归档');

  @override
  Future<void> updateWishRedeemState({
    required String id,
    int? pointCost,
    DateTime? redeemRequestedAt,
    DateTime? redeemedAt,
    DateTime? redeemRejectedAt,
    bool clearRedeemRequest = false,
    bool clearRedeemRejected = false,
  }) => throw UnimplementedError('这一组不做兑换动作');
}

class _StubRelationshipRepo implements RelationshipRepository {
  @override
  Future<List<RelationshipModel>> queryRelationships(String userId) async => [
    RelationshipModel(
      id: 'r_1',
      studentId: studentId,
      parentId: parentId,
      senderId: parentId,
      studentName: '李雨霏',
      parentName: '李鹏',
      status: RelationshipStatus.active,
    ),
  ];

  @override
  Future<RelationshipModel> createRelationshipInvitation({
    required String senderId,
    required String targetPhone,
  }) => throw UnimplementedError('这一组不发邀请');

  @override
  Future<void> updateRelationshipStatus({
    required String id,
    required RelationshipStatus status,
  }) => throw UnimplementedError('这一组不改关系状态');

  @override
  Future<void> revokeRelationship({required String id}) =>
      throw UnimplementedError('这一组不涉及解除结伴');

  @override
  Future<List<ChatMessageModel>> queryChatMessages({
    required String relationshipId,
    required String requesterId,
  }) => throw UnimplementedError('这一组不聊天');

  @override
  Future<ChatMessageModel> sendChatMessage({
    required String relationshipId,
    required String senderId,
    required String content,
  }) => throw UnimplementedError('这一组不聊天');
}

class _StubNotificationRepo implements NotificationRepository {
  _StubNotificationRepo({required this.items});

  final List<AppNotificationModel> items;

  @override
  Future<List<AppNotificationModel>> queryNotifications({
    String? userId,
  }) async => items;

  @override
  Future<void> insertNotification(AppNotificationModel notification) async {}

  @override
  Future<void> markNotificationRead(String id) async {}

  /// 这一组不测批量已读，但接口必须实现 —— 漏了它整个文件编译不过
  /// （`non_abstract_class_inherits_abstract_member`），而报错指向的是
  /// 这个 stub，看起来像「测试坏了」。
  @override
  Future<int> markAllNotificationsRead({String? userId}) async => 0;

  @override
  Future<void> insertDailyComment(DailyCommentModel comment) async {}

  @override
  Future<List<DailyCommentModel>> queryDailyComments() async => [];
}

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
