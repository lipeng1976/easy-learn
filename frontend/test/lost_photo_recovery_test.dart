import 'dart:convert';
import 'dart:typed_data';

import 'package:easy_learn_app/controllers/student_controller.dart';
import 'package:easy_learn_app/models/homework_model.dart';
import 'package:easy_learn_app/models/homework_photo_draft.dart';
import 'package:easy_learn_app/models/op_result.dart';
import 'package:easy_learn_app/pages/student/widgets/homework_submit_sheet.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/services/lost_photo_recovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

/// 一张 1×1 的**合法** PNG。
///
/// 为什么不随便给几个字节：面板会把待提交照片渲染成缩略图（`Image.memory`），
/// 非法字节会让解码抛错，而那个错误跟被测行为毫无关系 —— 测试会红在一个
/// 完全无关的地方，然后误导人去查图片链路。
final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

/// 造一个"丢失的照片"。
///
/// 必须走 `XFile.fromData` 而不是 `XFile(path)`：io 实现里构造函数收的
/// `bytes` 参数是被**忽略**的（`_bytes = null`），只有 `fromData` 才真的
/// 把字节攥在内存里（`readAsBytes()` 会直接返回它）。用 `XFile(path)` 的话
/// 会去读磁盘，而 `testWidgets` 跑在假时钟里，真实文件 I/O 永远不会完成。
XFile _lostPhoto(String name) =>
    XFile.fromData(_tinyPng, path: name, name: name, mimeType: 'image/png');

/// 只记录「面板把哪些照片交上来了」的控制器。
///
/// 不碰数据库的理由见 `恢复的照片要真的进到提交面板里` 那组的注释。
/// 断言「提交调用收到的照片」与断言「落库的照片」一样硬 —— 它证明恢复的
/// 照片确实被面板持有、并且真的进入了提交这条链路。
class _FakeSubmitController extends StudentController {
  _FakeSubmitController({required HomeworkItem homework})
    : super(imageStorage: LocalImageStorageService(useMemory: true)) {
    homeworkList.add(homework);
  }

  List<HomeworkPhotoDraft>? submittedPhotos;

  @override
  Future<OpResult> submitHomework({
    required String homeworkId,
    List<HomeworkPhotoDraft> photos = const <HomeworkPhotoDraft>[],
    bool? needsGrading,
  }) async {
    submittedPhotos = photos;
    return const OpResult.success('作业已提交');
  }
}

HomeworkItem _homework() => HomeworkItem(
  id: 'hw_lost',
  title: '数学作业',
  subject: '数学',
  imageUrl: '',
  dueAt: DateTime(2026, 9, 17, 20),
  estimatedMinutes: 15,
  status: HomeworkStatus.pending,
  wrongCount: 0,
  aiEnabled: true,
  needsGrading: false,
  userRole: 'student',
  studentId: 'stu_001',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  tearDown(() {
    Get.reset();
    // 静态实例是全局状态，必须还原，否则会漏给下一个用例。
    LostPhotoRecovery.instance = const LostPhotoRecovery();
  });

  /// 推进固定帧数，**不要用 `pumpAndSettle()`**。
  ///
  /// 待提交列表里渲染的是 `Image.memory`，而图片解码是真实异步的 ——
  /// 在 testWidgets 的假时钟下它不会完成，`pumpAndSettle()` 会一直等下去。
  /// 现象是整个测试**挂死**（跑几分钟毫无输出），而不是干脆地失败 ——
  /// 很容易误判成「测试运行器卡了」，然后去查完全无关的地方。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));
  }

  /// 排空 GetX snackbar 的定时器队列。
  ///
  /// snackbar 自带「到点自动关」，而且是**排队**的：第一条关掉第二条才显示、
  /// 又新建一个定时器。测试结束时还有定时器活着，框架会判
  /// 「A Timer is still pending」。注意 `pumpAndSettle` 不管这事 ——
  /// 它只推进会排帧的定时器。
  Future<void> drainSnackbars(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 4));
    }
  }

  group('LostPhotoRecovery 取数', () {
    test('没有丢失数据时返回空', () async {
      final recovery = LostPhotoRecovery(
        retrieve: () async => LostDataResponse.empty(),
      );
      expect(await recovery.takeLostPhotos(), isEmpty);
    });

    test('多选丢失走 files，全部取回', () async {
      final recovery = LostPhotoRecovery(
        retrieve: () async => LostDataResponse(
          files: [_lostPhoto('a.png'), _lostPhoto('b.png')],
        ),
      );
      final files = await recovery.takeLostPhotos();
      expect(files.map((e) => e.name).toList(), ['a.png', 'b.png']);
    });

    test('单张拍照只填了 file 也要取到', () async {
      // 官方注释说「files 有值时 file 就是它的最后一项」，反过来说
      // 「files 为空时 file 可能单独有值」——只看 files 会漏掉单张的情况。
      final recovery = LostPhotoRecovery(
        retrieve: () async => LostDataResponse(file: _lostPhoto('solo.png')),
      );
      final files = await recovery.takeLostPhotos();
      expect(files.map((e) => e.name).toList(), ['solo.png']);
    });

    test('files 与 file 同时有值时不会多出一张重复', () async {
      // 这正是「顺序反了」会踩的坑：若先取 file 再并 files，同一张会进两次。
      final last = _lostPhoto('b.png');
      final recovery = LostPhotoRecovery(
        retrieve: () async =>
            LostDataResponse(files: [_lostPhoto('a.png'), last], file: last),
      );
      expect(await recovery.takeLostPhotos(), hasLength(2));
    });

    test('响应非空但两个字段都为空时返回空列表', () async {
      // 注意 LostDataResponse 的 isEmpty 只反映「是不是用 .empty() 构造的」，
      // 不代表里面真有文件，所以不能只靠它判断。
      final recovery = LostPhotoRecovery(
        retrieve: () async => LostDataResponse(),
      );
      expect(await recovery.takeLostPhotos(), isEmpty);
    });

    test('取数抛异常时吞掉，不把界面变成红屏', () async {
      final recovery = LostPhotoRecovery(
        retrieve: () async => throw StateError('平台通道炸了'),
      );
      expect(await recovery.takeLostPhotos(), isEmpty);
    });
  });

  group('恢复的照片要真的进到提交面板里', () {
    // 这一组刻意**不碰数据库**：`testWidgets` 跑在假时钟里，真实异步 I/O
    // （SQLite 查询）永远不会完成 —— 现象是测试**挂死**而不是失败，
    // 一挂就是几分钟，很容易被误判成「运行器卡了」。
    // 「提交之后有没有真的落库」由 homework_submission_flow_test.dart 负责，
    // 两边分工：这里只钉「恢复的照片有没有进到面板、有没有被交出去」。

    Future<void> openSheet(WidgetTester tester, StudentController s) async {
      await tester.pumpWidget(
        // GetMaterialApp 而不是 MaterialApp：面板会用 Get.snackbar 通报
        // 「已找回照片」，而它依赖 GetX 自己的 overlay / navigator。
        GetMaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                // 不用 ElevatedButton：面板里的提交按钮就是 ElevatedButton，
                // 同一类型会让 `find.byType` 一次命中两个。
                onPressed: () => openHomeworkSubmitSheet(
                  context: context,
                  controller: s,
                  homework: _homework(),
                ),
                child: const Text('打开提交面板'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开提交面板'));
      await settle(tester);
    }

    testWidgets('有丢失照片时，照片进到待提交列表并明确告知来历', (tester) async {
      final controller = _FakeSubmitController(homework: _homework());
      LostPhotoRecovery.instance = LostPhotoRecovery(
        retrieve: () async =>
            LostDataResponse(files: [_lostPhoto('lost-1.png')]),
      );

      await openSheet(tester, controller);

      // 「本次提交的照片（N 张）」是**同一个 Text 里的插值**，所以整句在语义树里
      // 真实存在；这一点与「标签 + 数字是两个独立节点」的情况不同。
      // 文案在 2026-10-03 从「本次提交的照片（N 张）」改成了按类型分列的
      // 「本次提交的附件（N 张照片）」—— 因为同一个列表里现在还会有音频与
      // 视频，混成一个总数会让人以为照片有那么多张。
      expect(find.text('本次提交的附件（1 张照片）'), findsOneWidget);
      // 必须明确说来历：列表里凭空多出照片而不解释，比照片丢了更让人困惑。
      expect(find.text('已找回照片'), findsOneWidget);

      await drainSnackbars(tester);
    });

    testWidgets('没有丢失照片时不塞东西、也不弹提示', (tester) async {
      final controller = _FakeSubmitController(homework: _homework());
      LostPhotoRecovery.instance = LostPhotoRecovery(
        retrieve: () async => LostDataResponse.empty(),
      );

      await openSheet(tester, controller);

      expect(find.text('本次提交的附件'), findsOneWidget);
      expect(find.text('已找回照片'), findsNothing);

      await drainSnackbars(tester);
    });

    testWidgets('恢复的照片会跟着这次提交一起交给控制器', (tester) async {
      // 最硬的一条：不只看它出现在列表上，还要看它真的被交了出去。
      // 中间任何一段断了都会在这里露出来 —— 没接上、接了但没 setState、
      // 提交时没用这个列表而是又去读了一次相册。
      final controller = _FakeSubmitController(homework: _homework());
      LostPhotoRecovery.instance = LostPhotoRecovery(
        retrieve: () async =>
            LostDataResponse(files: [_lostPhoto('lost-2.png')]),
      );

      await openSheet(tester, controller);
      expect(controller.submittedPhotos, isNull, reason: '取回阶段不该提交');

      // 面板里唯一的 ElevatedButton 就是提交按钮。
      await tester.tap(find.byType(ElevatedButton));
      await settle(tester);

      expect(controller.submittedPhotos, hasLength(1));
      expect(controller.submittedPhotos!.single.fileName, 'lost-2.png');

      await drainSnackbars(tester);
    });
  });
}
