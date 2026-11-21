import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'data_config.dart';

/// 服务端实例标识，打包时烧入（`--dart-define=SERVER_INSTANCE_ID=…`）。
///
/// 空串 = **不校验**，兼容没配这个值的旧部署。
/// ⚠️ 配了它才有「192.168.3.80 撞车」这层保护 ——
/// 别人家同一网段上的另一台服务同样会回 200 和一个合法信封。
const kServerInstanceId = String.fromEnvironment('SERVER_INSTANCE_ID');

/// 探测一个候选地址是否可用。返回 `true` = 这台机器、这套服务、确实在跑。
typedef EndpointProbe = Future<bool> Function(Uri uri, Duration timeout);

/// 在多个候选地址之间**选一个能用的**。
///
/// ## 它解决的问题
///
/// 手机在家走局域网 `192.168.3.80`，出门走 Tailscale `100.96.105.11` ——
/// 同一个后端的两条路。地址是打包时烧进去的，而这两条路不能同时写进一个字段。
///
/// ## 为什么是「并发探测、谁先回谁赢」
///
/// 最直觉的写法是「先试内网，超时了再试 Tailscale」。它在家很快，但**在外网
/// 每次冷启动都要白等一个超时**（1.5 秒），而这段时间里 Tailscale 其实早就
/// 回来了。反过来「先试 Tailscale」则让家里变成最慢的那条路 —— 与使用场景
/// （大部分时间在家）正好相反。
///
/// 并发探测让两条路同时跑，**第一个成功的胜出，输家继续跑但结果丢掉**。
/// 在家多花的钱是一次内网往返（十几毫秒），在外多花的钱是零。
///
/// ⚠️ 必须是「谁先成功谁赢」，**不是** `Future.wait` 等全部回来 ——
/// 后者在家也要等 Tailscale 那条，白白把局域网变成最慢链路。
///
/// ## 为什么必须校验实例身份
///
/// `192.168.3.80` 是最常见的内网段之一。在别人家 WiFi 里，这个 IP
/// **大概率是另一台设备**；万一那台也跑着同款服务，只判「端口通」
/// 就会把数据写到陌生人库里 —— 而且不会报任何错。
/// 所以探测除了看 200，还要比对 `/health` 里的 `instanceId`。
/// 不配 `expectedInstance` 时跳过比对（兼容旧部署），但那意味着放弃这层保护。
///
/// ## 只在两个时机探测
///
/// 1. 冷启动、第一次需要发请求之前（[ensureActive]）；
/// 2. 某个请求**连接失败**之后（[onNetworkFailure]）。
///
/// 日常每个请求都探测的话，局域网也会平白多一次往返 —— 那是这个方案最容易被
/// 做成「反而更慢」的地方，所以这里刻意不做。
class EndpointResolver {
  EndpointResolver({
    required List<String> candidates,
    required this.healthPath,
    this.expectedInstance = '',
    this.probeTimeout = const Duration(milliseconds: 1500),
    this.reprobeCooldown = const Duration(seconds: 10),
    EndpointProbe? probe,
    DateTime Function()? clock,
  })  : candidates = _clean(candidates),
        _injectedProbe = probe,
        _clock = clock ?? DateTime.now;

  /// 候选地址，**首选在前**。已去空、去重、去掉尾部斜杠。
  final List<String> candidates;

  /// 探测用的相对路径：数据服务 `/health`，AI 网关 `/ai/health`。
  final String healthPath;

  /// 期望的实例标识（`/health` 里的 `instanceId`）。空串 = 不校验。
  final String expectedInstance;

  /// 单次探测的超时。
  ///
  /// 1.5 秒的依据：局域网正常是十几毫秒，Tailscale 直连几十到几百毫秒，
  /// 走中继也在 1 秒内。超过 1.5 秒的「通」对首屏已经没有意义。
  /// ⚠️ 不要为了「更稳」调到 5 秒 —— 外网时内网那条会一直挂着，
  /// 虽然赢家照样先返回，但失败路径上用户要多等好几秒。
  final Duration probeTimeout;

  /// 两次探测之间的最小间隔。
  ///
  /// 没有它的话，服务重启那几秒里每个失败请求都会触发一次探测：
  /// 用户看到的是「每个操作都卡一下」，而真正的故障（服务没起）反而被淹没。
  final Duration reprobeCooldown;

  final EndpointProbe? _injectedProbe;
  final DateTime Function() _clock;

  String? _active;
  DateTime? _lastProbeAt;
  Future<String?>? _inFlight;

  /// 当前选中的地址；`null` = 还没成功探测过。
  String? get active => _active;

  /// 是否有多个候选。只有一个时**不需要探测**（省掉一次往返）——
  /// 地址是打包时烧的，要么通要么不通，没有第二个选择可做。
  bool get hasChoice => candidates.length > 1;

  /// 拿当前地址；没选过就先探一次。
  ///
  /// 已经有可用地址时是**同步返回**的（不 await），日常请求走的就是这条。
  Future<String?> ensureActive() async {
    final current = _active;
    if (current != null) return current;
    if (!hasChoice) {
      // 单候选：不探测，直接用它。失败由业务请求自己报错 ——
      // 在这里先探一次只会让每个冷启动多一次无意义的往返。
      return _active = candidates.isEmpty ? null : candidates.first;
    }
    return resolve();
  }

  /// 并发探测，第一个成功的胜出。
  Future<String?> resolve() {
    if (candidates.isEmpty) return Future.value(null);
    final running = _inFlight;
    if (running != null) return running;

    // 冷却期内不重复探测：失败之后到点之前，后续请求直接拿 null
    // （调用方会退回 `config.baseUrl`，也就是首选地址）。
    final last = _lastProbeAt;
    if (last != null && _clock().difference(last) < reprobeCooldown) {
      return Future.value(_active);
    }

    _lastProbeAt = _clock();
    final future = _race();
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  /// 一个请求连接失败了：把当前地址作废，必要时重新探测。
  ///
  /// 返回 `true` = 已经换到另一个**可用**地址，调用方可以重试；
  /// `false` = 冷却中或没有别的可用地址，调用方照常报错。
  Future<bool> onNetworkFailure() async {
    // ⚠️ 节流**只写在 `resolve()` 里**，这里不再判断一遍。
    //
    // 两处各写一份的后果是：证伪时删掉其中一处，另一处还在挡，
    // 于是「冷却」这条判据看起来是绿的、其实什么都没测到
    // （实际发生过：删掉这里的判断后测试仍然全绿）。
    // 一个机制只能有一处实现 —— 否则它就没法被一条判据盯住。
    _active = null;
    final next = await resolve();
    if (next == null) return false;
    debugPrint('数据服务已切换到备用地址：$next');
    return true;
  }

  Future<String?> _race() async {
    final completer = Completer<String?>();
    var pending = candidates.length;

    for (final url in candidates) {
      // 刻意不 await：所有候选同时探。
      unawaited(
        _probeOne(url).then(
          (ok) {
            if (ok && !completer.isCompleted) {
              _active = url;
              completer.complete(url);
            }
          },
          onError: (Object _) {
            // 探测自己不会抛（内部全 catch），这里兜一层是为了
            // 「少了一个候选也要把 pending 减掉」那条不被打断。
          },
        ).whenComplete(() {
          pending--;
          if (pending == 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        }),
      );
    }

    return completer.future;
  }

  Future<bool> _probeOne(String baseUrl) {
    final probe = _injectedProbe ?? _defaultProbe;
    return probe(
      Uri.parse(joinUrlPath(baseUrl, healthPath)),
      probeTimeout,
    );
  }

  Future<bool> _defaultProbe(Uri uri, Duration timeout) async {
    final client = http.Client();
    try {
      final response = await client
          .get(uri, headers: const {'accept': 'application/json'})
          .timeout(timeout);
      if (response.statusCode != 200) return false;

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map || decoded['ok'] != true) return false;

      if (expectedInstance.isEmpty) return true;

      final data = decoded['data'];
      final instance = data is Map ? data['instanceId'] : null;
      if (instance != expectedInstance) {
        // ⭐ 这条不是「苛刻」，是**唯一能防住撞车的地方**：
        // 别人家同一网段上的另一台服务同样会回 200 和一个合法的信封。
        debugPrint('地址 $uri 上的服务不是这台机器（instanceId 不匹配），跳过');
        return false;
      }
      return true;
    } catch (_) {
      // ⚠️ 探测失败是**常态**（在外网时内网那条必然失败），
      // 所以这里不打 error 级日志 —— 那会把真正的故障淹掉。
      return false;
    } finally {
      client.close();
    }
  }

  static List<String> _clean(List<String> raw) {
    final out = <String>[];
    for (final item in raw) {
      var url = item.trim();
      while (url.endsWith('/')) {
        url = url.substring(0, url.length - 1);
      }
      if (url.isEmpty) continue;
      if (out.contains(url)) continue;
      out.add(url);
    }
    return out;
  }

  @override
  String toString() =>
      'EndpointResolver(active: ${_active ?? '(未选定)'}, candidates: ${candidates.length})';
}
