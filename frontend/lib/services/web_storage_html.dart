// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html';

import 'web_storage.dart';

class _HtmlWebStorage implements WebStorage {
  @override
  String? read(String key) => window.localStorage[key];

  @override
  bool write(String key, String value) {
    try {
      window.localStorage[key] = value;
      return true;
    } catch (_) {
      // QuotaExceededError：浏览器存储空间不足
      return false;
    }
  }

  @override
  void remove(String key) {
    window.localStorage.remove(key);
  }
}

WebStorage createWebStorage() => _HtmlWebStorage();
