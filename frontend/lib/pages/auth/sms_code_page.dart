import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/auth_controller.dart';
import '../../models/user_model.dart';
import '../../services/auth_service.dart';
import '../../services/sms_gateway.dart';
import '../../utils/pop_route.dart';

/// 短信验证码页。**一个页面承载两种用途**（登录 / 重置密码）。
///
/// 合成一个页面而不是两个，是因为两种流程的差异只有一处：
/// 重置密码多两个「新密码 / 确认密码」输入框。分开写会得到两份
/// 发送验证码 / 倒计时 / 错误提示的代码，而它们将来会分别漂移 ——
/// 一处加了「60 秒内不能重发」，另一处没有。
///
/// ## 为什么未接入时还要把这个页面做出来
///
/// 本期没有短信网关，这个页面**所有按钮都是禁用的**。
/// 之所以不把它藏起来：藏起来的结果是接入那天没人记得它存在，
/// 而且「入口在哪、文案怎么说、验证码几位」这些决定会被推迟到
/// 有真实短信压力的时候再拍板。现在做出来，接入时只改一个开关
/// （见 `doc/auth-extension-seams.md`）。
///
/// 页面上那条横幅是刻意留的：它把「功能没做好」和「服务没接入」
/// 分开说。用户看到「服务尚未接入」不会反复重试；看到「发送失败」
/// 才会一直点。
class SmsCodePage extends StatefulWidget {
  const SmsCodePage({super.key, required this.purpose});

  final SmsPurpose purpose;

  @override
  State<SmsCodePage> createState() => _SmsCodePageState();
}

class _SmsCodePageState extends State<SmsCodePage> {
  final phoneCtrl = TextEditingController();
  final codeCtrl = TextEditingController();
  final newPasswordCtrl = TextEditingController();
  final confirmPasswordCtrl = TextEditingController();

  /// 重发倒计时（秒）。0 = 可以发送。
  int _countdown = 0;
  Timer? _timer;
  bool _sending = false;
  bool _submitting = false;

  bool get _isReset => widget.purpose == SmsPurpose.resetPassword;

  @override
  void initState() {
    super.initState();
    // 从个人信息页进来时会带上当前账号的手机号，省得用户再敲一遍。
    // 从登录页进来时没有参数（`arguments` 为 null），保持空输入框。
    final args = Get.arguments;
    if (args is String && args.isNotEmpty) {
      phoneCtrl.text = args;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    phoneCtrl.dispose();
    codeCtrl.dispose();
    newPasswordCtrl.dispose();
    confirmPasswordCtrl.dispose();
    super.dispose();
  }

  void _startCountdown(int seconds) {
    _timer?.cancel();
    setState(() => _countdown = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _countdown -= 1;
        if (_countdown <= 0) timer.cancel();
      });
    });
  }

  Future<void> _sendCode() async {
    final auth = Get.find<AuthController>();
    setState(() => _sending = true);
    final result = await auth.sendSmsCode(phoneCtrl.text, widget.purpose);
    if (!mounted) return;
    setState(() => _sending = false);

    if (result.isSent) {
      // 冷却是**服务端给多少就用多少**，不写死 60：
      // 两边对不上时用户会看到「按钮亮了但发不出去」。
      _startCountdown(result.retryAfterSeconds ?? 60);
      Get.snackbar(
        '已发送',
        '验证码已发送至 ${UserModel.maskPhone(phoneCtrl.text)}',
      );
      return;
    }

    // 「没接入」和「被拒」分开说。合成一句「发送失败，请重试」
    // 会让用户对着一个永远不会成功的按钮反复点。
    Get.snackbar(
      result.status == SmsSendStatus.unavailable ? '暂不可用' : '发送失败',
      result.message,
    );
  }

  Future<void> _submit() async {
    final auth = Get.find<AuthController>();

    if (_isReset && newPasswordCtrl.text != confirmPasswordCtrl.text) {
      Get.snackbar('重置失败', '两次输入的密码不一致');
      return;
    }

    setState(() => _submitting = true);
    try {
      // 校验在服务端，这里只负责把码递过去、把凭证拿回来。
      final verification = await auth.verifySmsCode(
        phone: phoneCtrl.text,
        code: codeCtrl.text,
        purpose: widget.purpose,
      );
      if (!mounted) return;

      if (_isReset) {
        // 成功后会自动登录并跳首页，这个页面随后被销毁。
        await auth.resetPasswordBySmsCode(verification, newPasswordCtrl.text);
      } else {
        await auth.loginBySmsCode(verification);
      }
    } on AuthException catch (error) {
      if (!mounted) return;
      Get.snackbar(_isReset ? '重置失败' : '登录失败', error.message);
    } on SmsException catch (error) {
      if (!mounted) return;
      // 标题按**原因**分，不是统一一句「校验失败」：
      // 「没接入」要去找运维、「码错了」该让用户重输、「太频繁」要让他等。
      // 三种处置互不相干，共用一句话会让用户一直往错的方向试。
      Get.snackbar(_smsFailureTitle(error.kind), error.message);
    } finally {
      // 成功路径上页面已经不在树上（`Get.offAllNamed` 换掉了整个栈），
      // 这里的 mounted 判断不是防御性编程，是必需的。
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _smsFailureTitle(SmsFailureKind kind) => switch (kind) {
    SmsFailureKind.unavailable => '暂不可用',
    SmsFailureKind.invalidCode => '验证码不正确',
    SmsFailureKind.rateLimited => '操作太频繁',
  };

  @override
  Widget build(BuildContext context) {
    final auth = Get.find<AuthController>();
    final enabled = auth.smsEnabled;
    final title = _isReset ? '找回密码' : '验证码登录';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: SizedBox(
                  width: 360,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isReset
                            ? '用手机号接收短信验证码，验证通过后重设密码'
                            : '用手机号接收短信验证码，无需输入密码即可登录',
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                      const SizedBox(height: 20),
                      if (!enabled) const _SmsUnavailableBanner(),
                      if (!enabled) const SizedBox(height: 20),
                      TextField(
                        controller: phoneCtrl,
                        keyboardType: TextInputType.phone,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(11),
                        ],
                        decoration: const InputDecoration(
                          labelText: '手机号',
                          hintText: '请输入11位手机号',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: codeCtrl,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(6),
                              ],
                              decoration: const InputDecoration(
                                labelText: '验证码',
                                hintText: '6位数字',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 132,
                            child: OutlinedButton(
                              // 唯一能力开关，见 SmsGateway.isConfigured。
                              onPressed: enabled && !_sending && _countdown == 0
                                  ? _sendCode
                                  : null,
                              child: Text(
                                _countdown > 0 ? '$_countdown 秒后重发' : '获取验证码',
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_isReset) ...[
                        const SizedBox(height: 14),
                        TextField(
                          controller: newPasswordCtrl,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: '新密码',
                            hintText: '6-16位数字和字母组合',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: confirmPasswordCtrl,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: '确认新密码',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          // 未接入时**禁用按钮，但不禁用入口**：
                          // 入口留着，用户才知道这里以后能点。
                          onPressed: enabled && !_submitting ? _submit : null,
                          child: _submitting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(_isReset ? '重置密码' : '验证码登录'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton(
                          onPressed: () => popRoute(context),
                          child: const Text('返回'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 未接入短信服务时页顶的说明横幅。
///
/// 写清楚「为什么不能点」以及「接入后会自动启用」——
/// 少了后半句，看到它的人（包括以后的我们）会以为这是个没人管的半成品。
class _SmsUnavailableBanner extends StatelessWidget {
  const _SmsUnavailableBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: AppColors.warning),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '短信服务尚未接入，暂时无法发送验证码。\n'
              '接入短信网关并开通后，本页会自动启用。',
              style: TextStyle(fontSize: 13, color: AppColors.text),
            ),
          ),
        ],
      ),
    );
  }
}
