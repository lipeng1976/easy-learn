import 'package:flutter/material.dart';

import '../config/api_endpoints.dart';
import '../config/app_config.dart';
import '../core/network/api_client.dart';
import '../core/network/api_exception.dart';

/// 最小首页：展示构建期配置 + 一键检查数据服务。
/// 只显示公开端点地址，不显示任何密钥或存储根目录。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = '未检查';
  bool _busy = false;

  Future<void> _checkHealth() async {
    if (!AppConfig.hasCloudBackend) {
      setState(() => _status = '未配置 DATA_API_BASE_URL（构建期注入）');
      return;
    }
    setState(() {
      _busy = true;
      _status = '检查中…';
    });

    var next = _status;
    try {
      final client = ApiClient(
        baseUrl: AppConfig.dataApiBaseUrl,
        timeout: Duration(milliseconds: AppConfig.dataTimeoutMs),
      );
      final response = await client.getJson(ApiEndpoints.health);
      next = '数据服务：${response['status'] ?? 'unknown'}';
    } on ApiException catch (err) {
      next = '失败：${err.message}${err.shouldRetry ? '（可重试）' : ''}';
    } catch (err) {
      next = '失败：$err';
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final dataUrl = AppConfig.hasCloudBackend ? AppConfig.dataApiBaseUrl : '（未注入）';
    final aiUrl = AppConfig.hasAiGateway ? AppConfig.aiBaseUrl : '（未注入）';

    return Scaffold(
      appBar: AppBar(title: const Text('伴学 · 工程交接基线')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '本页只验证「构建期配置 → HTTP → 服务健康」这条链路。'
              '业务页面按 docs/source-index.md 从原工程迁入。',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 20),
            Text('DATA_API_BASE_URL：$dataUrl'),
            Text('AI_BASE_URL：$aiUrl'),
            Text('DATA_TIMEOUT_MS：${AppConfig.dataTimeoutMs} ms'),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _busy ? null : _checkHealth,
              child: Text(_busy ? '检查中…' : '检查数据服务'),
            ),
            const SizedBox(height: 12),
            Text(_status, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
