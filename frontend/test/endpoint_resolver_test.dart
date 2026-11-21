import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_learn_app/services/data_api_client.dart';
import 'package:easy_learn_app/services/data_config.dart';
import 'package:easy_learn_app/services/endpoint_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 「家里走局域网、出门走 Tailscale」的地址选择。
///
/// ── 这一组盯的是什么 ────────────────────────────────────────────────────
///
/// 这个能力最容易做错的地方**不是选错**，而是**把局域网也拖慢**：
/// 写成 `Future.wait([内网, Tailscale])` 之后功能完全正常、测试也能过，
/// 但在家每次冷启动都要等 Tailscale 那条回来。所以第一条判据就是
/// 「输家永远不返回时，赢家必须照样立刻返回」。
///
/// 第二容易做错的是**撞车**：`192.168.3.80` 在别人家 WiFi 里是另一台设备。
/// 只判「HTTP 200」不够，必须比对 `/health` 里的 `instanceId`。
void main() {
  group('并发探测：谁先成功谁赢', () {
    test('慢的那个永远不回来，也必须立刻拿到快的那个', () async {
      final never = Completer<bool>();
      final resolver = EndpointResolver(
        candidates: ['http://lan', 'http://tailscale'],
        healthPath: '/health',
        probe: (uri, _) async {
          if (uri.host == 'lan') return true;
          return never.future; // 永远不完成
        },
      );

      // ⚠️ 这条的关键在 timeout：写成 Future.wait 的实现会在这里挂住，
      // 被 2 秒超时打死 —— 那正是用户在家会遇到的「白等一秒多」。
      final picked = await resolver.resolve().timeout(
        const Duration(seconds: 2),
        onTimeout: () => 'TIMEOUT',
      );

      expect(picked, 'http://lan');
      expect(resolver.active, 'http://lan');

      // 收拾掉那个永不完成的 Future，避免测试结束时残留。
      never.complete(false);
    });

    test('首选不通时用备选', () async {
      final resolver = EndpointResolver(
        candidates: ['http://lan', 'http://tailscale'],
        healthPath: '/health',
        probe: (uri, _) async => uri.host == 'tailscale',
      );

      expect(await resolver.resolve(), 'http://tailscale');
    });

    test('两个都不通时返回 null，不抛', () async {
      final resolver = EndpointResolver(
        candidates: ['http://lan', 'http://tailscale'],
        healthPath: '/health',
        probe: (_, _) async => false,
      );

      expect(await resolver.resolve(), isNull);
      expect(resolver.active, isNull);
    });

    test('只有一个候选时不探测 —— 没有第二个选择可做', () async {
      var probes = 0;
      final resolver = EndpointResolver(
        candidates: ['http://only'],
        healthPath: '/health',
        probe: (_, _) async {
          probes++;
          return true;
        },
      );

      expect(resolver.hasChoice, isFalse);
      expect(await resolver.ensureActive(), 'http://only');
      expect(probes, 0, reason: '单地址还探测，等于给每个冷启动白加一次往返');
    });
  });

  group('实例身份：防「同网段上的别人家」', () {
    test('instanceId 不匹配的候选被排除，匹配的才收', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'ok': true,
          'data': {'service': 'data-service', 'instanceId': 'someone-else'},
        }));
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));

      final url = 'http://127.0.0.1:${server.port}';

      final rejected = EndpointResolver(
        candidates: [url],
        healthPath: '/health',
        expectedInstance: 'mine',
        probeTimeout: const Duration(seconds: 2),
      );
      expect(
        await rejected.resolve(),
        isNull,
        reason: '别人的服务同样回 200 和合法信封 —— 只看状态码就撞车了',
      );

      final accepted = EndpointResolver(
        candidates: [url],
        healthPath: '/health',
        expectedInstance: 'someone-else',
        probeTimeout: const Duration(seconds: 2),
      );
      expect(await accepted.resolve(), url);
    });

    test('没配 instanceId 时不校验（旧部署兼容）', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'ok': true,
          'data': {'service': 'data-service'},
        }));
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));

      final url = 'http://127.0.0.1:${server.port}';
      final resolver = EndpointResolver(
        candidates: [url],
        healthPath: '/health',
        probeTimeout: const Duration(seconds: 2),
      );
      expect(await resolver.resolve(), url);
    });
  });

  group('切换与节流', () {
    test('冷却期内不重复探测', () async {
      var probes = 0;
      final resolver = EndpointResolver(
        candidates: ['http://lan', 'http://tailscale'],
        healthPath: '/health',
        reprobeCooldown: const Duration(minutes: 1),
        probe: (_, _) async {
          probes++;
          return false;
        },
      );

      await resolver.resolve();
      expect(probes, 2, reason: '两个候选各探一次');

      // 服务刚挂时，每个失败请求都会调到这里 —— 不能再探。
      expect(await resolver.onNetworkFailure(), isFalse);
      expect(await resolver.onNetworkFailure(), isFalse);
      expect(probes, 2, reason: '冷却期内又探了：用户会觉得每个操作都卡一下');
    });

    test('冷却期过了会重新探测，并能切到另一个地址', () async {
      var probes = 0;
      var tailscaleUp = false;
      final resolver = EndpointResolver(
        candidates: ['http://lan', 'http://tailscale'],
        healthPath: '/health',
        reprobeCooldown: Duration.zero,
        probe: (uri, _) async {
          probes++;
          if (uri.host == 'lan') return false;
          return tailscaleUp;
        },
      );

      expect(await resolver.resolve(), isNull);

      tailscaleUp = true; // 比如用户在这期间打开了 Tailscale
      expect(await resolver.onNetworkFailure(), isTrue);
      expect(resolver.active, 'http://tailscale');
      expect(probes, 4, reason: '两轮探测 × 两个候选');
    });

    test('已经选中之后 ensureActive 不再探测', () async {
      var probes = 0;
      final resolver = EndpointResolver(
        candidates: ['http://lan', 'http://tailscale'],
        healthPath: '/health',
        probe: (uri, _) async {
          probes++;
          return uri.host == 'lan';
        },
      );

      await resolver.resolve();
      final afterFirst = probes;

      for (var i = 0; i < 5; i++) {
        expect(await resolver.ensureActive(), 'http://lan');
      }
      expect(probes, afterFirst, reason: '日常请求不该再探测');
    });
  });

  group('配置解析', () {
    test('逗号分隔的备选地址：空格、空项、重复都要被清掉', () {
      expect(DataConfig.splitUrls(''), isEmpty);
      expect(DataConfig.splitUrls('  ,  '), isEmpty);
      expect(
        DataConfig.splitUrls(' http://a , http://b ,, http://c '),
        ['http://a', 'http://b', 'http://c'],
      );
    });

    test('candidateBaseUrls = 首选 + 备选（空首选不占位）', () {
      const config = DataConfig(
        baseUrl: 'http://lan:8788',
        fallbackBaseUrls: ['http://ts:8788'],
      );
      expect(config.candidateBaseUrls, ['http://lan:8788', 'http://ts:8788']);

      const empty = DataConfig(baseUrl: '', fallbackBaseUrls: []);
      expect(empty.candidateBaseUrls, isEmpty);
    });
  });

  group('DataApiClient 接入', () {
    test('首选连不上时切到备选并重试，GET 最终成功', () async {
      final calls = <String>[];
      final client = MockClient((request) async {
        calls.add(request.url.host);
        if (request.url.host == 'lan') {
          throw const SocketException('no route to host');
        }
        return http.Response(
          jsonEncode({'ok': true, 'data': {'value': 42}}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final resolver = EndpointResolver(
        candidates: ['http://lan:8788', 'http://tailscale:8788'],
        healthPath: '/health',
        reprobeCooldown: Duration.zero,
        probe: (uri, _) async => uri.host == 'tailscale',
      );

      final api = DataApiClient(
        config: const DataConfig(baseUrl: 'http://lan:8788'),
        httpClient: client,
        endpoint: resolver,
      );

      final data = await api.getJson('/data/probe');

      expect(data['value'], 42);
      expect(resolver.active, 'http://tailscale:8788');
      expect(
        calls.last,
        'tailscale',
        reason: '最后一次必须打到备选地址',
      );
    });

    test('POST 不因换地址而重试 —— 写操作重复执行比失败更糟', () async {
      var posts = 0;
      final client = MockClient((request) async {
        posts++;
        throw const SocketException('connection reset');
      });

      final resolver = EndpointResolver(
        candidates: ['http://lan:8788', 'http://tailscale:8788'],
        healthPath: '/health',
        reprobeCooldown: Duration.zero,
        probe: (uri, _) async => uri.host == 'tailscale',
      );

      final api = DataApiClient(
        config: const DataConfig(baseUrl: 'http://lan:8788'),
        httpClient: client,
        endpoint: resolver,
      );

      await expectLater(
        api.postJson('/data/homework', body: {'title': 'x'}),
        throwsA(isA<DataApiException>()),
      );
      expect(posts, 1, reason: 'POST 重试一次就可能变成两条记录');
    });
  });
}
