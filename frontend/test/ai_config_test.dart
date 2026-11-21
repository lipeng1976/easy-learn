import 'package:easy_learn_app/services/ai_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('默认值即离线（不能被改动的一层保护）', () {
    test('什么都不配时，baseUrl 为空 → hasBackend 为 false', () {
      final config = AiConfig.fromEnvironment();

      expect(config.baseUrl, isEmpty);
      expect(config.hasBackend, isFalse);
      expect(config.enabled, isTrue);
      expect(config.toString(), contains('(offline)'));
    });

    test('三条超时线各自的默认值：12s / 30s / 20s', () {
      final config = AiConfig.fromEnvironment();

      expect(config.requestTimeout, const Duration(seconds: 12));
      expect(config.uploadTimeout, const Duration(seconds: 30));
      // 判定单独一条线（2026-09-26 定 20s）。它**必须不等于**默认的 12s ——
      // 判定是全链路唯一开着思维链的路由，12s 会把它静默降级成本地结论。
      expect(config.judgeTimeout, const Duration(seconds: 20));
      expect(config.judgeTimeout, isNot(config.requestTimeout));
    });

    test('能力位默认全开，传输默认内联', () {
      final config = AiConfig.fromEnvironment();

      expect(config.capabilities, AiCapabilities.all);
      expect(config.imageTransport, AiImageTransport.inline);
      expect(config.maxAttempts, 2);
    });
  });

  group('超时可配置（接本机模型时必须能调）', () {
    test('正常值直接生效', () {
      expect(
        AiConfig.sanitizeTimeout(90_000, const Duration(seconds: 12)),
        const Duration(seconds: 90),
      );
      expect(
        AiConfig.sanitizeTimeout(1_000, const Duration(seconds: 12)),
        const Duration(seconds: 1),
      );
    });

    test('按秒填的笔误会被挡回默认值，而不是变成 30ms', () {
      // 这三个是最容易写出来的三种笔误。
      for (final mistaken in <int>[0, 30, 999]) {
        expect(
          AiConfig.sanitizeTimeout(mistaken, const Duration(seconds: 30)),
          const Duration(seconds: 30),
          reason: '$mistaken ms 应被视为没配',
        );
      }
    });
  });
}
