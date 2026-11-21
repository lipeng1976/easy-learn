import 'dart:async';
import 'dart:convert';

import '../models/checkin_models.dart';
import '../models/knowledge_tip.dart';
import '../models/mistake_figure.dart';
import '../models/practice_figure.dart';
import '../models/review_model.dart';
import '../utils/grading_sanity.dart';
import '../utils/practice_question_rules.dart';
import 'ai_api_client.dart';
import 'ai_config.dart';
import 'ai_data_source.dart';
import 'ai_image_transport.dart';
import 'checkin_question_parser.dart';
import 'simulated_ai_data_source.dart';

/// 走自建 Serverless 网关的 AI 实现。
///
/// 三层防御里的第 2、3 层落在本类：
///
/// 1. **厂商层**：服务端用 function calling 约束模型只能按 schema 输出（在网关侧）
/// 2. **服务端层**：网关做字段存在性、枚举、数值范围校验
/// 3. **客户端层**（本类）：再校一次业务约束 —— 网关可能换人写、可能版本不齐，
///    而这里校验失败不会造出错数据，只是多一次本地兜底
///
/// 校验失败不是直接降级，而是**带着错误信息重试一次**：
/// 「你给的 steps 是空数组」这句话回给模型，第二次基本能修好。
/// 直接降级会让模型的小失误变成学生看到的通用模板，白白浪费掉已有算力。
class RemoteAiDataSource implements AiDataSource {
  RemoteAiDataSource({
    required this.client,
    required this.imageUploader,
    AiConfig? config,
    this.fallback = const SimulatedAiDataSource(),
    this.onDegraded,
    this.retryBackoff = const Duration(milliseconds: 300),
  }) : _config = config ?? client.config;

  final AiApiClient client;

  AiConfig _config;

  /// 当前生效的配置。能力开关会被 [probeCapabilities] 修正，因此不是 final。
  AiConfig get config => _config;

  /// 用探测结果修正能力开关。
  void updateCapabilities(AiCapabilities capabilities) {
    _config = _config.withCapabilities(capabilities);
  }

  /// 作业照片的取用方式。见 [HomeworkImageUploader]。
  final HomeworkImageUploader imageUploader;

  /// 降级终点。默认就是那个本地实现 —— 它同时负责离线、故障、测试三种场景，
  /// 这里不需要再造一个「备用备用」。
  final AiDataSource fallback;

  final AiDegradationListener? onDegraded;

  /// 重试前的等待。测试传 [Duration.zero]，否则每个降级用例白等 300ms。
  final Duration retryBackoff;

  /// 最近一次降级。P3 会用它把「本次为离线参考结果」显示到界面上。
  AiDegradation? lastDegradation;

  // ===== 接口实现 =====

  @override
  Future<HomeworkCheckOutcome> checkHomework({
    required String subject,
    required String title,
    List<String> imagePaths = const [],
  }) async {
    // 没有照片就没有可批改的东西。
    //
    // 这条短路的必要性有两层：
    // - **成本**：发过去也是白花一次上行与一次模型调用；
    // - **正确性**：网关只能照科目名和标题硬编一份错题明细，而那些错题
    //   会进错题库、被组卷、被打印出来让学生重做。假错题比没有结果更糟。
    if (imagePaths.isEmpty) {
      return _degrade(
        operation: 'checkHomework',
        code: 'no_images',
        reason: '没有作业照片，云端批改无法进行',
        local: () => fallback.checkHomework(
          subject: subject,
          title: title,
          imagePaths: imagePaths,
        ),
      );
    }

    final prepared = await imageUploader.prepare(imagePaths);

    // 有照片但一张都没送上去 —— 这时候的「AI 批改」等于盲判。
    // 与其让网关硬着头皮出一份没有依据的结果，不如老实降级。
    if (imagePaths.isNotEmpty && prepared.isEmpty) {
      return _degrade(
        operation: 'checkHomework',
        code: 'images_unavailable',
        reason: prepared.note.isEmpty
            ? '作业照片无法送达云端（${imagePaths.length} 张）'
            : prepared.note,
        local: () => fallback.checkHomework(
          subject: subject,
          title: title,
          imagePaths: imagePaths,
        ),
      );
    }

    return _invoke(
      operation: 'checkHomework',
      path: AiEndpoints.homeworkCheck,
      body: {
        'subject': subject,
        'title': title,
        'images': prepared.images.map((image) => image.toJson()).toList(),
        if (prepared.skipped > 0) 'imagesSkipped': prepared.skipped,
      },
      // 批改要过视觉模型，比纯文本慢，单独放宽。
      timeout: const Duration(seconds: 30),
      // 只有真的带图时才受视觉开关约束：没有照片的批改不该被视觉能力拦下。
      capabilityEnabled: prepared.isEmpty || config.capabilities.vision,
      capabilityLabel: '视觉模型（手写识别 / 作业批改）',
      parse: _parseHomeworkCheck,
      validate: (outcome) {
        if (outcome.summary.trim().isEmpty) return 'summary 不能为空';
        // `items` 空却扣分 ⇒ 自相矛盾（口径见 GradingSanity.contradiction）。
        //
        // ⚠️ 这条**只对模型输出生效**，不碰本地兜底：`_invoke` 里的 validate
        // 只在解析云端响应之后被调用，走 `_degrade` 那条路（网络故障、能力未开通）
        // 不经过它。这样是刻意的 —— 本地实现是**模拟**，它的
        // 「无错题给 96-100」本来就不是按这条契约写的，而且它没有重试的机会。
        // 契约归契约，模拟归模拟，两者不要互相迁就。
        return GradingSanity.contradiction(outcome);
      },
      local: () => fallback.checkHomework(
        subject: subject,
        title: title,
        imagePaths: imagePaths,
      ),
    );
  }

  /// 拍照作答：把照片里手写的这一题解答转录成文字。
  ///
  /// ## 为什么超时按视觉档放宽（30s）
  ///
  /// 与批改同一条理由：视觉模型的响应里带着图像输入的处理时间，
  /// 而默认的 12s 窗口在真机上实测会被超（见 `AiConfig.requestTimeout`
  /// 与 `checkHomework` 的覆盖）。用默认值会让这条链路在真实照片上
  /// **稳定超时**，然后安静地降级成本地占位文案 —— 学生看到的是
  /// 「识别不了」，而真相是超时窗口给短了。
  ///
  /// ## 降级时不是「返回空串」
  ///
  /// 本地兜底会返回一段说明文字，`source` 是 local。调用方靠
  /// `AnswerRecognition.isUsable` 判断出「这不是真的识别结果」，
  /// 从而不会把它当作学生的作答。
  @override
  Future<AnswerRecognition> recognizeAnswer({
    required List<String> imagePaths,
    String questionContent = '',
    String knowledgePoint = '',
  }) async {
    Future<AnswerRecognition> local() => fallback.recognizeAnswer(
      imagePaths: imagePaths,
      questionContent: questionContent,
      knowledgePoint: knowledgePoint,
    );

    if (imagePaths.isEmpty) {
      return _degrade(
        operation: 'recognizeAnswer',
        code: 'no_images',
        reason: '没有照片，无法识别作答内容',
        local: local,
      );
    }

    final prepared = await imageUploader.prepare(imagePaths);
    if (prepared.isEmpty) {
      // 图没送上去时的「识别结果」只能是编的。与其让学生按一段
      // 凭空的文字去核对，不如如实说「这次没识别成」。
      return _degrade(
        operation: 'recognizeAnswer',
        code: 'images_unavailable',
        reason: prepared.note.isEmpty
            ? '照片无法送达云端（${imagePaths.length} 张）'
            : prepared.note,
        local: local,
      );
    }

    return _invoke(
      operation: 'recognizeAnswer',
      path: AiEndpoints.reviewAnswerOcr,
      body: {
        'images': prepared.images.map((image) => image.toJson()).toList(),
        if (questionContent.isNotEmpty) 'questionContent': questionContent,
        if (knowledgePoint.isNotEmpty) 'knowledgePoint': knowledgePoint,
        if (prepared.skipped > 0) 'imagesSkipped': prepared.skipped,
      },
      // 视觉档，与批改同一个窗口（见上面的注释）。
      timeout: const Duration(seconds: 30),
      capabilityEnabled: config.capabilities.vision,
      capabilityLabel: '视觉模型（手写识别 / 作业批改）',
      parse: _parseAnswerRecognition,
      local: local,
    );
  }

  @override
  Future<MistakeExtraction> extractMistakes({
    required List<String> imagePaths,
    String hint = '',
  }) async {
    Future<MistakeExtraction> local() => fallback.extractMistakes(
      imagePaths: imagePaths,
      hint: hint,
    );

    if (imagePaths.isEmpty) {
      return _degrade(
        operation: 'extractMistakes',
        code: 'no_images',
        reason: '没有照片，无法提取题目',
        local: local,
      );
    }

    final prepared = await imageUploader.prepare(imagePaths);
    if (prepared.isEmpty) {
      // 一张都没送上去时，「提取结果」只能是编的。宁可让学生手填，
      // 也不要凭空造一道题让他确认 —— 那道题会被存进错题库。
      return _degrade(
        operation: 'extractMistakes',
        code: 'images_unavailable',
        reason: prepared.note.isEmpty
            ? '照片无法送达云端（${imagePaths.length} 张）'
            : prepared.note,
        local: local,
      );
    }

    return _invoke(
      operation: 'extractMistakes',
      path: AiEndpoints.reviewExtractMistakes,
      body: {
        'images': prepared.images.map((image) => image.toJson()).toList(),
        if (hint.isNotEmpty) 'hint': hint,
        // 部分照片没送达时**必须告诉模型**：否则它会对着半张卷子
        // 说「题目都在这里了」，而缺失的那部分是学生以为录进去了的。
        if (prepared.skipped > 0) 'imagesSkipped': prepared.skipped,
      },
      // 视觉档，与批改同一个窗口。用默认 12s 会让这条链路在真实照片上
      // 稳定超时，然后安静地降级成「识别不了」。
      timeout: const Duration(seconds: 30),
      capabilityEnabled: config.capabilities.vision,
      capabilityLabel: '视觉模型（题目识别）',
      parse: _parseExtraction,
      local: local,
    );
  }

  @override
  Future<AnswerJudgement> judgeAnswer({
    required String studentAnswer,
    required String referenceAnswer,
    String subject = '',
    String knowledgePoint = '',
    String questionContent = '',
  }) async {
    return _invoke(
      operation: 'judgeAnswer',
      path: AiEndpoints.reviewJudge,
      body: {
        'studentAnswer': studentAnswer,
        'referenceAnswer': referenceAnswer,
        'subject': subject,
        'knowledgePoint': knowledgePoint,
        'questionContent': questionContent,
      },
      // 判定单独一条窗口（默认 20s），不跟着 requestTimeout 走 ——
      // 它走强推理档、而且**是全链路唯一开着思维链的路由**，
      // 默认那 12s 会静默降级成本地结论。推导过程见 `AiConfig.judgeTimeout`。
      timeout: config.judgeTimeout,
      parse: _parseJudgement,
      capabilityEnabled: config.capabilities.reasoning,
      capabilityLabel: '强推理模型（单题判定）',
      local: () => fallback.judgeAnswer(
        studentAnswer: studentAnswer,
        referenceAnswer: referenceAnswer,
        subject: subject,
        knowledgePoint: knowledgePoint,
        questionContent: questionContent,
      ),
    );
  }

  @override
  Future<MistakeExplanation> explainMistake({
    required String subject,
    required String knowledgePoint,
    required String title,
    required String wrongReason,
    String questionBody = '',
    List<AiSourceImage> images = const [],
    String referenceAnswer = '',
    String studentProcess = '',
  }) async {
    // 有图就走视觉档：图形题的讲解必须看得见那个图，否则只能给通用套路。
    // 与举一反三共用同一套体积预算（见 `_encodeSourceImages`）。
    final payload = _encodeSourceImages(images, keyPrefix: 'explain-source');
    return _invoke(
      operation: 'explainMistake',
      path: AiEndpoints.reviewExplain,
      body: {
        'subject': subject,
        'knowledgePoint': knowledgePoint,
        'title': title,
        'wrongReason': wrongReason,
        // 空串不传：网关拿不到这个键时会把 `title` 当题目用（历史错题的
        // 唯一出路）。传一个空串反而会让提示词里出现「题目原文：」，
        // 模型对着一个空标题讲题。
        if (questionBody.trim().isNotEmpty) 'questionBody': questionBody,
        if (referenceAnswer.trim().isNotEmpty) 'referenceAnswer': referenceAnswer,
        if (studentProcess.trim().isNotEmpty) 'studentProcess': studentProcess,
        if (payload.isNotEmpty) 'images': payload,
      },
      // 视觉档要读一张照片再推理，12s 的默认值不够（实测讲解约 9s）。
      timeout: payload.isNotEmpty ? const Duration(seconds: 30) : null,
      parse: _parseExplanation,
      capabilityEnabled:
          payload.isNotEmpty ? config.capabilities.vision : config.capabilities.reasoning,
      capabilityLabel: payload.isNotEmpty
          ? '视觉模型（错题讲解 · 读原题照片）'
          : '强推理模型（错题讲解）',
      validate: (explanation) {
        // 没有步骤的讲解是空的。模型偶尔会只给一段感慨 ——
        // 那对学生毫无用处，但对「看 JSON 有没有字段」的校验来说却是合法的。
        if (explanation.steps.isEmpty) return 'steps 不能为空，至少要给出解法的分步';
        return null;
      },
      local: () => fallback.explainMistake(
        subject: subject,
        knowledgePoint: knowledgePoint,
        title: title,
        wrongReason: wrongReason,
        questionBody: questionBody,
      ),
    );
  }

  @override
  Future<MistakeFigure> generateFigure({
    required String subject,
    required String knowledgePoint,
    String title = '',
    String questionBody = '',
    String wrongReason = '',
    String referenceAnswer = '',
    String studentProcess = '',
    List<AiSourceImage> images = const [],
  }) async {
    final payload = _encodeSourceImages(images, keyPrefix: 'figure-source');
    return _invoke(
      operation: 'generateFigure',
      path: AiEndpoints.reviewFigure,
      body: {
        'subject': subject,
        'knowledgePoint': knowledgePoint,
        if (title.trim().isNotEmpty) 'title': title,
        if (questionBody.trim().isNotEmpty) 'questionBody': questionBody,
        if (wrongReason.trim().isNotEmpty) 'wrongReason': wrongReason,
        if (referenceAnswer.trim().isNotEmpty) 'referenceAnswer': referenceAnswer,
        if (studentProcess.trim().isNotEmpty) 'studentProcess': studentProcess,
        if (payload.isNotEmpty) 'images': payload,
      },
      // ⚠️ 这条比别的路由都慢，因为它是**先判断再画**的两段思考：
      // 实测纯文本档 9~14s，而默认窗口只有 12s —— 会在最后一刻把它掐掉。
      // 被掐掉之后学生看到的是「这次没画成」，没有人会想到是超时，
      // 而重试一次又是十几秒。宁可把窗口放宽，也不要让它静默地慢失败。
      timeout: payload.isNotEmpty
          ? const Duration(seconds: 40)
          : const Duration(seconds: 30),
      parse: _parseFigure,
      capabilityEnabled: payload.isNotEmpty
          ? config.capabilities.vision
          : config.capabilities.reasoning,
      capabilityLabel: payload.isNotEmpty
          ? '视觉模型（讲解配图 · 读原题照片）'
          : '强推理模型（讲解配图）',
      // 离线不编一张假图：图上任何一个画错的长度都会让学生推理出错误结论。
      local: () async => const MistakeFigure(
        reason: '离线时不画图，先看上面的文字讲解。',
      ),
    );
  }

  /// 把原题照片编成网关要的 base64 载荷。
  ///
  /// 网关的上限是 4 张 / 3MB（`AI_MAX_IMAGES` / `AI_MAX_IMAGE_BYTES`），
  /// 超了整条请求会被 413 挡下 —— 那不是「多传一张」的问题，
  /// 是「这道题根本处理不了」。所以这里按**更保守**的 2 张 / 2.5MB 截断：
  /// 一道题拍到两三张已经是极限，再多对出题和讲解都没有帮助，只是白花钱。
  ///
  /// 两处调用（举一反三、错题讲解）**必须共用这一份预算**：
  /// 各写一套的话，改上限时只会改到一处，另一处继续被 413 挡下，
  /// 而现象是「有的功能能传图、有的不能」—— 看起来像两个不同的 bug。
  static List<Map<String, dynamic>> _encodeSourceImages(
    List<AiSourceImage> images, {
    required String keyPrefix,
  }) {
    const maxImages = 2;
    const maxTotalBytes = 2500 * 1024;

    final payload = <Map<String, dynamic>>[];
    var bytesUsed = 0;
    for (final image in images) {
      if (payload.length >= maxImages) break;
      if (image.bytes.isEmpty) continue;
      final next = bytesUsed + image.bytes.length;
      if (next > maxTotalBytes) break;
      bytesUsed = next;
      payload.add(
        CloudHomeworkImage(
          // 这些照片没有「上传到云端存储」这一步，storageKey 只是排查用的
          // 标记；留空会让 toJson 少一个字段，所以给一个能对上的名字。
          storageKey: '$keyPrefix-${payload.length}',
          mimeType: image.mimeType,
          byteSize: image.bytes.length,
          base64: base64Encode(image.bytes),
        ).toJson(),
      );
    }
    return payload;
  }

  @override
  Future<List<GeneratedQuestion>> generatePractice({
    required String subject,
    required String knowledgePoint,
    String difficulty = '基础',
    int round = 1,
    int count = 3,
    List<AiSourceImage> images = const [],
  }) async {
    final payload = _encodeSourceImages(images, keyPrefix: 'practice-source');

    return _invoke(
      operation: 'generatePractice',
      path: AiEndpoints.reviewPractice,
      body: {
        'subject': subject,
        'knowledgePoint': knowledgePoint,
        'difficulty': difficulty,
        'round': round,
        'count': count,
        if (payload.isNotEmpty) 'images': payload,
      },
      timeout: const Duration(seconds: 30),
      parse: (data) {
        final questions = <GeneratedQuestion>[];
        for (final raw in _requireList(data, 'questions')) {
          final question = _parseGeneratedQuestion(raw);
          // 不合格的那一道丢掉，不让它去污染学生的练习 —— 但也**不静默**：
          // `_parseGeneratedQuestion` 里已经为每条丢掉的题留了降级记录。
          if (question != null) questions.add(question);
        }
        // 多给的题截掉：学生做超额的题不会更巩固，只会更烦。
        return questions.length > count ? questions.sublist(0, count) : questions;
      },
      validate: (questions) {
        if (questions.isEmpty) return 'questions 不能为空';
        return null;
      },
      // 带图时走视觉档（网关据此换模型），不带图仍走推理档。
      // 这个开关必须跟着**实际有没有图**走：没有照片的错题不该被
      // 「视觉能力未开通」拦下 —— 它根本不需要看图。
      capabilityEnabled:
          payload.isNotEmpty ? config.capabilities.vision : config.capabilities.reasoning,
      capabilityLabel:
          payload.isNotEmpty ? '视觉模型（举一反三 · 读原题照片）' : '强推理模型（举一反三）',
      local: () => fallback.generatePractice(
        subject: subject,
        knowledgePoint: knowledgePoint,
        difficulty: difficulty,
        round: round,
        count: count,
      ),
    );
  }

  @override
  Future<List<CheckinQuestion>> generateCheckinQuestions({
    required String subject,
    required List<CheckinSeed> items,
    int count = 5,
  }) {
    if (items.isEmpty) {
      // 没有知识点就没有出题的锚点。回空列表会让界面显示「今天没有题」，
      // 而那其实是一次调用错误 —— 学生/家长会以为今天不用做。
      throw ArgumentError('items 不能为空：打卡题必须围绕知识点出');
    }

    return _invoke(
      operation: 'generateCheckinQuestions',
      path: AiEndpoints.checkinGenerate,
      body: {
        'subject': subject,
        'count': count,
        'items': [
          for (final item in items)
            {
              'knowledge': item.knowledge,
              if (item.wrongCount > 0) 'wrongCount': item.wrongCount,
              if (item.wrongReason.trim().isNotEmpty) 'wrongReason': item.wrongReason,
            },
        ],
      },
      timeout: const Duration(seconds: 30),
      parse: (data) {
        // 复用客户端那份 5 重守卫（剥围栏 / 严格 JSON / 答案 ∈ 选项 /
        // 题型推断 / LaTeX 修复），而不是在这里另写一份「结构差不多」的解析。
        // 两份校验迟早会漂，而漂的那一刻表现是「网关说合格、客户端说没题」。
        final parsed = CheckinQuestionParser.parse(jsonEncode(data));
        return parsed.questions;
      },
      validate: (questions) => questions.isEmpty ? 'questions 不能为空' : null,
      capabilityEnabled: config.capabilities.reasoning,
      capabilityLabel: '强推理模型（每日概念打卡）',
      local: () => fallback.generateCheckinQuestions(
        subject: subject,
        items: items,
        count: count,
      ),
    );
  }

  @override
  Future<List<MistakeTipDraft>> summarizeMistakeTips({
    required String subject,
    required List<MistakeTipSeed> items,
  }) async {
    final seeds = items
        .where((seed) => seed.knowledgePoint.trim().isNotEmpty)
        .toList();
    if (seeds.isEmpty) return const <MistakeTipDraft>[];
    final known = <String>{for (final seed in seeds) seed.knowledgePoint};

    return _invoke(
      operation: 'summarizeMistakeTips',
      path: AiEndpoints.reviewTips,
      body: {
        'subject': subject,
        'items': [
          for (final seed in seeds)
            {
              'knowledgePoint': seed.knowledgePoint,
              'wrongCount': seed.wrongCount,
              if (seed.wrongReason.trim().isNotEmpty)
                'wrongReason': seed.wrongReason,
            },
        ],
      },
      timeout: const Duration(seconds: 30),
      parse: (data) {
        final drafts = <MistakeTipDraft>[];
        final seen = <String>{};
        var rejected = 0;
        for (final raw in _requireList(data, 'tips')) {
          if (raw is! Map) throw const _SchemaViolation('tips 的元素应为对象');
          final item = Map<String, dynamic>.from(raw);
          final point = _requireNonEmptyString(item, 'knowledgePoint').trim();
          final text = _requireNonEmptyString(item, 'text').trim();
          // 模型自己造了一个知识点名 → 这条提示挂不回任何一道错题。
          // 丢掉它，但**不能整批作废**：其余几条仍然是可用的。
          if (!known.contains(point)) {
            rejected += 1;
            continue;
          }
          if (!seen.add(point)) continue;
          drafts.add(MistakeTipDraft(knowledgePoint: point, text: text));
        }
        // 一条都没剩下，说明这一批全挂不回去 —— 那就不该当成成功。
        // 交回给重试机制，让它带着原因再要一次。
        if (drafts.isEmpty && rejected > 0) {
          throw _SchemaViolation(
            'knowledgePoint 必须是请求里给出的知识点之一（有 $rejected 条不符合）',
          );
        }
        return drafts.length > 6
            ? drafts.sublist(0, 6)
            : drafts;
      },
      validate: (drafts) => drafts.isEmpty ? 'tips 不能为空' : null,
      capabilityEnabled: config.capabilities.reasoning,
      capabilityLabel: '强推理模型（知识点提示）',
      local: () =>
          fallback.summarizeMistakeTips(subject: subject, items: seeds),
    );
  }

  @override
  Future<String> referenceAnswerFor({
    required String subject,
    required String knowledgePoint,
  }) async {
    return _invoke(
      operation: 'referenceAnswerFor',
      path: AiEndpoints.reviewPractice,
      // 参考答案与讲解、出题共用一份「知识点画像」，
      // 单独为它发一次请求不划算 —— 组卷时一页 20 道题就是 20 次调用。
      body: {
        'subject': subject,
        'knowledgePoint': knowledgePoint,
        'want': 'referenceAnswer',
        'count': 0,
      },
      parse: (data) => _requireString(data, 'referenceAnswer'),
      validate: (answer) =>
          answer.trim().isEmpty ? 'referenceAnswer 不能为空' : null,
      // 参考答案按强推理档走，而不是轻量档。它看着像「查个答案」的小任务，
      // 但它的产物直接参与判卷 —— 编错一个答案，就会把做对的学生判成错的，
      // 而这个坑在本地实现里已经踩过一次（见 SimulatedAiDataSource 的剥括号注释）。
      capabilityEnabled: config.capabilities.reasoning,
      capabilityLabel: '强推理模型（参考答案）',
      local: () => fallback.referenceAnswerFor(
        subject: subject,
        knowledgePoint: knowledgePoint,
      ),
    );
  }

  @override
  Future<Map<String, String>> referenceAnswersFor(
    List<ReferenceQuery> queries,
  ) async {
    if (queries.isEmpty) return const <String, String>{};

    // 先去重再发请求。一页卷子里同知识点的题很常见，重复条目既多付一遍
    // 输出 token，也会让模型在答案里出现两条指代不明的重复项。
    final unique = <String, ReferenceQuery>{};
    for (final query in queries) {
      unique.putIfAbsent(query.key, () => query);
    }
    final ordered = unique.values.toList();

    // 只有一条时走单条接口：批量端点的固定开销（组装清单、按 index 回包）
    // 在 n=1 时纯属浪费。
    if (ordered.length == 1) {
      final single = await referenceAnswerFor(
        subject: ordered.first.subject,
        knowledgePoint: ordered.first.knowledgePoint,
      );
      return {ordered.first.key: single};
    }

    final resolved = await _invoke<Map<String, String>>(
      operation: 'referenceAnswersFor',
      path: AiEndpoints.reviewReferenceBatch,
      body: {
        'items': [
          for (final query in ordered)
            {
              'subject': query.subject,
              'knowledgePoint': query.knowledgePoint,
              if (query.questionTitle.isNotEmpty)
                'questionTitle': query.questionTitle,
            },
        ],
      },
      // 一页 20 道题比单题生成慢，放宽超时；但不能不设上限 ——
      // 组卷是学生点一下就要出纸的动作，卡住比降级更糟。
      timeout: const Duration(seconds: 30),
      parse: (data) => _parseReferenceBatch(data, ordered),
      validate: (answers) {
        if (answers.isEmpty) return 'answers 不能为空';
        return null;
      },
      capabilityEnabled: config.capabilities.reasoning,
      capabilityLabel: '强推理模型（参考答案）',
      local: () => _localReferenceAnswers(ordered),
    );

    // 模型漏了条目时**只补缺的那几条**，不整批重来。
    //
    // 网关侧刻意不替模型补空（见 test/gateway.test.js 的同名用例），
    // 于是回填的责任落在客户端：缺的用本地兜底补上，并如实报一次降级。
    // 一份印出去的卷子不允许某道题没有参考答案 —— 学生做完没法对错。
    final missing = ordered
        .where((query) => !resolved.containsKey(query.key))
        .toList();
    if (missing.isEmpty) return resolved;

    final filled = Map<String, String>.from(resolved);
    for (final query in missing) {
      filled[query.key] = await fallback.referenceAnswerFor(
        subject: query.subject,
        knowledgePoint: query.knowledgePoint,
      );
    }
    _report(
      operation: 'referenceAnswersFor',
      code: 'partial_reference',
      reason:
          '模型只给出 ${resolved.length}/${ordered.length} 条参考答案，'
          '其余 ${missing.length} 条改用本地兜底（涉及知识点：'
          '${missing.map((query) => query.knowledgePoint).join('、')}）',
    );
    return filled;
  }

  /// 本地兜底版的批量取答案（逐条）。
  Future<Map<String, String>> _localReferenceAnswers(
    List<ReferenceQuery> queries,
  ) async {
    final answers = <String, String>{};
    for (final query in queries) {
      answers[query.key] = await fallback.referenceAnswerFor(
        subject: query.subject,
        knowledgePoint: query.knowledgePoint,
      );
    }
    return answers;
  }

  // ===== 能力探测 =====

  /// 问网关哪些能力真的开着，**并把结果直接应用到后续调用上**。
  ///
  /// 方舟的视觉与强推理模型**通常要分别开通**，部分还需单独申请。
  /// 客户端不探测的后果很具体：把 3MB 照片发上去，等一个必然失败的响应，
  /// 再走一遍降级 —— 用户白等十几秒，流量白花。
  ///
  /// 探测结果在这里就落地，而不是只返回给调用方去处理：
  /// 一个「查了但不生效」的探测方法，接线时漏掉一步就会静默退化成
  /// 「每次都白发一次请求」，而且完全没有报错。
  ///
  /// 失败不是一个错误，只是「维持现状」：返回 null，保留原配置。
  Future<AiCapabilities?> refreshCapabilities() async {
    try {
      final data = await client.health();
      final capabilities = AiCapabilities.fromJson(data);
      updateCapabilities(capabilities);
      return capabilities;
    } catch (_) {
      return null;
    }
  }

  // ===== 调用骨架 =====

  /// 一次带重试与降级的调用。
  ///
  /// 重试的判定依据来自两处：网关给的 `retryable`（模型 5xx、限流可重试；
  /// 「模型未开通」不可重试），以及本地校验发现的问题（带上问题重试，
  /// 相当于给模型一次纠错机会）。
  Future<T> _invoke<T>({
    required String operation,
    required String path,
    required Map<String, dynamic> body,
    required T Function(Map<String, dynamic> data) parse,
    required Future<T> Function() local,
    String? Function(T value)? validate,
    Duration? timeout,
    bool capabilityEnabled = true,
    String capabilityLabel = '',
  }) async {
    // 能力未开通就直接降级，不发这一次注定失败的请求。
    //
    // 代价不是零：一次批改要先把 3MB 照片传上去、等网关报错、再走降级，
    // 用户白等十几秒，上行流量白花。而网关侧的错误码本来就是确定的
    // （`model_not_enabled`），没有任何「也许这次能成」的空间。
    if (!capabilityEnabled) {
      return _degrade(
        operation: operation,
        code: 'capability_disabled',
        reason: '服务端未开通$capabilityLabel，本次改用本地实现',
        local: local,
      );
    }

    final attempts = config.maxAttempts < 1 ? 1 : config.maxAttempts;
    AiRequestException? lastError;
    String? retryHint;

    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        final payload = <String, dynamic>{...body};
        // 把上一次校验失败的原因交回服务端，由它拼进提示词。
        // 这是「重试」与「盲重试」的区别所在。
        if (retryHint != null) payload['retryHint'] = retryHint;

        final data = await client.postJson(path, payload, timeout: timeout);
        final parsed = parse(data);
        final problem = validate?.call(parsed);
        if (problem == null) return parsed;

        retryHint = problem;
        lastError = AiRequestException(
          code: 'schema_violation',
          message: '响应不符合契约：$problem',
          retryable: true,
        );
      } on _SchemaViolation catch (e) {
        retryHint = e.message;
        lastError = AiRequestException(
          code: 'schema_violation',
          message: e.message,
          retryable: true,
        );
      } on AiRequestException catch (e) {
        lastError = e;
        // 网关自己校验失败（模型给了东西、但不合约定）**是能纠正的**：
        // 它把「哪一项不合格」写进了 message（`questions[0].content 不能为空`），
        // 把这句话交回去，第二次才是带着答案的纠错。
        //
        // 2026-10-23 实测：举一反三偶发 502，模型把两道题的 `content` 都留空。
        // 不带提示的第二次大概率原样再空一遍；带上这句话一次就过（kept=2）。
        // 这条分支以前只 `lastError = e` 就走 —— 典型「机制存在 ≠ 被使用」。
        if (e.code == 'schema_violation' && e.message.trim().isNotEmpty) {
          retryHint = e.message;
        }
        // 不可重试的错误（模型未开通、请求格式错误、鉴权失败）立刻停手：
        // 重试既不会成功，又会产生费用。
        if (!e.retryable) break;
      }

      if (attempt < attempts && retryBackoff > Duration.zero) {
        await Future<void>.delayed(retryBackoff * attempt);
      }
    }

    return _degrade(
      operation: operation,
      code: lastError?.code ?? 'unknown',
      // ⚠️ `userMessage` 而不是 `message`（2026-10-06）：这条 reason 会进
      // `AiDegradedBanner` 与 AI 观察页 —— 那是**界面**，而 `message` 里
      // 可能是底层英文异常（`ClientException: …`）。
      reason: lastError?.userMessage ?? '未知原因',
      local: local,
    );
  }

  /// 记录降级并返回本地结果。
  Future<T> _degrade<T>({
    required String operation,
    required String code,
    required String reason,
    required Future<T> Function() local,
  }) async {
    _report(operation: operation, code: code, reason: reason);
    return local();
  }

  /// 只记录，不产生本地结果。
  ///
  /// 与 [_degrade] 分开是因为有一种情况只完成了「一部分」：
  /// 批量取答案时模型漏了几条，那几条要补，但已经拿到的模型结果不该被丢掉。
  void _report({
    required String operation,
    required String code,
    required String reason,
  }) {
    final event = AiDegradation(
      operation: operation,
      code: code,
      reason: reason,
      at: DateTime.now(),
    );
    lastDegradation = event;
    onDegraded?.call(event);
  }

  // ===== 响应解析与校验 =====
  //
  // 全部走显式取值而不是 `as` 强转：`as` 失败抛的是 TypeError，
  // 堆栈指不到「哪个字段」，排查线上问题时要花十倍时间。

  HomeworkCheckOutcome _parseHomeworkCheck(Map<String, dynamic> data) {
    final score = _requireInt(data, 'score');
    if (score < 0 || score > 100) {
      throw const _SchemaViolation('score 必须在 0-100 之间');
    }
    final items = <HomeworkCheckItem>[];
    for (final raw in _requireList(data, 'items')) {
      if (raw is! Map) throw const _SchemaViolation('items 的元素必须是对象');
      final map = raw.cast<String, dynamic>();
      final question = _optionalString(map, 'question').trim();
      if (question.isEmpty) {
        // 题干缺失不该让整份批改作废（同一次里另外几条可能是真错题），
        // 但也不能悄悄留空：空题干会让这道错的讲解退化回「对着知识点讲」，
        // 而界面上看不出任何异常。留一条能读到的痕迹，别静默。
        _report(
          operation: 'checkHomework',
          code: 'question_missing',
          reason:
              '第 ${items.length + 1} 条错题没有题干'
              '（knowledgePoint=${_optionalString(map, 'knowledgePoint')}），'
              '已按知识点回退展示，讲解会变笼统',
        );
      }
      items.add(
        HomeworkCheckItem(
          question: question,
          knowledgePoint: _requireNonEmptyString(map, 'knowledgePoint'),
          originalAnswer: _requireString(map, 'originalAnswer'),
          wrongReason: _requireString(map, 'wrongReason'),
          // 可选字段：契约里没设成必填（很多作业本来就没有题号），
          // 缺了就留空，**不能因为缺它判整条不合格**。
          questionNo: _optionalString(map, 'questionNo'),
          studentProcess: _optionalString(map, 'studentProcess'),
          standardAnswer: _optionalString(map, 'standardAnswer'),
        ),
      );
    }
    // 规范问题与错题分开收。
    //
    // **字段缺席是正常的** —— 没有这类问题时模型会省略它（契约里刻意没
    // 把它设成必填），所以这里不能像 items 那样要求它存在。
    final formatIssues = <HomeworkFormatIssue>[];
    final rawFormatIssues = data['formatIssues'];
    if (rawFormatIssues is List) {
      for (final raw in rawFormatIssues) {
        // 单条不合格就跳过那一条，不让整批作废。
        //
        // 与判定里「未知 verdict 直接硬失败」不同：那里错的是**结论**
        // （会把对的学生判成错的），这里只是少了一条提醒 ——
        // 为一条格式不对的提醒退掉整份批改结果，代价完全不成比例。
        if (raw is! Map) continue;
        final map = raw.cast<String, dynamic>();
        final detail = _requireString(map, 'detail');
        if (detail.trim().isEmpty) continue;
        formatIssues.add(
          HomeworkFormatIssue(
            knowledgePoint: _requireString(map, 'knowledgePoint'),
            detail: detail,
          ),
        );
      }
    } else if (rawFormatIssues != null) {
      // 传了、但不是数组。多数是厂商把嵌套数组序列化成了字符串
      // （百炼有这毛病，网关有一层修补兜着）。这里必须留一条**能被读到**的
      // 痕迹，而不是打个日志了事 —— 静默丢掉的话，界面上看起来
      // 就只是「这孩子书写没问题」。
      _report(
        operation: 'checkHomework',
        code: 'format_issues_dropped',
        reason:
            'formatIssues 不是数组而是 ${rawFormatIssues.runtimeType}，'
            '这批书写规范提示已丢弃（其余批改结果照常使用）',
      );
    }

    return HomeworkCheckOutcome(
      score: score,
      summary: _requireNonEmptyString(data, 'summary'),
      items: items,
      formatIssues: formatIssues,
      // 走到这里说明模型确实出了结果。降级路径不会经过本方法 ——
      // 它直接返回 fallback 的产物，那份的来源是 local。
      source: AiAnswerSource.cloud,
    );
  }

  /// 装配批量参考答案。
  ///
  /// 按 index 对齐而不是按数组顺序 —— 契约里写死 index 的理由就在这：
  /// 模型不保证顺序也不保证长度，按位置对应的话，一次错位就会让
  /// 「第 3 题的答案」出现在「第 5 题」上，而且不会报任何错。
  Map<String, String> _parseReferenceBatch(
    Map<String, dynamic> data,
    List<ReferenceQuery> ordered,
  ) {
    final answers = <String, String>{};
    for (final raw in _requireList(data, 'answers')) {
      // 单条不合格就跳过那一条，而不是让整批作废。
      //
      // 与判定里的「未知 verdict 直接硬失败」不同：那里错的是**数据本身**
      // （把对的判成错的），这里只是**少了一条**，少的那条会被回填接住。
      // 为一条格式不对的答案退掉另外 19 条，是拿 19 道题的参考答案去陪葬。
      if (raw is! Map) continue;
      final map = raw.cast<String, dynamic>();
      final index = map['index'];
      if (index is! num) continue;
      final slot = index.toInt();
      if (slot < 0 || slot >= ordered.length) continue;
      final answer = map['referenceAnswer'];
      if (answer is! String || answer.trim().isEmpty) continue;
      answers[ordered[slot].key] = answer.trim();
    }
    return answers;
  }

  AnswerRecognition _parseAnswerRecognition(Map<String, dynamic> data) {
    final confidence = _requireNum(data, 'confidence');
    return AnswerRecognition(
      // 刻意用 `_requireString` 而不是 `_requireNonEmptyString`：
      // 网关的契约要求 text 非空，但「学生那张照片上确实什么都没写」
      // 是一个**合法的业务状态**，不是契约违约。硬失败会让这种情况
      // 走进降级、拿到一句「当前无法识别手写」—— 把「你没写字」
      // 说成「系统认不出」，学生会一直重拍。
      text: _requireString(data, 'text'),
      // 越界的值夹回 [0,1]。模型偶尔会给 95 这种「置信度百分比」，
      // 而下游拿它跟 0.8 比 —— 一次夹取好过让整个阈值判定失效。
      // ⚠️ 必须显式 `.toDouble()`：`_requireNum` 返回 `num`，而 Dart 对
      // `clamp` 的特殊静态类型规则只在全 int / 全 double 时收窄返回类型，
      // receiver 是 num 时返回 `num` —— 不加这个，赋给 double 字段直接
      // 编译不过（这段代码一直没跑过 analyze，所以是第一次被发现）。
      confidence: confidence.clamp(0.0, 1.0).toDouble(),
      // `uncertain` 在网关契约里是**可选**字段（schema 只 required
      // `text` + `confidence`）—— 模型对转录有把握时就是不给。
      // 2026-09-25 真模型冒烟（`probe-route --route=answerOcr`）两次
      // 独立调用**都没返回**这个字段；这里若按必填解析，每一次
      // 成功的识别都会在客户端被判成 schema violation、整单降级成
      // 本地占位文案 —— 云端明明答对了，学生看到的却是「识别不了」。
      // 所以必须容忍缺席，缺席即「模型没有要提示的存疑点」。
      uncertain: data['uncertain'] is String ? data['uncertain'] as String : '',
      source: AiAnswerSource.cloud,
    );
  }

  /// 解析一次错题提取。
  ///
  /// ## 为什么逐条容错，而不是一条坏就整单降级
  ///
  /// 拍一整页时返回 8 条，其中 1 条格式坏掉，整单判违约意味着**另外 7 条
  /// 好题也一起没了** —— 学生看到的还是「识别不了」，重拍一次大概率还是
  /// 同样的结果（坏的是模型这次输出的措辞，不是照片）。
  ///
  /// 但跳过不能是静默的：丢掉几条要写进整体 `uncertain`，否则
  /// 学生以为照片里就这么多题。**「少了几条」和「本来就没有」看起来一样**，
  /// 这正是这套系统里最难查的那类问题。
  MistakeExtraction _parseExtraction(Map<String, dynamic> data) {
    final raw = data['questions'];
    if (raw is! List) {
      throw _SchemaViolation('questions 应为数组');
    }

    final candidates = <ExtractedMistake>[];
    var broken = 0;
    for (final item in raw) {
      if (item is! Map) {
        broken++;
        continue;
      }
      final map = Map<String, dynamic>.from(item);
      final body = map['questionBody'];
      // 没有题干就没有要落库的东西 —— 这条留着也没用。
      if (body is! String || body.trim().isEmpty) {
        broken++;
        continue;
      }
      final confidence = map['confidence'];
      candidates.add(
        ExtractedMistake(
          questionBody: body.trim(),
          answerKey: _optionalString(map, 'answerKey'),
          knowledgePoint: _optionalString(map, 'knowledgePoint'),
          // 缺 confidence 时给 0 而不是 1：方向必须偏保守 ——
          // 一个「没把握」被当成「很有把握」，学生就会跳过核对。
          confidence: confidence is num ? confidence.toDouble().clamp(0.0, 1.0) : 0,
          uncertain: _optionalString(map, 'uncertain'),
        ),
      );
    }

    // 一条都没解析出来，而模型确实给了条目：这是真违约，不是
    // 「照片里没题」。两条路的处置完全不同（重拍 vs 手填）。
    if (raw.isNotEmpty && candidates.isEmpty) {
      throw _SchemaViolation('questions 里没有一条带 questionBody 的条目');
    }

    var overall = data['confidence'];
    var uncertain = _optionalString(data, 'uncertain');
    double confidence;
    if (overall is num) {
      confidence = overall.toDouble().clamp(0.0, 1.0);
    } else if (candidates.isNotEmpty) {
      // 整体把握缺失时取候选的**最小值**，不取均值：一页里有一道题糊了，
      // 均值会被另外七道好题拉高，于是「这页有一处要重拍」的信号消失。
      confidence = candidates
          .map((candidate) => candidate.confidence)
          .reduce((a, b) => a < b ? a : b);
      uncertain = uncertain.isEmpty ? '' : uncertain;
    } else {
      confidence = 0;
    }

    if (broken > 0) {
      final note = '有 $broken 条识别结果格式不完整，已忽略，可以补拍这几道。';
      uncertain = uncertain.isEmpty ? note : '$uncertain；$note';
    }

    return MistakeExtraction(
      candidates: candidates,
      confidence: confidence,
      uncertain: uncertain,
      source: AiAnswerSource.cloud,
    );
  }

  AnswerJudgement _parseJudgement(Map<String, dynamic> data) {
    final raw = _requireNonEmptyString(data, 'verdict');
    final verdict = switch (raw) {
      'correct' => AnswerVerdict.correct,
      'wrong' => AnswerVerdict.wrong,
      'inconclusive' => AnswerVerdict.inconclusive,
      // 硬失败而不是猜一个：把未知取值默认成 wrong 会让「模型换了字段名」
      // 表现为「学生全错」，这是最难发现的一类线上事故。
      _ => throw _SchemaViolation('verdict 取值非法：$raw'),
    };
    final score = _requireInt(data, 'score');
    return AnswerJudgement(
      verdict: verdict,
      score: score.clamp(0, 100),
      comment: _requireNonEmptyString(data, 'comment'),
      // 走到这里就是模型真的答了 —— 影子的 A/B 比对靠这个标记决定要不要记一笔。
      // 降级路径走 `fallback.judgeAnswer`，那里默认是 local，不需要在这里处理。
      source: AiAnswerSource.cloud,
    );
  }

  /// 解析讲解配图。
  ///
  /// 只有一种情况算违约：`draw=true` 却给了解析不出来的图。那时**抛异常**
  /// 走重试，而不是悄悄退成「不画」—— 两者在界面上都表现为「没有图」，
  /// 但前者是模型这次没画对（值得再试一次），后者是这题本来就不该画
  /// （再试一百次也是同一句话）。混在一起，配图质量下滑就再也看不见了。
  MistakeFigure _parseFigure(Map<String, dynamic> data) {
    final parsed = MistakeFigure.parse(data);
    if (parsed == null) {
      throw const _SchemaViolation('draw=true 但 figure 无法解析，或 draw 字段缺失');
    }
    return parsed;
  }

  MistakeExplanation _parseExplanation(Map<String, dynamic> data) {
    return MistakeExplanation(
      knowledgePoint: _requireNonEmptyString(data, 'knowledgePoint'),
      position: _requireString(data, 'position'),
      whyWrong: _requireNonEmptyString(data, 'whyWrong'),
      steps: _requireStringList(data, 'steps'),
      pitfalls: _requireStringList(data, 'pitfalls'),
      mnemonic: _requireString(data, 'mnemonic'),
    );
  }

  /// 解析一道变式题。**不合格返回 null**，由调用方丢弃。
  ///
  /// 为什么不是抛异常：一条题的选项数不对，不该让另外两道好题一起作废 ——
  /// 学生点一次「生成变式题」等三十秒，回来的东西全没了，比少一道题糟得多。
  /// 但也不能原样放过去：选项只有 3 个的选择题，学生点哪个都可能被判错。
  ///
  /// 返回 null 的每一种情况都会 `_report` 一条降级记录 —— 丢题这件事
  /// 必须能在 `lastDegradation` 里读到，而不是只表现为「这次只出了 2 道」。
  GeneratedQuestion? _parseGeneratedQuestion(Object? raw) {
    if (raw is! Map) {
      _report(
        operation: 'generatePractice',
        code: 'practice_question_dropped',
        reason: 'questions 里混进了非对象元素（${raw.runtimeType}），已丢弃',
      );
      return null;
    }
    final map = raw.cast<String, dynamic>();

    final type = PracticeQuestionType.parse(_optionalString(map, 'type'));
    final title = _optionalString(map, 'title').trim();
    final content = _optionalString(map, 'content').trim();
    final answer = _optionalString(map, 'answer').trim();
    final difficulty = _optionalString(map, 'difficulty').trim();

    if (title.isEmpty || content.isEmpty || answer.isEmpty) {
      _report(
        operation: 'generatePractice',
        code: 'practice_question_dropped',
        reason:
            '有一道 $type 题缺题干或答案'
            '（title=${title.isEmpty ? '空' : '有'}，'
            'content=${content.isEmpty ? '空' : '有'}，'
            'answer=${answer.isEmpty ? '空' : '有'}），已丢弃',
      );
      return null;
    }

    var options = const <String>[];
    var normalizedAnswer = answer;

    if (type == PracticeQuestionType.choice) {
      final rawOptions = map['options'];
      if (rawOptions is! List) {
        _report(
          operation: 'generatePractice',
          code: 'practice_question_dropped',
          reason: '有一道选择题没给 options，已丢弃',
        );
        return null;
      }
      options = rawOptions
          .whereType<String>()
          .map(stripOptionPrefix)
          .where((option) => option.isNotEmpty)
          .toList(growable: false);
      if (!isUsableOptions(options)) {
        _report(
          operation: 'generatePractice',
          code: 'practice_question_dropped',
          reason:
              '有一道选择题的选项不合格（${options.length} 个，'
              '${options.toSet().length} 个不重复），已丢弃',
        );
        return null;
      }
      final letter = normalizeChoiceAnswer(answer, options);
      if (letter == null) {
        _report(
          operation: 'generatePractice',
          code: 'practice_question_dropped',
          reason: '有一道选择题的答案认不出是哪个选项（answer=$answer），已丢弃',
        );
        return null;
      }
      normalizedAnswer = letter;
    } else if (type == PracticeQuestionType.judge) {
      final normalized = normalizeJudgeAnswer(answer);
      if (normalized == null) {
        _report(
          operation: 'generatePractice',
          code: 'practice_question_dropped',
          reason: '有一道判断题的答案不是「正确/错误」（answer=$answer），已丢弃',
        );
        return null;
      }
      normalizedAnswer = normalized;
    }

    // 配图。解析不出就当没有图 —— `PracticeFigure.parse` 已经保证
    // 「哪一处对不上就整张返回 null」，这里不用再判。
    // 注意**不**因为图坏了就把整道题丢掉：网关那边已经做过这道判断
    // （题干说「如图」才丢题），这里只负责画得出来就画。
    final figure = PracticeFigure.parse(map['figure']);

    return GeneratedQuestion(
      title: title,
      content: content,
      // answer 必须有值：没有答案的练习题在闭环里无法判定对错，
      // 只能变成一道永远毕不了业的题。
      answer: normalizedAnswer,
      difficulty: difficulty.isEmpty ? '基础' : difficulty,
      questionType: type,
      options: options,
      figure: figure,
    );
  }
}

/// 网关返回的数据不符合契约。
///
/// 单独定义而不是复用 [AiRequestException]：解析期的失败要能带上
/// 具体的字段名回给模型，而 [AiRequestException] 的语义是「这次请求没成」。
class _SchemaViolation implements Exception {
  const _SchemaViolation(this.message);

  final String message;
}

num _requireNum(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is num) return value;
  // 只认识数字。绝不 `double.tryParse(value) ?? 0` —— 那种写法会把
  // 「模型没给 confidence」静默变成一个**看起来很低但合法**的值，
  // 于是「这个字段缺失」表现成「模型对识别没把握」，方向完全错。
  throw _SchemaViolation('$key 应为数字，实际是 ${_describe(value)}');
}

int _requireInt(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw _SchemaViolation('$key 应为数字，实际是 ${_describe(value)}');
}

String _requireString(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is String) return value;
  throw _SchemaViolation('$key 应为字符串，实际是 ${_describe(value)}');
}

String _requireNonEmptyString(Map<String, dynamic> data, String key) {
  final value = _requireString(data, key);
  if (value.trim().isEmpty) throw _SchemaViolation('$key 不能为空');
  return value;
}

/// 读一个**可以缺席**的字符串字段，缺席即空串。
///
/// 与 [_requireString] 的区别只在「缺失时怎么办」，而不是「校验松一点」：
/// 它用在 `answerKey` / `uncertain` 这类**契约上可选**的字段上。
/// 类型写错（比如给了数字）也按空串处理 —— 理由是这几条链路已经
/// 按条容错了，为一个装饰性字段把整页题目判死，代价比缺这一条信息大。
///
/// ⚠️ 不要拿它读 `questionBody` 这类**承载业务**的字段：那里的空值
/// 必须走违约分支，否则「模型没答」会表现成「这道题是空的」。
String _optionalString(Map<String, dynamic> data, String key) {
  final value = data[key];
  return value is String ? value.trim() : '';
}

List<Object?> _requireList(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is List) return value;
  throw _SchemaViolation('$key 应为数组，实际是 ${_describe(value)}');
}

List<String> _requireStringList(Map<String, dynamic> data, String key) {
  return _requireList(data, key).map((item) {
    if (item is String) return item;
    throw _SchemaViolation('$key 的元素应为字符串，实际是 ${_describe(item)}');
  }).toList();
}

String _describe(Object? value) {
  if (value == null) return 'null';
  if (value is Map) return '对象';
  if (value is List) return '数组';
  return '${value.runtimeType}($value)';
}
