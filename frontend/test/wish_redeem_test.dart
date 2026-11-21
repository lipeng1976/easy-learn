import 'dart:io';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/notification_controller.dart';
import 'package:easy_learn_app/controllers/parent_controller.dart';
import 'package:easy_learn_app/controllers/point_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/point_model.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/models/wish_model.dart';
import 'package:easy_learn_app/services/database_service.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';

/// 愿望兑换闭环：许愿 → 家长定价 → 孩子申请 → 家长兑现（扣分）。
///
/// 这套流程里最容易错的是**扣分时机**。孩子一申请就扣，家长要是拒绝，
/// 就成了「分没了、愿望也没实现」—— 这种账孩子会记很久，而且没法补偿。
/// 所以这里的断言全围着「什么时候余额会动」写。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  Directory? tempDir;
  late AuthController auth;

  setUp(() async {
    tempDir = await setUpTestDatabase();
    auth = Get.put(AuthController());
    Get.put(NotificationController());
  });

  tearDown(() async {
    Get.reset();
    final dir = tempDir;
    if (dir != null) await tearDownTestDatabase(dir);
  });

  void loginAs(String id, String role, {String name = ''}) {
    auth.currentUser.value = UserModel(
      id: id,
      name: name,
      phone: '',
      role: role,
      avatar: '',
    );
  }

  Future<void> seedWish({
    required String id,
    String title = '去游乐园',
    String studentId = 'stu_001',
    int pointCost = 0,
    bool confirmed = true,
  }) async {
    await DatabaseService.instance.insertWish(
      WishModel(
        id: id,
        title: title,
        description: '想去玩一天',
        isPublic: true,
        parentConfirmed: confirmed,
        studentConfirmed: confirmed,
        isArchived: false,
        studentId: studentId,
        pointCost: pointCost,
      ),
      'student',
    );
  }

  Future<int> balanceOf(String studentId) async {
    return PointController.to.balanceOf(studentId);
  }

  Future<void> givePoints(String studentId, int points) async {
    await PointController.to.grantReward(
      studentId: studentId,
      points: points,
      reason: '测试发放',
      createdBy: 'par_001',
    );
  }

  test('家长定价后孩子的余额没有变化', () async {
    await seedWish(id: 'w_cost');
    loginAs('par_001', 'parent', name: '王老师');
    final parent = ParentController();
    await parent.loadData();
    parent.selectedStudentId.value = 'stu_001';

    await parent.setWishPointCost('w_cost', 30);

    final wishes = await DatabaseService.instance.queryWishes('student');
    // 演示数据里本来就有心愿，按 id 取自己造的那条
    expect(wishes.firstWhere((w) => w.id == 'w_cost').pointCost, 30);
    expect(await balanceOf('stu_001'), 0, reason: '定价只是标价，不是扣费');
  });

  test('孩子申请兑换：只登记意向，一分都不扣', () async {
    await seedWish(id: 'w_apply', pointCost: 30);
    await givePoints('stu_001', 50);

    loginAs('stu_001', 'student', name: '林小宇');
    final student = StudentController(
      aiCheckDelay: Duration.zero,
      imageStorage: LocalImageStorageService(useMemory: true),
    );
    await student.loadData();
    await student.requestWishRedeem('w_apply');

    final wish = student.wishes.firstWhere((w) => w.id == 'w_apply');
    expect(wish.isRedeemPending, isTrue);
    expect(wish.redeemedAt, isNull);
    // 关键断言：申请本身不扣分
    expect(await balanceOf('stu_001'), 50);
  });

  test('家长兑现：这一刻才扣分，并标记已兑现', () async {
    // 前置必须是「家长还没确认过」，否则「兑现要不要写 parentConfirmed」
    // 这条断言永远绿 —— 种子数据自己就是 true，测不出任何东西。
    await seedWish(id: 'w_ok', pointCost: 30, confirmed: false);
    await givePoints('stu_001', 50);

    loginAs('stu_001', 'student');
    final student = StudentController(
      aiCheckDelay: Duration.zero,
      imageStorage: LocalImageStorageService(useMemory: true),
    );
    await student.loadData();
    await student.requestWishRedeem('w_ok');

    loginAs('par_001', 'parent', name: '王老师');
    final parent = ParentController();
    await parent.loadData();
    parent.selectedStudentId.value = 'stu_001';
    final result = await parent.approveWishRedeem('w_ok');

    expect(result.ok, isTrue, reason: result.message);
    expect(await balanceOf('stu_001'), 20);

    final wish = parent.wishes.firstWhere((w) => w.id == 'w_ok');
    expect(wish.isRedeemed, isTrue);
    expect(wish.isRedeemPending, isFalse);
    // 兑现即「家长认可已实现」——不写这一列，卡片上的「已逾期 N 天」永远消不掉
    expect(wish.parentConfirmed, isTrue);
    final stored = (await DatabaseService.instance.queryWishes('student'))
        .firstWhere((w) => w.id == 'w_ok');
    expect(stored.parentConfirmed, isTrue, reason: '确认要落库，不能只改内存');

    final ledger = await DatabaseService.instance.queryPointLedger('stu_001');
    final redeem = ledger.firstWhere(
      (e) => e.action == PointAction.wishRedeem.code,
    );
    expect(redeem.points, -30);
    expect(redeem.refId, 'w_ok');
    expect(redeem.reason, contains('去游乐园'));
  });

  test('同一个心愿不会扣两次', () async {
    await seedWish(id: 'w_twice', pointCost: 30);
    await givePoints('stu_001', 60);

    loginAs('par_001', 'parent');
    final parent = ParentController();
    await parent.loadData();
    parent.selectedStudentId.value = 'stu_001';

    await parent.approveWishRedeem('w_twice');
    final second = await parent.approveWishRedeem('w_twice');

    // 第二次应被「已兑现」挡住，而不是再扣 30
    expect(second.ok, isFalse);
    expect(await balanceOf('stu_001'), 30);
  });

  test('家长拒绝：一分不动，孩子可以再申请', () async {
    await seedWish(id: 'w_reject', pointCost: 30);
    await givePoints('stu_001', 50);

    loginAs('stu_001', 'student');
    final student = StudentController(
      aiCheckDelay: Duration.zero,
      imageStorage: LocalImageStorageService(useMemory: true),
    );
    await student.loadData();
    await student.requestWishRedeem('w_reject');

    loginAs('par_001', 'parent');
    final parent = ParentController();
    await parent.loadData();
    parent.selectedStudentId.value = 'stu_001';
    await parent.rejectWishRedeem('w_reject', reason: '这个月去过了');

    expect(await balanceOf('stu_001'), 50, reason: '拒绝不该动积分');

    final rejected = parent.wishes.firstWhere((w) => w.id == 'w_reject');
    expect(rejected.redeemRejectedAt, isNotNull);
    expect(rejected.isRedeemPending, isFalse);
    expect(rejected.isRedeemRejected, isTrue);
    expect(rejected.redeemedAt, isNull);

    // 孩子再申请一次：拒绝只是把决定权还回去，不是封禁
    loginAs('stu_001', 'student');
    final again = StudentController(
      aiCheckDelay: Duration.zero,
      imageStorage: LocalImageStorageService(useMemory: true),
    );
    await again.loadData();
    await again.requestWishRedeem('w_reject');

    final retried = again.wishes.firstWhere((w) => w.id == 'w_reject');
    expect(retried.isRedeemPending, isTrue);
    // 再申请之后「被拒绝」的痕迹要清掉，否则孩子会一直看到那句提示
    expect(retried.isRedeemRejected, isFalse);
    expect(await balanceOf('stu_001'), 50);
  });

  test('孩子撤回申请：状态回退，积分没有任何变化', () async {
    await seedWish(id: 'w_cancel', pointCost: 30);
    await givePoints('stu_001', 50);

    loginAs('stu_001', 'student');
    final student = StudentController(
      aiCheckDelay: Duration.zero,
      imageStorage: LocalImageStorageService(useMemory: true),
    );
    await student.loadData();
    await student.requestWishRedeem('w_cancel');
    await student.cancelWishRedeem('w_cancel');

    final wish = student.wishes.firstWhere((w) => w.id == 'w_cancel');
    expect(wish.redeemRequestedAt, isNull);
    expect(wish.isRedeemPending, isFalse);
    expect(await balanceOf('stu_001'), 50);
  });

  test('积分不够时家长兑现会被挡下，且不产生半截状态', () async {
    await seedWish(id: 'w_poor', pointCost: 80);
    await givePoints('stu_001', 50);

    loginAs('par_001', 'parent');
    final parent = ParentController();
    await parent.loadData();
    parent.selectedStudentId.value = 'stu_001';

    final result = await parent.approveWishRedeem('w_poor');

    expect(result.ok, isFalse);
    expect(result.message, contains('积分不足'));
    expect(await balanceOf('stu_001'), 50);
    final wish = parent.wishes.firstWhere((w) => w.id == 'w_poor');
    expect(wish.isRedeemed, isFalse, reason: '没扣成分就不该标记兑现');
  });

  test('定价为 0 的心愿兑现时不扣分', () async {
    await seedWish(id: 'w_free', pointCost: 0);

    loginAs('par_001', 'parent');
    final parent = ParentController();
    await parent.loadData();
    parent.selectedStudentId.value = 'stu_001';

    final result = await parent.approveWishRedeem('w_free');

    expect(result.ok, isTrue);
    expect(await balanceOf('stu_001'), 0);
    expect(
      parent.wishes.firstWhere((w) => w.id == 'w_free').isRedeemed,
      isTrue,
    );
  });

  test('家长额外奖励直接进账，并留下理由', () async {
    loginAs('par_001', 'parent', name: '王老师');
    final parent = ParentController();
    await parent.loadData();
    parent.selectedStudentId.value = 'stu_001';

    final result = await parent.grantPoints(points: 15, reason: '主动练琴');

    expect(result.ok, isTrue, reason: result.message);
    expect(await balanceOf('stu_001'), 15);
    final ledger = await DatabaseService.instance.queryPointLedger('stu_001');
    expect(ledger.single.reason, '主动练琴');
    expect(ledger.single.action, PointAction.parentReward.code);
  });

  test('奖励 0 分或负数会被拒', () async {
    loginAs('par_001', 'parent');
    final parent = ParentController();
    await parent.loadData();
    parent.selectedStudentId.value = 'stu_001';

    expect((await parent.grantPoints(points: 0, reason: 'x')).ok, isFalse);
    expect((await parent.grantPoints(points: -5, reason: 'x')).ok, isFalse);
    expect(await balanceOf('stu_001'), 0);
  });

  test('家长端一进来就把孩子账本拉好', () async {
    // 家长可能直接停在**心愿页**：那张卡要在定价旁边显示孩子余额，
    // 「够不够扣」的判断也依赖它。如果账本要等点进「积分」tab 才加载，
    // 心愿页上的余额会是 0 —— 而数字出错时，家长只会以为孩子把分花了。
    await givePoints('stu_001', 25);

    loginAs('par_001', 'parent');
    final parent = ParentController();
    await parent.loadData();
    parent.selectedStudentId.value = 'stu_001';
    // 切孩子是异步触发账本加载的，让微任务先跑完
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(PointController.to.account.value.balance, 25);
  });
}
