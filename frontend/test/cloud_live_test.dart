import 'dart:io';

import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/repositories/homework_repository.dart';
import 'package:easy_learn_app/services/cloud_runtime.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// **真·联调**：客户端的 HTTP 数据层，打一个真的在跑的数据服务。
///
/// ## 它和别的测试有什么不同
///
/// `flutter test` 里其余每一条用例都在**本机内存/SQLite** 上跑，
/// 它们证明的是「本地实现没坏」。这一条不同：它起一次真的 HTTP、
/// 打一个真的 PostgreSQL，用的是 `npm run dev:stack` 灌出来的那份演示数据。
///
/// 它验的是三件**只有真连起来才知道**的事：
///
/// 1. **信封与字段名对得上**。客户端的 `_fromRow` 是按服务端的 camelCase 写的，
///    而对不上的症状是「作业列表能拉到、但分数全是空」这种静默错误 ——
///    只有真数据能暴露。
/// 2. **第二条链路（另一台设备）看得到第一条写的东西**。这正是上云的全部意义：
///    家长用**另一个 client、另一个 token** 读到了孩子刚写的作业。
///    单机时代的「家长看得到」是因为两个角色共用同一个库，那不是这件事。
/// 3. **越权在服务端被拦**。另一个学生的 token 读不到别人家的孩子 ——
///    客户端这边没有一行权限代码，所以它必须由服务端回答。
///
/// ## 怎么跑
///
/// 它是**可跳过的**：没设 `CLOUD_LIVE_BASE` 就整组跳过（与 `reconcile_dump_test`
/// 同一个套路）。因为默认的 `flutter test` 不该依赖「外面有个服务在跑」——
/// 那会让一条本地用例的失败看起来像代码坏了。
///
/// ```bash
/// cd serverless/data-service && npm run dev:stack     # 另一个终端
/// CLOUD_LIVE_BASE=http://127.0.0.1:8788 flutter test test/cloud_live_test.dart
/// ```
///
/// ⚠️ 它会**往演示库里写数据**（新建一份作业并批改）。这是刻意的：
/// 只读的联调证明不了「写路径的字段名也对」。标题带固定前缀，第二次跑会跳过，
/// 所以它可以反复执行而不会越堆越多。
void main() {
  final base = Platform.environment['CLOUD_LIVE_BASE'] ?? '';
  if (base.isEmpty) {
    test('联调（未设置 CLOUD_LIVE_BASE，跳过）', () {}, skip: '需要先起本机数据服务');
    return;
  }

  late CloudRuntime student;
  late CloudRuntime parent;
  late CloudRuntime other;

  setUp(() async {
    student = _runtimeFor(base);
    parent = _runtimeFor(base);
    other = _runtimeFor(base);
  });

  tearDown(() {
    student.dispose();
    parent.dispose();
    other.dispose();
  });

  test('学生登录 → 读到演示数据（真实服务端）', () async {
    final account = await student.auth.login(
      phone: '13800000001',
      password: 'abc123',
      role: 'student',
    );
    expect(account.token, isNotEmpty);
    expect(account.user['name'], '林小宇');
    // id 是服务端生成的 uuid —— 不再是本地那套 `user_1712…`。
    expect(account.user['id'], isNot(startsWith('user_')));

    final homework = await student.homework.queryHomework('student');
    expect(homework, isNotEmpty, reason: '演示数据里应当有作业');

    final graded = homework.firstWhere((h) => h.score != null);
    expect(graded.score, 86);
    // 这两条最容易静默错：服务端给的是真布尔，本地那套 `as num? == 1` 会读成 false；
    // 时间是带 Z 的 UTC，不转本地就整体差 8 小时。
    expect(graded.needsGrading, isFalse, reason: '批改完成之后不再需要批改');
    expect(graded.dueAt.isUtc, isFalse, reason: '下行时间必须已转成本地时间');
    expect(graded.checkedAt, isNotNull);
    expect(graded.status, HomeworkStatus.finished);
  });

  test('错题 / 计划 / 积分 / 心愿 / 通知都读得到', () async {
    await student.auth.login(phone: '13800000001', password: 'abc123', role: 'student');

    final mistakes = await student.review.queryReviewMistakes();
    expect(mistakes.length, greaterThanOrEqualTo(2));
    expect(mistakes.first.subject, isNotEmpty);

    final plans = await student.studyPlans.queryStudyPlans('student');
    expect(plans, isNotEmpty);

    final checkins = await student.studyPlans.queryStudyPlanCheckins();
    expect(checkins, isNotEmpty, reason: '种子里打过卡');

    final ledger = await student.points.queryPointLedger(
      student.api.session.userId!,
    );
    expect(ledger, isNotEmpty);

    final wishes = await student.wishes.queryWishes('student');
    expect(wishes, isNotEmpty);
  });

  test('写路径：建作业 → 提交 → 批改（掩码在网络边界上保得住）', () async {
    await student.auth.login(phone: '13800000001', password: 'abc123', role: 'student');
    final studentId = student.api.session.userId!;
    const title = '【联调】掩码语义自检';

    // 幂等：第二次跑时它已经在了，就跳过插入（作业没有删除端点）。
    var existing = (await student.homework.queryHomework('student'))
        .where((h) => h.title == title)
        .toList();

    if (existing.isEmpty) {
      final now = DateTime.now();
      await student.homework.insertHomework(
        HomeworkItem(
          id: 'client-generated-ignored',
          title: title,
          subject: '数学',
          imageUrl: '',
          dueAt: now.add(const Duration(hours: 2)),
          estimatedMinutes: 20,
          status: HomeworkStatus.pending,
          wrongCount: 0,
          aiEnabled: true,
          needsGrading: true,
          userRole: 'student',
          studentId: studentId,
          summary: '',
          imageCount: 0,
          submitBatchId: '',
          gradingSource: GradingSource.none,
        ),
        'student',
      );
      existing = (await student.homework.queryHomework('student'))
          .where((h) => h.title == title)
          .toList();
    }
    expect(existing, hasLength(1), reason: '服务端生成 id，客户端要重新查一次才拿得到');
    final hw = existing.first;

    // 先写一次「提交」，再写一次「批改」—— 与 `StudentController` 逐字段一致。
    await student.homework.updateHomework(
      HomeworkPatch(id: hw.id)
        ..status = HomeworkStatus.checking
        ..submittedAt = DateTime.now()
        ..needsGrading = true
        ..imageCount = 1
        ..submitBatchId = 'live-test-batch',
    );
    await student.homework.updateHomework(
      HomeworkPatch(id: hw.id)
        ..status = HomeworkStatus.finished
        ..checkedAt = DateTime.now()
        ..score = 95
        ..summary = '联调用例写入的批改结果'
        ..wrongCount = 0
        ..gradingSource = GradingSource.cloud
        ..needsGrading = false,
    );

    final after = (await student.homework.queryHomework('student'))
        .firstWhere((h) => h.id == hw.id);
    expect(after.score, 95);
    expect(after.summary, '联调用例写入的批改结果');
    expect(after.status, HomeworkStatus.finished);
    expect(after.submitBatchId, 'live-test-batch');

    // 掩码的**反向**：清空批改结果。`clearResult()` 产出的是「显式空值」，
    // 而它在 JSON 上必须活着到达 —— 到不了的话症状是「重新提交后家长仍看到旧分数」。
    await student.homework.updateHomework(HomeworkPatch(id: hw.id)..clearResult());
    final cleared = (await student.homework.queryHomework('student'))
        .firstWhere((h) => h.id == hw.id);
    expect(cleared.score, isNull, reason: '清空必须真的清空');
    expect(cleared.summary, isEmpty);
    expect(cleared.checkedAt, isNull);

    // 收尾：把它标回「待完成」，免得演示时看到一份被清空的怪作业。
    await student.homework.updateHomework(
      HomeworkPatch(id: hw.id)
        ..status = HomeworkStatus.finished
        ..checkedAt = DateTime.now()
        ..score = 95
        ..summary = '联调用例写入的批改结果'
        ..needsGrading = false
        ..gradingSource = GradingSource.cloud,
    );
  });

  test('第二条链路：家长用另一个 token 看得到孩子刚写的作业', () async {
    await student.auth.login(phone: '13800000001', password: 'abc123', role: 'student');
    await parent.auth.login(phone: '13800000002', password: 'abc123', role: 'parent');

    final childId = student.api.session.userId!;
    final asStudent = await student.homework.queryHomework('student');
    final asParent = await parent.homework.queryHomeworkByStudentIds([childId]);

    expect(asParent.map((h) => h.id).toSet(), asStudent.map((h) => h.id).toSet(),
        reason: '同一份数据，两个 token、两个 client 都应当看到');

    // 家长还能读到孩子的档案（用于把 id 显示成姓名）—— 走的是另一张表的 RLS。
    final users = await parent.users.queryUsersByIds([childId]);
    expect(users, hasLength(1));
    expect(users.first['name'], '林小宇');
  });

  test('越权：另一个学生读不到别人家孩子的作业（服务端 403）', () async {
    await student.auth.login(phone: '13800000001', password: 'abc123', role: 'student');
    await other.auth.login(phone: '13800000003', password: 'abc123', role: 'student');

    final childId = student.api.session.userId!;
    await expectLater(
      other.homework.queryHomeworkByStudentIds([childId]),
      throwsA(isA<DataApiException>().having((e) => e.code, 'code', 'forbidden')),
    );
  });

  test('登出之后同一个 token 立刻失效', () async {
    final account = await student.auth.login(
      phone: '13800000001',
      password: 'abc123',
      role: 'student',
    );
    final token = account.token;
    await student.auth.logout();

    // 直接拿旧 token 再发一次：服务端会话已吊销，必须被拒。
    final replay = DataApiClient(
      config: DataConfig(baseUrl: base),
      session: _FixedSession(token: token, user: account.user),
    );
    await expectLater(
      replay.getJson('/auth/me'),
      throwsA(isA<DataApiException>().having((e) => e.code, 'code', 'token_invalid')),
    );
    replay.close();
  });

  test('错密码被拒，且文案来自服务端', () async {
    await expectLater(
      student.auth.login(phone: '13800000001', password: 'wrong-password', role: 'student'),
      throwsA(isA<DataApiException>()),
    );
  });

  test('作业照片 / 计数端点形状对得上', () async {
    await student.auth.login(phone: '13800000001', password: 'abc123', role: 'student');
    final homework = await student.homework.queryHomework('student');
    final target = homework.firstWhere((h) => h.score != null);

    final count = await student.homework.countHomeworkImages(target.id);
    expect(count, greaterThanOrEqualTo(0));
    final images = await student.homework.queryHomeworkImagesByHomeworkId(target.id);
    expect(images, isA<List>());
  });
}

/// 内存版会话：测试里不该落到磁盘（`path_provider` 在 VM 测试环境没有平台通道）。
///
/// `extends` 不是 `implements`：`SessionStore` 的 `isAuthenticated` / `userId` /
/// `role` 是**带实现的具体成员**，`implements` 要求把它们全部重写一遍 ——
/// 而重写出来的那三个 getter 与基类一字不差，纯属噪音。
class _MemorySession extends SessionStore {
  String? _token;
  Map<String, dynamic>? _user;

  @override
  Future<void> initialize() async {}

  @override
  String? get token => _token;

  @override
  Map<String, dynamic>? get user => _user;

  @override
  Future<void> save({required String token, required Map<String, dynamic> user}) async {
    _token = token;
    _user = user;
  }

  @override
  Future<void> clear() async {
    _token = null;
    _user = null;
  }
}

/// 预置一份 token 的会话 —— 用来验「登出之后旧 token 还能不能用」。
///
/// 这里**不转发、不落盘**：`save`/`clear` 是空操作，因为要测的正是
/// 「一个已经握在手里的 token，在服务端被吊销之后还能不能再用」——
/// 如果 `clear()` 真的能改掉它，那这个用例就自己把自己验完了。
/// 字段直接覆写基类的 getter（`String` 比 `String?` 窄，是合法的协变收窄）。
class _FixedSession extends SessionStore {
  _FixedSession({required this.token, required this.user});

  @override
  final String token;

  @override
  final Map<String, dynamic> user;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> save({required String token, required Map<String, dynamic> user}) async {}

  @override
  Future<void> clear() async {}
}

CloudRuntime _runtimeFor(String base) {
  final api = DataApiClient(
    config: DataConfig(baseUrl: base, requestTimeout: const Duration(seconds: 15)),
    session: _MemorySession(),
  );
  return CloudRuntime(
    config: DataConfig(baseUrl: base),
    api: api,
  );
}
