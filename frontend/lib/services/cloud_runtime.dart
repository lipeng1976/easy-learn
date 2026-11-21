import 'dart:async';

import 'package:flutter/foundation.dart';

import 'data_api_client.dart';
import 'data_config.dart';
import 'endpoint_resolver.dart';
import 'http_auth_api.dart';
import 'http_focus_repository.dart';
import 'http_homework_repository.dart';
import 'http_checkin_repository.dart';
import 'http_reading_repository.dart';
import 'http_ima_repository.dart';
import 'http_notification_repository.dart';
import 'http_point_repository.dart';
import 'http_relationship_repository.dart';
import 'http_review_repository.dart';
import 'http_study_plan_repository.dart';
import 'http_user_repository.dart';
import 'http_wish_repository.dart';
import 'http_workout_repository.dart';
import 'read_cache.dart';

/// 一次装配好的云端数据环境。
///
/// 与 `AiRuntime` 是同构的东西，理由也一样：装配本身有几个步骤，
/// 而它们散在各处时就会长出「三个地方各自 new 一个 client」这种局面 ——
/// 每个 client 一个连接池、一套超时、一份 token 快照，于是「登录之后
/// 有的页面能读、有的页面还是 401」，而根因只是某处拿的是旧快照。
///
/// ## 它是唯一持有 token 的地方
///
/// 九个仓库共享同一个 [DataApiClient]、也就是共享同一份会话。
/// 这不是省内存，是为了让「登出」只需要清**一处** ——
/// 清九处的话，漏掉任何一处都会表现为「已经登出了，但某个页面还能读到数据」。
class CloudRuntime {
  factory CloudRuntime({
    required DataConfig config,
    DataApiClient? api,
    ReadCache? cache,
    EndpointResolver? endpoint,
  }) {
    // 候选地址只有**一个**时不建 resolver：省掉一次探测往返。
    // 这也是云版（单一地址）与全部既有测试走的路，行为与之前逐字相同。
    final resolver = endpoint ?? buildDataEndpoint(config);
    return CloudRuntime._(
      config: config,
      readCache: cache,
      endpoint: resolver,
      api: api ??
          DataApiClient(
            config: config,
            cache: cache,
            endpoint: resolver,
            // 首屏聚合预热（P2-2）。**只有在这里打开**，理由见
            // `DataApiClient.bootstrapPrefetch`：它是一次额外的请求，
            // 属于「这次装配要什么」而不是「传输层默认怎么干」。
            bootstrapPrefetch: true,
          ),
    );
  }

  CloudRuntime._({
    required this.config,
    required this.readCache,
    required this.endpoint,
    required this.api,
  }) {
    auth = HttpAuthApi(api);
    focus = HttpFocusRepository(api);
    homework = HttpHomeworkRepository(api);
    ima = HttpImaRepository(api);
    checkin = HttpCheckinRepository(api);
    reading = HttpReadingRepository(api);
    notifications = HttpNotificationRepository(api);
    points = HttpPointRepository(api);
    relationships = HttpRelationshipRepository(api);
    review = HttpReviewRepository(api);
    studyPlans = HttpStudyPlanRepository(api);
    users = HttpUserRepository(api);
    wishes = HttpWishRepository(api);
    workouts = HttpWorkoutRepository(api);
  }

  final DataConfig config;
  final DataApiClient api;

  /// 多地址择优；`null` = 只有一个地址（或纯本地），不需要选。
  final EndpointResolver? endpoint;

  /// 读缓存（迁移计划 §7 方案 B）。
  ///
  /// 为 null = **纯在线**，行为与本轮之前一字不差。
  ///
  /// 它同时被 [DataApiClient] 持有（那里才是真正用它的地方），这里再留一份
  /// 是因为**载入与落盘发生在传输层的生命周期之外**：载入要在第一次读之前
  /// （见 [initialize]），落盘要在进程退出时（见 [dispose]）。
  final ReadCache? readCache;

  late final HttpAuthApi auth;
  late final HttpFocusRepository focus;
  late final HttpHomeworkRepository homework;
  late final HttpImaRepository ima;

  /// 每日概念打卡：题目快照与作答结果（云端专属，本地模式不可用）。
  late final HttpCheckinRepository checkin;

  /// 英文阅读：书 / 任务 / 打卡（同样是云端专属 —— 家长与孩子是两个账号，
  /// 进度放本地各存一份就永远对不上）。
  late final HttpReadingRepository reading;
  late final HttpNotificationRepository notifications;
  late final HttpPointRepository points;
  late final HttpRelationshipRepository relationships;
  late final HttpReviewRepository review;
  late final HttpStudyPlanRepository studyPlans;
  late final HttpUserRepository users;
  late final HttpWishRepository wishes;
  late final HttpWorkoutRepository workouts;

  /// 数据面的地址选择器。候选少于两个时返回 `null`（没什么可选的）。
  ///
  /// 探测路径用 `/health`：那条端点在数据服务里**不鉴权、不查库**，
  /// 是最轻的一个「你在不在」的信号。
  static EndpointResolver? buildDataEndpoint(DataConfig config) {
    final candidates = config.candidateBaseUrls;
    if (candidates.length < 2) return null;
    return EndpointResolver(
      candidates: candidates,
      healthPath: '/health',
      expectedInstance: kServerInstanceId,
    );
  }

  /// 按编译期常量装配。**没配地址就返回 null**（纯本地）。
  ///
  /// 这里**不抛异常、不警告**：没配数据服务是「本地模式」这个合法状态的表达，
  /// 不是配置错误。启动时对着一台只想跑本地的设备报一堆错，
  /// 会让人以为漏了什么必填项。
  static CloudRuntime? fromEnvironment() {
    final config = DataConfig.fromEnvironment();
    if (!config.hasBackend) return null;
    return CloudRuntime(config: config, cache: createReadCache());
  }

  /// 启动时的准备工作：**先载入缓存，再恢复会话**。顺序不能反。
  ///
  /// 缓存必须在第一次读之前载入，因为 [ReadCache.lookup] 是同步的
  /// （理由见那个类的注释）。载入晚一步，第一次读会当作未命中 —— 于是
  /// 冷启动的第一屏永远是空等一次网络，而这恰好是缓存最该起作用的那一屏。
  Future<void> initialize() async {
    await readCache?.initialize();

    // 先选地址，再恢复会话 —— 会话那一步要真的发一个 `me()` 请求，
    // 地址没定就会打到首选上（在外网时那次请求必然失败）。
    //
    // ⚠️ `resolve()` 是**并发探测、第一个成功即返回**：
    // 在家时内网十几毫秒就赢，不会等 Tailscale 那条。写成 `Future.wait`
    // 就会让局域网也去等最慢的候选 —— 那正是这个方案最容易做反的地方。
    final picked = await endpoint?.resolve();
    if (endpoint != null && picked == null) {
      // 都探不通：不在这里报错，照常往下走。业务请求会带着首选地址失败，
      // 用户看到的是「连不上数据服务」——比启动阶段抛异常更好定位。
      debugPrint('两个候选地址都没探通，先按首选 ${config.baseUrl} 发请求');
    }

    await restoreSession();
  }

  /// 读一次落盘的会话，并顺带验证它还算不算数。
  ///
  /// 冷启动必须做这一步，否则「刷新页面」就等于「被登出」——
  /// 内存里没有 token，而磁盘上那一份没人去读。
  ///
  /// 验证失败（token 过期 / 被吊销）时**不清空**：`DataApiClient` 在收到
  /// 那类错误码时已经清过了，这里再清一次是重复的；而且这一次失败可能只是
  /// 断网 —— 断网时把用户的登录态抹掉，等于「出门一趟回来要重新登录」。
  Future<void> restoreSession() async {
    await api.session.initialize();
    if (!api.isAuthenticated) return;
    try {
      final user = await auth.me();
      if (user.isNotEmpty) {
        await api.session.save(token: api.session.token!, user: user);
      }
    } on DataApiException {
      // 保持现状：本地那份 token 与用户信息先留着。
    }
  }

  void dispose() {
    // 把还没落盘的缓存写出去。**不 await** —— 缓存丢了最坏的结果是回到
    // 纯在线，为此阻塞一次退出不划算（而且 `dispose` 的调用方是同步的）。
    final cache = readCache;
    if (cache != null) unawaited(cache.flush());
    api.close();
  }
}
