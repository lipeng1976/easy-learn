import 'dart:typed_data';

import 'homework_text_parser.dart';

/// 把握低于它就要**醒目提示逐条核对**。
///
/// ⚠️ **它不是「丢弃线」**（2026-09-29 改口径）。原来低于它整份识别结果
/// 会被当作「没认出来」丢掉 —— 实测下来这是错的：真实的手抄清单照片上，
/// 模型四条科目全认对、结构违约 0 条，把握却稳定在 0.6~0.7，
/// 于是整份结果被丢，学生看到的却是「没能认出作业内容，建议重拍」。
///
/// 而这条线是**与提示词自己那张标尺对齐**的：提示词把「字迹工整清晰」
/// 定在 0.9 以上、「有潦草或遮挡」定在 0.6-0.8。手写清单本来就属于后者，
/// 所以真正该做的事是「让它进表单、提醒核对」，不是「判它没认出来」。
///
/// 「认错比认不出更坏」这条理由仍然成立 —— 但满足它的手段是**核对**
/// （表单上方摆着原图、每条都能改），不是**丢弃**。见
/// `HomeworkOcrResult.needsReview`。
const double kOcrConfidenceFloor = 0.8;

/// 一次识别为什么没成功。
///
/// 存在的理由是**「认不出」是个多义词**，而它对用户的含义完全不同：
/// - 照片糊了 → 他该重拍；
/// - 没登录 → 他该去登录，重拍一百次也没用；
/// - 网关拒了 / 连不上 → 是我们在排障，不是他的问题。
///
/// 只回一句「没能认出」会让三种情况长得一模一样，
/// 用户只能猜「是不是模型不行」—— 这个猜测通常是错的（见 2026-09-15 那次：
/// 真实原因是未登录、模型一次都没被调用）。
enum OcrFailureKind {
  /// 模型确实看过了，但没能从照片里读出可用的作业内容（照片/内容的问题）。
  notRecognized,

  /// 没接云端，或云端失败后回落到本地模拟 —— 本地实现不可能真的识别照片。
  offline,

  /// 未登录：请求**根本没发出去**。因为网关记账要真实学号，
  /// 拿占位符去问会被当作「没有身份」拒收，那是一次必然失败的往返。
  noIdentity,

  /// 网关明确拒收（参数契约、权限、配额）。
  rejected,

  /// 网关不可达或超时。
  unreachable,
}

/// OCR 识别数据源抽象接口。
///
/// 参考 [AuthDataSource] 的封装方式：客户端只依赖本接口，
/// 生产环境可通过依赖注入替换为真实后端 OCR API 实现，
/// 本地原型则使用 [SimulatedOcrDataSource]。
abstract class OcrDataSource {
  Future<OcrRecognitionResult> recognizeHomework({
    required String fileName,
    required Uint8List bytes,
  });
}

/// 一次 OCR 识别的纯结果（不含图片存储信息）。
class OcrRecognitionResult {
  final bool success;
  final String text;
  final String subject;
  final double confidence;
  final List<Map<String, dynamic>> tasks;

  /// 失败原因。[success] 为 true 时必须是 null（否则说明有人漏了赋值）。
  final OcrFailureKind? failure;

  /// 给人看的失败说明。用于「为什么没认出来」的提示，不参与任何判定。
  final String? failureNote;

  const OcrRecognitionResult({
    required this.success,
    required this.text,
    required this.subject,
    required this.confidence,
    required this.tasks,
    this.failure,
    this.failureNote,
  }) : assert(
         !success || failure == null,
         '成功的结果不该带失败原因，否则界面会一边说识别完成、一边说没认出来',
       );

  OcrRecognitionResult copyWith({
    bool? success,
    String? text,
    String? subject,
    double? confidence,
    List<Map<String, dynamic>>? tasks,
    OcrFailureKind? failure,
    String? failureNote,
  }) {
    return OcrRecognitionResult(
      success: success ?? this.success,
      text: text ?? this.text,
      subject: subject ?? this.subject,
      confidence: confidence ?? this.confidence,
      tasks: tasks ?? this.tasks,
      failure: failure ?? this.failure,
      failureNote: failureNote ?? this.failureNote,
    );
  }
}

/// 本地模拟 OCR 实现。
///
/// 一期没有真实 OCR：按**文件名里的关键词**给出对应的识别结果，
/// 让「拍照 → 识别 → 生成任务」这条链路能整条跑通。
///
/// 真实部署时替换为 HTTP 实现（见 `http_ocr_data_source.dart`）：把图片字节
/// 上传到后端，由**视觉模型**（豆包视觉 / Qwen-VL 这类）同时完成文字识别与
/// 题目结构抽取 —— 手写体识别加题目切分用一个模型做完，
/// 比先 OCR 再让文本模型切题更省也更准。
///
/// 逻辑直接内联在本类里：OCR 模拟本来就属于 OCR 数据源的职责，
/// 不必再绕一层只会加深耦合的中间服务。
class SimulatedOcrDataSource implements OcrDataSource {
  const SimulatedOcrDataSource();

  @override
  Future<OcrRecognitionResult> recognizeHomework({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final lowerName = fileName.toLowerCase();
    if (lowerName.contains('multi') ||
        lowerName.contains('综合') ||
        lowerName.contains('作业单')) {
      const text = '1.语文：背诵第二课；小作文《新学期新希望》\n2.数学：资料第8-9页；试卷一套\n3.英语：听写单词unit2';
      return OcrRecognitionResult(
        success: true,
        text: text,
        subject: '多科目',
        confidence: 0.93,
        tasks: HomeworkTextParser.parse(text),
      );
    }
    if (lowerName.contains('math') || lowerName.contains('数学')) {
      const text = '完成第1-20题：分数、小数四则运算';
      return OcrRecognitionResult(
        success: true,
        text: text,
        subject: '数学',
        confidence: 0.96,
        tasks: HomeworkTextParser.parse('数学：$text'),
      );
    }
    if (lowerName.contains('english') || lowerName.contains('英语')) {
      const text = '背诵并抄写 Unit 3 单词，完成课后练习';
      return OcrRecognitionResult(
        success: true,
        text: text,
        subject: '英语',
        confidence: 0.94,
        tasks: HomeworkTextParser.parse('英语：$text'),
      );
    }
    // 名字里没有任何线索 —— 离线的模拟实现对照片内容**确实一无所知**。
    //
    // 这里必须如实报「没认出来」，而不是编一条「待确认」的任务占位：
    // 编出来的那条会在学生手上变成一项真的作业，他得自己去发现它是假的。
    // 真实视觉模型接上之后，这条分支基本不会被走到。
    //
    // 标成 [OcrFailureKind.offline] 而不是 notRecognized：这一条的成因是
    // 「本地实现没有视觉能力」，不是「照片不好」。两者对用户的处置完全不同。
    // 若本类是被 [HttpOcrDataSource] 当作降级兜底调用的，外层会把原因
    // 覆盖成真实的那一个（未登录 / 被拒 / 连不上）。
    return const OcrRecognitionResult(
      success: false,
      text: '离线模式下只能按图片名做演示识别，这张照片认不出作业内容。',
      subject: '待确认',
      confidence: 0.3,
      tasks: [],
      failure: OcrFailureKind.offline,
      failureNote: '当前没有可用的云端识别（离线运行），本地实现按图片名演示识别。',
    );
  }
}
