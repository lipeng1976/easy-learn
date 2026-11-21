import 'dart:typed_data';

import '../models/homework_image_model.dart';
import 'database_service.dart';
import 'homework_item_normalizer.dart';
import 'homework_text_parser.dart';
import 'image_storage_service.dart';
import 'ocr_data_source.dart';

class OcrService {
  OcrService({
    ImageStorageService? storage,
    DatabaseService? database,
    OcrDataSource? dataSource,
  }) : _storage = storage ?? createImageStorage(),
       _database = database ?? DatabaseService.instance,
       _dataSource = dataSource ?? SimulatedOcrDataSource();

  final ImageStorageService _storage;
  final DatabaseService _database;
  final OcrDataSource _dataSource;

  /// 识别若干张作业照片，合并出这次要录入的作业条目（按科目 + 内容去重）。
  ///
  /// 一次性收多张，而不是「一张一次」：作业抄在两三页上很常见，
  /// 一张一次会让同一次录入产生几份互不知情的清单，学生得手动合并。
  Future<HomeworkOcrResult> recognizeHomework({
    required String studentId,
    required List<HomeworkOcrInput> inputs,
  }) async {
    final images = <HomeworkImageModel>[];
    final textBuffer = <String>[];
    final tasks = <Map<String, dynamic>>[];
    final failures = <OcrFailureKind>[];
    final failureNotes = <String>[];
    double confidence = 0;

    for (final input in inputs) {
      final result = await _dataSource.recognizeHomework(
        fileName: input.fileName,
        bytes: input.bytes,
      );
      // 认不出来的照片不落库：它既不是作业成果（不能进作业详情），
      // 也没能产出任务（没有核对价值），存下来只会占空间且永远没人看。
      if (!result.success) {
        // 但**原因**要留下来。只丢一个「失败了」出去，界面就只能说
        // 「没能认出内容」——而真实成因可能是「没登录」，两者给用户的
        // 下一步动作完全相反。
        if (result.failure != null) failures.add(result.failure!);
        if (result.failureNote != null) failureNotes.add(result.failureNote!);
        continue;
      }

      final image = await _storage.saveHomeworkImage(
        studentId: studentId,
        fileName: input.fileName,
        bytes: input.bytes,
        ocrStatus: 'completed',
        ocrText: result.text,
      );
      // 与「提交作业」那条同一条口径：**写行返回的那一行才是这一行的最终 id**，
      // 因为服务端 `imageRow()` 里写死 `id: newId()`，上传时那个 `img_…`
      // 只是本地占位（见 `HomeworkRepository.saveHomeworkImages` 的说明）。
      //
      // 这条路目前没有「按 id 读回图片」的下游 —— 识别预览用的是内存里
      // 带字节的 draft，而这些行的 `homeworkId` 是空的、`imagesOfHomework`
      // 永远匹配不到它们。但延续本地占位 id 是同一颗地雷：
      // 哪天有人把 `result.images` 直接喂给 `HomeworkImageGrid`，就会炸。
      var stored = image;
      try {
        final rows = await _database.saveHomeworkImage(image);
        if (rows.isNotEmpty) stored = rows.first;
      } catch (_) {
        // 落库失败不该让整批识别结果作废 —— 这一张的字节还在本进程里，
        // 沿用本地那份至少本次会话是自洽的。
      }
      images.add(stored);

      if (result.text.isNotEmpty) textBuffer.add(result.text);
      // 取最高的一张：一张清楚、一张模糊时，整体把握由清楚的那张决定，
      // 加权平均会让「两页里只有一页糊」显得像整份都没认好。
      if (result.confidence > confidence) confidence = result.confidence;

      // 归一化是**所有来源的公共漏斗**：模型给的 tasks、规则解析出的 tasks、
      // 模拟实现的 tasks 都从这里过一遍。放在这里而不是各自的实现里，
      // 是因为「一条 = 一件事」是这个类的调用方（分组、统计、组卷）
      // 依赖的前提，谁产生的不该影响它成不成立。
      final raw = result.tasks.isNotEmpty
          ? result.tasks
          : (result.text.isEmpty
                ? const <Map<String, dynamic>>[]
                : HomeworkTextParser.parse(result.text));
      for (final item in HomeworkItemNormalizer.normalizeAll(raw)) {
        HomeworkItemNormalizer.mergeInto(tasks, item);
      }
    }

    return HomeworkOcrResult(
      images: images,
      text: textBuffer.join('\n'),
      subject: _dominantSubject(tasks),
      confidence: images.isEmpty ? 0 : confidence,
      tasks: tasks,
      sourceImageCount: inputs.length,
      recognizedImageCount: images.length,
      failure: _dominantFailure(failures),
      failureNote: failureNotes.isEmpty ? null : failureNotes.first,
    );
  }

  /// 多张照片各有各的失败原因时，取**最该被处理的那一个**。
  ///
  /// 顺序按「用户能做什么」排，不按严重程度排：
  /// 未登录（去登录就能解决）→ 没接云端 → 服务端拒了 → 连不上 → 照片没认出来。
  /// 反过来的话，一张糊照片会把「其实是你没登录」这件事盖掉。
  OcrFailureKind? _dominantFailure(List<OcrFailureKind> failures) {
    if (failures.isEmpty) return null;
    const priority = [
      OcrFailureKind.noIdentity,
      OcrFailureKind.offline,
      OcrFailureKind.rejected,
      OcrFailureKind.unreachable,
      OcrFailureKind.notRecognized,
    ];
    for (final kind in priority) {
      if (failures.contains(kind)) return kind;
    }
    return failures.first;
  }

  /// 单科目时直接用它的名字，多科目时标成「多科目」。
  ///
  /// 不再沿用「最后一张照片给的 subject」：多张照片合并后，
  /// 用其中一张的科目代表整体，界面会显示成「数学（其实还有语文）」。
  String _dominantSubject(List<Map<String, dynamic>> tasks) {
    final subjects = <String>{};
    for (final task in tasks) {
      final subject = (task['subject'] as String?)?.trim();
      if (subject == null || subject.isEmpty) continue;
      if (subject == HomeworkItemNormalizer.unknownSubject) continue;
      subjects.add(subject);
    }
    if (subjects.isEmpty) return HomeworkItemNormalizer.unknownSubject;
    if (subjects.length == 1) return subjects.first;
    return '多科目';
  }
}

/// 多张待识别图片的输入参数。
class HomeworkOcrInput {
  final String fileName;
  final Uint8List bytes;

  const HomeworkOcrInput({required this.fileName, required this.bytes});
}

class HomeworkOcrResult {
  final List<HomeworkImageModel> images;
  final String text;
  final String subject;
  final double confidence;
  final List<Map<String, dynamic>> tasks;

  /// 这次一共送进来几张照片。
  final int sourceImageCount;

  /// 其中认出内容的张数。少于 [sourceImageCount] 说明有照片白拍了 ——
  /// 这必须告诉学生，否则他会以为整份作业都录进来了。
  final int recognizedImageCount;

  /// 这次识别失败的**主要原因**。全部成功时为 null。
  ///
  /// 与 [isUsable] 是两件事：[failure] 回答「为什么没成」，
  /// [isUsable] 回答「这次的产出能不能当作业清单用」。
  /// 一张也没认出来时两者会同时出现；而「模型答了、但一条可用任务都没有」
  /// 只有 [isUsable] 为假 —— 那种情况才该建议重拍。
  ///
  /// ⚠️ [isUsable] **不看 [confidence]**，所以「模型答了但把握低」不再
  /// 落进这里；它走 [needsReview]，进核对表单而不是被丢掉。
  final OcrFailureKind? failure;

  /// 给人看的失败说明，直接可用于提示文案。
  final String? failureNote;

  const HomeworkOcrResult({
    required this.images,
    required this.text,
    required this.subject,
    required this.confidence,
    required this.tasks,
    this.sourceImageCount = 0,
    this.recognizedImageCount = 0,
    this.failure,
    this.failureNote,
  });

  /// 有没有照片没认出来。
  bool get hasMissedImages => recognizedImageCount < sourceImageCount;

  /// 这次有没有产出能当作业清单用的内容。
  ///
  /// ⚠️ **只看有没有任务，不看把握**（2026-09-29 改）。
  ///
  /// 原来写成 `tasks.isNotEmpty && confidence >= kOcrConfidenceFloor`。
  /// 后果是「认出来了、但整体把握偏低」的整份结果被**丢掉**，学生只看到
  /// 「没能认出作业内容」加一句「建议重拍」—— 而模型其实每条都认对了。
  ///
  /// 真实案例（虫子给的一张手抄作业清单照片，线上配置 `qwen3.5-omni-plus`
  /// 连跑 10 次）：**8 条任务、四门课的科目全对、结构违约 0 条、平均 5.7 秒**，
  /// 但把握只有 0.6~0.7 ⇒ 10/10 全都低于 0.8，**一条都进不了核对表单**。
  ///
  /// 而这个路由的输入按提示词的描述本身就是「手写，可能连笔、潦草、有涂改」，
  /// 提示词又把「有潦草或遮挡」对应的把握定在 0.6-0.8 —— 两处口径一撞，
  /// 0.6-0.8 那段恰好是**这个功能的主要使用场景**，等于整段作废。
  ///
  /// 所以拆成两个问题，与 `AnswerRecognition` 同一条形状：
  /// 「有没有结果」决定**能不能用**（见 [isUsable]），
  /// 「把握多大」决定**要不要提醒核对**（见 [needsReview]）。
  bool get isUsable => tasks.isNotEmpty;

  /// 这份清单值不值得让学生逐条核对一遍再保存。
  ///
  /// 为真时**照旧进核对表单**（表单上方就摆着原图，可放大对照，
  /// 每一条还能改科目），只是把顶部提示换成醒目的一版。
  /// **不要拿它当丢弃的判据** —— 那正是上面那条实测缺陷的成因。
  bool get needsReview => isUsable && confidence < kOcrConfidenceFloor;
}

/// 判断一条识别出的任务是否被标为「有认不准的字」。
///
/// 独立成一个函数而不是各页面自己读 map：这个字段名出现在三条链路上
/// （网关返回 → 界面提示 → 保存前的核对），写错任何一处都会**静默失效** ——
/// 界面不再提示，而识别结果照样落库。
///
/// **为什么需要这个标记**（2026-09-15 实测，本机 gemma4:26b）：
/// 手写体最典型的失败不是「认不出」—— 那种会走 `isUsable` 为假的分支，
/// 学生被明确告知了。真正的麻烦是**认成了一个读起来通顺的错词**：
/// 同一份作业清单从楷体换到潦草体，5 档里 4 档 6/6 全对，
/// 最潦草的那档把「静夜思」认成了「静在恩」，而**置信度仍报 0.9**
/// （门槛是 0.8）。转录读起来毫无异常，置信度也指不出来，
/// 学生扫一眼就过，最后照着一项假作业去做。
/// 唯一的线索就是模型自己说「这几个字我没把握」。
bool taskIsUncertain(Map<String, dynamic> task) => task['uncertain'] == true;
