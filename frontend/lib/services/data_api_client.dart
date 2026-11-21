import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'bootstrap_sections.dart';
import 'data_config.dart';
import 'data_staleness_log.dart';
import 'endpoint_resolver.dart';
import 'read_cache.dart';
import 'session_store.dart';

/// 数据服务的调用失败。
///
/// ## 为什么错误码要原样带出来，而不是压成一句文案
///
/// 服务端的错误码是**协议的一部分**（见 `serverless/shared/errors.js`）：
/// 同一个 401 下，`token_invalid` 要去登录页，`token_expired` 理论上可以续签；
/// 403 是「我知道你是谁，但这不是你的」—— 重新登录没有用。
/// 把三者压成「请求失败，请重试」之后，界面能做的只有一件事：让用户重试。
/// 而重试对一个权限问题永远不会成功。
class DataApiException implements Exception {
  const DataApiException({
    required this.code,
    required this.message,
    this.status = 0,
    this.requestId,
    this.retryable = false,
    this.details,
  });

  /// 服务端错误码，或客户端自己产生的 `network` / `timeout` / `bad_response`。
  final String code;

  /// 给人看的中文说明。**直接可展示** —— 服务端的文案就是中文的。
  final String message;

  final int status;
  final String? requestId;

  /// 服务端声明的「重试有没有意义」。
  final bool retryable;

  /// 服务端附带的细节（信封里的 `error.details`）。
  ///
  /// 目前只有一个用途，但它是**必须**的：照片读不到时 `details['reason']`
  /// 区分「这张图的字节不在服务端（旧数据，请**回退本地读**）」与
  /// 「文件真的没了（如实报不可用）」。两者都会是 `not_found`，
  /// 而处置**完全相反** —— 只看 code 分辨不出来。
  final Map<String, dynamic>? details;

  /// 凭证问题：必须重新登录。
  ///
  /// `token_expired` 也归在这里 —— 服务端**没有** `/auth/refresh` 这条端点
  /// （见 `src/app.js` 的路由表），所以「过期」在客户端能做的与「无效」相同。
  /// 将来补上续签时，这里要拆开，而不是让续签逻辑悄悄挂在 invalid 上。
  bool get needsReLogin =>
      code == 'token_invalid' || code == 'unauthorized' || code == 'token_expired';

  /// 身份有效但没权限。**重试与重登都没用**。
  bool get isForbidden => code == 'forbidden';

  /// 根本没连上（离线 / 服务没起来）。这类失败**最该在界面上说清楚**，
  /// 因为它与「服务端拒绝了」的处置完全不同：一个是查网络，一个是查数据。
  bool get isOffline => code == 'network' || code == 'timeout';

  /// 可以**直接摆给用户看**的一句话。与 [message] 分开是有意的。
  ///
  /// ## 为什么必须分开
  ///
  /// [message] 里带着 URL 和底层异常原文（`ClientException: Software caused
  /// connection abort, uri=https://…`）—— 那是**给排查用的**。2026-09-25 真机
  /// 上就是让它进了界面：横幅把 `message` 原样拼出来，学生看到的是
  ///
  /// > 现在连不上数据服务（连不上数据服务（https://…/data/study-plans）：
  /// > ClientException: Software caused connection abort, uri=https://…），
  /// > 界面显示的是上一次同步下来的内容。
  ///
  /// 双重前缀 + 英文异常 + 完整地址。用户从这句话里**得不到任何能据以行动
  /// 的信息**，只能确定「出事了」—— 而那正是 `photo_failure_reason` 那条路
  /// 早就确立过的原则（见 `test/photo_failure_reason_test.dart` 的
  /// 「取不到原因时不许编：只说张数，不带内部错误文本」）。
  ///
  /// ## 为什么回落 [message] 而不是无脑换掉
  ///
  /// 服务端回来的业务文案天然是中文且可展示（「需要提供会话 token」这类），
  /// 换掉它等于把有用的原因丢掉。真正需要换的只有 `network` / `timeout`
  /// 这两个**在客户端本地生成**的 code —— 它们的 `message` 是写给开发者看的。
  /// ⚠️ 2026-10-06 改过措辞：原来这两句是「现在连不上数据服务」/「数据服务响应超时」。
  /// 它们在横幅里本来读得通（后面还接着「界面显示的是上一次同步下来的内容。」），
  /// 但同一个 getter 也被**单独展示**的地方用（聊天失败、照片保存失败）——
  /// 那里只说了「出事了」，没说「你该怎么办」。补上行动建议。
  String get userMessage => switch (code) {
        'network' => '网络不可用，请检查网络后重试',
        'timeout' => '网络较慢或服务繁忙，请稍后重试',
        _ => message,
      };

  @override
  String toString() => '[$code] $message';
}

/// 首屏聚合预热（P2-2）的战绩。
///
/// 只用于排查与测试，**不进界面** —— 它不是指标，是「聚合到底有没有在干活」
/// 的证据。与 `ReadCacheStats` 同一个理由。
///
/// 为什么值得单独记：这个优化**失败的时候什么都不发生**。聚合没生效、段名对不上、
/// 服务端没有这条路由 —— 三种情况的界面表现完全一样，只是首页多打了 17 次网络。
/// 在一个往返 0.2ms 的本机上，那 17 次根本看不出来。
class BootstrapPrefetchStats {
  const BootstrapPrefetchStats({
    this.attempts = 0,
    this.seeded = 0,
    this.failedSections = 0,
    this.rejected = 0,
    this.lastError = '',
  });

  /// 真的向 `/data/bootstrap` 发过几次请求。
  final int attempts;

  /// 最近一次成功**写进缓存**的段数。
  final int seeded;

  /// 最近一次服务端**如实上报**的失败段数（见 `bootstrap.js` 的 `failed`）。
  final int failedSections;

  /// 最近一次因「一条太大」被读缓存静默拒收的段数（`ReadCacheLimits.maxEntryBytes`）。
  final int rejected;

  /// 最近一次整体失败的原因。空串 = 没失败过。
  final String lastError;

  BootstrapPrefetchStats copyWith({
    int? attempts,
    int? seeded,
    int? failedSections,
    int? rejected,
    String? lastError,
  }) =>
      BootstrapPrefetchStats(
        attempts: attempts ?? this.attempts,
        seeded: seeded ?? this.seeded,
        failedSections: failedSections ?? this.failedSections,
        rejected: rejected ?? this.rejected,
        lastError: lastError ?? this.lastError,
      );

  @override
  String toString() => '聚合预热：发过 $attempts 次 / 写入 $seeded 段 / '
      '服务端报失败 $failedSections 段 / 缓存拒收 $rejected 段'
      '${lastError.isEmpty ? '' : ' / 最近一次失败：$lastError'}';
}

/// 数据服务的 HTTP 传输层。
///
/// 只做三件事：拼 URL、带 token、拆信封。**不含任何业务判断** ——
/// 「这次读要不要走服务端」在 `DatabaseService` 门面里决定，
/// 字段怎么映射在各自的 Repository 实现里。
///
/// 信封形状与 ai-gateway 一致（`{ok, data, meta}` / `{ok:false, error}`），
/// 所以客户端的解析逻辑两边共用一套心智模型，不需要记两套。
///
/// ## 读缓存挂在这一层（迁移计划 §7 方案 B）
///
/// 缓存放这里而不是放进九个 `Http*Repository`，是因为**读路径的形状是一样的**：
/// 拼 URL → 带 token → 拆信封 → 拿 `data`。九个仓库各写一遍缓存，就得到九份
/// 各自演化的失效规则；而失效规则一旦分叉，症状是「同一个账号在手机上看到
/// 新的、在浏览器里看到旧的」，那是最难定位的一类不一致。
///
/// 写路径（POST）的规则只有一条：**成功即整体作废**。已核对过全部 POST 端点，
/// **它们都是写**（create / update / insert / delete / upsert / earn / redeem /
/// confirm / archive / status / invite / read / logout）—— 没有「用 POST 表达的读」，
/// 所以这条规则不会误伤。
class DataApiClient {
  DataApiClient({
    required this.config,
    SessionStore? session,
    http.Client? httpClient,
    DateTime Function()? now,
    this.cache,
    this.endpoint,
    this.cacheTtl = const Duration(seconds: 15),
    this.bootstrapPrefetch = false,
  })  : session = session ?? createSessionStore(),
        _http = httpClient ?? http.Client(),
        _now = now ?? DateTime.now;

  final DataConfig config;

  /// 多地址择优（家里局域网 / Tailscale）。
  ///
  /// 为 null 时行为与本轮之前**逐字相同**：所有请求都发往 [config.baseUrl]。
  /// 纯本地模式、以及全部既有测试走的都是这条。
  final EndpointResolver? endpoint;
  final SessionStore session;
  final http.Client _http;
  final DateTime Function() _now;

  /// 读缓存。为 null 时行为与本轮之前**完全一致**（每次读都打网络）——
  /// 这是本地模式与全部既有测试所走的那条路。
  final ReadCache? cache;

  /// 首屏聚合预热（P2-2）。**默认关**，由装配点显式打开（见 `CloudRuntime`）。
  ///
  /// ## 为什么默认关，而不是默认开
  ///
  /// 打开它意味着「第一次读落空时会**额外**发一次 `GET /data/bootstrap`」。
  /// 对真实的 App 那是这笔买卖的全部意义（18 次往返变 1 次），
  /// 但对**单元测试构造的 client** 来说，它是一次谁都没想到的请求 ——
  /// 会打乱「数请求次数」这类断言，而失败信息指向的是被测代码。
  ///
  /// 所以它是一个**装配点的决定**，与「有没有读缓存」同一层：
  /// `CloudRuntime` 是唯一的装配点，它打开它；
  /// 需要精确控制请求的测试显式关着（默认值就是关）。
  ///
  /// ⚠️ 它**不是数据通路**。聚合失败、服务端没有这条路由、段名对不上 ——
  /// 任何一种情况都只是退回「逐条读」，也就是这个开关出现之前的行为。
  /// 所以这里没有「依赖它」的代码，只有「占它便宜」的代码。
  final bool bootstrapPrefetch;

  /// 「新鲜」的判定窗口。
  ///
  /// 它挡的**不是数据的保鲜期**，而是**同一屏内对同一份数据的重复读**：
  /// 进一次首页会连着读作业、照片、心愿、计划、错题……其中若干次是同一个
  /// 端点；窗口内直接用缓存，窗口外先给缓存再后台刷新。
  ///
  /// 之所以不做成「越长越省」：这个窗口同时也是**跨设备陈旧窗口** ——
  /// 家长端那台设备能看到的「孩子刚交的作业」，最晚就是这个时长之后。
  /// 15 秒是「演示时看不出来、真实使用也够短」的那个位置。
  final Duration cacheTtl;

  /// 正在飞的那一次聚合。**同一个 Future 交给所有等待者**。
  ///
  /// 首页那十几次读是并发来的（`ReviewController` 与 `StudentController` 各自
  /// `onInit`），没有它就等于「每个人都去拉一次聚合」—— 18 次往返换成 18 次聚合，
  /// 比不做还差。这与缩略图那次的死锁教训是同一个形状的两面：
  /// 那里是**等自己**（`whenComplete` 自等待），这里是**等别人**，
  /// 两处都必须固定成同一个 Future 实例。
  Future<void>? _bootstrapInFlight;

  /// 已经为哪一个**缓存世代**做过聚合。`invalidateAll` 会让世代 +1，
  /// 于是「写完之后的第一读」会重新聚合一次 —— 那是**想要的**：
  /// 写把缓存清空了，此时用一次聚合重新铺满，比让接下来十几次读各打一次网络划算。
  int? _bootstrappedGeneration;

  BootstrapPrefetchStats _bootstrapStats = const BootstrapPrefetchStats();

  /// 见 [BootstrapPrefetchStats]。
  BootstrapPrefetchStats get bootstrapStats => _bootstrapStats;

  /// 现在该不该（发起或等待）聚合。
  ///
  /// ⚠️ 「有在飞的 → 等它」这一条**不能省**，写成「只有这个世代没拉过才进」
  /// 会得到一个很难发现的退化：`_prefetch` 在**发请求之前**就把
  /// `_bootstrappedGeneration` 置上了（必须如此，否则失败后每次读都重试），
  /// 于是**并发来的第二个读**会看到「这个世代拉过了」而跳过等待，
  /// 直接自己去打网络 —— 聚合把 18 次往返省成 1 次，这一处又把它加回 17 次。
  ///
  /// 它只在**并发**下发生：本机顺序读（相邻两次读之间隔着一个 await 链）
  /// 通常躲得过去，而首页恰恰是两个控制器各自 `onInit` 一起读。
  /// `test/bootstrap_prefetch_test.dart` 的「并发来的读共用一次聚合」就是它。
  bool get _shouldPrefetch {
    final c = cache;
    if (!bootstrapPrefetch || c == null) return false;
    if (!isAuthenticated) return false;
    // 有人在拉 = 这一次读应当**等它**，而不是另起一次或自己去取。
    if (_bootstrapInFlight != null) return true;
    return _bootstrappedGeneration != c.generation;
  }

  /// 当前用户 id。写端点靠它判断「这条数据属于谁」。
  String? get userId => session.userId;

  /// 当前角色（`student` / `parent`）。
  String? get role => session.role;

  bool get isAuthenticated => session.isAuthenticated;

  /// 关闭连接池。进程退出或切回本地实现时调用。
  void close() => _http.close();

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, Object?>? query,
  }) =>
      _readWithCache(path, query);

  Future<Map<String, dynamic>> postJson(
    String path, {
    Object? body,
    String? authToken,
    Duration? timeout,
  }) async {
    try {
      final data = await _send(
        'POST',
        path,
        body: body ?? const <String, Object?>{},
        authToken: authToken,
        timeout: timeout,
      );
      // 写成功 → 读缓存**整体作废**。放在这里而不是让调用方记得清：
      // 九个仓库几十个调用点，漏掉任何一处，症状都是
      // 「刚改完，看到的还是改之前的」—— 而它看起来像缓存没生效，
      // 实际是那次写没通知缓存。
      //
      // 不 await：作废是内存操作，而调用方关心的是写有没有成功。
      // 等它反而会让一次写多付一次落盘时间（见 ReadCache.flush 的延迟合并）。
      final readCache = cache;
      if (readCache != null) unawaited(readCache.invalidateAll());
      return data;
    } on DataApiException catch (e) {
      if (e.isOffline) {
        // 方案 B 的「写必须在线」在这里落地：写失败**不落本地、不排队重试**，
        // 但要留下一个能被读到的信号。
        //
        // 没有它的话，「写必须在线」会退化成「写悄悄丢了」—— 控制器里的写
        // 路径全是 `catch (_)`，用户看到的是一次**看起来成功**的提交，
        // 而这份作业在服务端根本不存在。
        //
        // 只上报离线这一类：非离线的写失败（400 / 403）是业务与权限问题，
        // 文案各异且需要调用方决策，塞进一个全局横幅只会把真正的原因盖掉。
        DataStalenessLog.add(DataStaleness(
          kind: DataStalenessKind.writeDropped,
          // 同 `_reportStaleRead`：`userMessage` 而不是 `message`。
          reason: '${e.userMessage}，这次修改没有保存到云端。',
          at: _now(),
        ));
      }
      rethrow;
    }
  }

  /// 更新一个已有资源（目前只有 `PUT /data/word/scope` 用）。
  ///
  /// 与 [postJson] 同口径：写成功后整体作废读缓存，否则「刚改完范围、
  /// 下一秒读到的还是上一本书」会看起来像家长没点到保存。
  /// 不重试 —— `_send` 只对 GET 重试，写的盲重试会插出两条记录。
  Future<Map<String, dynamic>> putJson(
    String path, {
    Object? body,
    Duration? timeout,
  }) async {
    final data = await _send(
      'PUT',
      path,
      body: body ?? const <String, Object?>{},
      timeout: timeout,
    );
    final readCache = cache;
    if (readCache != null) unawaited(readCache.invalidateAll());
    return data;
  }

  /// 取列表端点的 `data.items`。
  ///
  /// 单拎出来是因为它在服务端是**统一形状**（见 `src/routes/*.js`：
  /// 每个 list 都返回 `{items}`）—— 而客户端有九个仓库要读它，
  /// 每处各写一遍 `data['items'] as List` 就等于把那句类型转换抄九遍，
  /// 其中八处会忘掉 `?? const []` 然后在一个空列表上炸。
  Future<List<Map<String, dynamic>>> getItems(
    String path, {
    Map<String, Object?>? query,
  }) async {
    final data = await getJson(path, query: query);
    final raw = data['items'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map(Map<String, dynamic>.from).toList();
  }

  /// 读的四种走法。**这是方案 B 的全部规则**。
  ///
  /// | 状态 | 行为 |
  /// |---|---|
  /// | 命中且新鲜 | 直接给缓存，**不打网络** |
  /// | 命中但过期 | **先给缓存**，同时后台刷新换新的 |
  /// | 未命中 | 走网络，成功则写入缓存 |
  /// | 未命中且离线 | 如实抛错（没有东西可给，编一个比报错更坏） |
  ///
  /// 「命中但过期」这一支是**断网可用的全部来源**：它先把手里的东西交出去，
  /// 再尝试更新。刷新失败不改变已经返回的结果 —— 于是断网时用户看到的
  /// 是上一次同步下来的内容，而不是一个空列表。代价是这份内容必须**可见地
  /// 标注为旧**（见 `DataStalenessLog`），否则它和实时数据长得一模一样。
  ///
  /// ## 聚合预热插在哪一步，以及为什么是这一步
  ///
  /// 插在「**第一次落空**」：先照常查缓存，落空且这个世代还没聚合过，
  /// 就先拉一次 `/data/bootstrap` 把各段铺进缓存，然后再看一眼。
  ///
  /// 这个位置是刻意的，换成别处都不行：
  ///   · 放在 `main()` 里（启动时预拉）—— 那时还不知道用户会打开哪一屏，
  ///     也不知道他的身份，等于替一个可能不存在的页面付一次请求；
  ///   · 放在登录成功之后 —— 「登录」有七八条路径（手机号 / 微信 / 短信 /
  ///     会话恢复），漏掉任何一条都表现为「有时候快、有时候慢」；
  ///   · 放在**第一个读**里 —— 读路径只有一条，且它天然知道「这次真的要读数据」。
  ///
  /// 落空时先补齐、再重新查一次，而不是「聚合里直接挑出这一段返回」：
  /// 后者会让读路径长出第二条返回通道（一段来自聚合、一段来自单端点），
  /// 而两条通道的数据形状迟早会分叉。现在的写法**只有一条数据通道**
  /// （缓存 → 否则单端点），聚合只是**提前把缓存铺好**。
  Future<Map<String, dynamic>> _readWithCache(
    String path,
    Map<String, Object?>? query,
  ) async {
    final cache = this.cache;
    final key = cache == null ? null : _cacheKey(path, query);

    // 两个「不走缓存」的条件，理由不同：
    // - 没装配缓存（本地模式）：行为必须与之前一字不差。
    // - 拿不到可信身份：缓存键里**必须**带身份（见 [_cacheKey]），
    //   拿不到就不能缓存 —— 宁可不缓存，也不能把上一个人的数据给下一个人。
    if (cache == null || key == null) return _send('GET', path, query: query);

    var hit = _takeHit(cache, key, path, query);
    if (hit == null && _shouldPrefetch) {
      await _ensurePrefetch();
      hit = _takeHit(cache, key, path, query);
    }
    if (hit != null) return hit;

    try {
      final data = await _send('GET', path, query: query);
      await cache.store(key, data);
      return data;
    } on DataApiException catch (e) {
      if (e.isOffline) _reportStaleRead(e, path);
      rethrow;
    }
  }

  /// 取一次命中。返回 null 表示**未命中**（或缓存里的那条产生于某次写之前），
  /// 调用方应当走网络。
  ///
  /// 抽出来是因为它现在有**两个**调用点：聚合之前、聚合之后。
  /// 抄一份的代价是两处的 freshness 判定会漂 —— 而漂的表现是
  /// 「聚合之后明明铺好了，这次读却还是打了网络」，正好把这个优化的收益吃掉。
  Map<String, dynamic>? _takeHit(
    ReadCache cache,
    String key,
    String path,
    Map<String, Object?>? query,
  ) {
    final hit = cache.lookup(key);
    // 世代不符 = 这条缓存产生于某次写操作之前，但活过了那次作废
    // （只有「取出来之后、用之前恰好发生了写」这个极短窗口能做到）。
    // 当作未命中处理，而不是当作过期 —— 过期的东西还可能有用，
    // 而写之前的状态**已经在服务端不存在了**。
    if (hit == null || hit.generation != cache.generation) return null;
    if (hit.isFreshAt(_now(), cacheTtl)) {
      cache.noteFresh();
      return hit.data;
    }
    cache.noteStale();
    _revalidate(key, path, query, hit.generation);
    return hit.data;
  }

  /// 保证这一次聚合**只发一次**，且所有等到它的人共用同一个 Future。
  ///
  /// 见 [_bootstrapInFlight] 的说明：并发来的读必须等同一个，而不是各拉一次。
  Future<void> _ensurePrefetch() async {
    final inFlight = _bootstrapInFlight;
    if (inFlight != null) return inFlight;
    // 先置位再 await，否则并发的第二次调用会在第一个 Future 完成之前
    // 又走一遍下面这段 —— 那正是「并发变成多次请求」的写法。
    final run = _prefetch();
    _bootstrapInFlight = run;
    try {
      await run;
    } finally {
      _bootstrapInFlight = null;
    }
  }

  /// 拉一次聚合，按段写进读缓存。
  ///
  /// ## 为什么这里**不**抛异常
  ///
  /// 聚合是**加速手段**。它失败的时刻恰恰是最不该被它连累的时刻 ——
  /// 服务端还没部署这条路由（旧版本）、某台机器上路由被关掉、
  /// 请求超时……这些情况下正确的行为都是「那就逐条读」，也就是
  /// 这个优化出现之前的行为。抛出去会把一次本来能成功的读变成失败。
  ///
  /// 但**不能静默**：失败原因与段级失败都记进 [bootstrapStats]，
  /// 并且打一行日志。少了这一步，「聚合一直没生效」这件事在界面上
  /// 与「聚合正常工作」完全一样 —— 只是首页每次多打十几次网络。
  Future<void> _prefetch() async {
    final cache = this.cache;
    if (cache == null) return;

    final generationAtStart = cache.generation;
    // 先记「这个世代做过了」。放在**请求之前**：失败时也算了过一次 ——
    // 否则每次读落空都会再撞一次那个坏掉的端点，18 次读变成 18 次失败请求。
    _bootstrappedGeneration = generationAtStart;
    _bootstrapStats = _bootstrapStats.copyWith(attempts: _bootstrapStats.attempts + 1);

    Map<String, dynamic> data;
    try {
      // 刻意走 `_send` 而不是 `getJson`：聚合响应本身**不进缓存**
      // （它比 `maxEntryBytes` 大，写进去只会白占一条被拒的记录），
      // 要进缓存的是它拆开后的各段。
      data = await _send('GET', kBootstrapPath);
    } on DataApiException catch (e) {
      _bootstrapStats = _bootstrapStats.copyWith(lastError: e.code);
      debugPrint('首屏聚合预热未生效（${e.code}）：$e —— 退回逐条读，行为与之前一致');
      return;
    }

    final seeded = await _seed(cache, data, generationAtStart);
    _bootstrapStats = _bootstrapStats.copyWith(seeded: seeded);
    if (seeded < kBootstrapSections.length) {
      // 「写进去的段数比表里的少」有两种原因，都必须能看见：
      // 服务端报了失败段（`failed`），或者某一段大过 `maxEntryBytes` 被拒收。
      // 两种情况的表现都是「那一段多打一次网络」，而它不会报错。
      debugPrint(
        '首屏聚合预热只写了 $seeded/${kBootstrapSections.length} 段'
        '（失败段 ${_bootstrapStats.failedSections}、被拒收 ${_bootstrapStats.rejected}）',
      );
    }
  }

  /// 把聚合响应拆成各段，按**客户端自己的**键规则写进缓存。
  ///
  /// 键由 [_cacheKey] 现算，而不是在这里另拼一套 —— 那是这个优化唯一
  /// 会**静默失效**的地方：两边差一个字符，读就落空，而界面上什么都看不出来。
  /// 所以这里也用 [_cacheKey]，与读路径共用同一个实现。
  ///
  /// 返回**真的写进缓存的段数**。
  Future<int> _seed(
    ReadCache cache,
    Map<String, dynamic> data,
    int generationAtStart,
  ) async {
    final sections = data['sections'];
    if (sections is! Map) {
      _bootstrapStats = _bootstrapStats.copyWith(lastError: 'bad_response');
      return 0;
    }

    // 服务端如实上报的失败段（`failed`）。**照常数出来**，因为「哪一段在失败」
    // 是排查的第一句话 —— 而它在客户端这边不留痕的话，服务端日志里也
    // 只有一行 console.error，两边都对不上。
    final failed = data['failed'];
    _bootstrapStats = _bootstrapStats.copyWith(
      failedSections: failed is List ? failed.length : 0,
    );

    var written = 0;
    var rejected = 0;

    /// 写一段。返回是否真的进去了。
    ///
    /// ⚠️ 「真的进去了没有」只能靠 `stats.rejected` 有没有涨来判断：
    /// `ReadCache.store` 在一条太大时**静默不收**（缓存是尽力而为的，不是数据
    /// 通路），而它没有返回值。给 `store` 加一个返回值会更直接，但那要动
    /// 三个平台实现与 `ReadCache` 的抽象 —— 而 `rejected` 这个计数**本来就是
    /// 为这件事记的**（见 `ReadCacheStats.rejected` 的注释），这里只是把它读出来。
    Future<bool> write(
      String path,
      Map<String, Object?>? query,
      Object? items,
    ) async {
      if (items is! List) return false;
      // 世代变了 = 中间发生过一次写操作，缓存已被整体作废。
      // 此刻照写不误会把**写之前**的数据重新铺回去，于是
      // 「刚改完刷新一下又变回去了」—— 与 `_revalidate` 里那条世代校验
      // 是同一个不变量，理由见 `ReadCache.generation`。
      if (cache.generation != generationAtStart) return false;
      final key = _cacheKey(path, query);
      if (key == null) return false;
      final beforeRejected = cache.stats.rejected;
      await cache.store(key, <String, dynamic>{'items': items});
      if (cache.stats.rejected > beforeRejected) {
        rejected += 1;
        return false;
      }
      written += 1;
      return true;
    }

    for (final section in kBootstrapSections) {
      final raw = sections[section.name];
      if (raw is! Map) continue;

      switch (section.scope) {
        case BootstrapScope.broad:
          if (raw['ok'] != true) continue;
          await write(section.path, section.query, raw['items']);

        case BootstrapScope.perStudent:
          final byStudent = raw['byStudent'];
          if (byStudent is! Map) continue;
          for (final entry in byStudent.entries) {
            final sid = entry.key is String ? entry.key as String : '';
            final bucket = entry.value;
            if (bucket is! Map || bucket['ok'] != true) continue;
            final query = withStudentId(section.query, sid);
            if (query == null) continue;
            await write(section.path, query, bucket['items']);
          }

        case BootstrapScope.narrow:
          if (raw['ok'] != true) continue;
          final acting = data['actingStudentId'];
          final query = withStudentId(
            section.query,
            acting is String ? acting : '',
          );
          if (query == null) continue;
          await write(section.path, query, raw['items']);
      }
    }

    _bootstrapStats = _bootstrapStats.copyWith(rejected: rejected);
    return written;
  }

  /// 后台把过期的缓存换成新的。**不 await** —— 调用方已经拿到数据了。
  void _revalidate(
    String key,
    String path,
    Map<String, Object?>? query,
    int generationAtStart,
  ) {
    unawaited(() async {
      try {
        final data = await _send('GET', path, query: query);
        final cache = this.cache;
        if (cache == null) return;
        // **世代校验**，这是本文件里最重要的一行。
        //
        // 时序：t0 读到过期缓存并发出本次刷新 → t1 用户写操作成功、缓存被作废
        // → t2 本次刷新才返回，内容是**写之前**的旧数据 → 若照写不误，
        // 缓存里就躺着写之前的状态，而下一次读会命中它。
        //
        // 症状是「改完了，刷新一下又变回去了」—— 而且只在慢网络下出现
        // （本机演示时 t0→t2 只有几毫秒，写操作插不进去），
        // 所以它不可能靠手测发现，只能靠这个不变量挡住。
        if (cache.generation != generationAtStart) return;
        await cache.store(key, data);
      } on DataApiException catch (e) {
        if (e.isOffline) _reportStaleRead(e, path);
      } catch (_) {
        // 后台刷新失败**不打扰任何人**：用户手里已经有数据了。
        // 非离线的失败（例如这一瞬间 token 过期）会在下一次前台请求上
        // 如实暴露出来，不需要在这里抢答。
      }
    }());
  }

  void _reportStaleRead(DataApiException e, String path) {
    DataStalenessLog.add(DataStaleness(
      kind: DataStalenessKind.staleRead,
      // ⚠️ 用 `userMessage` 而**不是** `message`：后者带 URL 与
      // `ClientException: …` 原文，拼进横幅就是往用户脸上糊一串英文。
      // 判据见 `test/data_api_retry_test.dart` 的「横幅文案不出现底层异常」。
      reason: '${e.userMessage}，界面显示的是上一次同步下来的内容。',
      at: _now(),
    ));
  }

  /// 缓存的键。**必须带身份**，这是它唯一不能省的成分。
  ///
  /// 不带身份的后果很具体：同一台设备上换账号（孩子用自己的号、家长用他的号
  /// 看同一个首页），第二个账号会**直接命中第一个账号的缓存** ——
  /// 于是家长看到的是用自己 ID 读回来的孩子的作业，而这份数据是
  /// 上一个登录者留下的。它看起来完全正常，只是数字不对。
  ///
  /// 参数要**规范化**（丢空值、按键排序）后再拼：`?a=1&b=2` 与 `?b=2&a=1`
  /// 是同一个请求，而它们会算出两个不同的键 —— 结果是同一份数据被缓存两遍，
  /// 并且两遍的过期时间不同（于是「有时刷新有时不刷新」）。
  ///
  /// 找不到身份时返回 null（不缓存）。未登录的读本来就会被服务端拒掉。
  String? _cacheKey(String path, Map<String, Object?>? query) {
    // 认证端点**永远不缓存**。
    //
    // `/auth/me` 的语义是「这个 token 现在还作数吗」—— 它是一次**验证**。
    // 用缓存回答一个验证问题，等于没验证：一个已被服务端吊销的 token
    // 会让用户进入「已登录」状态，直到第一次真正的业务请求失败。
    // 而这恰好发生在冷启动那一瞬间，表现是「打开了首页，然后被弹回登录页」。
    if (!path.startsWith('/data/')) return null;

    final uid = userId;
    if (uid == null || uid.isEmpty) return null;

    final params = <String, String>{
      for (final e in (query ?? const <String, Object?>{}).entries)
        if (e.value != null && e.value.toString().isNotEmpty)
          e.key: e.value.toString(),
    };
    final keys = params.keys.toList()..sort();
    final qs = keys.map((k) => '$k=${params[k]}').join('&');
    return '$uid|GET $path${qs.isEmpty ? '' : '?$qs'}';
  }

  /// 拼 URL（含查询串）。
  ///
  /// 空值参数会被**丢掉**而不是拼成 `?id=`：服务端对「空字符串」与「没传」
  /// 的处理常常不同（前者是一个值，后者是缺省），拼上去等于替调用方
  /// 做了一个它没做的选择。
  /// 当前实际发往的基地址。
  ///
  /// 探测还没选出来时退回 [DataConfig.baseUrl]（首选）—— 那是「探测失败」
  /// 与「只有单地址」的共同落点，业务请求会照常失败并报错，
  /// 而不是因为拿不到地址就静默不发。
  String get activeBaseUrl => endpoint?.active ?? config.baseUrl;

  Uri _uriFor(String path, Map<String, Object?>? query) {
    final base = joinUrlPath(activeBaseUrl, path);
    return Uri.parse(base).replace(
      queryParameters: query == null
          ? null
          : {
              for (final e in query.entries)
                if (e.value != null && e.value.toString().isNotEmpty)
                  e.key: e.value.toString(),
            },
    );
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Object? body,
    Map<String, Object?>? query,
    String? authToken,
    /// 单次请求的超时。默认用 `config.requestTimeout`（12 秒）。
    ///
    /// 存在的理由只有一个：**有些端点本身就要等模型**。每日打卡出题在服务端
    /// 走「查错题 → 调网关 → 落库」，冷启动实测 5 秒上下、缓存命中 0.1 秒。
    /// 12 秒不够时客户端先断开，而服务端还在跑并**已经把题存好了** ——
    /// 用户看到失败、点重试，于是又生成一遍覆盖。慢一点可以等，
    /// 「明明成功却报失败」不行。
    Duration? timeout,
  }) async {
    /// 默认用会话里那一份；[authToken] 是**显式指定本次凭证**的逃生口。
    ///
    /// 目前只有登出用它：登出必须在发出「吊销这个会话」的请求之前先把本地凭证抹掉
    /// （否则一次失败的登出会把用户永久留在登录态），而抹掉之后默认取值就成了空 ——
    /// 于是那条请求变成未认证，服务端不知道该吊销谁。详见 `HttpAuthApi.logout`。
    final token = authToken ?? session.token;
    final headers = <String, String>{
      'accept': 'application/json',
      if (body != null) 'content-type': 'application/json',
      if (token != null && token.isNotEmpty) 'authorization': 'Bearer $token',
    };

    // ── 重试几次 ────────────────────────────────────────────────────────────
    //
    // GET 是幂等的，所以「连接被掐断」这类**瞬时**失败可以重试一次。
    //
    // ## 为什么只重试 GET
    //
    // POST 在本文件里**全部是写**（见类注释：没有「用 POST 表达的读」）。
    // 盲重试的后果不是多一次往返，而是「其实成功了但响应没回来」那一次
    // 变成**两条记录** —— 运动记录、打卡这类都按天去重，插出两条等于
    // 把「今天跑了几次」改掉（`test/workout_idempotency_test.dart` 钉的就是它）。
    //
    // ## 为什么只重试 network、不重试 timeout
    //
    // 两者性质相反，合并处理是错的：
    //   · `network`（连接被掐断 / 被重置）：那条连接**已经没了**，重试会新建
    //     一条，几乎必然成功。实测（`build/probe-concurrency-scan.mjs` 对云端
    //     真打 186 次）失败只出现在「复用连接 + 并发 ≥8」那一格，全部是这一类；
    //     而**每次新建连接**那一组 93 次全过。
    //   · `timeout`（服务端慢）：重试大概率还是慢，而用户已经多等了一个
    //     超时周期（10 秒 → 20 秒）。那是服务端的问题，不该由客户端用
    //     **加倍等待**去掩盖 —— 把「慢」变成长得多的「慢」，比如实失败更坏。
    //
    // ## 不需要「把坏连接踢掉」
    //
    // `HttpClient` 在请求失败后**不会**把那条连接归还池子，所以下一次
    // 尝试天然是新连接。这会话里不必再手工干预连接池。
    final attempts = method == 'GET' ? 2 : 1;

    // 动词校验放在循环外：写错动词是**编码错误**，不该落进下面那个
    // `catch (e)` 被转成「连不上数据服务」——那会让人去查网络。
    if (method != 'GET' && method != 'POST' && method != 'PUT') {
      throw ArgumentError.value(
        method,
        'method',
        '未支持的请求方法（只有 GET / POST / PUT）',
      );
    }

    late http.Response response;
    late Uri uri;
    // 本次请求的等待上限。**在循环外算一次**：重试不该改变「愿意等多久」，
    // 否则两次重试叠起来等于把超时放大一倍。
    final limit = timeout ?? config.requestTimeout;
    // 因「换了地址」而重试最多一次。不加这个计数的话，两个候选都不通时
    // 会 A→B→A→B 无限循环，而用户看到的是永远转圈。
    var switchedEndpoint = false;

    for (var attempt = 1;; attempt++) {
      // ⚠️ 每轮重算：上一轮可能刚把地址切走。
      uri = _uriFor(path, query);
      try {
        // ⚠️ 这里是**唯一**把 [method] 变成真 HTTP 动词的地方。
        //
        // 曾经写成「GET 走 get，其余一律 post」，而 [method] 只被用在
        // 「重试几次 / 换不换地址」两个判断里 —— 于是 `putJson('PUT')`
        // 在网线上发出去的是 **POST**。服务端路由只注册了
        // `PUT /data/word/scope` ⇒ 405 ⇒ 家长端「保存没成功」，而客户端
        // 代码看着完全正确、日志里也确实发了请求。
        //
        // 这类错抓不住的原因是两边各自都没错：服务端探针自己拼的 PUT（对），
        // 客户端单测用假 client 只断返回值（不关心动词）。错在接缝。
        // 判据：`test/data_api_verb_test.dart` 盯发出去的报文。
        final request = switch (method) {
          'GET' => _http.get(uri, headers: headers),
          'POST' => _http.post(uri, headers: headers, body: jsonEncode(body)),
          'PUT' => _http.put(uri, headers: headers, body: jsonEncode(body)),
          _ => throw ArgumentError.value(
              method,
              'method',
              '未支持的请求方法（只有 GET / POST / PUT）',
            ),
        };
        response = await request.timeout(limit);
        break;
      } on TimeoutException {
        throw DataApiException(
          code: 'timeout',
          message: '数据服务 ${limit.inSeconds} 秒没有响应（$uri）',
        );
      } catch (e) {
        if (attempt < attempts) {
          // 看得见才叫重试：不打这行的话，「重试救回来了」在日志里与
          // 「本来就没事」完全一样，而那正是判断要不要继续加次数时的依据。
          debugPrint('数据服务请求被中断，重试（$uri）：$e');
          continue;
        }

        // 原来的地址连不上 ⇒ 有可能只是「换了网络」（出门 / 回家）。
        // 换一个候选再试一次。
        //
        // ⚠️ **只对 GET**：POST 在本文件里全部是写（见类注释），
        // 而「其实成功了但响应没回来」重试一次就是两条记录。
        // 让 POST 直接失败，下一个请求自然会用新地址。
        if (!switchedEndpoint &&
            method == 'GET' &&
            endpoint != null &&
            await endpoint!.onNetworkFailure()) {
          switchedEndpoint = true;
          attempt = 0;
          continue;
        }

        // 连不上 ≠ 被拒绝。分开的理由见 [DataApiException.isOffline]。
        throw DataApiException(code: 'network', message: '连不上数据服务（$uri）：$e');
      }
    }

    return _unwrap(response, uri);
  }

  /// 拆信封：成功给 `data`，失败抛 [DataApiException]。
  ///
  /// 单拎出来的理由是它现在有**两个**调用方：JSON 那条路（[_send]），
  /// 以及照片上传（请求体是原始字节，响应仍然是信封）。抄一份的代价
  /// 不是多几行，而是**同一个失败在两处被解析成不同的东西**。
  Future<Map<String, dynamic>> _unwrap(http.Response response, Uri uri) async {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw DataApiException(
        code: 'bad_response',
        message: '数据服务返回的不是 JSON（HTTP ${response.statusCode}）',
        status: response.statusCode,
      );
    }
    if (decoded is! Map) {
      throw DataApiException(
        code: 'bad_response',
        message: '数据服务的响应不是对象（HTTP ${response.statusCode}）',
        status: response.statusCode,
      );
    }

    final json = Map<String, dynamic>.from(decoded);
    if (json['ok'] == true) {
      final data = json['data'];
      return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    }

    final error = json['error'];
    final err = error is Map ? Map<String, dynamic>.from(error) : const <String, dynamic>{};
    final rawDetails = err['details'];
    final exception = DataApiException(
      code: (err['code'] as String?) ?? 'internal',
      message: (err['message'] as String?) ?? '数据服务返回了失败（HTTP ${response.statusCode}）',
      status: response.statusCode,
      requestId: err['requestId'] as String?,
      retryable: err['retryable'] == true,
      // `details` 原样带出来：照片那条路靠它区分「旧数据要回退本地读」
      // 与「文件真没了」。丢掉它，两种情形在客户端就只剩一个 404。
      details: rawDetails is Map ? Map<String, dynamic>.from(rawDetails) : null,
    );

    // 凭证已经不可用了：**顺手清掉**。
    //
    // 不清的后果是每次冷启动都会拿同一个坏 token 去撞一遍，界面反复闪一次
    // 「加载失败」——而它其实只需要去登录页。清掉之后，下一次进首页时
    // `AuthController` 会看到「没有身份」，走的就是登录页那条正常路径。
    if (exception.needsReLogin) {
      await session.clear();
      // 凭证没了，缓存里那份是按**上一个身份**存的，也跟着作废。
      // 不清的后果：下一个登录者用同一个 userId 看到别人留下的数字
      // （同一台设备上家长和孩子轮流登录时真的会发生）。
      await cache?.clear();
    }
    throw exception;
  }

  /// 上传**原始字节**。
  ///
  /// 为什么不复用 [_send]：那个方法把请求体 `jsonEncode`、且假定响应一定是
  /// JSON 信封。照片这条路请求体是图片本身 —— 走 base64 会让链路上凭空胖
  /// 三分之一、两端各多一次编解码，而编解码正是把二进制弄坏的最常见入口。
  /// 响应**仍然**是信封（服务端回 `storageKey`），所以收尾照样走 [_unwrap]。
  Future<Map<String, dynamic>> uploadBytes(
    String path, {
    required Uint8List bytes,
    required String contentType,
    Map<String, Object?>? query,
  }) async {
    final uri = _uriFor(path, query);
    final token = session.token;
    http.Response response;
    try {
      response = await _http
          .post(
            uri,
            headers: {
              'accept': 'application/json',
              'content-type': contentType,
              if (token != null && token.isNotEmpty) 'authorization': 'Bearer $token',
            },
            body: bytes,
          )
          .timeout(config.imageTimeout);
    } on TimeoutException {
      throw DataApiException(
        code: 'timeout',
        message: '上传照片超时（${config.imageTimeout.inSeconds} 秒，$uri）',
      );
    } catch (e) {
      throw DataApiException(code: 'network', message: '上传照片时连不上数据服务（$uri）：$e');
    }
    return _unwrap(response, uri);
  }

  /// 把字节 **PUT 到一个绝对 URL**（对象存储预签名直传）。
  ///
  /// ## 为什么它不在 `_uriFor` 那套里
  ///
  /// 本类其余方法都发往数据服务（相对路径 + `baseUrl` + 会话 token）。
  /// 直传的目标是**对象存储的绝对地址**，鉴权来自服务端签好的 header，
  /// 与会话 token 无关 —— 硬塞进 `_send` 只会让「URL 从哪来」「谁鉴权」
  /// 两件事同时变得不清楚。
  ///
  /// ## headers 必须原样发
  ///
  /// OSS V4 把 `content-type`、`host`、`x-oss-*` 一并纳入签名。少一个、
  /// 改一个，回的都是 `SignatureDoesNotMatch` —— 而那个错误看起来像
  /// 「密钥配错了」，与「客户端偷偷换了个头」毫无关联。所以这里**一个头
  /// 都不挑**，整份透传。
  ///
  /// ## 非 2xx 要把响应体带出来
  ///
  /// OSS 的失败原因在 XML 里（`NoSuchBucket` / `AccessDenied` /
  /// `SignatureDoesNotMatch`），只报状态码等于把唯一有用的信息丢掉。
  /// 2026-10-03 那个 `NoSuchBucket`（桶名没写进子域）就是靠它定位的。
  Future<void> putToAbsoluteUrl(
    String url, {
    required Uint8List bytes,
    required Map<String, String> headers,
    Duration? timeout,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      throw DataApiException(
        code: 'bad_response',
        message: '直传地址不是合法 URL：$url',
      );
    }
    final limit = timeout ?? config.imageTimeout;
    http.Response response;
    try {
      response = await _http
          .put(uri, headers: headers, body: bytes)
          .timeout(limit);
    } on TimeoutException {
      // ⚠️ 这条路是大文件（视频上限 100MB、超时 12 分钟）专用，
      // 文案必须说清「该怎么办」，还要能读 —— 「720 秒」没人知道是多久。
      throw DataApiException(
        code: 'timeout',
        message:
            '附件太大或网络太慢，${_humanTimeout(limit)}内没传完；'
            '建议换个网络（如 Wi-Fi）或压缩文件后重试',
      );
    } catch (e) {
      // 直传中断时底层异常是一串英文（ClientException…），不该糊给学生；
      // 但排查时要它 —— 放进 details，与展示文案分开。
      throw DataApiException(
        code: 'network',
        message: '上传附件时网络中断，请检查网络后重试',
        details: {'error': '$e'},
      );
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw DataApiException(
      code: 'upload_failed',
      status: response.statusCode,
      message:
          '对象存储拒绝了这次上传（HTTP ${response.statusCode}）：'
          '${_briefBody(response.body)}',
    );
  }

  /// 把超时时长说成人话（「12 分钟」而不是「720 秒」）—— 只给直传超时的
  /// 展示文案用。超时低于 1 分钟时按秒说（那些场景没有分钟可提）。
  static String _humanTimeout(Duration limit) => limit.inMinutes >= 1
      ? '${limit.inMinutes} 分钟'
      : '${limit.inSeconds} 秒';

  /// 把一段响应体压成一行、截断 —— 只用于错误提示。
  ///
  /// OSS 的失败 XML 里有换行与缩进，原样塞进 snackbar 会撑成一片乱码；
  /// 而 `NoSuchBucket` 这类关键字往往在**最后**，所以截断只截尾巴前 300 字符。
  static String _briefBody(String body) {
    final text = body.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty) return '（响应为空）';
    return text.length <= 300 ? text : '${text.substring(0, 300)}…';
  }

  /// 下载照片字节。
  ///
  /// 与 [uploadBytes] 对称：**成功时响应不是 JSON**，所以本类那套
  /// 「响应一定是信封」的假设在这里会把一张好好的图判成 `bad_response`。
  /// 失败时服务端回的反而是信封。于是按**状态码**分流：
  /// 200 给字节，其余交给 [_unwrap] 带出 `code` 与 `details`。
  ///
  /// 刻意不按 `content-type` 猜：猜错的表现是「图片被当成错误」或者
  /// 「错误被当成图片喂给图像解码器」，两种都很难从症状反推原因。
  Future<Uint8List> downloadBytes(
    String path, {
    Map<String, Object?>? query,
  }) async {
    final uri = _uriFor(path, query);
    final token = session.token;
    http.Response response;
    try {
      response = await _http
          .get(uri, headers: {
            'accept': 'image/*',
            if (token != null && token.isNotEmpty) 'authorization': 'Bearer $token',
          })
          .timeout(config.imageTimeout);
    } on TimeoutException {
      throw DataApiException(
        code: 'timeout',
        message: '读取照片超时（${config.imageTimeout.inSeconds} 秒，$uri）',
      );
    } catch (e) {
      throw DataApiException(code: 'network', message: '读取照片时连不上数据服务（$uri）：$e');
    }

    if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
      return response.bodyBytes;
    }
    // 非 200：一定是信封，交给它抛（`details.reason` 这样才能带出来）。
    await _unwrap(response, uri);
    // 走到这里说明服务端回了 `{ok:true}` —— 那不是照片。
    throw DataApiException(
      code: 'bad_response',
      message: '数据服务没有返回照片内容（HTTP ${response.statusCode}）',
      status: response.statusCode,
    );
  }

  /// 附件直读签发端点。**只有对象存储后端**回得出内容 —— `IMAGE_DRIVER=fs`
  /// 的部署会如实回 503 `upload_not_configured`，而不是给一个假地址。
  static const String signAttachmentReadPath = '/data/homework/images/sign-read';

  /// 签一个**客户端直读**的位置（大附件：视频）。
  ///
  /// ## 它与 [downloadBytes] 的分工
  ///
  /// 两者都能把字节取回来，差别在**经不经过函数**：函数计算的响应体上限是
  /// 32 MiB，而视频上限是 100 MB ⇒ 走 [downloadBytes] 的话，超过 32 MiB 的
  /// 视频**传得上去、取不回来**（见 `doc/open-items.md` B32）。
  /// 这条路让字节从对象存储**直接**到客户端，函数不经手，于是任意尺寸都行。
  ///
  /// 它还顺带解决了播放的两件事：可以**流式**播放（不用先整段下载进内存），
  /// 以及能拖动进度（播放器发的 Range 请求带着同一份签名也有效）。
  ///
  /// ## 回包与 [putToAbsoluteUrl] 的输入是同一种东西
  ///
  /// `{ readUrl, headers, expiresIn, mimeType }`，其中 `headers` 是签好的
  /// `x-oss-date` / `x-oss-content-sha256` / `authorization`。
  /// ⚠️ **一个头都不能挑、不能改** —— 理由与 [putToAbsoluteUrl] 逐字相同：
  /// 改动的表现是 `SignatureDoesNotMatch`，而那个错误看起来像密钥配错了。
  ///
  /// ⚠️ `expiresIn` 是凭证的有效秒数（OSS 的 15 分钟时钟窗，见服务端
  /// `OSS_V4_CLOCK_WINDOW_SECONDS`）。**它不是「这个 URL 能播多久」**：
  /// 慢到超过它的播放会中途 403，那种失败只能重新签一次，不能原地重试。
  ///
  /// ## 调用方必须准备兜底
  ///
  /// `IMAGE_DRIVER=fs` 的部署会抛 `upload_not_configured` —— 那不是故障，
  /// 而是「这条路在本部署上不存在」。调用方应当回落到 [downloadBytes]，
  /// 那才是功能上的正路（小附件本来就走得通）。
  Future<Map<String, dynamic>> signAttachmentRead(String id) {
    return _send('GET', signAttachmentReadPath, query: {'id': id});
  }

  @override
  String toString() =>
      'DataApiClient($activeBaseUrl${isAuthenticated ? ', 已登录 $userId' : ', 未登录'}, '
      'now=${_now().toIso8601String()}${cache == null ? '' : ', 带读缓存'})';
}
