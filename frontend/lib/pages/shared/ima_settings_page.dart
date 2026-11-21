import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/ima_controller.dart';
import '../../repositories/ima_repository.dart';

/// ima 知识库同步设置页。
///
/// 两种视角：
///   · **家长**：针对「当前伴学的学生」粘贴 clientId / apiKey 连接，或断开；
///     切孩子时 `ImaController.bindStudent` 会清状态并重拉，两边互不串。
///   · **学生**：纯只读——只能看到「我的 ima 同步开没开」，连接由家长完成。
///
/// **一个学生一个独立 KB**：父母共管同一个孩子时看到的是同一份配置，
/// 另一位家长不会再看到连接表单，也不会建出第二个库。
///
/// 这是**可选同步**：未连接时错题复习 / 打卡都不受影响，界面也会说清楚这一点，
/// 不会让家长以为「不连就用不了」。
class ImaSettingsPage extends StatefulWidget {
  const ImaSettingsPage({super.key});

  @override
  State<ImaSettingsPage> createState() => _ImaSettingsPageState();
}

class _ImaSettingsPageState extends State<ImaSettingsPage> {
  late final ImaController imaController;
  final clientIdController = TextEditingController();
  final apiKeyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 允许测试注入替身：已注册就复用，否则新建。
    imaController = Get.isRegistered<ImaController>()
        ? Get.find<ImaController>()
        : Get.put(ImaController());
    imaController.loadStatus();
    clientIdController.addListener(
      () => imaController.clientId.value = clientIdController.text,
    );
    apiKeyController.addListener(
      () => imaController.apiKey.value = apiKeyController.text,
    );
  }

  @override
  void dispose() {
    clientIdController.dispose();
    apiKeyController.dispose();
    super.dispose();
  }

  String get _role => Get.find<AuthController>().currentUser.value?.role ?? 'student';

  @override
  Widget build(BuildContext context) {
    final isParent = _role == 'parent';
    return Scaffold(
      appBar: AppBar(title: const Text('ima 知识库同步')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _IntroCard(),
          const SizedBox(height: 16),
          // 整个部署没开通 ima：功能不出现，也不出现任何错误。
          // `available == null`（老服务端 / 还在读）时按可用处理，
          // 不能让一次升级把已开通家庭的入口弄丢。
          Obx(() {
            if (imaController.status.value.isFeatureEnabled) {
              return const SizedBox.shrink();
            }
            return const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: _FeatureUnavailableNote(),
            );
          }),
          Obx(() {
            final busy = imaController.busy.value;
            final status = imaController.status.value;
            return _StatusCard(
              status: status,
              busy: busy,
              isParent: isParent,
            );
          }),
          const SizedBox(height: 16),
          Obx(() {
            final error = imaController.error.value;
            if (error == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                error,
                style: const TextStyle(color: AppColors.danger),
              ),
            );
          }),
          // 只读状态拉取失败：灰字，不是红错。
          Obx(() {
            final hint = imaController.hint.value;
            if (hint == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                hint,
                style: const TextStyle(color: AppColors.textMuted),
              ),
            );
          }),
          if (isParent) ...[
            Obx(() {
              final status = imaController.status.value;
              final busy = imaController.busy.value;
              final canConnect = imaController.canConnect;
              // 已连接 / 已失效：失效时仍允许用新密钥重连（保留表单）。
              final showForm =
                  status.isFeatureEnabled && (!status.isActive || status.isExpired);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showForm) ...[
                    TextField(
                      controller: clientIdController,
                      decoration: const InputDecoration(
                        labelText: 'clientId',
                        hintText: 'ima 开放平台的 clientId',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: apiKeyController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'apiKey',
                        hintText: 'ima 开放平台的 apiKey',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: busy || !canConnect
                            ? null
                            : () async {
                                final ok = await imaController.connect();
                                if (!mounted) return;
                                if (ok) {
                                  clientIdController.clear();
                                  apiKeyController.clear();
                                  Get.snackbar('已连接', 'ima 知识库同步已开启');
                                }
                              },
                        child: busy
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('连接 ima'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      '密钥仅用于连接时验证，并加密存储于服务端；本机不留存明文。',
                      style: TextStyle(fontSize: 13, color: AppColors.textMuted),
                    ),
                  ],
                  if (status.isFeatureEnabled && status.isActive) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: busy
                            ? null
                            : () async {
                                await imaController.disconnect();
                                if (!mounted) return;
                                Get.snackbar('已断开', 'ima 同步已关闭，错题 / 打卡不再推送');
                              },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.danger,
                        ),
                        child: const Text('断开 ima 同步'),
                      ),
                    ),
                  ],
                ],
              );
            }),
          ] else ...[
            const _StudentReadOnlyNote(),
          ],
        ],
      ),
    );
  }
}

/// 「这个服务压根没开 ima」的说明卡。
///
/// 不是错误提示：不红、不带异常原文，只说清楚「功能没有，别的照常用」。
/// 放在页面顶部是因为表单和入口此时都不该出现。
class _FeatureUnavailableNote extends StatelessWidget {
  const _FeatureUnavailableNote();

  @override
  Widget build(BuildContext context) => Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '当前未开启 ima 知识库',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              SizedBox(height: 8),
              Text(
                '这是可选功能。错题复习、每日打卡和英文阅读都照常使用，不受影响。',
                style: TextStyle(color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      );
}

class _IntroCard extends StatelessWidget {
  const _IntroCard();

  @override
  Widget build(BuildContext context) => Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                '这是什么',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              SizedBox(height: 8),
              Text(
                '连接后，当前伴学这个学生的错题与打卡档案会同步到他自己的 '
                'ima 知识库，方便检索、整理与二次学习。',
                style: TextStyle(color: AppColors.text),
              ),
              SizedBox(height: 8),
              Text(
                '每个学生一个独立知识库；父母共管同一个孩子时共享同一份配置，'
                '不需要各自再设一次。',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              ),
              SizedBox(height: 6),
              Text(
                '这是可选功能：不连接，错题复习与打卡照常使用，数据只存在本应用。',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      );
}

/// 状态卡：展示当前同步状态 +（已连接时）每个孩子的知识库。
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.status,
    required this.busy,
    required this.isParent,
  });

  final ImaStatus status;
  final bool busy;
  final bool isParent;

  (String, Color) get _badge {
    if (status.isActive) return ('已开启', AppColors.success);
    if (status.isExpired) return ('已失效', AppColors.warning);
    return ('未开启', AppColors.textMuted);
  }

  @override
  Widget build(BuildContext context) {
    final (label, color) = _badge;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '同步状态',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
                const Spacer(),
                if (busy)
                  const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(color: color, fontWeight: FontWeight.w700),
                    ),
                  ),
              ],
            ),
            if (status.studentName != null || status.studentId != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.person_outline, size: 16, color: AppColors.textMuted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '当前学生：${status.studentName ?? status.studentId ?? ''}',
                      style: const TextStyle(color: AppColors.text),
                    ),
                  ),
                ],
              ),
              if (isParent)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    '切换孩子后，这里会跟着切成那个学生的配置。',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ),
            ],
            if (status.isExpired) ...[
              const SizedBox(height: 8),
              const Text(
                '密钥可能已失效，请由配置该学生的家长重新连接。',
                style: TextStyle(color: AppColors.warning),
              ),
            ],
            if (status.isActive && status.kbs.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                '这个学生的知识库',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              for (final kb in status.kbs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.folder_outlined, size: 16, color: AppColors.textMuted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          kb.kbName,
                          style: const TextStyle(color: AppColors.text),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 学生端只读提示。
class _StudentReadOnlyNote extends StatelessWidget {
  const _StudentReadOnlyNote();

  @override
  Widget build(BuildContext context) => Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                '学生端',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              SizedBox(height: 8),
              Text(
                'ima 知识库按学生建立，由家长在家长端连接与管理；学生端只能查看'
                '自己这份同步是否开启，不能修改连接。',
                style: TextStyle(color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      );
}
