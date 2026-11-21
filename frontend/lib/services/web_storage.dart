import 'web_storage_stub.dart' if (dart.library.html) 'web_storage_html.dart';

abstract class WebStorage {
  String? read(String key);

  /// 写入并返回是否成功。
  ///
  /// 浏览器 localStorage 在超出配额时只会抛异常/静默失败，
  /// 旧接口返回 void 让调用方无法判断，表现为「图片上传成功但刷新后消失」。
  bool write(String key, String value);

  void remove(String key);
}

final WebStorage webStorage = createWebStorage();
