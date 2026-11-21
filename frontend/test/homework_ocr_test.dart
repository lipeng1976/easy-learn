import 'dart:io';
import 'dart:typed_data';

import 'package:easy_learn_app/services/homework_text_parser.dart';
import 'package:easy_learn_app/services/image_storage_service.dart';
import 'package:easy_learn_app/services/ocr_data_source.dart';
import 'package:easy_learn_app/services/ocr_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/db_test_helper.dart';

/// OCR 数据源的契约测试。
///
/// 走的是接口而不是某个静态方法：接真实 OCR 后换掉实现即可，
/// 这些断言应该继续成立。
///
/// 最要紧的一条是**认不出来时必须说认不出来**。给它编一条「待确认」的
/// 占位任务看起来更"友好"，但那条占位会变成学生真的照着做的一项作业，
/// 而且他没有任何线索知道那是假的 —— 认错比认不出坏得多。
///
/// ⚠️ 反过来的一条同样要紧：**认出来了就不能说「没认出来」**。
/// 2026-09-29 的缺陷就是这一支 —— 见下面 `识别结果可用性` 那段。
/// 这两条一起构成「可用性」的上下界，缺任何一条这个文件都会放过一种错。
const _realRecognitionTasks = <Map<String, dynamic>>[
  {'subject': '数学', 'text': '学法P28、P29'},
  {'subject': '数学', 'text': 'P30选做'},
  {'subject': '英语', 'text': '练字一张'},
  {'subject': '英语', 'text': '写书P23页题目(全部的)'},
  {'subject': '地理', 'text': '学法P27 1.2.37'},
  {'subject': '地理', 'text': 'P25选择题'},
  {'subject': '语文', 'text': '写学与练 P11 P12 P14'},
  {'subject': '语文', 'text': '背记《次》《天》，明早默写'},
];

void main() {
  const source = SimulatedOcrDataSource();
  final bytes = Uint8List.fromList(const [1, 2, 3]);

  test('能定出科目时，置信度必须高于可用底线', () async {
    final result = await source.recognizeHomework(
      fileName: 'math-homework.jpg',
      bytes: bytes,
    );

    expect(result.success, isTrue);
    expect(result.text, contains('分数'));
    expect(result.subject, '数学');
    expect(result.confidence, greaterThanOrEqualTo(kOcrConfidenceFloor));
    expect(result.tasks, isNotEmpty);
  });

  test('认不出内容时如实失败：不给占位任务', () async {
    final result = await source.recognizeHomework(
      fileName: 'homework-photo.jpg',
      bytes: bytes,
    );

    expect(result.success, isFalse);
    expect(result.tasks, isEmpty, reason: '猜出来的条目会变成学生真的去做的作业');
    expect(result.subject, '待确认');
    expect(result.confidence, lessThan(kOcrConfidenceFloor));
    expect(result.text, isNotEmpty, reason: '要留一句说明，界面才能解释为什么没认出来');
  });

  group('识别结果可用性', () {
    HomeworkOcrResult build({
      required List<Map<String, dynamic>> tasks,
      required double confidence,
    }) => HomeworkOcrResult(
      images: const [],
      text: '',
      subject: '待确认',
      confidence: confidence,
      tasks: tasks,
    );

    /// 线上真实的一次识别（2026-09-29，一张黑板手抄作业清单照片）。
    ///
    /// 四门课的科目全认对、8 条任务、网关结构违约 0 条、平均 5.7 秒，
    /// 但模型自报的把握只有 0.6~0.7（连跑 10 次，均值 0.665）。
    ///
    /// **口径改成现在这样之前，这 8 条会被整份丢掉**：`isUsable` 当时要求
    /// 把握 ≥ 0.8，于是学生看到的是「没能认出作业内容」+「建议重拍」——
    /// 而照片没问题，重拍多少次结果都一样（10 次 10 次都在 0.8 以下）。
    ///
    /// 条目内容与 [HttpOcrDataSource] 实际收到的一致（探针脚本
    /// `build/_probe/ocr_compare.mjs` 打出来的原文）。

    test('有任务就算可用 —— 把握低只要求核对，不整份丢弃', () {
      final result = build(tasks: _realRecognitionTasks, confidence: 0.665);

      expect(
        result.isUsable,
        isTrue,
        reason: '0.665 是这张照片实测的均值；判成「没认出来」就是那条缺陷',
      );
      expect(
        result.needsReview,
        isTrue,
        reason: '把握低必须在核对表单顶部醒目提醒逐条核对',
      );
    });

    test('把握够时不额外提醒核对', () {
      final result = build(
        tasks: _realRecognitionTasks,
        confidence: kOcrConfidenceFloor,
      );

      expect(result.isUsable, isTrue);
      expect(result.needsReview, isFalse, reason: '把握够就不该再说「这次偏低」');
    });

    test('没任务就不可用 —— 把握再高也一样', () {
      final result = build(tasks: const [], confidence: 0.95);

      expect(result.isUsable, isFalse, reason: '空清单存下去等于什么都没录');
      expect(
        result.needsReview,
        isFalse,
        reason: '这一支走的是报错对话框，不是核对表单',
      );
    });
  });

  group('按科目归类', () {
    test('组间按首次出现排序，「待确认」永远压到最后', () {
      final groups = HomeworkTextParser.groupBySubject([
        {'subject': '数学', 'text': '资料第8-9页'},
        {'subject': '待确认', 'text': '待补充说明'},
        {'subject': '语文', 'text': '背诵第二课'},
        {'subject': '数学', 'text': '试卷一套'},
      ]);

      expect(groups.map((group) => group.subject).toList(), ['数学', '语文', '待确认']);
      expect(groups.first.texts, ['资料第8-9页', '试卷一套']);
      expect(groups.last.count, 1);
    });

    test('同一科目下的重复条目只留一条', () {
      final groups = HomeworkTextParser.groupBySubject([
        {'subject': '英语', 'text': '听写 unit2'},
        {'subject': '英语', 'text': '听写 unit2'},
      ]);

      expect(groups.single.count, 1, reason: '同一页拍两遍不该变成两项作业');
    });

    test('空白条目被丢掉，也不会造出空分组', () {
      final groups = HomeworkTextParser.groupBySubject([
        {'subject': '语文', 'text': '   '},
        {'subject': '', 'text': '作文一篇'},
      ]);

      expect(groups.length, 1);
      expect(groups.single.subject, '待确认');
      expect(groups.single.texts, ['作文一篇']);
    });
  });

  group('多张照片合并成一份清单', () {
    late Directory dir;

    setUp(() async {
      dir = await setUpTestDatabase();
    });

    tearDown(() async {
      await tearDownTestDatabase(dir);
    });

    OcrService buildService() => OcrService(
      storage: LocalImageStorageService(useMemory: true),
      dataSource: const SimulatedOcrDataSource(),
    );

    HomeworkOcrInput input(String name, [int seed = 1]) =>
        HomeworkOcrInput(fileName: name, bytes: Uint8List.fromList([seed]));

    test('两张照片的任务合并去重，跨科目时标成「多科目」', () async {
      final result = await buildService().recognizeHomework(
        studentId: 'stu_001',
        inputs: [input('作业单.jpg'), input('作业单.jpg', 2)],
      );

      expect(result.sourceImageCount, 2);
      expect(result.recognizedImageCount, 2);
      expect(result.subject, '多科目');
      // 「作业单」档识别出 语文 2 条 + 数学 2 条 + 英语 1 条；
      // 两张照片给的是同一份清单，去重后仍应是 5 条而不是 10 条。
      expect(result.tasks.length, 5, reason: '两张照片认出同一份清单，去重后不该翻倍');
      expect(result.hasMissedImages, isFalse);
      expect(result.isUsable, isTrue);
    });

    test('有照片认不出来时，要能算出漏了几张', () async {
      final result = await buildService().recognizeHomework(
        studentId: 'stu_001',
        inputs: [input('数学.jpg'), input('随手拍的.jpg', 2)],
      );

      expect(result.recognizedImageCount, 1);
      expect(
        result.hasMissedImages,
        isTrue,
        reason: '不告诉学生漏了一张，他会以为整份作业都录进来了',
      );
      expect(
        result.isUsable,
        isTrue,
        reason: '认出一页也算能用，漏的那页单独提示即可',
      );
      expect(result.subject, '数学');
    });

    test('全都认不出来时不可用，也不把照片落库', () async {
      final result = await buildService().recognizeHomework(
        studentId: 'stu_001',
        inputs: [input('随手拍的.jpg'), input('另一张.jpg', 2)],
      );

      expect(result.isUsable, isFalse);
      expect(result.tasks, isEmpty);
      expect(result.confidence, 0);
      expect(
        result.images,
        isEmpty,
        reason: '没产出任何内容的照片存下来只会占空间，学生也不会去看',
      );
    });
  });

  group('线上真实结果走完整链路', () {
    late Directory dir;

    setUp(() async {
      dir = await setUpTestDatabase();
    });

    tearDown(() async {
      await tearDownTestDatabase(dir);
    });

    test('把握 0.665 的那一次：8 条全在、科目全对、只要求核对', () async {
      final result = await OcrService(
        storage: LocalImageStorageService(useMemory: true),
        dataSource: const _FixedOcrDataSource(),
      ).recognizeHomework(
        studentId: 'stu_001',
        inputs: [
          HomeworkOcrInput(
            fileName: '作业清单.jpg',
            bytes: Uint8List.fromList(const [1, 2, 3]),
          ),
        ],
      );

      expect(result.failure, isNull, reason: '这条路一次就成功了，不是降级');
      expect(
        result.isUsable,
        isTrue,
        reason: '这就是那次缺陷的现场：8 条真作业曾被判成「没认出来」',
      );
      expect(result.needsReview, isTrue);
      expect(
        result.tasks.length,
        8,
        reason: '归一化与去重不该吃掉任何一条'
            '（「学法P27 1.2.37」会被读成列举 `1、2、3、7`，但仍是一条）',
      );
      expect(result.tasks.map((task) => task['subject']).toSet(), {
        '数学',
        '英语',
        '地理',
        '语文',
      });
      expect(result.subject, '多科目');
    });
  });
}

/// 复刻线上那一次识别的返回（数值与条目取自 `build/_probe/ocr_compare.mjs`
/// 用同一张照片、同一份提示词与 schema 实测出来的结果）。
class _FixedOcrDataSource implements OcrDataSource {
  const _FixedOcrDataSource();

  @override
  Future<OcrRecognitionResult> recognizeHomework({
    required String fileName,
    required Uint8List bytes,
  }) async => const OcrRecognitionResult(
    success: true,
    text: '9.29 数学 学法P28、P29 / P30选做 英:练字一张 地:学法P27 语:写学与练P11P12P14',
    subject: '待确认',
    confidence: 0.665,
    tasks: _realRecognitionTasks,
  );
}
