import 'dart:convert';
import 'dart:typed_data';

import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/homework_image_model.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/repositories/homework_repository.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/http_homework_repository.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 「事后修改作业（科目 / 内容 / 要不要批改）」这条路上，**失败形态全是静默的**，
/// 所以每条断言都指向一种具体的错法，而不是「调用没报错」：
///
/// - **该发的没发** ⇒ 界面上字改了、库里没改，刷新之后打回原样；
/// - **不该发的发了** ⇒ 服务端 400「这些字段不能通过本端点写」，
///   而这句读起来像客户端 bug，实际是「服务端还没部署放行它的那一版」；
/// - **把整份表单发上去**（不是掩码）⇒ 抹掉家长端 / 另一台设备改过的那些字段，
///   而服务端回 200，**看起来完全成功**；
/// - **落库失败却先改了内存** ⇒ 界面显示新值，刷新之后又变回去。
///
/// ⚠️ 每个用例都留一份 **`hw_2` 对照组**：没有它的话，「整个列表都被改了」
/// 也能让 `hw_1` 的断言通过 —— 那就是一条**测不出东西的绿**。
///
/// ⚠️ **这份文件目前还没被执行过**（2026-09-29：本窗口 `flutter test` 被
/// Windows 命名管道枯竭拦死，见 `doc/open-items.md` B15）。它写在这里是为了
/// 环境一恢复就能一次跑通，**不构成「验证通过」**。
void main() {
  group('协议：HttpHomeworkRepository', () {
    test('打到 /update，body 是「id + 只改过的那些键」', () async {
      final calls = <String>[];
      Map<String, dynamic>? sent;
      final repo = HttpHomeworkRepository(
        _api((request) {
          calls.add('${request.method} ${request.url.path}');
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return {
            'updated': true,
            'touched': ['subject'],
            'item': <String, dynamic>{},
          };
        }),
      );

      await repo.updateHomework(HomeworkPatch(id: 'hw_1')..subject = '英语');

      expect(calls, ['POST /data/homework/update']);
      expect(
        sent,
        {'id': 'hw_1', 'subject': '英语'},
        reason:
            'body 必须是「id + 这次要写的那些键」。多带一个键就是多写一列 —— '
            '`title` / `subject` 现在**已经在服务端放行了**（`PATCH_SPEC`），'
            '所以这里多带什么，那边就真的会写进去。',
      );
    });
  });

  group('掩码：只写真正改过的字段', () {
    test('只改科目 —— 上行只有 subject', () async {
      final repo = _FakeHomework();
      final controller = _controller(repo);
      _seed(controller);

      final result = await controller.updateHomeworkFields(
        homeworkId: 'hw_1',
        title: '练字一张',
        subject: '语文',
        needsGrading: true,
      );

      expect(result.ok, isTrue, reason: result.message);
      expect(repo.patches, hasLength(1));
      expect(
        repo.patches.single,
        {'subject': '语文'},
        reason:
            '一个字都没改的 `title` 不该出现 —— 它不是「顺便保持一致」，'
            '而是「这次要写它」。界面手上这份值来自更早的一次读取，'
            '中途家长端改过它的话，这次上行会把那个改动抹掉，而且不报错。',
      );
    });

    test('只改内容 —— 上行只有 title（正是「练字→练习」那个错法）', () async {
      final repo = _FakeHomework();
      final controller = _controller(repo);
      _seed(controller);

      final result = await controller.updateHomeworkFields(
        homeworkId: 'hw_1',
        title: '练习一张',
        subject: '英语',
        needsGrading: true,
      );

      expect(result.ok, isTrue, reason: result.message);
      expect(repo.patches.single, {'title': '练习一张'});
    });

    test('改「要不要批改」—— 上行带真布尔，不是 1/0', () async {
      final repo = _FakeHomework();
      final controller = _controller(repo);
      _seed(controller);

      final result = await controller.updateHomeworkFields(
        homeworkId: 'hw_1',
        title: '练字一张',
        subject: '英语',
        needsGrading: false,
      );

      expect(result.ok, isTrue, reason: result.message);
      expect(
        repo.patches.single,
        {'needsGrading': false},
        reason:
            '本地库把布尔存成 1/0（SQLite 没有布尔列），上行必须发 true/false —— '
            '`HomeworkPatch.toWireMap()` 存在的唯一理由就是这个差别。'
            '发错编码时服务端要么 400、要么把它解释成别的值。',
      );
    });

    test('三条都改 —— 恰好这三个键，不多不少', () async {
      final repo = _FakeHomework();
      final controller = _controller(repo);
      _seed(controller);

      final result = await controller.updateHomeworkFields(
        homeworkId: 'hw_1',
        title: '练习一张',
        subject: '语文',
        needsGrading: false,
      );

      expect(result.ok, isTrue, reason: result.message);
      expect(repo.patches.single.keys.toSet(), {
        'title',
        'subject',
        'needsGrading',
      });
    });

    test('改标题不会顺手把 estimatedMinutes 带上行', () async {
      final repo = _FakeHomework();
      final controller = _controller(repo);
      _seed(controller);

      final result = await controller.updateHomeworkFields(
        homeworkId: 'hw_1',
        title: '练习一张',
        subject: '英语',
        needsGrading: true,
      );

      expect(result.ok, isTrue, reason: result.message);
      // ⚠️ 这条不是凑数：表单里**改标题就会重推预计耗时**
      // （`_HomeworkDraft.onTitleChanged`），所以「只改个错字」之后
      // 那个数很可能已经和库里不一样了。而服务端的可更新字段表
      // （`PATCH_SPEC`）里**没有** `estimatedMinutes` ⇒ 带上就是一次 400，
      // 表现成「改了字却保存不了」。
      expect(
        repo.patches.single.containsKey('estimatedMinutes'),
        isFalse,
        reason: '服务端没放行这个字段，发了必被拒。',
      );
      expect(repo.patches.single.keys, ['title']);
    });

    test('一个字都没改 —— 一次都不打扰仓库', () async {
      final repo = _FakeHomework();
      final controller = _controller(repo);
      _seed(controller);

      final result = await controller.updateHomeworkFields(
        homeworkId: 'hw_1',
        title: '练字一张',
        subject: '英语',
        needsGrading: true,
      );

      expect(result.ok, isTrue);
      expect(
        repo.patches,
        isEmpty,
        reason:
            '没改动却发一次空掩码：服务端容忍它（返回空结果），'
            '但仓库契约要求调用方跳过。更实际的问题是它会白占一次往返，'
            '而「保存成功」的提示会让人以为自己改了什么。',
      );
    });
  });

  group('落库与内存的顺序', () {
    test('成功：落库之后内存才更新，对照组 hw_2 不动', () async {
      final repo = _FakeHomework();
      final controller = _controller(repo);
      _seed(controller);

      final result = await controller.updateHomeworkFields(
        homeworkId: 'hw_1',
        title: '练习一张',
        subject: '语文',
        needsGrading: false,
      );

      expect(result.ok, isTrue, reason: result.message);

      final hw1 = controller.homeworkList.firstWhere((e) => e.id == 'hw_1');
      expect(hw1.title, '练习一张');
      expect(hw1.subject, '语文');
      expect(hw1.needsGrading, isFalse);

      final hw2 = controller.homeworkList.firstWhere((e) => e.id == 'hw_2');
      expect(hw2.title, '学法P28');
      expect(hw2.subject, '数学');
      expect(hw2.needsGrading, isTrue, reason: '对照组：改 hw_1 不该碰到 hw_2。');
    });

    test('服务端拒绝：内存一个字都不动，且把服务端那句中文原样透出来', () async {
      final repo = _FakeHomework()
        ..error = const DataApiException(
          code: 'badRequest',
          message: '这些字段不能通过本端点写：title。',
          status: 400,
        );
      final controller = _controller(repo);
      _seed(controller);

      final result = await controller.updateHomeworkFields(
        homeworkId: 'hw_1',
        title: '练习一张',
        subject: '英语',
        needsGrading: true,
      );

      expect(result.ok, isFalse);
      expect(
        result.message,
        '这些字段不能通过本端点写：title。',
        reason:
            '这句就是「服务端还没部署放行 title 的那一版」时的原话 —— '
            '透出来人才能一眼认出病因（客户端新、服务端旧）；'
            '换成通用的「保存失败，请稍后重试」，只会让人反复点。',
      );
      expect(
        controller.homeworkList.firstWhere((e) => e.id == 'hw_1').title,
        '练字一张',
        reason:
            '落库失败却已经改了内存 ⇒ 界面显示新值、刷新之后变回去。'
            '而用户在那之前刚看到过「正在保存」，会以为是自己看错了 —— '
            '与「刚提交的看不到、重登就好」是同一族的观感。',
      );
    });

    test('id 不在当前列表里：直接失败，也不去打扰仓库', () async {
      final repo = _FakeHomework();
      final controller = _controller(repo);
      _seed(controller);

      final result = await controller.updateHomeworkFields(
        homeworkId: 'hw_不存在',
        title: 'x',
        subject: '语文',
        needsGrading: true,
      );

      expect(result.ok, isFalse);
      expect(repo.patches, isEmpty);
      expect(controller.homeworkList.map((e) => e.id).toList(), [
        'hw_1',
        'hw_2',
      ]);
    });
  });
}

// ===== 装置 =====

StudentController _controller(HomeworkRepository repo) => StudentController(
  // 本文件不跑批改流程；写出来是为了将来有人在这个文件里加一条提交用例时
  // 不会莫名其妙慢 700ms。
  aiCheckDelay: Duration.zero,
  homework: repo,
  imageStorage: _MemoryStorage(),
);

/// 造 `hw_1`（要被改的那份）与 `hw_2`（**对照组**）。
///
/// `hw_1` 的初值刻意取成线上真实识别出来的那条：`练字一张` 被读成
/// `练习一张`，是同一张图上 25 次错 19 次的那一处（`doc/open-items.md` B27）。
void _seed(StudentController controller) {
  controller.homeworkList.add(
    HomeworkItem(
      id: 'hw_1',
      title: '练字一张',
      subject: '英语',
      imageUrl: '',
      dueAt: DateTime(2026, 9, 29),
      estimatedMinutes: 30,
      status: HomeworkStatus.pending,
      wrongCount: 0,
      aiEnabled: true,
      needsGrading: true,
      userRole: 'student',
      studentId: 'stu_1',
    ),
  );
  controller.homeworkList.add(
    HomeworkItem(
      id: 'hw_2',
      title: '学法P28',
      subject: '数学',
      imageUrl: '',
      dueAt: DateTime(2026, 9, 29),
      estimatedMinutes: 30,
      status: HomeworkStatus.pending,
      wrongCount: 0,
      aiEnabled: true,
      needsGrading: true,
      userRole: 'student',
      studentId: 'stu_1',
    ),
  );
}

/// 只实现 `updateHomework`。
///
/// 其余方法一律抛 —— 刻意不写成一堆 `async => const []`：空实现会让
/// 「控制器不小心多发了一次查询」这类事情**静默通过**，而这个文件想抓的
/// 正是那种「看起来正常」的错。（`implements` 要求实现全部成员，所以接口
/// 将来加了方法这里会编译不过 —— 那是提醒，不是麻烦。）
class _FakeHomework implements HomeworkRepository {
  /// 收到的每一次更新，按**上行编码**记（`toWireMap`）。
  ///
  /// ⚠️ 记上行而不是本地编码：掩码最终要以这个形状到服务端，而两者的差别
  /// 恰好落在一处 —— 布尔是 `true/false` 还是 `1/0`。
  final List<Map<String, Object?>> patches = <Map<String, Object?>>[];

  /// 非空 → `updateHomework` 抛它（模拟服务端 400 / 403）。
  Object? error;

  @override
  Future<void> updateHomework(HomeworkPatch patch) async {
    final e = error;
    if (e != null) throw e;
    patches.add(Map<String, Object?>.from(patch.toWireMap()));
  }

  @override
  Future<List<HomeworkItem>> queryHomework(String userRole) => _unused();

  @override
  Future<List<HomeworkItem>> queryHomeworkByStudentIds(
    List<String> studentIds,
  ) => _unused();

  @override
  Future<HomeworkItem> insertHomework(HomeworkItem item, String userRole) =>
      _unused();

  @override
  Future<void> deleteHomework(String id) => _unused();

  @override
  Future<List<HomeworkImageModel>> saveHomeworkImage(HomeworkImageModel image) =>
      _unused();

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
  Future<void> deleteHomeworkImagesByHomeworkId(String homeworkId) => _unused();

  @override
  Future<int> countHomeworkImages(String homeworkId) => _unused();
}

Never _unused() =>
    throw UnimplementedError('本替身只实现了 updateHomework —— 走到了这里说明调用方多做了什么');

/// 内存版照片存储。本文件不碰照片，只需要能满足构造。
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

final _config = DataConfig(
  baseUrl: 'http://127.0.0.1:8788',
  requestTimeout: const Duration(seconds: 5),
);

/// 一个能捕获请求的假服务端。`postJson` 期望 `{ok:true, data:{...}}` 信封。
DataApiClient _api(Map<String, dynamic> Function(http.Request) onPost) =>
    DataApiClient(
      config: _config,
      session: _MemorySession(),
      httpClient: MockClient((request) async {
        final data = onPost(request);
        return http.Response.bytes(
          utf8.encode(jsonEncode({'ok': true, 'data': data})),
          200,
        );
      }),
    );

/// 只为了让 `DataApiClient` 拿得到一个 token。
///
/// 协议用例**不依赖角色**：`HttpHomeworkRepository` 把归属整个交给服务端，
/// 客户端这一层不读 role（所以「客户端自报身份」这条路根本不存在）。
class _MemorySession extends SessionStore {
  @override
  Future<void> initialize() async {}

  @override
  String? get token => 't';

  @override
  Map<String, dynamic>? get user => {'id': 'stu_1', 'role': 'student'};

  @override
  Future<void> save({
    required String token,
    required Map<String, dynamic> user,
  }) async {}

  @override
  Future<void> clear() async {}
}
