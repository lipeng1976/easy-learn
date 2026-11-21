// 直传探针 **第 2 步**：Dart 客户端按 `RemoteImageStorageService` 的方式
// 发一次 PUT，看对象存储认不认。
//
// ## 它验的是什么
//
// 服务端签名已被 node 验通。剩下唯一没验过的一环是：`package:http` 会不会
// 把服务端返回的那几个头**原样**发出去。V4 把 `host` 纳入签名，而 dart:io
// 对 Host 有自己的处理 —— 若它被改写或吞掉，OSS 回 `SignatureDoesNotMatch`，
// 而那个错误看起来像「AccessKey 配错了」。
//
// 所以这里刻意**一个头都不加、一个头都不减**，与 `putToAbsoluteUrl` 里
// 「整份透传」的写法逐字一致。
//
// ## 跑法
//
//   1. node tools/direct-put-sign.mjs        （导出签名）
//   2. dart run tools/direct_put_probe.dart  （本文件：发 PUT）
//
// ⚠️ 探针只写一个约 100 字节的对象到 `__dart_put_probe__/` 下，跑完自行删除。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

const String _signedPath =
    'C:/Users/lp_pr/WorkBuddy/2026-09-14-16-29-22/_signed_put.json';

Future<void> main() async {
  final raw = File(_signedPath).readAsStringSync();
  final signed = jsonDecode(raw) as Map<String, dynamic>;

  final uploadUrl = signed['uploadUrl'] as String;
  final storageKey = signed['storageKey'] as String;
  final headers = <String, String>{};
  (signed['headers'] as Map).forEach((k, v) {
    if (v != null) headers['$k'] = '$v';
  });

  print('目标   : $uploadUrl');
  print('键     : $storageKey');
  print('发送头 : ${headers.keys.join(', ')}');
  // host 单独点出来：它是本探针唯一真正怀疑的那个头。
  print('含 host: ${headers.containsKey('Host') || headers.containsKey('host')}');

  final payload = Uint8List.fromList(
    utf8.encode('easylearn dart direct-put probe 直传验证 ${DateTime.now().toIso8601String()}'),
  );
  print('载荷   : ${payload.length} 字节');

  http.Response res;
  try {
    res = await http.put(Uri.parse(uploadUrl), headers: headers, body: payload);
  } catch (e) {
    print('❌ PUT 抛出异常：$e');
    exitCode = 2;
    return;
  }

  print('① PUT  → HTTP ${res.statusCode} ${res.reasonPhrase}');
  if (res.statusCode != 200) {
    print('   响应：${res.body.length > 500 ? res.body.substring(0, 500) : res.body}');
    print('   ← 客户端这条路的签名没被接受。');
    exitCode = 1;
    return;
  }

  // ② 读回：用**服务端**那条已验证的路径（另一条独立判据），
  //    确认字节经过 Dart 这一趟没有损坏 —— 载荷里有中文，非 ASCII 也会被验到。
  final origin = signed['origin'] as String;
  final key = signed['key'] as String;

  // 读回与删除都要签名，而签名算法只在 node 侧。所以这里只报「PUT 成功」，
  // 由 `tools/direct-put-verify.mjs` 接着做读回与清理。
  print('   ✅ 签名被接受（客户端直传这一步成立）');
  print('');
  print('下一步：node tools/direct-put-verify.mjs   （读回比对 + 清理）');
  print('  origin=$origin');
  print('  key=$key');
}
