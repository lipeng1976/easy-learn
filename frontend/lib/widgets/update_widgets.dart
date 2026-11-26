import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/update_controller.dart';
import '../services/app_update_service.dart';

/// 个人页的「版本更新」入口。
///
/// 只在本机版（有数据服务 + 服务端配了更新包）真正可用：查不到清单时
/// **不显示**，而不是显示一个点了没反应的按钮。
class UpdateCard extends StatefulWidget {
  const UpdateCard({super.key});

  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<UpdateCard> {
  final controller = Get.put(UpdateController());
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    // 静默预检一次：只决定卡片显不显示，不弹窗（启动提醒由 main 里那次负责）。
    controller.check(showSpinner: false).then((result) {
      if (!mounted) return;
      setState(() => _checked = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasUpdate = controller.hasUpdate;
    if (_checked && !hasUpdate) return const SizedBox.shrink();

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.system_update, size: 22),
                const SizedBox(width: 8),
                const Text('版本更新', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                const Spacer(),
                Text(
                  UpdateController.currentVersionName,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (hasUpdate)
              Text(
                '发现新版本 ${controller.info.value?.versionName ?? ''}，建议更新后使用。',
                style: const TextStyle(color: Colors.green),
              )
            else
              const Text('检查是否有新版本。更新包只在本机部署上提供。'),
            const SizedBox(height: 12),
            Obx(() {
              final phase = controller.phase.value;
              return SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: phase == UpdatePhase.downloading
                      ? null
                      : () async {
                          final result = await controller.check();
                          if (!context.mounted) return;
                          if (result.hasNewerThan(UpdateController.currentVersionCode)) {
                            showUpdateDialog(context, controller);
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('当前已是最新版本')),
                            );
                          }
                        },
                  child: Text(phase == UpdatePhase.checking ? '检查中…' : '检查更新'),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

/// 更新确认弹窗：把「是否升级」的选择权留给用户，绝不自动下载或安装。
void showUpdateDialog(BuildContext context, UpdateController controller) {
  final info = controller.info.value;
  if (info == null) return;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => UpdateDialog(controller: controller, info: info),
  );
}

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.controller, required this.info});

  final UpdateController controller;
  final UpdateInfo info;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  DownloadedApk? _downloaded;
  bool _installAttempted = false;

  Future<void> _start() async {
    final apk = await widget.controller.downloadAndInstall();
    if (!mounted) return;
    if (apk == null) return;
    setState(() => _downloaded = apk);

    if (!widget.controller.canInstallApk) return;
    final ok = await widget.controller.install(apk);
    if (!mounted) return;
    setState(() => _installAttempted = true);
    if (ok && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return AlertDialog(
      title: Text('发现新版本 ${widget.info.versionName}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.info.changelog.isEmpty ? '修复了一些问题，优化了体验。' : widget.info.changelog),
            const SizedBox(height: 10),
            Text(
              '大小 ${(widget.info.size / 1024 / 1024).toStringAsFixed(1)} MB · 下载后可以自己决定是否安装。',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            Obx(() {
              if (c.phase.value != UpdatePhase.downloading && c.progress.value == 0) {
                return const SizedBox.shrink();
              }
              final p = c.progress.value;
              return Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  children: [
                    LinearProgressIndicator(value: p == 0 ? null : p),
                    const SizedBox(height: 4),
                    Text('${(p * 100).round()}%', style: const TextStyle(fontSize: 11)),
                  ],
                ),
              );
            }),
            Obx(() {
              final msg = c.message.value;
              return msg.isEmpty
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(msg, style: const TextStyle(color: Colors.red, fontSize: 12)),
                    );
            }),
            if (_downloaded != null && _installAttempted)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: SelectableText(
                  '系统安装器没能拉起。APK 已下载到：\n${_downloaded!.path}\n'
                  '可以打开文件管理器手动点击安装。',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('稍后'),
        ),
        Obx(() {
          final busy = c.phase.value == UpdatePhase.downloading;
          return FilledButton(
            onPressed: busy || _downloaded != null ? null : _start,
            child: Text(busy ? '下载中…' : (_downloaded == null ? '下载并更新' : '已下载')),
          );
        }),
      ],
    );
  }
}
