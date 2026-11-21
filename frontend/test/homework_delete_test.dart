import 'dart:convert';
import 'dart:typed_data';

import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/homework_image_model.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/models/review_model.dart';
import 'package:easy_learn_app/repositories/homework_repository.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/http_homework_repository.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 「删除整份作业」这条路上，**失败形态全是静默的**，所以每条断言都指向
/// 一种具体的错法，而不是「调用没报错」：
///
/// - 只删了作业行 → 照片与错题的孤儿行留着（配额照算、错题本里那些题
///   指着一份不存在的作业），而每一段单独看都「成功」；
/// - 删不到却当成功 → 界面显示「已删除」，刷新之后那条又回来 ——
///   用户会以为自己看错了，这是最难被当成 bug 报上来的形态；
/// - 反过来（服务端报错但内存已经清了）→ 同一种现象的另一种成因。
///
/// ⚠️ 每个用例都留了一份 **`hw_2` 对照组**：不放它的话，「把整个列表清空」
/// 也能让 `isNot(contains('hw_1'))` 通过 —— 那就是一条测不出东西的绿。
void main() {
  group('协议：HttpHomeworkRepository', () {
    test('打到 /delete，body 只有 id', () async {
      final calls = <String>[];
      Map<String, dynamic>? sent;
      final repo = HttpHomeworkRepository(
        _api((request) {
          calls.add('${request.method} ${request.url.path}');
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return {'deleted': true, 'id': 'hw_1'};
        }),
      );

      await repo.deleteHomework('hw_1');

      expect(
        calls,
        ['POST /data/homework/delete'],
        reason: '删除只有一个请求，且必须打在 /delete 上。'
            '同族里最像的是 /update —— 它是掩码更新，打过去会回 200、'
            '把一个不存在的 id 默默「更新」掉，界面表现成「点了一下没反应」，'
            '而学生以为自己删掉了（与 B21「点了没反应」同一种观感，成因不同）。',
      );
      expect(
        sent,
        {'id': 'hw_1'},
        reason: 'body 只该有 id —— 归属由服务端从 token 解出来。'
            '客户端能自报 studentId 的地方就是越权面，'
            '服务端那边两道闸（角色 / 可见集合）只信 token。',
      );
    });
  });

  test('删除成功：先落库，之后才清内存里的作业、照片与错题', () async {
    final repo = _FakeHomework();
    final storage = _MemoryStorage();
    final controller = _controller(repo, storage);
    _seed(controller);

    final result = await controller.deleteHomework('hw_1');

    expect(result.ok, isTrue, reason: result.message);

    // ① 仓库真的收到了这次删除。少了这一条，「内存清空了」说明不了任何事 ——
    //    内存清空也可能是「仓库没被调用、代码直接把本地那条抹了」。
    expect(repo.deletedIds, ['hw_1']);

    // ② 三处内存都只剩对照组：作业、它的照片、它带出来的错题。
    expect(controller.homeworkList.map((e) => e.id).toList(), ['hw_2']);
    expect(
      controller.homeworkImages.map((e) => e.homeworkId).toList(),
      ['hw_2'],
    );
    expect(controller.mistakes.map((e) => e.homeworkId).toList(), ['hw_2']);

    // ③ 本机那份照片字节也清了。云端构建下这个调用是空实现
    //    （桶里的字节按服务端的口径不删），本地构建下它是真的删文件。
    expect(storage.deletedKeys, ['k/hw_1_a.png']);

    // ④ 提示里要带上「连带删掉了什么」：学生在错题本里认识的是那些题，
    //    不点明他会以为它们还在。
    expect(result.message, contains('错题'));
  });

  test('删除失败：如实返回失败，且**内存一个字都不动**', () async {
    final repo = _FakeHomework()
      ..error = StateError('找不到这份作业（或无权删除）');
    final controller = _controller(repo, _MemoryStorage());
    _seed(controller);

    final result = await controller.deleteHomework('hw_1');

    expect(result.ok, isFalse);

    // 服务端那句原因要透出来，不能变成一句通用的「删除失败」——
    // 它说的是「你手上这份已经不存在了（或不属于你）」，指了下一步。
    expect(result.message, contains('找不到这份作业'));

    // ⚠️ 这一段是重点。静默把内存清掉的话，界面显示删掉了、刷新之后又回来，
    //    而用户会以为自己看错了 —— 与「B19 作答照片从不落库」同一类：
    //    每一段都「正常」，合起来是错的。
    expect(controller.homeworkList.map((e) => e.id).toList(), ['hw_1', 'hw_2']);
    expect(
      controller.homeworkImages.map((e) => e.homeworkId).toList(),
      ['hw_1', 'hw_2'],
    );
    expect(
      controller.mistakes.map((e) => e.homeworkId).toList(),
      ['hw_1', 'hw_2'],
    );
  });

  test('服务端拒绝时，把服务端那句中文原样透出来（不是通用文案）', () async {
    final repo = _FakeHomework()
      ..error = const DataApiException(
        code: 'forbidden',
        message: '只有学生可以删除自己的作业',
        status: 403,
      );
    final controller = _controller(repo, _MemoryStorage());
    _seed(controller);

    final result = await controller.deleteHomework('hw_1');

    expect(result.ok, isFalse);
    // 与上一条同源（原因不能被吞），但走的是**云端**那支：
    // `DataApiException.message` 本来就是中文、直接可展示（见 data_api_client.dart），
    // 而且它顺带指了下一步 ——「只有学生可以删」意思是「你拿错身份了」。
    // 换成一句通用的「删除失败，请稍后重试」，人就只会反复点。
    expect(result.message, '只有学生可以删除自己的作业');
    expect(controller.homeworkList.map((e) => e.id).toList(), ['hw_1', 'hw_2']);
  });

  test('id 不在当前列表里：直接失败，也不去打扰仓库', () async {
    final repo = _FakeHomework();
    final controller = _controller(repo, _MemoryStorage());
    _seed(controller);

    final result = await controller.deleteHomework('hw_不存在');

    expect(result.ok, isFalse);
    // 本地就知道不存在的 id，没必要发一次注定失败的请求 ——
    // 而它一旦真的发出去，服务端回 403 也是这个结果，只是多一次往返。
    expect(repo.deletedIds, isEmpty);
    expect(controller.homeworkList.map((e) => e.id).toList(), ['hw_1', 'hw_2']);
  });
}

// ===== 装置 =====

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
/// 这里填 `student` 贴合真实场景（删除只有学生能做），但**协议用例不依赖它** ——
/// `HttpHomeworkRepository` 把归属整个交给服务端，客户端这一层不读 role
/// （所以「客户端自报身份」这条路根本不存在，也就没得测）。
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

StudentController _controller(
  HomeworkRepository repo,
  ImageStorageService storage,
) => StudentController(
  // 这个文件不跑批改，但控制器默认会等 700ms 的模拟耗时 ——
  // 只调 deleteHomework 时它不生效，写出来是为了将来有人在这个文件里
  // 加一条提交流程的用例时不会莫名其妙慢下来。
  aiCheckDelay: Duration.zero,
  homework: repo,
  imageStorage: storage,
);

/// 造一份要被删的作业（`hw_1`）与一份**对照组**（`hw_2`）。
///
/// 对照组不是凑数：没有它的话，「删完之后 `hw_1` 不在了」与
/// 「删完之后列表整个空了」分不出来。
void _seed(StudentController controller) {
  for (final id in ['hw_1', 'hw_2']) {
    controller.homeworkList.add(
      HomeworkItem(
        id: id,
        title: '作业 $id',
        subject: '数学',
        imageUrl: '',
        dueAt: DateTime(2026, 9, 28),
        estimatedMinutes: 30,
        status: HomeworkStatus.pending,
        wrongCount: 1,
        aiEnabled: true,
        userRole: 'student',
        studentId: 'stu_1',
      ),
    );
    controller.homeworkImages.add(
      HomeworkImageModel(
        id: 'img_$id',
        studentId: 'stu_1',
        homeworkId: id,
        storageKey: id == 'hw_1' ? 'k/hw_1_a.png' : 'k/hw_2_a.png',
        fileName: '$id.png',
        fileSize: 10,
        mimeType: 'image/png',
        ocrStatus: 'done',
        ocrText: '',
        createdAt: DateTime(2026, 9, 28),
      ),
    );
    controller.mistakes.add(
      ReviewMistake(
        id: 'rm_$id',
        subject: '数学',
        title: '错题 $id',
        originalAnswer: '',
        wrongReason: '',
        createdAt: DateTime(2026, 9, 28),
        state: ReviewState.pending,
        studentId: 'stu_1',
        homeworkId: id,
      ),
    );
  }
}

/// 只实现 `deleteHomework`。
///
/// 其余方法一律抛 —— 刻意不写成一堆 `async => const []`：
/// 空实现会让「控制器不小心多调了一次 `queryHomework`」这类事情
/// **静默通过**，而这个文件想抓的正是那种「看起来正常」的错。
/// （Dart 的 `implements` 要求实现全部成员，所以接口将来加了方法，
/// 这里会编译不过 —— 那是提醒，不是麻烦。）
class _FakeHomework implements HomeworkRepository {
  final List<String> deletedIds = <String>[];

  /// 非空 → `deleteHomework` 抛它（模拟服务端 403）。
  Object? error;

  @override
  Future<void> deleteHomework(String id) async {
    final e = error;
    if (e != null) throw e;
    deletedIds.add(id);
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
  Future<void> updateHomework(HomeworkPatch patch) => _unused();

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
    throw UnimplementedError('本替身只实现了 deleteHomework —— 走到了这里说明调用方多做了什么');

/// 内存版照片存储：只需要记录「哪几个 key 被要求删掉」。
class _MemoryStorage implements ImageStorageService {
  final List<String> deletedKeys = <String>[];

  @override
  void deleteImage(String storageKey) => deletedKeys.add(storageKey);

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
