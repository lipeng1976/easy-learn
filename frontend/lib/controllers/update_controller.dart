import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../services/app_update_service.dart';
import '../services/database_service.dart';

/// 更新检测的三态。用枚举而不是 bool：`checking` 时按钮要转圈、不能重复点。
enum UpdatePhase { idle, checking, downloading, ready, failed }

/// 更新流程的唯一状态源。
///
/// 页面（个人页卡片）与启动弹窗共用同一个实例，避免「两处各查一次、
/// 一个说有新版一个说没有」——那种分叉在服务端的清单变了时尤其容易发生。
class UpdateController extends GetxController {
  // ignore: prefer_initializing_formals
  UpdateController({AppUpdateService? service, ApkInstaller? installer})
      : _service = service,
        _installer = installer;

  AppUpdateService? _service;
  ApkInstaller? _installer;

  final phase = UpdatePhase.idle.obs;
  final info = Rxn<UpdateInfo>();
  final progress = 0.0.obs;
  final message = ''.obs;
  UpdateCheckResult? _lastCheck;

  /// 编译期烧入的版本号。构建脚本每次构建都会递增，见 tools/build-local-apk.mjs。
  static const int currentVersionCode =
      int.fromEnvironment('APP_VERSION_CODE', defaultValue: 1);
  static const String currentVersionName =
      String.fromEnvironment('APP_VERSION_NAME', defaultValue: '1.0.0');

  AppUpdateService get _effectiveService => _service ??= AppUpdateService(
        httpClient: null,
        currentVersionCode: currentVersionCode,
        currentVersionName: currentVersionName,
      );

  ApkInstaller get _effectiveInstaller => _installer ??= const MethodChannelApkInstaller(
        channel: MethodChannel('cn.easylearn.app/updater'),
      );

  /// 候选地址：与业务请求同一份（首选 + FRP 备用），不另造一份配置。
  List<String> get _baseUrls {
    final api = DatabaseService.cloud?.api;
    if (api == null) return const [];
    return <String>[api.activeBaseUrl, ...api.config.fallbackBaseUrls];
  }

  Future<UpdateCheckResult> check({bool showSpinner = true}) async {
    final bases = _baseUrls;
    // 纯本地模式没有数据服务 —— 不是故障，安静跳过（ima 那条硬规矩）。
    if (bases.isEmpty) return const UpdateCheckResult(available: false);
    if (showSpinner) phase.value = UpdatePhase.checking;
    message.value = '';
    try {
      final result = await _effectiveService.check(bases);
      _lastCheck = result;
      info.value = result.latest;
      phase.value = UpdatePhase.idle;
      return result;
    } on Object catch (e) {
      message.value = '检查更新失败：$e';
      phase.value = UpdatePhase.failed;
      return const UpdateCheckResult(available: false);
    }
  }

  bool get hasUpdate => _lastCheck?.hasNewerThan(currentVersionCode) ?? false;

  Future<DownloadedApk?> downloadAndInstall() async {
    final latest = info.value;
    if (latest == null || !hasUpdate) return null;
    phase.value = UpdatePhase.downloading;
    progress.value = 0;
    message.value = '';
    try {
      final apk = await _effectiveService.download(
        _baseUrls,
        latest,
        onProgress: (received, total) {
          progress.value = total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
        },
      );
      phase.value = UpdatePhase.ready;
      return apk;
    } on UpdateDownloadException catch (e) {
      message.value = e.message;
      phase.value = UpdatePhase.failed;
      return null;
    } on Object catch (e) {
      message.value = '下载失败：$e';
      phase.value = UpdatePhase.failed;
      return null;
    }
  }

  /// 拉起系统安装器。`false` 不是异常 —— 卓易通容器很可能拒绝 intent，
  /// 那种情况下界面必须把 APK 路径告诉用户，让他自己去文件管理器点装。
  Future<bool> install(DownloadedApk apk) => _effectiveInstaller.install(apk.path);

  /// Web 版没有 APK 安装器：下载仍能做，但提示语要说清楚「这是给手机用的包」。
  bool get canInstallApk => !kIsWeb;
}
