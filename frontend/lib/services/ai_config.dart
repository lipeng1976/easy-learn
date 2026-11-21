import 'package:flutter/foundation.dart';

import 'data_config.dart';
import 'session_store.dart';

/// AI 能力的运行期配置。
///
/// 这是项目里**第一个配置层**。在此之前 AI 调用全是 static 直连，
/// 没有 baseUrl / 开关 / 超时这些概念，于是「切到云端」就等于「改代码」。
///
/// 默认值是刻意选的：**空 baseUrl 即完全离线**。
/// 也就是说，什么都不配的情况下，[AiConfig.resolve] 返回的就是今天的行为
/// （走 [SimulatedAiDataSource]），线上不会因为忘记配环境变量而突然产生费用。
class AiConfig {
  const AiConfig({
    this.baseUrl = '',
    this.fallbackBaseUrls = const [],
    this.enabled = true,
    this.requestTimeout = const Duration(seconds: 12),
    this.uploadTimeout = const Duration(seconds: 30),
    this.judgeTimeout = const Duration(seconds: 20),
    this.maxAttempts = 2,
    this.imageTransport = AiImageTransport.inline,
    this.inlineImageMaxCount = 4,
    this.inlineImageMaxBytes = 3 * 1024 * 1024,
    this.capabilities = AiCapabilities.all,
  });

  /// AI 网关地址，例如 `https://ai.example.com`。
  ///
  /// **必须是你自己的服务端**，不能填模型厂商的地址 ——
  /// 填厂商地址就意味着 API Key 要进客户端产物，Web 端编译进 JS 可被直接抄走。
  final String baseUrl;

  /// 备选网关地址 —— 与 [baseUrl] 是**同一台机器的两条网络路径**
  /// （家里局域网 / Tailscale），不是两个网关。由 `EndpointResolver` 择优。
  ///
  /// 与数据面必须成对出现：只切数据面会导致「登录成功、批改连不上」。
  final List<String> fallbackBaseUrls;

  /// 参与探测的候选地址，首选在前。
  List<String> get candidateBaseUrls => [
        if (baseUrl.trim().isNotEmpty) baseUrl.trim(),
        ...fallbackBaseUrls.where((e) => e.trim().isNotEmpty),
      ];

  /// 总开关。紧急止血用：置 false 后客户端完全走本地实现，不发任何请求。
  final bool enabled;

  /// 单次请求超时。批改要过视觉模型，比文本慢，所以取 12s。
  final Duration requestTimeout;

  /// 图片上传单独的超时（对象存储模式直传，不经网关）。
  final Duration uploadTimeout;

  /// 单题判定（`/ai/review/judge`）的超时窗口。
  ///
  /// 比 [requestTimeout] 宽、比批改的 30s 窄，取 **20s**。三条理由：
  ///
  /// - 判定走强推理档，而且是**唯一没有关掉思维链**的路由
  ///   （名单见网关的 `AI_THINKING_DISABLED_KINDS`）。实测同一份
  ///   prompt/schema/模型：开思维链 4.7~7.0s（中位 5.3s），关掉只要 1.7s。
  ///   判定结果直接决定这道题能不能从错题库毕业，准确率比那 3 秒值钱，所以不关。
  /// - 默认那 12s 会被**冷启动**撞穿（实测云上首批 47~50s）。撞穿的后果不是报错，
  ///   而是安静地返回本地兜底结论 —— 学生看不出来那不是模型给的。
  /// - 不跟着批改一起取 30s：判定是**交互动作**，学生每点一次都要等，
  ///   「等 30s 才降级」比「等 20s 就降级」更伤。
  ///
  /// ⚠️ 窗口是**单次尝试**的。`maxAttempts` = 2 ⇒ 最坏 ≈ 20s + 退避 + 20s。
  final Duration judgeTimeout;

  /// 单次调用最多尝试几次（含首次）。
  ///
  /// 2 意味着失败后重试一次 —— 与设计文档「校验失败带错误信息重试一次，
  /// 仍失败则回落本地」一致。**不要调到 3 以上**：每次重试都是真金白银，
  /// 而且模型侧的偶发失败通常是连续的，连续三次失败的概率远高于单次。
  final int maxAttempts;

  /// 作业照片怎么送到云端。见 [AiImageTransport]。
  final AiImageTransport imageTransport;

  /// 内联模式下单次请求最多带几张照片。
  final int inlineImageMaxCount;

  /// 内联模式下单次请求照片的总体积上限（base64 之前）。
  ///
  /// 3MB 是照着 Serverless 平台的请求体上限倒推的：常见限额 6MB，
  /// base64 会膨胀约 33%，再留出 JSON 与文本的余量。
  /// 客户端先压到 1600px / quality 72，单张约 200–600KB，4 张仍在预算内。
  final int inlineImageMaxBytes;

  /// 服务端已开通的能力。见 [AiCapabilities]。
  final AiCapabilities capabilities;

  /// 是否具备走云端的条件。false 时调用方应直接用本地实现。
  bool get hasBackend => enabled && baseUrl.isNotEmpty;

  AiConfig copyWith({
    String? baseUrl,
    List<String>? fallbackBaseUrls,
    bool? enabled,
    Duration? requestTimeout,
    Duration? uploadTimeout,
    Duration? judgeTimeout,
    int? maxAttempts,
    AiImageTransport? imageTransport,
    int? inlineImageMaxCount,
    int? inlineImageMaxBytes,
    AiCapabilities? capabilities,
  }) {
    return AiConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      fallbackBaseUrls: fallbackBaseUrls ?? this.fallbackBaseUrls,
      enabled: enabled ?? this.enabled,
      requestTimeout: requestTimeout ?? this.requestTimeout,
      uploadTimeout: uploadTimeout ?? this.uploadTimeout,
      judgeTimeout: judgeTimeout ?? this.judgeTimeout,
      maxAttempts: maxAttempts ?? this.maxAttempts,
      imageTransport: imageTransport ?? this.imageTransport,
      inlineImageMaxCount: inlineImageMaxCount ?? this.inlineImageMaxCount,
      inlineImageMaxBytes: inlineImageMaxBytes ?? this.inlineImageMaxBytes,
      capabilities: capabilities ?? this.capabilities,
    );
  }

  /// 从编译期常量读取。
  ///
  /// 数据面地址由网关决定，客户端只需要知道网关在哪 ——
  /// 厂商、模型、区域都是服务端知识，改这些不该要求发版。
  ///
  /// ```bash
  /// flutter build web --dart-define=AI_BASE_URL=https://ai.example.com
  /// ```
  ///
  /// 三条超时线也可以覆盖，**这是接本机模型时必须做的**：
  /// 云端模型的耗时是稳定的，本机模型的耗时由那台机器的显存决定 ——
  /// 实测一台 12GB 显存笔记本上的 `gemma4:26b` 约 46–55 token/s，
  /// 于是默认的 12s 只够产出约 500 个输出 token，而「错题讲解」的
  /// 结构化输出（步骤 / 易错点 / 口诀）天然要 2000 个左右。
  /// 不调窗口的症状是「讲解永远返回本地兜底」，而不是报错。
  ///
  /// ```bash
  /// flutter build web --dart-define=AI_BASE_URL=http://127.0.0.1:8787 \
  ///   --dart-define=AI_TIMEOUT_MS=90000 --dart-define=AI_UPLOAD_TIMEOUT_MS=120000 \
  ///   --dart-define=AI_JUDGE_TIMEOUT_MS=45000
  /// ```
  ///
  /// **云端部署不要动它们**：那是把「模型一句话都不回」的等待时间也一起放大了。
  factory AiConfig.fromEnvironment() {
    const baseUrl = String.fromEnvironment('AI_BASE_URL');
    const fallbacks = String.fromEnvironment('AI_FALLBACK_URLS');
    const disabled = bool.fromEnvironment('AI_DISABLED');
    const vision = bool.fromEnvironment('AI_CAP_VISION', defaultValue: true);
    const reasoning = bool.fromEnvironment(
      'AI_CAP_REASONING',
      defaultValue: true,
    );
    const light = bool.fromEnvironment('AI_CAP_LIGHT', defaultValue: true);
    const inlineTransport = String.fromEnvironment(
      'AI_IMAGE_TRANSPORT',
      defaultValue: 'inline',
    );
    const attempts = int.fromEnvironment('AI_MAX_ATTEMPTS', defaultValue: 2);
    const timeoutMs = int.fromEnvironment('AI_TIMEOUT_MS');
    const uploadTimeoutMs = int.fromEnvironment('AI_UPLOAD_TIMEOUT_MS');
    const judgeTimeoutMs = int.fromEnvironment('AI_JUDGE_TIMEOUT_MS');

    return AiConfig(
      baseUrl: baseUrl,
      fallbackBaseUrls: DataConfig.splitUrls(fallbacks),
      enabled: !disabled,
      requestTimeout: sanitizeTimeout(
        timeoutMs,
        const Duration(seconds: 12),
      ),
      uploadTimeout: sanitizeTimeout(
        uploadTimeoutMs,
        const Duration(seconds: 30),
      ),
      judgeTimeout: sanitizeTimeout(
        judgeTimeoutMs,
        const Duration(seconds: 20),
      ),
      imageTransport: inlineTransport == 'objectStorage'
          ? AiImageTransport.objectStorage
          : AiImageTransport.inline,
      maxAttempts: attempts < 1 ? 1 : attempts,
      capabilities: const AiCapabilities(
        vision: vision,
        reasoning: reasoning,
        light: light,
      ),
    );
  }

  /// 把编译期常量里的毫秒数收敛成合法的超时值。
  ///
  /// 单独提成纯函数是为了能直接测 —— 而它偏偏最需要被测：
  /// 把单位写错（想写 30 秒却填了 `30`）得到的是 30ms，
  /// 症状是「每次调用都失败得很稳定」，比不配这个参数更难查。
  ///
  /// 小于 1s 一律当作没配。1000ms 这个下限本身也说明了一件事：
  /// 没有任何一次真的模型调用能在 1 秒内跑完，凡是往这个方向配的值都是笔误。
  static Duration sanitizeTimeout(int milliseconds, Duration fallback) =>
      milliseconds >= 1000 ? Duration(milliseconds: milliseconds) : fallback;

  /// 解析出真正要用的配置：显式传入的优先，否则读环境。
  static AiConfig resolve([AiConfig? override]) =>
      override ?? AiConfig.fromEnvironment();

  /// 依据网关 `/ai/health` 的回报修正能力开关。
  ///
  /// 必要性在于：视觉模型（手写识别）与强推理模型在方舟上**通常要分别开通**，
  /// 部分还需单独申请。客户端如果不知道，就会把 3MB 的照片发上去、
  /// 等一个必然失败的响应回来 —— 白花一次上行流量，还得再走一遍降级。
  AiConfig withCapabilities(AiCapabilities next) =>
      copyWith(capabilities: next);

  @override
  String toString() =>
      'AiConfig(baseUrl: ${baseUrl.isEmpty ? '(offline)' : baseUrl}, '
      'enabled: $enabled, transport: ${imageTransport.name}, '
      'attempts: $maxAttempts, caps: $capabilities)';
}

/// 作业照片送到云端的方式。
enum AiImageTransport {
  /// 字节内联进请求体，由网关转成方舟的多模态输入。
  ///
  /// 默认选择，理由有三条：
  /// - **零额外基础设施**：不需要对象存储、不需要签名、不需要 CORS 配置。
  /// - **照片不产生公网 URL**。这是教育类产品的实质优势 ——
  ///   作业照片里常年有孩子的姓名、班级、家庭住址。
  /// - **成本更低**：少一次上下行，少一次签名往返。
  ///
  /// 代价是请求体上限。照片已压到 1600px / quality 72，单张 200–600KB，
  /// 加上 base64 膨胀仍能装进 3MB 预算；超出部分会被丢弃并计数上报。
  inline,

  /// 客户端直传对象存储，请求体里只带 URL。
  ///
  /// 适合照片多、大，或需要跨次复用的场景（同一张照片反复批改时，
  /// 方舟的 `file_id` 可以缓存复用，不必重复计费）。
  /// 代价是要多一条签名链路，且照片会成为有时效的公网 URL。
  objectStorage,
}

/// 网关已开通的能力开关。
///
/// 对应模型选型的三级：视觉 / 强推理 / 轻量。三级不是拍脑袋分的 ——
/// 它们对应完全不同的单价（视觉 3/9、强推理 0.8/4.8、轻量 0.3/0.6 元每百万 token），
/// 混用会把成本结构搞坏：拿强推理模型去做文本格式化，钱花得毫无意义。
@immutable
class AiCapabilities {
  const AiCapabilities({
    required this.vision,
    required this.reasoning,
    required this.light,
  });

  /// 视觉：作业拍照识别、手写批改。对应方舟的豆包视觉档。
  final bool vision;

  /// 强推理：出题、讲解生成、规则判不了的难题。对应方舟的 Seed Pro 档。
  final bool reasoning;

  /// 轻量：文本解析、格式化、分类。对应方舟的 Lite / Mini 档。
  final bool light;

  static const AiCapabilities all = AiCapabilities(
    vision: true,
    reasoning: true,
    light: true,
  );

  static const AiCapabilities none = AiCapabilities(
    vision: false,
    reasoning: false,
    light: false,
  );

  bool get any => vision || reasoning || light;

  factory AiCapabilities.fromJson(Map<String, dynamic> json) {
    final raw = json['capabilities'];
    if (raw is! Map) return AiCapabilities.none;
    return AiCapabilities(
      vision: raw['vision'] == true,
      reasoning: raw['reasoning'] == true,
      light: raw['light'] == true,
    );
  }

  @override
  String toString() =>
      'vision: ${vision ? 'on' : 'off'}, '
      'reasoning: ${reasoning ? 'on' : 'off'}, '
      'light: ${light ? 'on' : 'off'}';
}

/// 「没有身份」时客户端曾用过、也**绝对不该再上行**的占位符。
///
/// 网关认识这个值，并把它和「请求头缺失」一样当作没身份 —— 因为配额与审计
/// 需要能归到某个真实学生头上，一个占位符会让额度落在「谁也不是」的账上。
///
/// 记在这里而不是散在调用点：客户端与网关对这个字符串的判断必须一致。
/// 曾经它只出现在 `student_home_page` 的 `?? 'anonymous'` 里，
/// 结果就是一次必然被拒的往返 —— 用户看到的是「照片认不出内容」，
/// 而模型一次都没被调用（2026-09-15 排查记录）。
const String kAnonymousStudentId = 'anonymous';

/// 请求身份。
///
/// 网关用它做三件事：鉴权（谁在调用）、限流（每人每日配额）、审计（谁花了多少）。
/// 三者缺一不可 —— 没有限流，上线后必然被刷；没有审计，事后无法归因。
///
/// ## 两种形态，靠 [sessionToken] 区分
///
/// - **本地模式**（没配数据服务地址）：没有会话，身份就是本地库里的用户 id。
///   这一路径与上云之前**逐字相同**。
/// - **云端模式**：登录时向数据服务换取会话 token（`HttpAuthApi`），
///   此后每个 AI 请求都带 `Authorization: Bearer …`。
///   网关侧 `AI_REQUIRE_AUTH=true` 时**只认 token**，请求头里的学号被忽略。
///
/// 学号在云端形态下仍然发，但它的作用变了：网关会把它与 token 里的
/// subject 比对，不一致就记一笔 `declaredStudentId` —— 那是一条**抓伪造**的
/// 审计信号。所以云端必须发会话里那一个（服务端签发的 uuid），
/// 用本地 id 会把每一次正常请求都灌进那条信号里，等于把它废掉。
@immutable
class AiIdentity {
  const AiIdentity({
    required this.studentId,
    this.deviceId = '',
    this.sessionToken = '',
    this.appVersion = '',
  });

  /// 按当前登录态装配身份。**两个构造点都必须走它**。
  ///
  /// 为什么不各自 `AiIdentity(studentId: ...)` 一行了事：token 与学号
  /// **必须来自同一份事实**（同一个会话）。各写各的时，最容易漏的正是
  /// [sessionToken] —— 而它的缺失没有任何本地症状：本地全绿、界面正常，
  /// 只有网关那边变成 401，表现为「AI 功能全挂」，根因却在一个没传的字段上
  /// （2026-09-20 打开 `AI_REQUIRE_AUTH` 时发现的正是这个）。
  ///
  /// [session] 为 null 或没有 token 时退回 [localUserId]，即本地模式的行为。
  /// 云端模式下身份取**会话里的用户 id**：它与 token 的 subject 是同一个值。
  static AiIdentity resolve({SessionStore? session, String? localUserId}) {
    final token = session?.token ?? '';
    if (token.isEmpty) return AiIdentity(studentId: localUserId ?? '');
    return AiIdentity(
      studentId: session?.userId ?? localUserId ?? '',
      sessionToken: token,
    );
  }

  final String studentId;
  final String deviceId;
  final String sessionToken;
  final String appVersion;

  bool get authenticated => sessionToken.isNotEmpty;

  /// 这份身份**能不能拿去问网关**。
  ///
  /// 空字符串与 [kAnonymousStudentId] 都不行。判定放在这里而不是调用点，
  /// 是为了让「未登录就别发请求」成为传输层的性质，而不是每个调用方各自记得。
  ///
  /// **有会话 token 时直接放行**：`requireAuth` 打开后网关只认 token，
  /// 学号是它自己从载荷里解的。这时若还拿学号当门槛，一条「有票但本地
  /// 用户行还没读出来」的请求会被客户端自己拦掉 —— 那是把有效的凭证
  /// 当成没身份。
  bool get usable {
    if (authenticated) return true;
    final id = studentId.trim();
    return id.isNotEmpty && id != kAnonymousStudentId;
  }

  AiIdentity copyWith({
    String? studentId,
    String? deviceId,
    String? sessionToken,
    String? appVersion,
  }) {
    return AiIdentity(
      studentId: studentId ?? this.studentId,
      deviceId: deviceId ?? this.deviceId,
      sessionToken: sessionToken ?? this.sessionToken,
      appVersion: appVersion ?? this.appVersion,
    );
  }

  @override
  String toString() =>
      'AiIdentity(student: $studentId, device: ${deviceId.isEmpty ? '-' : deviceId}, '
      'token: ${authenticated ? 'yes' : 'no'})';
}

/// 网关端点。集中在一处，避免路径字符串散落到各个实现里。
///
/// 端点**按业务动作划分，不按模型划分** —— 客户端不需要知道背后是哪个模型，
/// 换模型不该要求发版。这也是为什么这里找不到 `doubao` 之类的字样。
abstract final class AiEndpoints {
  static const String health = '/ai/health';
  static const String homeworkOcr = '/ai/homework/ocr';
  static const String homeworkCheck = '/ai/homework/check';
  static const String reviewJudge = '/ai/review/judge';

  /// 拍照作答：把照片里手写的**这一题**解答转录成文字。
  ///
  /// 它是 [reviewJudge] 的**上游**，不是替代品：识别出来的文字会先填进
  /// 学生的作答框（学生看得见、改得了），确认后再走原来的判定。
  /// 所以这条端点**不返回对错** —— 拍照只是换一种输入方式，
  /// 不该因为「怎么输入的」而得到不同的判定结论。
  ///
  /// ⚠️ 不要复用 [homeworkOcr]：它的语义是「整卷识别 + 按科目归纳作业要求」，
  /// 拿它来识别单题作答，模型会努力在一份作答里找出「作业要求」来填。
  static const String reviewAnswerOcr = '/ai/review/answer-ocr';

  /// 错题录入：把照片里的**题目**提取成文本。
  ///
  /// 与 [reviewAnswerOcr] 是镜像关系，不要合并：那条问「学生写了什么」，
  /// 这条问「这上面印着什么」。共用一个端点的后果是模型对着学生手写的
  /// 答案讲题 —— 而题干会被存进错题库，之后被反复重做。
  static const String reviewExtractMistakes = '/ai/review/extract-mistakes';

  static const String reviewExplain = '/ai/review/explain';

  /// 讲解配图：先判「这题该不该画」，该画才给坐标。
  ///
  /// 与 [reviewPractice] 分开：那条是「出题给人做」，这条是「画图给人看」。
  /// 合成一条靠 `want` 字段区分的后果，是 `want` 写错时学生拿到三道练习题
  /// 却看不到图 —— 而且两边都返回 200，没有一处会报错。
  static const String reviewFigure = '/ai/review/figure';

  static const String reviewPractice = '/ai/review/practice';

  /// 每日概念打卡：按知识点出几道**可本地判分**的短题（选择 / 判断）。
  ///
  /// 与 [reviewPractice] 分开，因为判分方式不同：那边允许填空与解答
  /// （批改有人/模型参与），这边由 App 本地确定性比对 —— 只出两种题型。
  static const String checkinGenerate = '/ai/checkin/generate';

  /// 错题库 → 知识点提示。
  ///
  /// 与 [reviewPractice] 的区别是**只读不改**：它不出题、不判定，
  /// 只把学生已经错过的知识点各写一句话，供计时页轮换显示。
  static const String reviewTips = '/ai/review/tips';

  /// 伴读：文字 → 一组音频地址。
  ///
  /// 为什么在服务端：学生那台鸿蒙手机通过卓易通跑安卓应用，那个容器
  /// **没有实现安卓的语音合成服务** —— 端上 `TextToSpeech.speak()` 会卡十几秒
  /// 然后超时，不是参数问题，是那台设备上没有这条路。
  static const String tts = '/ai/tts';

  /// 批量取参考答案。
  ///
  /// 单独一个端点而不是复用 [reviewPractice]：组卷一页 20 道题，
  /// 逐题请求就是 20 次往返，而且每次都要重付一遍同样的提示词输入 token。
  static const String reviewReferenceBatch = '/ai/review/reference-batch';

  static const String uploadsSign = '/ai/uploads/sign';

  /// 用量与成本看板（只读）。
  ///
  /// **它读的是网关自己那份审计聚合，不占学生配额** ——
  /// 运维看数据这件事本身不该吃掉孩子的批改额度。
  static const String metrics = '/ai/metrics';
}
