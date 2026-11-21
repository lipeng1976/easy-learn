/// 服务端照片键的形状判别。
///
/// ## 为什么客户端也需要认这个
///
/// `homework_image.storage_key` 现在有**两种形态**，而客户端必须能分辨：
///
/// - **服务端相对键**（本文件认的那种）：`20260920/<studentId>/<uuid>.jpg`，
///   相对服务端的存储根目录。任何一台设备都能通过
///   `/data/homework/images/file?id=` 把它取回来。
/// - **旧的设备本地标识**：Web 端是 `memory://…`（浏览器存储的键）、
///   原生端是绝对路径。这些值**只在当初那台设备上成立** ——
///   字节从来没有离开过那台设备，服务端拿不到。
///
/// 分辨错的代价是**症状相同、处置相反**：两种都表现为
/// 「照片位置一片空白、没有任何报错」。该回退本地读的（旧数据）
/// 若被当成服务端键去请求，就永远看不到；该走服务端的若去本地找，同样。
///
/// ## 权威定义在哪
///
/// 服务端 `serverless/data-service/src/imagestore.js` 的 `SERVER_KEY_PATTERN`。
/// 这里是**客户端副本**，不是第二份定义 —— `test/image_key_test.dart`
/// 与 `test/images.test.js` 用**同一组样本**钉住两侧行为，
/// 任何一侧改了规则，那一侧当场红。
library;

/// 服务端键：`YYYYMMDD/<studentId>/<文件名>.<扩展名>`。
final RegExp _serverKeyPattern = RegExp(r'^\d{8}/[A-Za-z0-9_-]+/[A-Za-z0-9._-]+$');

/// 这个 `storageKey` 是不是**服务端相对键**（能通过 HTTP 取回字节）。
///
/// `..` 段要显式挡掉：上面那条正则的字符类含 `.`，所以 `20260920/abc/..`
/// **能通过它**。而那个键在服务端会被解析成「根目录之内的一个目录」
/// （不是穿越），最后炸在「读一个目录」上 —— 一个和权限毫无关系的报错。
/// 两侧都挡，是为了让这条规则只有一种解释。
bool isServerImageKey(String key) {
  if (key.isEmpty || key.contains('\u0000')) return false;
  if (!_serverKeyPattern.hasMatch(key)) return false;
  for (final segment in key.split('/')) {
    if (segment == '.' || segment == '..') return false;
  }
  return true;
}
