import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/auth_controller.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final TextEditingController phoneCtrl;
  late final TextEditingController pwdCtrl;
  late String selectedRole;
  bool _agreed = false;

  @override
  void initState() {
    super.initState();
    final auth = Get.find<AuthController>();
    phoneCtrl = TextEditingController(text: auth.savedPhone);
    pwdCtrl = TextEditingController(text: auth.savedPassword);
    selectedRole = auth.savedRole;
  }

  @override
  void dispose() {
    phoneCtrl.dispose();
    pwdCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authController = Get.find<AuthController>();

    return Scaffold(
      backgroundColor: AppColors.background,
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
                      const Text(
                        '伴学APP',
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '家庭亲子学习监督平台',
                        style: TextStyle(
                          fontSize: 15,
                          color: AppColors.textMuted,
                        ),
                      ),
                      // 「上次使用」只在上次确实登录过时显示。
                      // 没有记录时什么都不写，而不是默认写「手机号密码」——
                      // 那会让新用户看到一句不存在的历史。
                      if (authController.savedMethod != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          '上次使用：${authController.savedMethod!.label}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          _RoleOption(
                            label: '学生',
                            value: 'student',
                            selected: selectedRole == 'student',
                            onTap: () =>
                                setState(() => selectedRole = 'student'),
                          ),
                          const SizedBox(width: 12),
                          _RoleOption(
                            label: '家长',
                            value: 'parent',
                            selected: selectedRole == 'parent',
                            onTap: () =>
                                setState(() => selectedRole = 'parent'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: phoneCtrl,
                        decoration: const InputDecoration(
                          labelText: '手机号',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.phone,
                      ),
                      const SizedBox(height: 18),
                      TextField(
                        controller: pwdCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: '密码',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Checkbox(
                            value: authController.rememberMe.value,
                            onChanged: (v) =>
                                authController.rememberMe.value = v ?? false,
                          ),
                          const Text('记住密码'),
                          const Spacer(),
                          TextButton(
                            // 以前这里弹一句「短信找回密码已模拟完成」——
                            // 那是**假成功**：用户以为密码被找回了，
                            // 实际上什么都没发生，短信也一条没发。
                            // 现在进真正的预留页，页面自己说清「为什么现在用不了」。
                            onPressed: () =>
                                Get.toNamed('/forgot-password'),
                            child: const Text('忘记密码'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Checkbox(
                            value: _agreed,
                            onChanged: (v) =>
                                setState(() => _agreed = v ?? false),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setState(() => _agreed = !_agreed),
                              child: const Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(text: '我已阅读并同意'),
                                    TextSpan(
                                      text: '《用户协议》',
                                      style: TextStyle(
                                        color: AppColors.primary,
                                      ),
                                    ),
                                    TextSpan(text: '和'),
                                    TextSpan(
                                      text: '《隐私政策》',
                                      style: TextStyle(
                                        color: AppColors.primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Obx(
                        () => SizedBox(
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
                            onPressed:
                                authController.isLoading.value || !_agreed
                                ? null
                                : () => authController.login(
                                    phoneCtrl.text,
                                    pwdCtrl.text,
                                    selectedRole,
                                  ),
                            child: authController.isLoading.value
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('手机号登录'),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: () => Get.toNamed('/register'),
                          child: const Text('注册新账号'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Row(
                        children: [
                          Expanded(child: Divider()),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text('或'),
                          ),
                          Expanded(child: Divider()),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Obx(
                        () => SizedBox(
                          width: double.infinity,
                          child: TextButton.icon(
                            onPressed: authController.isLoading.value
                                ? null
                                : () => authController.loginWithWechat(
                                    selectedRole,
                                  ),
                            icon: const Icon(Icons.wechat),
                            label: const Text('微信授权登录'),
                          ),
                        ),
                      ),
                      // 短信验证码登录的**预留入口**。
                      //
                      // 未接入时**不隐藏、只标注**：入口留着，
                      // 接入那天才有人记得这里本来就该有东西，
                      // 也才有人验收得了「入口文案对不对」。
                      // 点了会进预留页，那页有横幅说明为什么现在用不了。
                      Center(
                        child: TextButton(
                          onPressed: () => Get.toNamed('/sms-login'),
                          child: Text(
                            authController.smsEnabled
                                ? '验证码登录'
                                : '验证码登录（未开通）',
                          ),
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

class _RoleOption extends StatelessWidget {
  final String label;
  final String value;
  final bool selected;
  final VoidCallback onTap;

  const _RoleOption({
    required this.label,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? AppColors.primary : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : AppColors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
