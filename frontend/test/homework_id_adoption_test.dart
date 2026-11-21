import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy_learn_app/controllers/auth_controller.dart';
import 'package:easy_learn_app/controllers/notification_controller.dart';
import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/homework_image_model.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/models/homework_photo_draft.dart';
import 'package:easy_learn_app/models/user_model.dart';
import 'package:easy_learn_app/repositories/homework_repository.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'helpers/db_test_helper.dart';

/// 假仓库：**模拟服务端把 id 换掉**（迁移规则 R2）。
///
/// `insertHomework` 刻意返回一个与入参不同的 id —— 这正是线上发生的事：
/// 服务端 `POST /data/homework` 用 `newId()` 生成 uuid，客户端送的一律忽略
/// （`routes/homework.js` 的 `createHomework`）。本地那份实现不会换 id，
/// 所以这个差异**只有在这里才造得出来**。
class _ServerIdRepo implements HomeworkRepository {
  final List<String> patchedIds = <String>[];
  final List<HomeworkImageModel> savedImages = <HomeworkImageModel>[];
  int insertCalls = 0;
  int imageCalls = 0;
  bool failInsert = false;

  /// 把一次插入按住不返回，用来观察「往返还在飞」的那段中间态。
  Completer<void>? hold;

  @override
  Future<HomeworkItem> insertHomework(HomeworkItem item, String userRole) async {
    insertCalls++;
    final gate = hold;
    if (gate != null) await gate.future;
    if (failInsert) throw StateError('数据服务连不上');
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

  /// 写照片行，同样**换掉 id** —— 服务端 `imageRow()` 里写死 `id: newId()`，
  /// 客户端送进来的一律忽略（与作业那条同一条规则）。
  ///
  /// 这里必须真的换：本地实现原样返回入参，所以「占位 id 能被看出来」
  /// 这个差异**只有在这个假仓库上才造得出来**。
  @override
  Future<SavedHomeworkImages> saveHomeworkImages(
    List<HomeworkImageModel> images,
  ) async {
    final stored = images
        .map((e) => e.copyWith(id: 'simg-${++imageCalls}'))
        .toList();
    savedImages.addAll(stored);
    // 这个替身是**假的服务端**：它可以造出任意用量（含「快满了」）。
    // 默认回 null = 假装服务端没给这个字段 —— 正面场景不该顺带出提示。
    return SavedHomeworkImages(images: stored);
  }

  /// 本文件不测删除路径。这个空实现只是让「接口加了方法」的编译期约束过掉；
  /// 真要验删除，用 `homework_delete_test.dart` 里的专用替身。
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

/// 作业 id 必须在落库后被**换成服务端那一行的 id**。
///
/// 这条链路的失败方式全是静默的：照片挂在服务端不存在的作业上（按作业查
/// 查不到）、提交时的 update 打到不存在的行上（403 被 `_safePersist` 吞掉）。
/// 两处都「成功返回」，界面也正常 —— 所以判据只能打在**写出去的键**上：
/// 每一次写（照片、状态更新）用的都必须是服务端认得的那个 id。
///
/// 还有一条配套的顺序约束：**先落库拿到最终 id，再把作业放进列表**。
/// 反过来的窗口更窄（只有一次往返那么宽），但造成的失败一模一样 ——
/// 所以也在这里钉一条判据，见「往返还在飞的时候」那条。
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

  StudentController build(_ServerIdRepo repo) => StudentController(
    aiCheckDelay: Duration.zero,
    imageStorage: LocalImageStorageService(useMemory: true),
    homework: repo,
  );

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
    {
      'title': '背诵第二课',
      'subject': '语文',
      'dueAt': DateTime(2026, 9, 23, 21),
      'estimatedMinutes': 15,
    },
  ];

  group('落库后 id 只能是服务端那一行', () {
    test('识别确认建的作业，内存里换成服务端那一行', () async {
      final repo = _ServerIdRepo();
      final student = build(repo);

      await student.addHomeworks(drafts());

      expect(repo.insertCalls, 2);
      expect(student.homeworkList, hasLength(2));
      expect(student.homeworkList.map((e) => e.id), containsAll(['srv-1', 'srv-2']));
      expect(
        student.homeworkList.any((e) => e.id.startsWith('hw_')),
        isFalse,
        reason: '留着本地 id 的话，后面每一步（上传 / 提交 / 批改）都会打空',
      );
    });

    test('手工加一条作业也一样', () async {
      final repo = _ServerIdRepo();
      final student = build(repo);

      await student.addHomework(
        title: '默写单词',
        subject: '英语',
        dueAt: DateTime(2026, 9, 23, 19),
      );

      expect(student.homeworkList.first.id, 'srv-1');
    });

    test('换成服务端 id 之后，提交的照片与状态更新都打在那一行上', () async {
      // 这条是「照片看不到」的正面判据：照片挂的键 == 服务端作业的键。
      final repo = _ServerIdRepo();
      final student = build(repo);
      await student.addHomeworks(drafts());

      // 按标题认那一条，别用 `first`：`addHomeworks` 是
      // `insertAll(0, items.reversed)`，列表顺序与 drafts 的顺序相反。
      final target = student.homeworkList.firstWhere(
        (e) => e.title == '完成第1-20题',
      );
      expect(target.id, 'srv-1');

      final result = await student.submitHomework(
        homeworkId: target.id,
        photos: [photo('math-1.jpg')],
        needsGrading: false,
      );
      expect(result.ok, isTrue, reason: result.message);

      expect(repo.savedImages, hasLength(1));
      expect(repo.savedImages.single.homeworkId, 'srv-1');
      expect(repo.patchedIds, contains('srv-1'));
      expect(
        repo.patchedIds.any((e) => e.startsWith('hw_')),
        isFalse,
        reason: '这条打下去服务端会回 403「找不到这份作业」，而错误会被静默吞掉',
      );
    });

    test('提交后，内存里那份照片行必须换成服务端那一行', () async {
      // 真机反馈：「学生提交作业后，在当前界面看不到提交的图片，
      // 切换其他菜单再回来也没用，但是退出登录再进来就可以」。
      //
      // 读图是按 **id** 查的（`GET /data/homework/images/file?id=`），
      // 而服务端的 id 由它自己生成（`imageRow()` 里写死 `newId()`）。
      // 沿用上传时那个本地占位 id，字节明明在服务端也照样查不到 —— 且不报错。
      // 重登能好，是因为 `queryHomeworkImages` 那时才把真 id 带回来。
      //
      // 判据因此打在**内存里那一行的 id** 上，而不是「照片在不在」：
      // `savedImages` 里当然有、服务端也确实写了行 —— 每一段单独看都成功，
      // 那正是这条 bug 最难查的地方。
      final repo = _ServerIdRepo();
      final student = build(repo);
      await student.addHomeworks(drafts());

      final target = student.homeworkList.firstWhere(
        (e) => e.title == '完成第1-20题',
      );
      final result = await student.submitHomework(
        homeworkId: target.id,
        photos: [photo('math-1.jpg'), photo('math-2.jpg')],
        needsGrading: false,
      );
      expect(result.ok, isTrue, reason: result.message);

      final inMemory = student.imagesOfHomework(target.id);
      expect(inMemory, hasLength(2));
      expect(
        inMemory.map((e) => e.id),
        containsAll(<String>['simg-1', 'simg-2']),
        reason: '内存里留着本地占位 id 的话，按 id 读这条照片必然查不到（服务端不认那个 id）',
      );
      expect(
        inMemory.any((e) => e.id.startsWith('img_')),
        isFalse,
        reason: '`img_…` 是 RemoteImageStorageService 的本地占位，不是这一行的 id',
      );
      // 反面：`homeworkId` 也必须是服务端那个作业 id。这半边早就对了，
      // 一起钉住 —— 免得将来只盯着 id 而把挂载的作业弄丢。
      expect(inMemory.every((e) => e.homeworkId == target.id), isTrue);
    });

    test('插入失败时沿用本地 id —— 失败的只是回填，作业不能丢', () async {
      final repo = _ServerIdRepo()..failInsert = true;
      final student = build(repo);

      await student.addHomeworks(drafts());

      expect(student.homeworkList, hasLength(2));
      expect(
        student.homeworkList.every((e) => e.id.startsWith('hw_')),
        isTrue,
        reason: '`_safePersist` 的语义是「存不下也别毁掉这次操作」，拿不到服务端的行就沿用本地 id',
      );
    });

    test('往返还在飞的时候，这条作业不能出现在列表里', () async {
      // 判据打在**中间态**上。列表里一旦出现 id 还没定下来的作业，用户就能
      // 点进去提交，照片会挂到服务端不认的键上 —— 和「照片看不到」同一个成因，
      // 只是窗口只有一次往返那么宽。所以：落库回来之前，列表必须是空的。
      final repo = _ServerIdRepo()..hold = Completer<void>();
      final student = build(repo);

      final pending = student.addHomeworks(drafts());
      await Future<void>.delayed(Duration.zero);
      expect(
        student.homeworkList,
        isEmpty,
        reason: '窗口内出现在列表上 = 用户能点进去，而这时 id 还是本地拼的',
      );

      repo.hold!.complete();
      await pending;
      expect(
        student.homeworkList.every((e) => e.id.startsWith('srv-')),
        isTrue,
        reason: '出现的时候就必须已经是最终 id',
      );
      expect(student.homeworkList, hasLength(2));
    });
  });
}
