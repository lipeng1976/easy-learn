import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'data_config.dart';

/// 前台更新检查的结果。
///
/// `available: false` 是**正常**状态，不是错误：未部署更新包、云版没有这台
/// 本机目录、第一次打开 app —— 三种情况都该安静地什么都不做。
class UpdateInfo {
  const UpdateInfo({
    required this.versionCode,
    required this.versionName,
    required this.changelog,
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.publishedAt,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) => UpdateInfo(
        versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
        versionName: (json['versionName'] as String?) ?? '',
        changelog: (json['changelog'] as String?) ?? '',
        fileName: (json['fileName'] as String?) ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        sha256: ((json['sha256'] as String?) ?? '').toLowerCase(),
        publishedAt: (json['publishedAt'] as String?) ?? '',
      );

  final int versionCode;
  final String versionName;
  final String changelog;
  final String fileName;
  final int size;
  final String sha256;
  final String publishedAt;

  /// 文件名必须是裸名：服务端已经挡过一次，客户端再挡一次是 defense in depth ——
  /// 本地写路径时如果让 `../` 进来，会覆盖应用私有目录里的任意文件。
  bool get hasSafeFileName => fileName.isNotEmpty
      && fileName == Uri.parse(fileName).pathSegments.last
      && fileName.toLowerCase().endsWith('.apk');
}

class UpdateCheckResult {
  const UpdateCheckResult({required this.available, this.latest});

  final bool available;
  final UpdateInfo? latest;

  /// 有没有一个真正可以下载的新版本（清单有效性由服务端把关，这里只判版本）。
  bool hasNewerThan(int currentVersionCode) => available
      && latest != null
      && latest!.versionCode > currentVersionCode
      && latest!.hasSafeFileName;
}

/// 下载完成的 APK 及校验结果。保留 [path] 是为了安装失败时能告诉用户文件在哪 ——
/// 「下载了但不知道放哪」是这类功能最常见的投诉。
class DownloadedApk {
  const DownloadedApk({required this.path, required this.sha256, required this.size});

  final String path;
  final String sha256;
  final int size;
}

/// App 自我更新：检查清冽 → 下载 → sha256 校验 → 交给平台安装。
///
/// ## 为什么不用 `DataApiClient.getJson` 检查版本
///
/// 那条路会带 session token、走缓存、还可能因为 token 过期把用户弹去登录。
/// 更新检查必须在**登录之前**就能做（旧版可能因 bug 根本登不进去），
/// 所以它用裸 `http.Client` 打公开端点，完全绕开会话层。
///
/// ## 为什么下载单独一条请求
///
/// 74MB 的 APK 不能用 `getJson` 那套「响应一定是 JSON 信封」的解析；
/// 也不能用 `DataApiClient.downloadBytes`（那是给照片用的，20 秒超时）。
class AppUpdateService {
  AppUpdateService({
    http.Client? httpClient,
    this.currentVersionCode = 1,
    this.currentVersionName = '1.0.0',
    Future<String> Function()? updatesDir,
    this.onProgress,
  })  : _http = httpClient ?? http.Client(),
        _updatesDir = updatesDir ?? _defaultUpdatesDir;

  final http.Client _http;
  final int currentVersionCode;
  final String currentVersionName;
  final Future<String> Function() _updatesDir;
  final void Function(int received, int total)? onProgress;

  static Future<String> _defaultUpdatesDir() async {
    final root = await getTemporaryDirectory();
    return root.path;
  }

  /// 主地址失效时用的备选列表（与数据服务同一套 FRP 备用地址）。
  List<String> fallbackBaseUrls = const [];

  Future<UpdateCheckResult> check(Iterable<String> baseUrls) async {
    for (final base in _unique(baseUrls)) {
      final uri = Uri.parse(joinUrlPath(base, '/app/update'));
      try {
        final res = await _http.get(uri).timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) continue;
        final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        if (body['ok'] != true) continue;
        final data = body['data'] as Map<String, dynamic>? ?? {};
        if (data['available'] != true) {
          // 服务端明确说「没有更新能力」——不去试下一个地址，那只会重复几次无谓请求。
          return const UpdateCheckResult(available: false);
        }
        return UpdateCheckResult(
          available: true,
          latest: UpdateInfo.fromJson(data['latest'] as Map<String, dynamic>? ?? {}),
        );
      } on Object {
        // 网络抖动 / 非 JSON / 超时：换下一个地址。全失败由调用方按「没有更新」处理。
        continue;
      }
    }
    return const UpdateCheckResult(available: false);
  }

  Future<DownloadedApk> download(
    Iterable<String> baseUrls,
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
  }) async {
    final report = onProgress ?? this.onProgress;
    if (!info.hasSafeFileName) {
      throw const UpdateDownloadException('更新包文件名不合法，已取消下载');
    }

    final dir = Directory(await _updatesDir());
    await dir.create(recursive: true);
    // 固定文件名：同一版本重复下载就是覆盖，不会攒一堆 74MB 的旧包。
    final dest = File('${dir.path}${Platform.pathSeparator}${info.fileName}');
    if (!await dest.exists() || await dest.length() != info.size) {
      final tmp = File('${dest.path}.part');
      http.StreamedResponse? response;
      String? lastError;
      for (final base in _unique(baseUrls)) {
        final request = http.Request('GET', Uri.parse(joinUrlPath(base, '/app/download')));
        request.headers['accept'] = 'application/vnd.android.package-archive';
        try {
          final candidate = await _http.send(request).timeout(const Duration(minutes: 10));
          if (candidate.statusCode == 200) {
            response = candidate;
            break;
          }
          lastError = 'HTTP ${candidate.statusCode}';
          await candidate.stream.drain<void>();
        } on Object catch (e) {
          lastError = '$e';
        }
      }
      if (response == null) {
        throw UpdateDownloadException('下载更新包失败：$lastError');
      }
      final sink = tmp.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          report?.call(received, info.size);
        }
      } finally {
        await sink.close();
      }
      if (info.size > 0 && await tmp.length() != info.size) {
        throw UpdateDownloadException(
          '更新包大小不对（期望 ${info.size} 字节，实得 ${await tmp.length()}）',
        );
      }
      await tmp.rename(dest.path);
    }

    final digest = sha256.convert(await dest.readAsBytes()).toString();
    if (info.sha256.isNotEmpty && digest != info.sha256) {
      // 校验失败就删掉：留着一个「看着下完了但校验不过」的包，下次会被
      // size 相同骗过去不再重下，用户点一百次「更新」都是同一个坏包。
      await dest.delete();
      throw UpdateDownloadException('更新包校验失败，请重新下载');
    }
    report?.call(info.size, info.size);
    return DownloadedApk(path: dest.path, sha256: digest, size: await dest.length());
  }

  /// 去重且去掉空串：`baseUrls.first` 在下载时会被当作首选，不能是空。
  List<String> _unique(Iterable<String> urls) {
    final out = <String>[];
    for (final u in urls) {
      final v = u.trim();
      if (v.isNotEmpty && !out.contains(v)) out.add(v);
    }
    return out;
  }
}

class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 平台安装通道。Web / iOS 没有系统 APK 安装器，返回 false 让上层显示路径提示。
abstract class ApkInstaller {
  const ApkInstaller();
  Future<bool> install(String path);
}

class MethodChannelApkInstaller extends ApkInstaller {
  const MethodChannelApkInstaller({required this.channel});

  final MethodChannel channel;

  @override
  Future<bool> install(String path) async {
    if (kIsWeb) return false;
    try {
      final ok = await channel.invokeMethod<bool>('installApk', {'path': path});
      return ok ?? false;
    } on Object {
      // 卓易通容器可能没有安装器；这里必须把「失败」如实带回去，
      // 由界面告诉用户 APK 在哪个目录，而不是显示「更新成功」然后什么都没发生。
      return false;
    }
  }
}
