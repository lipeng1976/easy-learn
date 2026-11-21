/// 数据面的运行期配置。
///
/// 与 [AiConfig] 是同一条思路的第二次应用：**默认值是空的，空即离线**。
/// 也就是说，什么都不配的情况下客户端走 [LocalDatabaseService]（本地 SQLite /
/// Web 内存），行为与上云之前**逐字相同** —— 线上不会因为漏配一个环境变量
/// 就突然把数据写到一个谁都没管的服务端上。
///
/// ```bash
/// # 本地演示（配本机的数据服务）
/// flutter run -d chrome --dart-define=DATA_API_BASE_URL=http://127.0.0.1:8788
/// ```
///
/// ## 为什么是编译期常量而不是运行期开关
///
/// 「数据存在哪」不是用户可以切的偏好 —— 它是**部署形态**。
/// 做成运行期开关的后果是：同一个安装包里两套实现都活着，于是「这个 bug 是在
/// 哪一套里出现的」变成每次都要先问一遍的问题，而本地库里那份数据与云端那份
/// 会在用户来回切换时开始分叉（而分叉不报错，只表现为「我的作业少了一份」）。
///
/// 与 [AiConfig.baseUrl] 的区别：AI 那个可以在运行期探测能力（`/ai/health`），
/// 因为降级是它的常态；数据面没有「降级到本地」这个选项 ——
/// 读不到就是读不到，退回去只会让用户看到一份**过期的**数据并且不知道。
class DataConfig {
  const DataConfig({
    this.baseUrl = '',
    this.fallbackBaseUrls = const [],
    this.requestTimeout = const Duration(seconds: 10),
    this.imageTimeout = const Duration(seconds: 20),
    this.enabled = true,
  });

  /// 数据服务地址，例如 `http://127.0.0.1:8788`。
  final String baseUrl;

  /// 备选地址（同一个后端的**另一条网络路径**，不是另一个后端）。
  ///
  /// 典型场景：家里走局域网 `192.168.3.80`，出门走 Tailscale `100.96.105.11`。
  /// 由 `EndpointResolver` 在运行期探测择优。
  ///
  /// ⚠️ 它们必须指向**同一份数据库**。这台机器上 `8788` 后面只有一个
  /// `easylearn_db`，两条路只是网络可达性不同 —— 所以不会出现
  /// 「数据在两个后端之间分叉」。上面关于「不做运行期开关」的说明反对的是
  /// **在本地 SQLite 与云端之间**来回切，与这里不是一回事。
  final List<String> fallbackBaseUrls;

  /// 参与探测的完整候选列表，首选在前。
  List<String> get candidateBaseUrls => [
        if (baseUrl.trim().isNotEmpty) baseUrl.trim(),
        ...fallbackBaseUrls.where((e) => e.trim().isNotEmpty),
      ];

  /// 单次请求超时。
  ///
  /// 10 秒是照着「本地局域网 + 云 RDS」的正常量级取的（几十毫秒）。
  /// 比 AI 那条 12 秒的线短，因为数据请求的期望是「立刻回来」——
  /// 让它等 30 秒，用户看到的是一个卡住不动的首页，而其实早就该失败了。
  final Duration requestTimeout;

  /// 照片上传 / 读取的超时。
  ///
  /// **单独一条，刻意不复用 [requestTimeout]**：JSON 请求的体是几百字节、
  /// 期望「立刻回来」，而一张手机照片是好几兆 —— 拿 10 秒去卡它，
  /// 在正常网络下也会超时。而这条路超时的表现是「照片传不上去」，
  /// 看起来像服务端坏了，实际只是限额给小了。
  final Duration imageTimeout;

  /// 总开关。紧急止血用：置 false 后完全走本地实现。
  final bool enabled;

  /// 是否具备走服务端的条件。
  bool get hasBackend => enabled && baseUrl.trim().isNotEmpty;

  DataConfig copyWith({
    String? baseUrl,
    List<String>? fallbackBaseUrls,
    Duration? requestTimeout,
    Duration? imageTimeout,
    bool? enabled,
  }) {
    return DataConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      fallbackBaseUrls: fallbackBaseUrls ?? this.fallbackBaseUrls,
      requestTimeout: requestTimeout ?? this.requestTimeout,
      imageTimeout: imageTimeout ?? this.imageTimeout,
      enabled: enabled ?? this.enabled,
    );
  }

  /// 从编译期常量读取。
  ///
  /// ```bash
  /// flutter build web --dart-define=DATA_API_BASE_URL=https://data.example.com
  /// ```
  /// 逗号分隔的备选地址：`--dart-define=DATA_API_FALLBACK_URLS=a,b`
  factory DataConfig.fromEnvironment() {
    const baseUrl = String.fromEnvironment('DATA_API_BASE_URL');
    const fallbacks = String.fromEnvironment('DATA_API_FALLBACK_URLS');
    const disabled = bool.fromEnvironment('DATA_DISABLED');
    const timeoutMs = int.fromEnvironment('DATA_TIMEOUT_MS');
    const imageTimeoutMs = int.fromEnvironment('DATA_IMAGE_TIMEOUT_MS');

    return DataConfig(
      baseUrl: baseUrl,
      fallbackBaseUrls: splitUrls(fallbacks),
      enabled: !disabled,
      requestTimeout: sanitizeTimeout(timeoutMs, const Duration(seconds: 10)),
      imageTimeout: sanitizeTimeout(imageTimeoutMs, const Duration(seconds: 30)),
    );
  }

  /// 把一个逗号分隔的字符串拆成地址列表。
  ///
  /// 单独提出来是为了能被测试直接盯住：「多一个空格」「多一个逗号」
  /// 在这里的后果是**一个永远连不上的候选**，而它不报错，
  /// 只让每次冷启动多等一个超时。
  static List<String> splitUrls(String raw) => raw
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);

  /// 小于 1 秒一律当作没配 —— 与 [AiConfig.sanitizeTimeout] 同一条理由：
  /// 把单位写错（想写 10 秒却填了 `10`）得到的是 10ms，症状是
  /// 「每个请求都超时得很稳定」，比不配这个参数更难查。
  static Duration sanitizeTimeout(int milliseconds, Duration fallback) =>
      milliseconds >= 1000 ? Duration(milliseconds: milliseconds) : fallback;

  static DataConfig resolve([DataConfig? override]) =>
      override ?? DataConfig.fromEnvironment();

  @override
  String toString() =>
      'DataConfig(baseUrl: ${baseUrl.isEmpty ? '(本地实现)' : baseUrl}, '
      'timeout: ${requestTimeout.inSeconds}s, enabled: $enabled)';
}

/// 规范一个端点路径：`/data/homework` ↔ `data/homework` 都收。
///
/// 存在的理由是「拼 URL」这件事在这个项目里会做几十次，而 `Uri.resolve` 对
/// 不带前导斜杠的相对路径是**按目录**解析的 —— `http://host/api` + `data/homework`
/// 会得到 `http://host/data/homework`（`/api` 被吃掉了）。这类错误不会报错，
/// 只会得到一次 404，然后在「接口拼错了」这个方向上浪费半小时。
String joinUrlPath(String baseUrl, String path) {
  final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
  final rest = path.startsWith('/') ? path : '/$path';
  return '$base$rest';
}
