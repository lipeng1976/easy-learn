import 'dart:convert';
import 'dart:typed_data';

import 'ai_api_client.dart';
import 'ai_config.dart';
import 'ai_data_source.dart';
import 'ai_image_transport.dart';
import 'homework_item_normalizer.dart';
import 'homework_text_parser.dart';
import 'ocr_data_source.dart';

/// 走网关的 OCR 实现：把图片交给**视觉模型**，同时完成文字识别与题目结构抽取。
///
/// 与 `SimulatedOcrDataSource` 的关键差别不只是「真的识别」：
/// 视觉模型能看到版式（哪几行属于同一道题、哪里是题号），
/// 而模拟实现只能按文件名猜、再靠正则切文本。
///
/// 但**切分仍保留纯规则兜底**：模型没给出 tasks 时回落到 [HomeworkTextParser]。
/// 这不是多余 —— 模型偶尔只肯回一段连续文本，此时如果直接把整段当一条任务，
/// 「语文：背书 数学：第8页」就会变成一条内容含两个科目的怪任务，
/// 后面按科目筛选、组卷全都要错。
/// （`HomeworkTextParser` 的注释里写的「解析不交给模型」，说的是**切分算法**
/// 要确定；把模型看到的版式信息用好，与这条原则并不冲突。）
class HttpOcrDataSource implements OcrDataSource {
  HttpOcrDataSource({
    required this.client,
    this.fallback = const SimulatedOcrDataSource(),
    this.onDegraded,
    this.retryBackoff = const Duration(milliseconds: 300),
  });

  final AiApiClient client;
  final OcrDataSource fallback;
  final AiDegradationListener? onDegraded;
  final Duration retryBackoff;

  @override
  Future<OcrRecognitionResult> recognizeHomework({
    required String fileName,
    required Uint8List bytes,
  }) async {
    if (!client.config.capabilities.vision) {
      return _degrade(
        '服务端未开通视觉模型，本次识别改用本地模拟',
        fileName: fileName,
        bytes: bytes,
        kind: OcrFailureKind.offline,
      );
    }

    final attempts = client.config.maxAttempts < 1
        ? 1
        : client.config.maxAttempts;
    AiRequestException? lastError;

    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        final data = await client.postJson(
          AiEndpoints.homeworkOcr,
          {
            'fileName': fileName,
            'images': [
              {
                // 按**真实字节**判断类型，不写死 jpeg。
                //
                // 写死的代价不是「多失败一次」，而是失败得**看不出来**：
                // 浏览器给的文件名不可靠（改名、截图工具无扩展名、聊天软件导出的随机名），
                // 于是「声明 jpeg、实为 png」会被发出去。本地网关只按声明值过白名单，
                // 侥幸能过；接方舟之后会被厂商侧按格式不符拒绝，
                // 那时报出来的错和「照片拍糊了」长得一样。
                'mimeType': imageMimeTypeOf(bytes, fileName: fileName),
                'byteSize': bytes.length,
                'base64': base64Encode(bytes),
              },
            ],
          },
          // 走配置里的上传超时，**不要在这里写死 30s**。
          //
          // 写死会把 `AI_UPLOAD_TIMEOUT_MS` 变成一句空话：
          // 本机部署时按说明把它调到 120s，带图批改生效了、拍照识别却仍在 30s 断线，
          // 而两条链路报出来的都是 `model_timeout`，看起来像「模型太慢」，
          // 实际是这里没读配置。
          timeout: client.config.uploadTimeout,
        );
        return _parse(data, fileName: fileName, bytes: bytes);
      } on AiRequestException catch (e) {
        lastError = e;
        if (!e.retryable) break;
      } on _OcrSchemaViolation catch (e) {
        lastError = AiRequestException(
          code: 'schema_violation',
          message: e.message,
          retryable: true,
        );
      }

      if (attempt < attempts && retryBackoff > Duration.zero) {
        await Future<void>.delayed(retryBackoff * attempt);
      }
    }

    return _degrade(
      // ⚠️ `userMessage` 而不是 `message`（2026-10-06）：这条 reason 会挪到
      // 界面上的降级说明，`message` 里可能是底层英文异常。
      lastError?.userMessage ?? '未知原因',
      fileName: fileName,
      bytes: bytes,
      code: lastError?.code ?? 'unknown',
      kind: _kindOf(lastError),
    );
  }

  OcrRecognitionResult _parse(
    Map<String, dynamic> data, {
    required String fileName,
    required Uint8List bytes,
  }) {
    final text = data['text'];
    if (text is! String || text.trim().isEmpty) {
      throw const _OcrSchemaViolation('text 不能为空');
    }
    final confidence = (data['confidence'] as num?)?.toDouble() ?? 0;
    if (confidence < 0 || confidence > 1) {
      throw const _OcrSchemaViolation('confidence 必须在 0-1 之间');
    }

    return OcrRecognitionResult(
      success: true,
      text: text,
      subject: (data['subject'] as String?)?.trim().isNotEmpty == true
          ? (data['subject'] as String).trim()
          : '待确认',
      confidence: confidence,
      tasks: _tasksOf(data, text),
    );
  }

  /// 优先用模型给出的版式切分，缺失时回落纯规则解析。
  List<Map<String, dynamic>> _tasksOf(Map<String, dynamic> data, String text) {
    final raw = data['tasks'];
    if (raw is List && raw.isNotEmpty) {
      final tasks = <Map<String, dynamic>>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final subject = item['subject'];
        final taskText = item['text'];
        if (subject is! String || taskText is! String) continue;
        if (taskText.trim().isEmpty) continue;
        final minutes = _plausibleMinutes(item['estimatedMinutes']);
        tasks.add({
          'subject': subject.trim().isEmpty
              ? HomeworkItemNormalizer.unknownSubject
              : subject.trim(),
          'text': taskText.trim(),
          // 模型自报「这一条里有认不准的字」。只有明确为 true 才带上 ——
          // 补一个 false 会让「模型没表态」和「模型说没问题」变得无法区分，
          // 而这两件事对核对的提示强度是不一样的。
          if (item['uncertain'] == true) 'uncertain': true,
          // 耗时建议在这一层把范围卡住，不给界面留校验活。
          //
          // 与科目同理：这里是从外部（网关）进来的唯一入口，
          // 而 schema 是服务端的事 —— 客户端不能假设它一定生效
          // （老网关、被改过参数的部署都会绕过）。放过了的话，
          // 一个 99999 会直接填进「预计耗时」输入框，界面上无从分辨
          // 它是模型算的还是坏数据。范围外的值**连字段都不带**：
          // clamp 过去会显得像模型真的这么估过。
          //
          // `?` 的语义正是「值为 null 就整个 entry 不带」。
          'estimatedMinutes': ?minutes,
        });
      }
      // 模型给了 tasks 但一条都没能通过校验 —— 同样是「没给出」，
      // 落到纯规则而不是返回空列表：空列表会让「拍照→生成任务」整条链断掉。
      if (tasks.isNotEmpty) return tasks;
    }
    return HomeworkTextParser.parse(text);
  }

  /// 模型给的耗时建议；范围不合理时返回 null（当作「没给」）。
  ///
  /// 5–120 这个范围与网关 schema 里写的是同一个，但**不是重复实现**：
  /// schema 约束的是模型，这里防的是「schema 没生效」那条路径。
  static int? _plausibleMinutes(Object? raw) {
    if (raw is! num) return null;
    final value = raw.round();
    return value >= 5 && value <= 120 ? value : null;
  }

  /// 把网关/传输层的错误码归成用户能理解的四类成因。
  ///
  /// 分类不是为了好看，是为了**给对处置建议**：
  /// 未登录该去登录，服务端拒了该找我们排障，连不上该等一等，
  /// 而「模型看了但认不出」才该建议重拍。四类的建议互不通用 ——
  /// 把它们合成一句「没能认出内容」，用户只能自己猜（通常猜成「模型不行」）。
  OcrFailureKind _kindOf(AiRequestException? error) {
    switch (error?.code) {
      case 'no_identity':
        return OcrFailureKind.noIdentity;
      case 'capability_disabled':
        return OcrFailureKind.offline;
      case 'timeout':
      case 'transport_error':
      case 'internal':
      case 'model_timeout':
      case 'model_unavailable':
      case 'model_output_invalid':
        return OcrFailureKind.unreachable;
      case 'schema_violation':
        // 模型跑过了，只是没给出可用的结构 —— 属于「它没能识读这张照片」，
        // 不是「服务用不了」。这两者的下一步动作完全不同。
        return OcrFailureKind.notRecognized;
      default:
        // bad_request / unauthorized / forbidden / quota_* / payload_too_large
        return OcrFailureKind.rejected;
    }
  }

  Future<OcrRecognitionResult> _degrade(
    String reason, {
    required String fileName,
    required Uint8List bytes,
    String code = 'capability_disabled',
    OcrFailureKind kind = OcrFailureKind.rejected,
  }) async {
    onDegraded?.call(
      AiDegradation(
        operation: 'recognizeHomework',
        code: code,
        reason: reason,
        at: DateTime.now(),
      ),
    );
    final fallbackResult = await fallback.recognizeHomework(
      fileName: fileName,
      bytes: bytes,
    );
    // 把真实成因**覆盖**到兜底结果上：兜底实现只知道「我没接模型」，
    // 它不知道这次到底是因为没登录、还是被网关拒了。
    // 不覆盖的话，用户看到的永远是「离线模式下只能按图片名识别」——
    // 而这句话会把人引向「那接上模型不就好了」的错误结论。
    return fallbackResult.copyWith(
      success: false,
      failure: kind,
      failureNote: reason,
    );
  }
}

class _OcrSchemaViolation implements Exception {
  const _OcrSchemaViolation(this.message);

  final String message;
}
