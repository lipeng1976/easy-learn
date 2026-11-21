import 'package:flutter_test/flutter_test.dart';

import 'package:easy_learn_app/controllers/ai_status_controller.dart';
import 'package:easy_learn_app/services/ai_data_source.dart';

AiDegradation _event(String code, {String operation = 'judgeAnswer'}) =>
    AiDegradation(
      operation: operation,
      code: code,
      reason: '测试用降级原因（$code）',
      at: DateTime(2026, 9, 15, 10),
    );

void main() {
  group('AI 降级提示位', () {
    test('默认安静：没有任何降级时不显示任何东西', () {
      final status = AiStatusController();
      expect(status.latest.value, isNull);
      expect(status.isShowing, isFalse);
      expect(status.totalCount.value, 0);
      status.onClose();
    });

    test('报一次就显示，并带上原因', () {
      final status = AiStatusController();
      status.report(_event('timeout'));

      expect(status.isShowing, isTrue);
      expect(status.latest.value?.code, 'timeout');
      expect(status.latest.value?.reason, contains('timeout'));
      status.onClose();
    });

    test('次数累计且不因提示消失而清零', () async {
      final status = AiStatusController(
        autoHideAfter: const Duration(milliseconds: 20),
      );

      status.report(_event('timeout'));
      status.report(_event('rate_limited'));
      expect(status.totalCount.value, 2);

      // 只显示最近一次：横幅的位置只够放一条，放两条会被忽略。
      expect(status.latest.value?.code, 'rate_limited');

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(status.isShowing, isFalse, reason: '短窗口后自动消失，不长期占据界面');
      // 关掉横幅表示「我知道了」，不表示「这件事没发生过」。
      expect(status.totalCount.value, 2);
      status.onClose();
    });

    test('持续降级会不断续期，不会闪一下就消失', () async {
      final status = AiStatusController(
        autoHideAfter: const Duration(milliseconds: 40),
      );

      status.report(_event('timeout'));
      await Future<void>.delayed(const Duration(milliseconds: 25));
      status.report(_event('timeout'));

      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(
        status.isShowing,
        isTrue,
        reason: '服务端整体故障时会连续降级，横幅该一直挂着而不是每 40ms 闪一次',
      );
      status.onClose();
    });

    test('手动关掉后不再自动弹回来', () async {
      final status = AiStatusController(
        autoHideAfter: const Duration(milliseconds: 20),
      );

      status.report(_event('timeout'));
      status.dismiss();
      expect(status.isShowing, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(status.isShowing, isFalse);
      status.onClose();
    });

    test('控制器关闭时清掉定时器，不留悬空回调', () async {
      final status = AiStatusController(
        autoHideAfter: const Duration(milliseconds: 10),
      );
      status.report(_event('timeout'));
      status.onClose();

      // 定时器被取消的话，这里不会因为「向已关闭的 Rx 写值」而抛异常。
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
  });
}
