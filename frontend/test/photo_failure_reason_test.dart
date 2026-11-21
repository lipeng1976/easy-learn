import 'dart:io';
import 'dart:typed_data';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/notification_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/homework_image_model.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/models/homework_photo_draft.dart';
import 'package:easy_learn_app/models/photo_usage.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/repositories/homework_repository.dart';
import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';

/// 服务端配额满时回的那句中文。**逐字抄自**
/// `serverless/data-service/src/routes/homework.js` 的 `assertPhotoQuota`。
///
/// 抄而不是 import：这是**跨栈的契约**，两边各写一份才能发现漂移。
/// 客户端这条判据要断言的正是「服务端写的文案被原样送到学生眼前」，
/// 如果哪天服务端改了措辞而这里没改，红了才知道。
///
/// ⚠️ 句中的数字（`3000` / `3000` / `3`）只是**夹具取值**，不是配额配置的副本 ——
/// 服务端那句是模板变量（`${state.used} / ${state.quota}`），填什么都成立。
/// 所以**改配额默认值不需要动这里**；写成 3000 只是免得读的人以为默认值还是 10000。
const String _serverQuotaMessage =
    '该学生的照片数量已达上限（已用 3000 / 3000 张，本次还要再加 3 张）。'
    '删掉一些旧照片再试，或让运维调大 IMAGE_QUOTA_PER_STUDENT';

/// 上传阶段就失败（字节没上去）。用来造「配额」这一类**再试也不会好**的失败。
class _UploadFailingStorage implements ImageStorageService {
  _UploadFailingStorage(this.error);

  final Object error;
  int calls = 0;

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
  }) async {
    calls++;
    throw error;
  }

  @override
  Uint8List? readImage(String storageKey) => null;

  @override
  void deleteImage(String storageKey) {}
}

/// 假仓库：写照片**行**这一步可以按需失败。
///
/// 为什么需要单独的替身：`saveHomeworkImages` 失败与上传失败是两件事
/// （「字节上去了但行没记上」vs「字节都没上去」），而本地真仓储
/// **不会**制造前者 —— 它不查配额。差异只有在这里才造得出来。
class _RowsFailingRepo implements HomeworkRepository {
  /// 非空 → `saveHomeworkImages` 抛它。
  Object? rowsError;

  /// 写行成功时回给调用方的用量。默认 null = 服务端没给这个字段 ——
  /// 正面用例（照片全成功）不该顺带冒出一句「快满了」。
  PhotoUsage? usage;

  final List<HomeworkImageModel> savedImages = <HomeworkImageModel>[];
  final List<String> patchedIds = <String>[];
  int insertCalls = 0;
  int rowCalls = 0;

  @override
  Future<HomeworkItem> insertHomework(HomeworkItem item, String userRole) async {
    insertCalls++;
    return item.copyWith(id: 'srv-$insertCalls');
  }

  @override
  Future<void> updateHomework(HomeworkPatch patch) async {
    patchedIds.add(patch.id);
  }

  @override
  Future<List<HomeworkImageModel>> saveHomeworkImage(
    HomeworkImageModel image,
  ) async => (await saveHomeworkImages([image])).images;

  @override
  Future<SavedHomeworkImages> saveHomeworkImages(
    List<HomeworkImageModel> images,
  ) async {
    rowCalls++;
    final err = rowsError;
    if (err != null) throw err;
    final stored = images
        .map((e) => e.copyWith(id: 'simg-${++rowCalls}'))
        .toList();
    savedImages.addAll(stored);
    // 写行这一步顺带回用量；这个替身默认不给（null），
    // 要验「快满了」的用例自己填 [usage]。
    return SavedHomeworkImages(images: stored, photoUsage: usage);
  }

  /// 本文件只测「照片写行失败」的提示，不碰删除路径。
  /// 空实现让接口加了方法之后这里仍然编得过；验删除见
  /// `homework_delete_test.dart`。
  @override
  Future<void> deleteHomework(String id) async {}

  @override
  Future<void> deleteHomeworkImagesByHomeworkId(String homeworkId) async {}

  @override
  Future<int> countHomeworkImages(String homeworkId) async => 0;

  @override
  Future<List<HomeworkItem>> queryHomework(String userRole) async => const [];

  @override
  Future<List<HomeworkItem>> queryHomeworkByStudentIds(
    List<String> studentIds,
  ) async => const [];

  @override
  Future<List<HomeworkImageModel>> queryHomeworkImages(String studentId) async =>
      savedImages.where((e) => e.studentId == studentId).toList();

  @override
  Future<List<HomeworkImageModel>> queryHomeworkImagesByHomeworkId(
    String homeworkId,
  ) async => savedImages.where((e) => e.homeworkId == homeworkId).toList();
}

/// 照片失败时，**原因必须跟着提示一起给学生**。
///
/// 旧实现是 `catch (_) { photoFailures++; }` —— 原因被整段丢掉，学生只看到
/// 「（3 张照片保存失败）」。网络抖动、照片太大、**照片数量已达上限**在这里
/// 长得一模一样，而它们的处置完全不同：前两个等一下再试就好，
/// 最后一个是**再试一百次也不会好**的 —— 不告诉他要去删旧照片，
/// 他就只会反复点提交。
///
/// 判据的三条底线（缺一条这个修复就会静默退化）：
///   ① 拿得到原因时，**服务端那句中文原样出现**（不是客户端另编一句）；
///   ② 拿不到原因时**不许编** —— 宁可只说张数，也不能出现一句假话；
///   ③ 成功路径**不许长尾巴** —— 那会让每次正常提交都多一句吓人的话。
///
/// 还有一条分界：上传失败与写行失败的提示语**必须不同**。
/// 前者照片没上去、后者照片上去了但没绑上作业（家长看不到），
/// 学生要做的事不一样。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  Directory? tempDir;

  setUp(() async {
    tempDir = await setUpTestDatabase();
    Get.put(AuthController());
    Get.put(NotificationController());
    Get.find<AuthController>().currentUser.value = UserModel(
      id: 'stu_001',
      name: '林小宇',
      phone: '13800000001',
      role: 'student',
      avatar: '👦',
    );
  });

  tearDown(() async {
    Get.reset();
    final dir = tempDir;
    if (dir != null) await tearDownTestDatabase(dir);
  });

  HomeworkPhotoDraft photo(String name) => HomeworkPhotoDraft(
    fileName: name,
    bytes: Uint8List.fromList(List<int>.filled(8, 7)),
  );

  List<Map<String, dynamic>> drafts() => [
    {
      'title': '完成第1-20题',
      'subject': '数学',
      'dueAt': DateTime(2026, 9, 23, 20),
      'estimatedMinutes': 20,
    },
  ];

  /// 建一份作业并返回它的 id（走假仓库，id 是 `srv-N`）。
  Future<({StudentController student, String homeworkId})> ready({
    ImageStorageService? storage,
    _RowsFailingRepo? repo,
  }) async {
    final r = repo ?? _RowsFailingRepo();
    final student = StudentController(
      aiCheckDelay: Duration.zero,
      imageStorage: storage ?? LocalImageStorageService(useMemory: true),
      homework: r,
    );
    await student.addHomeworks(drafts());
    return (student: student, homeworkId: student.homeworkList.first.id);
  }

  group('照片失败时必须带出原因', () {
    test('上传就失败（配额满）：服务端那句话原样出现在提示里', () async {
      final quota = DataApiException(
        code: 'storage_quota_exceeded',
        message: _serverQuotaMessage,
        status: 409,
        retryable: false,
      );
      final ctx = await ready(storage: _UploadFailingStorage(quota));

      final result = await ctx.student.submitHomework(
        homeworkId: ctx.homeworkId,
        photos: [photo('a.jpg'), photo('b.jpg'), photo('c.jpg')],
        needsGrading: false,
      );

      // 提交本身没被毁 —— 照片存不下不该让「已提交」这件事消失。
      expect(result.ok, isTrue, reason: result.message);
      expect(result.message, contains('作业已提交'));
      expect(result.message, contains('（3 张照片保存失败）'));
      expect(
        result.message,
        contains('照片数量已达上限'),
        reason: '不告诉学生「是什么原因」，他只会反复点提交（这是再试也不会好的失败）',
      );
      // 比「含原因」更硬的一条：提示得**指了下一步该做什么**。
      expect(result.message, contains('删掉一些旧照片'));
      expect(
        result.message,
        contains('IMAGE_QUOTA_PER_STUDENT'),
        reason: '服务端文案里带上了「谁能调大它」—— 这是给运维看的那半句，原样保留',
      );
    });

    test('非配额的原因也照样带出来（不是给配额特调的一条路）', () async {
      final tooBig = DataApiException(
        code: 'payload_too_large',
        message: '照片超过单张 8MB 上限，请压缩后重试',
        status: 413,
      );
      final ctx = await ready(storage: _UploadFailingStorage(tooBig));

      final result = await ctx.student.submitHomework(
        homeworkId: ctx.homeworkId,
        photos: [photo('a.jpg')],
        needsGrading: false,
      );

      expect(result.message, contains('（1 张照片保存失败）'));
      expect(result.message, contains('照片超过单张 8MB 上限'));
    });

    test('写行失败（字节上去了、行没记上）：提示与「保存失败」不是同一句', () async {
      // 库里已 9999 张、这次交 3 张时会发生这件事：上传是**逐张**预检的，
      // 所以三次上传全都过，写行时才越界。而这一段以前被 `_safePersist`
      // 整个吞掉 —— 后果是「提交成功」+ 照片一张都不在，连张数提示都没有。
      final repo = _RowsFailingRepo()
        ..rowsError = DataApiException(
          code: 'storage_quota_exceeded',
          message: _serverQuotaMessage,
          status: 409,
        );
      final ctx = await ready(repo: repo);

      final result = await ctx.student.submitHomework(
        homeworkId: ctx.homeworkId,
        photos: [photo('a.jpg'), photo('b.jpg')],
        needsGrading: false,
      );

      expect(result.ok, isTrue, reason: result.message);
      expect(
        result.message,
        contains('照片没能记进这次作业'),
        reason: '「上去了但没绑上作业」与「压根没上去」要分开说，学生的处置不一样',
      );
      expect(
        result.message,
        isNot(contains('张照片保存失败')),
        reason: '字节其实上去了，说成「保存失败」是错的',
      );
      expect(result.message, contains('照片数量已达上限'));
      expect(
        result.message,
        startsWith('作业已提交（'),
        reason: '尾巴必须自带括号，否则「作业已提交照片没能记进…」会糊成一句话',
      );

      // 存不下也别毁掉这次操作：内存里那几行要留下（字节还在本进程缓存里，
      // `HomeworkImageReader` 会先命中它，所以本会话内照片仍然看得见）。
      expect(
        ctx.student.imagesOfHomework(ctx.homeworkId),
        hasLength(2),
        reason: '行没记上就把照片从内存里也删掉的话，学生这次提交等于白交',
      );
    });

    test('取不到原因时不许编：只说张数，不带内部错误文本', () async {
      // 超时 / 连接被拒这类不是 DataApiException，没有可展示的中文。
      // 这时的正确行为是**少说一句**，而不是把 `Exception: ...` 丢给学生，
      // 也不是自己编一句「网络异常」—— 那是猜的。
      final ctx = await ready(
        storage: _UploadFailingStorage(
          const SocketException('Connection refused (127.0.0.1:8788)'),
        ),
      );

      final result = await ctx.student.submitHomework(
        homeworkId: ctx.homeworkId,
        photos: [photo('a.jpg'), photo('b.jpg')],
        needsGrading: false,
      );

      expect(
        result.message,
        '作业已提交（2 张照片保存失败）',
        reason: '取不到原因就只有张数 —— 精确到这一整句，才守得住「不许编」这条线',
      );
      expect(result.message, isNot(contains('SocketException')));
      expect(result.message, isNot(contains('127.0.0.1')));
    });

    test('照片全部成功时，提示里不许出现任何尾巴', () async {
      final ctx = await ready();

      final result = await ctx.student.submitHomework(
        homeworkId: ctx.homeworkId,
        photos: [photo('a.jpg')],
        needsGrading: false,
      );

      expect(
        result.message,
        '作业已提交',
        reason: '成功路径上多一句「（0 张照片保存失败）」这种噪音，会让人开始忽略这类提示',
      );
    });
  });

  /// 「快满了」是在**下一次失败之前**说话 —— 它要防的那件事是：
  /// 学生只有在传不上去的那一刻才知道额度没了，而那时作业已经交不了。
  ///
  /// 判据的重点全在**反面**：这类提示太容易变成「无论什么情况都加一句」，
  /// 而那样做的结果是每次提交都多一句没人读的话，最后连真出问题的那条
  /// 也跟着被忽略。所以：不接近时不许说、服务端没给时不许说、
  /// **写行失败时更不许说**（那时该说的是为什么失败）。
  group('照片快满了要提前说', () {
    /// 造一个「服务端给了用量」的替身。`nearLimit` 由调用方明确给出 ——
    /// 它是**服务端下的结论**，客户端不做二次判断（见 `PhotoUsage` 的类文档）。
    _RowsFailingRepo repoWithUsage({
      required int used,
      required int remaining,
      required bool nearLimit,
    }) => _RowsFailingRepo()
      ..usage = PhotoUsage(
        used: used,
        quota: 3000,
        remaining: remaining,
        warnRemaining: 20,
        nearLimit: nearLimit,
      );

    test('接近上限：成功提交后带出「已存多少 / 只剩多少」', () async {
      final ctx = await ready(
        repo: repoWithUsage(used: 2985, remaining: 15, nearLimit: true),
      );

      final result = await ctx.student.submitHomework(
        homeworkId: ctx.homeworkId,
        photos: [photo('a.jpg')],
        needsGrading: false,
      );

      expect(result.ok, isTrue, reason: result.message);
      expect(result.message, startsWith('作业已提交'));
      expect(result.message, contains('2985'), reason: '要说清「已经存了多少」');
      expect(result.message, contains('3000'), reason: '还要说清「上限是多少」');
      expect(
        result.message,
        contains('只剩 15 张'),
        reason: '最关键的是这句 —— 「我还剩几次机会」才是学生能据以行动的信息',
      );
      expect(
        result.message,
        contains('删掉一些旧照片'),
        reason: '只说「快满了」而不说该怎么办，等于把问题丢给学生',
      );
    });

    test('不接近上限时**一个字都不说**', () async {
      // 反面判据。少了这一条，把提示写成「无论什么情况都加一句」也会全绿，
      // 而那种实现的后果是每次提交都多一句没人读的话。
      final ctx = await ready(
        repo: repoWithUsage(used: 100, remaining: 2900, nearLimit: false),
      );

      final result = await ctx.student.submitHomework(
        homeworkId: ctx.homeworkId,
        photos: [photo('a.jpg')],
        needsGrading: false,
      );

      expect(
        result.message,
        '作业已提交',
        reason: '还有 2900 张额度时说「快满了」就是在喊狼来了',
      );
    });

    test('服务端没给用量时也不说（本地模式走的就是这条路）', () async {
      // 替身默认 `usage = null`，等价于「服务端响应里没有 photoUsage 这个字段」
      // —— 解析不出来时客户端的正确行为是**少说一句**，不是编一个。
      final ctx = await ready();

      final result = await ctx.student.submitHomework(
        homeworkId: ctx.homeworkId,
        photos: [photo('a.jpg')],
        needsGrading: false,
      );

      expect(result.message, '作业已提交');
    });

    test('写行失败时不说「快满了」—— 那时该说的是为什么失败', () async {
      // 这一条把「失败」与「快满了」的优先级钉住：两件事同时成立时，
      // 学生需要的是「这次为什么没成」，而「快满了」会把话头带偏。
      // 实现上它是天然成立的（写行抛错时用量根本没被采纳），
      // 所以这条判据守的是**以后有人把两件事合并成一句**的情况。
      final repo = repoWithUsage(used: 2985, remaining: 15, nearLimit: true)
        ..rowsError = DataApiException(
          code: 'storage_quota_exceeded',
          message: _serverQuotaMessage,
          status: 409,
        );
      final ctx = await ready(repo: repo);

      final result = await ctx.student.submitHomework(
        homeworkId: ctx.homeworkId,
        photos: [photo('a.jpg')],
        needsGrading: false,
      );

      expect(result.message, contains('照片没能记进这次作业'));
      expect(result.message, contains('照片数量已达上限'), reason: '失败原因要说');
      expect(
        result.message,
        isNot(contains('只剩')),
        reason: '这次都没写进去，再叠一句「快满了」只会把失败原因淹掉',
      );
    });
  });
}
