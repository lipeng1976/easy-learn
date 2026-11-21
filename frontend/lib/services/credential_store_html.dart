// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html';

import 'credential_store.dart';

/// Web：直接用浏览器的 `localStorage`。
///
/// ## 与移动端实现的差别（是刻意的，不是疏漏）
///
/// 1. **不加密**。浏览器的 `localStorage` 已经是「同源隔离 + 用户 profile」
///    这一层，且明文对「这台机器的这个用户」是可见的 —— 与移动端
///    应用私有目录是同一档语义。真正要在意的是**共享电脑**，那是产品问题
///    （勾选框旁边的文案已经是一句明确的授权），不是在这里偷偷加密能解决的。
///    ⚠️ 更要紧的是：Web 上本来就有老用户存着明文，改成密文之后
///    **他们的密码会读不出来** —— 为了一个不存在的威胁换掉可用性，不值。
/// 2. **`readSecret` 与 `read` 等价**：数据本身就是明文，别做无谓的搬运。
///
/// ## 它原先在哪
///
/// 这段逻辑本来在 `web_storage_html.dart` 里，与一个跨平台的
/// `WebStorage` 抽象共用一个文件。2026-10-06（B37）把它挪到这里：
/// 那个抽象在移动端**没有实现**，而「它叫什么」掩盖了这件事。
/// 现在 `CredentialStore` 三路都有真实实现，谁缺了会被编译/测试挡住。
class _HtmlCredentialStore implements CredentialStore {
  @override
  Future<void> initialize() async {
    // `localStorage` 是同步可读的，没有「载入」这一步。
  }

  @override
  String? read(String key) => window.localStorage[key];

  @override
  Future<String?> readSecret(String key) async => window.localStorage[key];

  @override
  Future<bool> write(String key, String value, {bool secret = false}) async {
    try {
      window.localStorage[key] = value;
      return true;
    } catch (_) {
      // QuotaExceededError：浏览器存储空间不足。
      // 返回 false 让调用方**能看见**这次没存上（旧接口返回 void，
      // 于是「上传成功但刷新后消失」变成一个查不出来的现象）。
      return false;
    }
  }

  @override
  Future<void> remove(String key) async {
    window.localStorage.remove(key);
  }
}

CredentialStore createPlatformCredentialStore() => _HtmlCredentialStore();
