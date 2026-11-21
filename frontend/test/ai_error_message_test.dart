import 'dart:io';

import 'package:easy_learn_app/services/ai_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// `AiRequestException.userMessage` 的判据（2026-10-06，见 doc/open-items.md B38）。
///
/// ## 为什么单独立一条
///
/// 这个 getter 是 B38 新加的。在此之前，界面上显示的失败原因是 `message` ——
/// 而它里面装着**排查用的东西**：底层英文异常
/// （`ClientException: Software caused connection abort`）、`requestId`、
/// 乃至网关响应体原文（可能是 HTML）。
///
/// 它进的界面是 `ai_degraded_banner.dart` 与 `ai_observe_page.dart`
/// （经由 `AiDegradation.reason`）—— 家长端会看到一屏英文。
///
/// ## 两条判据，方向相反，缺一不可
///
/// 1. **客户端本地生成的技术文案 → 必须换掉**（不许含英文类名 / requestId / 响应体）；
/// 2. **服务端回来的业务文案 → 原样回落**（换掉它等于把有用的原因丢掉）。
///
/// 只做 ① 会矫枉过正（把「该模型尚未开通」也糊成「出错了」），只做 ② 等于没修。
/// 这与 `test/data_api_retry_test.dart` 里那条 `userMessage` 用例是同一口径。
///
/// 3. **展示点必须真的走 `userMessage`**（文件末尾那组）—— 这是 B38 的原始教训：
///    **机制存在 ≠ 被使用**。上面两条把 getter 测绿，调用点仍然可以改回
///    `.message` 而没有任何一条判据会红。所以调用点要单独钉住。
void main() {
  group('技术文案换成人话', () {
    test('本地生成的 code 一律不含英文异常 / requestId / 响应体', () {
      const technical = {
        'timeout': '请求超时（30s）',
        'upload_timeout': '照片上传超时（60s）',
        'transport_error':
            '网络异常：ClientException: Software caused connection abort',
        'upload_transport_error': '照片上传失败：Connection reset by peer',
        'invalid_json': '网关返回的不是合法 JSON（requestId: abc-123）',
        'invalid_envelope': '网关信封缺少 data 对象（requestId: abc-123）',
        'gateway_error': '网关返回错误但未给出 error 对象（requestId: abc-123）',
        'http_502': '网关返回 502：<html>502 Bad Gateway</html>',
      };

      for (final entry in technical.entries) {
        final shown =
            AiRequestException(code: entry.key, message: entry.value).userMessage;

        expect(shown, isNot(entry.value),
            reason: '${entry.key}：原始 message 原样漏给了用户');
        for (final leak in const [
          'ClientException',
          'requestId',
          'http://',
          'https://',
          '<html>',
          'connection abort',
          'reset by peer',
          'Bad Gateway',
        ]) {
          expect(shown, isNot(contains(leak)),
              reason: '${entry.key} 的展示文案里漏了「$leak」——'
                  '用户从这句话里得不到任何能据以行动的信息');
        }
      }
    });

    test('换完之后不能是空串（否则界面会出现空白提示）', () {
      for (final code in const [
        'timeout',
        'upload_timeout',
        'transport_error',
        'upload_transport_error',
        'invalid_json',
        'invalid_envelope',
        'gateway_error',
        'http_500',
      ]) {
        expect(
          AiRequestException(code: code, message: 'raw').userMessage,
          isNotEmpty,
          reason: '$code 换出了空串',
        );
      }
    });
  });

  group('服务端文案原样回落（不能矫枉过正）', () {
    test('业务错误的中文原因照旧可展示', () {
      expect(
        const AiRequestException(
          code: 'model_not_enabled',
          message: '该模型尚未开通，请联系管理员',
        ).userMessage,
        '该模型尚未开通，请联系管理员',
      );
    });

    test('本来就是人话的那几条不被改写', () {
      expect(
        const AiRequestException(code: 'rate_limited', message: '调用过于频繁，已触发限流')
            .userMessage,
        '调用过于频繁，已触发限流',
      );
      expect(
        const AiRequestException(
          code: 'payload_too_large',
          message: '本次请求内容过大，请减少照片数量或降低分辨率',
        ).userMessage,
        '本次请求内容过大，请减少照片数量或降低分辨率',
      );
      expect(
        const AiRequestException(
          code: 'unauthorized',
          message: '网关拒绝了本次调用（401），请检查会话是否有效',
        ).userMessage,
        '网关拒绝了本次调用（401），请检查会话是否有效',
      );
    });
  });

  /// 「机制存在 ≠ 被使用」（B38 的教训）。
  ///
  /// `DataApiException.userMessage` 和 `AiRequestException.userMessage` 都在，
  /// 而且都是对的 —— 但 B38 那次的问题是**调用点**：三处展示点直接用了
  /// `.message`，用户看到的是带 URL 的英文异常。所以只测 getter **不够**：
  /// getter 测绿之后，调用点照样可以改回 `.message`，一条判据都不会红。
  ///
  /// 这里退而求其次，用**读源码**的方式钉住调用点（与
  /// `test/attachment_limits_test.dart` 读 `attachments.js` 是同一个手法）。
  /// 它不是行为判据 —— 行为判据要起 widget 再伪造网络层，代价过大；
  /// 但它**能看见这件事**：改回去立刻红，不会像上次那样悄悄漏一整轮。
  group('展示点走 userMessage，而不是 message', () {
    // 文件 -> 该文件里允许出现的 `error.message` 次数（每次都必须在源码里
    // 写清理由，否则这条断言会替你追问）。
    const callSites = <String, int>{
      'lib/controllers/chat_controller.dart': 0,
      'lib/pages/shared/chat_page.dart': 0,
      // 唯一保留的一处：`is StateError` 分支。那是本地构建抛的中文文案，
      // 本来就不经过 `DataApiException`，也没有 `userMessage` 可用。
      'lib/controllers/student_controller.dart': 1,
    };

    test('三处展示路径都接了 userMessage', () {
      for (final path in callSites.keys) {
        expect(
          File(path).readAsStringSync(),
          contains('.userMessage'),
          reason: '$path 不再引用 userMessage ——'
              '用户会重新看到「连不上数据服务（https://…）：ClientException」这种句子',
        );
      }
    });

    test('展示路径上没有多余的 error.message 漏出去', () {
      callSites.forEach((path, allowed) {
        final hits = RegExp(r'error\.message').allMatches(
          File(path).readAsStringSync(),
        ).length;
        expect(
          hits,
          allowed,
          reason: '$path 有 $hits 处 error.message（允许 $allowed 处）——'
              'B38 就是这么漏的：机制在，但调用点没用它',
        );
      });
    });
  });
}
